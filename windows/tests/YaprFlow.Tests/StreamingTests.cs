using Xunit;
using YaprFlow.Core;
namespace YaprFlow.Tests;
public class StreamingTests
{
    private sealed class Audio : IAudioRecorder
    {
        public float[] Samples = [.. Enumerable.Repeat(.1f, 16000), .. new float[12000]];
        public Task StartAsync(CancellationToken t) => Task.CompletedTask;
        public Task<float[]> StopAsync() => Task.FromResult(Samples);
        public float[] Since(int offset) => Samples.Skip(offset).ToArray();
    }
    private sealed class Speech : ISpeechRecognizer
    {
        public int Calls;
        public TaskCompletionSource? Gate;
        public TaskCompletionSource Entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task PrepareAsync(CancellationToken t) => Task.CompletedTask;
        public async Task<string> TranscribeAsync(float[] s, CancellationToken t)
        { Calls++; Entered.TrySetResult(); if (Gate is not null) await Gate.Task; return "Hello world."; }
    }
    private sealed class Delivery : ITextDelivery
    {
        public bool CanStreamNow { get; set; } = true;
        public string Result = "Text sent";
        public List<string> Texts = [];
        public TaskCompletionSource Sent = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task<object?> CaptureTargetAsync() => Task.FromResult<object?>(this);
        public Task<string> DeliverAsync(string s, object? target, CancellationToken t)
        { t.ThrowIfCancellationRequested(); Assert.Same(this, target); Texts.Add(s); Sent.TrySetResult(); return Task.FromResult(Result); }
    }
    private static DictationSession Create(Audio a, Speech s, Delivery d, Settings? settings = null, ITextPolisher? p = null) =>
        new(a, s, d, () => settings ?? new(), () => [], TimeSpan.FromMilliseconds(15), p);
    [Fact] public async Task CommittedPhraseIsInsertedBeforeFinishAndNeverDuplicated()
    {
        var a = new Audio(); var s = new Speech(); var d = new Delivery(); var session = Create(a,s,d);
        HistoryEntry? saved = null; session.Completed += e => saved = e;
        await session.StartAsync(); await d.Sent.Task.WaitAsync(TimeSpan.FromSeconds(3));
        Assert.Equal(SessionPhase.Listening, session.Phase); await session.FinishAsync();
        Assert.Single(d.Texts); Assert.Equal("Hello world. ", d.Texts[0]); Assert.Equal("Hello world.", saved?.Text); Assert.Equal(1, s.Calls);
    }
    [Fact] public async Task HeldModifiersQueueStreamingTextUntilFinalRelease()
    {
        var a = new Audio(); var s = new Speech(); var d = new Delivery { CanStreamNow = false }; var session = Create(a,s,d);
        var preview = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        session.PreviewChanged += () => { if (session.PreviewText.Length > 0) preview.TrySetResult(); };
        await session.StartAsync(); await preview.Task.WaitAsync(TimeSpan.FromSeconds(3)); Assert.Empty(d.Texts);
        d.CanStreamNow = true; await session.FinishAsync(); Assert.Single(d.Texts); Assert.Equal("Hello world.", d.Texts[0]);
    }
    [Fact] public async Task FieldChangeBlocksEveryLaterAutomaticInsertion()
    {
        var a = new Audio(); var s = new Speech(); var d = new Delivery { Result = "Not inserted — field changed" }; var session = Create(a,s,d);
        HistoryEntry? saved = null; session.Completed += e => saved = e;
        await session.StartAsync(); await d.Sent.Task.WaitAsync(TimeSpan.FromSeconds(3));
        a.Samples = [.. a.Samples, .. Enumerable.Repeat(.1f, 4000)]; await session.FinishAsync();
        Assert.Single(d.Texts); Assert.Equal("Hello world. Hello world.", saved?.Text); Assert.Contains("field changed", saved?.Delivery);
    }
    [Fact] public async Task CancelDuringPreviewWaitsForNativeWorkAndDiscardsItsResult()
    {
        var a = new Audio(); var s = new Speech { Gate = new() }; var d = new Delivery(); var session = Create(a,s,d);
        await session.StartAsync(); await s.Entered.Task.WaitAsync(TimeSpan.FromSeconds(3));
        var cancel = session.CancelAsync(); await session.StartAsync(); Assert.True(session.IsBusy);
        s.Gate.SetResult(); await cancel; Assert.Empty(d.Texts); Assert.False(session.IsBusy);
    }
    [Fact] public async Task FinishDuringPreviewKeepsAllAudioWithoutOverlappingRecognition()
    {
        var a = new Audio(); var s = new Speech { Gate = new() }; var d = new Delivery(); var session = Create(a,s,d);
        await session.StartAsync(); await s.Entered.Task.WaitAsync(TimeSpan.FromSeconds(3));
        var finish = session.FinishAsync(); Assert.False(finish.IsCompleted); s.Gate.SetResult(); await finish;
        Assert.Single(d.Texts); Assert.Equal("Hello world.", d.Texts[0]); Assert.Equal(2, s.Calls);
    }
    private sealed class FailingPolish : ITextPolisher { public Task<string> PolishAsync(string s, CancellationToken t) => throw new IOException(); }
    [Fact] public async Task FailedPolishKeepsOriginalAndReportsFallback()
    {
        var d = new Delivery(); var session = Create(new(), new(), d, new Settings { AIPolish = true, StreamingInsertion = false, StreamingPreview = false }, new FailingPolish());
        HistoryEntry? saved = null; session.Completed += e => saved = e;
        await session.StartAsync(); await session.FinishAsync();
        Assert.Equal("Hello world.", saved?.OriginalText); Assert.Equal(saved?.OriginalText, saved?.Text); Assert.Contains("original kept", saved?.Delivery);
    }
    [Fact] public async Task InsertionOffNeverSendsLiveOrFinalText()
    {
        var s = new Speech(); var d = new Delivery(); var session = Create(new(),s,d,new Settings { AutomaticInsertion = false });
        await session.StartAsync(); await s.Entered.Task.WaitAsync(TimeSpan.FromSeconds(3)); await session.FinishAsync(); Assert.Empty(d.Texts);
    }
}
