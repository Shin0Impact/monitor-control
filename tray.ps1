# tray.ps1 - Display modes: a system tray app for switching between desktop / TV / all screens.
# Start it with tray.vbs (no window). Settings live in config.json (edited by the Settings window here).
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# DPI aware (per monitor): menu text stays sharp and the screen capture behind the menu lines up with it.
# This has to happen before any window is created.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DpiAware {
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    public static void Enable() {
        try { if (!SetProcessDpiAwarenessContext(new IntPtr(-4))) SetProcessDPIAware(); }
        catch (Exception) { try { SetProcessDPIAware(); } catch (Exception) { } }
    }
}
'@
[DpiAware]::Enable()
[System.Windows.Forms.Application]::EnableVisualStyles()

$here = $PSScriptRoot
$switchScript = Join-Path $here 'switch-mode.ps1'
$cfgPath = Join-Path $here 'config.json'
$statePath = Join-Path $here 'state.json'
$trayLog = Join-Path $here 'tray-log.txt'

function Log-Tray([string]$m) {
    try {
        if ((Test-Path $trayLog) -and ((Get-Item $trayLog).Length -gt 60000)) { Remove-Item $trayLog -ErrorAction SilentlyContinue }
        Add-Content -Path $trayLog -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $m)
    } catch {}
}

# log anything that kills the app at startup
trap { Log-Tray ('fatal: ' + $_ + ' (line ' + $_.InvocationInfo.ScriptLineNumber + ')'); break }

# only one copy at a time
$createdNew = $false
$script:mutex = New-Object System.Threading.Mutex($true, 'Local\DisplayModesTray', [ref]$createdNew)
if (-not $createdNew) { Log-Tray 'already running - exiting'; exit }

# a hidden window that receives the global hotkeys
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;
public class HotkeyWindow : NativeWindow, IDisposable {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    public event Action<int> Pressed;
    public HotkeyWindow() { CreateHandle(new CreateParams()); }
    public bool Register(int id, uint modifiers, uint vk) { return RegisterHotKey(this.Handle, id, modifiers, vk); }
    public void UnregisterAll() { for (int i = 1; i <= 3; i++) UnregisterHotKey(this.Handle, i); }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && Pressed != null) Pressed(m.WParam.ToInt32());
        base.WndProc(ref m);
    }
    public void Dispose() { UnregisterAll(); DestroyHandle(); }
}
'@

# ---------------- config / state ----------------
function Load-Config {
    if (Test-Path $cfgPath) {
        try { return (Get-Content -Raw -Path $cfgPath | ConvertFrom-Json) } catch { Log-Tray "config.json unreadable: $_" }
    }
    return $null
}
function Save-Config($cfg) { $cfg | ConvertTo-Json -Depth 6 | Set-Content -Path $cfgPath -Encoding UTF8 }
function Get-Mode {
    try { if (Test-Path $statePath) { return [string]((Get-Content -Raw -Path $statePath | ConvertFrom-Json).mode) } } catch {}
    return 'unknown'
}
function Set-Mode([string]$m) { try { @{ mode = $m } | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8 } catch {} }

# ---------------- tray icon ----------------
function New-ModeIcon([string]$mode) {
    $color = [System.Drawing.Color]::White          # white icon; the letter (D / T / A) shows the mode
    $letter = switch ($mode) { 'desk' { 'D' } 'tv' { 'T' } 'all' { 'A' } default { '?' } }
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $brush = New-Object System.Drawing.SolidBrush $color
    $dark = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(30, 41, 59))
    $font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $g.FillRectangle($brush, 1, 3, 30, 21)          # screen frame
    $g.FillRectangle($dark, 4, 6, 24, 15)           # dark glass
    $g.FillRectangle($brush, 13, 24, 6, 3)          # neck
    $g.FillRectangle($brush, 8, 27, 16, 3)          # foot
    $g.DrawString($letter, $font, $brush, 9, 5)
    $handle = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($handle)
    $g.Dispose(); $bmp.Dispose(); $brush.Dispose(); $dark.Dispose(); $font.Dispose()
    return $icon
}

function Mode-Title([string]$mode) {
    switch ($mode) { 'desk' { 'Desktop mode' } 'tv' { 'TV mode' } 'all' { 'All screens' } default { 'Display modes' } }
}

$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Visible = $true
function Show-Balloon([string]$text) {
    try { $script:notify.ShowBalloonTip(1500, 'Display modes', $text, [System.Windows.Forms.ToolTipIcon]::None) } catch {}
}

