using Xunit;
using YaprFlow.Core;
using YaprFlow.Speech;

namespace YaprFlow.Tests;

public class CoreTests
{
    [Theory]
    [InlineData("  the the the house , is ready!!  ", "the house, is ready!!")]
    [InlineData("log in in the morning", "log in in the morning")]
    [InlineData("I I think  so ;;;", "I think so;")]
    [InlineData("a\n\n\n\nb", "a\n\nb")]
    public void CleanupPreservesMeaning(string input, string expected) => Assert.Equal(expected, TextProcessing.Cleanup(input));

    [Fact]
    public void VocabularyIsLiteralLongestFirstAndDoesNotCascade()
    {
        VocabularyRule[] rules = [new("lee", "Lee"), new("lee wong", "Michael Wong"), new("Michael Wong", "Wrong"), new("c++", "C++"), new("price", "$5")];
        Assert.Equal("Michael Wong and Lee greeted Leeland. C++ costs $5.", TextProcessing.ApplyVocabulary("lee wong and lee greeted Leeland. c++ costs price.", rules));
    }
    [Fact]
    public void UnicodeBoundariesDoNotReplaceInsideNames() =>
        Assert.Equal("élee Lee leeā", TextProcessing.ApplyVocabulary("élee lee leeā", [new("lee", "Lee")]));
    [Fact]
    public void DuplicateVocabularyIsRejected() => Assert.Throws<InvalidDataException>(() =>
        TextProcessing.ValidateVocabulary([new("one", "1"), new("ONE", "2")]));
    [Theory]
    [InlineData(0, 32, false)] [InlineData(0, 0x41, false)] [InlineData(0, 0x7C, true)]
    [InlineData(3, 32, true)] [InlineData(8, 0x41, false)] [InlineData(3, 0, false)]
    public void ShortcutAvoidsBareTypingKeys(uint modifiers, uint key, bool expected) => Assert.Equal(expected, new Shortcut(modifiers, key).IsValid);
    [Fact]
    public void ExternalCannotConflictWithPrimary() => Assert.Throws<InvalidDataException>(() =>
        new Settings { External = new Shortcut(3, 32, TriggerMode.Toggle) }.Validate());
    [Fact]
    public void UnknownTriggerModeRejected() => Assert.False(new Shortcut(3, 32, (TriggerMode)42).IsValid);
    [Fact]
    public void PersistenceRoundTripAndCorruptionPreservesOriginal()
    {
        var root = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        try
        {
            var store = new JsonStore(root);
            store.Write("settings.json", new Settings());
            Assert.Equal(new Settings(), store.Read("settings.json", () => new Settings()));
            var file = Path.Combine(root, "settings.json");
            File.WriteAllText(file, "broken");
            Assert.Throws<System.Text.Json.JsonException>(() => store.Read("settings.json", () => new Settings()));
            Assert.Equal("broken", File.ReadAllText(file));
        }
        finally { Directory.Delete(root, true); }
    }
    [Fact]
    public void OlderSettingsKeepSoundPreferenceAndGainQuietDefault()
    {
        var settings = System.Text.Json.JsonSerializer.Deserialize<Settings>("{\"Sounds\":false}")!;
        settings.Validate();
        Assert.False(settings.Sounds);
        Assert.Equal(.35, settings.SoundVolume);
        var changed = settings with { SoundVolume = .6 };
        Assert.Equal(changed, System.Text.Json.JsonSerializer.Deserialize<Settings>(System.Text.Json.JsonSerializer.Serialize(changed)));
    }
    [Theory]
    [InlineData(-.1)] [InlineData(1.1)] [InlineData(double.NaN)] [InlineData(double.PositiveInfinity)]
    public void InvalidSoundVolumeRejected(double volume) => Assert.Throws<InvalidDataException>(() =>
        new Settings { SoundVolume = volume }.Validate());
    [Fact]
    public void LongAudioSegmentationKeepsEverySampleAndBoundsMemory()
    {
        var audio = Enumerable.Range(0, 16000 * 80).Select(n => (float)(n % 150) / 150).ToArray();
        var chunks = AudioSegments.Split(audio).ToArray();
        Assert.All(chunks, c => Assert.InRange(c.Length, 1, 25 * 16000));
        Assert.Equal(audio, chunks.SelectMany(c => c));
    }
    [Fact]
    public async Task ModelChecksumRejectsCorruptArchive()
    {
        var file = Path.GetTempFileName();
        try { await File.WriteAllTextAsync(file, "not a model"); await Assert.ThrowsAsync<InvalidDataException>(() => ModelInstaller.ValidateArchiveAsync(file, default)); }
        finally { File.Delete(file); }
    }
}
