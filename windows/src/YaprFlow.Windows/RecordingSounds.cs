using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace YaprFlow.Windows;

/// <summary>Original, short cues with app-local gain; never changes the Windows mixer.</summary>
internal sealed class RecordingSounds(string directory) : IDisposable
{
    private Playback? active;
    internal static byte[] Cue(SoundPreset preset, bool starting) => Load(
        preset == SoundPreset.Classic ? (starting ? "start" : "stop")
        : preset.ToString().ToLowerInvariant() + (starting ? "-start" : "-stop"));

    private static byte[] Load(string name)
    {
        using var stream = typeof(RecordingSounds).Assembly.GetManifestResourceStream(
            $"YaprFlow.Windows.Assets.Sounds.{name}.wav")
            ?? throw new InvalidOperationException("Missing recording cue: " + name);
        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        return buffer.ToArray();
    }

    public void Play(bool starting, double volume, SoundPreset preset, string? custom = null)
    {
        active?.Dispose(); active = null;
        if (!double.IsFinite(volume) || volume <= 0) return;
        try
        {
            var data = Cue(preset, starting);
            if (custom is not null && Guid.TryParse(Path.GetFileNameWithoutExtension(custom), out _)
                && Path.GetFileName(custom) == custom && Path.GetExtension(custom) == ".wav")
            {
                var path = Path.Combine(directory, custom);
                if (File.Exists(path) && new FileInfo(path).Length <= 600000) data = File.ReadAllBytes(path);
            }
            active = new Playback(data, (float)Math.Clamp(volume, 0, 1));
        }
        // Feedback is optional: unavailable speakers must never interrupt dictation.
        catch (Exception ex) { System.Diagnostics.Trace.WriteLine("Recording cue unavailable: " + ex.Message); }
    }

    public string Import(string path)
    {
        if (new FileInfo(path).Length > 10 * 1024 * 1024) throw new InvalidDataException("Choose a WAV smaller than 10 MB.");
        using var input = new WaveFileReader(path);
        if (input.TotalTime.TotalSeconds > 3 || input.TotalTime.TotalSeconds <= 0 || input.WaveFormat.Channels > 2)
            throw new InvalidDataException("Choose a mono or stereo WAV up to three seconds long.");
        var source = input.ToSampleProvider();
        if (source.WaveFormat.Channels == 2) source = new StereoToMonoSampleProvider(source);
        source = new WdlResamplingSampleProvider(source, 24000);
        var data = new float[72001]; var count = 0;
        while (count < data.Length)
        {
            var n = source.Read(data, count, data.Length - count);
            if (n == 0) break; count += n;
        }
        if (count == 0 || data.Take(count).Any(x => !float.IsFinite(x))) throw new InvalidDataException("Choose a WAV with valid audio samples.");
        if (count > 72000) throw new InvalidDataException("Choose a sound no longer than three seconds.");
        var peak = data.Take(count).Select(Math.Abs).DefaultIfEmpty(0).Max();
        var gain = peak > .35f ? .35f / peak : 1;
        Directory.CreateDirectory(directory);
        var name = Guid.NewGuid().ToString("N") + ".wav";
        using var writer = new WaveFileWriter(Path.Combine(directory, name), new WaveFormat(24000, 16, 1));
        for (var i = 0; i < count; i++) writer.WriteSample(data[i] * gain);
        return name;
    }
    public void Dispose() { active?.Dispose(); active = null; }

    private sealed class Playback : IDisposable
    {
        private readonly WaveOutEvent output = new() { DesiredLatency = 60 };
        private readonly WaveFileReader reader;
        private int disposed;

        public Playback(byte[] data, float volume)
        {
            reader = new WaveFileReader(new MemoryStream(data, writable: false));
            try
            {
                // Scale samples, not WaveOutEvent.Volume (which controls the device).
                output.Init(new VolumeSampleProvider(reader.ToSampleProvider()) { Volume = volume });
                output.PlaybackStopped += OnStopped;
                output.Play();
            }
            catch { Dispose(); throw; }
        }
        private void OnStopped(object? sender, StoppedEventArgs e) => Dispose();
        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) != 0) return;
            output.PlaybackStopped -= OnStopped;
            output.Dispose(); reader.Dispose();
        }
    }
}
