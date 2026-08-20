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

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

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

    // Foreground-focus helpers: needed to defeat Windows' foreground-lock so a
    // non-foreground process (the hidden MacroTool player) can actually activate
    // the target window instead of only flashing its taskbar button.
    [DllImport("user32.dll")]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, ref uint pvParam, uint fWinIni);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();
"@
}

# --------------------------------------------------------------------------
# Wheel capture (zero-dependency, user32.dll only).
#
# The mouse wheel is a transient WM_MOUSEWHEEL message, invisible to the
# GetAsyncKeyState polling the recorder uses for buttons/keys. To capture it
# without any external dependency, install a WH_MOUSE_LL low-level mouse hook
# on a dedicated background thread that runs its own message pump. The hook
# enqueues wheel deltas into a thread-safe queue that the recorder's poll loop
# drains. Uses only user32.dll P/Invoke - no pip, no modules.
# --------------------------------------------------------------------------
if (-not ([System.Management.Automation.PSTypeName]'Win32.WheelHook').Type) {
    Add-Type -Namespace Win32 -Name WheelHook -UsingNamespace @('System.Threading','System.Collections.Concurrent') -MemberDefinition @"
    private const int WH_MOUSE_LL   = 14;
    private const int WM_MOUSEWHEEL  = 0x020A;
    private const int WM_MOUSEHWHEEL = 0x020E;

    [StructLayout(LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT {
        public int x; public int y;
        public uint mouseData; public uint flags; public uint time; public IntPtr dwExtraInfo;
    }

    private delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll")]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY; }
    [DllImport("user32.dll")]
    private static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint min, uint max);
    [DllImport("user32.dll")]
    private static extern bool PostThreadMessage(uint idThread, uint Msg, IntPtr wParam, IntPtr lParam);

    // A captured wheel event: dx/dy in wheel notches (120 units = 1 notch),
    // plus the screen coordinates where it happened and the time (seconds since
    // the hook started) so the recorder can preserve accurate per-event timing.
    public struct WheelEvent { public int dx; public int dy; public int x; public int y; public double t; }

    private static IntPtr _hook = IntPtr.Zero;
    private static HookProc _proc;            // kept alive to avoid GC of the delegate
    private static System.Threading.Thread _thread;
    private static uint _threadId;
    private static readonly System.Diagnostics.Stopwatch _clock = new System.Diagnostics.Stopwatch();
    private static System.Threading.ManualResetEventSlim _ready;
    private static readonly System.Collections.Concurrent.ConcurrentQueue<WheelEvent> _queue =
        new System.Collections.Concurrent.ConcurrentQueue<WheelEvent>();

    private static IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0) {
            int msg = wParam.ToInt32();
            if (msg == WM_MOUSEWHEEL || msg == WM_MOUSEHWHEEL) {
                MSLLHOOKSTRUCT data = (MSLLHOOKSTRUCT)System.Runtime.InteropServices.Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                short delta = (short)((data.mouseData >> 16) & 0xFFFF);
                WheelEvent we = new WheelEvent();
                we.x = data.x; we.y = data.y;
                we.t = _clock.Elapsed.TotalSeconds;
                if (msg == WM_MOUSEWHEEL) { we.dy = delta; we.dx = 0; }
                else                      { we.dx = delta; we.dy = 0; }
                _queue.Enqueue(we);
            }
        }
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    // Install the hook synchronously: returns true only once SetWindowsHookEx has
    // actually run on the pump thread and succeeded. This removes the race where
    // early scrolls were lost because Start() returned before the hook existed.
    public static bool Start() {
        if (_thread != null) return _hook != IntPtr.Zero;
        _proc = new HookProc(Callback);
        _ready = new System.Threading.ManualResetEventSlim(false);
        _clock.Reset(); _clock.Start();
        WheelEvent tmp;
        while (_queue.TryDequeue(out tmp)) { }   // clear any stale events
        _thread = new System.Threading.Thread(new System.Threading.ThreadStart(delegate {
            _threadId = GetCurrentThreadId();
            _hook = SetWindowsHookEx(WH_MOUSE_LL, _proc, GetModuleHandle(null), 0);
            _ready.Set();   // signal AFTER the hook attempt (success or failure)
            MSG m;
            while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { /* pump */ }
            if (_hook != IntPtr.Zero) { UnhookWindowsHookEx(_hook); _hook = IntPtr.Zero; }
        }));
        _thread.IsBackground = true;
        _thread.Start();
        _ready.Wait(2000);   // block until the hook is installed (or timeout)
        return _hook != IntPtr.Zero;
    }

    public static void Stop() {
        System.Threading.Thread t = _thread;
        if (t == null) return;
        // Ensure the pump thread has reached the point where _threadId is set.
        if (_ready != null) _ready.Wait(2000);
        // WM_QUIT = 0x0012 to break the message pump.
        if (_threadId != 0) PostThreadMessage(_threadId, 0x0012, IntPtr.Zero, IntPtr.Zero);
        try { t.Join(2000); } catch { }
        _thread = null; _threadId = 0;
        _clock.Stop();
        if (_ready != null) { _ready.Dispose(); _ready = null; }
    }

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    // Drain one queued wheel event. Returns true and fills the out fields if one
    // was available, false otherwise. 't' is seconds since the hook started.
    public static bool TryDequeue(out int dx, out int dy, out int x, out int y, out double t) {
        WheelEvent we;
        if (_queue.TryDequeue(out we)) { dx = we.dx; dy = we.dy; x = we.x; y = we.y; t = we.t; return true; }
        dx = 0; dy = 0; x = 0; y = 0; t = 0; return false;
    }
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
$MOUSEEVENTF_HWHEEL      = 0x1000

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
$SW_SHOW     = 5

# Foreground-lock defeat constants (see Focus-Pid).
$SPI_GETFOREGROUNDLOCKTIMEOUT = 0x2000
$SPI_SETFOREGROUNDLOCKTIMEOUT = 0x2001
$SPIF_SENDCHANGE              = 0x2
$VK_MENU                      = 0x12   # ALT
$SPI_GETKEYBOARDSPEED         = 0x000A

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

function Set-ForegroundReliable([IntPtr]$hWnd) {
    # Force a target window to the foreground from a non-foreground process.
    #
    # Windows blocks SetForegroundWindow when the calling process is not itself
    # the foreground process (foreground-lock), so a naked call only flashes the
    # taskbar. We defeat this with the standard, dependency-free combo, but we
    # try the LEAST intrusive method first and only escalate if needed, because
    # the ALT key-tap can trigger menu shortcuts in some apps (e.g. Chrome) when
    # it coincides with the macro's own injected clicks.
    #   1. Try SetForegroundWindow after AttachThreadInput (no synthetic keys).
    #   2. Only if that fails: temporarily zero SPI_SETFOREGROUNDLOCKTIMEOUT and
    #      retry (still no keys).
    #   3. Only if that still fails: the ALT key-tap as a last resort.
    # Returns $true if the target ends up foreground.
    if ($hWnd -eq [IntPtr]::Zero) { return $false }

    # Only un-minimize if iconic. Do NOT touch an already-visible window's show
    # state (avoids disturbing size/position of apps like Chrome).
    if ([Win32.Native]::IsIconic($hWnd)) {
        [void][Win32.Native]::ShowWindow($hWnd, $SW_RESTORE)
    }

    # Helper: attach our thread to the current foreground thread, try to activate.
    $activate = {
        $curTid = [Win32.Native]::GetCurrentThreadId()
        $fg = [Win32.Native]::GetForegroundWindow()
        $tmp = 0
        $fgTid = [Win32.Native]::GetWindowThreadProcessId($fg, [ref]$tmp)
        $attached = $false
        try {
            if ($curTid -ne 0 -and $fgTid -ne 0 -and $curTid -ne $fgTid) {
                $attached = [Win32.Native]::AttachThreadInput($curTid, $fgTid, $true)
            }
            [void][Win32.Native]::BringWindowToTop($hWnd)
            [void][Win32.Native]::SetForegroundWindow($hWnd)
        } finally {
            if ($attached) { [void][Win32.Native]::AttachThreadInput($curTid, $fgTid, $false) }
        }
        Start-Sleep -Milliseconds 60
        return ([Win32.Native]::GetForegroundWindow() -eq $hWnd)
    }

    # 1. Least intrusive: attach + activate, no synthetic keys.
    if (& $activate) { Start-Sleep -Milliseconds 60; return $true }

    # 2. Zero the foreground-lock timeout (save/restore), retry - still no keys.
    $oldTimeout = [uint32]0
    $gotOld = [Win32.Native]::SystemParametersInfo($SPI_GETFOREGROUNDLOCKTIMEOUT, 0, [ref]$oldTimeout, 0)
    $zero = [uint32]0
    [void][Win32.Native]::SystemParametersInfo($SPI_SETFOREGROUNDLOCKTIMEOUT, 0, [ref]$zero, $SPIF_SENDCHANGE)
    $ok2 = (& $activate)
    if ($gotOld) {
        [void][Win32.Native]::SystemParametersInfo($SPI_SETFOREGROUNDLOCKTIMEOUT, 0, [ref]$oldTimeout, $SPIF_SENDCHANGE)
    }
    if ($ok2) { Start-Sleep -Milliseconds 60; return $true }

    # 3. Last resort: ALT key-tap to unlock foreground rights, then activate.
    #    Kept last so it never interferes with normal activation / injected input.
    Send-Inputs @( (New-KeyInput ([uint16]$VK_MENU) $false) )
    Send-Inputs @( (New-KeyInput ([uint16]$VK_MENU) $true) )
    $ok3 = (& $activate)

    Start-Sleep -Milliseconds 120
    return ([Win32.Native]::GetForegroundWindow() -eq $hWnd)
}

function Focus-Pid([int]$targetPid, [IntPtr]$explicitHwnd = [IntPtr]::Zero) {
    # Prefer the explicit target window handle (the exact previewed window) so we
    # activate precisely what the user is automating; fall back to PID lookup.
    $hWnd = $explicitHwnd
    if ($hWnd -eq [IntPtr]::Zero) {
        $hwnds = Get-HwndsForPid $targetPid
        if ($hwnds.Count -eq 0) { return $false }
        $hWnd = $hwnds[0].Hwnd
    }

    $ok = Set-ForegroundReliable $hWnd
    if (-not $ok) {
        # One retry - some shells need a second nudge to release the lock.
        Start-Sleep -Milliseconds 60
        $ok = Set-ForegroundReliable $hWnd
    }
    if (-not $ok) {
        Write-Host "[warn] Could not bring target to foreground; input may not land. Click the target once if needed." -ForegroundColor DarkYellow
    }
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

function ConvertTo-UInt32Bits([int]$v) {
    # Reinterpret a signed 32-bit int's bit pattern as a uint32 WITHOUT throwing.
    # A direct [uint32]$negative cast throws ("value too small"), and
    # ($v -band 0xFFFFFFFF) stays negative because 0xFFFFFFFF is a signed int.
    # Masking through int64 yields the correct unsigned bit pattern (e.g.
    # -120 -> 4294967176) which is what mouseData / wheel deltas require.
    return [uint32]([int64]$v -band 0xFFFFFFFFL)
}

function Send-Wheel([int]$dx, [int]$dy) {
    # Reproduce a recorded wheel notch. mouseData carries the (signed) delta as a
    # 32-bit bit pattern; vertical uses MOUSEEVENTF_WHEEL, horizontal HWHEEL.
    if ($dy -ne 0) {
        Send-Inputs @( (New-MouseInput $MOUSEEVENTF_WHEEL 0 0 (ConvertTo-UInt32Bits $dy)) )
    }
    if ($dx -ne 0) {
        Send-Inputs @( (New-MouseInput $MOUSEEVENTF_HWHEEL 0 0 (ConvertTo-UInt32Bits $dx)) )
    }
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

    # Start the low-level wheel hook so scroll (which key-state polling cannot
    # see) gets captured. Zero external dependencies - user32.dll only. Start()
    # is synchronous and reports whether the hook actually installed.
    $wheelOk = [Win32.WheelHook]::Start()
    if (-not $wheelOk) {
        Write-Host "[warn] Mouse-wheel hook could not be installed; scroll will not be recorded." -ForegroundColor DarkYellow
    }
    try {

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

        # mouse wheel (drained from the low-level hook queue). Each notch is 120
        # units. Use the hook's own capture time so rapid multi-notch scrolls keep
        # accurate, distinct timings instead of collapsing to one poll tick.
        $wdx = 0; $wdy = 0; $wx = 0; $wy = 0; $wt = 0.0
        while ([Win32.WheelHook]::TryDequeue([ref]$wdx, [ref]$wdy, [ref]$wx, [ref]$wy, [ref]$wt)) {
            [void]$events.Add([ordered]@{
                t = [math]::Round($wt, 4); type = 'mouse_scroll'
                dx = $wdx; dy = $wdy; x = $wx; y = $wy
            })
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

    } finally {
        # Always tear down the wheel hook so the background thread/pump exits.
        [Win32.WheelHook]::Stop()
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
function Get-KeyRepeatIntervalMs {
    # System keyboard repeat rate: SPI_GETKEYBOARDSPEED returns 0 (slow, ~2.5/s)
    # .. 31 (fast, ~30/s). Map linearly to a per-repeat interval in ms. Fall back
    # to ~33ms (about 30 repeats/sec) if the query fails.
    $speed = [uint32]0
    if ([Win32.Native]::SystemParametersInfo($SPI_GETKEYBOARDSPEED, 0, [ref]$speed, 0)) {
        # repeats/sec ~= 2.5 + (speed/31)*(30-2.5)
        $rps = 2.5 + ([double]$speed / 31.0) * 27.5
        if ($rps -lt 1) { $rps = 1 }
        return [int](1000.0 / $rps)
    }
    return 33
}

function Invoke-PlayEvents($events, [double]$speed) {
    if ($speed -le 0) { $speed = 1.0 }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # Does this macro itself use Esc? If so, the raw GetAsyncKeyState(Esc) panic
    # key would false-trigger the instant we INJECT the macro's own Esc, aborting
    # playback immediately (this is the classic "macro does nothing" symptom).
    # When the macro contains Esc events we rely solely on the -StopFile signal
    # (used by the UI Stop button) for aborting, which never collides with
    # injected input.
    $macroUsesEsc = $false
    foreach ($ev in $events) {
        if ($ev.type -eq 'key' -and [int]$ev.vk -eq 0x1B) { $macroUsesEsc = $true; break }
    }
    $escAbortEnabled = -not $macroUsesEsc

    # Key-hold support: recorded holds are a single down event then a delayed up
    # event. Injected input produces no OS auto-repeat, so message-driven apps
    # would see one keystroke instead of a hold. We synthesize repeats: track
    # currently-held keys and, during the wait before each event, re-inject
    # KEYDOWN for held keys at the system repeat interval.
    $heldKeys = @{}                      # vk -> $true while held
    $repeatIntervalMs = Get-KeyRepeatIntervalMs
    $nextRepeatMs = $repeatIntervalMs

    for ($ei = 0; $ei -lt $events.Count; $ei++) {
        $ev = $events[$ei]
        # abort on Esc (only when the macro doesn't use Esc itself) OR stop-file.
        if (($escAbortEnabled -and (([Win32.Native]::GetAsyncKeyState(0x1B) -band 0x8000) -ne 0)) -or (Test-StopSignal)) {
            Write-Host "Aborted." -ForegroundColor Red
            return $false
        }
        $target = ($ev.t / $speed) * 1000.0
        while ($sw.Elapsed.TotalMilliseconds -lt $target) {
            if (($escAbortEnabled -and (([Win32.Native]::GetAsyncKeyState(0x1B) -band 0x8000) -ne 0)) -or (Test-StopSignal)) {
                Write-Host "Aborted." -ForegroundColor Red
                return $false
            }
            # Emit auto-repeat KEYDOWNs for any keys currently held down.
            if ($heldKeys.Count -gt 0 -and $sw.Elapsed.TotalMilliseconds -ge $nextRepeatMs) {
                foreach ($hvk in @($heldKeys.Keys)) {
                    Send-Inputs @( (New-KeyInput ([uint16]$hvk) $false) )  # $false = key DOWN
                }
                $nextRepeatMs = $sw.Elapsed.TotalMilliseconds + $repeatIntervalMs
            }
            Start-Sleep -Milliseconds 2
        }

        switch ($ev.type) {
            'mouse_move'  { Move-MouseAbsolute $ev.x $ev.y }
            'mouse_scroll' {
                Move-MouseAbsolute $ev.x $ev.y
                Send-Wheel ([int]$ev.dx) ([int]$ev.dy)
            }
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
                $vk = [int]$ev.vk
                Send-Inputs @( (New-KeyInput ([uint16]$vk) (-not $ev.pressed)) )
                if ($ev.pressed) {
                    $heldKeys[$vk] = $true
                    # Reset the repeat clock so the first auto-repeat honors the
                    # system's initial repeat delay from this fresh press.
                    $nextRepeatMs = $sw.Elapsed.TotalMilliseconds + $repeatIntervalMs
                } else {
                    [void]$heldKeys.Remove($vk)
                }
            }
        }
    }

    # Safety: release any keys still marked held (macro ended mid-hold).
    foreach ($hvk in @($heldKeys.Keys)) {
        Send-Inputs @( (New-KeyInput ([uint16]$hvk) $true) )  # $true = key UP
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
$WM_MOUSEWHEEL  = 0x020A
$WM_MOUSEHWHEEL = 0x020E
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

    # See Invoke-PlayEvents: disable the raw Esc panic key when the macro itself
    # injects Esc, otherwise playback aborts on its own injected keystroke.
    $macroUsesEsc = $false
    foreach ($ev in $events) {
        if ($ev.type -eq 'key' -and [int]$ev.vk -eq 0x1B) { $macroUsesEsc = $true; break }
    }
    $escAbortEnabled = -not $macroUsesEsc

    foreach ($ev in $events) {
        if (($escAbortEnabled -and (([Win32.Native]::GetAsyncKeyState(0x1B) -band 0x8000) -ne 0)) -or (Test-StopSignal)) {
            Write-Host "Aborted." -ForegroundColor Red; return $false
        }
        $target = ($ev.t / $speed) * 1000.0
        while ($sw.Elapsed.TotalMilliseconds -lt $target) {
            if (($escAbortEnabled -and (([Win32.Native]::GetAsyncKeyState(0x1B) -band 0x8000) -ne 0)) -or (Test-StopSignal)) {
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
            'mouse_scroll' {
                $child = Get-DeepChildAt $hWnd $ev.x $ev.y
                $keyTarget = $child
                # WM_MOUSEWHEEL/HWHEEL uses SCREEN coords in lParam (not client),
                # and packs the signed wheel delta in the HIWORD of wParam.
                $lp = New-LParamXY $ev.x $ev.y
                if ([int]$ev.dy -ne 0) {
                    $wp = [IntPtr]([int64](([int]$ev.dy -band 0xFFFF) -shl 16))
                    [void][Win32.Native]::PostMessage($child, $WM_MOUSEWHEEL, $wp, $lp)
                }
                if ([int]$ev.dx -ne 0) {
                    $wp = [IntPtr]([int64](([int]$ev.dx -band 0xFFFF) -shl 16))
                    [void][Win32.Native]::PostMessage($child, $WM_MOUSEHWHEEL, $wp, $lp)
                }
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
    $modeLabel = if ($background) { 'BACKGROUND (no focus)' } else { 'FOREGROUND (focus target, keep it in front)' }
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

    # Post-playback focus policy: we KEEP the target window in front so the user
    # can immediately keep working in the automated program (they launched Play
    # from the LivePreview overlay and want the program focused afterwards, not
    # the overlay). No prior-foreground snapshot / restore is needed.

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
    $focusFailCount = 0
    while ($true) {
        # Auto-stop checks at the top of each run (covers between-run intervals).
        if (Test-StopSignal) {
            Write-Host "Auto-stopped (safety trigger)." -ForegroundColor Yellow
            return
        }
        if ($background) {
            if (-not (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)) {
                Write-Host "[error] Target process exited. Stopping." -ForegroundColor Red; return
            }
        } else {
            # Foreground playback: verify the target is still alive BEFORE we
            # focus + inject. If the target process died or its window is gone,
            # abort immediately so we never click blindly into whatever window
            # happens to sit under the recorded screen coordinates (which could
            # be another app or the desktop).
            if (-not (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)) {
                Write-Host "[error] Target process exited. Stopping (no blind input)." -ForegroundColor Red; return
            }
            if ($explicitHwnd -ne [IntPtr]::Zero -and -not [Win32.Native]::IsWindow($explicitHwnd)) {
                Write-Host "[error] Target window no longer exists. Stopping." -ForegroundColor Red; return
            }
            # Focus the target (pass the explicit window so we activate exactly
            # the previewed window).
            if (-not (Focus-Pid $targetPid $explicitHwnd)) {
                Write-Host "[error] Could not focus a window for PID $targetPid. Stopping." -ForegroundColor Red
                return
            }
            # After focusing, confirm the FOREGROUND window belongs to the target
            # process. If activation failed and some OTHER app is foreground, DON'T
            # inject - the clicks would land on the wrong window (this is what
            # prevents a macro from clicking controls of an unrelated app or the
            # desktop). We match by PID, not exact hwnd, because apps like Chrome
            # legitimately move focus among their own top-level/popup windows.
            $fgNow = [Win32.Native]::GetForegroundWindow()
            $fgPid = 0
            [void][Win32.Native]::GetWindowThreadProcessId($fgNow, [ref]$fgPid)
            if ([int]$fgPid -ne [int]$targetPid) {
                $focusFailCount++
                if ($focusFailCount -ge 3) {
                    Write-Host "[error] Could not bring target to foreground after $focusFailCount tries; stopping to avoid clicking the wrong window." -ForegroundColor Red
                    return
                }
                Write-Host "[warn] Target ($targetPid) is not foreground (foreground PID=$fgPid); skipping this run to avoid clicking the wrong window." -ForegroundColor DarkYellow
                Start-Sleep -Milliseconds 300
                continue
            }
            $focusFailCount = 0
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
            return
        }
        if ($repeat -and $run -ge $repeat) { break }
        if ($interval -gt 0) { Show-Countdown $interval "Next run in" }
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
