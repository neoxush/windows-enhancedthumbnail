<#
.SYNOPSIS
    LivePreview - A live window preview tool for Windows.
    Shows a real-time DWM thumbnail of any running window in a floating, movable, pin-to-top overlay.

.DESCRIPTION
    Features:
    - Live hardware-accelerated window preview (DWM Thumbnail API)
    - Drag to move anywhere on screen
    - Resize by dragging edges/corners
    - Pin to stay always-on-top
    - Adjustable opacity (click opacity button to cycle)
    - Window picker with search/filter
    - Double-click title bar to snap to mini size (compact monitoring view)
    - Right-click title bar to pick a new window

.NOTES
    Requires Windows Vista+ with Desktop Window Manager enabled (default on modern Windows).
    Run with: powershell -ExecutionPolicy Bypass -File LivePreview.ps1
#>

# ============================================================
# Console Information - Do Not Close This Window
# ============================================================
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = "Live Window Preview Tool"
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor DarkCyan
Write-Host "    LivePreview(win) - Live Window Preview Tool" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  [!] This window keeps the LivePreview function alive." -ForegroundColor Yellow
Write-Host "      Do NOT close this window, or the preview will stop." -ForegroundColor Yellow
Write-Host ""
Write-Host "  [!] 此窗口用于保持 LivePreview 实时预览功能运行。" -ForegroundColor Yellow
Write-Host "      请勿关闭此窗口，否则预览将停止工作。" -ForegroundColor Yellow
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor DarkCyan
Write-Host ""

# ============================================================
# Environment & System Pre-check
# ============================================================
$script:checksPassed = $true
$script:checkErrors = @()

# 1. Check OS - Windows Vista (6.0) or later required for DWM Thumbnail API
$osVersion = [System.Environment]::OSVersion
if ($osVersion.Platform -ne [System.PlatformID]::Win32NT) {
    $script:checkErrors += "This tool only runs on Windows (requires Win32NT platform)."
    $script:checksPassed = $false
}
elseif ($osVersion.Version.Major -lt 6) {
    $script:checkErrors += "Windows Vista or later is required (detected: $($osVersion.VersionString)). DWM Thumbnail API is not available."
    $script:checksPassed = $false
}

# 2. Check if Desktop Window Manager (DWM) service is running
try {
    $dwmService = Get-Service -Name "uxsms" -ErrorAction Stop
    if ($dwmService.Status -ne "Running") {
        $script:checkErrors += "Desktop Window Manager service (uxsms) is not running. DWM is required for live thumbnails."
        $script:checksPassed = $false
    }
} catch {
    # On Windows 8+, DWM cannot be disabled, so missing service check is acceptable
    if ([System.Environment]::OSVersion.Version.Major -lt 6 -or
        ([System.Environment]::OSVersion.Version.Major -eq 6 -and [System.Environment]::OSVersion.Version.Minor -lt 2)) {
        $script:checkErrors += "Cannot verify Desktop Window Manager service. DWM may not be available."
        $script:checksPassed = $false
    }
}

# 3. Check PowerShell version (need 3.0+ for reliable WPF support)
if ($PSVersionTable.PSVersion.Major -lt 3) {
    $script:checkErrors += "PowerShell 3.0 or later is required (detected: $($PSVersionTable.PSVersion)). Please update PowerShell."
    $script:checksPassed = $false
}

# 4. Check required .NET assemblies are loadable
$requiredAssemblies = @("PresentationFramework", "PresentationCore", "WindowsBase", "System.Windows.Forms")
foreach ($asm in $requiredAssemblies) {
    try {
        [void][System.Reflection.Assembly]::LoadWithPartialName($asm)
        if (-not ([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq $asm })) {
            throw "Assembly not found"
        }
    } catch {
        $script:checkErrors += "Required .NET assembly '$asm' is not available. Ensure .NET Framework 3.5+ or .NET Desktop Runtime is installed."
        $script:checksPassed = $false
    }
}

# 5. Check DWM composition is enabled (relevant for Vista/7 where it can be disabled)
if ($script:checksPassed) {
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DwmCheck {
    [DllImport("dwmapi.dll")]
    public static extern int DwmIsCompositionEnabled(out bool enabled);
}
"@ -ErrorAction Stop
        $compositionEnabled = $false
        $hr = [DwmCheck]::DwmIsCompositionEnabled([ref]$compositionEnabled)
        if ($hr -eq 0 -and -not $compositionEnabled) {
            $script:checkErrors += "DWM Desktop Composition is disabled. Please enable Aero theme or Desktop Composition in system settings."
            $script:checksPassed = $false
        }
    } catch {
        # If we can't check, dwmapi.dll might not be available at all
        $script:checkErrors += "Cannot load dwmapi.dll. DWM Thumbnail API may not be available on this system."
        $script:checksPassed = $false
    }
}

# 6. Check MacroTool.ps1 backend is present (for the Automate feature)
$script:MacroToolPath = Join-Path $PSScriptRoot 'MacroTool.ps1'
$script:MacroToolAvailable = Test-Path $script:MacroToolPath
# Auto-stop: hard wall-clock cap (seconds) for any single playback job. A runaway
# or infinite-repeat macro can never run longer than this. Adjust if needed.
$script:AutoMaxRuntime = 300

# --------------------------------------------------------------------------
# Persisted settings (settings.json next to the scripts).
# Currently stores the record/stop shortcut key so users can override F9 when
# it is already claimed by another app.
# --------------------------------------------------------------------------
$script:SettingsPath = Join-Path $PSScriptRoot 'settings.json'
$script:RecordStopVk = 0x78   # default F9
$script:AutoCollapseOnPlay = $false   # off by default; collapse macro panel after Play

# Friendly labels for the shortcut dropdown. Order here defines the UI order.
$script:StopKeyChoices = [ordered]@{
    'F9'          = 0x78
    'F8'          = 0x77
    'F10'         = 0x79
    'F11'         = 0x7A
    'F12'         = 0x7B
    'F7'          = 0x76
    'F6'          = 0x75
    'Pause/Break' = 0x13
    'Scroll Lock' = 0x91
}

function Get-StopKeyName([int]$vk) {
    foreach ($k in $script:StopKeyChoices.Keys) {
        if ($script:StopKeyChoices[$k] -eq $vk) { return $k }
    }
    return ("Key 0x{0:X2}" -f $vk)
}

function Load-Settings {
    if (Test-Path -LiteralPath $script:SettingsPath) {
        try {
            $s = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
            if ($s -and $s.recordStopVk) { $script:RecordStopVk = [int]$s.recordStopVk }
            if ($s -and ($s.PSObject.Properties.Name -contains 'autoCollapseOnPlay')) {
                $script:AutoCollapseOnPlay = [bool]$s.autoCollapseOnPlay
            }
        } catch {
            Write-Host "  [!] Could not read settings.json - using defaults." -ForegroundColor Yellow
        }
    }
}

function Save-Settings {
    try {
        [ordered]@{ recordStopVk = [int]$script:RecordStopVk; autoCollapseOnPlay = [bool]$script:AutoCollapseOnPlay } |
            ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    } catch {
        Write-Host "  [!] Could not write settings.json." -ForegroundColor Yellow
    }
}

Load-Settings
if (-not $script:MacroToolAvailable) {
    # Not fatal - LivePreview still works for preview-only; Automate button is disabled.
    Write-Host "  [!] MacroTool.ps1 not found next to LivePreview.ps1 - Automate feature will be disabled." -ForegroundColor Yellow
}

