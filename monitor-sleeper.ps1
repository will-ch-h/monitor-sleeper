# monitor-sleeper -- puts one monitor into DPMS standby (DDC/CI VCP D6) when it's not
# being used, and wakes it the moment you look at it again. Settings live in settings.json.
#
#   .\monitor-sleeper.ps1 -List    show detected monitors, pick your displayIndex
#   .\monitor-sleeper.ps1 -Test    console, prints every decision, touches no hardware
#   .\monitor-sleeper.ps1          tray icon
param([switch]$Test, [switch]$List)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
public class Mon {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct PHYSICAL_MONITOR {
    public IntPtr Handle;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
  }
  delegate bool EnumProc(IntPtr h, IntPtr hdc, ref RECT r, IntPtr data);

  [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, EnumProc cb, IntPtr data);
  [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
  [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, out uint n);
  [DllImport("dxva2.dll")] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PHYSICAL_MONITOR[] a);
  [DllImport("dxva2.dll")] static extern bool DestroyPhysicalMonitor(IntPtr h);
  [DllImport("dxva2.dll")] static extern bool SetVCPFeature(IntPtr h, byte code, uint value);

  // ponytail: re-enumerated on every call. It's a handful of monitors every 15s, and it
  // survives hotplug/undock for free. Cache it if you ever see this in a profile.
  static List<IntPtr> Handles() {
    List<IntPtr> found = new List<IntPtr>();
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero,
      delegate(IntPtr h, IntPtr hdc, ref RECT r, IntPtr d) { found.Add(h); return true; }, IntPtr.Zero);
    return found;
  }

  public static POINT Cursor() { POINT p; GetCursorPos(out p); return p; }

  [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
  static extern uint ExtractIconEx(string file, int index, IntPtr[] large, IntPtr[] small, uint count);

  // HICON for an icon inside a DLL, or Zero. Held for the life of the process, so no DestroyIcon.
  public static IntPtr IconHandle(string file, int index) {
    IntPtr[] large = new IntPtr[1]; IntPtr[] small = new IntPtr[1];
    return ExtractIconEx(file, index, large, small, 1) > 0 ? large[0] : IntPtr.Zero;
  }

  public static string[] Describe() {
    List<IntPtr> hs = Handles();
    string[] lines = new string[hs.Count];
    for (int i = 0; i < hs.Count; i++) {
      RECT r = Bounds(i);
      string name = "?";
      uint n; PHYSICAL_MONITOR[] pm = new PHYSICAL_MONITOR[1];
      if (GetNumberOfPhysicalMonitorsFromHMONITOR(hs[i], out n) && n > 0 &&
          GetPhysicalMonitorsFromHMONITOR(hs[i], 1, pm)) {
        name = pm[0].Description; DestroyPhysicalMonitor(pm[0].Handle);
      }
      lines[i] = string.Format("[{0}] {1}  {2}x{3} at ({4},{5})",
        i, name, r.R - r.L, r.B - r.T, r.L, r.T);
    }
    return lines;
  }

  public static RECT Bounds(int index) {
    List<RECT> rects = new List<RECT>();
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero,
      delegate(IntPtr h, IntPtr hdc, ref RECT r, IntPtr d) { rects.Add(r); return true; }, IntPtr.Zero);
    return index >= 0 && index < rects.Count ? rects[index] : new RECT();
  }

  // Index of the monitor holding the foreground window, or -1. ~0.03ms, so it's the
  // fast path: a GlazeWM workspace switch moves focus, which shows up here immediately.
  public static int ForegroundMonitor() {
    IntPtr m = MonitorFromWindow(GetForegroundWindow(), 2 /* NEAREST */);
    return Handles().IndexOf(m);
  }

  // Index of the monitor the cursor is on, or -1.
  public static int CursorMonitor() {
    POINT p; if (!GetCursorPos(out p)) return -1;
    List<RECT> rects = new List<RECT>();
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero,
      delegate(IntPtr h, IntPtr hdc, ref RECT r, IntPtr d) { rects.Add(r); return true; }, IntPtr.Zero);
    for (int i = 0; i < rects.Count; i++)
      if (p.X >= rects[i].L && p.X < rects[i].R && p.Y >= rects[i].T && p.Y < rects[i].B) return i;
    return -1;
  }

  // Only DDC write this program makes: VCP 0xD6, the DPMS power state. Volatile, so unlike
  // brightness (0x10) it costs no monitor NVRAM write cycles.
  public static bool SetPower(int index, uint value) {
    List<IntPtr> hs = Handles();
    if (index < 0 || index >= hs.Count) return false;
    uint n; PHYSICAL_MONITOR[] pm = new PHYSICAL_MONITOR[1];
    if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hs[index], out n) || n == 0) return false;
    if (!GetPhysicalMonitorsFromHMONITOR(hs[index], 1, pm)) return false;
    bool ok = SetVCPFeature(pm[0].Handle, 0xD6, value);
    DestroyPhysicalMonitor(pm[0].Handle);
    return ok;
  }
}
'@

