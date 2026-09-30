using System.Windows.Interop;
using System.Windows.Threading;

namespace YaprFlow.Windows;

internal sealed class HotkeyService : IDisposable
{
    private readonly HwndSource source = new(new HwndSourceParameters("yaprflow hotkeys")
    { ParentWindow = new IntPtr(-3), WindowStyle = 0 });
    private readonly Dictionary<int, Shortcut> bindings = [];
    private readonly HashSet<int> pressed = [];
    private readonly DispatcherTimer releaseTimer = new() { Interval = TimeSpan.FromMilliseconds(25) };
    private int nextId = 100;
    private const int EscapeId = 1;
    public bool HasShortcut => bindings.Count > 0;
    public event Action<int, Shortcut>? Pressed;
    public event Action<int, Shortcut>? Released;
    public event Action? Escape;

    public HotkeyService()
    {
        source.AddHook(Hook);
        releaseTimer.Tick += (_, _) => PollReleases();
        releaseTimer.Start();
    }

    public bool Configure(Settings settings)
    {
        settings.Validate();
        // Reuse unchanged registrations; register new ones before removing old
        // ones. A conflict never strands the user with no working shortcut.
        var wanted = new[] { settings.Primary, settings.External }.OfType<Shortcut>().ToArray();
        var additions = new Dictionary<int, Shortcut>();
        foreach (var shortcut in wanted)
        {
            if (bindings.Values.Any(b => b.Key == shortcut.Key && b.Modifiers == shortcut.Modifiers)) continue;
            var id = nextId++;
            if (!Native.RegisterHotKey(source.Handle, id, shortcut.Modifiers | 0x4000u, shortcut.Key))
            {
                foreach (var created in additions.Keys) Native.UnregisterHotKey(source.Handle, created);
                return false;
            }
            additions.Add(id, shortcut);
        }
        foreach (var id in bindings.Keys.ToArray())
        {
            var old = bindings[id];
            var current = wanted.FirstOrDefault(s => s.Key == old.Key && s.Modifiers == old.Modifiers);
            if (current is null) { Native.UnregisterHotKey(source.Handle, id); bindings.Remove(id); }
            else bindings[id] = current;
        }
        foreach (var pair in additions) bindings.Add(pair.Key, pair.Value);
        pressed.Clear();
        return true;
    }
    public bool SetEscape(bool enabled)
    {
        Native.UnregisterHotKey(source.Handle, EscapeId);
        return !enabled || Native.RegisterHotKey(source.Handle, EscapeId, 0x4000, 0x1B);
    }
    private IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg != 0x0312) return IntPtr.Zero;
        var id = wParam.ToInt32();
        if (id == EscapeId) { handled = true; Escape?.Invoke(); }
        else if (bindings.TryGetValue(id, out var shortcut) && pressed.Add(id))
        { handled = true; Pressed?.Invoke(id, shortcut); }
        return IntPtr.Zero;
    }
    private void PollReleases()
    {
        foreach (var id in pressed.ToArray())
        {
            if (!bindings.TryGetValue(id, out var shortcut)) { pressed.Remove(id); continue; }
            // Release on either the trigger key or a required modifier going up.
            if (Native.IsDown((int)shortcut.Key) &&
                ((shortcut.Modifiers & 1) == 0 || Native.IsDown(0x12)) &&
                ((shortcut.Modifiers & 2) == 0 || Native.IsDown(0x11)) &&
                ((shortcut.Modifiers & 4) == 0 || Native.IsDown(0x10))) continue;
            pressed.Remove(id);
            Released?.Invoke(id, shortcut);
        }
    }
    public void Dispose()
    {
        releaseTimer.Stop();
        foreach (var id in bindings.Keys) Native.UnregisterHotKey(source.Handle, id);
        SetEscape(false);
        source.Dispose();
    }
}
