namespace YaprFlow.Core;

public enum SessionPhase { Idle, Preparing, Listening, Transcribing, Canceling }
public interface IAudioRecorder
{
    Task StartAsync(CancellationToken token);
    Task<float[]> StopAsync();
    float[] Snapshot(int maximumSamples) => [];
    float[] Since(int sampleOffset) => [];
}
public interface ISpeechRecognizer
{
    Task PrepareAsync(CancellationToken token);
    Task<string> TranscribeAsync(float[] samples, CancellationToken token);
}
public interface ITextDelivery
{
    bool CanStreamNow => true;
    Task<object?> CaptureTargetAsync();
    Task<string> DeliverAsync(string text, object? target, CancellationToken token);
}

/// All entry points and event callbacks run on the owning UI synchronization context.
/// Native recognition may not be interruptible; keep the session busy until it ends,
/// discard its result on cancellation, and never overlap native recognizer use.
public sealed class DictationSession(IAudioRecorder audio, ISpeechRecognizer speech, ITextDelivery delivery,
    Func<Settings> settings, Func<IReadOnlyList<VocabularyRule>> vocabulary, TimeSpan? previewInterval = null, ITextPolisher? polisher = null)
{
    public SessionPhase Phase { get; private set; }
    public string Status { get; private set; } = "Ready";
    public string PreviewText { get; private set; } = "";
    public event Action? PreviewChanged;
    private CancellationTokenSource? previewCancellation;
    private Task previewTask = Task.CompletedTask;
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
    private readonly List<string> originals = [];
    private string polishNotice = "";
    private readonly List<string> phrases = [];
    private readonly List<string> pending = [];
    private int processedSamples;
    private bool streamedAny;
    private bool insertionBlocked;
    private string insertionStatus = "";

    public Task StartAsync()
    {
        if (IsBusy) return Task.CompletedTask;
        cancellation?.Dispose();
        cancellation = new CancellationTokenSource();
        finishRequested = false; finishTask = null;
        originals.Clear(); polishNotice = ""; phrases.Clear(); pending.Clear(); processedSamples = 0; streamedAny = false;
        insertionBlocked = false; insertionStatus = "";
        PreviewText = ""; PreviewChanged?.Invoke();
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
            if (snapshot.StreamingPreview || snapshot.StreamingInsertion)
            {
                previewCancellation = CancellationTokenSource.CreateLinkedTokenSource(token);
                previewTask = PreviewLoopAsync(previewCancellation.Token);
            }
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
            var stop = audio.StopAsync();
            recording = false;
            await StopPreviewAsync();
            var samples = await stop;
            token.ThrowIfCancellationRequested();
            samples = samples.Skip(processedSamples).ToArray();
            if (phrases.Count == 0 && (samples.Length < 1600 || !samples.Any(s => Math.Abs(s) > 0.005f)))
            { Set(SessionPhase.Idle, "No speech captured — check your microphone"); return; }
            if (samples.Length >= 1600 && samples.Any(x => Math.Abs(x) > .005f))
            {
                var raw = await speech.TranscribeAsync(samples, token);
                token.ThrowIfCancellationRequested();
                await AddPhraseAsync(raw, token);
            }
            var text = string.Join(" ", phrases);
            if (string.IsNullOrWhiteSpace(text)) { Set(SessionPhase.Idle, "No speech recognized"); return; }
            string result = "Automatic insertion is off";
            if (snapshot.AutomaticInsertion)
            {
                if (!insertionBlocked && pending.Count > 0) await FlushPendingAsync(token, final: true);
                result = insertionBlocked ? (streamedAny ? "Partially inserted — remaining text is in History. " : "") + insertionStatus
                    : streamedAny ? "Text sent to the original field" : insertionStatus;
            }
            token.ThrowIfCancellationRequested();
            Completed?.Invoke(new HistoryEntry(Guid.NewGuid(), DateTimeOffset.Now, text, result + polishNotice, snapshot.AIPolish ? string.Join(" ", originals) : null));
            Set(SessionPhase.Idle, result + polishNotice);
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
            await StopPreviewAsync();
            await DiscardAudioAsync();
            Set(SessionPhase.Idle, "Canceled");
        }
        else Set(SessionPhase.Canceling, "Canceling — waiting for local processing to finish…");
    }
    private async Task PreviewLoopAsync(CancellationToken token)
    {
        try
        {
            while (true)
            {
                await Task.Delay(previewInterval ?? TimeSpan.FromMilliseconds(1800), token);
                if (snapshot.StreamingInsertion && pending.Count > 0 && delivery.CanStreamNow)
                    await FlushPendingAsync(token, final: false);
                var samples = audio.Since(processedSamples);
                if (samples.Length < 16000 || !samples.Any(x => Math.Abs(x) > .005f)) continue;
                // Finalize only after a quiet boundary. Long uninterrupted speech
                // remains a revisable draft and is recognized fully at release.
                var quiet = samples.Length >= 11200 && Math.Sqrt(samples[^11200..].Average(x => (double)x * x)) < .006;
                var previewSamples = quiet ? samples : samples.TakeLast(20 * 16000).ToArray();
                var text = await speech.TranscribeAsync(previewSamples, token);
                token.ThrowIfCancellationRequested();
                if (Phase != SessionPhase.Listening) return;
                if (quiet)
                {
                    await AddPhraseAsync(text, token);
                    processedSamples += samples.Length;
                    if (snapshot.StreamingInsertion && delivery.CanStreamNow) await FlushPendingAsync(token, final: false);
                }
                PreviewText = snapshot.StreamingPreview ? TextProcessing.ApplyVocabulary(text, vocabulary()) : "";
                if (snapshot.StreamingInsertion && pending.Count > 0 && !delivery.CanStreamNow)
                    Set(SessionPhase.Listening, "Listening · release modifier keys to insert text");
                else Set(SessionPhase.Listening, "Listening…");
                PreviewChanged?.Invoke();
            }
        }
        catch (OperationCanceledException) { }
        catch { /* Live preview is optional; final recognition remains available. */ }
    }
    private async Task AddPhraseAsync(string raw, CancellationToken token)
    {
        var text = TextProcessing.ApplyVocabulary(raw.Trim(), vocabulary());
        if (snapshot.LightCleanup) text = TextProcessing.Cleanup(text);
        if (string.IsNullOrWhiteSpace(text)) return;
        originals.Add(text);
        if (snapshot.AIPolish && polisher is not null)
        {
            try { text = TextProcessing.ApplyVocabulary(await polisher.PolishAsync(text, token), vocabulary()); }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { originals.RemoveAt(originals.Count - 1); throw; }
            catch { polishNotice = " · AI Polish unavailable for some text; original kept"; }
        }
        token.ThrowIfCancellationRequested();
        phrases.Add(text); pending.Add(text);
    }
    private async Task FlushPendingAsync(CancellationToken token, bool final)
    {
        if (!snapshot.AutomaticInsertion || insertionBlocked || pending.Count == 0) return;
        try
        {
            var result = await delivery.DeliverAsync(string.Join(" ", pending) + (final ? "" : " "), target, token);
            if (result.StartsWith("Text sent", StringComparison.Ordinal)) { pending.Clear(); streamedAny = true; }
            else { insertionBlocked = true; insertionStatus = result; }
        }
        catch (OperationCanceledException) { throw; }
        catch { insertionBlocked = true; insertionStatus = "Not inserted — delivery failed; copy from History"; }
    }
    private async Task StopPreviewAsync()
    {
        previewCancellation?.Cancel();
        await previewTask;
        previewCancellation?.Dispose(); previewCancellation = null;
    }
    private async Task DiscardAudioAsync()
    {
        if (!recording) return;
        try { await audio.StopAsync(); } catch { /* Original failure is the useful error. */ }
        recording = false;
    }
    private void Set(SessionPhase phase, string status) { Phase = phase; Status = status; Changed?.Invoke(); }
}
