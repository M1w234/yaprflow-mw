using Xunit;
using YaprFlow.Core;

namespace YaprFlow.Tests;

public class SessionTests
{
    private sealed class Audio : IAudioRecorder
    {
        public int Starts, Stops;
        public float[] Samples = Enumerable.Repeat(.1f, 4000).ToArray();
        public Task StartAsync(CancellationToken token) { token.ThrowIfCancellationRequested(); Starts++; return Task.CompletedTask; }
        public Task<float[]> StopAsync() { Stops++; return Task.FromResult(Samples); }
    }
    private sealed class Speech : ISpeechRecognizer
    {
        public TaskCompletionSource? PrepareGate, DecodeGate;
        public int Decodes;
        public async Task PrepareAsync(CancellationToken token) { if (PrepareGate is not null) await PrepareGate.Task; }
        public async Task<string> TranscribeAsync(float[] samples, CancellationToken token)
        { Decodes++; if (DecodeGate is not null) await DecodeGate.Task; return "  the the yapper flow  "; }
    }
    private sealed class Delivery : ITextDelivery
    {
        public readonly object Target = new();
        public object? DeliveredTarget;
        public string? Text;
        public bool Fail;
        public Task<object?> CaptureTargetAsync() => Task.FromResult<object?>(Target);
        public Task<string> DeliverAsync(string text, object? target, CancellationToken token)
        {
            if (Fail) throw new IOException("field went away");
            Text = text; DeliveredTarget = target; return Task.FromResult("Text sent");
        }
    }
    [Fact]
    public async Task ReleaseDuringPreparationNeverStartsMicrophone()
    {
        var audio = new Audio(); var speech = new Speech { PrepareGate = new() }; var delivery = new Delivery();
        var session = Create(audio, speech, delivery);
        var start = session.StartAsync(); var finish = session.FinishAsync(); speech.PrepareGate.SetResult();
        await Task.WhenAll(start, finish);
        Assert.Equal(0, audio.Starts); Assert.False(session.IsBusy); Assert.Null(delivery.Text);
    }
    [Fact]
    public async Task CancelDuringPreparationNeverStartsMicrophone()
    {
        var audio = new Audio(); var speech = new Speech { PrepareGate = new() }; var delivery = new Delivery();
        var session = Create(audio, speech, delivery);
        var start = session.StartAsync(); await session.CancelAsync(); speech.PrepareGate.SetResult(); await start;
        Assert.Equal(0, audio.Starts); Assert.False(session.IsBusy); Assert.Equal("Canceled", session.Status);
    }
    [Fact]
    public async Task CancelDuringRecognitionDiscardsTextAndPreventsOverlappingSessions()
    {
        var audio = new Audio(); var speech = new Speech { DecodeGate = new() }; var delivery = new Delivery();
        var session = Create(audio, speech, delivery); var completions = 0; session.Completed += _ => completions++;
        await session.StartAsync(); var finish = session.FinishAsync(); await session.CancelAsync();
        await session.StartAsync(); Assert.Equal(1, audio.Starts);
        speech.DecodeGate.SetResult(); await finish;
        Assert.False(session.IsBusy); Assert.Null(delivery.Text); Assert.Equal(0, completions);
    }
    [Fact]
    public async Task CancelWhileRecordingDiscardsAudio()
    {
        var audio = new Audio(); var speech = new Speech(); var delivery = new Delivery(); var session = Create(audio, speech, delivery);
        await session.StartAsync(); await session.CancelAsync();
        Assert.Equal(1, audio.Stops); Assert.Equal(0, speech.Decodes); Assert.Null(delivery.Text); Assert.False(session.IsBusy);
    }
    [Fact]
    public async Task DeliveryUsesOriginalTargetAndAppliesVocabularyBeforeCleanup()
    {
        var audio = new Audio(); var speech = new Speech(); var delivery = new Delivery(); var session = Create(audio, speech, delivery);
        HistoryEntry? saved = null; session.Completed += e => saved = e;
        await session.StartAsync(); await session.FinishAsync();
        Assert.Same(delivery.Target, delivery.DeliveredTarget); Assert.Equal("the yaprflow", delivery.Text);
        Assert.Equal(delivery.Text, saved?.Text); Assert.False(session.IsBusy);
    }
    [Fact]
    public async Task DeliveryFailureStillProducesRecoverableTranscript()
    {
        var session = Create(new(), new(), new() { Fail = true }); HistoryEntry? saved = null; session.Completed += e => saved = e;
        await session.StartAsync(); await session.FinishAsync(); Assert.Equal("the yaprflow", saved?.Text); Assert.Contains("Not inserted", saved?.Delivery);
    }
    [Fact]
    public async Task SilenceDoesNotRunRecognitionOrDelivery()
    {
        var audio = new Audio { Samples = new float[16000] }; var speech = new Speech(); var delivery = new Delivery();
        var session = Create(audio, speech, delivery); await session.StartAsync(); await session.FinishAsync();
        Assert.Equal(0, speech.Decodes); Assert.Null(delivery.Text); Assert.Contains("No speech", session.Status);
    }
    [Fact]
    public async Task AutomaticInsertionOffStillCompletesTranscript()
    {
        var delivery = new Delivery();
        var session = new DictationSession(new Audio(), new Speech(), delivery, () => new Settings { AutomaticInsertion = false }, () => []);
        HistoryEntry? saved = null; session.Completed += e => saved = e;
        await session.StartAsync(); await session.FinishAsync(); Assert.NotNull(saved); Assert.Null(delivery.Text);
    }
    private static DictationSession Create(Audio audio, Speech speech, Delivery delivery) => new(audio, speech, delivery, () => new(), () => [new("yapper flow", "yaprflow")]);
}
