using System.Security.Cryptography;
namespace YaprFlow.Polish;

public sealed class PolishModel(string directory)
{
    public const long Bytes = 639446688;
    public const string Sha256 = "9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031";
    public const string Url = "https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/23749fefcc72300e3a2ad315e1317431b06b590a/Qwen3-0.6B-Q8_0.gguf";
    public string Path { get; } = System.IO.Path.Combine(directory, "Qwen3-0.6B-Q8_0.gguf");
    public bool IsInstalled => File.Exists(Path) && new FileInfo(Path).Length == Bytes;
    public async Task VerifyAsync(CancellationToken token)
    {
        await using var file = File.OpenRead(Path);
        if (file.Length != Bytes || !Convert.ToHexString(await SHA256.HashDataAsync(file, token)).Equals(Sha256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("AI Polish model is damaged. Download it again.");
    }
    public async Task DownloadAsync(IProgress<double> progress, CancellationToken token)
    {
        Directory.CreateDirectory(directory);
        var temporary = Path + "." + Guid.NewGuid().ToString("N") + ".download";
        try
        {
            using var client = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
            using var response = await client.GetAsync(Url, HttpCompletionOption.ResponseHeadersRead, token);
            response.EnsureSuccessStatusCode();
            await using (var input = await response.Content.ReadAsStreamAsync(token))
            await using (var output = File.Create(temporary))
            {
                var buffer = new byte[131072]; long total = 0; int count;
                while ((count = await input.ReadAsync(buffer, token)) > 0)
                {
                    total += count; if (total > Bytes) throw new InvalidDataException("Unexpected model size.");
                    await output.WriteAsync(buffer.AsMemory(0, count), token); progress.Report((double)total / Bytes);
                }
                if (total != Bytes) throw new InvalidDataException("Incomplete download.");
            }
            await using (var file = File.OpenRead(temporary))
                if (!Convert.ToHexString(await SHA256.HashDataAsync(file, token)).Equals(Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("AI Polish checksum mismatch. Download was not installed.");
            token.ThrowIfCancellationRequested(); File.Move(temporary, Path, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
