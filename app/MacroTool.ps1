<#
.SYNOPSIS
    MacroTool - zero-dependency Windows macro recorder/player targeting a PID.

    Pure PowerShell (5.1+) + Win32 P/Invoke. No Python, no pip, no installs.

.DESCRIPTION
    Records keyboard + mouse actions by polling input state, saves them as JSON,
    and replays them against a specific process (by PID) after focusing its
    window. Supports initial delay, repeat count and interval scheduling.

.EXAMPLE
    # List processes / PIDs matching a name
    .\MacroTool.ps1 pids -Name notepad

.EXAMPLE
    # Record (press F9 to stop)
    .\MacroTool.ps1 record -Name login

.EXAMPLE
    # Replay against PID 12345: wait 5s, run 3 times, 10s apart
    .\MacroTool.ps1 play -Name login -TargetPid 12345 -Delay 5 -Repeat 3 -Interval 10

.EXAMPLE
    .\MacroTool.ps1 list
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('record', 'play', 'list', 'pids', 'windows', 'checkenv')]
    [string]$Command,

    [string]$Name,
    [int]$TargetPid,
    [long]$TargetHwnd,
    [string]$ProcName,

    [double]$Delay = 0,
    [int]$Repeat = 1,
    [double]$Interval = 0,
    [double]$Speed = 1.0,

    [switch]$NoMove,

    [switch]$Json,

    [switch]$Background,

    [switch]$FlashRestore,

    [string]$StopFile,

    # Virtual-key code that stops a recording. Defaults to F9 (0x78) but can be
    # overridden (e.g. by the UI's shortcut setting) when F9 is already occupied.
    [int]$StopVk = 0x78,

    # Auto-stop safety nets:
    [double]$MaxRuntime = 300,   # hard wall-clock cap in seconds (0 = unlimited)
    [int]$WatchPid = 0           # if this PID (the launching UI) exits, stop playback
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Auto-stop safety: playback aborts when ANY of these becomes true.
#   1. -StopFile        : the file appears (manual/UI stop, focus-independent)
#   2. -WatchPid        : the launching UI process exits (dead-man's switch)
#   3. -MaxRuntime      : wall-clock runtime exceeds the cap (runaway guard)
# ---------------------------------------------------------------------------
$script:StopFilePath = $StopFile
$script:WatchPid     = $WatchPid
$script:MaxRuntime   = $MaxRuntime
$script:PlayStart    = $null   # set when playback begins

function Test-StopSignal {
    # 1. Manual/UI stop file
    if ($script:StopFilePath -and (Test-Path -LiteralPath $script:StopFilePath)) { return $true }
    # 2. Dead-man's switch: launching UI gone
    if ($script:WatchPid -gt 0) {
        if (-not (Get-Process -Id $script:WatchPid -ErrorAction SilentlyContinue)) { return $true }
    }
    # 3. Max-runtime cap
    if ($script:MaxRuntime -gt 0 -and $script:PlayStart) {
        if (([DateTime]::Now - $script:PlayStart).TotalSeconds -ge $script:MaxRuntime) { return $true }
    }
    return $false
}

# --------------------------------------------------------------------------
# Win32 interop
# --------------------------------------------------------------------------
if (-not ([System.Management.Automation.PSTypeName]'Win32.Native').Type) {
    Add-Type -Namespace Win32 -Name Native -MemberDefinition @"
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx; public int dy; public uint mouseData;
        public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort wVk; public ushort wScan; public uint dwFlags;
        public uint time; public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type;
        public INPUTUNION u;
    }

    [DllImport("user32.dll")]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder s, int n);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);

    // Per-monitor DPI awareness so GetCursorPos (record) and SendInput (play)
    // both work in physical pixels regardless of each monitor's scale factor.
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    public static extern IntPtr GetShellWindow();

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool ScreenToClient(IntPtr hWnd, ref POINT lpPoint);

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT p);

    [DllImport("user32.dll")]
    public static extern IntPtr ChildWindowFromPointEx(IntPtr hWnd, POINT pt, uint uFlags);

    [DllImport("user32.dll")]
    public static extern IntPtr RealChildWindowFromPoint(IntPtr hWnd, POINT pt);

    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder s, int n);

    [DllImport("user32.dll")]
    public static extern uint MapVirtualKey(uint uCode, uint uMapType);
"@
}

# Constants
$INPUT_MOUSE    = 0
$INPUT_KEYBOARD = 1

$MOUSEEVENTF_MOVE        = 0x0001
$MOUSEEVENTF_ABSOLUTE    = 0x8000
$MOUSEEVENTF_VIRTUALDESK = 0x4000
$MOUSEEVENTF_LEFTDOWN    = 0x0002
$MOUSEEVENTF_LEFTUP      = 0x0004
$MOUSEEVENTF_RIGHTDOWN   = 0x0008
$MOUSEEVENTF_RIGHTUP     = 0x0010
$MOUSEEVENTF_MIDDLEDOWN  = 0x0020
$MOUSEEVENTF_MIDDLEUP    = 0x0040
$MOUSEEVENTF_WHEEL       = 0x0800

$KEYEVENTF_KEYUP        = 0x0002
$KEYEVENTF_SCANCODE     = 0x0008
$KEYEVENTF_EXTENDEDKEY  = 0x0001

$SM_CXSCREEN = 0
$SM_CYSCREEN = 1
# Virtual screen (bounding box of ALL monitors) metrics. Non-primary monitors
# sit at positive or negative offsets within this rectangle, so absolute mouse
# input must be normalized against the virtual desktop rather than the primary
# screen alone.
$SM_XVIRTUALSCREEN  = 76
$SM_YVIRTUALSCREEN  = 77
$SM_CXVIRTUALSCREEN = 78
$SM_CYVIRTUALSCREEN = 79
$SW_RESTORE  = 9

# Virtual-key code that stops recording. Configurable via the -StopVk parameter
# (defaults to F9 = 0x78) so users can pick another key when F9 is taken.
$VK_STOP = $StopVk

