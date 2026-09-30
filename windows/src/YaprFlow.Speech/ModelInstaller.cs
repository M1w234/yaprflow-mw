using System.Formats.Tar;
using System.Security.Cryptography;
using SharpCompress.Compressors;
using SharpCompress.Compressors.BZip2;

namespace YaprFlow.Speech;

public sealed record DownloadProgress(string Message, double Fraction);

public sealed class ModelInstaller(string modelDirectory)
{
    public string ModelDirectory { get; } = modelDirectory;
    public bool IsInstalled => ModelCatalog.RequiredFiles.All(f => File.Exists(Path.Combine(ModelDirectory, f))) &&
        File.Exists(Path.Combine(ModelDirectory, "verified.sha256"));

    public async Task VerifyAsync(CancellationToken token)
    {
        if (!IsInstalled) throw new InvalidOperationException("Download the speech model in Settings first.");
        foreach (var name in ModelCatalog.RequiredFiles)
        {
            await using var stream = File.OpenRead(Path.Combine(ModelDirectory, name));
            var hash = Convert.ToHexString(await SHA256.HashDataAsync(stream, token)).ToLowerInvariant();
            if (ModelCatalog.FileHashes[name] != hash) throw new InvalidDataException("Speech model is damaged. Download it again in Settings.");
        }
    }

    public async Task InstallAsync(IProgress<DownloadProgress>? progress, CancellationToken token, string? existingArchive = null)
    {
        var parent = Path.GetDirectoryName(ModelDirectory)!;
        Directory.CreateDirectory(parent);
        var staging = Path.Combine(parent, ".download-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staging);
        var archive = Path.Combine(staging, "model.tar.bz2");
        var extracted = Path.Combine(staging, "extracted");
        Directory.CreateDirectory(extracted);
        try
        {
            if (existingArchive is not null)
            {
                await using var input = File.OpenRead(existingArchive);
                await using var output = File.Create(archive);
                await input.CopyToAsync(output, token);
            }
            else
            {
            using var client = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
            client.DefaultRequestHeaders.UserAgent.ParseAdd("yaprflow-windows/0.1");
            using var response = await client.GetAsync(ModelCatalog.Url, HttpCompletionOption.ResponseHeadersRead, token);
            response.EnsureSuccessStatusCode();
            await using (var source = await response.Content.ReadAsStreamAsync(token))
            await using (var dest = File.Create(archive))
            {
                var buffer = new byte[131072];
                long total = 0;
                int count;
                while ((count = await source.ReadAsync(buffer, token)) != 0)
                {
                    total += count;
                    if (total > ModelCatalog.ArchiveBytes) throw new InvalidDataException("Unexpected model download size.");
                    await dest.WriteAsync(buffer.AsMemory(0, count), token);
                    progress?.Report(new($"Downloading speech model · {total / 1048576} / 460 MB", (double)total / ModelCatalog.ArchiveBytes * .85));
                }
                if (total != ModelCatalog.ArchiveBytes) throw new InvalidDataException("The download was incomplete. Please retry.");
            }
            }
            progress?.Report(new("Verifying download…", .86));
            await ValidateArchiveAsync(archive, token);
            progress?.Report(new("Installing speech model…", .9));
            await Task.Run(async () =>
            {
                using var compressed = File.OpenRead(archive);
                using var bzip = BZip2Stream.Create(compressed, CompressionMode.Decompress, false);
                using var tar = new TarReader(bzip);
                var found = new HashSet<string>(StringComparer.Ordinal);
                while (await tar.GetNextEntryAsync(cancellationToken: token) is { } entry)
                {
                    var name = Path.GetFileName(entry.Name);
                    if (!ModelCatalog.RequiredFiles.Contains(name)) continue;
                    if (entry.EntryType != TarEntryType.RegularFile && entry.EntryType != TarEntryType.V7RegularFile)
                        throw new InvalidDataException("Model archive contains an unexpected entry.");
                    if (!found.Add(name) || entry.Length > 800_000_000 || entry.DataStream is null)
                        throw new InvalidDataException("Invalid model archive.");
                    // Only fixed, allowlisted basenames are written; no archive paths or links.
                    await using var output = File.Create(Path.Combine(extracted, name));
                    await entry.DataStream.CopyToAsync(output, token);
                }
                if (found.Count != ModelCatalog.RequiredFiles.Length) throw new InvalidDataException("Model archive is missing files.");
                var hashes = new List<string>();
                foreach (var name in ModelCatalog.RequiredFiles)
                {
                    await using var stream = File.OpenRead(Path.Combine(extracted, name));
                    hashes.Add(Convert.ToHexString(await SHA256.HashDataAsync(stream, token)).ToLowerInvariant() + "  " + name);
                }
                await File.WriteAllLinesAsync(Path.Combine(extracted, "verified.sha256"), hashes, token);
            }, token);
            token.ThrowIfCancellationRequested();
            // Stage completely before promotion. Keep an old installation recoverable on failure.
            var backup = ModelDirectory + ".previous";
            if (Directory.Exists(backup)) Directory.Delete(backup, true);
            if (Directory.Exists(ModelDirectory)) Directory.Move(ModelDirectory, backup);
            try { Directory.Move(extracted, ModelDirectory); }
            catch { if (Directory.Exists(backup)) Directory.Move(backup, ModelDirectory); throw; }
            if (Directory.Exists(backup)) Directory.Delete(backup, true);
            progress?.Report(new("Speech model ready · offline dictation enabled", 1));
        }
        finally { if (Directory.Exists(staging)) Directory.Delete(staging, true); }
    }

    public static async Task ValidateArchiveAsync(string path, CancellationToken token)
    {
        await using var file = File.OpenRead(path);
        var hash = Convert.ToHexString(await SHA256.HashDataAsync(file, token));
        if (!hash.Equals(ModelCatalog.ArchiveSha256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Speech model checksum mismatch. The download was not installed.");
    }
}
