using System.Net;
using System.Text.Json;
using YaprFlow.Core;
using Xunit;

namespace YaprFlow.Tests;
public class DesklingBridgeTests
{
    private sealed class Relay : HttpMessageHandler
    {
        public string? Command;
        public long Sequence = 1;
        public bool FailAck, InvalidVersion, FailPoll;
        public readonly List<(string Path, string Body)> Requests = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            if (request.Content is not null) Assert.True(request.Content.Headers.ContentLength > 0);
            var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(token);
            var path = request.RequestUri!.AbsolutePath;
            Requests.Add((path, body));
            Assert.Equal("127.0.0.1", request.RequestUri.Host);
            if (FailPoll && path.EndsWith("command")) throw new HttpRequestException();
            if (FailAck && path.EndsWith("status") && JsonDocument.Parse(body).RootElement.GetProperty("ackSeq").GetInt64() > 0)
                throw new HttpRequestException();
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new
            { ok = true, v = InvalidVersion ? 2 : 1, command = path.EndsWith("command") && Command is not null ? new { seq = Sequence, command = Command } : null })) };
        }
    }
    [Theory]
    [InlineData("start")][InlineData("stop")][InlineData("cancel")][InlineData("toggle_lock")]
    public async Task CommandsAreOneShotAndPayloadContainsOnlyCoarseState(string action)
    {
        var relay = new Relay { Command = action }; using var http = new HttpClient(relay);
        var seen = new List<string>(); var bridge = new DesklingBridge(http, () => "idle", seen.Add, () => {});
        await bridge.CycleAsync(default); await bridge.CycleAsync(default);
        Assert.Equal(new[] { action }, seen); Assert.True(bridge.Connected);
        foreach(var row in relay.Requests.Where(x => x.Path.EndsWith("status")))
        {
            using var json = JsonDocument.Parse(row.Body);
            Assert.Equal(new[] { "ackSeq", "canSubmit", "client", "state" }, json.RootElement.EnumerateObject().Select(x => x.Name).Order().ToArray());
            Assert.False(json.RootElement.GetProperty("canSubmit").GetBoolean());
        }
    }
    [Theory][InlineData("submit")][InlineData("shell")]
    public async Task UnsupportedCommandsNeverDispatch(string action)
    {
        var relay = new Relay { Command = action }; using var http = new HttpClient(relay);
        var seen = new List<string>(); var bridge = new DesklingBridge(http, () => "idle", seen.Add, () => {});
        await bridge.CycleAsync(default); Assert.Empty(seen);
    }
    [Fact]
    public async Task FailedAcknowledgmentDisconnectsAndRotatesClientBeforeReconnect()
    {
        var relay = new Relay { Command = "toggle_lock", FailAck = true }; using var http = new HttpClient(relay);
        var seen = new List<string>(); var lost = 0;
        var bridge = new DesklingBridge(http, () => "listening", seen.Add, () => lost++);
        await bridge.CycleAsync(default);
        Assert.Single(seen); Assert.False(bridge.Connected); Assert.Equal(1,lost);
        relay.FailAck = false; relay.Command = null; await bridge.CycleAsync(default);
        var clients = relay.Requests.Where(x => x.Path.EndsWith("client")).Select(x => x.Body).ToArray();
        Assert.Equal(2,clients.Length); Assert.NotEqual(clients[0],clients[1]); Assert.Single(seen);
    }
    [Fact]
    public async Task MalformedProtocolDoesNotExecuteOrClaimConnection()
    {
        var relay = new Relay { Command = "start", InvalidVersion = true }; using var http = new HttpClient(relay);
        var seen = new List<string>(); var bridge = new DesklingBridge(http, () => "idle", seen.Add, () => {});
        await bridge.CycleAsync(default); Assert.Empty(seen); Assert.False(bridge.Connected);
    }
    [Fact]
    public async Task LostRelaySignalsCancellationOnlyOnce()
    {
        var relay = new Relay(); using var http = new HttpClient(relay); var lost = 0;
        var bridge = new DesklingBridge(http, () => "listening", _ => {}, () => lost++);
        await bridge.CycleAsync(default); relay.FailPoll = true;
        await bridge.CycleAsync(default); await bridge.CycleAsync(default);
        Assert.Equal(1,lost); Assert.False(bridge.Connected);
    }
}
