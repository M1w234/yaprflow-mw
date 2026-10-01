namespace YaprFlow.Core;

public enum SessionPhase { Idle, Preparing, Listening, Transcribing, Canceling }
public interface IAudioRecorder
{
    Task StartAsync(CancellationToken token);
    Task<float[]> StopAsync();
}
public interface ISpeechRecognizer
{
    Task PrepareAsync(CancellationToken token);
    Task<string> TranscribeAsync(float[] samples, CancellationToken token);
}
public interface ITextDelivery
{
    Task<object?> CaptureTargetAsync();
    Task<string> DeliverAsync(string text, object? target, CancellationToken token);
}

/// All entry points and event callbacks run on the owning UI synchronization context.
/// Native recognition may not be interruptible; keep the session busy until it ends,
/// discard its result on cancellation, and never overlap native recognizer use.
public sealed class DictationSession(IAudioRecorder audio, ISpeechRecognizer speech, ITextDelivery delivery,
    Func<Settings> settings, Func<IReadOnlyList<VocabularyRule>> vocabulary)
{
    public SessionPhase Phase { get; private set; }
    public string Status { get; private set; } = "Ready";
    public bool IsBusy => Phase != SessionPhase.Idle;
    public event Action? Changed;
    public event Action<HistoryEntry>? Completed;
    private CancellationTokenSource? cancellation;
    private bool finishRequested;
    private bool recording;
    private Task? startTask;
    private Task? finishTask;
    private object? target;
    private Settings snapshot = new();

    public Task StartAsync()
    {
        if (IsBusy) return Task.CompletedTask;
        cancellation?.Dispose();
        cancellation = new CancellationTokenSource();
        finishRequested = false;
        snapshot = settings();
        Set(SessionPhase.Preparing, "Preparing microphone…");
        return startTask = StartCoreAsync(cancellation.Token);
    }
    private async Task StartCoreAsync(CancellationToken token)
    {
        try
        {
            // Capture before the overlay is shown by Listening; never retarget at delivery.
            target = await delivery.CaptureTargetAsync();
            await speech.PrepareAsync(token);
            token.ThrowIfCancellationRequested();
            if (finishRequested) { Set(SessionPhase.Idle, "Released before recording started — try again"); return; }
            await audio.StartAsync(token);
            recording = true;
            token.ThrowIfCancellationRequested();
            if (finishRequested) { await FinishCoreAsync(token); return; }
            Set(SessionPhase.Listening, "Listening…");
        }
        catch (OperationCanceledException) { await DiscardAudioAsync(); Set(SessionPhase.Idle, "Canceled"); }
        catch (Exception ex) { await DiscardAudioAsync(); Set(SessionPhase.Idle, "Could not start: " + ex.Message); }
    }
    public Task FinishAsync()
    {
        if (Phase == SessionPhase.Preparing) { finishRequested = true; return startTask ?? Task.CompletedTask; }
        if (Phase != SessionPhase.Listening) return finishTask ?? Task.CompletedTask;
        return finishTask = FinishCoreAsync(cancellation!.Token);
    }
    private async Task FinishCoreAsync(CancellationToken token)
    {
        Set(SessionPhase.Transcribing, "Transcribing on this PC…");
        try
        {
            var samples = await audio.StopAsync();
            recording = false;
            token.ThrowIfCancellationRequested();
            if (samples.Length < 1600 || !samples.Any(s => Math.Abs(s) > 0.005f))
            { Set(SessionPhase.Idle, "No speech captured — check your microphone"); return; }
            var raw = await speech.TranscribeAsync(samples, token);
            token.ThrowIfCancellationRequested();
            var text = TextProcessing.ApplyVocabulary(raw, vocabulary());
            if (snapshot.LightCleanup) text = TextProcessing.Cleanup(text);
            if (string.IsNullOrWhiteSpace(text)) { Set(SessionPhase.Idle, "No speech recognized"); return; }
            string result;
            try
            {
                result = snapshot.AutomaticInsertion
                    ? await delivery.DeliverAsync(text, target, token)
                    : "Automatic insertion is off";
            }
            catch (OperationCanceledException) { throw; }
            catch { result = "Not inserted — delivery failed; copy from History"; }
            token.ThrowIfCancellationRequested();
            Completed?.Invoke(new HistoryEntry(Guid.NewGuid(), DateTimeOffset.Now, text, result));
            Set(SessionPhase.Idle, result);
        }
        catch (OperationCanceledException) { await DiscardAudioAsync(); Set(SessionPhase.Idle, "Canceled"); }
        catch (Exception ex) { await DiscardAudioAsync(); Set(SessionPhase.Idle, "Dictation failed: " + ex.Message); }
    }
    public async Task CancelAsync()
    {
        if (!IsBusy) return;
        cancellation?.Cancel();
        if (Phase == SessionPhase.Listening)
        {
            Set(SessionPhase.Canceling, "Canceling…");
            await DiscardAudioAsync();
            Set(SessionPhase.Idle, "Canceled");
        }
        else Set(SessionPhase.Canceling, "Canceling — waiting for local processing to finish…");
    }
    private async Task DiscardAudioAsync()
    {
        if (!recording) return;
        try { await audio.StopAsync(); } catch { /* Original failure is the useful error. */ }
        recording = false;
    }
    private void Set(SessionPhase phase, string status) { Phase = phase; Status = status; Changed?.Invoke(); }
}
