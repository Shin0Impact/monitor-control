# switch-mode.ps1 - switch screens + sound + TV in one go. All settings live in config.json
# (the tray app's Settings window edits that file).
#   -Mode desk     : desktop screens only; TV goes Home / back to its previous app (if it was on the PC's input)
#   -Mode tv       : TV only; sound -> TV; TV wakes and jumps to the PC's HDMI input
#   -Mode all      : every screen on
#   -Mode list     : write targets.json (screens + sound devices Windows sees) for the Settings window
#   -Mode tvaction : run one TV command in the background (-TvAction show | leave | sleep | wake)
# Screens are switched in ONE Windows call (SetDisplayConfig); Windows re-uses the layout it remembers.
param([ValidateSet('tv','desk','all','list','tvaction')][string]$Mode = 'list',
      [ValidateSet('show','leave','sleep','wake','')][string]$TvAction = '')

$here = $PSScriptRoot
$cfgPath = Join-Path $here 'config.json'

$defaultConfigJson = @'
{
  "monitors": [
    { "id": "SAM7312", "name": "S27C31x",      "role": "desktop", "width": 1920, "height": 1080 },
    { "id": "AOC2702", "name": "Q27G2G3R3B",   "role": "desktop", "width": 2560, "height": 1440 },
    { "id": "XXX8000", "name": "Smart TV Pro", "role": "tv",      "width": 3840, "height": 2160 }
  ],
  "main": "AOC2702",
  "tv": { "ip": "10.0.0.222", "port": 5555, "hdmiInput": "com.tcl.tvinput/.TvPassThroughService/HW15", "audio": "Smart TV Pro", "tvApp": "com.tcl.tv" },
  "returnTo": "home",
  "hotkeys": true
}
'@
function Load-Config {
    if (Test-Path $cfgPath) {
        try { return (Get-Content -Raw -Path $cfgPath | ConvertFrom-Json) } catch { Write-Host "config.json unreadable, using defaults: $_" }
    }
    return ($defaultConfigJson | ConvertFrom-Json)
}
$Cfg = Load-Config

# Screens in physical order, left -> right (that is the order in config.json). role = desktop | tv | unused
$MonList     = @($Cfg.monitors | Where-Object { $_.role -ne 'unused' })
$ORDER       = @($MonList | ForEach-Object { $_.id })
$DESKTOP_IDS = @($MonList | Where-Object { $_.role -eq 'desktop' } | ForEach-Object { $_.id })
$TV_IDS      = @($MonList | Where-Object { $_.role -eq 'tv' } | ForEach-Object { $_.id })
$MAIN_ID = $null
if ($Cfg.main -and ($DESKTOP_IDS -contains $Cfg.main)) { $MAIN_ID = [string]$Cfg.main }
elseif ($DESKTOP_IDS.Count -gt 0) { $MAIN_ID = $DESKTOP_IDS[0] }
$RES = @{}
foreach ($mon in $MonList) { $RES[$mon.id] = @([int]$mon.width, [int]$mon.height) }

# TV network control (Android TV, ADB over Wi-Fi)
$TV_IP = [string]$Cfg.tv.ip
$TV_PORT = if ($Cfg.tv.port) { [int]$Cfg.tv.port } else { 5555 }
$TV_HDMI_INPUT = [string]$Cfg.tv.hdmiInput
$TV_AUDIO = [string]$Cfg.tv.audio
$TV_APP = if ($Cfg.tv.tvApp) { [string]$Cfg.tv.tvApp } else { 'com.tcl.tv' }
$RETURN_TO = if ($Cfg.returnTo -eq 'previous') { 'previous' } else { 'home' }

