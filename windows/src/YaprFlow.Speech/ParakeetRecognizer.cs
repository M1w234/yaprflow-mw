using SherpaOnnx;
using YaprFlow.Core;

namespace YaprFlow.Speech;

public sealed class ParakeetRecognizer(ModelInstaller installer) : ISpeechRecognizer, IDisposable
{
    private OfflineRecognizer? recognizer;
    private readonly SemaphoreSlim gate = new(1, 1);
    public async Task PrepareAsync(CancellationToken token)
    {
        await gate.WaitAsync(token);
        try
        {
            if (recognizer is not null) return;
            await installer.VerifyAsync(token);
            var loaded = await Task.Run(() =>
            {
                var config = new OfflineRecognizerConfig();
                config.FeatConfig.SampleRate = 16000;
                config.FeatConfig.FeatureDim = 80;
                config.ModelConfig.Transducer.Encoder = Path.Combine(installer.ModelDirectory, "encoder.int8.onnx");
                config.ModelConfig.Transducer.Decoder = Path.Combine(installer.ModelDirectory, "decoder.int8.onnx");
                config.ModelConfig.Transducer.Joiner = Path.Combine(installer.ModelDirectory, "joiner.int8.onnx");
                config.ModelConfig.Tokens = Path.Combine(installer.ModelDirectory, "tokens.txt");
                config.ModelConfig.ModelType = "nemo_transducer";
                config.ModelConfig.Provider = "cpu";
                config.ModelConfig.NumThreads = Math.Clamp(Environment.ProcessorCount / 2, 1, 4);
                return new OfflineRecognizer(config);
            }, token);
            recognizer = loaded;
            token.ThrowIfCancellationRequested();
        }
        finally { gate.Release(); }
    }

    public async Task<string> TranscribeAsync(float[] samples, CancellationToken token)
    {
        await PrepareAsync(token);
        await gate.WaitAsync(token);
        try
        {
            return await Task.Run(() =>
            {
                var parts = new List<string>();
                // Bound attention/memory on long recordings. Prefer a low-energy
                // boundary in the last 5 seconds of each 25-second chunk.
                foreach (var chunk in AudioSegments.Split(samples))
                {
                    token.ThrowIfCancellationRequested();
                    using var stream = recognizer!.CreateStream();
                    stream.AcceptWaveform(16000, chunk);
                    recognizer.Decode(stream);
                    token.ThrowIfCancellationRequested();
                    var text = stream.Result.Text.Trim();
                    if (text.Length > 0) parts.Add(text);
                }
                return string.Join(" ", parts);
            }, token);
        }
        finally { gate.Release(); }
    }
    public void Dispose() { recognizer?.Dispose(); gate.Dispose(); }
}

public static class AudioSegments
{
    public static IEnumerable<float[]> Split(float[] samples)
    {
        const int max = 25 * 16000;
        var start = 0;
        while (start < samples.Length)
        {
            var end = Math.Min(samples.Length, start + max);
            if (end < samples.Length)
            {
                var limit = Math.Min(samples.Length, start + max);
                var bestEnergy = double.MaxValue;
                for (var candidate = limit - 5 * 16000; candidate < limit; candidate += 1600)
                {
                    double energy = 0;
                    for (var i = candidate; i < candidate + 1600; i++) energy += samples[i] * samples[i];
                    if (energy < bestEnergy) { bestEnergy = energy; end = candidate + 800; }
                }
            }
            yield return samples[start..end];
            start = end;
        }
    }
}