# ---------------- running things ----------------
$script:proc = $null
function Run-Mode([string]$mode) {
    try {
        if ($script:proc -and (-not $script:proc.HasExited)) { Show-Balloon 'Still switching, one moment...'; return }
        $script:proc = Start-Process -FilePath powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$switchScript`"", '-Mode', $mode)
        Set-Mode $mode
        Update-Tray
        Show-Balloon (Mode-Title $mode)
        Log-Tray "mode: $mode"
    } catch { Log-Tray "Run-Mode $mode failed: $_" }
}
function Run-TvAction([string]$action) {
    try {
        Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$switchScript`"", '-Mode', 'tvaction', '-TvAction', $action)
        Show-Balloon $(if ($action -eq 'sleep') { 'Putting the TV to sleep' } else { 'Waking the TV' })
        Log-Tray "tv: $action"
    } catch { Log-Tray "Run-TvAction $action failed: $_" }
}

# ---------------- start with Windows ----------------
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName = 'DisplayModesTray'
function Get-Startup { return [bool](Get-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue) }
function Set-Startup([bool]$on) {
    try {
        if ($on) {
            $exe = Join-Path $here 'MonitorControl.exe'
            if (Test-Path $exe) { Set-ItemProperty -Path $runKey -Name $runName -Value ('"{0}"' -f $exe) }
            else { Set-ItemProperty -Path $runKey -Name $runName -Value ('wscript.exe "{0}"' -f (Join-Path $here 'tray.vbs')) }
        }
        else { Remove-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue }
    } catch { Log-Tray "startup setting failed: $_" }
}

# ---------------- Windows 11 style menu: frosted (blurred screen behind), rounded, follows light/dark ----------------
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Windows.Forms;
using System.Runtime.InteropServices;
using Microsoft.Win32;

public static class MenuNative {
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    public static void Round(IntPtr h) { try { int v = 2; DwmSetWindowAttribute(h, 33, ref v, 4); } catch (Exception) { } }   // Windows 11 rounded corners
}

public static class MenuTheme {
    public static bool Light;
    public static Color Frost, Fore, Muted, Hot, Line, Back;
    public static void Refresh() {
        Light = false;
        try {
            using (RegistryKey k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", false)) {
                if (k != null) { object v = k.GetValue("AppsUseLightTheme"); if (v is int) Light = ((int)v) != 0; }
            }
        } catch (Exception) { }
        if (Light) {
            Frost = Color.FromArgb(188, 243, 243, 245); Back = Color.FromArgb(249, 249, 249); Fore = Color.FromArgb(25, 25, 25);
            Muted = Color.FromArgb(140, 140, 140); Hot = Color.FromArgb(40, 0, 0, 0); Line = Color.FromArgb(50, 0, 0, 0);
        } else {
            Frost = Color.FromArgb(180, 30, 30, 34); Back = Color.FromArgb(43, 43, 43); Fore = Color.FromArgb(240, 240, 240);
            Muted = Color.FromArgb(125, 125, 125); Hot = Color.FromArgb(46, 255, 255, 255); Line = Color.FromArgb(60, 255, 255, 255);
        }
    }
}

// The blurred picture of the screen behind the menu (taken just before it opens).
public static class FrostBackdrop {
    public static Bitmap Small;
    public static Point Origin;
    public const float Factor = 16f;
    public static void Capture(Rectangle monitor) {
        Release();
        try {
            using (Bitmap full = new Bitmap(monitor.Width, monitor.Height, PixelFormat.Format32bppRgb)) {
                using (Graphics g = Graphics.FromImage(full)) g.CopyFromScreen(monitor.Location, Point.Empty, monitor.Size);
                int w = Math.Max(2, (int)(monitor.Width / Factor)), h = Math.Max(2, (int)(monitor.Height / Factor));
                Bitmap small = new Bitmap(w, h, PixelFormat.Format32bppRgb);
                using (Graphics sg = Graphics.FromImage(small)) {
                    sg.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    sg.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    sg.DrawImage(full, new Rectangle(0, 0, w, h), 0, 0, monitor.Width, monitor.Height, GraphicsUnit.Pixel);
                }
                Small = small; Origin = monitor.Location;
            }
        } catch (Exception) { Small = null; }
    }
    public static void Release() { if (Small != null) { Small.Dispose(); Small = null; } }
}

public class FrostColors : ProfessionalColorTable {
    public override Color ToolStripDropDownBackground { get { return MenuTheme.Back; } }
    public override Color ImageMarginGradientBegin { get { return MenuTheme.Back; } }
    public override Color ImageMarginGradientMiddle { get { return MenuTheme.Back; } }
    public override Color ImageMarginGradientEnd { get { return MenuTheme.Back; } }
}

