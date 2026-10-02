using System.Diagnostics;
using System.Windows.Automation;
using System.Windows.Input;
using Microsoft.Win32;

namespace YaprFlow.Windows;

internal sealed class MainWindow : Window
{
    private readonly AppController app;
    private readonly TextBlock modelStatus = Text("");
    private readonly TextBlock notice = Text("");
    private readonly TextBlock sessionStatus = Text("");
    private readonly ProgressBar progress = new() { Height = 6, Maximum = 1, Margin = new Thickness(0, 10, 0, 10) };
    private readonly Button download;
    private readonly Button cancelDownload;
    private readonly List<StackPanel> settingsGroups = [];
    private readonly ListBox history = new() { MinHeight = 160, DisplayMemberPath = nameof(HistoryRow.Label) };
    private readonly TextBox transcript = new() { IsReadOnly = true, TextWrapping = TextWrapping.Wrap, AcceptsReturn = true, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MinHeight = 110 };
    private readonly TextBox search = new() { MinHeight = 32, Padding = new Thickness(6) };
    private readonly TextBlock historyState = Text("");
    private readonly ListBox vocabulary = new() { MinHeight = 170, DisplayMemberPath = nameof(VocabularyRow.Label) };
    private readonly TextBox heard = new() { MinHeight = 32, Padding = new Thickness(6) };
    private readonly TextBox replacement = new() { MinHeight = 32, Padding = new Thickness(6) };
    private readonly Button saveRule;
    private readonly ShortcutEditor primary;
    private readonly ShortcutEditor external;
    private readonly CheckBox externalEnabled = new() { Content = "Enable a second shortcut for a mouse button", Margin = new Thickness(0, 12, 0, 8) };
    private bool refreshing;
    private string lastHistory = "";
    private string lastVocabulary = "";