# Report results and exit if checks failed
if (-not $script:checksPassed) {
    Write-Host ""
    Write-Host "  [X] Environment check FAILED / 环境检查未通过" -ForegroundColor Red
    Write-Host "  ============================================================" -ForegroundColor Red
    foreach ($err in $script:checkErrors) {
        Write-Host "  - $err" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  LivePreview cannot start. Please fix the issues above."
    Write-Host "  LivePreview 无法启动，请先解决以上问题。"
    Write-Host ""
    Write-Host "  Press any key to exit / 按任意键退出..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

Write-Host "  [OK] Environment check passed / 环境检查通过" -ForegroundColor Green
Write-Host "  Starting LivePreview... / 正在启动 LivePreview..." -ForegroundColor Cyan
Write-Host ""

# ============================================================
# Main Program Start
# ============================================================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# P/Invoke definitions for DWM and Win32 APIs
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public struct RECT {
    public int Left, Top, Right, Bottom;
    public RECT(int l, int t, int r, int b) { Left=l; Top=t; Right=r; Bottom=b; }
}

public struct PSIZE {
    public int x, y;
}

[StructLayout(LayoutKind.Sequential)]
public struct DWM_THUMBNAIL_PROPERTIES {
    public int dwFlags;
    public RECT rcDestination;
    public RECT rcSource;
    public byte opacity;
    [MarshalAs(UnmanagedType.Bool)] public bool fVisible;
    [MarshalAs(UnmanagedType.Bool)] public bool fSourceClientAreaOnly;
}

public class NativeMethods {
    public const int DWM_TNP_RECTDESTINATION = 0x00000001;
    public const int DWM_TNP_RECTSOURCE      = 0x00000002;
    public const int DWM_TNP_OPACITY         = 0x00000004;
    public const int DWM_TNP_VISIBLE         = 0x00000008;
    public const int DWM_TNP_SOURCECLIENTAREAONLY = 0x00000010;

    public const int GWL_EXSTYLE = -20;
    public const int GW_OWNER = 4;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_APPWINDOW  = 0x00040000;

    [DllImport("dwmapi.dll")]
    public static extern int DwmRegisterThumbnail(IntPtr dest, IntPtr src, out IntPtr thumb);

    [DllImport("dwmapi.dll")]
    public static extern int DwmUnregisterThumbnail(IntPtr thumb);

    [DllImport("dwmapi.dll")]
    public static extern int DwmQueryThumbnailSourceSize(IntPtr thumb, out PSIZE size);

    [DllImport("dwmapi.dll")]
    public static extern int DwmUpdateThumbnailProperties(IntPtr thumb, ref DWM_THUMBNAIL_PROPERTIES props);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern IntPtr GetShellWindow();

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    public static List<KeyValuePair<IntPtr, string>> GetVisibleWindows(IntPtr excludeHandle) {
        var windows = new List<KeyValuePair<IntPtr, string>>();
        IntPtr shell = GetShellWindow();

        EnumWindows((hWnd, lParam) => {
            if (!IsWindowVisible(hWnd)) return true;
            if (hWnd == shell) return true;
            if (hWnd == excludeHandle) return true;

            int exStyle = GetWindowLong(hWnd, GWL_EXSTYLE);
            if ((exStyle & WS_EX_TOOLWINDOW) != 0 && (exStyle & WS_EX_APPWINDOW) == 0)
                return true;

            int titleLen = GetWindowTextLength(hWnd);
            if (titleLen == 0) return true;

            IntPtr owner = GetWindow(hWnd, GW_OWNER);
            if (owner != IntPtr.Zero && (exStyle & WS_EX_APPWINDOW) == 0)
                return true;

            var sb = new StringBuilder(titleLen + 1);
            GetWindowText(hWnd, sb, sb.Capacity);

            windows.Add(new KeyValuePair<IntPtr, string>(hWnd, sb.ToString()));
            return true;
        }, IntPtr.Zero);

        windows.Sort((a, b) => string.Compare(a.Value, b.Value, StringComparison.OrdinalIgnoreCase));
        return windows;
    }
}
"@ -ReferencedAssemblies @()

# ============================================================
# XAML for the Main Window
# ============================================================
[xml]$MainXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Live Preview"
        Width="320" Height="210"
        MinWidth="160" MinHeight="120"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ResizeMode="CanResizeWithGrip"
        ShowInTaskbar="True">
    <Border Name="OuterBorder" Background="#E0222222" CornerRadius="6" BorderBrush="#555555" BorderThickness="1">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <!-- Title Bar (auto-hides when mouse leaves window) -->
            <Border Grid.Row="0" Background="#E0333333" CornerRadius="6,6,0,0" Name="TitleBar" Height="28">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <TextBlock Grid.Column="0" Name="TitleText"
                               Text="  Live Preview - Right-click to select window"
                               Foreground="#CCCCCC" FontSize="11"
                               VerticalAlignment="Center" Margin="6,0,0,0"
                               TextTrimming="CharacterEllipsis"/>

                    <!-- EXPERIMENTAL: live macro countdown / progress badge.
                         Populated purely from the existing playback log tail; no
                         new deps. Collapsed when idle so it never intrudes. -->
                    <Border Grid.Column="1" Name="AutoTabBadge" Visibility="Collapsed"
                            Background="#3322AACC" CornerRadius="8" Padding="7,1"
                            VerticalAlignment="Center" Margin="0,0,4,0">
                        <TextBlock Name="AutoTabStatus" Text=""
                                   Foreground="#8AE6FF" FontSize="10" FontWeight="Bold"
                                   VerticalAlignment="Center"/>
                    </Border>

                    <StackPanel Grid.Column="2" Orientation="Horizontal" Margin="0,2,4,2">
                        <Button Name="BtnSelect" Content="&#x1F50D;" ToolTip="Select Window (Ctrl+W)"
                                Width="26" Height="20" FontSize="10"
                                Background="Transparent" Foreground="#CCCCCC" BorderThickness="0" Cursor="Hand"/>
                        <Button Name="BtnNew" Content="&#x2795;" ToolTip="New Instance (Ctrl+N)"
                                Width="26" Height="20" FontSize="10"
                                Background="Transparent" Foreground="#CCCCCC" BorderThickness="0" Cursor="Hand"/>
                        <Button Name="BtnScale" Content="1x" ToolTip="Scale Size (Ctrl+S) - cycles 1x/2x/3x/4x"
                                Width="26" Height="20" FontSize="10" FontWeight="Bold"
                                Background="Transparent" Foreground="#CCCCCC" BorderThickness="0" Cursor="Hand"/>
                        <Button Name="BtnPin" Content="&#x1F4CC;" ToolTip="Pin on Top (Ctrl+T)"
                                Width="26" Height="20" FontSize="10"
                                Background="Transparent" Foreground="#CCCCCC" BorderThickness="0" Cursor="Hand"/>
                        <Button Name="BtnAutomate" Content="&#x25B6;" ToolTip="Automate this window (record/play macros)"
                                Width="26" Height="20" FontSize="10"
                                Background="Transparent" Foreground="#7EC8FF" BorderThickness="0" Cursor="Hand"/>
                        <Button Name="BtnClose" Content="&#x2715;" ToolTip="Close"
                                Width="26" Height="20" FontSize="10"
                                Background="Transparent" Foreground="#CCCCCC" BorderThickness="0" Cursor="Hand"/>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- Automate flyout (collapsed by default; toggled by BtnAutomate) -->
            <Border Grid.Row="1" Name="AutomatePanel" Background="#F02A2A2A"
                    BorderBrush="#4478B4FF" BorderThickness="0,0,0,1" Visibility="Collapsed">
                <StackPanel Margin="8,6,8,8">
                    <StackPanel.LayoutTransform>
                        <ScaleTransform x:Name="AutoPanelScale" ScaleX="1" ScaleY="1"/>
                    </StackPanel.LayoutTransform>
                    <TextBlock Text="AUTOMATE THIS WINDOW" Foreground="#7EC8FF" FontSize="10"
                               FontWeight="Bold" Margin="0,0,0,4"/>

                    <!-- Settings sub-panel (toggled by the gear button; collapsed by default) -->
                    <Border Name="SettingsPanel" Background="#12121E" CornerRadius="3"
                            BorderBrush="#4478B4FF" BorderThickness="1" Padding="6,5"
                            Margin="0,0,0,6" Visibility="Collapsed">
                        <StackPanel>
                            <TextBlock Text="SETTINGS" Foreground="#7EC8FF" FontSize="10"
                                       FontWeight="Bold" Margin="0,0,0,4"/>
                            <TextBlock Text="Record / stop shortcut" Foreground="#999999" FontSize="10"/>
                            <StackPanel Orientation="Horizontal" Margin="0,1,0,0">
                                <ComboBox Name="SetStopKey" Width="130" Height="22" FontSize="11" Margin="0,0,4,0"/>
                                <Button Name="BtnSettingsSave" Content="Save" Width="56" Height="22" FontSize="11"
                                        Background="#4266D6" Foreground="White" BorderThickness="0" Cursor="Hand"/>
                            </StackPanel>
                            <TextBlock Name="SetHint" Text="Use a different key if F9 is already taken by another app."
                                       Foreground="#777777" FontSize="9" TextWrapping="Wrap" Margin="0,4,0,0"/>
                            <CheckBox Name="SetAutoCollapse" Content="Auto-collapse this panel after Play"
                                      Foreground="#CCCCCC" FontSize="10" Margin="0,6,0,0"/>
                        </StackPanel>
                    </Border>
                    <TextBlock Name="AutoTarget" Text="Target: (none)" Foreground="#AAAAAA"
                               FontSize="10" TextTrimming="CharacterEllipsis" Margin="0,0,0,6"/>

                    <TextBlock Text="Macro" Foreground="#999999" FontSize="10"/>
                    <!-- Macro list row: Refresh + Folder act on the macro list, so they
                         live next to the dropdown. The ComboBox fills remaining width. -->
                    <DockPanel Margin="0,1,0,6" LastChildFill="True">
                        <Button Name="BtnAutoRefresh" Content="&#x21BB;" ToolTip="Refresh macro list"
                                DockPanel.Dock="Right" Width="26" Height="22" FontSize="13"
                                Background="#3A3A58" Foreground="#EEEEEE" BorderThickness="0" Cursor="Hand" Margin="4,0,0,0"/>
                        <Button Name="BtnAutoFolder" Content="&#x1F4C1;" ToolTip="Reveal macro folder in Explorer"
                                DockPanel.Dock="Right" Width="26" Height="22" FontSize="11"
                                Background="#3A3A58" Foreground="#EEEEEE" BorderThickness="0" Cursor="Hand" Margin="4,0,0,0"/>
                        <ComboBox Name="AutoMacro" Height="22" FontSize="11" MaxDropDownHeight="260"/>
                    </DockPanel>

                    <Grid Margin="0,0,0,6">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel Grid.Column="0" Margin="0,0,3,0">
                            <TextBlock Text="CountDown" Foreground="#999999" FontSize="9"/>
                            <TextBox Name="AutoDelay" Text="3" FontSize="11" Height="20"/>
                        </StackPanel>
                        <StackPanel Grid.Column="1" Margin="0,0,3,0">
                            <TextBlock Text="Repeat" Foreground="#999999" FontSize="9"/>
                            <TextBox Name="AutoRepeat" Text="1" FontSize="11" Height="20"/>
                        </StackPanel>
                        <StackPanel Grid.Column="2" Margin="0,0,3,0">
                            <TextBlock Text="Interval" Foreground="#999999" FontSize="9"/>
                            <TextBox Name="AutoInterval" Text="0" FontSize="11" Height="20"/>
                        </StackPanel>
                        <StackPanel Grid.Column="3">
                            <TextBlock Text="Speed" Foreground="#999999" FontSize="9"/>
                            <TextBox Name="AutoSpeed" Text="1" FontSize="11" Height="20"/>
                        </StackPanel>
                    </Grid>

                    <TextBlock Text="Playback mode" Foreground="#999999" FontSize="10"/>
                    <ComboBox Name="AutoMode" Height="22" FontSize="11" Margin="0,1,0,6">
                        <ComboBoxItem Content="Flash-restore (focus target, return to you)" IsSelected="True"/>
                        <ComboBoxItem Content="Foreground (bring target to front)"/>
                        <ComboBoxItem Content="Background (no focus - Win32 apps only)"/>
                    </ComboBox>

                    <!-- Action row: name box stretches; Record / Play / Settings are
                         fixed. Refresh + Folder moved up next to the macro list. -->
                    <DockPanel Margin="0,0,0,4" LastChildFill="True">
                        <Button Name="BtnSettings" Content="&#x2699;" ToolTip="Settings (record/stop shortcut)"
                                DockPanel.Dock="Right" Width="28" Height="24" FontSize="13"
                                Background="#3A3A58" Foreground="#EEEEEE" BorderThickness="0" Cursor="Hand" Margin="4,0,0,0"/>
                        <Button Name="BtnAutoPlay" Content="&#x25B6; Play" DockPanel.Dock="Right"
                                Width="64" Height="24" FontSize="11"
                                Background="#4266D6" Foreground="White" BorderThickness="0" Cursor="Hand" Margin="4,0,0,0"/>
                        <Button Name="BtnAutoRecord" Content="&#x25CF; Record" DockPanel.Dock="Right"
                                Width="76" Height="24" FontSize="11"
                                Background="#3A3A58" Foreground="#EEEEEE" BorderThickness="0" Cursor="Hand" Margin="4,0,0,0"/>
                        <TextBox Name="AutoRecName" Text="mymacro" FontSize="11" Height="24"
                                 VerticalContentAlignment="Center"/>
                    </DockPanel>

                    <!-- Status indicator: colored dot + live text (replaces the Stop button) -->
                    <Border Background="#12121E" CornerRadius="3" Padding="6,4" Margin="0,2,0,0">
                        <DockPanel LastChildFill="True">
                            <Ellipse Name="AutoDot" Width="9" Height="9" Fill="#666666"
                                     DockPanel.Dock="Left"
                                     VerticalAlignment="Top" Margin="0,3,6,0"/>
                            <TextBlock Name="AutoStatus" Text="Idle." Foreground="#B8F0B8" FontSize="10"
                                       FontFamily="Consolas" TextWrapping="Wrap" MinHeight="30"/>
                        </DockPanel>
                    </Border>
                    <TextBlock Name="AutoHint" Text="Recording stops with the configured shortcut. Playback auto-stops when done or on safety limit."
                               Foreground="#777777" FontSize="9" TextWrapping="Wrap" Margin="0,3,0,0"/>
                </StackPanel>
            </Border>

            <!-- Preview Area -->
            <Border Grid.Row="2" Name="PreviewBorder" Background="#FF111111" CornerRadius="0,0,6,6" ClipToBounds="True">
                <TextBlock Name="PlaceholderText"
                           Text="Right-click title bar or click the magnifying glass to select a window to preview"
                           Foreground="#888888" FontSize="12"
                           HorizontalAlignment="Center" VerticalAlignment="Center"
                           TextWrapping="Wrap" TextAlignment="Center" Margin="20"/>
            </Border>
        </Grid>
    </Border>
</Window>
"@

# ============================================================
# XAML for the Window Picker
# ============================================================
[xml]$PickerXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Select Window to Preview"
        Width="460" Height="420"
        WindowStartupLocation="CenterOwner"
        Background="#222222"
        ResizeMode="CanResize">
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0" Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox Name="SearchBox" Grid.Column="0"
                     Background="#333333" Foreground="#EEEEEE"
                     BorderBrush="#555555" Padding="6,4" FontSize="12"/>
            <Button Name="BtnRefresh" Grid.Column="1" Content="Refresh" Margin="6,0,0,0"
                    Padding="10,4" Background="#444444" Foreground="#CCCCCC" BorderBrush="#666666"/>
        </Grid>

        <ListBox Name="WindowList" Grid.Row="1"
                 Background="#1A1A1A" BorderBrush="#555555"
                 Foreground="#EEEEEE" FontSize="12"/>

        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
            <Button Name="BtnOk" Content="OK" Width="80" Height="28" Margin="0,0,8,0"
                    IsEnabled="False" Background="#0078D4" Foreground="White" BorderBrush="#0078D4"/>
            <Button Name="BtnCancel" Content="Cancel" Width="80" Height="28"
                    Background="#444444" Foreground="#CCCCCC" BorderBrush="#666666"/>
        </StackPanel>
    </Grid>
</Window>
"@

# ============================================================
# Global State & Helpers
# ============================================================
$script:firstTargetSet  = $false
$script:openWindowCount = 0
$script:instanceCounter = 0
$script:hostPid         = $PID
$script:MINI_WIDTH  = 320
$script:MINI_HEIGHT = 210

# Console window helper for minimizing cmd.exe
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class ConsoleHelper {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    public const int SW_MINIMIZE = 6;
    public static void MinimizeConsole() {
        IntPtr hwnd = GetConsoleWindow();
        if (hwnd != IntPtr.Zero) {
            ShowWindow(hwnd, SW_MINIMIZE);
        }
    }
}
"@

# ============================================================
# Per-Window Functions (operate on context stored in Window.Tag)
# ============================================================

function Get-Ctx($sender) {
    $wnd = [System.Windows.Window]::GetWindow($sender)
    if ($null -eq $wnd) { return $null }
    return $wnd.Tag
}

function Update-Thumbnail($ctx) {
    if ($null -eq $ctx -or $ctx.ThumbnailHandle -eq [IntPtr]::Zero) { return }
    $wnd = $ctx.Window
    $previewBorder = $ctx.PreviewBorder

    $sourceSize = New-Object PSIZE
    $hr = [NativeMethods]::DwmQueryThumbnailSourceSize($ctx.ThumbnailHandle, [ref]$sourceSize)
    if ($hr -ne 0) { return }

    $point = $previewBorder.TranslatePoint([System.Windows.Point]::new(0, 0), $wnd)
    $source = [System.Windows.PresentationSource]::FromVisual($wnd)
    $dpiX = 1.0; $dpiY = 1.0
    if ($null -ne $source) {
        $dpiX = $source.CompositionTarget.TransformToDevice.M11
        $dpiY = $source.CompositionTarget.TransformToDevice.M22
    }

    $destLeft   = [int]($point.X * $dpiX)
    $destTop    = [int]($point.Y * $dpiY)
    $destRight  = [int](($point.X + $previewBorder.ActualWidth) * $dpiX)
    $destBottom = [int](($point.Y + $previewBorder.ActualHeight) * $dpiY)

    $destWidth  = $destRight - $destLeft
    $destHeight = $destBottom - $destTop

    if ($sourceSize.y -gt 0 -and $destHeight -gt 0) {
        $sourceAspect = [double]$sourceSize.x / [double]$sourceSize.y
        $destAspect   = [double]$destWidth / [double]$destHeight
        if ($sourceAspect -gt $destAspect) {
            $newHeight = [int]($destWidth / $sourceAspect)
            $offset = [int](($destHeight - $newHeight) / 2)
            $destTop += $offset
            $destBottom = $destTop + $newHeight
        } else {
            $newWidth = [int]($destHeight * $sourceAspect)
            $offset = [int](($destWidth - $newWidth) / 2)
            $destLeft += $offset
            $destRight = $destLeft + $newWidth
        }
    }

    $props = New-Object DWM_THUMBNAIL_PROPERTIES
    $props.dwFlags = [NativeMethods]::DWM_TNP_RECTDESTINATION -bor [NativeMethods]::DWM_TNP_VISIBLE -bor [NativeMethods]::DWM_TNP_OPACITY -bor [NativeMethods]::DWM_TNP_SOURCECLIENTAREAONLY
    $props.rcDestination = New-Object RECT -ArgumentList $destLeft, $destTop, $destRight, $destBottom
    $props.fVisible = $true
    $props.fSourceClientAreaOnly = $false
    $props.opacity = 255
    [void][NativeMethods]::DwmUpdateThumbnailProperties($ctx.ThumbnailHandle, [ref]$props)
}

function Unregister-Thumbnail($ctx) {
    if ($null -eq $ctx) { return }
    if ($ctx.ThumbnailHandle -ne [IntPtr]::Zero) {
        [void][NativeMethods]::DwmUnregisterThumbnail($ctx.ThumbnailHandle)
        $ctx.ThumbnailHandle = [IntPtr]::Zero
    }
}

function Set-TargetWindow($ctx, [IntPtr]$Handle, [string]$Title) {
    Unregister-Thumbnail $ctx

    $ctx.TargetHandle = $Handle

    # Get target window's PID for display
    $targetPid = 0
    [void][NativeMethods]::GetWindowThreadProcessId($Handle, [ref]$targetPid)

    # Resolve a friendly display name for the target process.
    # Priority: FileDescription (localized, e.g. Chinese product name) > MainWindowTitle > ProcessName
    $procName = "unknown"
    try {
        $proc = Get-Process -Id $targetPid -ErrorAction Stop
        $friendly = $null
        try {
            if ($proc.MainModule -and $proc.MainModule.FileVersionInfo) {
                $fd = $proc.MainModule.FileVersionInfo.FileDescription
                if ($fd -and $fd.Trim()) { $friendly = $fd.Trim() }
            }
        } catch {}
        if (-not $friendly -and $proc.MainWindowTitle) {
            $mwt = $proc.MainWindowTitle.Trim()
            if ($mwt) { $friendly = $mwt }
        }
        if (-not $friendly) { $friendly = $proc.ProcessName }
        $procName = $friendly
    } catch {}

    # Short title (shown on taskbar AND in-app title bar): "FriendlyName(#Index)"
    # Extract this window's index from InstanceTag ("hostPid#index")
    $idx = ($ctx.InstanceTag -split '#')[-1]
    $shortTitle = "$procName(#$idx)"
    $ctx.TitleText.Text = "  $shortTitle"
    $ctx.Window.Title = $shortTitle
    $ctx.TargetTitle = $procName
    if ($ctx.AutoTarget) { $ctx.AutoTarget.Text = "Target: $procName" }
    $ctx.PlaceholderText.Visibility = [System.Windows.Visibility]::Collapsed

    $helper = [System.Windows.Interop.WindowInteropHelper]::new($ctx.Window)
    $thisHandle = $helper.Handle

    $thumbOut = [IntPtr]::Zero
    $hr = [NativeMethods]::DwmRegisterThumbnail($thisHandle, $Handle, [ref]$thumbOut)
    if ($hr -ne 0) {
        [System.Windows.MessageBox]::Show("Failed to register thumbnail. Error: 0x$($hr.ToString('X8'))`nThe target window may have been closed.", "Error")
        return
    }
    $ctx.ThumbnailHandle = $thumbOut
    Update-Thumbnail $ctx

    # Minimize cmd.exe on first target selection (any window)
    if (-not $script:firstTargetSet) {
        $script:firstTargetSet = $true
        [ConsoleHelper]::MinimizeConsole()
    }
}

function Show-WindowPicker($ctx) {
    $reader2 = [System.Xml.XmlNodeReader]::new($PickerXaml)
    $picker = [System.Windows.Markup.XamlReader]::Load($reader2)
    $picker.Owner = $ctx.Window

    $searchBox  = $picker.FindName("SearchBox")
    $windowList = $picker.FindName("WindowList")
    $btnOk2     = $picker.FindName("BtnOk")
    $btnCancel2 = $picker.FindName("BtnCancel")
    $btnRefresh = $picker.FindName("BtnRefresh")

    $script:_pickerWindows = $null
    $script:_pickerResult  = $null

    $refreshAction = {
        $helper = [System.Windows.Interop.WindowInteropHelper]::new($ctx.Window)
        $excludeHandle = $helper.Handle
        $script:_pickerWindows = [NativeMethods]::GetVisibleWindows($excludeHandle)
        $windowList.Items.Clear()
        foreach ($w in $script:_pickerWindows) {
            [void]$windowList.Items.Add($w.Value)
        }
    }

    & $refreshAction

    $searchBox.Add_TextChanged({
        $filter = $searchBox.Text.ToLowerInvariant().Trim()
        $windowList.Items.Clear()
        foreach ($w in $script:_pickerWindows) {
            if ([string]::IsNullOrEmpty($filter) -or $w.Value.ToLowerInvariant().Contains($filter)) {
                [void]$windowList.Items.Add($w.Value)
            }
        }
    })

    $btnRefresh.Add_Click({ & $refreshAction })

    $windowList.Add_SelectionChanged({
        $btnOk2.IsEnabled = ($windowList.SelectedIndex -ge 0)
    })

    $windowList.Add_MouseDoubleClick({
        if ($windowList.SelectedIndex -ge 0) {
            $selectedTitle = $windowList.SelectedItem.ToString()
            foreach ($w in $script:_pickerWindows) {
                if ($w.Value -eq $selectedTitle) {
                    $script:_pickerResult = $w
                    break
                }
            }
            $picker.DialogResult = $true
            $picker.Close()
        }
    })

    $btnOk2.Add_Click({
        if ($windowList.SelectedIndex -ge 0) {
            $selectedTitle = $windowList.SelectedItem.ToString()
            foreach ($w in $script:_pickerWindows) {
                if ($w.Value -eq $selectedTitle) {
                    $script:_pickerResult = $w
                    break
                }
            }
            $picker.DialogResult = $true
            $picker.Close()
        }
    })

    $btnCancel2.Add_Click({
        $picker.DialogResult = $false
        $picker.Close()
    })

    $searchBox.Focus() | Out-Null

    $result = $picker.ShowDialog()
    if ($result -eq $true -and $null -ne $script:_pickerResult) {
        Set-TargetWindow $ctx $script:_pickerResult.Key $script:_pickerResult.Value
    }
}

function Show-TitleBar($ctx) {
    if ($ctx.TitleBarVisible) { return }
    $ctx.TitleBarVisible = $true
    $ctx.TitleBar.Visibility = [System.Windows.Visibility]::Visible
    $ctx.PreviewBorder.CornerRadius = [System.Windows.CornerRadius]::new(0, 0, 6, 6)
    $ctx.Window.Height = $ctx.Window.Height + 28
    Update-Thumbnail $ctx
}

function Hide-TitleBar($ctx) {
    if (-not $ctx.TitleBarVisible) { return }
    # Keep the title bar (and flyout) visible while the Automate panel is open.
    if ($ctx.AutomatePanel -and $ctx.AutomatePanel.Visibility -eq [System.Windows.Visibility]::Visible) { return }
    # EXPERIMENTAL: keep the title bar visible while a macro job is running so the
    # countdown / progress badge stays on-screen even when focus is on the target.
    if ($ctx.AutoJobProc -and -not $ctx.AutoJobProc.HasExited) { return }
    $ctx.TitleBarVisible = $false
    $ctx.TitleBar.Visibility = [System.Windows.Visibility]::Collapsed
    $ctx.PreviewBorder.CornerRadius = [System.Windows.CornerRadius]::new(6)

    if ($ctx.ThumbnailHandle -ne [IntPtr]::Zero) {
        $sourceSize = New-Object PSIZE
        $hr = [NativeMethods]::DwmQueryThumbnailSourceSize($ctx.ThumbnailHandle, [ref]$sourceSize)
        if ($hr -eq 0 -and $sourceSize.x -gt 0 -and $sourceSize.y -gt 0) {
            $source = [System.Windows.PresentationSource]::FromVisual($ctx.Window)
            $dpiX = 1.0; $dpiY = 1.0
            if ($null -ne $source) {
                $dpiX = $source.CompositionTarget.TransformToDevice.M11
                $dpiY = $source.CompositionTarget.TransformToDevice.M22
            }
            $sourceAspect = [double]$sourceSize.x / [double]$sourceSize.y
            $contentWidth = $ctx.Window.Width - 2
            $exactHeight = $contentWidth / $sourceAspect
            $ctx.Window.Height = [Math]::Max($exactHeight + 2, 120)
        }
    } else {
        $ctx.Window.Height = [Math]::Max($ctx.Window.Height - 28, 120)
    }
    Update-Thumbnail $ctx
}

# ============================================================
# Automate feature helpers (drive MacroTool.ps1 as a background job)
# ============================================================
function Refresh-AutoMacros($ctx) {
    $ctx.AutoMacro.Items.Clear()
    if (-not $script:MacroToolAvailable) { return }
    try {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:MacroToolPath list -Json 2>$null
        $json = ($out | Out-String).Trim()
        if ($json) {
            $names = $json | ConvertFrom-Json
            foreach ($nm in @($names)) { [void]$ctx.AutoMacro.Items.Add($nm) }
            if ($ctx.AutoMacro.Items.Count -eq 1) { $ctx.AutoMacro.SelectedIndex = 0 }
        }
    } catch {
        $ctx.AutoStatus.Text = "Could not list macros: $($_.Exception.Message)"
    }
}

function Set-AutoUiState($ctx, [string]$state) {
    # state: 'idle' | 'record' | 'play'
    $ctx.AutoBusy = if ($state -eq 'idle') { $null } else { $state }
    switch ($state) {
        'record' {
            $ctx.AutoDot.Fill = [System.Windows.Media.Brushes]::Red
            $ctx.BtnAutoRecord.Content = [char]0x25A0 + " Stop"
            $ctx.BtnAutoRecord.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(214,66,66))
            $ctx.BtnAutoPlay.IsEnabled = $false
            $ctx.AutoHint.Text = "Recording... perform your actions, then press $(Get-StopKeyName $script:RecordStopVk) (or click Stop) to finish."
        }
        'play' {
            $ctx.AutoDot.Fill = [System.Windows.Media.Brushes]::LimeGreen
            $ctx.BtnAutoPlay.Content = [char]0x25A0 + " Stop"
            $ctx.BtnAutoPlay.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(214,66,66))
            $ctx.BtnAutoRecord.IsEnabled = $false
            $ctx.AutoHint.Text = "Playing... click Stop to halt. Auto-stops when done or on safety limit."
        }
        default {
            $ctx.AutoDot.Fill = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(102,102,102))
            $ctx.BtnAutoRecord.Content = [char]0x25CF + " Record"
            $ctx.BtnAutoRecord.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(58,58,88))
            $ctx.BtnAutoRecord.IsEnabled = $true
            $ctx.BtnAutoPlay.Content = [char]0x25B6 + " Play"
            $ctx.BtnAutoPlay.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(66,102,214))
            $ctx.BtnAutoPlay.IsEnabled = $true
            $ctx.AutoHint.Text = "Recording stops with $(Get-StopKeyName $script:RecordStopVk). Playback auto-stops when done or on safety limit."
        }
    }
}

