using System.Windows.Interop;

namespace YaprFlow.Windows;

internal sealed class OverlayWindow : Window
{
    private readonly TextBlock status = new() { Foreground = Brush("#E5F5EF"), FontSize = 13, Width = 230, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock time = new() { Foreground = Brush("#94D9BC"), Width = 48, VerticalAlignment = VerticalAlignment.Center };
    private readonly ProgressBar level = new() { Width = 44, Height = 6, Minimum = 0, Maximum = 1, Margin = new Thickness(8), Foreground = Brush("#94D9BC") };
    private readonly TextBlock preview = new() { Foreground = Brush("#E5F5EF"), FontSize = 16, TextWrapping = TextWrapping.Wrap, MaxHeight = 130, Margin = new Thickness(8, 14, 8, 8), Visibility = Visibility.Collapsed };
    private readonly Button finish;
    private readonly Button cancel;
    public OverlayWindow(Action onCancel, Action onFinish)
    {
        Width = 550; SizeToContent = SizeToContent.Height; MinHeight = 76; WindowStyle = WindowStyle.None; AllowsTransparency = true;
        Background = Brushes.Transparent; Topmost = true; ShowInTaskbar = false; ShowActivated = false;
        ResizeMode = ResizeMode.NoResize; Title = "yaprflow recording";
        Resources.Add(typeof(Button), System.Windows.Markup.XamlReader.Parse("""
            <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button">
              <Setter Property="Foreground" Value="#E5F5EF"/><Setter Property="Background" Value="#2C403A"/>
              <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
                <Border Name="b" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center"/></Border>
                <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#3C594B"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger></ControlTemplate.Triggers>
              </ControlTemplate></Setter.Value></Setter>
            </Style>
            """));
        SizeChanged += (_, _) => { if (IsVisible) Top = SystemParameters.WorkArea.Bottom - ActualHeight - 24; };
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        // Mouse actions must not move keyboard focus out of the target field.
        // Keyboard equivalents remain Escape, the dictation shortcut, and tray commands.
        cancel = new Button { Content = "Cancel", Focusable = false, Margin = new Thickness(4), Padding = new Thickness(9, 6, 9, 6) };
        finish = new Button { Content = "Finish", Focusable = false, Margin = new Thickness(4), Padding = new Thickness(9, 6, 9, 6) };
        cancel.Click += (_, _) => onCancel(); finish.Click += (_, _) => onFinish();
        row.Children.Add(cancel); row.Children.Add(level); row.Children.Add(status); row.Children.Add(time); row.Children.Add(finish);
        var content = new StackPanel(); content.Children.Add(row); content.Children.Add(preview);
        Content = new Border { Background = Brush("#182322"), CornerRadius = new CornerRadius(14), Padding = new Thickness(12), Child = content, Margin = new Thickness(4) };
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
            Top = area.Bottom - Math.Max(76, ActualHeight) - 24;
            Show();
        }
    }
    public void SetPreview(string text)
    {
        preview.Text = (text.Length > 350 ? "…" + text[^350..] : text);
        preview.Visibility = string.IsNullOrWhiteSpace(text) ? Visibility.Collapsed : Visibility.Visible;
        UpdateLayout();
        if (IsVisible) Top = SystemParameters.WorkArea.Bottom - ActualHeight - 24;
    }
    public void SetLevel(float value) => level.Value = Math.Clamp(value * 4, 0, 1);
    public void SetTime(TimeSpan elapsed) => time.Text = $"{(int)elapsed.TotalMinutes}:{elapsed.Seconds:00}";
    private static SolidColorBrush Brush(string color) => new((Color)ColorConverter.ConvertFromString(color));
}