$log = Join-Path $here $(if ($Mode -eq 'tvaction') { 'tv-log.txt' } else { 'switch-log.txt' })
$sw = [Diagnostics.Stopwatch]::StartNew()
function Log($m) { $line = ('[{0,5:n1}s] {1}' -f $sw.Elapsed.TotalSeconds, $m); Add-Content -Path $log -Value $line; Write-Host $line }
if ($Mode -eq 'tvaction') {
    # background TV commands append to their own log (and keep it from growing forever)
    if ((Test-Path $log) -and ((Get-Item $log).Length -gt 60000)) { Remove-Item $log -ErrorAction SilentlyContinue }
    Add-Content -Path $log -Value "===== tvaction $TvAction $(Get-Date) ====="
} else {
    Set-Content -Path $log -Value "===== $Mode $(Get-Date) ====="
    # MultiMonitorTool: apply each change once (it defaults to 5 times, which causes extra flicker) and don't keep refreshing
    $mmtCfg = Join-Path $here 'MultiMonitorTool.cfg'
    if (-not (Test-Path $mmtCfg)) { Set-Content -Path $mmtCfg -Value "[General]`r`nMonitorsConfigNumOfCalls=1`r`nAutoRefresh=0`r`n" -Encoding ASCII }
}

if ($Mode -ne 'tvaction') { Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class Ccd {
    [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] public struct SRC { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
    [StructLayout(LayoutKind.Sequential)] public struct RATIONAL { public uint Num; public uint Den; }
    [StructLayout(LayoutKind.Sequential)] public struct TGT {
        public LUID adapterId; public uint id; public uint modeInfoIdx; public uint outputTechnology;
        public uint rotation; public uint scaling; public RATIONAL refreshRate; public uint scanLineOrdering;
        public int targetAvailable; public uint statusFlags;
    }
    [StructLayout(LayoutKind.Sequential)] public struct PATH { public SRC source; public TGT target; public uint flags; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct TARGET_NAME {
        public int type; public uint size; public LUID adapterId; public uint id;
        public uint flags; public uint outputTechnology; public ushort edidManufactureId; public ushort edidProductCodeId;
        public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string friendlyName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string devicePath;
    }

    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPath, out uint numMode);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint numPath, [Out] PATH[] paths, ref uint numMode, IntPtr modes, IntPtr topology);
    [DllImport("user32.dll")] static extern int SetDisplayConfig(uint numPath, [In] PATH[] paths, uint numMode, IntPtr modes, uint flags);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref TARGET_NAME req);

    public static string Log = "";

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);

    // Highest refresh rate the screen offers at this resolution (non-interlaced)
    public static int MaxRefresh(string device, int w, int h) {
        DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        int best = 0;
        for (int i = 0; EnumDisplaySettings(device, i, ref dm); i++) {
            if (dm.dmPelsWidth == w && dm.dmPelsHeight == h && (dm.dmDisplayFlags & 2) == 0 && dm.dmDisplayFrequency > best)
                best = dm.dmDisplayFrequency;
        }
        return best;
    }

    public static PATH[] AllPaths() {
        for (int attempt = 0; attempt < 5; attempt++) {
            uint np, nm;
            int r = GetDisplayConfigBufferSizes(1 /*QDC_ALL_PATHS*/, out np, out nm);
            if (r != 0) throw new Exception("GetDisplayConfigBufferSizes failed: " + r);
            PATH[] paths = new PATH[np];
            IntPtr modes = Marshal.AllocHGlobal((int)Math.Max(1, nm) * 64);
            try { r = QueryDisplayConfig(1, ref np, paths, ref nm, modes, IntPtr.Zero); }
            finally { Marshal.FreeHGlobal(modes); }
            if (r == 122) continue; // buffer changed size, retry
            if (r != 0) throw new Exception("QueryDisplayConfig failed: " + r);
            Array.Resize(ref paths, (int)np);
            return paths;
        }
        throw new Exception("QueryDisplayConfig kept changing size");
    }

    static Dictionary<string, string[]> nameCache = new Dictionary<string, string[]>();
    public static string[] TargetName(LUID a, uint id) {
        string key = a.Low + ":" + a.High + ":" + id;
        string[] v;
        if (nameCache.TryGetValue(key, out v)) return v;
        TARGET_NAME t = new TARGET_NAME();
        t.type = 2; /*GET_TARGET_NAME*/ t.size = (uint)Marshal.SizeOf(typeof(TARGET_NAME)); t.adapterId = a; t.id = id;
        int r = DisplayConfigGetDeviceInfo(ref t);
        v = r == 0 ? new string[] { t.friendlyName ?? "", t.devicePath ?? "" } : new string[] { "", "" };
        nameCache[key] = v;
        return v;
    }

    public static string List() {
        string s = "";
        Dictionary<string, bool> seen = new Dictionary<string, bool>();
        foreach (PATH p in AllPaths()) {
            if (p.target.targetAvailable == 0) continue;
            string key = p.target.adapterId.Low + ":" + p.target.id;
            bool active = (p.flags & 1) != 0;
            if (seen.ContainsKey(key) && !active) continue;
            seen[key] = true;
            string[] n = TargetName(p.target.adapterId, p.target.id);
            string[] parts = n[1].Split('#');
            string id = parts.Length > 1 ? parts[1] : n[1];
            s += id + "|" + n[0] + "|" + (active ? "1" : "0") + "\n";
        }
        return s;
    }

    // Turn on exactly the screens whose device path contains one of the given IDs, everything else off.
    public static int Apply(string[] wanted) {
        Log = "";
        PATH[] all = AllPaths();
        List<PATH> chosen = new List<PATH>();
        Dictionary<string, bool> usedSrc = new Dictionary<string, bool>();
        foreach (string w in wanted) {
            bool found = false;
            // first pass: keep the source the screen is already using (if it's on); second pass: any free source
            for (int pass = 0; pass < 2 && !found; pass++) {
                foreach (PATH p in all) {
                    if (p.target.targetAvailable == 0) continue;
                    if (pass == 0 && (p.flags & 1) == 0) continue;
                    string[] n = TargetName(p.target.adapterId, p.target.id);
                    if (n[1].IndexOf(w, StringComparison.OrdinalIgnoreCase) < 0) continue;
                    string sk = p.source.adapterId.Low + ":" + p.source.adapterId.High + ":" + p.source.id;
                    if (usedSrc.ContainsKey(sk)) continue;
                    PATH q = p;
                    q.flags = 1; // DISPLAYCONFIG_PATH_ACTIVE
                    q.source.modeInfoIdx = 0xFFFFFFFF;
                    q.target.modeInfoIdx = 0xFFFFFFFF;
                    chosen.Add(q); usedSrc[sk] = true; found = true;
                    Log += "  " + w + " = " + n[0] + " (source " + p.source.id + ")\r\n";
                    break;
                }
            }
            if (!found) { Log += "  " + w + " NOT FOUND\r\n"; return -1; }
        }
        PATH[] arr = chosen.ToArray();
        // 1st try: let Windows use the layout it remembers for this set of screens
        int r = SetDisplayConfig((uint)arr.Length, arr, 0, IntPtr.Zero, 0x80 /*APPLY*/ | 0x10 /*TOPOLOGY_SUPPLIED*/);
        Log += "  SetDisplayConfig(topology) = " + r + "\r\n";
        if (r == 0) return 0;
        // 2nd try: let Windows pick modes itself and save the result
        r = SetDisplayConfig((uint)arr.Length, arr, 0, IntPtr.Zero, 0x80 | 0x20 /*USE_SUPPLIED*/ | 0x400 /*ALLOW_CHANGES*/ | 0x200 /*SAVE_TO_DB*/);
        Log += "  SetDisplayConfig(supplied) = " + r + "\r\n";
        return r;
    }
}

[ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPolicyConfig {
    int GetMixFormat(); int GetDeviceFormat(); int ResetDeviceFormat(); int SetDeviceFormat();
    int GetProcessingPeriod(); int SetProcessingPeriod(); int GetShareMode(); int SetShareMode();
    int GetPropertyValue(); int SetPropertyValue();
    [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int role);
    int SetEndpointVisibility();
}
[ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")] class CPolicyConfigClient {}
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
    int Activate(ref Guid iid, int clsCtx, IntPtr p, out IntPtr ppInterface);
    int OpenPropertyStore(int access, out IntPtr props);
    [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
}
[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
    int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
    [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
}
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator {}
public static class AudioSwitch {
    public static int SetDefault(string id) {
        IPolicyConfig pc = (IPolicyConfig)new CPolicyConfigClient();
        int hr = 0;
        for (int role = 0; role < 3; role++) { int r = pc.SetDefaultEndpoint(id, role); if (r != 0) hr = r; }
        return hr;
    }
    public static string GetDefaultId() {
        IMMDeviceEnumerator en = (IMMDeviceEnumerator)new MMDeviceEnumerator();
        IMMDevice dev;
        if (en.GetDefaultAudioEndpoint(0, 1, out dev) != 0 || dev == null) return null;
        string id; dev.GetId(out id); return id;
    }
}
'@
}

function Get-PlaybackDevices {
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
    Get-ChildItem $root | ForEach-Object {
        $state = (Get-ItemProperty $_.PSPath).DeviceState
        $p = Get-ItemProperty (Join-Path $_.PSPath 'Properties') -ErrorAction SilentlyContinue
        $desc = $p.'{a45c254e-df1c-4efd-8020-67d146a850e0},2'
        $iface = $p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
        [pscustomobject]@{ Name = if ($iface) { "$desc ($iface)" } else { "$desc" }; Active = ($state -eq 1); Id = '{0.0.0.00000000}.' + $_.PSChildName }
    }
}
function Set-AudioWithRetry([scriptblock]$pick, [string]$label, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    do {
        $dev = & $pick | Select-Object -First 1
        if ($dev -and [AudioSwitch]::SetDefault($dev.Id) -eq 0) { Log "audio -> $($dev.Name)"; return }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    Log "audio: could not switch to $label"
}

$mmt = Join-Path $here 'MultiMonitorTool.exe'
function MMT([string]$argLine) { Start-Process -FilePath $mmt -ArgumentList $argLine -Wait -WindowStyle Hidden }
function Get-ActiveScreens {
    $tmp = Join-Path $here 'snap.tmp'
    MMT "/scomma `"$tmp`""
    Import-Csv $tmp | Where-Object { $_.Active -eq 'Yes' }
}

# Make sure the screens that are on sit in the configured physical order, the right one is main,
# and each runs its native resolution at its highest refresh rate. Only touches anything if it's wrong.
function Enforce-Layout([string[]]$on) {
    $order = @($ORDER | Where-Object { $on -contains $_ })
    $primary = if ($MAIN_ID -and ($on -contains $MAIN_ID)) { $MAIN_ID } else { $order[0] }
    $snap = $null
    for ($i = 0; $i -lt 4; $i++) {           # screens can take a moment to report in
        $snap = @(Get-ActiveScreens)
        $missing = @($order | Where-Object { $id = $_; -not ($snap | Where-Object { $_.'Short Monitor ID' -eq $id }) })
        if ($missing.Count -eq 0) { break }
        Start-Sleep -Milliseconds 300
    }
    if ($missing.Count -gt 0) { Log "layout: not active yet: $($missing -join ', ')"; return }

    # x positions: primary at 0, others packed to its left/right in physical order
    $x = @{}; $p = [array]::IndexOf($order, $primary); $x[$primary] = 0
    $cur = 0; for ($i = $p - 1; $i -ge 0; $i--) { $cur -= $RES[$order[$i]][0]; $x[$order[$i]] = $cur }
    $cur = $RES[$primary][0]; for ($i = $p + 1; $i -lt $order.Count; $i++) { $x[$order[$i]] = $cur; $cur += $RES[$order[$i]][0] }

    $need = $false; $parts = @()
    foreach ($id in $order) {
        $m = $snap | Where-Object { $_.'Short Monitor ID' -eq $id } | Select-Object -First 1
        $w = $RES[$id][0]; $h = $RES[$id][1]
        $max = [Ccd]::MaxRefresh($m.Name, $w, $h)
        if ($max -le 0) { $max = [int]$m.Frequency }
        $lt = $m.'Left-Top' -split ',\s*'
        $curRes = $m.Resolution -split ' X '
        $ok = ([int]$lt[0] -eq $x[$id]) -and ([int]$lt[1] -eq 0) -and ([int]$curRes[0] -eq $w) -and ([int]$curRes[1] -eq $h) -and
              ([int]$m.Frequency -ge $max - 1) -and (($m.Primary -eq 'Yes') -eq ($id -eq $primary))
        if (-not $ok) { $need = $true }
        Log ("  {0}: {1} at ({2}) {3}Hz -> want {4}x{5} at ({6},0) {7}Hz{8}" -f $id, $m.Resolution, ($lt -join ','), $m.Frequency, $w, $h, $x[$id], $max, $(if ($id -eq $primary) { ' main' } else { '' }))
        $s = "Name=$id Width=$w Height=$h DisplayFrequency=$max PositionX=$($x[$id]) PositionY=0"
        if ($id -eq $primary) { $s += ' Primary=1' }
        $parts += "`"$s`""
    }
    if ($need) { Log 'layout: fixing'; MMT ('/SetMonitors ' + ($parts -join ' ')) } else { Log 'layout: already correct' }
}

# Slow backup plan if the one-step switch fails: turn everything on with Windows' own tool, then trim with MultiMonitorTool
function Fallback([string[]]$on, [string[]]$off) {
    Log 'fallback: DisplaySwitch /extend + MultiMonitorTool'
    Start-Process DisplaySwitch.exe -ArgumentList '/extend' -Wait
    Start-Sleep -Seconds 3
    $primary = if ($MAIN_ID -and ($on -contains $MAIN_ID)) { $MAIN_ID } else { $on[0] }
    MMT "/SetPrimary $primary"; Start-Sleep -Seconds 2
    if ($off) { MMT ("/disable " + ($off -join ' ')); Start-Sleep -Seconds 1 }
}

function Switch-Displays([string[]]$on, [string[]]$off) {
    try {
        $r = [Ccd]::Apply($on)
        Log ("displays:`r`n" + [Ccd]::Log.TrimEnd())
    } catch { $r = -2; Log "displays: error $_" }
    if ($r -ne 0) { Fallback $on $off }
    Log 'displays done'
}


# ---------------- TV control (Android TV over ADB) ----------------
# TV commands run in a separate background process (-Mode tvaction) so they never slow the screen switch down.
function Tv-Async([string]$action) {
    if (-not $TV_IP) { Log 'tv: no TV address in config.json, skipping'; return }
    Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Mode', 'tvaction', '-TvAction', $action)
    Log "tv: started '$action' in the background (see tv-log.txt)"
}

function Find-Adb {
    $c = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @((Join-Path $here 'adb.exe'), (Join-Path $here 'platform-tools\adb.exe'))) { if (Test-Path $p) { return $p } }
    return $null
}
function Adb-Shell([string]$cmd) { return ((& $script:Adb -s $script:Target shell $cmd 2>&1 | Out-String).Trim()) }
function Tv-Connect {
    $r = (& $script:Adb connect $script:Target 2>&1 | Out-String).Trim()
    Log "adb connect: $r"
    return (($r -match 'connected to') -or ($r -match 'already connected'))
}
# Remember the TV's hardware address so it can be woken with Wake-on-LAN if ADB can't reach it
function Remember-Mac {
    $a = (arp -a $TV_IP 2>$null | Out-String)
    if ($a -match '((?:[0-9a-fA-F]{2}-){5}[0-9a-fA-F]{2})') { Set-Content -Path (Join-Path $here 'tv-mac.txt') -Value ($matches[1] -replace '-', ':') }
}
# Is the TV's ADB port answering? (quick check, so we never sit through a 20 second adb timeout)
function Test-Tcp([int]$timeoutMs = 1500) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($TV_IP, $TV_PORT, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($timeoutMs, $false)
        if ($ok) { try { $c.EndConnect($iar) } catch { $ok = $false } }
        return $ok
    } catch { return $false } finally { $c.Close() }
}
function Send-Wol {
    $f = Join-Path $here 'tv-mac.txt'
    if (-not (Test-Path $f)) { Log 'wol: no saved MAC address yet (it is saved the first time the TV answers)'; return $false }
    $hex = (Get-Content $f -TotalCount 1).Trim() -split '[:-]'
    if ($hex.Count -ne 6) { return $false }
    $mac = [byte[]]($hex | ForEach-Object { [Convert]::ToByte($_, 16) })
    $pkt = [byte[]]((@(255) * 6) + (@($mac) * 16))
    # to everyone, to the home network's broadcast address, and straight to the TV - some TVs only listen to one of them
    $targets = @('255.255.255.255')
    if ($TV_IP -match '^(\d+\.\d+\.\d+)\.\d+$') { $targets += ($matches[1] + '.255'); $targets += $TV_IP }
    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.EnableBroadcast = $true
        for ($i = 0; $i -lt 3; $i++) {
            foreach ($t in $targets) { foreach ($port in 9, 7) { try { [void]$udp.Send($pkt, $pkt.Length, $t, $port) } catch {} } }
            Start-Sleep -Milliseconds 200
        }
    } finally { $udp.Close() }
    Log 'wol: magic packets sent'
    return $true
}

