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
    private readonly StackPanel settingsForm = new();
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
        app = controller; Title = "yaprflow · Windows companion"; Width = 780; Height = 800; MinWidth = 600; MinHeight = 570;
        // Match the light window surface even when Windows app mode is dark.
        Resources.MergedDictionaries.Add(new ResourceDictionary
        { Source = new Uri("pack://application:,,,/PresentationFramework.Fluent;component/Themes/Fluent.Light.xaml") });
        FontFamily = new FontFamily("Segoe UI"); FontSize = 14; Background = SystemColors.WindowBrush; Foreground = SystemColors.WindowTextBrush;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var root = new DockPanel { Margin = new Thickness(24) };
        var heading = new StackPanel();
        heading.Children.Add(new TextBlock { Text = "yaprflow", FontSize = 28, FontWeight = FontWeights.SemiBold });
        heading.Children.Add(Text("Your voice, on your PC. Local dictation for Windows.", 0, 6));
        heading.Children.Add(sessionStatus);
        DockPanel.SetDock(heading, Dock.Top); root.Children.Add(heading);
        notice.TextWrapping = TextWrapping.Wrap; notice.Margin = new Thickness(0, 12, 0, 0);
        AutomationProperties.SetLiveSetting(notice, AutomationLiveSetting.Polite);
        DockPanel.SetDock(notice, Dock.Bottom); root.Children.Add(notice);
        var tabs = new TabControl { Margin = new Thickness(0, 18, 0, 0) };
        var settings = new StackPanel { Margin = new Thickness(16) };
        settings.Children.Add(TitleText("Speech model")); settings.Children.Add(modelStatus); settings.Children.Add(progress);
        settings.Children.Add(Text("One-time download: 460 MB. Allow 2 GB of free space during setup. After setup, dictation works offline.", 0, 8));
        download = Button("Download speech model", async () => await app.DownloadAsync());
        cancelDownload = Button("Cancel download", app.CancelDownload);
        settings.Children.Add(Row(download, cancelDownload));
        settings.Children.Add(settingsForm);
        settingsForm.Children.Add(TitleText("Shortcuts", 24));
        settingsForm.Children.Add(Text("Focus a text field, use your shortcut, and speak. Hold mode finishes when you release; toggle mode finishes on a second press.", 0, 10));
        primary = new ShortcutEditor(app.Settings.Primary); settingsForm.Children.Add(primary);
        settingsForm.Children.Add(externalEnabled);
        externalEnabled.IsChecked = app.Settings.External is not null;
        external = new ShortcutEditor(app.Settings.External ?? new Shortcut(6, 0x7C, TriggerMode.Toggle));
        settingsForm.Children.Add(external); external.IsEnabled = externalEnabled.IsChecked == true;
        externalEnabled.Click += (_, _) => external.IsEnabled = externalEnabled.IsChecked == true;
        settingsForm.Children.Add(Text("For a programmable mouse, assign this same key combination in your mouse software. Hold mode requires real key-down and key-up events.", 0, 8));
        settingsForm.Children.Add(Row(Button("Apply shortcuts", () =>
        {
            if (app.SaveSettings(app.Settings with { Primary = primary.Value, External = externalEnabled.IsChecked == true ? external.Value : null }))
                app.SetNotice("Shortcut active: " + app.Settings.Primary.Label);
        }), Button("Reset shortcuts", () =>
        {
            if (app.SaveSettings(app.Settings with { Primary = new Shortcut(), External = null }))
            { primary.Set(new Shortcut()); externalEnabled.IsChecked = false; external.IsEnabled = false; }
        })));
        settingsForm.Children.Add(TitleText("Dictation", 24));
        var devices = Microphone.Devices();
        var mic = new ComboBox { ItemsSource = devices.Select(d => d.Name).ToList(), MinHeight = 30 };
        mic.SelectedIndex = Math.Max(0, devices.ToList().FindIndex(d => d.Id == app.Settings.MicrophoneDevice));
        settingsForm.Children.Add(Label("_Microphone", mic)); settingsForm.Children.Add(mic);
        mic.SelectionChanged += (_, _) =>
        {
            if (refreshing || mic.SelectedIndex < 0) return;
            if (!app.SaveSettings(app.Settings with { MicrophoneDevice = devices[mic.SelectedIndex].Id }))
            { refreshing = true; mic.SelectedIndex = Math.Max(0, devices.ToList().FindIndex(d => d.Id == app.Settings.MicrophoneDevice)); refreshing = false; }
        };
        settingsForm.Children.Add(Setting("Insert text into the original field", () => app.Settings.AutomaticInsertion, v => app.Settings with { AutomaticInsertion = v }));
        settingsForm.Children.Add(Setting("Light cleanup · spacing, punctuation, repeated words", () => app.Settings.LightCleanup, v => app.Settings with { LightCleanup = v }));
        settingsForm.Children.Add(Setting("Play start and stop sounds", () => app.Settings.Sounds, v => app.Settings with { Sounds = v }));
        settingsForm.Children.Add(Setting("Save future transcripts in local History (up to 200)", () => app.Settings.KeepHistory, v => app.Settings with { KeepHistory = v }));
        settingsForm.Children.Add(Text("Turning History off keeps only the latest result in memory. Existing saved history remains until you clear it. Audio is never saved. History files contain plain text in your Windows user profile.", 0, 8));
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
        settingsForm.Children.Add(startup);
        settings.Children.Add(Row(Button("Microphone privacy settings", () => Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true })), Button("Open local data folder", app.OpenDataFolder)));
        settings.Children.Add(Text("Windows 11 · x64 · Preview 0.1.0\nNo account, no cloud transcription, no telemetry. Model setup contacts GitHub. AI polish, modifier-only gestures, and automatic correction learning are planned for a later edition.", 20, 8));
        tabs.Items.Add(new TabItem { Header = "_Settings", Content = new ScrollViewer { Content = settings, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } });

        var historyPanel = new DockPanel { Margin = new Thickness(16) };
        var historyTop = new StackPanel();
        historyTop.Children.Add(Label("_Search history", search)); historyTop.Children.Add(search); historyTop.Children.Add(historyState);
        DockPanel.SetDock(historyTop, Dock.Top); historyPanel.Children.Add(historyTop);
        var historyBottom = new StackPanel();
        historyBottom.Children.Add(Label("_Transcript", transcript)); historyBottom.Children.Add(transcript);
        historyBottom.Children.Add(Row(Button("Copy transcript", () =>
        {
            if (history.SelectedItem is not HistoryRow selected) return;
            try { Clipboard.SetText(selected.Entry.Text); app.SetNotice("Transcript copied"); }
            catch (Exception ex) { app.SetNotice("Clipboard is busy. Try Copy again. " + ex.Message); }
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

        var vocabPanel = new DockPanel { Margin = new Thickness(16) };
        var intro = Text("Teach yaprflow names and phrases it keeps mishearing. These replacements run locally after transcription.", 0, 14);
        DockPanel.SetDock(intro, Dock.Top); vocabPanel.Children.Add(intro);
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
        tabs.Items.Add(new TabItem { Header = "_Vocabulary", Content = vocabPanel });
        root.Children.Add(tabs); Content = root;
        Closing += (_, e) => { e.Cancel = true; Hide(); };
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape && app.Session.IsBusy) { _ = app.Session.CancelAsync(); e.Handled = true; } };
        app.Changed += Refresh; Refresh();
    }
    private CheckBox Setting(string title, Func<bool> value, Func<bool, Settings> change)
    {
        var box = new CheckBox { Content = title, IsChecked = value(), Margin = new Thickness(0, 12, 0, 0) };
        box.Click += (_, _) => { if (!app.SaveSettings(change(box.IsChecked == true))) box.IsChecked = value(); };
        return box;
    }
    private void Refresh()
    {
        modelStatus.Text = app.ModelStatus; progress.Value = app.ModelProgress;
        download.IsEnabled = !app.ModelBusy && !app.ModelReady && !app.Session.IsBusy;
        download.Content = app.Installer.IsInstalled ? "Repair speech model" : "Download speech model";
        cancelDownload.IsEnabled = app.CanCancelDownload;
        settingsForm.IsEnabled = !app.ModelBusy && !app.Session.IsBusy;
        notice.Text = app.Notice;
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
    { Text = text, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, top, 0, bottom) };
    private static TextBlock TitleText(string text, double top = 0) => new() { Text = text, FontSize = 18, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, top, 0, 12) };
    internal static Label Label(string title, UIElement target) => new() { Content = title, Target = target, Padding = new Thickness(0, 8, 0, 4) };
    internal static Button Button(string title, Action action)
    {
        var button = new Button { Content = title, MinHeight = 32, Padding = new Thickness(12, 5, 12, 5), Margin = new Thickness(0, 4, 8, 4) };
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