public class FrostRenderer : ToolStripProfessionalRenderer {
    public FrostRenderer() : base(new FrostColors()) { }
    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) {
        ToolStripDropDown dd = e.ToolStrip as ToolStripDropDown;
        Graphics g = e.Graphics;
        Rectangle r = new Rectangle(0, 0, e.ToolStrip.Width, e.ToolStrip.Height);
        Bitmap small = FrostBackdrop.Small;
        if (dd != null && small != null && dd.IsHandleCreated) {
            Point sp = dd.PointToScreen(Point.Empty);
            float k = FrostBackdrop.Factor;
            using (ImageAttributes ia = new ImageAttributes()) {
                ia.SetWrapMode(WrapMode.TileFlipXY);
                g.InterpolationMode = InterpolationMode.HighQualityBilinear;
                g.PixelOffsetMode = PixelOffsetMode.Half;
                g.DrawImage(small, r, (sp.X - FrostBackdrop.Origin.X) / k, (sp.Y - FrostBackdrop.Origin.Y) / k, r.Width / k, r.Height / k, GraphicsUnit.Pixel, ia);
            }
            using (SolidBrush tint = new SolidBrush(MenuTheme.Frost)) g.FillRectangle(tint, r);
        } else {
            using (SolidBrush b = new SolidBrush(MenuTheme.Back)) g.FillRectangle(b, r);
        }
    }
    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) { }
    protected override void OnRenderImageMargin(ToolStripRenderEventArgs e) { }
    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e) {
        int y = e.Item.Height / 2;
        using (Pen p = new Pen(MenuTheme.Line)) e.Graphics.DrawLine(p, 10, y, e.Item.Width - 10, y);
    }
    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
        if (!e.Item.Enabled || (!e.Item.Selected && !e.Item.Pressed)) return;
        Rectangle r = new Rectangle(4, 1, e.Item.Width - 8, e.Item.Height - 2);
        SmoothingMode old = e.Graphics.SmoothingMode;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (GraphicsPath gp = Round(r, 5)) using (SolidBrush b = new SolidBrush(MenuTheme.Hot)) e.Graphics.FillPath(b, gp);
        e.Graphics.SmoothingMode = old;
    }
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
        if (!e.Item.Enabled) e.TextColor = MenuTheme.Muted;
        base.OnRenderItemText(e);
    }
    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e) {
        e.ArrowColor = e.Item.Enabled ? MenuTheme.Fore : MenuTheme.Muted;
        base.OnRenderArrow(e);
    }
    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) {
        Rectangle r = e.ImageRectangle;
        int cx = r.X + r.Width / 2, cy = r.Y + r.Height / 2;
        SmoothingMode old = e.Graphics.SmoothingMode;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (Pen p = new Pen(MenuTheme.Fore, 1.8f)) {
            p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
            e.Graphics.DrawLines(p, new PointF[] { new PointF(cx - 4.5f, cy + 0.5f), new PointF(cx - 1.5f, cy + 3.5f), new PointF(cx + 4.5f, cy - 3.5f) });
        }
        e.Graphics.SmoothingMode = old;
    }
    static GraphicsPath Round(Rectangle r, int radius) {
        int d = radius * 2; GraphicsPath gp = new GraphicsPath();
        gp.AddArc(r.X, r.Y, d, d, 180, 90); gp.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        gp.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); gp.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        gp.CloseFigure(); return gp;
    }
}
'@
[MenuTheme]::Refresh()
[System.Windows.Forms.ToolStripManager]::Renderer = New-Object FrostRenderer
$script:menuFont = New-Object System.Drawing.Font('Segoe UI', 10)
$script:uiScale = 1.0
try { $g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $script:uiScale = $g0.DpiX / 96.0; $g0.Dispose() } catch {}

# ---------------- menu ----------------
$menu = New-Object System.Windows.Forms.ContextMenuStrip
function Add-Item([string]$text, [scriptblock]$onClick) {
    $it = New-Object System.Windows.Forms.ToolStripMenuItem $text
    if ($onClick) { $it.add_Click($onClick) }
    [void]$menu.Items.Add($it)
    return $it
}
$miDesk = Add-Item 'Desktop mode' { Run-Mode 'desk' }
$miTv   = Add-Item 'TV mode'      { Run-Mode 'tv' }
$miAll  = Add-Item 'All screens on' { Run-Mode 'all' }
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miSleep = Add-Item 'Put TV to sleep' { Run-TvAction 'sleep' }
$miWake  = Add-Item 'Wake TV'         { Run-TvAction 'wake' }
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miReturn = New-Object System.Windows.Forms.ToolStripMenuItem 'Back to desktop mode, TV goes to'
$miHome = New-Object System.Windows.Forms.ToolStripMenuItem 'Home screen'
$miPrev = New-Object System.Windows.Forms.ToolStripMenuItem 'Previous app'
$miHome.add_Click({ Set-ReturnTo 'home' })
$miPrev.add_Click({ Set-ReturnTo 'previous' })
[void]$miReturn.DropDownItems.Add($miHome)
[void]$miReturn.DropDownItems.Add($miPrev)
[void]$menu.Items.Add($miReturn)

