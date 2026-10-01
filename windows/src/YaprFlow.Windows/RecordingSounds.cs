using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace YaprFlow.Windows;

/// <summary>Original, short cues with app-local gain; never changes the Windows mixer.</summary>
internal sealed class RecordingSounds : IDisposable
{
    private Playback? active;
    private static readonly byte[] start = Load("start");
    private static readonly byte[] stop = Load("stop");

    private static byte[] Load(string name)
    {
        using var stream = typeof(RecordingSounds).Assembly.GetManifestResourceStream(
            $"YaprFlow.Windows.Assets.Sounds.{name}.wav")
            ?? throw new InvalidOperationException("Missing recording cue: " + name);
        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        return buffer.ToArray();
    }

    public void Play(bool starting, double volume)
    {
        active?.Dispose(); active = null;
        if (!double.IsFinite(volume) || volume <= 0) return;
        try { active = new Playback(starting ? start : stop, (float)Math.Clamp(volume, 0, 1)); }
        // Feedback is optional: unavailable speakers must never interrupt dictation.
        catch (Exception ex) { System.Diagnostics.Trace.WriteLine("Recording cue unavailable: " + ex.Message); }
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
