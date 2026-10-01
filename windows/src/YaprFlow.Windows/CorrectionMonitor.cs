namespace YaprFlow.Windows;

/// Optional, bounded observation of the exact field we just inserted into.
/// Field contents remain transient; only a reviewed replacement is ever saved.
internal sealed class CorrectionMonitor(TextDelivery delivery) : IDisposable
{
    private CancellationTokenSource? cancellation;
    public event Action<VocabularyRule>? Suggested;
    public void Stop() { cancellation?.Cancel(); cancellation?.Dispose(); cancellation = null; }
    public void Begin(string inserted)
    {
        Stop();
        if (delivery.LastTarget is not { } target) return;
        cancellation = new(); _ = WatchAsync(target, inserted, cancellation.Token);
    }
    private async Task WatchAsync(Target target, string inserted, CancellationToken token)
    {
        try
        {
            await Task.Delay(250, token);
            var baseline = await delivery.ReadFieldAsync(target); token.ThrowIfCancellationRequested();
            if (baseline is null || CorrectionInference.EditedSpan(baseline, inserted, baseline) is null) return;
            string? previous = null; int stable = 0;
            for (var i = 0; i < 20; i++)
            {
                await Task.Delay(1000, token);
                var value = await delivery.ReadFieldAsync(target); token.ThrowIfCancellationRequested();
                if (value is null) return;
                var edited = CorrectionInference.EditedSpan(baseline, inserted, value);
                if (edited is null) return;
                if (edited == previous) stable++; else { previous = edited; stable = 0; }
                if (stable >= 1 && CorrectionInference.Infer(inserted, edited) is { } rule)
                { Suggested?.Invoke(rule); return; }
            }
        }
        catch (OperationCanceledException) { }
        catch { /* Unsupported or changing fields simply produce no suggestion. */ }
    }
    public void Dispose() => Stop();
}
