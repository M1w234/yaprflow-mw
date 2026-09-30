using System.Windows.Interop;

namespace YaprFlow.Windows;

internal sealed class OverlayWindow : Window
{
    private readonly TextBlock status = new() { Foreground = Brush("#E5F5EF"), FontSize = 13, Width = 250, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock time = new() { Foreground = Brush("#94D9BC"), Width = 48, VerticalAlignment = VerticalAlignment.Center };
    private readonly ProgressBar level = new() { Width = 44, Height = 6, Minimum = 0, Maximum = 1, Margin = new Thickness(8), Foreground = Brush("#94D9BC") };
    private readonly Button finish;
    private readonly Button cancel;
    public OverlayWindow(Action onCancel, Action onFinish)
    {
        Width = 550; Height = 90; WindowStyle = WindowStyle.None; AllowsTransparency = true;
        Background = Brushes.Transparent; Topmost = true; ShowInTaskbar = false; ShowActivated = false;
        ResizeMode = ResizeMode.NoResize; Title = "yaprflow recording";
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        cancel = new Button { Content = "Cancel", Margin = new Thickness(4), Padding = new Thickness(9, 6, 9, 6) };
        finish = new Button { Content = "Finish", Margin = new Thickness(4), Padding = new Thickness(9, 6, 9, 6) };
        cancel.Click += (_, _) => onCancel(); finish.Click += (_, _) => onFinish();
        row.Children.Add(cancel); row.Children.Add(level); row.Children.Add(status); row.Children.Add(time); row.Children.Add(finish);
        Content = new Border { Background = Brush("#182322"), CornerRadius = new CornerRadius(22), Padding = new Thickness(12), Child = row, Margin = new Thickness(4) };
        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            var style = Native.GetWindowLongPtr(hwnd, -20).ToInt64();
            Native.SetWindowLongPtr(hwnd, -20, new IntPtr(style | 0x08000000 | 0x00000080)); // NOACTIVATE | TOOLWINDOW
            HwndSource.FromHwnd(hwnd)?.AddHook(DoNotActivate);
        };
    }
    private static IntPtr DoNotActivate(IntPtr hwnd, int message, IntPtr w, IntPtr l, ref bool handled)
    {
        if (message == 0x0021) { handled = true; return new IntPtr(3); } // MA_NOACTIVATE
        return IntPtr.Zero;
    }
    public void Update(SessionPhase phase, string text)
    {
        if (phase == SessionPhase.Idle) { Hide(); return; }
        status.Text = text;
        finish.IsEnabled = phase == SessionPhase.Listening;
        cancel.IsEnabled = phase != SessionPhase.Canceling;
        if (!IsVisible)
        {
            var area = SystemParameters.WorkArea;
            Left = area.Left + (area.Width - Width) / 2;
            Top = area.Bottom - Height - 24;
            Show();
        }
    }
    public void SetLevel(float value) => level.Value = Math.Clamp(value * 4, 0, 1);
    public void SetTime(TimeSpan elapsed) => time.Text = $"{(int)elapsed.TotalMinutes}:{elapsed.Seconds:00}";
    private static SolidColorBrush Brush(string color) => new((Color)ColorConverter.ConvertFromString(color));
}
