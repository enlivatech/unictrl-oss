using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;
using CanvasRect = Windows.Foundation.Rect;

namespace Unictrl;

public sealed partial class MainWindow : Window
{
    private readonly Settings settings = Settings.Load();
    private readonly Tray tray;
    private Receiver? receiver;
    private bool quitting;
    private bool startsAtLogin;
    private bool connected;

    public MainWindow()
    {
        InitializeComponent();
        var icon = Path.Combine(AppContext.BaseDirectory, "Assets", "Unictrl.ico");
        AppWindow.SetIcon(icon);
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        TitleIcon.Source = new BitmapImage(new Uri(icon));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsMaximizable = false;
            presenter.PreferredMinimumWidth = (int)(520 * GetDpiScale());
            presenter.PreferredMinimumHeight = (int)(480 * GetDpiScale());
        }
        var scale = GetDpiScale();
        // The size the user left it at, else the default size.
        var (width, height) = settings.WindowWidth >= 520 && settings.WindowHeight >= 480
            ? (settings.WindowWidth, settings.WindowHeight) : (801.0, 748.0);
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(width * scale), (int)(height * scale)));
        AppWindow.Changed += (_, change) => { if (change.DidSizeChange) RememberSize(); };

        EnabledSwitch.IsOn = settings.Enabled;
        KeyboardBox.SelectedIndex = settings.KeyboardProfile == "mac-positions" ? 1 : 0;
        ShowKeyboardDetail();
        RestoreDetails();
        StartAtLoginSwitch.IsOn = settings.StartAtLogin;
        AboutText.Text = $"Unictrl {typeof(App).Assembly.GetName().Version?.ToString(3)} · This PC: {Environment.MachineName}";
        ShowPairing(string.IsNullOrEmpty(settings.PairingKey));
        UpdateDetail();
        RenderScreens();

        tray = new Tray(Path.Combine(AppContext.BaseDirectory, "Assets", "UnictrlTray.ico"), settings.ShowTrayIcon);
        TraySwitch.IsOn = settings.ShowTrayIcon;
        TaskbarSwitch.IsOn = settings.ShowInTaskbar;
        Task.Run(StartMenuShortcut.Ensure);
        tray.IsEnabled = () => settings.Enabled;
        tray.StartsAtLogin = () => startsAtLogin;
        tray.OpenRequested += () => DispatcherQueue.TryEnqueue(ShowWindow);
        tray.EnabledToggled += () => DispatcherQueue.TryEnqueue(() => EnabledSwitch.IsOn = !EnabledSwitch.IsOn);
        tray.StartAtLoginToggled += () => DispatcherQueue.TryEnqueue(() => StartAtLoginSwitch.IsOn = !startsAtLogin);
        tray.QuitRequested += () => DispatcherQueue.TryEnqueue(Quit);
        // Closing the window keeps Unictrl running in the notification area; Quit is in the tray menu.
        // With the taskbar icon on, closing minimizes to the taskbar; otherwise it hides (reopen from
        // the notification area or by launching Unictrl again).
        AppWindow.Closing += (_, e) =>
        {
            if (quitting) return;
            e.Cancel = true;
            if (settings.ShowInTaskbar && AppWindow.Presenter is OverlappedPresenter overlapped) overlapped.Minimize();
            else AppWindow.Hide();
        };
        Closed += (_, _) => { receiver?.Dispose(); tray.Dispose(); };

        if (settings.Enabled) StartReceiver(); else SetStatus("Paused");
        Task.Run(() =>
        {
            startsAtLogin = AutoStart.IsEnabled();
            if (settings.StartAtLogin && !startsAtLogin) SetStartAtLogin(true);
            DispatcherQueue.TryEnqueue(() => StartAtLoginSwitch.IsOn = startsAtLogin);
        });
    }

    private CancellationTokenSource? sizeSave;

    /// Saves the window size a moment after the user stops resizing.
    private void RememberSize()
    {
        if (!AppWindow.IsVisible) return;
        sizeSave?.Cancel();
        var pending = sizeSave = new CancellationTokenSource();
        var scale = GetDpiScale();
        var size = AppWindow.Size;
        _ = Task.Delay(600, pending.Token).ContinueWith(t =>
        {
            if (t.IsCanceled) return;
            settings.WindowWidth = Math.Round(size.Width / scale);
            settings.WindowHeight = Math.Round(size.Height / scale);
            settings.Save();
        }, TaskScheduler.Default);
    }

    /// Started at login: stay out of the way, but keep the taskbar button if the user wants one.
    public void StartInBackground()
    {
        if (!settings.ShowInTaskbar || AppWindow.Presenter is not OverlappedPresenter overlapped) return;
        AppWindow.Show(false);
        overlapped.Minimize(false);
    }

    private void OnTrayToggled(object sender, RoutedEventArgs e)
    {
        if (settings.ShowTrayIcon == TraySwitch.IsOn) return;
        settings.ShowTrayIcon = TraySwitch.IsOn;
        settings.Save();
        tray.SetVisible(settings.ShowTrayIcon);
    }

    private void OnTaskbarToggled(object sender, RoutedEventArgs e)
    {
        if (settings.ShowInTaskbar == TaskbarSwitch.IsOn) return;
        settings.ShowInTaskbar = TaskbarSwitch.IsOn;
        settings.Save();
    }

    private void ShowWindow()
    {
        AppWindow.Show();
        Activate();
    }

    private void SetStartAtLogin(bool on)
    {
        var ok = on ? AutoStart.Enable() : AutoStart.Disable();
        if (ok) startsAtLogin = on;
        settings.StartAtLogin = startsAtLogin;
        settings.Save();
    }

    private void OnStartAtLoginToggled(object sender, RoutedEventArgs e)
    {
        var on = StartAtLoginSwitch.IsOn;
        if (on == startsAtLogin) return;
        Task.Run(() =>
        {
            SetStartAtLogin(on);
            DispatcherQueue.TryEnqueue(() => StartAtLoginSwitch.IsOn = startsAtLogin);
        });
    }

    private void OnKeyboardChanged(object sender, SelectionChangedEventArgs e)
    {
        if (KeyboardBox.SelectedItem is not ComboBoxItem { Tag: string profile } || profile == settings.KeyboardProfile) return;
        settings.KeyboardProfile = profile; // the injector reads it for each key
        settings.Save();
        ShowKeyboardDetail();
        Log.Write("keyboard_profile", profile);
    }

    /// What the Mac keyboard's modifier keys do here. "Windows layout" puts the keys where a Windows
    /// keyboard has them (and where dual-labelled keyboards print the Windows names).
    private void ShowKeyboardDetail() =>
        KeyboardDetail.Text = settings.KeyboardProfile == "mac-positions"
            ? "⌘ acts as the Windows key and ⌥ as Alt."
            : "⌥ acts as the Windows key, ⌘ as Alt and the right ⌥ as Ctrl, as on a Windows keyboard.";

    private void Quit()
    {
        quitting = true;
        CursorHider.Show("quit");
        receiver?.Dispose();
        tray.Dispose();
        Application.Current.Exit();
    }

    // MARK: Status

    private void UpdateDetail()
    {
        var mac = string.IsNullOrEmpty(settings.MacName) ? settings.MacAddress : settings.MacName;
        if (string.IsNullOrEmpty(settings.PairingKey))
        {
            DetailText.Text = "Pair with your Mac to use its keyboard and mouse here.";
            PairTitle.Text = "Not paired";
            PairDetail.Text = "Enter the code your Mac shows";
        }
        else
        {
            DetailText.Text = connected ? $"Use the Mac's keyboard and mouse by moving the pointer across to this PC."
                : settings.Enabled ? $"Waiting for {mac} on the local network." : "Turned off on this PC.";
            PairTitle.Text = mac;
            PairDetail.Text = string.IsNullOrEmpty(settings.MacAddress) ? "Paired" : $"Paired · {settings.MacAddress}";
        }
        StatusBadge.Background = connected ? (Brush)Application.Current.Resources["PineGradientBrush"]
            : (Brush)Application.Current.Resources["ControlAltFillColorQuarternaryBrush"];
        StatusGlyph.Foreground = connected ? new SolidColorBrush(Microsoft.UI.Colors.White)
            : (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
    }

    private void SetStatus(string text)
    {
        tray.SetTooltip($"Unictrl · {text}");
        DispatcherQueue.TryEnqueue(() =>
        {
            StatusText.Text = text;
            connected = text.StartsWith("Connected", StringComparison.Ordinal);
            UpdateDetail();
        });
    }

    private void OnEnabledToggled(object sender, RoutedEventArgs e)
    {
        if (settings.Enabled == EnabledSwitch.IsOn) return;
        settings.Enabled = EnabledSwitch.IsOn;
        settings.Save();
        receiver?.Dispose();
        receiver = null;
        arrangement = null;
        RenderScreens();
        ShowQuality(null);
        if (settings.Enabled) StartReceiver(); else SetStatus("Paused");
    }

    private void StartReceiver(Action? onConnected = null)
    {
        if (string.IsNullOrEmpty(settings.PairingKey))
        {
            SetStatus("Not paired yet");
            return;
        }
        var next = new Receiver(settings, SetStatus);
        next.MacChanged += () => DispatcherQueue.TryEnqueue(UpdateDetail);
        next.ArrangementChanged += info => DispatcherQueue.TryEnqueue(() =>
        {
            if (receiver != next) return;
            arrangement = info;
            RenderScreens();
            ShowNames();
        });
        next.QualityChanged += info => DispatcherQueue.TryEnqueue(() =>
        {
            if (receiver == next) ShowQuality(info);
        });
        if (onConnected is not null) next.Connected += onConnected;
        receiver = next;
        next.Start();
    }

    // MARK: Connection quality

    private List<TipInfo>? shownTips;
    private readonly List<(DateTime At, double Ms)> rttHistory = [];
    private readonly List<(DateTime At, string Source)> hitchHistory = [];
    private static readonly TimeSpan GraphWindow = TimeSpan.FromSeconds(60);

    /// Opens Details and tips as the user left it, then remembers each change.
    private void RestoreDetails()
    {
        DetailsExpander.IsExpanded = settings.ShowConnectionDetails;
        DetailsExpander.RegisterPropertyChangedCallback(Expander.IsExpandedProperty, (_, _) =>
        {
            if (settings.ShowConnectionDetails == DetailsExpander.IsExpanded) return;
            settings.ShowConnectionDetails = DetailsExpander.IsExpanded;
            settings.Save();
        });
    }

    private void OnRttCanvasSizeChanged(object sender, SizeChangedEventArgs e) => DrawRtt();

    /// Round trips as a line, hitches as ticks along the bottom, the last minute left to right; like the Mac's.
    private void DrawRtt()
    {
        RttCanvas.Children.Clear();
        var width = RttCanvas.ActualWidth;
        var height = RttCanvas.ActualHeight;
        if (width <= 0 || height <= 0) return;
        var resources = Application.Current.Resources;
        var now = DateTime.UtcNow;
        const double gutter = 38, tick = 8;
        double plotTop = 2, plotBottom = height - tick - 6, plotWidth = width - gutter;
        var top = Math.Max(20, rttHistory.Count == 0 ? 0 : rttHistory.Max(r => r.Ms) * 1.15);
        double X(DateTime at) => width - (now - at).TotalSeconds / GraphWindow.TotalSeconds * plotWidth;
        double Y(double ms) => plotBottom - Math.Min(ms, top) / top * (plotBottom - plotTop);
        var secondary = (Brush)resources["TextFillColorSecondaryBrush"];

        RttCanvas.Children.Add(new Microsoft.UI.Xaml.Shapes.Line
        {
            X1 = gutter, X2 = width, Y1 = Y(10), Y2 = Y(10), Stroke = secondary, StrokeThickness = 0.5, Opacity = 0.5,
            StrokeDashArray = [3, 3],
        });
        var label = new TextBlock { Text = "10 ms", FontSize = 10, Foreground = secondary, Width = gutter - 6, TextAlignment = TextAlignment.Right };
        Canvas.SetTop(label, Y(10) - 7);
        RttCanvas.Children.Add(label);

        var pine = Windows.UI.Color.FromArgb(255, 0x26, 0x95, 0x7F);
        if (rttHistory.Count > 1)
        {
            var line = new Microsoft.UI.Xaml.Shapes.Polyline { Stroke = new SolidColorBrush(pine), StrokeThickness = 1.3 };
            var area = new Microsoft.UI.Xaml.Shapes.Polygon { Fill = new SolidColorBrush(Windows.UI.Color.FromArgb(40, pine.R, pine.G, pine.B)) };
            area.Points.Add(new Point(X(rttHistory[0].At), plotBottom));
            foreach (var (at, ms) in rttHistory)
            {
                var point = new Point(X(at), Y(ms));
                line.Points.Add(point);
                area.Points.Add(point);
            }
            area.Points.Add(new Point(X(rttHistory[^1].At), plotBottom));
            RttCanvas.Children.Add(area);
            RttCanvas.Children.Add(line);
        }
        RttCanvas.Children.Add(new Microsoft.UI.Xaml.Shapes.Line
        {
            X1 = gutter, X2 = width, Y1 = height - tick / 2, Y2 = height - tick / 2, Stroke = secondary, StrokeThickness = 0.5, Opacity = 0.4,
        });
        foreach (var (at, source) in hitchHistory)
        {
            var x = X(at);
            if (x < gutter) continue;
            var mark = new Microsoft.UI.Xaml.Shapes.Rectangle { Width = 2, Height = tick, RadiusX = 1, RadiusY = 1, Fill = new SolidColorBrush(HitchColor(source)) };
            Canvas.SetLeft(mark, x - 1);
            Canvas.SetTop(mark, height - tick);
            RttCanvas.Children.Add(mark);
        }
    }

    /// The Mac's colours for where a hitch came from.
    private static Windows.UI.Color HitchColor(string source) => source switch
    {
        "mouse" => Windows.UI.Color.FromArgb(255, 0xAF, 0x52, 0xDE),
        "mac" => Windows.UI.Color.FromArgb(255, 0x00, 0x7A, 0xFF),
        "network" => Windows.UI.Color.FromArgb(255, 0xFF, 0x95, 0x00),
        _ => Windows.UI.Color.FromArgb(255, 0xFF, 0x2D, 0x55),
    };

    private void ShowQuality(QualityInfo? info)
    {
        ConnectionSection.Visibility = info is null ? Visibility.Collapsed : Visibility.Visible;
        if (info is null)
        {
            shownTips = null;
            TipsPanel.Children.Clear();
            rttHistory.Clear();
            hitchHistory.Clear();
            return;
        }
        var now = DateTime.UtcNow;
        if (info.RttMs is { } current) rttHistory.Add((now, current));
        foreach (var source in info.RecentHitches ?? []) hitchHistory.Add((now, source));
        rttHistory.RemoveAll(r => now - r.At > GraphWindow);
        hitchHistory.RemoveAll(h => now - h.At > GraphWindow);
        GradePeer.Text = string.IsNullOrEmpty(settings.MacName) ? "" : settings.MacName;
        DrawRtt();
        var resources = Application.Current.Resources;
        (GradeText.Text, GradeDot.Fill) = info.Grade switch
        {
            "smooth" => ("Smooth", (Brush)resources["SystemFillColorSuccessBrush"]),
            "fair" => ("Some hitches", (Brush)resources["SystemFillColorCautionBrush"]),
            "poor" => ("Choppy", (Brush)resources["SystemFillColorCriticalBrush"]),
            _ => ("Waiting for movement", (Brush)resources["TextFillColorTertiaryBrush"]),
        };
        RttText.Text = info.RttMs is { } rtt ? $"{rtt:F0} ms" : "";
        RttPeakText.Text = info.RttP95Ms is { } peak ? $"peak {peak:F0} ms" : "";
        var rates = info.HitchesPerMin;
        static string Rate(double value) => value == 0 ? "0" : $"{value:F1}";
        HitchText.Text = info.MovingSeconds < 3 || rates is null
            ? "Move the pointer here for a while to measure hitches."
            : $"Hitches per minute of movement, by where they came from: mouse {Rate(rates.Mouse)} · Mac {Rate(rates.Mac)} · network {Rate(rates.Network)} · this PC {Rate(rates.Pc)}";
        // Rebuild the list only when the Mac sent a new one, so open items stay open.
        if (!ReferenceEquals(info.Tips, shownTips))
        {
            shownTips = info.Tips;
            RenderTips(info.Tips ?? []);
            var todo = (info.Tips ?? []).Count(t => t.Status == "act");
            SuggestionBadge.Visibility = todo > 0 ? Visibility.Visible : Visibility.Collapsed;
            SuggestionText.Text = todo == 1 ? "1 suggestion" : $"{todo} suggestions";
        }
    }

    private void RenderTips(List<TipInfo> tips)
    {
        TipsPanel.Children.Clear();
        foreach (var tip in tips.Where(t => t.Status != "ok")) TipsPanel.Children.Add(TipItem(tip));
        var passed = tips.Where(t => t.Status == "ok").ToList();
        if (passed.Count == 0) return;
        var list = new StackPanel { Spacing = 4 };
        foreach (var tip in passed) list.Children.Add(TipItem(tip));
        TipsPanel.Children.Add(new Expander
        {
            Header = new TextBlock { Text = $"{passed.Count} checks passed", Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] },
            Content = list, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
        });
    }

    /// A checklist item: hover for why it matters, open for what Unictrl saw and how to do it.
    private static Expander TipItem(TipInfo tip)
    {
        var resources = Application.Current.Resources;
        var (glyph, brush) = tip.Status switch
        {
            "act" => ("\uE7BA", (Brush)resources["SystemFillColorCautionBrush"]),
            "ok" => ("\uE73E", (Brush)resources["SystemFillColorSuccessBrush"]),
            _ => ("\uE82F", (Brush)resources["TextFillColorSecondaryBrush"]),
        };
        var header = new Grid { ColumnSpacing = 12 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.Children.Add(new FontIcon { Glyph = glyph, FontSize = 16, Foreground = brush, VerticalAlignment = VerticalAlignment.Center });
        var titles = new StackPanel { Spacing = 1 };
        titles.Children.Add(new TextBlock { Text = tip.Title, TextWrapping = TextWrapping.Wrap });
        titles.Children.Add(new TextBlock
        {
            Text = tip.Summary, Style = (Style)resources["CaptionTextBlockStyle"], Foreground = (Brush)resources["TextFillColorSecondaryBrush"],
            TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1,
        });
        Grid.SetColumn(titles, 1);
        header.Children.Add(titles);
        ToolTipService.SetToolTip(header, tip.Summary);

        var body = new StackPanel { Spacing = 10, Padding = new Thickness(28, 2, 0, 4) };
        body.Children.Add(new TextBlock { Text = tip.Summary, TextWrapping = TextWrapping.Wrap });
        if (!string.IsNullOrEmpty(tip.Seen))
        {
            body.Children.Add(new Border
            {
                Background = (Brush)resources["LayerOnMicaBaseAltFillColorDefaultBrush"], CornerRadius = new CornerRadius(4), Padding = new Thickness(10, 6, 10, 6),
                Child = new TextBlock { Text = tip.Seen, TextWrapping = TextWrapping.Wrap, Style = (Style)resources["CaptionTextBlockStyle"] },
            });
        }
        if (!(tip.Steps.Count == 1 && tip.Steps[0] == "Nothing to do."))
        {
            body.Children.Add(new TextBlock
            {
                Text = tip.Status == "ok" ? "Already done. For reference:" : "How to", Style = (Style)resources["BodyStrongTextBlockStyle"],
            });
            for (var i = 0; i < tip.Steps.Count; i++)
                body.Children.Add(new TextBlock { Text = $"{i + 1}.  {tip.Steps[i]}", TextWrapping = TextWrapping.Wrap });
        }
        return new Expander
        {
            Header = header, Content = body, IsExpanded = false,
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
    }

    // MARK: Pairing

    private void ShowPairing(bool show)
    {
        PairPanel.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        PairAgainButton.Visibility = show ? Visibility.Collapsed : Visibility.Visible;
        CancelPairButton.Visibility = string.IsNullOrEmpty(settings.PairingKey) ? Visibility.Collapsed : Visibility.Visible;
        if (show) CodeBox.Focus(FocusState.Programmatic);
    }

    private void OnPairAgain(object sender, RoutedEventArgs e)
    {
        PairStatus.Text = "";
        CodeBox.Text = "";
        ShowPairing(true);
    }

    private void OnCancelPair(object sender, RoutedEventArgs e) => ShowPairing(false);

    private void OnCodeKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter) OnPairClicked(sender, e);
    }

    private async void OnPairClicked(object sender, RoutedEventArgs e)
    {
        var code = new string(CodeBox.Text.Where(char.IsDigit).ToArray());
        if (code.Length != 6)
        {
            PairStatus.Text = "Enter the 6 digits shown on the Mac.";
            return;
        }
        PairButton.IsEnabled = false;
        PairStatus.Text = "Looking for your Mac…";
        var (result, mac) = await Task.Run(() => Pair(code));
        PairButton.IsEnabled = true;
        switch (result.Outcome)
        {
            case PairingClient.Outcome.Paired when mac is not null:
                settings.PairingKey = result.PairingKey!;
                settings.MacId = result.MacId ?? mac.Id;
                settings.MacName = mac.Name;
                settings.MacAddress = mac.Address;
                settings.Port = mac.Port;
                settings.Save();
                Log.Write("paired", $"mac={settings.MacId}");
                // Hand over without a gap: the old session keeps running until the new key's session is up.
                var previous = receiver;
                receiver = null;
                if (settings.Enabled && previous is not null)
                {
                    StartReceiver(onConnected: () => previous.Dispose());
                    _ = Task.Delay(10_000).ContinueWith(_ => previous.Dispose());
                }
                else
                {
                    previous?.Dispose();
                    if (settings.Enabled) StartReceiver();
                }
                UpdateDetail();
                ShowPairing(false);
                break;
            case PairingClient.Outcome.WrongCode:
                PairStatus.Text = "That code didn't match. Check the code on the Mac and try again.";
                break;
            case PairingClient.Outcome.NotPairing:
                PairStatus.Text = "Your Mac isn't showing a code. On the Mac, choose Pair a Windows PC… first.";
                break;
            default:
                PairStatus.Text = "No Mac with Unictrl found on this network. Check that both are on the same network.";
                break;
        }
    }

    /// Tries each Mac that answers discovery (and the last known address) until one accepts the code.
    private (PairingClient.Result, Discovery.Mac?) Pair(string code)
    {
        var macs = Discovery.Find(TimeSpan.FromMilliseconds(1500));
        if (!string.IsNullOrWhiteSpace(settings.MacAddress) && macs.All(m => m.Address != settings.MacAddress))
            macs.Add(new Discovery.Mac(settings.MacId, settings.MacName, settings.MacAddress, settings.Port));
        var last = new PairingClient.Result(PairingClient.Outcome.Unreachable);
        foreach (var mac in macs)
        {
            var result = PairingClient.Pair(mac.Address, mac.Port, code, settings.DeviceIdBytes);
            if (result.Outcome is PairingClient.Outcome.Paired or PairingClient.Outcome.WrongCode) return (result, mac);
            if (result.Outcome == PairingClient.Outcome.NotPairing) last = result;
        }
        return (last, null);
    }

    private double GetDpiScale() =>
        Native.GetDpiForMonitor(Native.MonitorFromPoint(new Native.Point(0, 0), 1), 0, out var dpi, out _) == 0
            ? dpi / 96.0 : 1.0;

    // MARK: Screens

    private ArrangementInfo? arrangement;
    private List<(ScreenInfo Screen, CanvasRect Rect)> frames = [];
    private double mmScale = 1;
    private string? draggingId;
    private Point dragStart;
    private FrameworkElement? draggingTile;

    private void OnCanvasSizeChanged(object sender, SizeChangedEventArgs e) => RenderScreens();

    /// The two-dimensional screen layout at its physical sizes.
    private void RenderScreens()
    {
        ScreensCanvas.Children.Clear();
        frames = [];
        var screens = arrangement?.Screens ?? [];
        ScreensPlaceholder.Visibility = screens.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        var width = ScreensCanvas.ActualWidth;
        var height = ScreensCanvas.ActualHeight;
        if (screens.Count == 0 || width <= 0 || height <= 0) return;

        var rectangles = arrangement!.Rectangles();
        var mm = screens.Select(screen => (screen, rectangles[screen.Id])).ToList();
        var left = mm.Min(m => m.Item2.X);
        var right = mm.Max(m => m.Item2.Right);
        var top = mm.Min(m => m.Item2.Y);
        var bottom = mm.Max(m => m.Item2.Bottom);
        const double padding = 14;
        mmScale = Math.Max(0.01, Math.Min((width - 2 * padding) / (right - left), (height - 2 * padding) / Math.Max(bottom - top, 200)));
        var originX = (width - (right - left) * mmScale) / 2 - left * mmScale;
        var originY = (height - (bottom - top) * mmScale) / 2 - top * mmScale;
        ScreensHint.Text = arrangement.Supports2D ? "Drag any screen to a shared edge; right-click to choose a position." : "Update the Mac app to arrange screens above or below.";
        foreach (var (screen, rect) in mm)
        {
            var r = new CanvasRect(originX + rect.X * mmScale, originY + rect.Y * mmScale, rect.Width * mmScale, rect.Height * mmScale);
            frames.Add((screen, r));
            ScreensCanvas.Children.Add(Tile(screen, r));
        }
    }

    private FrameworkElement Tile(ScreenInfo screen, CanvasRect rect)
    {
        var mine = screen.Id == arrangement?.You;
        var green = mine || screen.Online;
        var resources = Application.Current.Resources;
        Brush foreground = mine ? new SolidColorBrush(Microsoft.UI.Colors.White)
            : screen.Online ? new SolidColorBrush(Windows.UI.Color.FromArgb(255, 0x0B, 0x4A, 0x40)) // pine ink
            : (Brush)resources["TextFillColorPrimaryBrush"];
        var content = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Spacing = 2 };
        content.Children.Add(new FontIcon { Glyph = screen.IsMac ? "" : "", FontSize = 18, Foreground = foreground, Margin = new Thickness(0, 0, 0, 4) });
        content.Children.Add(new TextBlock
        {
            Text = screen.Name, FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = foreground,
            TextTrimming = TextTrimming.CharacterEllipsis, HorizontalAlignment = HorizontalAlignment.Center, MaxWidth = rect.Width - 12,
        });
        content.Children.Add(new TextBlock
        {
            Text = mine ? "This PC" : screen.Online ? $"{screen.WidthMm / 10:F0} × {screen.HeightMm / 10:F0} cm" : "Offline",
            FontSize = 11, Foreground = foreground, Opacity = 0.75, HorizontalAlignment = HorizontalAlignment.Center,
        });
        var tile = new Border
        {
            Width = Math.Max(0, rect.Width - 3), Height = Math.Max(0, rect.Height - 3), CornerRadius = new CornerRadius(6),
            Background = mine ? (Brush)resources["PineGradientBrush"]
                : screen.Online ? (Brush)resources["PineLightGradientBrush"] : (Brush)resources["CardBackgroundFillColorDefaultBrush"],
            BorderBrush = (Brush)resources["CardStrokeColorDefaultBrush"], BorderThickness = new Thickness(1),
            Opacity = screen.Online || mine ? 1 : 0.55, Child = content, Tag = screen.Id,
            Shadow = new ThemeShadow(), Translation = new System.Numerics.Vector3(0, 0, 4),
        };
        Canvas.SetLeft(tile, rect.X + 1.5);
        Canvas.SetTop(tile, rect.Y + 1.5);
        if (arrangement?.Supports2D == true)
        {
            tile.PointerPressed += OnTilePressed;
            tile.PointerMoved += OnTileMoved;
            tile.PointerReleased += OnTileReleased;
            tile.PointerCaptureLost += (_, _) => { if (draggingId is not null) { draggingId = null; RenderScreens(); } };
            tile.PointerEntered += (s, _) => ((UIElement)s).ProtectedCursor(InputSystemCursorShape.SizeAll);
        }
        var rename = new MenuFlyoutItem { Text = "Rename…", Icon = new FontIcon { Glyph = "\uE8AC" } };
        rename.Click += (_, _) => RenameScreen(screen);
        var menu = new MenuFlyout { Items = { rename } };
        if (!screen.IsMac && arrangement?.Supports2D == true)
        {
            foreach (var (title, side) in new[] { ("Windows above Mac", ScreenEdge.Top), ("Windows below Mac", ScreenEdge.Bottom),
                ("Windows left of Mac", ScreenEdge.Left), ("Windows right of Mac", ScreenEdge.Right) })
            {
                var item = new MenuFlyoutItem { Text = title };
                item.Click += (_, _) => { if (arrangement is not null) CommitLayout(arrangement.Place(screen.Id, side)); };
                menu.Items.Add(item);
            }
        }
        tile.ContextFlyout = menu;
        return tile;
    }

    private void OnTilePressed(object sender, PointerRoutedEventArgs e)
    {
        if (sender is not FrameworkElement tile || tile.Tag is not string id) return;
        if (!e.GetCurrentPoint(tile).Properties.IsLeftButtonPressed) return; // right-click opens the menu
        draggingId = id;
        draggingTile = tile;
        dragStart = e.GetCurrentPoint(ScreensCanvas).Position;
        tile.CapturePointer(e.Pointer);
        Canvas.SetZIndex(tile, 1);
        tile.Translation = new System.Numerics.Vector3(0, 0, 24);
        e.Handled = true;
    }

    private void OnTileMoved(object sender, PointerRoutedEventArgs e)
    {
        if (draggingId is null || draggingTile is null) return;
        var frame = frames.First(f => f.Screen.Id == draggingId).Rect;
        var at = e.GetCurrentPoint(ScreensCanvas).Position;
        Canvas.SetLeft(draggingTile, frame.X + 1.5 + at.X - dragStart.X);
        Canvas.SetTop(draggingTile, frame.Y + 1.5 + at.Y - dragStart.Y);
    }

    private void OnTileReleased(object sender, PointerRoutedEventArgs e)
    {
        if (draggingId is null || arrangement is null) return;
        var id = draggingId;
        draggingId = null;
        (sender as UIElement)?.ReleasePointerCaptures();
        var at = e.GetCurrentPoint(ScreensCanvas).Position;
        Drop(id, at.X - dragStart.X, at.Y - dragStart.Y);
    }

    /// Asks for a new name; the Mac saves it and every screen shows it.
    private async void RenameScreen(ScreenInfo screen)
    {
        var box = new TextBox { Text = screen.Name, PlaceholderText = "The computer's own name", MaxLength = 40 };
        box.SelectAll();
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = screen.IsMac ? "Rename your Mac" : screen.Id == arrangement?.You ? "Rename this PC" : $"Rename {screen.Name}",
            Content = new StackPanel
            {
                Spacing = 8,
                Children =
                {
                    box,
                    new TextBlock
                    {
                        Text = "Shown on the Mac and on every PC. Leave empty for the computer's own name.",
                        TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                    },
                },
            },
            PrimaryButtonText = "Rename",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        receiver?.Rename(screen.Id, box.Text.Trim());
        Log.Write("rename_requested", screen.IsMac ? "mac" : screen.Id[..Math.Min(8, screen.Id.Length)]);
    }

    /// Names follow the Mac's arrangement: the Mac's name in the status and pairing card, this PC's below.
    private void ShowNames()
    {
        if (arrangement is null) return;
        var mac = arrangement.Screens.FirstOrDefault(s => s.IsMac)?.Name;
        if (!string.IsNullOrEmpty(mac) && mac != settings.MacName)
        {
            settings.MacName = mac;
            settings.Save();
        }
        if (connected && !string.IsNullOrEmpty(mac)) StatusText.Text = $"Connected to {mac}";
        var me = arrangement.Screens.FirstOrDefault(s => s.Id == arrangement.You)?.Name ?? Environment.MachineName;
        AboutText.Text = $"Unictrl {typeof(App).Assembly.GetName().Version?.ToString(3)} · This PC: {me}";
        UpdateDetail();
    }

    /// Reorders by where the screen was dropped and keeps it sharing enough edge with its neighbours;
    /// shows the result at once and sends it to the Mac, which answers with what it saved.
    private void Drop(string id, double dx, double dy)
    {
        if (arrangement is null) return;
        var rect = arrangement.Rectangles()[id];
        CommitLayout(arrangement.Drop(id, rect.CenterX + dx / mmScale, rect.CenterY + dy / mmScale));
    }

    private void CommitLayout(ArrangementInfo next)
    {
        arrangement = next;
        RenderScreens();
        var offsets = next.Screens.Where(s => !s.IsMac).ToDictionary(s => s.Id, s => s.YMm ?? s.OffsetMm);
        var positions = next.Screens.Where(s => !s.IsMac).ToDictionary(s => s.Id, s => new ScreenPosition(s.XMm ?? 0, s.YMm ?? s.OffsetMm));
        receiver?.EditArrangement(next.Screens.Select(s => s.Id), offsets, positions);
        Log.Write("arrangement_edit", "2D");
    }
}

internal static class CursorExtensions
{
    /// UIElement.ProtectedCursor is protected; set it by reflection so a plain Border can show the move cursor.
    public static void ProtectedCursor(this UIElement element, InputSystemCursorShape shape) =>
        typeof(UIElement).GetProperty("ProtectedCursor", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)
            ?.SetValue(element, InputSystemCursor.Create(shape));
}