function Do-TvAction([string]$action) {
    $script:Adb = Find-Adb
    if (-not $script:Adb) { Log 'tv: adb not found (install it, or put adb.exe next to this script)'; return }
    $script:Target = "${TV_IP}:$TV_PORT"
    $reach = Test-Tcp
    if ((-not $reach) -and (($action -eq 'wake') -or ($action -eq 'show'))) {
        Log 'tv: not answering - trying to wake it over the network'
        if (Send-Wol) {
            for ($i = 0; ($i -lt 14) -and (-not $reach); $i++) { Start-Sleep -Seconds 2; $reach = Test-Tcp }
        }
    }
    if (-not $reach) {
        Log "tv: $($script:Target) is not answering. The TV is off or in deep standby; use the remote, or turn on Wake on Wi-Fi/LAN (or Instant Power On) in the TV's power settings."
        return
    }
    if (-not (Tv-Connect)) { Log "tv: adb could not connect to $($script:Target) (is network debugging on?)"; return }
    Remember-Mac
    switch ($action) {
        'sleep' { [void](Adb-Shell 'input keyevent KEYCODE_SLEEP'); Log 'tv: sleep sent' }
        'wake'  { [void](Adb-Shell 'input keyevent KEYCODE_WAKEUP'); Log 'tv: wake sent' }
        'show'  {
            # wake it, remember what it was showing (for "previous app"), then jump to the PC's input
            [void](Adb-Shell 'input keyevent KEYCODE_WAKEUP')
            Start-Sleep -Milliseconds 1200
            $top = Adb-Shell 'dumpsys activity activities | grep mResumedActivity'
            if ($top -match 'u0 ([\w\.]+)/([\w\.\$]+)') {
                $pkg = $matches[1]; $act = $matches[2]
                if ($pkg -ne $TV_APP) { Set-Content -Path (Join-Path $here 'tv-last-app.txt') -Value "$pkg/$act"; Log "tv: remembered $pkg/$act" }
                else { Log 'tv: was already on its TV/HDMI screen, keeping the remembered app' }
            } else { Log "tv: could not read the foreground app: $top" }
            $uri = 'content://android.media.tv/passthrough/' + [uri]::EscapeDataString($TV_HDMI_INPUT)
            $o = Adb-Shell "am start -a android.intent.action.VIEW -d $uri"
            if ($o -match 'Error|Exception') { Log "tv: switching input said: $o" }
            Log 'tv: switched to the PC input'
        }
        'leave' {
            # only if the TV is showing the PC's input right now (so YouTube etc. are never interrupted)
            $check = Adb-Shell "dumpsys window | grep mCurrentFocus | grep -q $TV_APP && dumpsys tv_input | grep -q 'inputId: $TV_HDMI_INPUT' && echo yes"
            if ($check -notmatch 'yes') { Log 'tv: not on the PC input, leaving it alone'; return }
            $lastFile = Join-Path $here 'tv-last-app.txt'
            if (($RETURN_TO -eq 'previous') -and (Test-Path $lastFile)) {
                $comp = (Get-Content $lastFile -TotalCount 1).Trim()
                if ($comp -match '^([\w\.]+)/') {
                    $pkg = $matches[1]
                    # open the app the way the TV's own launcher does (its front door), not one inner screen of it.
                    # The inner screen we remembered (e.g. YouTube's MainActivity) often does nothing when opened cold.
                    $bad = 'No activities found|monkey aborted|Error|Exception|does not exist'
                    $o = Adb-Shell "monkey -p $pkg -c android.intent.category.LEANBACK_LAUNCHER 1"
                    Log "tv: open $pkg (TV launcher entry) -> $(($o -split "`n" | Select-Object -First 3) -join ' | ')"
                    if ($o -match $bad) {
                        $o = Adb-Shell "monkey -p $pkg -c android.intent.category.LAUNCHER 1"
                        Log "tv: open $pkg (phone launcher entry) -> $(($o -split "`n" | Select-Object -First 3) -join ' | ')"
                    }
                    if ($o -match $bad) {
                        $o = Adb-Shell "am start -n '$comp'"
                        Log "tv: open $comp -> $o"
                    }
                    return
                }
            }
            [void](Adb-Shell 'input keyevent KEYCODE_HOME')
            Log 'tv: sent Home'
        }
    }
}

