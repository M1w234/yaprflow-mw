using System.Diagnostics;
using System.Windows.Threading;
using Microsoft.Win32;
using YaprFlow.Speech;
using Forms = System.Windows.Forms;

namespace YaprFlow.Windows;

internal sealed class App : Application
{
    private Mutex? instance;
    private AppController? controller;
    [STAThread]
    public static void Main()
    {
        var app = new App { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Run();
    }
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        instance = new Mutex(true, "Local\\TeamWong.YaprFlow.Windows", out var first);
        if (!first) { MessageBox.Show("yaprflow is already running. Open it from the system tray.", "yaprflow"); Shutdown(); return; }
        try
        {
            var smokeIndex = Array.IndexOf(e.Args, "--smoke-ui");
            var smokeDirectory = smokeIndex >= 0 && smokeIndex + 1 < e.Args.Length ? Path.GetFullPath(e.Args[smokeIndex + 1]) : null;
            var directory = smokeDirectory is null
                ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "YaprFlow")
                : Path.Combine(Path.GetTempPath(), "yaprflow-smoke-" + Guid.NewGuid().ToString("N"));
            controller = new AppController(directory);
            MainWindow = controller.Window;
            if (smokeDirectory is not null) { _ = UiSmoke.RunAsync(controller, smokeDirectory); return; }
            if (!e.Args.Contains("--background") || !controller.Installer.IsInstalled) controller.Show();
            _ = controller.WarmupAsync();
        }
        catch (Exception ex)
        {
            MessageBox.Show("yaprflow could not start. Your saved files have not been reset.\n\n" + ex.Message +
                "\n\nData is in %LOCALAPPDATA%\\YaprFlow.", "yaprflow", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }
    protected override void OnExit(ExitEventArgs e) { controller?.Dispose(); instance?.Dispose(); base.OnExit(e); }
}

internal sealed class AppController : IDisposable
{
    private readonly JsonStore store;
    private readonly HotkeyService hotkeys = new();
    private readonly Microphone microphone;
    private readonly ParakeetRecognizer recognizer;
    private readonly Forms.NotifyIcon tray;
    private readonly OverlayWindow overlay;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private readonly Stopwatch recordingTime = new();
    private int? holdOwner;
    private SessionPhase previousPhase;
    private CancellationTokenSource? download;
    private bool exiting;
    public Settings Settings { get; private set; }
    public List<HistoryEntry> History { get; private set; }
    public List<VocabularyRule> Vocabulary { get; private set; }
    public ModelInstaller Installer { get; }
    public DictationSession Session { get; }
    public MainWindow Window { get; }
    public bool ModelReady { get; private set; }
    public bool HasShortcut => hotkeys.HasShortcut;
    public bool ModelBusy { get; private set; }
    public bool CanCancelDownload => download is not null;
    public string ModelStatus { get; private set; } = "Download the speech model to get started.";
    public string Notice { get; private set; } = "";
    public double ModelProgress { get; private set; }
    public event Action? Changed;