# ============================================================
# EXPERIMENTAL: live macro countdown / progress in the tab title bar.
#
# Fully self-contained: it only *reads* the playback log text that
# Start-AutoJob already tails (no new processes, files, timers, modules or
# other dependencies). If parsing fails for any reason it silently does
# nothing, so existing behavior is never affected.
#
# Recognized log lines (emitted by MacroTool.ps1):
#   "Starting in:   Ns"   -> pre-run delay countdown
#   "Run 3/5..."          -> current run / total (or 3/inf)
#   "Next run in:   Ns"   -> between-run interval countdown
#   "Done."               -> handled separately as a finished flash
# ============================================================
function Set-AutoTabBadge($ctx, [string]$text, [string]$colorHex) {
    if (-not $ctx.AutoTabStatus -or -not $ctx.AutoTabBadge) { return }
    if ([string]::IsNullOrEmpty($text)) {
        $ctx.AutoTabBadge.Visibility = [System.Windows.Visibility]::Collapsed
        $ctx.AutoTabStatus.Text = ""
        return
    }
    $ctx.AutoTabStatus.Text = $text
    if ($colorHex) {
        try {
            $ctx.AutoTabStatus.Foreground =
                [System.Windows.Media.SolidColorBrush]::new(
                    [System.Windows.Media.ColorConverter]::ConvertFromString($colorHex))
        } catch {}
    }
    $ctx.AutoTabBadge.Visibility = [System.Windows.Visibility]::Visible
}

