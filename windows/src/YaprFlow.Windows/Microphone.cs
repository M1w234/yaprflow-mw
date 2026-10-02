using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using NAudio.CoreAudioApi;

namespace YaprFlow.Windows;

internal sealed class Microphone(Func<string?> device) : IAudioRecorder
{
    private WasapiCapture? capture;
    private MMDevice? endpoint;
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
        lock (sync) samples.Clear();
        stopped = new(TaskCreationOptions.RunContinuationsAsynchronously); captureError = null;
        using var devices = new MMDeviceEnumerator();
        var id = device();
        try
        {
            endpoint = string.IsNullOrEmpty(id) ? devices.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications) : devices.GetDevice(id);
            if (endpoint.State != DeviceState.Active) throw new InvalidOperationException("Selected microphone is disconnected. Choose an available input in Dictation.");
            var input = new WasapiCapture(endpoint);
            var buffer = new BufferedWaveProvider(input.WaveFormat) { ReadFully = false, BufferDuration = TimeSpan.FromSeconds(5) };
            ISampleProvider mono = new MonoInput(buffer.ToSampleProvider());
            var resampled = new WdlResamplingSampleProvider(mono, 16000);
            input.DataAvailable += (_, e) =>
            {
                try
                {
                    buffer.AddSamples(e.Buffer, 0, e.BytesRecorded);
                    var data = new float[4096]; float peak = 0; int count;
                    lock (sync)
                    {
                        while ((count = resampled.Read(data, 0, data.Length)) > 0)
                            for (var i = 0; i < count && samples.Count < 600 * 16000; i++)
                            { samples.Add(data[i]); peak = Math.Max(peak, Math.Abs(data[i])); }
                    }
                    Level?.Invoke(peak);
                }
                catch (Exception ex) { captureError = ex; Fault?.Invoke("Microphone unavailable: " + ex.Message); }
            };
            input.RecordingStopped += (_, e) =>
            {
                captureError ??= e.Exception; stopped.TrySetResult();
                if (e.Exception is not null) Fault?.Invoke("Microphone disconnected or unavailable: " + e.Exception.Message);
            };
            capture = input;
            input.StartRecording();
        }
        catch { capture?.Dispose(); capture = null; endpoint?.Dispose(); endpoint = null; throw; }
        return Task.CompletedTask;
    }
    public float[] Since(int sampleOffset)
    {
        lock (sync) return samples.Skip(sampleOffset).ToArray();
    }
    public float[] Snapshot(int maximumSamples)
    {
        lock (sync) return samples.Skip(Math.Max(0, samples.Count - maximumSamples)).ToArray();
    }
    public async Task<float[]> StopAsync()
    {
        var input = capture;
        if (input is null) return [];
        try
        {
            input.StopRecording(); await stopped!.Task.WaitAsync(TimeSpan.FromSeconds(3));
            if (captureError is not null) throw new IOException("Recording stopped unexpectedly. Check the microphone and retry.", captureError);
            lock (sync) return samples.ToArray();
        }
        finally
        {
            input.Dispose(); capture = null; endpoint?.Dispose(); endpoint = null;
            lock (sync) samples.Clear(); Level?.Invoke(0);
        }
    }
    public static string? LegacyId(int index)
    {
        try
        {
            var oldName = WaveIn.GetCapabilities(index).ProductName;
            var matches = Devices().Where(d => d.Id is not null && d.Name.StartsWith(oldName, StringComparison.OrdinalIgnoreCase)).ToList();
            return matches.Count == 1 ? matches[0].Id : null;
        }
        catch { return null; }
    }
    public static IReadOnlyList<(string? Id, string Name)> Devices()
    {
        var result = new List<(string?, string)> { (null, "Windows default microphone") };
        using var enumerator = new MMDeviceEnumerator();
        foreach (var item in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
        { using (item) result.Add((item.ID, item.FriendlyName)); }
        return result;
    }
    private sealed class MonoInput(ISampleProvider source) : ISampleProvider
    {
        public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(source.WaveFormat.SampleRate, 1);
        private float[] buffer = [];
        public int Read(float[] output, int offset, int count)
        {
            var channels = source.WaveFormat.Channels;
            if (buffer.Length < count * channels) buffer = new float[count * channels];
            var read = source.Read(buffer, 0, count * channels) / channels;
            for (var i = 0; i < read; i++)
            {
                float value = 0;
                for (var c = 0; c < channels; c++) value += buffer[i * channels + c];
                output[offset + i] = value / channels;
            }
            return read;
        }
    }
}
