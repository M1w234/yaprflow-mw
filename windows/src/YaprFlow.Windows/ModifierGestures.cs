using System.Runtime.InteropServices;
using System.Windows.Threading;

namespace YaprFlow.Windows;

/// Pass-through keyboard hook: observes only chord transitions, never suppresses keys.
internal sealed class ModifierGestures : IDisposable
{
    private delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetWindowsHookExW(int id, HookProc callback, IntPtr module, uint thread);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string? name);
    [StructLayout(LayoutKind.Sequential)] private struct Keyboard { public uint Key, Scan, Flags, Time; public UIntPtr Extra; }
    private readonly HookProc callback;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(25) };
    private ModifierGestureState state = new(ModifierGesture.Off, false);
    private IntPtr hook;
    public event Action<GestureAction>? Action;
    public ModifierGestures()
    {
        callback = Observe;
        timer.Tick += (_, _) => Emit(state.Tick(Environment.TickCount64));
    }
    public bool Configure(Settings settings)
    {
        if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }
        timer.Stop(); state = new(settings.ModifierGesture, settings.DoubleTapLock);
        if (settings.ModifierGesture == ModifierGesture.Off) return true;
        hook = SetWindowsHookExW(13, callback, GetModuleHandle(null), 0);
        if (hook == IntPtr.Zero) return false;
        timer.Start(); return true;
    }
    public void Reset() => state.Reset();
    private IntPtr Observe(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0)
        {
            var data = Marshal.PtrToStructure<Keyboard>(lParam);
            if ((data.Flags & 0x10) == 0 && wParam.ToInt32() is 0x100 or 0x104 or 0x101 or 0x105)
                Emit(state.Key((int)data.Key, wParam.ToInt32() is 0x100 or 0x104, Environment.TickCount64));
        }
        return CallNextHookEx(hook, code, wParam, lParam);
    }
    private void Emit(GestureAction action)
    {
        // Keep hook callbacks short; microphone/UI work belongs on the dispatcher.
        if (action != GestureAction.None) Application.Current.Dispatcher.BeginInvoke(() => Action?.Invoke(action));
    }
    public void Dispose() { timer.Stop(); if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }
}