function Update-AutoTabBadge($ctx, $lines) {
    if (-not $lines) { return }
    # Scan from the newest line backwards for the most recent meaningful state.
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $ln = "" + $lines[$i]
        if ($ln -match 'Starting in:\s*(\d+)\s*s') {
            Set-AutoTabBadge $ctx ("start " + $matches[1] + "s") "#8AE6FF"; return
        }
        if ($ln -match 'Next run in:\s*(\d+)\s*s') {
            Set-AutoTabBadge $ctx ("next " + $matches[1] + "s") "#8AE6FF"; return
        }
        if ($ln -match 'Run\s+(\d+)\s*/\s*(\d+|inf)') {
            $cur = $matches[1]; $tot = $matches[2]
            $sym = [char]0x25B6  # play triangle
            Set-AutoTabBadge $ctx ("$sym $cur/$tot") "#8AE6FF"; return
        }
        if ($ln -match '^\s*Done\.') { return }  # completion handled by the flash
    }
}

# Flash a transient "done" badge in the tab, then auto-hide after a moment.
function Show-AutoTabDone($ctx) {
    if (-not $ctx.AutoTabStatus -or -not $ctx.AutoTabBadge) { return }
    # Make sure the badge is on-screen: reveal the title bar for the flash.
    try { Show-TitleBar $ctx } catch {}
    Set-AutoTabBadge $ctx ([char]0x2713 + " done") "#B8F0B8"   # checkmark
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds(3)
    $doneCtx = $ctx
    $t.Add_Tick({
        $t.Stop()
        try { Set-AutoTabBadge $doneCtx "" $null } catch {}
    }.GetNewClosure())
    $t.Start()
}

