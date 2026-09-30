using System.Text.Json;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

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
            foreach (var name in new[] { "settings", "history", "vocabulary" })
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
                if (name == "settings" && Find<ScrollViewer>(tabs) is { } scroll)
                {
                    scroll.ScrollToEnd(); app.Window.UpdateLayout();
                    await app.Window.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Render);
                    var bottom = new RenderTargetBitmap((int)app.Window.ActualWidth, (int)app.Window.ActualHeight, 96, 96, PixelFormats.Pbgra32);
                    bottom.Render(app.Window);
                    var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(bottom));
                    using var bottomFile = File.Create(Path.Combine(outputDirectory, "settings-bottom.png")); png.Save(bottomFile);
                }
            }
            await File.WriteAllTextAsync(Path.Combine(outputDirectory, "ui-smoke.json"), JsonSerializer.Serialize(new
            { passed = true, platform = Environment.OSVersion.ToString(), shortcutRegistered = app.HasShortcut, tabs = counts }, new JsonSerializerOptions { WriteIndented = true }));
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
