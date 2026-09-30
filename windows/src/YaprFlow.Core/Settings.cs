namespace YaprFlow.Core;

public enum TriggerMode { Hold, Toggle }

// Values deliberately match Win32 MOD_* and VK_*, not macOS scan codes.
public sealed record Shortcut(uint Modifiers = 3, uint Key = 32, TriggerMode Mode = TriggerMode.Hold)
{
    public bool IsValid => Enum.IsDefined(Mode) && (Modifiers & ~7u) == 0 &&
        (Key is >= 0x41 and <= 0x5A or >= 0x30 and <= 0x39 or >= 0x70 and <= 0x87 || Key == 32) &&
        (Modifiers != 0 || Key is >= 0x7C and <= 0x87);
    public string Label => string.Concat((Modifiers & 2) != 0 ? "Ctrl + " : "",
        (Modifiers & 1) != 0 ? "Alt + " : "", (Modifiers & 4) != 0 ? "Shift + " : "") +
        (Key == 32 ? "Space" : Key is >= 0x70 and <= 0x87 ? $"F{Key - 0x6F}" : ((char)Key).ToString());
}

public sealed record Settings
{
    public int SchemaVersion { get; init; } = 1;
    public Shortcut Primary { get; init; } = new();
    public Shortcut? External { get; init; }
    public bool AutomaticInsertion { get; init; } = true;
    public bool LightCleanup { get; init; } = true;
    public bool KeepHistory { get; init; } = true;
    public bool Sounds { get; init; } = true;
    public int MicrophoneDevice { get; init; } = -1;

    public void Validate()
    {
        if (SchemaVersion != 1 || Primary is null || !Primary.IsValid ||
            (External is not null && (!External.IsValid ||
            (External.Key == Primary.Key && External.Modifiers == Primary.Modifiers))) || MicrophoneDevice < -1)
            throw new InvalidDataException("Settings contain an unsupported or conflicting shortcut. Reset shortcuts in Settings.");
    }
}

public sealed record VocabularyRule(string Heard, string Replacement);
public sealed record HistoryEntry(Guid Id, DateTimeOffset CreatedAt, string Text, string Delivery);