$miPic = New-Object System.Windows.Forms.ToolStripMenuItem 'TV picture'
$miPic4k  = New-Object System.Windows.Forms.ToolStripMenuItem '4K 60 Hz'
$miPicHd  = New-Object System.Windows.Forms.ToolStripMenuItem '1080p 120 Hz'
$miPic4k.add_Click({ Set-TvPicture 3840 2160 })
$miPicHd.add_Click({ Set-TvPicture 1920 1080 })
[void]$miPic.DropDownItems.Add($miPic4k)
[void]$miPic.DropDownItems.Add($miPicHd)
[void]$menu.Items.Add($miPic)

$miSettings = Add-Item 'Settings...' { Show-Settings }
$miStartup = Add-Item 'Start with Windows' { Set-Startup (-not (Get-Startup)); Update-Tray }
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miExit = Add-Item 'Exit' { Exit-Tray }

# padding, font and rounded corners for the menu and its submenus
function Style-Menu([System.Windows.Forms.ToolStripDropDown]$dd) {
    $dd.Font = $script:menuFont
    $dd.add_Opened({ param($s, $e) try { [MenuNative]::Round($s.Handle) } catch {} })
    foreach ($it in @($dd.Items)) {
        if ($it -is [System.Windows.Forms.ToolStripMenuItem]) {
            $it.Padding = New-Object System.Windows.Forms.Padding([int][Math]::Round(4 * $script:uiScale), [int][Math]::Round(5 * $script:uiScale), [int][Math]::Round(4 * $script:uiScale), [int][Math]::Round(5 * $script:uiScale))
            if ($it.HasDropDownItems) { Style-Menu $it.DropDown }
        }
    }
}
function Apply-MenuColors($items, $fg) {
    foreach ($it in @($items)) {
        $it.BackColor = [System.Drawing.Color]::Transparent
        $it.ForeColor = $fg
        if (($it -is [System.Windows.Forms.ToolStripMenuItem]) -and $it.HasDropDownItems) { Apply-MenuColors $it.DropDownItems $fg }
    }
}
Style-Menu $menu
$menu.add_Closed({ [FrostBackdrop]::Release() })

# The menu opens with its left edge at the pointer, growing to the right and upward from the taskbar.
# It only slides left as far as needed to stay on screen.
function Show-TrayMenu {
    try {
        [MenuTheme]::Refresh()
        $fg = [MenuTheme]::Fore
        $menu.ForeColor = $fg
        Apply-MenuColors $menu.Items $fg
        $pt = [System.Windows.Forms.Cursor]::Position
        $scr = [System.Windows.Forms.Screen]::FromPoint($pt)
        $wa = $scr.WorkingArea
        $sz = $menu.GetPreferredSize([System.Drawing.Size]::Empty)
        $x = [Math]::Max($wa.Left, [Math]::Min($pt.X, $wa.Right - $sz.Width))
        $bottom = [Math]::Min($pt.Y, $wa.Bottom)
        $y = [Math]::Max($wa.Top, $bottom - $sz.Height)
        [FrostBackdrop]::Capture($scr.Bounds)          # before the menu covers the screen
        $null = $menu.Handle
        [void][MenuNative]::SetForegroundWindow($menu.Handle)   # so the menu closes when you click elsewhere
        $menu.Show((New-Object System.Drawing.Point($x, $y)))
    } catch { Log-Tray "menu: $_" }
}

function Set-ReturnTo([string]$value) {
    $cfg = Load-Config
    if (-not $cfg) { return }
    $cfg | Add-Member -NotePropertyName returnTo -NotePropertyValue $value -Force
    Save-Config $cfg
    Update-Tray
}