# Friendly display name for a virtual-key code (used in prompts).
function Get-VkName([int]$vk) {
    $names = @{
        0x70='F1'; 0x71='F2'; 0x72='F3'; 0x73='F4'; 0x74='F5'; 0x75='F6';
        0x76='F7'; 0x77='F8'; 0x78='F9'; 0x79='F10'; 0x7A='F11'; 0x7B='F12';
        0x13='Pause'; 0x91='ScrollLock'; 0x2D='Insert'; 0x24='Home'; 0x23='End';
        0x21='PageUp'; 0x22='PageDown'; 0x1B='Esc'; 0x60='Num0'; 0x6A='Num*'
    }
    if ($names.ContainsKey($vk)) { return $names[$vk] }
    return ("VK 0x{0:X2}" -f $vk)
}

# Opt into per-monitor DPI awareness before capturing or replaying coordinates.
# Without this, Windows virtualizes cursor coordinates on high-DPI monitors and
# recorded points drift when played back on a differently-scaled display. Prefer
# the Per-Monitor-v2 context (Win10 1703+); fall back to system DPI awareness.
function Enable-DpiAwareness {
    try {
        # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = (HANDLE)-4
        $ctx = [IntPtr](-4)
        if ([Win32.Native]::SetProcessDpiAwarenessContext($ctx)) { return }
    } catch { }
    try { [void][Win32.Native]::SetProcessDPIAware() } catch { }
}
Enable-DpiAwareness

$script:MacrosDir = Join-Path $PSScriptRoot 'macros'

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
function Get-MacroPath([string]$n) {
    if (-not $n.EndsWith('.json')) { $n = "$n.json" }
    Join-Path $script:MacrosDir $n
}

function Save-Macro([string]$n, $events) {
    if (-not (Test-Path $script:MacrosDir)) {
        New-Item -ItemType Directory -Path $script:MacrosDir | Out-Null
    }
    $obj = [ordered]@{
        name    = $n
        created = (Get-Date).ToString('s')
        events  = $events
    }
    $obj | ConvertTo-Json -Depth 6 | Set-Content -Path (Get-MacroPath $n) -Encoding UTF8
}