# ---------------- list: what the Settings window needs ----------------
function Write-Targets {
    $info = @{}
    $tmp = Join-Path $here 'snap.tmp'
    MMT "/scomma `"$tmp`""
    if (Test-Path $tmp) {
        foreach ($row in (Import-Csv $tmp)) {
            if ($row.Resolution -match '(\d+)\s*X\s*(\d+)') { $info[$row.'Short Monitor ID'] = @([int]$matches[1], [int]$matches[2]) }
        }
    }
    $screens = @{}
    foreach ($line in ([Ccd]::List() -split "`n")) {
        if (-not $line.Trim()) { continue }
        $p = $line.Trim() -split '\|'
        $id = $p[0]; $active = ($p[2] -eq '1')
        if ($screens.ContainsKey($id)) { if ($active) { $screens[$id].active = $true }; continue }
        $w = 1920; $h = 1080
        if ($info.ContainsKey($id)) { $w = $info[$id][0]; $h = $info[$id][1] }
        if ($w -eq 4096) { $w = 3840 }          # TVs report DCI 4K; the normal 4K picture is 3840
        $screens[$id] = [pscustomobject]@{ id = $id; name = $p[1]; active = $active; width = $w; height = $h }
    }
    $audio = @(Get-PlaybackDevices | Where-Object { $_.Active -and $_.Name } | ForEach-Object { $_.Name } | Sort-Object -Unique)
    $obj = [ordered]@{ screens = @($screens.Values); audio = $audio }
    $out = Join-Path $here 'targets.json'
    $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $out -Encoding UTF8
    Log "saved $out ($($screens.Count) screens)"
}