function Start-AutoJob($ctx, [string]$macroArgs, [string]$label, [string]$kind) {
    if (-not $script:MacroToolAvailable) { $ctx.AutoStatus.Text = "MacroTool.ps1 not available."; return }
    $stamp = [DateTime]::Now.Ticks
    $ctx.AutoJobLog  = Join-Path $env:TEMP ("wt_job_{0}.log" -f $stamp)
    $ctx.AutoStopFile = Join-Path $env:TEMP ("wt_stop_{0}.flag" -f $stamp)
    $ctx.AutoJobDone = $null
    Remove-Item -LiteralPath $ctx.AutoStopFile -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $ctx.AutoJobLog -Value "" -Encoding UTF8
    $ctx.AutoStatus.Text = "$label started..."
    Set-AutoUiState $ctx $kind

    # Run MacroTool.ps1 DIRECTLY as the tracked process (no wrapper subshell that
    # could orphan the real player). Redirect its output to the log file so we can
    # tail it. Because AutoJobProc IS the player, Stop can kill it reliably and
    # input injection halts immediately. A -StopFile is passed so playback also
    # aborts gracefully the instant the flag file appears (focus-independent).
    #
    # IMPORTANT: -ArgumentList as an array does NOT auto-quote elements that
    # contain spaces, which would break if the install/user path has spaces.
    # Build the argument list as a single, explicitly-quoted string instead.
    $macroParts = ($macroArgs -split ' (?=(?:[^"]*"[^"]*")*[^"]*$)' | Where-Object { $_ -ne '' }) |
                  ForEach-Object { $_ -replace '^"(.*)"$', '$1' }
    # Requote any argument token that contains whitespace.
    $macroTokens = $macroParts | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }

    $argParts = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", ('"' + $script:MacroToolPath + '"')
    ) + $macroTokens + @("-StopFile", ('"' + $ctx.AutoStopFile + '"'))

    # Auto-stop safety nets for PLAYBACK only:
    #  - WatchPid: if this LivePreview process exits, the player stops itself.
    #  - MaxRuntime: hard wall-clock cap so a runaway/infinite macro can't run forever.
    if ($macroArgs -match '^\s*play\b') {
        $argParts += @("-WatchPid", "$PID", "-MaxRuntime", "$($script:AutoMaxRuntime)")
    }

    # Pass the user-configured record/stop shortcut for RECORD jobs.
    if ($macroArgs -match '^\s*record\b') {
        $argParts += @("-StopVk", "$($script:RecordStopVk)")
    }

    $argString = $argParts -join ' '
    $proc = Start-Process powershell -ArgumentList $argString -WindowStyle Hidden -PassThru `
                -RedirectStandardOutput $ctx.AutoJobLog `
                -RedirectStandardError ($ctx.AutoJobLog + ".err")
    $ctx.AutoJobProc = $proc

    # Tail the log into the status area and detect completion via process exit.
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(400)
    $ctx.AutoTimer = $timer
    $timerCtx = $ctx
    $timer.Add_Tick({
        $c = $timerCtx
        try {
            if (Test-Path $c.AutoJobLog) {
                $lines = Get-Content -LiteralPath $c.AutoJobLog -ErrorAction SilentlyContinue
                if ($lines) {
                    $tail = ($lines | Select-Object -Last 6) -join "`n"
                    $c.AutoStatus.Text = $tail
                    # EXPERIMENTAL: derive a compact tab-view badge from the same log.
                    try { Update-AutoTabBadge $c $lines } catch {}
                }
            }
        } catch {}
        # Completion = the tracked player process has exited.
        if (-not $c.AutoJobProc -or $c.AutoJobProc.HasExited) {
            $c.AutoTimer.Stop()
            $c.AutoTimer = $null
            $c.AutoJobProc = $null
            Remove-Item -LiteralPath $c.AutoJobLog -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath ($c.AutoJobLog + ".err") -Force -ErrorAction SilentlyContinue
            $c.AutoStatus.Text = ($c.AutoStatus.Text + "`n[finished]")
            # EXPERIMENTAL: flash a transient "done" badge, then auto-hide.
            try { Show-AutoTabDone $c } catch {}
            Set-AutoUiState $c 'idle'
            Refresh-AutoMacros $c
        }
    }.GetNewClosure())
    $timer.Start()
}

