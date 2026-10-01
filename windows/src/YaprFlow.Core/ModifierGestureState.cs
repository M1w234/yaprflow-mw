namespace YaprFlow.Core;

public enum GestureAction { None, StartHold, StartLocked, Finish, Cancel }

/// Only modifier state is retained, never typed characters. Call on the UI thread.
public sealed class ModifierGestureState(ModifierGesture mode, bool doubleTap)
{
    private readonly HashSet<int> down = [];
    private bool candidate, dirty, holding, locked;
    private long began, lastTap = -1000;
    private int Ctrl => mode == ModifierGesture.RightCtrlShift ? 0xA3 : 0xA2;
    private int Shift => mode == ModifierGesture.RightCtrlShift ? 0xA1 : 0xA0;
    public void Reset() { down.Clear(); candidate = dirty = holding = locked = false; lastTap = -1000; }
    public GestureAction Key(int key, bool pressed, long now)
    {
        if (mode == ModifierGesture.Off) return GestureAction.None;
        bool modifier = key is >= 0xA0 and <= 0xA5 or 0x5B or 0x5C;
        if (modifier) { if (pressed) { if (!down.Add(key)) return GestureAction.None; } else down.Remove(key); }
        if (pressed && (!modifier || key != Ctrl && key != Shift))
        {
            dirty = true; candidate = false; lastTap = -1000;
            if (holding) { holding = false; return GestureAction.Cancel; }
        }
        if (!pressed && candidate && (key == Ctrl || key == Shift))
        {
            candidate = false;
            if (holding) { holding = false; dirty = down.Count > 0; return GestureAction.Finish; }
            if (!dirty)
            {
                dirty = down.Count > 0;
                if (locked) { locked = false; lastTap = -1000; return GestureAction.Finish; }
                if (doubleTap && now - lastTap <= 350) { locked = true; lastTap = -1000; return GestureAction.StartLocked; }
                lastTap = now;
            }
        }
        if (down.Count == 0) dirty = false;
        if (pressed && !dirty && !candidate && down.Count == 2 && down.Contains(Ctrl) && down.Contains(Shift))
        { candidate = true; began = now; }
        return GestureAction.None;
    }
    public GestureAction Tick(long now)
    {
        if (!candidate || dirty || holding || locked || now - began < 180) return GestureAction.None;
        holding = true; lastTap = -1000; return GestureAction.StartHold;
    }
}