if ($List) { [Mon]::Describe(); exit }

$script:cfgPath  = Join-Path $PSScriptRoot 'settings.json'
$script:cfgStamp = [datetime]::MinValue

# Re-reads settings.json when its timestamp moves. Returns $true if the config changed.
function Update-Config {
  $t = (Get-Item $script:cfgPath).LastWriteTimeUtc
  if ($t -eq $script:cfgStamp) { return $false }
  try {
    $script:cfg = Get-Content $script:cfgPath -Raw | ConvertFrom-Json
    $script:cfgStamp = $t
    return $true
  } catch {
    # ponytail: stamp not advanced, so a half-written file is retried on the next poll.
    Write-Warning "settings.json unreadable, keeping previous values: $($_.Exception.Message)"
    return $false
  }
}

if (-not (Update-Config)) { throw "Could not read $script:cfgPath" }

$script:glazeMons = $null                    # last `glazewm query monitors` result, $null = query failed
$script:glazeAt   = [datetime]::MinValue
$script:enabled   = $true
$script:timer     = $null
$script:state     = @{}                      # displayIndex -> @{ asleep; lastUsed }
$script:lastKey   = @{}                      # displayIndex -> last printed -Test line
$script:lastCursorMon = [Mon]::CursorMonitor()
$script:lastPos       = [Mon]::Cursor()

# pollSeconds may be fractional (0.5 = twice a second). Floor of 50ms so a typo'd 0 can't spin.
function Get-PollMs { [Math]::Max(50, [int]($cfg.pollSeconds * 1000)) }

# One entry per controlled display. A settings.json without a "displays" list is read as a
# single display from the top-level keys, so old config files keep working.
function Get-Displays {
  if ($cfg.displays) { return @($cfg.displays) }
  return @([pscustomobject]@{
    displayIndex        = $cfg.displayIndex
    glazeMonitorIndex   = $cfg.glazeMonitorIndex
    keepAwakeWorkspaces = $cfg.keepAwakeWorkspaces
  })
}

function Get-State([int]$index) {
  if (-not $script:state.ContainsKey($index)) {
    $script:state[$index] = @{ asleep = $false; lastUsed = Get-Date }
  }
  return $script:state[$index]
}

# One query serves every display, so two monitors cost the same 21ms as one.
function Get-GlazeMonitors {
  if (((Get-Date) - $script:glazeAt).TotalSeconds -lt $cfg.glazePollSeconds) { return $script:glazeMons }
  $script:glazeAt = Get-Date
  try { $script:glazeMons = (glazewm query monitors | ConvertFrom-Json).data.monitors }
  catch { $script:glazeMons = $null }
  return $script:glazeMons
}

# True while GlazeWM shows one of this display's keepAwakeWorkspaces on it, with windows.
function Test-GlazeKeepAwake($d) {
  if (-not $d.keepAwakeWorkspaces) { return $false }
  $mons = Get-GlazeMonitors
  # ponytail: GlazeWM missing or query broken -> stay awake. Fail lit, not dark.
  if ($null -eq $mons) { return $true }
  try {
    $m  = $mons[$d.glazeMonitorIndex]
    $ws = $m.children | Where-Object { $_.isDisplayed }
    if (-not $ws) { $ws = $m.children[0] }
    # Compared as strings, so named workspaces ("web", "chat") work as well as numbers.
    $named = [string[]]$d.keepAwakeWorkspaces -contains [string]$ws.name
    return ($named -and $ws.children.Count -gt 0)
  } catch { return $true }
}

# The one place power changes.
function Set-Display([bool]$sleep, [int]$index) {
  $v = if ($sleep) { [uint32]$cfg.offValue } else { [uint32]1 }
  if ($Test) { Write-Host "  -> would set D6=$v on display $index" }
  elseif (-not [Mon]::SetPower($index, $v)) { Write-Warning "SetVCPFeature D6=$v failed" }
  (Get-State $index).asleep = $sleep
}

function Wake-All {
  foreach ($i in @($script:state.Keys)) {
    if ($script:state[$i].asleep) { Set-Display $false $i }
    $script:state[$i].lastUsed = Get-Date
  }
}

