using System.Text.Json;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using System.Windows.Interop;
using System.Runtime.InteropServices;

namespace YaprFlow.Windows;

internal static class UiSmoke
{
    public static async Task RunAsync(AppController app, string outputDirectory)
    {
        try
        {
            Directory.CreateDirectory(outputDirectory);
            app.Show();
            await Task.Delay(700);
            if (!app.HasShortcut) throw new InvalidOperationException("The fresh default shortcut did not register.");
            var tabs = Find<TabControl>(app.Window) ?? throw new InvalidOperationException("No settings tabs rendered.");
            var counts = new Dictionary<string, int>();
            foreach (var name in new[] { "dictation", "shortcuts", "sound", "privacy", "models", "history", "vocabulary" })
            {
                tabs.SelectedIndex = counts.Count;
                app.Window.UpdateLayout();
                await app.Window.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Render);
                var buttons = All<Button>(tabs).ToList();
                if (buttons.Count == 0) throw new InvalidOperationException("No accessible buttons in " + name);
                counts[name] = buttons.Count;
                var image = new RenderTargetBitmap((int)app.Window.ActualWidth, (int)app.Window.ActualHeight, 96, 96, PixelFormats.Pbgra32);
                image.Render(app.Window);
                var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image));
                using var file = File.Create(Path.Combine(outputDirectory, name + ".png")); encoder.Save(file);
                if (name is "dictation" or "shortcuts" or "vocabulary" && Find<ScrollViewer>(tabs) is { } scroll)
                {
                    scroll.ScrollToEnd(); app.Window.UpdateLayout();
                    await app.Window.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Render);
                    var bottom = new RenderTargetBitmap((int)app.Window.ActualWidth, (int)app.Window.ActualHeight, 96, 96, PixelFormats.Pbgra32);
                    bottom.Render(app.Window);
                    var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(bottom));
                    using var bottomFile = File.Create(Path.Combine(outputDirectory, name + "-bottom.png")); png.Save(bottomFile);
                }
            }
            // Exercise real Win32 registration and rollback, not just mocks.
            var original = app.Settings;
            var hwnd = new WindowInteropHelper(app.Window).Handle;
            const int conflictId = 9000;
            if (!Native.RegisterHotKey(hwnd, conflictId, 3 | 0x4000, 0x86))
                throw new InvalidOperationException("Could not reserve the conflict-test shortcut.");
            try
            {
                if (app.SaveSettings(original with { Primary = new Shortcut(3, 0x86) }) || app.Settings != original || !app.HasShortcut)
                    throw new InvalidOperationException("Conflicting shortcut did not preserve the previous binding.");
            }
            finally { Native.UnregisterHotKey(hwnd, conflictId); }
            if (!app.SaveSettings(original with { External = new Shortcut(0, 0x87, TriggerMode.Toggle) }) ||
                !app.SaveSettings(original) || !app.HasShortcut)
                throw new InvalidOperationException("Independent external shortcut lifecycle failed.");
            if (Marshal.SizeOf<Native.INPUT>() != 40) throw new InvalidOperationException("Wrong x64 INPUT layout.");
            var delivery = new TextDelivery();
            app.Window.Activate();
            if (await delivery.CaptureTargetAsync() is not null)
                throw new InvalidOperationException("The app must not target its own settings window.");
            var withheld = await delivery.DeliverAsync("must not be sent", null, CancellationToken.None);
            if (!withheld.StartsWith("Not inserted", StringComparison.Ordinal))
                throw new InvalidOperationException("Unknown target was not rejected.");
            var foreground = Native.GetForegroundWindow();
            var overlay = new OverlayWindow(() => { }, () => { });
            try
            {
                overlay.Update(SessionPhase.Listening, "Listening…"); overlay.SetPreview("This is a live draft. Completed phrases appear in your app when you pause."); overlay.SetLevel(.15f); overlay.SetTime(TimeSpan.FromSeconds(7));
                await overlay.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Render);
                if (Native.GetForegroundWindow() != foreground)
                    throw new InvalidOperationException("Recording overlay stole foreground focus.");
                var bitmap = new RenderTargetBitmap((int)overlay.ActualWidth, (int)overlay.ActualHeight, 96, 96, PixelFormats.Pbgra32);
                bitmap.Render(overlay);
                var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(bitmap));
                using var imageFile = File.Create(Path.Combine(outputDirectory, "recording-overlay.png")); png.Save(imageFile);
            }
            finally { overlay.Close(); }
            await File.WriteAllTextAsync(Path.Combine(outputDirectory, "ui-smoke.json"), JsonSerializer.Serialize(new
            { passed = true, platform = Environment.OSVersion.ToString(), shortcutRegistered = app.HasShortcut,
                conflictRollback = true, externalShortcutLifecycle = true, unsafeTargetRejected = true,
                overlayPreservesFocus = true, inputStructBytes = 40,
                tabs = counts }, new JsonSerializerOptions { WriteIndented = true }));
            Application.Current.Shutdown(0);
        }
        catch (Exception ex)
        {
            Directory.CreateDirectory(outputDirectory);
            await File.WriteAllTextAsync(Path.Combine(outputDirectory, "ui-smoke-error.txt"), ex.ToString());
            Application.Current.Shutdown(1);
        }
    }
    private static T? Find<T>(DependencyObject root) where T : DependencyObject => All<T>(root).FirstOrDefault();
    private static IEnumerable<T> All<T>(DependencyObject root) where T : DependencyObject
    {
        if (root is T match) yield return match;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
            foreach (var child in All<T>(VisualTreeHelper.GetChild(root, i))) yield return child;
    }
}
