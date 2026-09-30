using System.Runtime.InteropServices;
using System.Windows.Automation;

namespace YaprFlow.Windows;

internal sealed record Target(IntPtr Window, int ProcessId, int[] RuntimeId);

internal sealed class TextDelivery : ITextDelivery
{
    // One outstanding UIA call at most, even if a third-party app hangs forever.
    private readonly SemaphoreSlim uiaGate = new(1, 1);
    public async Task<object?> CaptureTargetAsync() => await ReadTargetAsync();

    private async Task<Target?> ReadTargetAsync()
    {
        if (!await uiaGate.WaitAsync(0)) return null;
        var task = Task.Run(() =>
        {
            try
            {
                var window = Native.GetForegroundWindow();
                Native.GetWindowThreadProcessId(window, out var pid);
                if (pid == Environment.ProcessId || pid == 0) return null;
                var focused = AutomationElement.FocusedElement;
                if (focused is null || focused.Current.ProcessId != pid || focused.Current.IsPassword ||
                    !focused.Current.IsEnabled || !focused.Current.HasKeyboardFocus) return null;
                // Require an editable control. Unknown controls fail closed; text
                // remains recoverable in history instead of typing into a password
                // field or invoking application shortcuts.
                var editable = focused.TryGetCurrentPattern(ValuePattern.Pattern, out var value) &&
                    !((ValuePattern)value).Current.IsReadOnly;
                editable |= focused.Current.ControlType == ControlType.Edit &&
                    focused.TryGetCurrentPattern(TextPattern.Pattern, out _);
                if (!editable || Native.GetForegroundWindow() != window) return null;
                return new Target(window, (int)pid, focused.GetRuntimeId());
            }
            catch { return null; }
            finally { uiaGate.Release(); }
        });
        try { return await task.WaitAsync(TimeSpan.FromMilliseconds(450)); }
        catch (TimeoutException) { return null; }
    }

    public async Task<string> DeliverAsync(string text, object? target, CancellationToken token)
    {
        if (target is not Target original) return "Not inserted — no supported, non-password field was focused";
        if (text.Length > 30000) return "Not inserted — transcript is too long for automatic insertion";
        // Avoid Ctrl/Alt held from push-to-talk changing synthetic text into shortcuts.
        var deadline = DateTime.UtcNow.AddSeconds(2);
        while (Native.AnyModifierDown && DateTime.UtcNow < deadline) await Task.Delay(25, token);
        token.ThrowIfCancellationRequested();
        if (Native.AnyModifierDown) return "Not inserted — release your modifier keys and copy from History";
        var current = await ReadTargetAsync();
        token.ThrowIfCancellationRequested();
        if (current is null || current.Window != original.Window || current.ProcessId != original.ProcessId ||
            !current.RuntimeId.SequenceEqual(original.RuntimeId) || Native.GetForegroundWindow() != original.Window)
            return "Not inserted — the focused field changed; copy from History";
        var inputs = new Native.INPUT[text.Length * 2];
        for (var i = 0; i < text.Length; i++)
        {
            inputs[i * 2] = new Native.INPUT { Type = 1, Data = new Native.InputUnion
                { Keyboard = new Native.KEYBDINPUT { Scan = text[i], Flags = 0x0004 } } };
            inputs[i * 2 + 1] = new Native.INPUT { Type = 1, Data = new Native.InputUnion
                { Keyboard = new Native.KEYBDINPUT { Scan = text[i], Flags = 0x0004 | 0x0002 } } };
        }
        // No clipboard writes, focus stealing, Return, or automatic resend.
        var count = Native.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Native.INPUT>());
        if (count != inputs.Length) return "Insertion blocked or incomplete — check the field before copying from History";
        return "Text sent to the original field";
    }
}