# TV resolution: 4K runs at 60 Hz, 1080p at 120 Hz (the highest refresh the TV offers at that size is picked automatically)
function Set-TvPicture([int]$w, [int]$h) {
    try {
        $cfg = Load-Config
        if (-not $cfg) { return }
        foreach ($m in @($cfg.monitors | Where-Object { $_.role -eq 'tv' })) {
            $m | Add-Member -NotePropertyName width -NotePropertyValue $w -Force
            $m | Add-Member -NotePropertyName height -NotePropertyValue $h -Force
        }
        Save-Config $cfg
        Update-Tray
        $mode = Get-Mode
        $label = if ($h -ge 2160) { '4K 60 Hz' } else { '1080p 120 Hz' }
        if (($mode -eq 'tv') -or ($mode -eq 'all')) {
            if ($script:proc -and (-not $script:proc.HasExited)) { Show-Balloon 'Still switching, one moment...'; return }
            $script:proc = Start-Process -FilePath powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$switchScript`"", '-Mode', 'layout')
            Show-Balloon "TV: $label"
        } else {
            Show-Balloon "TV will use $label"
        }
        Log-Tray "tv picture: $label"
    } catch { Log-Tray "Set-TvPicture failed: $_" }
}

function Update-Tray {
    $mode = Get-Mode
    $old = $script:notify.Icon
    $script:notify.Icon = New-ModeIcon $mode
    $script:notify.Text = ('Display modes - ' + (Mode-Title $mode))
    $miDesk.Checked = ($mode -eq 'desk')
    $miTv.Checked = ($mode -eq 'tv')
    $miAll.Checked = ($mode -eq 'all')
    $cfg = Load-Config
    $isPrev = ($cfg -and $cfg.returnTo -eq 'previous')
    $miHome.Checked = (-not $isPrev)
    $miPrev.Checked = $isPrev
    $hasTv = ($cfg -and (@($cfg.monitors | Where-Object { $_.role -eq 'tv' }).Count -gt 0))
    foreach ($it in @($miSleep, $miWake, $miReturn, $miPic)) { $it.Enabled = [bool]$hasTv }
    $tvMon = $null
    if ($cfg) { $tvMon = @($cfg.monitors | Where-Object { $_.role -eq 'tv' }) | Select-Object -First 1 }
    $is4k = ($tvMon -and ([int]$tvMon.height -ge 2160))
    $miPic4k.Checked = [bool]$is4k
    $miPicHd.Checked = [bool]($tvMon -and (-not $is4k))
    $miStartup.Checked = (Get-Startup)
    $hk = ''
    if ($cfg -and $cfg.hotkeys) { $hk = '   Ctrl+Alt+' }
    $miDesk.Text = 'Desktop mode' + $(if ($hk) { "$($hk)D" } else { '' })
    $miTv.Text   = 'TV mode' + $(if ($hk) { "$($hk)T" } else { '' })
    $miAll.Text  = 'All screens on' + $(if ($hk) { "$($hk)A" } else { '' })
}

# left and right click both open the menu at the pointer
$script:notify.add_MouseUp({
    param($sender, $e)
    if (($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) -or ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right)) { Show-TrayMenu }
})

# ---------------- hotkeys (Ctrl+Alt+D / T / A) ----------------
$script:hk = New-Object HotkeyWindow
$script:hk.add_Pressed([Action[int]]{
    param($id)
    switch ($id) { 1 { Run-Mode 'desk' } 2 { Run-Mode 'tv' } 3 { Run-Mode 'all' } }
})
function Apply-Hotkeys {
    $script:hk.UnregisterAll()
    $cfg = Load-Config
    if ($cfg -and $cfg.hotkeys) {
        $mod = [uint32](0x0001 -bor 0x0002 -bor 0x4000)     # Alt + Ctrl, no auto-repeat
        $a = $script:hk.Register(1, $mod, 0x44)             # D
        $b = $script:hk.Register(2, $mod, 0x54)             # T
        $c = $script:hk.Register(3, $mod, 0x41)             # A
        if (-not ($a -and $b -and $c)) { Show-Balloon 'Some hotkeys are already used by another program' }
    }
}

# ---------------- settings window ----------------
function Get-Targets {
    $f = Join-Path $here 'targets.json'
    Remove-Item $f -ErrorAction SilentlyContinue
    [void](Start-Process -FilePath powershell.exe -WindowStyle Hidden -PassThru -Wait -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$switchScript`"", '-Mode', 'list'))
    if (Test-Path $f) { try { return (Get-Content -Raw -Path $f | ConvertFrom-Json) } catch { Log-Tray "targets.json: $_" } }
    return $null
}
function Role-Text([string]$role) { switch ($role) { 'desktop' { 'Desktop' } 'tv' { 'TV' } default { 'Not used' } } }

