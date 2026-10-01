using NAudio.Wave;

namespace YaprFlow.Windows;

internal sealed class Microphone(Func<int> device) : IAudioRecorder
{
    private WaveInEvent? capture;
    private readonly object sync = new();
    private readonly List<float> samples = [];
    private TaskCompletionSource? stopped;
    private Exception? captureError;
    public event Action<float>? Level;
    public event Action<string>? Fault;
    public Task StartAsync(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (capture is not null) throw new InvalidOperationException("Microphone is already recording.");
        if (WaveIn.DeviceCount == 0) throw new InvalidOperationException("No microphone found. Connect one and check Windows microphone privacy settings.");
        lock (sync) samples.Clear();
        stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
        captureError = null;
        var input = new WaveInEvent
        {
            DeviceNumber = device(), WaveFormat = new WaveFormat(16000, 16, 1), BufferMilliseconds = 50
        };
        input.DataAvailable += (_, e) =>
        {
            float peak = 0;
            lock (sync)
            {
                // Hard bound even if a UI timer stalls: ten minutes at 16 kHz.
                for (var i = 0; i + 1 < e.BytesRecorded && samples.Count < 600 * 16000; i += 2)
                {
                    var sample = (short)(e.Buffer[i] | e.Buffer[i + 1] << 8) / 32768f;
                    samples.Add(sample);
                    peak = Math.Max(peak, Math.Abs(sample));
                }
            }
            Level?.Invoke(peak);
        };
        input.RecordingStopped += (_, e) =>
        {
            captureError = e.Exception;
            stopped.TrySetResult();
            if (e.Exception is not null) Fault?.Invoke("Microphone disconnected or unavailable: " + e.Exception.Message);
        };
        capture = input;
        try { input.StartRecording(); }
        catch { capture = null; input.Dispose(); throw; }
        return Task.CompletedTask;
    }
    public async Task<float[]> StopAsync()
    {
        var input = capture;
        if (input is null) return [];
        try
        {
            input.StopRecording();
            await stopped!.Task.WaitAsync(TimeSpan.FromSeconds(3));
            if (captureError is not null) throw new IOException("Recording stopped unexpectedly. Check the microphone and retry.", captureError);
            lock (sync) return samples.ToArray();
        }
        finally
        {
            input.Dispose(); capture = null;
            lock (sync) samples.Clear();
            Level?.Invoke(0);
        }
    }
    public static IReadOnlyList<(int Id, string Name)> Devices()
    {
        var result = new List<(int, string)> { (-1, "Windows default microphone") };
        for (var i = 0; i < WaveIn.DeviceCount; i++) result.Add((i, WaveIn.GetCapabilities(i).ProductName));
        return result;
    }
}
