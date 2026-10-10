using System.Diagnostics;
using System.Text.Json;
using YaprFlow.Speech;

if (args.Length == 2 && args[0] == "--polish")
{
    try
    {
        var model = new YaprFlow.Polish.PolishModel(args[1]);
        if (!model.IsInstalled) await model.DownloadAsync(new Progress<double>(), CancellationToken.None);
        using var polish = new YaprFlow.Polish.LocalPolisher(model);
        var watch = Stopwatch.StartNew();
        const string original = "i has two meeting tomorrow at 10";
        var text = await polish.PolishAsync(original, CancellationToken.None);
        Console.WriteLine(JsonSerializer.Serialize(new { model = "Qwen3-0.6B-Q8_0", original, text, seconds = watch.Elapsed.TotalSeconds }));
        return 0;
    }
    catch (Exception ex) { Console.Error.WriteLine(ex); return 1; }
}

// This tool is deliberately separate from the tray executable. It verifies the
// production model installer and recognizer without microphone/UI permissions.
if (args.Length is < 2 or > 4)
{
    Console.Error.WriteLine("Usage: YaprFlow.Smoke <model-directory> <16kHz-mono-PCM16.wav> [--install | --archive <verified-download.tar.bz2>]");
    return 2;
}
try
{
    var installer = new ModelInstaller(Path.GetFullPath(args[0]));
    if (args.Contains("--install") || args.Contains("--archive"))
    {
        var last = -1;
        await installer.InstallAsync(new Progress<DownloadProgress>(p =>
        {
            var bucket = (int)(p.Fraction * 10);
            if (bucket != last) { last = bucket; Console.Error.WriteLine(p.Message); }
        }), CancellationToken.None, args.Length == 4 && args[2] == "--archive" ? args[3] : null);
    }
    using var file = new BinaryReader(File.OpenRead(args[1]));
    if (new string(file.ReadChars(4)) != "RIFF") throw new InvalidDataException("Expected RIFF WAV.");
    file.ReadUInt32();
    if (new string(file.ReadChars(4)) != "WAVE") throw new InvalidDataException("Expected WAVE.");
    float[]? samples = null;
    var formatOk = false;
    while (file.BaseStream.Position + 8 <= file.BaseStream.Length)
    {
        var id = new string(file.ReadChars(4)); var size = file.ReadUInt32(); var start = file.BaseStream.Position;
        if (id == "fmt ")
        {
            var format = file.ReadUInt16(); var channels = file.ReadUInt16(); var rate = file.ReadUInt32();
            file.ReadUInt32(); file.ReadUInt16(); var bits = file.ReadUInt16();
            formatOk = format == 1 && channels == 1 && rate == 16000 && bits == 16;
        }
        if (id == "data")
        {
            if (!formatOk || size > 600 * 16000 * 2) throw new InvalidDataException("Use mono 16 kHz PCM16, up to 10 minutes.");
            samples = new float[size / 2];
            for (var i = 0; i < samples.Length; i++) samples[i] = file.ReadInt16() / 32768f;
        }
        file.BaseStream.Position = start + size + size % 2;
    }
    if (samples is null) throw new InvalidDataException("No WAV data found.");
    using var recognizer = new ParakeetRecognizer(installer);
    var watch = Stopwatch.StartNew();
    await recognizer.PrepareAsync(CancellationToken.None);
    var preparation = watch.Elapsed.TotalSeconds; watch.Restart();
    var text = await recognizer.TranscribeAsync(samples, CancellationToken.None);
    var decode = watch.Elapsed.TotalSeconds;
    Console.WriteLine(JsonSerializer.Serialize(new { model = ModelCatalog.Id, runtime = System.Runtime.InteropServices.RuntimeInformation.RuntimeIdentifier,
        audioSeconds = samples.Length / 16000.0, preparationSeconds = preparation, decodeSeconds = decode, text }, new JsonSerializerOptions { WriteIndented = true }));
    return string.IsNullOrWhiteSpace(text) ? 1 : 0;
}
catch (Exception ex) { Console.Error.WriteLine(ex.ToString()); return 1; }