$script:settingsOpen = $false
$script:ui = @{}

function Add-ScreenRows($grid, $cfgMonitors, $targets, [string]$mainId) {
    $have = @{}
    foreach ($r in $grid.Rows) { $have[[string]$r.Cells[1].Value] = $true }
    $tscreens = @()
    if ($targets -and $targets.screens) { $tscreens = @($targets.screens) }
    foreach ($m in @($cfgMonitors)) {
        if ((-not $m) -or $have[[string]$m.id]) { continue }
        $name = [string]$m.name
        foreach ($t in $tscreens) { if ($t.id -eq $m.id -and $t.name) { $name = [string]$t.name } }
        [void]$grid.Rows.Add($name, [string]$m.id, (Role-Text $m.role), ([string]$m.id -eq $mainId), ('{0}x{1}' -f $m.width, $m.height))
        $have[[string]$m.id] = $true
    }
    foreach ($t in $tscreens) {
        if ($have[[string]$t.id]) { continue }
        [void]$grid.Rows.Add([string]$t.name, [string]$t.id, 'Not used', $false, ('{0}x{1}' -f $t.width, $t.height))
        $have[[string]$t.id] = $true
    }
}

function New-Label([string]$text, [int]$x, [int]$y, [int]$w = 150) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.Size = New-Object System.Drawing.Size($w, 20)
    return $l
}
function New-Box([string]$text, [int]$x, [int]$y, [int]$w) {
    $b = New-Object System.Windows.Forms.TextBox
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, 24)
    return $b
}
function New-Btn([string]$text, [int]$x, [int]$y, [int]$w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, 28)
    return $b
}