# Returns the number of displays now asleep.
function Step {
  if (Update-Config) {
    if ($Test) { Write-Host 'settings.json reloaded' -ForegroundColor Cyan }
    # Wake everything we slept under the old settings, then re-decide from scratch. Keyed by
    # state, not config, so a display dropped from the list still gets turned back on.
    Wake-All
    if ($script:timer) { $script:timer.Interval = Get-PollMs }
  }
  # Cheap native checks, ~0.1ms total, and shared by every display. "In use" is per-display:
  # system-wide input does NOT count, or typing on the primary would keep them all lit.
  $cursor = [Mon]::CursorMonitor()
  $fg     = [Mon]::ForegroundMonitor()
  $pos    = [Mon]::Cursor()
  # Mouse counts only while it's on the display AND actually moving -- a cursor parked
  # there and forgotten shouldn't hold it awake forever.
  $moved  = $pos.X -ne $script:lastPos.X -or $pos.Y -ne $script:lastPos.Y

  $asleepCount = 0
  foreach ($d in Get-Displays) {
    $i  = [int]$d.displayIndex
    $st = Get-State $i

    $entered = $cursor -eq $i -and $script:lastCursorMon -ne $i
    $mouse   = $cfg.wakeOnMouseEnter -and $cursor -eq $i -and ($moved -or $entered)
    # Focus here means keystrokes are landing here, so this is the keyboard rule too.
    $focused = $cfg.wakeOnFocus -and $fg -eq $i

    $glaze = if ($mouse -or $focused) { $false } else { Test-GlazeKeepAwake $d }
    if ($mouse -or $focused -or $glaze) { $st.lastUsed = Get-Date }

    $idle  = [int]((Get-Date) - $st.lastUsed).TotalSeconds
    $limit = if ($null -ne $d.idleSeconds) { $d.idleSeconds } else { $cfg.idleSeconds }
    $want  = $script:enabled -and $idle -ge $limit

    if ($Test) {
      # ponytail: only print when something other than the idle counter moves -- at a 0.5s
      # tick, every-tick output is unreadable.
      $key = "$i|$fg|$cursor|$mouse|$focused|$glaze|$($script:enabled)|$want"
      if ($key -ne $script:lastKey[$i]) {
        $script:lastKey[$i] = $key
        Write-Host ("display {0}: unused={1,-4}s/{2,-4}s fgMon={3,-3} cursorMon={4,-3} mouse={5,-5} focus={6,-5} glazeKeep={7,-5} -> {8}" -f `
          $i, $idle, $limit, $fg, $cursor, $mouse, $focused, $glaze, $(if ($want) { 'ASLEEP' } else { 'awake' }))
      }
    }
    if ($want -ne $st.asleep) { Set-Display $want $i }
    if ($want) { $asleepCount++ }
  }

  $script:lastCursorMon = $cursor
  $script:lastPos = $pos
  return $asleepCount
}

if ($Test) {
  # Milliseconds, not -Seconds: that parameter is [int] on PS 5.1, so 0.5 would round to a busy loop.
  while ($true) { Step | Out-Null; Start-Sleep -Milliseconds (Get-PollMs) }
  exit
}

$tray = New-Object System.Windows.Forms.NotifyIcon
# ddores.dll #17 is the generic display icon -- the one that still reads as a monitor at 16px.
$hIcon = [Mon]::IconHandle("$env:SystemRoot\System32\ddores.dll", 17)
$tray.Icon = if ($hIcon -ne [IntPtr]::Zero) { [System.Drawing.Icon]::FromHandle($hIcon) }
             else { [System.Drawing.SystemIcons]::Application }
$tray.Text = 'monitor-sleeper'
$tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$toggle = $menu.Items.Add('Enabled')
$toggle.Checked = $true
$toggle.Add_Click({
  $script:enabled = -not $script:enabled
  $this.Checked = $script:enabled
  if (-not $script:enabled) { Wake-All } else { foreach ($i in @($script:state.Keys)) { $script:state[$i].lastUsed = Get-Date } }
})
$menu.Items.Add('Sleep now').Add_Click({ foreach ($d in Get-Displays) { Set-Display $true ([int]$d.displayIndex) } })
$menu.Items.Add('-') | Out-Null
$menu.Items.Add('Exit').Add_Click({
  Wake-All
  $tray.Visible = $false
  [System.Windows.Forms.Application]::Exit()
})
$tray.ContextMenuStrip = $menu

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = Get-PollMs
$script:timer.Add_Tick({
  $sleeping = Step
  $total = (Get-Displays).Count
  $tray.Text = if (-not $script:enabled) { 'monitor-sleeper: disabled' }
               else { "monitor-sleeper: $sleeping of $total asleep" }
})
$script:timer.Start()

[System.Windows.Forms.Application]::Run()