    public AppController(string directory)
    {
        store = new(directory);
        Settings = store.Read("settings.json", () => new Settings());
        Settings.Validate();
        History = Settings.KeepHistory ? store.Read("history.json", () => new List<HistoryEntry>()).Take(200).ToList() : [];
        Vocabulary = store.Read("vocabulary.json", () => new List<VocabularyRule>
        { new("yapper flow", "yaprflow"), new("yabber flow", "yaprflow") });
        TextProcessing.ValidateVocabulary(Vocabulary);
        Installer = new(Path.Combine(directory, "models", ModelCatalog.Id));
        microphone = new(() => Settings.MicrophoneDevice);
        recognizer = new(Installer);
        Session = new(microphone, recognizer, new TextDelivery(), () => Settings, () => Vocabulary);
        overlay = new OverlayWindow(() => _ = Session.CancelAsync(), () => _ = Session.FinishAsync());
        Window = new MainWindow(this);
        tray = new Forms.NotifyIcon
        {
            Icon = System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? System.Drawing.SystemIcons.Application,
            Text = "yaprflow · local dictation", Visible = true
        };
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open yaprflow", null, (_, _) => Show());
        menu.Items.Add("Finish dictation", null, (_, _) => _ = Session.FinishAsync());
        menu.Items.Add("Cancel dictation", null, (_, _) => _ = Session.CancelAsync());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit", null, async (_, _) => await QuitAsync());
        tray.ContextMenuStrip = menu;
        tray.DoubleClick += (_, _) => Show();
        Session.Changed += SessionChanged;
        Session.Completed += Completed;
        hotkeys.Pressed += Pressed;
        hotkeys.Released += (id, shortcut) => { if (shortcut.Mode == TriggerMode.Hold && holdOwner == id) _ = Session.FinishAsync(); };
        hotkeys.Escape += () => _ = Session.CancelAsync();
        if (!hotkeys.Configure(Settings))
        {
            Notice = "A saved shortcut is in use by another app. Choose another shortcut below.";
            // Start with a fresh fallback when possible; never report readiness with no trigger.
            var fallback = Settings with { Primary = new Shortcut(6, 0x78), External = null };
            if (hotkeys.Configure(fallback)) { Settings = fallback; Notice += " Ctrl + Shift + F9 is active for this session."; }
        }
        microphone.Level += level => Application.Current.Dispatcher.BeginInvoke(() => overlay.SetLevel(level));
        microphone.Fault += message => Application.Current.Dispatcher.BeginInvoke(async () =>
        { await Session.CancelAsync(); SetNotice(message); });
        timer.Tick += (_, _) =>
        {
            if (Session.Phase == SessionPhase.Listening)
            {
                overlay.SetTime(recordingTime.Elapsed);
                if (recordingTime.Elapsed >= TimeSpan.FromMinutes(10)) _ = Session.FinishAsync();
            }
        };
        timer.Start();
        SystemEvents.SessionSwitch += OnSessionSwitch;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        Changed?.Invoke();
    }
    private void OnSessionSwitch(object sender, SessionSwitchEventArgs e)
    {
        if (e.Reason is SessionSwitchReason.SessionLock or SessionSwitchReason.SessionLogoff)
            Application.Current.Dispatcher.BeginInvoke(async () => await Session.CancelAsync());
    }
    private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Suspend)
            Application.Current.Dispatcher.BeginInvoke(async () => await Session.CancelAsync());
    }
    public void Show() { Window.Show(); Window.Activate(); }
    public void SetNotice(string message) { Notice = message; Changed?.Invoke(); }
    private void Pressed(int id, Shortcut shortcut)
    {
        if (ModelBusy || !ModelReady) { Show(); SetNotice("Wait for the speech model to be ready, then try your shortcut again."); return; }
        if (Session.IsBusy)
        {
            if (shortcut.Mode == TriggerMode.Toggle && Session.Phase is SessionPhase.Listening or SessionPhase.Preparing)
                _ = Session.FinishAsync();
            return;
        }
        holdOwner = shortcut.Mode == TriggerMode.Hold ? id : null;
        _ = Session.StartAsync();
    }
    private void SessionChanged()
    {
        var phase = Session.Phase;
        if (phase != previousPhase)
        {
            if (phase == SessionPhase.Listening)
            {
                recordingTime.Restart();
                if (!hotkeys.SetEscape(true)) SetNotice("Escape is in use by another app. Use Cancel on the recording pill or tray menu.");
                if (Settings.Sounds) System.Media.SystemSounds.Asterisk.Play();
            }
            if (phase == SessionPhase.Idle)
            {
                holdOwner = null; recordingTime.Stop(); hotkeys.SetEscape(false);
            }
            if (previousPhase == SessionPhase.Listening && Settings.Sounds) System.Media.SystemSounds.Beep.Play();
            previousPhase = phase;
        }
        overlay.Update(phase, Session.Status);
        tray.Text = "yaprflow · " + phase;
        Changed?.Invoke();
    }
    private void Completed(HistoryEntry entry)
    {
        History.Insert(0, entry);
        History = History.Take(Settings.KeepHistory ? 200 : 1).ToList();
        if (Settings.KeepHistory)
        {
            try { store.Write("history.json", History); }
            catch (Exception ex) { SetNotice("Transcript is available in this session, but History could not be saved: " + ex.Message); }
        }
        if (!entry.Delivery.StartsWith("Text sent", StringComparison.Ordinal))
        {
            tray.ShowBalloonTip(5000, "Your transcript is ready", "Open yaprflow History to copy it. " + entry.Delivery, Forms.ToolTipIcon.Info);
        }
        Changed?.Invoke();
    }
    public bool SaveSettings(Settings candidate)
    {
        if (Session.IsBusy || ModelBusy) { SetNotice("Finish dictation or model setup before changing settings."); return false; }
        try
        {
            candidate.Validate();
            if (!hotkeys.Configure(candidate)) { SetNotice("That shortcut is already in use. Your previous shortcut is still active."); return false; }
            try
            {
                store.Write("settings.json", candidate);
            }
            catch { hotkeys.Configure(Settings); throw; }
            Settings = candidate;
            SetNotice("Settings saved");
            return true;
        }
        catch (Exception ex) { SetNotice("Could not save settings: " + ex.Message); return false; }
    }
    public void SaveVocabulary(List<VocabularyRule> candidate)
    {
        try { TextProcessing.ValidateVocabulary(candidate); store.Write("vocabulary.json", candidate); Vocabulary = candidate; SetNotice("Vocabulary saved"); }
        catch (Exception ex) { SetNotice("Could not save vocabulary: " + ex.Message); }
    }
    public void DeleteHistory(Guid? id)
    {
        var candidate = id.HasValue ? History.Where(h => h.Id != id).ToList() : [];
        try { if (Settings.KeepHistory || id is null) store.Write("history.json", candidate); History = candidate; SetNotice("History updated"); }
        catch (Exception ex) { SetNotice("Could not update History: " + ex.Message); }
    }
    public async Task WarmupAsync()
    {
        if (!Installer.IsInstalled || ModelBusy) return;
        ModelBusy = true; ModelStatus = "Checking and warming the local speech model…"; Changed?.Invoke();
        try
        {
            await recognizer.PrepareAsync(CancellationToken.None);
            ModelReady = true; ModelProgress = 1; ModelStatus = "Ready · speech recognition stays on this PC";
        }
        catch (Exception ex) { ModelReady = false; ModelStatus = "Model could not load: " + ex.Message; }
        finally { ModelBusy = false; Changed?.Invoke(); }
    }
    public async Task DownloadAsync()
    {
        if (ModelBusy || Session.IsBusy || ModelReady) return;
        download = new CancellationTokenSource(); ModelBusy = true; ModelProgress = 0; Changed?.Invoke();
        try
        {
            await Installer.InstallAsync(new Progress<DownloadProgress>(p =>
            { ModelStatus = p.Message; ModelProgress = p.Fraction; Changed?.Invoke(); }), download.Token);
        }
        catch (OperationCanceledException) { ModelStatus = "Download canceled. You can retry when ready."; }
        catch (Exception ex) { ModelStatus = "Download failed: " + ex.Message; }
        finally { ModelBusy = false; download.Dispose(); download = null; Changed?.Invoke(); }
        if (Installer.IsInstalled) await WarmupAsync();
    }
    public void CancelDownload() => download?.Cancel();
    public void OpenDataFolder() { Directory.CreateDirectory(store.DirectoryPath); Process.Start(new ProcessStartInfo(store.DirectoryPath) { UseShellExecute = true }); }
    public async Task QuitAsync()
    {
        if (exiting) return;
        if (Session.IsBusy)
        {
            if (MessageBox.Show(Window, "Cancel the current dictation and quit?", "Quit yaprflow", MessageBoxButton.YesNo) != MessageBoxResult.Yes) return;
            await Session.CancelAsync();
        }
        // Exit the process after disposing UI resources. Never dispose a native
        // recognizer while its worker is inside a native inference call.
        exiting = true; download?.Cancel(); Application.Current.Shutdown();
    }
    public void Dispose()
    {
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        timer.Stop(); hotkeys.Dispose(); tray.Visible = false; tray.Dispose(); overlay.Close();
        if (!Session.IsBusy && !ModelBusy) recognizer.Dispose();
    }
}