function Show-Settings {
    if ($script:settingsOpen) { try { $script:ui.form.Activate() } catch {}; return }
    $script:settingsOpen = $true
    try {
        $form = New-Object System.Windows.Forms.Form
        $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
        $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
        $script:ui.form = $form
        $form.Text = 'Display modes - Settings'
        $form.ClientSize = New-Object System.Drawing.Size(780, 600)
        $form.StartPosition = 'CenterScreen'
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false; $form.MinimizeBox = $false
        $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

        # finding the screens takes a couple of seconds
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
        $cfg = Load-Config
        $targets = Get-Targets
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default

        # --- screens ---
        $form.Controls.Add((New-Label 'Screens - top of the list = leftmost screen on your desk. Pick what each one is:' 14 12 740))
        $grid = New-Object System.Windows.Forms.DataGridView
        $script:ui.grid = $grid
        $grid.Location = New-Object System.Drawing.Point(14, 38); $grid.Size = New-Object System.Drawing.Size(752, 190)
        $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.AllowUserToResizeRows = $false
        $grid.RowHeadersVisible = $false; $grid.MultiSelect = $false
        $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
        $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
        $grid.BackgroundColor = [System.Drawing.SystemColors]::Window

        $cName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $cName.HeaderText = 'Screen'; $cName.ReadOnly = $true; $cName.FillWeight = 34
        $cId = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $cId.HeaderText = 'ID'; $cId.ReadOnly = $true; $cId.FillWeight = 18
        $cRole = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
        $cRole.HeaderText = 'This is a...'; $cRole.FillWeight = 20
        [void]$cRole.Items.Add('Desktop'); [void]$cRole.Items.Add('TV'); [void]$cRole.Items.Add('Not used')
        $cMain = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
        $cMain.HeaderText = 'Main'; $cMain.FillWeight = 10
        $cSize = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $cSize.HeaderText = 'Resolution'; $cSize.FillWeight = 18
        $grid.Columns.AddRange([System.Windows.Forms.DataGridViewColumn[]]@($cName, $cId, $cRole, $cMain, $cSize))
        $form.Controls.Add($grid)

        $mainId = ''
        if ($cfg -and $cfg.main) { $mainId = [string]$cfg.main }
        $cfgMonitors = @()
        if ($cfg -and $cfg.monitors) { $cfgMonitors = @($cfg.monitors) }
        Add-ScreenRows $grid $cfgMonitors $targets $mainId

        # only one screen can be Main
        $grid.add_CellContentClick({
            param($sender, $e)
            if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 3) {
                $script:ui.grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
                if ($script:ui.grid.Rows[$e.RowIndex].Cells[3].Value -eq $true) {
                    foreach ($r in $script:ui.grid.Rows) { if ($r.Index -ne $e.RowIndex) { $r.Cells[3].Value = $false } }
                }
            }
        })
        $grid.add_DataError({ param($sender, $e) $e.ThrowException = $false })

        $btnUp = New-Btn 'Move up' 14 234 100
        $btnDown = New-Btn 'Move down' 120 234 100
        $btnDetect = New-Btn 'Find screens again' 226 234 150
        $btnUp.add_Click({
            $g = $script:ui.grid
            if ($g.SelectedRows.Count -gt 0) {
                $i = $g.SelectedRows[0].Index
                if ($i -gt 0) { $row = $g.Rows[$i]; $g.Rows.RemoveAt($i); $g.Rows.Insert($i - 1, $row); $g.ClearSelection(); $g.Rows[$i - 1].Selected = $true }
            }
        })
        $btnDown.add_Click({
            $g = $script:ui.grid
            if ($g.SelectedRows.Count -gt 0) {
                $i = $g.SelectedRows[0].Index
                if ($i -lt ($g.Rows.Count - 1)) { $row = $g.Rows[$i]; $g.Rows.RemoveAt($i); $g.Rows.Insert($i + 1, $row); $g.ClearSelection(); $g.Rows[$i + 1].Selected = $true }
            }
        })
        $btnDetect.add_Click({
            $script:ui.form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $t = Get-Targets
            Add-ScreenRows $script:ui.grid @() $t ''
            $script:ui.form.Cursor = [System.Windows.Forms.Cursors]::Default
        })
        $form.Controls.AddRange(@($btnUp, $btnDown, $btnDetect))
        $form.Controls.Add((New-Label 'Desktop = turned on in desktop mode.  TV = turned on in TV mode.  Main = the screen with your taskbar.' 14 268 752))

        # --- TV ---
        $form.Controls.Add((New-Label 'TV (Android TV / Google TV over Wi-Fi - turn on network debugging on the TV)' 14 304 752))
        $tv = $null
        if ($cfg) { $tv = $cfg.tv }
        $ipText = ''; $portText = '5555'; $inputText = ''; $audioText = ''
        if ($tv) { $ipText = [string]$tv.ip; if ($tv.port) { $portText = [string]$tv.port }; $inputText = [string]$tv.hdmiInput; $audioText = [string]$tv.audio }
        $form.Controls.Add((New-Label 'TV address (IP)' 14 334 130))
        $tbIp = New-Box $ipText 150 331 160;  $script:ui.ip = $tbIp
        $form.Controls.Add((New-Label 'Port' 330 334 40))
        $tbPort = New-Box $portText 372 331 70; $script:ui.port = $tbPort
        $form.Controls.Add((New-Label 'PC input on the TV' 14 368 130))
        $tbInput = New-Box $inputText 150 365 420; $script:ui.input = $tbInput
        $form.Controls.Add((New-Label 'Sound device for TV mode' 14 402 140))
        $cbAudio = New-Object System.Windows.Forms.ComboBox
        $cbAudio.Location = New-Object System.Drawing.Point(150, 399); $cbAudio.Size = New-Object System.Drawing.Size(420, 24)
        $cbAudio.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
        if ($targets -and $targets.audio) { foreach ($a in @($targets.audio)) { [void]$cbAudio.Items.Add([string]$a) } }
        $cbAudio.Text = $audioText
        $script:ui.audio = $cbAudio
        $form.Controls.AddRange(@($tbIp, $tbPort, $tbInput, $cbAudio))
        $form.Controls.Add((New-Label '(part of the name is enough, e.g. Smart TV Pro)' 580 402 190))

        # --- when going back to desktop mode ---
        $form.Controls.Add((New-Label 'When you go back to desktop mode, the TV (if it is showing the PC) goes to:' 14 446 752))
        $rbHome = New-Object System.Windows.Forms.RadioButton
        $rbHome.Text = 'The Home screen'; $rbHome.Location = New-Object System.Drawing.Point(30, 470); $rbHome.Size = New-Object System.Drawing.Size(200, 22)
        $rbPrev = New-Object System.Windows.Forms.RadioButton
        $rbPrev.Text = 'The app it was on before TV mode'; $rbPrev.Location = New-Object System.Drawing.Point(240, 470); $rbPrev.Size = New-Object System.Drawing.Size(300, 22)
        if ($cfg -and $cfg.returnTo -eq 'previous') { $rbPrev.Checked = $true } else { $rbHome.Checked = $true }
        $script:ui.rbPrev = $rbPrev
        $form.Controls.AddRange(@($rbHome, $rbPrev))

        # --- options ---
        $chkHot = New-Object System.Windows.Forms.CheckBox
        $chkHot.Text = 'Hotkeys: Ctrl+Alt+D (desktop), Ctrl+Alt+T (TV), Ctrl+Alt+A (all)'
        $chkHot.Location = New-Object System.Drawing.Point(14, 506); $chkHot.Size = New-Object System.Drawing.Size(500, 22)
        $chkHot.Checked = [bool]($cfg -and $cfg.hotkeys)
        $script:ui.chkHot = $chkHot
        $chkStart = New-Object System.Windows.Forms.CheckBox
        $chkStart.Text = 'Start with Windows'
        $chkStart.Location = New-Object System.Drawing.Point(14, 530); $chkStart.Size = New-Object System.Drawing.Size(300, 22)
        $chkStart.Checked = (Get-Startup)
        $script:ui.chkStart = $chkStart
        $form.Controls.AddRange(@($chkHot, $chkStart))

        # --- save / cancel ---
        $btnSave = New-Btn 'Save' 566 560 100
        $btnCancel = New-Btn 'Cancel' 672 560 94
        $btnCancel.add_Click({ $script:ui.form.Close() })
        $btnSave.add_Click({
            try {
                $g = $script:ui.grid
                $mons = @()
                $mainPick = ''
                foreach ($r in $g.Rows) {
                    $roleName = [string]$r.Cells[2].Value
                    $role = 'unused'
                    if ($roleName -eq 'Desktop') { $role = 'desktop' } elseif ($roleName -eq 'TV') { $role = 'tv' }
                    $sz = [string]$r.Cells[4].Value
                    if ($sz -notmatch '^\s*(\d+)\s*[xX]\s*(\d+)\s*$') {
                        [void][System.Windows.Forms.MessageBox]::Show("The resolution for '$($r.Cells[0].Value)' must look like 1920x1080.", 'Display modes')
                        return
                    }
                    $w = [int]$matches[1]; $h = [int]$matches[2]
                    $id = [string]$r.Cells[1].Value
                    $mons += [pscustomobject]@{ id = $id; name = [string]$r.Cells[0].Value; role = $role; width = $w; height = $h }
                    if (($role -eq 'desktop') -and ($r.Cells[3].Value -eq $true) -and (-not $mainPick)) { $mainPick = $id }
                }
                $desk = @($mons | Where-Object { $_.role -eq 'desktop' })
                if ($desk.Count -eq 0) {
                    [void][System.Windows.Forms.MessageBox]::Show('Mark at least one screen as Desktop.', 'Display modes')
                    return
                }
                if (-not $mainPick) { $mainPick = $desk[0].id }
                $portNum = 0
                if (-not [int]::TryParse($script:ui.port.Text.Trim(), [ref]$portNum)) { $portNum = 5555 }
                $old = Load-Config
                $tvApp = 'com.tcl.tv'
                if ($old -and $old.tv -and $old.tv.tvApp) { $tvApp = [string]$old.tv.tvApp }
                $new = [pscustomobject]@{
                    monitors = $mons
                    main     = $mainPick
                    tv       = [pscustomobject]@{ ip = $script:ui.ip.Text.Trim(); port = $portNum; hdmiInput = $script:ui.input.Text.Trim(); audio = $script:ui.audio.Text.Trim(); tvApp = $tvApp }
                    returnTo = $(if ($script:ui.rbPrev.Checked) { 'previous' } else { 'home' })
                    hotkeys  = [bool]$script:ui.chkHot.Checked
                }
                Save-Config $new
                Set-Startup ([bool]$script:ui.chkStart.Checked)
                Apply-Hotkeys
                Update-Tray
                Show-Balloon 'Settings saved'
                $script:ui.form.Close()
            } catch {
                Log-Tray "save failed: $_"
                [void][System.Windows.Forms.MessageBox]::Show("Could not save: $_", 'Display modes')
            }
        })
        $form.Controls.AddRange(@($btnSave, $btnCancel))
        $form.AcceptButton = $btnSave
        $form.CancelButton = $btnCancel

        [void]$form.ShowDialog()
        $form.Dispose()
    } catch {
        Log-Tray "settings failed: $_"
        try { [void][System.Windows.Forms.MessageBox]::Show("Could not open Settings: $_", 'Display modes') } catch {}
    } finally {
        $script:settingsOpen = $false
    }
}

# ---------------- exit ----------------
function Exit-Tray {
    try { $script:hk.Dispose() } catch {}
    try { $script:notify.Visible = $false; $script:notify.Dispose() } catch {}
    try { $script:mutex.ReleaseMutex() } catch {}
    [System.Windows.Forms.Application]::Exit()
}

# ---------------- go ----------------
Apply-Hotkeys
Update-Tray
Log-Tray 'tray started'
$ctx = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($ctx)