function Stop-AutoJob($ctx) {
    # Stop the running job (playback or recording) WITHOUT closing this window.
    # 1) Drop the stop-flag file so any running playback aborts gracefully.
    # 2) Kill the tracked player process.
    # 3) Sweep for any stray MacroTool play process (belt and braces).
    $stopped = $false
    if ($ctx.AutoStopFile) {
        try { Set-Content -LiteralPath $ctx.AutoStopFile -Value 'stop' -ErrorAction SilentlyContinue; $stopped = $true } catch {}
    }
    if ($ctx.AutoJobProc -and -not $ctx.AutoJobProc.HasExited) {
        try {
            & taskkill.exe /PID $ctx.AutoJobProc.Id /T /F 2>$null | Out-Null
            $stopped = $true
        } catch {}
    }
    # Safety sweep: kill ANY powershell running MacroTool.ps1 'play'.
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'MacroTool\.ps1.*\bplay\b' } |
            ForEach-Object {
                & taskkill.exe /PID $_.ProcessId /T /F 2>$null | Out-Null
                $stopped = $true
            }
    } catch {}

    $ctx.AutoJobProc = $null
    if ($ctx.AutoTimer) { $ctx.AutoTimer.Stop(); $ctx.AutoTimer = $null }
    if ($ctx.AutoJobLog) {
        Remove-Item -LiteralPath $ctx.AutoJobLog -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ($ctx.AutoJobLog + ".err") -Force -ErrorAction SilentlyContinue
    }
    if ($ctx.AutoStopFile) { Remove-Item -LiteralPath $ctx.AutoStopFile -Force -ErrorAction SilentlyContinue }
    $wasKind = $ctx.AutoBusy
    if ($stopped) {
        $ctx.AutoStatus.Text = if ($wasKind -eq 'record') { "Recording stopped (not saved)." } else { "Stopped. All playback halted." }
    } else {
        $ctx.AutoStatus.Text = "Nothing is running."
    }
    Set-AutoUiState $ctx 'idle'
    Refresh-AutoMacros $ctx
    # EXPERIMENTAL: clear the tab countdown badge on manual stop.
    try { Set-AutoTabBadge $ctx "" $null } catch {}
}
# ============================================================
# New-PreviewWindow: Creates an independent preview window
# ============================================================
function New-PreviewWindow {
    $reader = [System.Xml.XmlNodeReader]::new($MainXaml)
    $wnd = [System.Windows.Markup.XamlReader]::Load($reader)

    $script:instanceCounter++
    $instanceTag = "$script:hostPid#$script:instanceCounter"
    $wnd.Title = "LivePreview($instanceTag)"

    $titleText = $wnd.FindName("TitleText")
    $titleText.Text = "  LivePreview($instanceTag) - Right-click to select window"

    # Build per-window context (stored in Window.Tag)
    $ctx = @{
        Window          = $wnd
        InstanceTag     = $instanceTag
        TitleBar        = $wnd.FindName("TitleBar")
        TitleText       = $wnd.FindName("TitleText")
        BtnSelect       = $wnd.FindName("BtnSelect")
        BtnNew          = $wnd.FindName("BtnNew")
        BtnScale        = $wnd.FindName("BtnScale")
        BtnPin          = $wnd.FindName("BtnPin")
        BtnAutomate     = $wnd.FindName("BtnAutomate")
        BtnSettings     = $wnd.FindName("BtnSettings")
        BtnClose        = $wnd.FindName("BtnClose")
        SettingsPanel   = $wnd.FindName("SettingsPanel")
        SetStopKey      = $wnd.FindName("SetStopKey")
        BtnSettingsSave = $wnd.FindName("BtnSettingsSave")
        SetHint         = $wnd.FindName("SetHint")
        PreviewBorder   = $wnd.FindName("PreviewBorder")
        PlaceholderText = $wnd.FindName("PlaceholderText")
        OuterBorder     = $wnd.FindName("OuterBorder")
        AutomatePanel   = $wnd.FindName("AutomatePanel")
        AutoTarget      = $wnd.FindName("AutoTarget")
        AutoMacro       = $wnd.FindName("AutoMacro")
        AutoDelay       = $wnd.FindName("AutoDelay")
        AutoRepeat      = $wnd.FindName("AutoRepeat")
        AutoInterval    = $wnd.FindName("AutoInterval")
        AutoSpeed       = $wnd.FindName("AutoSpeed")
        AutoMode        = $wnd.FindName("AutoMode")
        AutoRecName     = $wnd.FindName("AutoRecName")
        BtnAutoRecord   = $wnd.FindName("BtnAutoRecord")
        BtnAutoPlay     = $wnd.FindName("BtnAutoPlay")
        BtnAutoRefresh  = $wnd.FindName("BtnAutoRefresh")
        BtnAutoFolder   = $wnd.FindName("BtnAutoFolder")
        AutoStatus      = $wnd.FindName("AutoStatus")
        AutoDot         = $wnd.FindName("AutoDot")
        AutoTabBadge    = $wnd.FindName("AutoTabBadge")
        AutoTabStatus   = $wnd.FindName("AutoTabStatus")
        AutoHint        = $wnd.FindName("AutoHint")
        SetAutoCollapse = $wnd.FindName("SetAutoCollapse")
        AutoPanelScale  = $wnd.FindName("AutoPanelScale")
        AutoBusy        = $null   # 'record' | 'play' | $null
        ThumbnailHandle = [IntPtr]::Zero
        TargetHandle    = [IntPtr]::Zero
        TargetTitle     = ""
        AutoJobLog      = $null
        AutoJobDone     = $null
        AutoStopFile    = $null
        AutoJobProc     = $null
        AutoTimer       = $null
        IsPinned        = $false
        Timer           = $null
        TitleBarVisible = $true
        ScaleIndex      = 0
        ScaleFactors    = @(1, 2, 3, 4)
        BaseWidth       = 320.0
        BaseHeight      = 210.0
    }
    $wnd.Tag = $ctx

    # ==========================================================
    # Event Handlers (all use Get-Ctx to retrieve per-window state)
    # ==========================================================

    # Title bar drag / double-click to snap to mini size
    $ctx.TitleBar.Add_MouseLeftButtonDown({
        param($sender, $e)
        $c = Get-Ctx $sender
        if ($e.ClickCount -eq 2) {
            if ($c.ThumbnailHandle -ne [IntPtr]::Zero) {
                $sourceSize = New-Object PSIZE
                $hr = [NativeMethods]::DwmQueryThumbnailSourceSize($c.ThumbnailHandle, [ref]$sourceSize)
                if ($hr -eq 0 -and $sourceSize.x -gt 0 -and $sourceSize.y -gt 0) {
                    $titleBarHeight = 30
                    $availableHeight = $script:MINI_HEIGHT - $titleBarHeight
                    $sourceAspect = [double]$sourceSize.x / [double]$sourceSize.y
                    $fitWidth = $script:MINI_WIDTH
                    $fitHeight = [int]($fitWidth / $sourceAspect)
                    if ($fitHeight -gt $availableHeight) {
                        $fitHeight = $availableHeight
                        $fitWidth = [int]($fitHeight * $sourceAspect)
                    }
                    $c.Window.Width = [Math]::Max($fitWidth + 2, 160)
                    $c.Window.Height = [Math]::Max($fitHeight + $titleBarHeight + 2, 120)
                }
            } else {
                $c.Window.Width = $script:MINI_WIDTH
                $c.Window.Height = $script:MINI_HEIGHT
            }
            # Reset scale state: this new size becomes the 1x reference
            $c.ScaleIndex = 0
            $c.BaseWidth  = $c.Window.Width
            $c.BaseHeight = $c.Window.Height
            $c.BaseCaptured = $true
            $c.BtnScale.Content = "1x"
            if ($c.AutoPanelScale) { $c.AutoPanelScale.ScaleX = 1; $c.AutoPanelScale.ScaleY = 1 }
        } else {
            $c.Window.DragMove()
        }
    })

    # Right-click to pick window
    $ctx.TitleBar.Add_MouseRightButtonDown({
        param($sender, $e)
        $c = Get-Ctx $sender
        Show-WindowPicker $c
    })

    # Select window button
    $ctx.BtnSelect.Add_Click({
        param($sender, $e)
        $c = Get-Ctx $sender
        Show-WindowPicker $c
    })

    # New instance button
    $ctx.BtnNew.Add_Click({
        New-PreviewWindow
    })

    # Scale button - cycles through 1x/2x/3x/5x, per-tab (per-window) independent
    $ctx.BtnScale.Add_Click({
        param($sender, $e)
        $c = Get-Ctx $sender
        # Snapshot base size on first use so 1x always maps to that reference
        if (-not $c.ContainsKey('BaseCaptured') -or -not $c.BaseCaptured) {
            # Use current size divided by current scale factor as the true 1x base
            $curFactor = $c.ScaleFactors[$c.ScaleIndex]
            $c.BaseWidth  = $c.Window.Width  / $curFactor
            $c.BaseHeight = $c.Window.Height / $curFactor
            $c.BaseCaptured = $true
        }
        $c.ScaleIndex = ($c.ScaleIndex + 1) % $c.ScaleFactors.Count
        $factor = $c.ScaleFactors[$c.ScaleIndex]
        $c.BtnScale.Content = "$($factor)x"
        $c.Window.Width  = $c.BaseWidth  * $factor
        $c.Window.Height = $c.BaseHeight * $factor
        # Scale the Automate panel content so its controls stay readable/fit at each scale.
        if ($c.AutoPanelScale) {
            $c.AutoPanelScale.ScaleX = $factor
            $c.AutoPanelScale.ScaleY = $factor
        }
        Update-Thumbnail $c
    })

    # Pin button
    $ctx.BtnPin.Add_Click({
        param($sender, $e)
        $c = Get-Ctx $sender
        $c.IsPinned = -not $c.IsPinned
        $c.Window.Topmost = $c.IsPinned
        if ($c.IsPinned) {
            $c.BtnPin.Foreground = [System.Windows.Media.Brushes]::Gold
            $c.BtnPin.ToolTip = "Unpin from Top (Ctrl+T)"
        } else {
            $c.BtnPin.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(204,204,204))
            $c.BtnPin.ToolTip = "Pin on Top (Ctrl+T)"
        }
    })

    # Close button
    $ctx.BtnClose.Add_Click({
        param($sender, $e)
        $c = Get-Ctx $sender
        $c.Window.Close()
    })

    # ---- Automate feature -----------------------------------------------
    $ctx.BtnAutomate.Add_Click({
        param($sender, $e)
        $c = Get-Ctx $sender
        if ($c.AutomatePanel.Visibility -eq [System.Windows.Visibility]::Visible) {
            $c.AutomatePanel.Visibility = [System.Windows.Visibility]::Collapsed
        } else {
            if (-not $script:MacroToolAvailable) {
                $c.AutoStatus.Text = "MacroTool.ps1 not found next to LivePreview.ps1."
            }
            $c.AutomatePanel.Visibility = [System.Windows.Visibility]::Visible
            if ($c.TargetTitle) { $c.AutoTarget.Text = "Target: $($c.TargetTitle)" }
            else { $c.AutoTarget.Text = "Target: (select a window first)" }
            if (-not $c.AutoBusy) {
                $c.AutoHint.Text = "Recording stops with $(Get-StopKeyName $script:RecordStopVk). Playback auto-stops when done or on safety limit."
            }
            Refresh-AutoMacros $c
        }
    })

    # ---- Macro dropdown: grow the window while open so the list isn't -----
    # clipped. Under WindowStyle=None + AllowsTransparency=True, ComboBox
    # popups are clipped to the parent window, so we temporarily enlarge it.
    $ctx.AutoMacro.Add_DropDownOpened({
        param($sender, $e)
        $c = Get-Ctx $sender
        try {
            $count = [Math]::Max(1, $c.AutoMacro.Items.Count)
            # ~22px per row (scaled), capped by MaxDropDownHeight (260) + chrome.
            $factor = 1.0
            if ($c.AutoPanelScale) { $factor = [double]$c.AutoPanelScale.ScaleY }
            $needed = [Math]::Min(260, ($count * 22)) * $factor + 40
            $c.AutoMacroSavedHeight = $c.Window.Height
            $c.AutoMacroSavedMinHeight = $c.Window.MinHeight
            $required = $c.Window.ActualHeight + $needed
            if ($required -gt $c.Window.Height) {
                # Relax MinHeight if it would block growth, then grow.
                if ($c.Window.MinHeight -gt $required) { $c.Window.MinHeight = $required }
                $c.Window.Height = $required
            }
        } catch {}
    })
    $ctx.AutoMacro.Add_DropDownClosed({
        param($sender, $e)
        $c = Get-Ctx $sender
        try {
            if ($c.ContainsKey('AutoMacroSavedHeight') -and $c.AutoMacroSavedHeight) {
                $c.Window.Height = $c.AutoMacroSavedHeight
                $c.AutoMacroSavedHeight = $null
            }
            if ($c.ContainsKey('AutoMacroSavedMinHeight') -and $c.AutoMacroSavedMinHeight) {
                $c.Window.MinHeight = $c.AutoMacroSavedMinHeight
                $c.AutoMacroSavedMinHeight = $null
            }
        } catch {}
    })

    # ---- Settings (gear) -------------------------------------------------
    # Populate the shortcut dropdown and select the persisted key.
    $ctx.SetStopKey.Items.Clear()
    foreach ($label in $script:StopKeyChoices.Keys) { [void]$ctx.SetStopKey.Items.Add($label) }
    $ctx.SetStopKey.SelectedItem = (Get-StopKeyName $script:RecordStopVk)
    if ($null -eq $ctx.SetStopKey.SelectedItem) { $ctx.SetStopKey.SelectedIndex = 0 }
    $ctx.SetAutoCollapse.IsChecked = $script:AutoCollapseOnPlay

    $ctx.BtnSettings.Add_Click({
        param($sender, $e)
        $c = Get-Ctx $sender
        # Ensure the Automate panel (which hosts the settings sub-panel) is open.
        if ($c.AutomatePanel.Visibility -ne [System.Windows.Visibility]::Visible) {
            $c.AutomatePanel.Visibility = [System.Windows.Visibility]::Visible
            if ($c.TargetTitle) { $c.AutoTarget.Text = "Target: $($c.TargetTitle)" }
            else { $c.AutoTarget.Text = "Target: (select a window first)" }
            Refresh-AutoMacros $c
        }
        if ($c.SettingsPanel.Visibility -eq [System.Windows.Visibility]::Visible) {
            $c.SettingsPanel.Visibility = [System.Windows.Visibility]::Collapsed
        } else {
            $c.SetStopKey.SelectedItem = (Get-StopKeyName $script:RecordStopVk)
            $c.SetAutoCollapse.IsChecked = $script:AutoCollapseOnPlay
            $c.SettingsPanel.Visibility = [System.Windows.Visibility]::Visible
        }
    })

    $ctx.BtnSettingsSave.Add_Click({
        param($sender, $e)
        $c = Get-Ctx $sender
        $label = "" + $c.SetStopKey.SelectedItem
        if ($script:StopKeyChoices.Contains($label)) {
            $script:RecordStopVk = [int]$script:StopKeyChoices[$label]
            $script:AutoCollapseOnPlay = [bool]$c.SetAutoCollapse.IsChecked
            Save-Settings
            $c.SetHint.Text = "Saved. Recording now stops with $label."
            # Refresh the Automate hint if idle so it reflects the new key.
            if (-not $c.AutoBusy) {
                $c.AutoHint.Text = "Recording stops with $label. Playback auto-stops when done or on safety limit."
            }
            # Save also closes the settings sub-panel.
            $c.SettingsPanel.Visibility = [System.Windows.Visibility]::Collapsed
        } else {
            $c.SetHint.Text = "Pick a key first."
        }
    })

    $ctx.BtnAutoRecord.Add_Click({
        param($sender, $e)
        $c = Get-Ctx $sender
        # Toggle: if a recording is running, this button stops it.
        if ($c.AutoBusy -eq 'record') { Stop-AutoJob $c; return }
        if ($c.AutoBusy) { $c.AutoStatus.Text = "A $($c.AutoBusy) job is already running."; return }
        $name = ("" + $c.AutoRecName.Text).Trim()
        if (-not $name) { $c.AutoStatus.Text = "Enter a macro name first."; return }
        Start-AutoJob $c ("record -Name `"$name`"") "Recording" 'record'
    })

    $ctx.BtnAutoPlay.Add_Click({
        param($sender, $e)
        $c = Get-Ctx $sender
        # Toggle: if a playback is running, this button stops it.
        if ($c.AutoBusy -eq 'play') { Stop-AutoJob $c; return }
        if ($c.AutoBusy) { $c.AutoStatus.Text = "A $($c.AutoBusy) job is already running."; return }
        $macro = $c.AutoMacro.SelectedItem
        if (-not $macro) { $c.AutoStatus.Text = "Select a macro to play."; return }
        if ($c.TargetHandle -eq [IntPtr]::Zero) { $c.AutoStatus.Text = "Select a window to preview/automate first."; return }
        $delay    = ("" + $c.AutoDelay.Text).Trim();    if (-not $delay) { $delay = "0" }
        $repeat   = ("" + $c.AutoRepeat.Text).Trim();   if (-not $repeat) { $repeat = "1" }
        $interval = ("" + $c.AutoInterval.Text).Trim(); if (-not $interval) { $interval = "0" }
        $speed    = ("" + $c.AutoSpeed.Text).Trim();    if (-not $speed) { $speed = "1" }
        $modeIdx  = $c.AutoMode.SelectedIndex
        $modeFlag = ""
        if ($modeIdx -eq 0) { $modeFlag = " -FlashRestore" }
        elseif ($modeIdx -eq 2) { $modeFlag = " -Background" }
        $hwnd = [int64]$c.TargetHandle
        $args = "play -Name `"$macro`" -TargetHwnd $hwnd -Delay $delay -Repeat $repeat -Interval $interval -Speed $speed$modeFlag"
        Start-AutoJob $c $args "Playback" 'play'
        # Optionally collapse the macro panel after starting playback (opt-in setting).
        if ($script:AutoCollapseOnPlay) {
            $c.AutomatePanel.Visibility = [System.Windows.Visibility]::Collapsed
        }
    })

    $ctx.BtnAutoRefresh.Add_Click({
        param($sender, $e)
        $c = Get-Ctx $sender
        Refresh-AutoMacros $c
        $c.AutoStatus.Text = "Macro list refreshed."
    })

    $ctx.BtnAutoFolder.Add_Click({
        param($sender, $e)
        $c = Get-Ctx $sender
        $dir = Join-Path $PSScriptRoot 'macros'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # Quote the path so it survives spaces in the install directory.
        Start-Process explorer.exe -ArgumentList "`"$dir`""
    })
    # ---------------------------------------------------------------------

    # Keyboard shortcuts
    $wnd.Add_KeyDown({
        param($sender, $e)
        $c = $sender.Tag
        if ($e.Key -eq [System.Windows.Input.Key]::W -and
            [System.Windows.Input.Keyboard]::Modifiers -eq [System.Windows.Input.ModifierKeys]::Control) {
            Show-WindowPicker $c
            $e.Handled = $true
        }
        elseif ($e.Key -eq [System.Windows.Input.Key]::N -and
                [System.Windows.Input.Keyboard]::Modifiers -eq [System.Windows.Input.ModifierKeys]::Control) {
            New-PreviewWindow
            $e.Handled = $true
        }
        elseif ($e.Key -eq [System.Windows.Input.Key]::S -and
                [System.Windows.Input.Keyboard]::Modifiers -eq [System.Windows.Input.ModifierKeys]::Control) {
            $c.BtnScale.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            $e.Handled = $true
        }
        elseif ($e.Key -eq [System.Windows.Input.Key]::T -and
                [System.Windows.Input.Keyboard]::Modifiers -eq [System.Windows.Input.ModifierKeys]::Control) {
            $c.BtnPin.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            $e.Handled = $true
        }
        elseif ($e.Key -eq [System.Windows.Input.Key]::Escape) {
            $c.Window.Close()
        }
    })

    # Size changed - update thumbnail
    $wnd.Add_SizeChanged({
        param($sender, $e)
        Update-Thumbnail $sender.Tag
    })

    # Title bar auto-hide
    $wnd.Add_MouseEnter({
        param($sender, $e)
        Show-TitleBar $sender.Tag
    })
    $wnd.Add_MouseLeave({
        param($sender, $e)
        Hide-TitleBar $sender.Tag
    })
    $wnd.Add_Deactivated({
        param($sender, $e)
        Hide-TitleBar $sender.Tag
    })
    $wnd.Add_Activated({
        param($sender, $e)
        Show-TitleBar $sender.Tag
    })

    # Window closed - cleanup
    $wnd.Add_Closed({
        param($sender, $e)
        $c = $sender.Tag
        if ($null -ne $c.Timer) { $c.Timer.Stop() }
        Unregister-Thumbnail $c
        $script:openWindowCount--
        if ($script:openWindowCount -le 0) {
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
        }
    })

    # Show window and start timer
    $script:openWindowCount++
    $wnd.Show()

    # Timer for continuous thumbnail updates
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(100)
    $timer.Tag = $ctx
    $timer.Add_Tick({
        param($sender, $e)
        Update-Thumbnail $sender.Tag
    })
    $timer.Start()
    $ctx.Timer = $timer
}

# ============================================================
# Launch
# ============================================================
New-PreviewWindow
[System.Windows.Threading.Dispatcher]::Run()