$saveFile = Join-Path $here 'last-audio.txt'

switch ($Mode) {
    'list'     { Write-Targets }
    'tvaction' { Do-TvAction $TvAction }
    'tv' {
        if ($TV_IDS.Count -eq 0) { Log 'No TV screen is set in Settings - nothing to do'; break }
        if ($TV_AUDIO) {
            $cur = [AudioSwitch]::GetDefaultId()
            $curDev = Get-PlaybackDevices | Where-Object { $_.Id -eq $cur }
            if ($cur -and ($curDev.Name -notlike "*$TV_AUDIO*")) { Set-Content -Path $saveFile -Value $cur }
        }
        Switch-Displays $TV_IDS $DESKTOP_IDS
        Tv-Async 'show'
        if ($TV_AUDIO) { Set-AudioWithRetry { Get-PlaybackDevices | Where-Object { $_.Active -and $_.Name -like "*$TV_AUDIO*" } } $TV_AUDIO 12 }
        Enforce-Layout $TV_IDS
    }
    'desk' {
        if ($DESKTOP_IDS.Count -eq 0) { Log 'No desktop screens are set in Settings - nothing to do'; break }
        Switch-Displays $DESKTOP_IDS $TV_IDS
        if ($TV_IDS.Count -gt 0) { Tv-Async 'leave' }
        if (Test-Path $saveFile) {
            $id = (Get-Content $saveFile -TotalCount 1).Trim()
            Set-AudioWithRetry { Get-PlaybackDevices | Where-Object { $_.Active -and $_.Id -eq $id } } 'saved device' 8
        }
        Enforce-Layout $DESKTOP_IDS
    }
    'all' {
        if ($ORDER.Count -eq 0) { Log 'No screens are set in Settings - nothing to do'; break }
        Switch-Displays $ORDER @()
        if ($TV_IDS.Count -gt 0) { Tv-Async 'show' }
        Enforce-Layout $ORDER
    }
}
Log 'finished'