    public MainWindow(AppController controller)
    {
        app = controller; Title = "yaprflow · Windows companion"; Width = 960; Height = 760; MinWidth = 760; MinHeight = 570;
        // Match the light window surface even when Windows app mode is dark.
        Resources.MergedDictionaries.Add(new ResourceDictionary
        { Source = new Uri("pack://application:,,,/PresentationFramework.Fluent;component/Themes/Fluent.Light.xaml") });
        FontFamily = new FontFamily("Segoe UI"); FontSize = 14; Background = SystemParameters.HighContrast ? SystemColors.WindowBrush : new SolidColorBrush(Color.FromRgb(243, 246, 243)); Foreground = SystemParameters.HighContrast ? SystemColors.WindowTextBrush : new SolidColorBrush(Color.FromRgb(32, 51, 45));
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        if (!SystemParameters.HighContrast) Resources.MergedDictionaries.Add(new ResourceDictionary
        { Source = new Uri("pack://application:,,,/yaprflow;component/Theme.xaml") });
        var root = new DockPanel();
        var footer = new StackPanel { Margin = new Thickness(24, 10, 24, 12) };
        sessionStatus.FontSize = 12;
        footer.Children.Add(sessionStatus);
        notice.TextWrapping = TextWrapping.Wrap; notice.FontSize = 12; notice.Margin = new Thickness(0, 4, 0, 0);
        AutomationProperties.SetLiveSetting(notice, AutomationLiveSetting.Polite);
        footer.Children.Add(notice);
        DockPanel.SetDock(footer, Dock.Bottom); root.Children.Add(footer);
        var tabs = new TabControl { TabStripPlacement = Dock.Left };
        StackPanel Section(string name, string description)
        {
            var panel = new StackPanel { Margin = new Thickness(32, 28, 32, 28), MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Stretch };
            panel.Children.Add(new TextBlock { Text = name, FontSize = 28, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 8) }); panel.Children.Add(Text(description, 0, 24));
            var item = new TabItem { Header = name, Padding = new Thickness(14, 10, 14, 10),
                Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } };
            tabs.Items.Add(item); return panel;
        }
        var dictation = Section("Dictation", "Speak naturally. Keep your attention on what you’re writing.");
        settingsGroups.Add(dictation);
        var devices = Microphone.Devices().ToList();
        var mic = new ComboBox { MinHeight = 36, DisplayMemberPath = "Name" };
        var micState = Text("", 6, 12);
        var micRefreshing = false;
        void RefreshMicrophones()
        {
            if (app.Session.IsBusy) return;
            try
            {
                var next = Microphone.Devices().ToList();
                if (app.Settings.MicrophoneId is { } missing && !next.Any(d => d.Id == missing))
                    next.Add((missing, "Selected microphone · disconnected"));
                if (!devices.SequenceEqual(next) || mic.Items.Count == 0)
                {
                    devices = next; micRefreshing = true;
                    mic.ItemsSource = devices.Select(d => d.Name).ToList();
                    mic.SelectedIndex = Math.Max(0, devices.FindIndex(d => d.Id == app.Settings.MicrophoneId));
                    micRefreshing = false;
                }
                micState.Text = devices.Count <= 1 ? "Connect a microphone to get started. The list updates automatically."
                    : "Your microphone is remembered when you reconnect it.";
            }
            catch (Exception ex) { micState.Text = "Could not read microphones: " + ex.Message; }
        }
        mic.DisplayMemberPath = "";
        dictation.Children.Add(Label("_Microphone", mic)); dictation.Children.Add(mic); dictation.Children.Add(micState);
        mic.SelectionChanged += (_, _) =>
        {
            if (micRefreshing || mic.SelectedIndex < 0) return;
            if (!app.SaveSettings(app.Settings with { MicrophoneId = devices[mic.SelectedIndex].Id, MicrophoneDevice = -1 }))
            { micRefreshing = true; mic.SelectedIndex = Math.Max(0, devices.FindIndex(d => d.Id == app.Settings.MicrophoneId)); micRefreshing = false; }
        };
        RefreshMicrophones();
        var deviceTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        deviceTimer.Tick += (_, _) => { if (IsVisible) RefreshMicrophones(); }; deviceTimer.Start();
        dictation.Children.Add(Setting("Streaming text", () => app.Settings.StreamingInsertion, v => app.Settings with { StreamingInsertion = v }, "Phrases appear when you pause. Release shortcut keys to insert; tap-to-toggle works best. Cancel leaves text already inserted."));
        dictation.Children.Add(Setting("Live preview", () => app.Settings.StreamingPreview, v => app.Settings with { StreamingPreview = v }, "See a draft in the recording panel as you speak."));
        dictation.Children.Add(Setting("Automatic insertion", () => app.Settings.AutomaticInsertion, v => app.Settings with { AutomaticInsertion = v }, "Send your words to the field where you started."));
        dictation.Children.Add(Setting("Light cleanup", () => app.Settings.LightCleanup, v => app.Settings with { LightCleanup = v }, "Tidy spacing and punctuation."));
        dictation.Children.Add(Setting("AI Polish", () => app.Settings.AIPolish, v => app.Settings with { AIPolish = v }, "Refine grammar with an optional local model. Adds a short delay; originals stay in History. Download it in Models."));
        dictation.Children.Add(Row(Button("Windows microphone settings", () => Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true }))));

        var shortcuts = Section("Shortcuts", "Choose a comfortable way to start. Tap-to-toggle is recommended for streaming text.");
        settingsGroups.Add(shortcuts);
        primary = new ShortcutEditor(app.Settings.Primary); shortcuts.Children.Add(primary);
        shortcuts.Children.Add(externalEnabled); externalEnabled.IsChecked = app.Settings.External is not null;
        external = new ShortcutEditor(app.Settings.External ?? new Shortcut(6, 0x7C, TriggerMode.Toggle));
        shortcuts.Children.Add(external); external.IsEnabled = externalEnabled.IsChecked == true;
        externalEnabled.Click += (_, _) => external.IsEnabled = externalEnabled.IsChecked == true;
        shortcuts.Children.Add(Text("For a programmable mouse, assign the same shortcut in its software. Hold mode needs real key-down and key-up events.", 12, 12));
        shortcuts.Children.Add(Row(Button("Apply shortcuts", () =>
        {
            if (app.SaveSettings(app.Settings with { Primary = primary.Value, External = externalEnabled.IsChecked == true ? external.Value : null }))
                app.SetNotice("Shortcut active: " + app.Settings.Primary.Label);
        }), Button("Reset shortcuts", () =>
        {
            if (app.SaveSettings(app.Settings with { Primary = new Shortcut(), External = null }))
            { primary.Set(new Shortcut()); externalEnabled.IsChecked = false; external.IsEnabled = false; }
        })));

        shortcuts.Children.Add(TitleText("Modifier gesture", 24));
        var gesture = new ComboBox { MinHeight = 36, ItemsSource = new[] { "Off", "Left Ctrl + Left Shift", "Right Ctrl + Right Shift" }, SelectedIndex = (int)app.Settings.ModifierGesture };
        shortcuts.Children.Add(Label("Additional _gesture", gesture)); shortcuts.Children.Add(gesture);
        gesture.SelectionChanged += (_, _) =>
        {
            if (gesture.SelectedIndex != (int)app.Settings.ModifierGesture &&
                !app.SaveSettings(app.Settings with { ModifierGesture = (ModifierGesture)gesture.SelectedIndex }))
                gesture.SelectedIndex = (int)app.Settings.ModifierGesture;
        };
        shortcuts.Children.Add(Setting("Double-tap the gesture to keep recording", () => app.Settings.DoubleTapLock, v => app.Settings with { DoubleTapLock = v }));
        shortcuts.Children.Add(Text("Hold both keys to talk; release to finish. Two quick taps lock recording; tap once more to finish. Other keys reject a hold gesture. Your regular shortcut remains active. Escape cancels.", 8, 0));

        var sound = Section("Sound", "A little feedback. Just enough to know you’re recording."); settingsGroups.Add(sound);
        sound.Children.Add(Setting("Play start and stop sounds", () => app.Settings.Sounds, v => app.Settings with { Sounds = v }));
        var preset = new ComboBox { MinHeight = 40, ItemsSource = new[] { "Soft", "Wood", "Glass", "Classic" }, SelectedIndex = (int)app.Settings.SoundPreset };
        AutomationProperties.SetAutomationId(preset, "SoundPreset");
        sound.Children.Add(Label("Sound _style", preset)); sound.Children.Add(preset);
        var presetDescription = Text("", 8, 16); sound.Children.Add(presetDescription);
        void DescribePreset() => presetDescription.Text = app.Settings.SoundPreset switch
        {
            SoundPreset.Soft => "A gentle, rounded tap for everyday dictation.",
            SoundPreset.Wood => "A dry, tactile knock with a quick finish.",
            SoundPreset.Glass => "A light, clear note with a little more ring.",
            _ => "The original rising and falling tones."
        };
        preset.SelectionChanged += (_, _) =>
        {
            if (preset.SelectedIndex < 0) return;
            if (!app.SaveSettings(app.Settings with { SoundPreset = (SoundPreset)preset.SelectedIndex }))
                preset.SelectedIndex = (int)app.Settings.SoundPreset;
            DescribePreset();
        };
        DescribePreset();
        var volume = new Slider { Minimum = 0, Maximum = 100, Value = app.Settings.SoundVolume * 100,
            TickFrequency = 5, IsSnapToTickEnabled = true, SmallChange = 5, LargeChange = 10, MinHeight = 36 };
        AutomationProperties.SetName(volume, "Recording sound volume");
        var volumeLabel = Label($"Sound _volume · {volume.Value:0}%", volume);
        sound.Children.Add(volumeLabel); sound.Children.Add(volume);
        volume.ValueChanged += (_, _) =>
        {
            if (refreshing) return;
            if (!app.SaveSettings(app.Settings with { SoundVolume = volume.Value / 100 }))
            { refreshing = true; volume.Value = app.Settings.SoundVolume * 100; refreshing = false; }
            volumeLabel.Content = $"Sound _volume · {volume.Value:0}%";
        };
        void ImportCue(bool start)
        {
            var picker = new OpenFileDialog { Title = "Choose a short recording cue", Filter = "WAV audio|*.wav", CheckFileExists = true };
            if (picker.ShowDialog(this) == true) app.ImportSound(start, picker.FileName);
        }
        sound.Children.Add(TitleText("Start cue", 20));
        var startName = Text(""); sound.Children.Add(startName);
        sound.Children.Add(Row(Button("Preview start", () => app.PreviewSound(true)), Button("Import WAV…", () => ImportCue(true)),
            Button("Use selected style", () => app.SaveSettings(app.Settings with { StartSoundPath = null }))));
        sound.Children.Add(TitleText("Stop cue", 20));
        var stopName = Text(""); sound.Children.Add(stopName);
        sound.Children.Add(Row(Button("Preview stop", () => app.PreviewSound(false)), Button("Import WAV…", () => ImportCue(false)),
            Button("Use selected style", () => app.SaveSettings(app.Settings with { StopSoundPath = null }))));
        void CueLabels() { startName.Text = app.Settings.StartSoundPath is null ? app.Settings.SoundPreset + " · higher tap" : "Your imported start sound"; stopName.Text = app.Settings.StopSoundPath is null ? app.Settings.SoundPreset + " · lower tap" : "Your imported stop sound"; }
        CueLabels(); app.Changed += CueLabels;
        sound.Children.Add(Text("Try each cue at your chosen volume, even with sounds off. Custom WAVs override the style for that cue; use “Use selected style” to switch back. Up to 3 seconds. Volume affects only yaprflow.", 20, 0));

        var privacy = Section("Privacy", "Your audio stays in memory. Your words and preferences stay on this PC."); settingsGroups.Add(privacy);
        privacy.Children.Add(Setting("Save transcripts in local History", () => app.Settings.KeepHistory, v => app.Settings with { KeepHistory = v }));
        privacy.Children.Add(Text("Keep up to 200 transcripts. Turning this off stops future saves; clear old entries from History. Audio is never saved.", 6, 20));
        var startup = new CheckBox { Content = "Start yaprflow when I sign in", Margin = new Thickness(0, 10, 0, 8) };
        const string runPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
        using (var key = Registry.CurrentUser.OpenSubKey(runPath)) startup.IsChecked = key?.GetValue("YaprFlow") is not null;
        startup.Click += (_, _) =>
        {
            try
            {
                using var key = Registry.CurrentUser.CreateSubKey(runPath);
                if (startup.IsChecked == true) key.SetValue("YaprFlow", $"\"{Environment.ProcessPath}\" --background");
                else key.DeleteValue("YaprFlow", false);
            }
            catch (Exception ex) { startup.IsChecked = startup.IsChecked != true; app.SetNotice("Could not change startup: " + ex.Message); }
        };
        privacy.Children.Add(startup); privacy.Children.Add(Row(Button("Open local data folder", app.OpenDataFolder)));
        privacy.Children.Add(Text("No account. No cloud transcription. No telemetry.", 20, 0));

        var models = Section("Models", "Download once, then dictate offline.");
        models.Children.Add(TitleText("Parakeet speech recognition")); models.Children.Add(modelStatus); models.Children.Add(progress);
        models.Children.Add(Text("460 MB download · allow 2 GB free during setup", 0, 12));
        download = Button("Download speech model", async () => await app.DownloadAsync()); cancelDownload = Button("Cancel download", app.CancelDownload);
        models.Children.Add(Row(download, cancelDownload));
        models.Children.Add(TitleText("AI Polish", 24));
        var polishStatus = Text(app.PolishStatus, 0, 12); models.Children.Add(polishStatus);
        var polishButton = Button(app.PolishModel.IsInstalled ? "Repair AI Polish model" : "Download AI Polish model", async () => await app.DownloadPolishAsync());
        var polishCancel = Button("Cancel", app.CancelPolishDownload);
        models.Children.Add(Row(polishButton, polishCancel));
        models.Children.Add(Text("Qwen3 0.6B · 610 MB · allow 2 GB of memory. No account or other app required. This download is optional.", 6, 0));
        void RefreshPolish() { polishStatus.Text = app.PolishStatus; polishButton.IsEnabled = !app.ModelBusy && !app.Session.IsBusy; polishCancel.IsEnabled = app.PolishDownloading; }
        app.Changed += RefreshPolish; RefreshPolish();
        models.Children.Add(Text("Windows 11 · x64 · Preview 0.2.1", 24, 0));
        if (!app.Installer.IsInstalled) tabs.SelectedIndex = 4;

        var historyPanel = new DockPanel { Margin = new Thickness(32, 28, 32, 28) };
        var historyTop = new StackPanel();
        historyTop.Children.Add(TitleText("History")); historyTop.Children.Add(Text("Your recent words, ready to use again.", 0, 16));
        historyTop.Children.Add(Label("_Search history", search)); historyTop.Children.Add(search); historyTop.Children.Add(historyState);
        DockPanel.SetDock(historyTop, Dock.Top); historyPanel.Children.Add(historyTop);
        var historyBottom = new StackPanel();
        historyBottom.Children.Add(Label("_Transcript", transcript)); historyBottom.Children.Add(transcript);
        historyBottom.Children.Add(Row(Button("Copy transcript", () =>
        {
            if (history.SelectedItem is not HistoryRow selected) return;
            try { Clipboard.SetText(selected.Entry.Text); app.SetNotice("Transcript copied"); }
            catch (Exception ex) { app.SetNotice("Clipboard is busy. Try Copy again. " + ex.Message); }
        }), Button("Copy original", () =>
        {
            if (history.SelectedItem is not HistoryRow selected) return;
            try { Clipboard.SetText(selected.Entry.OriginalText ?? selected.Entry.Text); app.SetNotice("Original transcript copied"); }
            catch { app.SetNotice("Clipboard is busy. Try Copy again."); }
        }), Button("Delete selected", () =>
        { if (history.SelectedItem is HistoryRow selected) app.DeleteHistory(selected.Entry.Id); }),
        Button("Clear all history", () =>
        {
            if (MessageBox.Show(this, "Delete all saved transcripts? This cannot be undone.", "Clear history", MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes) app.DeleteHistory(null);
        })));
        DockPanel.SetDock(historyBottom, Dock.Bottom); historyPanel.Children.Add(historyBottom); historyPanel.Children.Add(history);
        history.SelectionChanged += (_, _) => transcript.Text = (history.SelectedItem as HistoryRow)?.Entry.Text ?? "";
        search.TextChanged += (_, _) => RefreshHistory();
        tabs.Items.Add(new TabItem { Header = "_History", Content = historyPanel });

        var vocabPanel = new DockPanel { Margin = new Thickness(32, 28, 32, 28) };
        var intro = Text("Teach yaprflow names and phrases it keeps mishearing. These replacements run locally after transcription.", 0, 14);
        var learn = new StackPanel(); learn.Children.Add(TitleText("Vocabulary")); learn.Children.Add(intro);
        learn.Children.Add(Setting("Suggest vocabulary from corrections I make", () => app.Settings.LearnCorrections, v => app.Settings with { LearnCorrections = v }));
        learn.Children.Add(Text("Off by default. For 20 seconds after insertion, checks only the same non-password field while it stays focused. Suggestions stay in memory until you approve them. Field contents are never saved.", 6, 12));
        var suggestions = new ComboBox { MinHeight = 32, DisplayMemberPath = nameof(VocabularyRow.Label) };
        learn.Children.Add(Label("_Suggested corrections", suggestions)); learn.Children.Add(suggestions);
        var accept = Button("Accept suggestion", () => { if (suggestions.SelectedItem is VocabularyRow row) app.ReviewCorrection(row.Rule, true); });
        var dismiss = Button("Dismiss", () => { if (suggestions.SelectedItem is VocabularyRow row) app.ReviewCorrection(row.Rule, false); });
        learn.Children.Add(Row(accept, dismiss));
        var lastSuggestions = "";
        void RefreshSuggestions()
        {
            var signature = string.Join("|", app.Suggestions);
            if (signature != lastSuggestions) { lastSuggestions = signature; suggestions.ItemsSource = app.Suggestions.Select(r => new VocabularyRow(r)).ToList(); suggestions.SelectedIndex = 0; }
            accept.IsEnabled = dismiss.IsEnabled = app.Suggestions.Count > 0;
        }
        app.Changed += RefreshSuggestions; RefreshSuggestions();
        DockPanel.SetDock(learn, Dock.Top); vocabPanel.Children.Add(learn);
        var edit = new StackPanel { Margin = new Thickness(0, 16, 0, 0) };
        edit.Children.Add(Label("_When it hears", heard)); edit.Children.Add(heard);
        edit.Children.Add(Label("_Use this spelling", replacement)); edit.Children.Add(replacement);
        saveRule = Button("Add phrase", () =>
        {
            var candidate = app.Vocabulary.ToList();
            if (vocabulary.SelectedItem is VocabularyRow selected) candidate.Remove(selected.Rule);
            candidate.Add(new(heard.Text.Trim(), replacement.Text.Trim()));
            app.SaveVocabulary(candidate);
        });
        edit.Children.Add(Row(saveRule, Button("New phrase", () => { vocabulary.SelectedItem = null; heard.Clear(); replacement.Clear(); heard.Focus(); }),
            Button("Delete selected", () =>
            { if (vocabulary.SelectedItem is VocabularyRow selected) app.SaveVocabulary(app.Vocabulary.Where(r => r != selected.Rule).ToList()); })));
        DockPanel.SetDock(edit, Dock.Bottom); vocabPanel.Children.Add(edit); vocabPanel.Children.Add(vocabulary);
        vocabulary.SelectionChanged += (_, _) =>
        {
            var selected = vocabulary.SelectedItem as VocabularyRow;
            heard.Text = selected?.Rule.Heard ?? ""; replacement.Text = selected?.Rule.Replacement ?? "";
            saveRule.Content = selected is null ? "Add phrase" : "Update phrase";
        };
        tabs.Items.Add(new TabItem { Header = "_Vocabulary", Content = new ScrollViewer { Content = vocabPanel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } });
        root.Children.Add(tabs); Content = root;
        Closing += (_, e) => { e.Cancel = true; Hide(); };
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape && app.Session.IsBusy) { _ = app.Session.CancelAsync(); e.Handled = true; } };
        app.Changed += Refresh; Refresh();
    }
    private CheckBox Setting(string title, Func<bool> value, Func<bool, Settings> change, string? description = null)
    {
        var content = new StackPanel();
        content.Children.Add(new TextBlock { Text = title, TextWrapping = TextWrapping.Wrap, FontWeight = FontWeights.SemiBold });
        if (description is not null) content.Children.Add(Text(description, 5, 0));
        var box = new CheckBox { Content = content, IsChecked = value(), Margin = new Thickness(0, 0, 0, 4) };
        AutomationProperties.SetName(box, title);
        if (description is not null) AutomationProperties.SetHelpText(box, description);
        if (!SystemParameters.HighContrast) box.Style = (Style)FindResource("SettingToggle");
        box.Click += (_, _) => { if (!app.SaveSettings(change(box.IsChecked == true))) box.IsChecked = value(); };
        return box;
    }
    private void Refresh()
    {
        modelStatus.Text = app.ModelStatus; progress.Value = app.ModelProgress;
        download.IsEnabled = !app.ModelBusy && !app.ModelReady && !app.Session.IsBusy;
        download.Content = app.Installer.IsInstalled ? "Repair speech model" : "Download speech model";
        cancelDownload.IsEnabled = app.CanCancelDownload;
        foreach (var group in settingsGroups) group.IsEnabled = !app.ModelBusy && !app.Session.IsBusy;
        notice.Text = app.Notice; notice.Visibility = string.IsNullOrWhiteSpace(app.Notice) ? Visibility.Collapsed : Visibility.Visible;
        sessionStatus.Text = !app.HasShortcut ? "No shortcut available — choose another combination in Settings"
            : app.Session.IsBusy ? app.Session.Status
            : !app.ModelReady ? (app.ModelBusy ? "Preparing the speech model…" : "Download or repair the speech model to enable dictation")
            : app.Settings.Primary.Label + " · " + app.Settings.Primary.Mode + " to talk · " + app.Session.Status;
        var h = string.Join(',', app.History.Select(e => e.Id));
        if (h != lastHistory) { lastHistory = h; RefreshHistory(); }
        else if (app.History.Count == 0) RefreshHistory();
        var v = string.Join('\n', app.Vocabulary.Select(r => r.Heard + "\t" + r.Replacement));
        if (v != lastVocabulary)
        {
            lastVocabulary = v;
            vocabulary.ItemsSource = app.Vocabulary.OrderBy(r => r.Heard).Select(r => new VocabularyRow(r)).ToList();
        }
    }
    private void RefreshHistory()
    {
        var selected = (history.SelectedItem as HistoryRow)?.Entry.Id;
        var filtered = app.History.Where(e => e.Text.Contains(search.Text, StringComparison.OrdinalIgnoreCase)).Select(e => new HistoryRow(e)).ToList();
        history.ItemsSource = filtered;
        history.SelectedItem = filtered.FirstOrDefault(r => r.Entry.Id == selected) ?? filtered.FirstOrDefault();
        historyState.Text = app.History.Count == 0 ? "Your dictations appear here. Focus a text field and use your shortcut to begin."
            : filtered.Count == 0 ? "No matching transcripts. Try another search." : $"{filtered.Count} transcript(s) · newest first";
    }
    private sealed record HistoryRow(HistoryEntry Entry)
    { public string Label => $"{Entry.CreatedAt.LocalDateTime:g}   {Entry.Text.Replace('\n', ' ')[..Math.Min(Entry.Text.Length, 80)]}\n{Entry.Delivery}"; }
    private sealed record VocabularyRow(VocabularyRule Rule) { public string Label => $"{Rule.Heard}  →  {Rule.Replacement}"; }
    internal static TextBlock Text(string text, double top = 0, double bottom = 0) => new()
    { Text = text, TextWrapping = TextWrapping.Wrap, FontSize = 13, Foreground = SystemParameters.HighContrast ? SystemColors.WindowTextBrush : new SolidColorBrush(Color.FromRgb(98, 113, 105)), Margin = new Thickness(0, top, 0, bottom) };
    private static TextBlock TitleText(string text, double top = 0) => new() { Text = text, FontSize = 18, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, top, 0, 12) };
    internal static Label Label(string title, UIElement target) => new() { Content = title, Target = target, Padding = new Thickness(0, 8, 0, 4) };
    internal static Button Button(string title, Action action)
    {
        var button = new Button { Content = title, MinHeight = 36, Padding = new Thickness(12, 7, 12, 7), Margin = new Thickness(0, 4, 8, 4) };
        button.Click += (_, _) => action(); return button;
    }
    internal static WrapPanel Row(params UIElement[] children)
    { var row = new WrapPanel(); foreach (var child in children) row.Children.Add(child); return row; }
}