function Load-Macro([string]$n) {
    $path = Get-MacroPath $n
    if (-not (Test-Path $path)) { throw "Macro not found: $path" }
    Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

# --------------------------------------------------------------------------
# Window / PID targeting
# --------------------------------------------------------------------------
function Get-HwndsForPid([int]$targetPid) {
    $found = New-Object System.Collections.ArrayList
    $cb = [Win32.Native+EnumWindowsProc] {
        param($hWnd, $lParam)
        if ([Win32.Native]::IsWindowVisible($hWnd)) {
            $procId = 0
            [void][Win32.Native]::GetWindowThreadProcessId($hWnd, [ref]$procId)
            if ($procId -eq $script:__pid) {
                $sb = New-Object System.Text.StringBuilder 512
                [void][Win32.Native]::GetWindowText($hWnd, $sb, $sb.Capacity)
                $title = $sb.ToString()
                if ($title) {
                    [void]$found.Add([pscustomobject]@{ Hwnd = $hWnd; Title = $title })
                }
            }
        }
        return $true
    }
    $script:__pid = $targetPid
    [void][Win32.Native]::EnumWindows($cb, [IntPtr]::Zero)
    return $found
}

# Constants for real top-level window filtering (mirrors LivePreview approach).
$GWL_EXSTYLE      = -20
$WS_EX_TOOLWINDOW = 0x00000080
$WS_EX_APPWINDOW  = 0x00040000
$GW_OWNER         = 4

function Get-FriendlyName([int]$procId, [string]$fallbackTitle) {
    # Priority: FileDescription (localized product name) > window title > process name.
    try {
        $proc = Get-Process -Id $procId -ErrorAction Stop
        try {
            if ($proc.MainModule -and $proc.MainModule.FileVersionInfo) {
                $fd = $proc.MainModule.FileVersionInfo.FileDescription
                if ($fd -and $fd.Trim()) { return $fd.Trim() }
            }
        } catch {}
        if ($fallbackTitle -and $fallbackTitle.Trim()) { return $fallbackTitle.Trim() }
        return $proc.ProcessName
    } catch {
        if ($fallbackTitle) { return $fallbackTitle }
        return "unknown"
    }
}

function Get-VisibleWindows {
    # Enumerate real, user-facing top-level windows (the programs a user started),
    # each resolved to a friendly instance name + PID. No PID hunting required.
    $found = New-Object System.Collections.ArrayList
    $shell = [Win32.Native]::GetShellWindow()

    $cb = [Win32.Native+EnumWindowsProc] {
        param($hWnd, $lParam)
        if (-not [Win32.Native]::IsWindowVisible($hWnd)) { return $true }
        if ($hWnd -eq $script:__shell) { return $true }

        $exStyle = [Win32.Native]::GetWindowLong($hWnd, $script:__gwlex)
        # Skip tool windows that are not app windows.
        if (($exStyle -band $script:__extool) -ne 0 -and ($exStyle -band $script:__exapp) -eq 0) {
            return $true
        }
        $len = [Win32.Native]::GetWindowTextLength($hWnd)
        if ($len -eq 0) { return $true }
        # Skip owned windows (dialogs) unless flagged as app windows.
        $owner = [Win32.Native]::GetWindow($hWnd, $script:__gwowner)
        if ($owner -ne [IntPtr]::Zero -and ($exStyle -band $script:__exapp) -eq 0) {
            return $true
        }

        $sb = New-Object System.Text.StringBuilder ($len + 1)
        [void][Win32.Native]::GetWindowText($hWnd, $sb, $sb.Capacity)
        $title = $sb.ToString()

        $wpid = 0
        [void][Win32.Native]::GetWindowThreadProcessId($hWnd, [ref]$wpid)
        $friendly = Get-FriendlyName $wpid $title

        [void]$script:__winlist.Add([pscustomobject]@{
            Hwnd = $hWnd; Title = $title; Pid = $wpid; Friendly = $friendly
        })
        return $true
    }

    $script:__shell   = $shell
    $script:__gwlex   = $GWL_EXSTYLE
    $script:__extool  = $WS_EX_TOOLWINDOW
    $script:__exapp   = $WS_EX_APPWINDOW
    $script:__gwowner = $GW_OWNER
    $script:__winlist = $found
    [void][Win32.Native]::EnumWindows($cb, [IntPtr]::Zero)

    # Sort by friendly name for a stable, browsable list.
    return @($found | Sort-Object Friendly, Title)
}

function Focus-Pid([int]$targetPid) {
    $hwnds = Get-HwndsForPid $targetPid
    if ($hwnds.Count -eq 0) { return $false }
    $hWnd = $hwnds[0].Hwnd

    if ([Win32.Native]::IsIconic($hWnd)) {
        [void][Win32.Native]::ShowWindow($hWnd, $SW_RESTORE)
    }
    $fg = [Win32.Native]::GetForegroundWindow()
    $curTid = 0; $tgtTid = 0; $tmp = 0
    $curTid = [Win32.Native]::GetWindowThreadProcessId($fg, [ref]$tmp)
    $tgtTid = [Win32.Native]::GetWindowThreadProcessId($hWnd, [ref]$tmp)

    $attached = $false
    try {
        if ($curTid -ne 0 -and $tgtTid -ne 0 -and $curTid -ne $tgtTid) {
            $attached = [Win32.Native]::AttachThreadInput($curTid, $tgtTid, $true)
        }
        [void][Win32.Native]::BringWindowToTop($hWnd)
        [void][Win32.Native]::SetForegroundWindow($hWnd)
    } finally {
        if ($attached) {
            [void][Win32.Native]::AttachThreadInput($curTid, $tgtTid, $false)
        }
    }
    Start-Sleep -Milliseconds 150
    return $true
}

# --------------------------------------------------------------------------
# SendInput builders
# --------------------------------------------------------------------------
function New-MouseInput([int]$flags, [int]$dx = 0, [int]$dy = 0, [uint32]$data = 0) {
    $inp = New-Object Win32.Native+INPUT
    $inp.type = $INPUT_MOUSE
    $mi = New-Object Win32.Native+MOUSEINPUT
    $mi.dx = $dx; $mi.dy = $dy; $mi.mouseData = $data
    $mi.dwFlags = $flags; $mi.time = 0; $mi.dwExtraInfo = [IntPtr]::Zero
    $u = New-Object Win32.Native+INPUTUNION
    $u.mi = $mi
    $inp.u = $u
    return $inp
}

function New-KeyInput([uint16]$vk, [bool]$up) {
    $inp = New-Object Win32.Native+INPUT
    $inp.type = $INPUT_KEYBOARD
    $ki = New-Object Win32.Native+KEYBDINPUT

    # Derive the hardware scan code so modifiers and extended keys register
    # reliably across apps (some ignore pure virtual-key injection).
    $scan = [Win32.Native]::MapVirtualKey([uint32]$vk, $MAPVK_VK_TO_VSC)

    # Extended-key flag is required for right-hand modifiers and the nav cluster.
    $extended = $false
    switch ($vk) {
        0xA3 { $extended = $true }  # VK_RCONTROL
        0xA5 { $extended = $true }  # VK_RMENU (Right Alt)
        0x21 { $extended = $true }  # PageUp
        0x22 { $extended = $true }  # PageDown
        0x23 { $extended = $true }  # End
        0x24 { $extended = $true }  # Home
        0x25 { $extended = $true }  # Left
        0x26 { $extended = $true }  # Up
        0x27 { $extended = $true }  # Right
        0x28 { $extended = $true }  # Down
        0x2D { $extended = $true }  # Insert
        0x2E { $extended = $true }  # Delete
        0x5B { $extended = $true }  # LWin
        0x5C { $extended = $true }  # RWin
    }

    if ($scan -ne 0) {
        # Scan-code path (most reliable). wVk must be 0 when using SCANCODE.
        $ki.wVk = 0
        $ki.wScan = [uint16]$scan
        $flags = $KEYEVENTF_SCANCODE
        if ($extended) { $flags = $flags -bor $KEYEVENTF_EXTENDEDKEY }
        if ($up)       { $flags = $flags -bor $KEYEVENTF_KEYUP }
        $ki.dwFlags = $flags
    } else {
        # Fallback to virtual-key injection if no scan code is available.
        $ki.wVk = $vk
        $ki.wScan = 0
        $ki.dwFlags = if ($up) { $KEYEVENTF_KEYUP } else { 0 }
    }
    $ki.time = 0; $ki.dwExtraInfo = [IntPtr]::Zero
    $u = New-Object Win32.Native+INPUTUNION
    $u.ki = $ki
    $inp.u = $u
    return $inp
}

function Send-Inputs([array]$inputs) {
    $arr = [Win32.Native+INPUT[]]$inputs
    $size = [System.Runtime.InteropServices.Marshal]::SizeOf([type]([Win32.Native+INPUT]))
    [void][Win32.Native]::SendInput([uint32]$arr.Length, $arr, $size)
}

function Move-MouseAbsolute([int]$x, [int]$y) {
    # Absolute SendInput coordinates are normalized to the 0..65535 range across
    # the whole virtual desktop. Using MOUSEEVENTF_VIRTUALDESK together with the
    # SM_*VIRTUALSCREEN metrics lets recorded points land correctly on secondary
    # monitors (which live at positive/negative offsets from the primary screen).
    $vx = [Win32.Native]::GetSystemMetrics($SM_XVIRTUALSCREEN)
    $vy = [Win32.Native]::GetSystemMetrics($SM_YVIRTUALSCREEN)
    $vw = [Win32.Native]::GetSystemMetrics($SM_CXVIRTUALSCREEN)
    $vh = [Win32.Native]::GetSystemMetrics($SM_CYVIRTUALSCREEN)

    # Fall back to the primary screen if the virtual metrics are unavailable
    # (older interop stubs / single-monitor probes return 0 width/height).
    if ($vw -le 0) { $vx = 0; $vw = [Win32.Native]::GetSystemMetrics($SM_CXSCREEN) }
    if ($vh -le 0) { $vy = 0; $vh = [Win32.Native]::GetSystemMetrics($SM_CYSCREEN) }
    if ($vw -le 1) { $vw = 1 }; if ($vh -le 1) { $vh = 1 }

    # Translate the absolute screen point into the virtual-desktop origin, then
    # scale to the normalized 0..65535 absolute coordinate space.
    $ax = [int]((($x - $vx) * 65535) / ($vw - 1))
    $ay = [int]((($y - $vy) * 65535) / ($vh - 1))

    # Clamp so slightly out-of-bounds recordings don't wrap to the far edge.
    if ($ax -lt 0) { $ax = 0 }; if ($ax -gt 65535) { $ax = 65535 }
    if ($ay -lt 0) { $ay = 0 }; if ($ay -gt 65535) { $ay = 65535 }

    $flags = $MOUSEEVENTF_MOVE -bor $MOUSEEVENTF_ABSOLUTE -bor $MOUSEEVENTF_VIRTUALDESK
    Send-Inputs @( (New-MouseInput $flags $ax $ay) )
}

# --------------------------------------------------------------------------
# Recorder (polling)
# --------------------------------------------------------------------------
# Virtual key codes we watch for button state.
$MOUSE_VKS = @{ 0x01 = 'left'; 0x02 = 'right'; 0x04 = 'middle' }  # VK_LBUTTON/RBUTTON/MBUTTON

function Invoke-Record([string]$n, [bool]$recordMoves) {
    Write-Host ("Recording... press {0} to stop." -f (Get-VkName $VK_STOP)) -ForegroundColor Yellow
    $events = New-Object System.Collections.ArrayList
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # previous states
    $prevBtn = @{ 'left' = $false; 'right' = $false; 'middle' = $false }
    $prevKeys = @{}
    $lastPt = New-Object Win32.Native+POINT
    [void][Win32.Native]::GetCursorPos([ref]$lastPt)
    $lastMoveT = 0.0
    $moveMinInterval = 1.0 / 30.0

    while ($true) {
        $t = $sw.Elapsed.TotalSeconds

        # stop key (F9)
        if (([Win32.Native]::GetAsyncKeyState($VK_STOP) -band 0x8000) -ne 0) {
            break
        }

        # mouse buttons
        foreach ($vk in $MOUSE_VKS.Keys) {
            $name = $MOUSE_VKS[$vk]
            $down = ([Win32.Native]::GetAsyncKeyState($vk) -band 0x8000) -ne 0
            if ($down -ne $prevBtn[$name]) {
                $pt = New-Object Win32.Native+POINT
                [void][Win32.Native]::GetCursorPos([ref]$pt)
                [void]$events.Add([ordered]@{
                    t = [math]::Round($t, 4); type = 'mouse_click'
                    button = $name; pressed = $down; x = $pt.X; y = $pt.Y
                })
                $prevBtn[$name] = $down
            }
        }

        # keyboard: scan VKs 0x08..0xFE, skip mouse buttons.
        # Skip the AGGREGATE modifier VKs (VK_SHIFT/CONTROL/MENU) because their
        # specific left/right variants (VK_LSHIFT..VK_RMENU, 0xA0-0xA5) also fire;
        # recording both would double every modifier press. We keep the L/R ones
        # so Ctrl/Alt/Shift are captured with correct handedness.
        for ($vk = 0x08; $vk -le 0xFE; $vk++) {
            if ($vk -eq 0x01 -or $vk -eq 0x02 -or $vk -eq 0x04 -or $vk -eq $VK_STOP) { continue }
            if ($vk -eq 0x10 -or $vk -eq 0x11 -or $vk -eq 0x12) { continue }  # aggregate Shift/Ctrl/Alt
            $down = ([Win32.Native]::GetAsyncKeyState($vk) -band 0x8000) -ne 0
            $was = $prevKeys[$vk]
            if ($down -and -not $was) {
                [void]$events.Add([ordered]@{ t = [math]::Round($t,4); type='key'; vk=$vk; pressed=$true })
                $prevKeys[$vk] = $true
            } elseif (-not $down -and $was) {
                [void]$events.Add([ordered]@{ t = [math]::Round($t,4); type='key'; vk=$vk; pressed=$false })
                $prevKeys[$vk] = $false
            }
        }

        # mouse move (throttled)
        if ($recordMoves -and ($t - $lastMoveT) -ge $moveMinInterval) {
            $pt = New-Object Win32.Native+POINT
            [void][Win32.Native]::GetCursorPos([ref]$pt)
            if ($pt.X -ne $lastPt.X -or $pt.Y -ne $lastPt.Y) {
                [void]$events.Add([ordered]@{ t=[math]::Round($t,4); type='mouse_move'; x=$pt.X; y=$pt.Y })
                $lastPt = $pt
                $lastMoveT = $t
            }
        }

        Start-Sleep -Milliseconds 8
    }

    Write-Host ("Recording stopped. Captured {0} events." -f $events.Count) -ForegroundColor Green
    if ($events.Count -gt 0) {
        Save-Macro $n $events
        Write-Host ("Saved to {0}" -f (Get-MacroPath $n)) -ForegroundColor Green
    } else {
        Write-Host "No events captured; nothing saved."
    }
}

# --------------------------------------------------------------------------
# Player
# --------------------------------------------------------------------------
function Invoke-PlayEvents($events, [double]$speed) {
    if ($speed -le 0) { $speed = 1.0 }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($ev in $events) {
        # abort on Esc OR stop-file (focus-independent kill signal)
        if ((([Win32.Native]::GetAsyncKeyState(0x1B) -band 0x8000) -ne 0) -or (Test-StopSignal)) {
            Write-Host "Aborted." -ForegroundColor Red
            return $false
        }
        $target = ($ev.t / $speed) * 1000.0
        while ($sw.Elapsed.TotalMilliseconds -lt $target) {
            if ((([Win32.Native]::GetAsyncKeyState(0x1B) -band 0x8000) -ne 0) -or (Test-StopSignal)) {
                Write-Host "Aborted." -ForegroundColor Red
                return $false
            }
            Start-Sleep -Milliseconds 2
        }

        switch ($ev.type) {
            'mouse_move'  { Move-MouseAbsolute $ev.x $ev.y }
            'mouse_click' {
                Move-MouseAbsolute $ev.x $ev.y
                $down = $ev.pressed
                switch ($ev.button) {
                    'left'   { $f = if ($down) { $MOUSEEVENTF_LEFTDOWN }   else { $MOUSEEVENTF_LEFTUP } }
                    'right'  { $f = if ($down) { $MOUSEEVENTF_RIGHTDOWN }  else { $MOUSEEVENTF_RIGHTUP } }
                    'middle' { $f = if ($down) { $MOUSEEVENTF_MIDDLEDOWN } else { $MOUSEEVENTF_MIDDLEUP } }
                }
                Send-Inputs @( (New-MouseInput $f) )
            }
            'key' {
                Send-Inputs @( (New-KeyInput ([uint16]$ev.vk) (-not $ev.pressed)) )
            }
        }
    }
    return $true
}

# --------------------------------------------------------------------------
# Background player (PostMessage - no foreground focus required)
# --------------------------------------------------------------------------
# Window message constants
$WM_MOUSEMOVE   = 0x0200
$WM_LBUTTONDOWN = 0x0201
$WM_LBUTTONUP   = 0x0202
$WM_RBUTTONDOWN = 0x0204
$WM_RBUTTONUP   = 0x0205
$WM_MBUTTONDOWN = 0x0207
$WM_MBUTTONUP   = 0x0208
$WM_KEYDOWN     = 0x0100
$WM_KEYUP       = 0x0101
$WM_CHAR        = 0x0102
$MAPVK_VK_TO_CHAR = 2
$MK_LBUTTON     = 0x0001
$MK_RBUTTON     = 0x0002
$MK_MBUTTON     = 0x0010
$MAPVK_VK_TO_VSC = 0

function New-LParamXY([int]$x, [int]$y) {
    # LOWORD = x, HIWORD = y (int64-safe)
    $lpv = [int64](($y -band 0xFFFF) -shl 16) -bor ($x -band 0xFFFF)
    return [IntPtr]$lpv
}

function Get-ClientPoint([IntPtr]$hWnd, [int]$screenX, [int]$screenY) {
    $pt = New-Object Win32.Native+POINT
    $pt.X = $screenX; $pt.Y = $screenY
    [void][Win32.Native]::ScreenToClient($hWnd, [ref]$pt)
    return $pt
}

function Get-DeepChildAt([IntPtr]$root, [int]$screenX, [int]$screenY) {
    # Resolve the deepest child window under a screen point (client of $root).
    $pt = New-Object Win32.Native+POINT
    $pt.X = $screenX; $pt.Y = $screenY
    [void][Win32.Native]::ScreenToClient($root, [ref]$pt)
    $child = [Win32.Native]::RealChildWindowFromPoint($root, $pt)
    if ($child -eq [IntPtr]::Zero) { return $root }
    return $child
}

function Find-EditableChild([IntPtr]$root) {
    # Fallback key target: first Edit/RichEdit-like child control under the window.
    $script:__editHit = [IntPtr]::Zero
    $cb = [Win32.Native+EnumWindowsProc] {
        param($hWnd, $lParam)
        if ($script:__editHit -ne [IntPtr]::Zero) { return $false }
        $sb = New-Object System.Text.StringBuilder 128
        [void][Win32.Native]::GetClassName($hWnd, $sb, $sb.Capacity)
        $cls = $sb.ToString().ToLower()
        if ($cls -match 'edit|richedit|text|scintilla|chrome_render') {
            $script:__editHit = $hWnd
            return $false
        }
        return $true
    }
    [void][Win32.Native]::EnumChildWindows($root, $cb, [IntPtr]::Zero)
    if ($script:__editHit -ne [IntPtr]::Zero) { return $script:__editHit }
    return $root
}

function Invoke-PlayEventsBackground($events, [double]$speed, [IntPtr]$hWnd) {
    if ($speed -le 0) { $speed = 1.0 }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # Current key target = deepest child under the last known cursor position.
    # If the macro has no mouse events, fall back to an editable child control.
    $keyTarget = Find-EditableChild $hWnd

    foreach ($ev in $events) {
        if ((([Win32.Native]::GetAsyncKeyState(0x1B) -band 0x8000) -ne 0) -or (Test-StopSignal)) {
            Write-Host "Aborted." -ForegroundColor Red; return $false
        }
        $target = ($ev.t / $speed) * 1000.0
        while ($sw.Elapsed.TotalMilliseconds -lt $target) {
            if ((([Win32.Native]::GetAsyncKeyState(0x1B) -band 0x8000) -ne 0) -or (Test-StopSignal)) {
                Write-Host "Aborted." -ForegroundColor Red; return $false
            }
            Start-Sleep -Milliseconds 2
        }

        switch ($ev.type) {
            'mouse_move' {
                $child = Get-DeepChildAt $hWnd $ev.x $ev.y
                $keyTarget = $child
                $c = Get-ClientPoint $child $ev.x $ev.y
                [void][Win32.Native]::PostMessage($child, $WM_MOUSEMOVE, [IntPtr]0, (New-LParamXY $c.X $c.Y))
            }
            'mouse_click' {
                $child = Get-DeepChildAt $hWnd $ev.x $ev.y
                $keyTarget = $child
                $c = Get-ClientPoint $child $ev.x $ev.y
                $lp = New-LParamXY $c.X $c.Y
                $down = $ev.pressed
                switch ($ev.button) {
                    'left'   { $msg = if ($down) { $WM_LBUTTONDOWN } else { $WM_LBUTTONUP }; $wp = $MK_LBUTTON }
                    'right'  { $msg = if ($down) { $WM_RBUTTONDOWN } else { $WM_RBUTTONUP }; $wp = $MK_RBUTTON }
                    'middle' { $msg = if ($down) { $WM_MBUTTONDOWN } else { $WM_MBUTTONUP }; $wp = $MK_MBUTTON }
                }
                [void][Win32.Native]::PostMessage($child, $WM_MOUSEMOVE, [IntPtr]0, $lp)
                $wpar = if ($down) { [IntPtr]$wp } else { [IntPtr]0 }
                [void][Win32.Native]::PostMessage($child, $msg, $wpar, $lp)
            }
            'key' {
                $vk = [uint32]$ev.vk
                $scan = [Win32.Native]::MapVirtualKey($vk, $MAPVK_VK_TO_VSC)
                $ch = [Win32.Native]::MapVirtualKey($vk, $MAPVK_VK_TO_CHAR) -band 0xFFFF
                if ($ch -ne 0) {
                    # Printable key: send a single WM_CHAR on key-down only, so edit
                    # controls insert exactly one character (no KEYDOWN duplicate).
                    if ($ev.pressed) {
                        $lpv = [int64](1 -bor ($scan -shl 16))
                        [void][Win32.Native]::PostMessage($keyTarget, $WM_CHAR, [IntPtr]([int]$ch), [IntPtr]$lpv)
                    }
                } else {
                    # Non-printable key (Enter, arrows, F-keys, etc.): use KEYDOWN/KEYUP.
                    if ($ev.pressed) {
                        $lpv = [int64](1 -bor ($scan -shl 16))
                        [void][Win32.Native]::PostMessage($keyTarget, $WM_KEYDOWN, [IntPtr]$vk, [IntPtr]$lpv)
                    } else {
                        $lpv = [int64]0xC0000001 -bor ([int64]$scan -shl 16)
                        [void][Win32.Native]::PostMessage($keyTarget, $WM_KEYUP, [IntPtr]$vk, [IntPtr]$lpv)
                    }
                }
            }
        }
    }
    return $true
}

# --------------------------------------------------------------------------
# Scheduler
# --------------------------------------------------------------------------
function Show-Countdown([double]$seconds, [string]$label) {
    $r = [int]$seconds
    while ($r -gt 0) {
        if (Test-StopSignal) { return }   # respect auto-stop during waits
        Write-Host ("`r{0}: {1,3}s " -f $label, $r) -NoNewline
        Start-Sleep -Seconds 1
        $r--
    }
    if ($seconds -gt 0) { Write-Host ("`r" + (' ' * 40) + "`r") -NoNewline }
}

function Invoke-Play([string]$n, [int]$targetPid, [double]$delay, [int]$repeat, [double]$interval, [double]$speed, [bool]$background, [bool]$flashRestore, [IntPtr]$explicitHwnd = [IntPtr]::Zero) {
    $macro = Load-Macro $n
    $proc = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
    if (-not $proc) { Write-Host "[error] PID $targetPid not found." -ForegroundColor Red; return }
    $modeLabel = if ($background) { 'BACKGROUND (no focus)' } elseif ($flashRestore) { 'FLASH-RESTORE (focus target, restore your window)' } else { 'foreground' }
    Write-Host ("Target: PID {0} ({1})  Mode: {2}" -f $targetPid, $proc.ProcessName, $modeLabel)

    $bgHwnd = [IntPtr]::Zero
    if ($background) {
        if ($explicitHwnd -ne [IntPtr]::Zero) {
            $bgHwnd = $explicitHwnd
            Write-Host ("Background target window (explicit): 0x{0:X}" -f [int64]$bgHwnd)
        } else {
            $hwnds = Get-HwndsForPid $targetPid
            if ($hwnds.Count -eq 0) {
                Write-Host "[error] No window found for PID $targetPid (needed for background mode)." -ForegroundColor Red
                return
            }
            $bgHwnd = $hwnds[0].Hwnd
            Write-Host ("Background target window: 0x{0:X} '{1}'" -f [int64]$bgHwnd, $hwnds[0].Title)
        }
        Write-Host "Note: many apps (games/DirectX/Chromium canvas, context menus) may ignore posted input." -ForegroundColor DarkYellow
    }

    # Snapshot the window that was in front BEFORE we started, so flash-restore
    # can return focus there after all runs finish.
    $priorFg = [IntPtr]::Zero
    if ($flashRestore) {
        $priorFg = [Win32.Native]::GetForegroundWindow()
    }

    if ($delay -gt 0) { Show-Countdown $delay "Starting in" }

    # Start the wall-clock now (after any pre-delay) for the max-runtime guard.
    $script:PlayStart = [DateTime]::Now
    if ($script:MaxRuntime -gt 0) {
        Write-Host ("Safety: auto-stop after {0}s max runtime." -f $script:MaxRuntime) -ForegroundColor DarkGray
    }
    if ($script:WatchPid -gt 0) {
        Write-Host ("Safety: auto-stop if UI (PID {0}) exits." -f $script:WatchPid) -ForegroundColor DarkGray
    }

    $run = 0
    while ($true) {
        # Auto-stop checks at the top of each run (covers between-run intervals).
        if (Test-StopSignal) {
            Write-Host "Auto-stopped (safety trigger)." -ForegroundColor Yellow
            if ($flashRestore) { Restore-Foreground $priorFg }
            return
        }
        if ($background) {
            if (-not (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)) {
                Write-Host "[error] Target process exited. Stopping." -ForegroundColor Red; return
            }
        } else {
            # Both foreground and flash-restore need the target focused to inject.
            if (-not (Focus-Pid $targetPid)) {
                Write-Host "[error] Could not focus a window for PID $targetPid. Stopping." -ForegroundColor Red
                return
            }
        }
        $run++
        $tag = if ($repeat) { "$run/$repeat" } else { "$run/inf" }
        Write-Host "Run $tag..."
        if ($background) {
            $ok = Invoke-PlayEventsBackground $macro.events $speed $bgHwnd
        } else {
            $ok = Invoke-PlayEvents $macro.events $speed
        }
        if (-not $ok) {
            if ($flashRestore) { Restore-Foreground $priorFg }
            return
        }
        if ($repeat -and $run -ge $repeat) { break }
        if ($interval -gt 0) { Show-Countdown $interval "Next run in" }
    }

    if ($flashRestore -and $priorFg -ne [IntPtr]::Zero) {
        Restore-Foreground $priorFg
        Write-Host "Focus restored to your previous window." -ForegroundColor DarkGray
    }
    Write-Host "Done." -ForegroundColor Green
}

function Restore-Foreground([IntPtr]$hWnd) {
    if ($hWnd -eq [IntPtr]::Zero) { return }
    if (-not [Win32.Native]::IsWindowVisible($hWnd)) { return }
    $fg = [Win32.Native]::GetForegroundWindow()
    $tmp = 0
    $curTid = [Win32.Native]::GetWindowThreadProcessId($fg, [ref]$tmp)
    $tgtTid = [Win32.Native]::GetWindowThreadProcessId($hWnd, [ref]$tmp)
    $attached = $false
    try {
        if ($curTid -ne 0 -and $tgtTid -ne 0 -and $curTid -ne $tgtTid) {
            $attached = [Win32.Native]::AttachThreadInput($curTid, $tgtTid, $true)
        }
        [void][Win32.Native]::BringWindowToTop($hWnd)
        [void][Win32.Native]::SetForegroundWindow($hWnd)
    } catch {
    } finally {
        if ($attached) { [void][Win32.Native]::AttachThreadInput($curTid, $tgtTid, $false) }
    }
}

# --------------------------------------------------------------------------
# list / pids
# --------------------------------------------------------------------------
function Invoke-List {
    $files = @()
    if (Test-Path $script:MacrosDir) {
        $files = @(Get-ChildItem -Path $script:MacrosDir -Filter *.json -ErrorAction SilentlyContinue)
    }
    if ($Json) {
        $names = @($files | ForEach-Object { $_.BaseName })
        Write-Output (ConvertTo-Json -InputObject $names -Compress)
        return
    }
    if (-not $files -or $files.Count -eq 0) { Write-Host "No macros saved yet."; return }
    Write-Host "Saved macros:"
    foreach ($f in $files) { Write-Host ("  {0}" -f $f.BaseName) }
}

function Invoke-Pids([string]$nameSub) {
    $procs = @(Get-Process | Where-Object { $_.ProcessName -like "*$nameSub*" })
    if ($Json) {
        $rows = @(foreach ($p in $procs) {
            $hwnds = Get-HwndsForPid $p.Id
            [pscustomobject]@{
                pid   = $p.Id
                name  = $p.ProcessName
                title = if ($hwnds.Count -gt 0) { $hwnds[0].Title } else { '' }
            }
        })
        Write-Output (ConvertTo-Json -InputObject $rows -Compress)
        return
    }
    if (-not $procs -or $procs.Count -eq 0) { Write-Host "No processes matching '$nameSub'."; return }
    "{0,8}  {1,-25}  {2}" -f 'PID', 'PROCESS', 'WINDOW TITLE' | Write-Host
    foreach ($p in $procs) {
        $hwnds = Get-HwndsForPid $p.Id
        $title = if ($hwnds.Count -gt 0) { $hwnds[0].Title } else { '' }
        "{0,8}  {1,-25}  {2}" -f $p.Id, $p.ProcessName, $title | Write-Host
    }
}

function Invoke-Windows([string]$nameSub) {
    # List open program windows (what the user started) with friendly names.
    $wins = @(Get-VisibleWindows)
    if ($nameSub) {
        $wins = @($wins | Where-Object {
            $_.Friendly -like "*$nameSub*" -or $_.Title -like "*$nameSub*"
        })
    }
    if ($Json) {
        $rows = @($wins | ForEach-Object {
            [pscustomobject]@{
                pid      = $_.Pid
                friendly = $_.Friendly
                title    = $_.Title
            }
        })
        Write-Output (ConvertTo-Json -InputObject $rows -Compress)
        return
    }
    if (-not $wins -or $wins.Count -eq 0) { Write-Host "No open windows found."; return }
    "{0,8}  {1,-28}  {2}" -f 'PID', 'PROGRAM', 'WINDOW TITLE' | Write-Host
    foreach ($w in $wins) {
        "{0,8}  {1,-28}  {2}" -f $w.Pid, $w.Friendly, $w.Title | Write-Host
    }
}

# --------------------------------------------------------------------------
# Environment check
# --------------------------------------------------------------------------
function Invoke-CheckEnv {
    $failures = 0
    $warnings = 0
    Write-Host "MacroTool environment check" -ForegroundColor Cyan
    Write-Host "============================"

    function Report($label, $ok, $detail, [bool]$warnOnly = $false) {
        if ($ok) {
            Write-Host ("  [ OK ] {0}: {1}" -f $label, $detail) -ForegroundColor Green
        } elseif ($warnOnly) {
            Write-Host ("  [WARN] {0}: {1}" -f $label, $detail) -ForegroundColor Yellow
            $script:__envWarn++
        } else {
            Write-Host ("  [FAIL] {0}: {1}" -f $label, $detail) -ForegroundColor Red
            $script:__envFail++
        }
    }
    $script:__envFail = 0
    $script:__envWarn = 0

    # 1. Operating system: must be Windows
    $isWin = ($env:OS -eq 'Windows_NT') -or ([System.Environment]::OSVersion.Platform -eq 'Win32NT')
    $osVer = [System.Environment]::OSVersion.Version
    Report "Operating system" $isWin ("Windows detected (kernel {0}.{1}.{2})" -f $osVer.Major, $osVer.Minor, $osVer.Build)
    if (-not $isWin) {
        Report "Compatibility" $false "This toolkit only runs on Windows. Aborting further checks."
    }

    # Friendly OS caption if available
    try {
        $cap = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption
        if ($cap) { Write-Host ("         {0}" -f $cap.Trim()) -ForegroundColor DarkGray }
    } catch {}

    # 2. PowerShell version: 5.1+ recommended
    $psv = $PSVersionTable.PSVersion
    $psOk = ($psv.Major -gt 5) -or ($psv.Major -eq 5 -and $psv.Minor -ge 1)
    Report "PowerShell version" $psOk ("{0} (need 5.1+)" -f $psv.ToString()) (-not $psOk)

    # 3. .NET / Add-Type P-Invoke support (core requirement for input injection)
    $addTypeOk = $false
    try {
        if (-not ([System.Management.Automation.PSTypeName]'MacroToolEnvProbe.Native').Type) {
            Add-Type -Namespace MacroToolEnvProbe -Name Native -MemberDefinition @"
            [System.Runtime.InteropServices.DllImport("user32.dll")]
            public static extern int GetSystemMetrics(int nIndex);
"@ -ErrorAction Stop
        }
        $sw = [MacroToolEnvProbe.Native]::GetSystemMetrics(0)
        $addTypeOk = ($sw -gt 0)
    } catch { $addTypeOk = $false }
    Report ".NET Add-Type + Win32 P/Invoke" $addTypeOk $(if ($addTypeOk) { "user32.dll interop works (screen width probe OK)" } else { "Could not compile/call Win32 interop (needed for input injection)" })

    # 4. Required user32 APIs present (SendInput / PostMessage / EnumWindows)
    $apiOk = $false
    try {
        if (-not ([System.Management.Automation.PSTypeName]'MacroToolEnvProbe.Api').Type) {
            Add-Type -Namespace MacroToolEnvProbe -Name Api -MemberDefinition @"
            [System.Runtime.InteropServices.DllImport("user32.dll")]
            public static extern short GetAsyncKeyState(int vKey);
            [System.Runtime.InteropServices.DllImport("user32.dll")]
            public static extern bool EnumWindows(System.IntPtr lpEnumFunc, System.IntPtr lParam);
"@ -ErrorAction Stop
        }
        [void][MacroToolEnvProbe.Api]::GetAsyncKeyState(0x10)
        $apiOk = $true
    } catch { $apiOk = $false }
    Report "Input APIs (GetAsyncKeyState/EnumWindows)" $apiOk $(if ($apiOk) { "available" } else { "unavailable" })

    # 5. mshta.exe (host for the visual console)
    $mshta = Join-Path $env:SystemRoot 'System32\mshta.exe'
    $mshtaOk = Test-Path $mshta
    Report "Visual console host (mshta.exe)" $mshtaOk $(if ($mshtaOk) { $mshta } else { "not found - CLI still works, but MacroTool.hta will not open" }) (-not $mshtaOk)

    # 6. explorer.exe (for 'Open macro folder')
    $explorer = Join-Path $env:SystemRoot 'explorer.exe'
    Report "File explorer (explorer.exe)" (Test-Path $explorer) $explorer (-not (Test-Path $explorer))

    # 7. Backend script + writable macros directory
    $scriptOk = Test-Path $PSCommandPath
    Report "Backend script" $scriptOk $PSCommandPath
    $canWrite = $false
    try {
        if (-not (Test-Path $script:MacrosDir)) { New-Item -ItemType Directory -Path $script:MacrosDir -ErrorAction Stop | Out-Null }
        $probe = Join-Path $script:MacrosDir '.envprobe'
        Set-Content -LiteralPath $probe -Value 'ok' -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        $canWrite = $true
    } catch { $canWrite = $false }
    Report "Macros directory writable" $canWrite $script:MacrosDir

    # 8. Elevation note (not a failure - informational)
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
        $admin = $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($admin) {
            Write-Host "  [INFO] Running elevated (can drive admin/elevated target apps)." -ForegroundColor DarkGray
        } else {
            Write-Host "  [INFO] Not elevated. To automate an admin app, run this elevated too." -ForegroundColor DarkGray
        }
    } catch {}

    Write-Host "----------------------------"
    if ($script:__envFail -gt 0) {
        Write-Host ("Environment check FAILED ({0} error(s), {1} warning(s))." -f $script:__envFail, $script:__envWarn) -ForegroundColor Red
        exit 1
    } elseif ($script:__envWarn -gt 0) {
        Write-Host ("Environment OK with {0} warning(s). You can proceed." -f $script:__envWarn) -ForegroundColor Yellow
        exit 0
    } else {
        Write-Host "Environment check PASSED. All good." -ForegroundColor Green
        exit 0
    }
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------
switch ($Command) {
    'checkenv' { Invoke-CheckEnv }
    'record' {
        if (-not $Name) { throw "record requires -Name" }
        Invoke-Record $Name (-not $NoMove.IsPresent)
    }
    'play' {
        if (-not $Name) { throw "play requires -Name" }
        # Allow targeting by exact window handle; resolve its PID.
        if ($TargetHwnd -ne 0 -and -not $TargetPid) {
            $rpid = 0
            [void][Win32.Native]::GetWindowThreadProcessId([IntPtr]$TargetHwnd, [ref]$rpid)
            $TargetPid = [int]$rpid
        }
        if (-not $TargetPid)  { throw "play requires -TargetPid or -TargetHwnd" }
        Invoke-Play $Name $TargetPid $Delay $Repeat $Interval $Speed $Background.IsPresent $FlashRestore.IsPresent ([IntPtr]$TargetHwnd)
    }
    'list' { Invoke-List }
    'pids' {
        $sub = if ($ProcName) { $ProcName } elseif ($Name) { $Name } else { '' }
        Invoke-Pids $sub
    }
    'windows' {
        $sub = if ($ProcName) { $ProcName } elseif ($Name) { $Name } else { '' }
        Invoke-Windows $sub
    }
}