internal sealed class ShortcutEditor : StackPanel
{
    private readonly CheckBox ctrl = new() { Content = "Ctrl", Margin = new Thickness(0, 8, 12, 8) };
    private readonly CheckBox alt = new() { Content = "Alt", Margin = new Thickness(0, 8, 12, 8) };
    private readonly CheckBox shift = new() { Content = "Shift", Margin = new Thickness(0, 8, 12, 8) };
    private readonly ComboBox key = new() { MinWidth = 100, MinHeight = 32, DisplayMemberPath = nameof(KeyChoice.Name), Margin = new Thickness(0, 0, 12, 0) };
    private readonly ComboBox mode = new() { MinWidth = 140, MinHeight = 32, ItemsSource = new[] { "Hold to talk", "Tap to toggle" } };
    private sealed record KeyChoice(uint Code, string Name);
    public ShortcutEditor(Shortcut value)
    {
        key.Items.Add(new KeyChoice(32, "Space"));
        for (uint k = 0x70; k <= 0x87; k++) key.Items.Add(new KeyChoice(k, $"F{k - 0x6F}"));
        for (uint k = 0x41; k <= 0x5A; k++) key.Items.Add(new KeyChoice(k, ((char)k).ToString()));
        for (uint k = 0x30; k <= 0x39; k++) key.Items.Add(new KeyChoice(k, ((char)k).ToString()));
        AutomationProperties.SetName(key, "Shortcut key"); AutomationProperties.SetName(mode, "Trigger mode");
        Children.Add(MainWindow.Row(ctrl, alt, shift, key, mode)); Set(value);
    }
    public Shortcut Value => new((ctrl.IsChecked == true ? 2u : 0) | (alt.IsChecked == true ? 1u : 0) | (shift.IsChecked == true ? 4u : 0),
        (key.SelectedItem as KeyChoice)?.Code ?? 32, mode.SelectedIndex == 1 ? TriggerMode.Toggle : TriggerMode.Hold);
    public void Set(Shortcut value)
    {
        ctrl.IsChecked = (value.Modifiers & 2) != 0; alt.IsChecked = (value.Modifiers & 1) != 0; shift.IsChecked = (value.Modifiers & 4) != 0;
        key.SelectedItem = key.Items.OfType<KeyChoice>().FirstOrDefault(k => k.Code == value.Key);
        mode.SelectedIndex = value.Mode == TriggerMode.Toggle ? 1 : 0;
    }
}
