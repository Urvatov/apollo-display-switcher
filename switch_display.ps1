#requires -Version 5.1

<#
.SYNOPSIS
    Moves an application window to the Apollo virtual display.

.DESCRIPTION
    switch_display.ps1 is a small Windows PowerShell utility designed
    specifically for Apollo streaming setups.

    By default, the script assumes that Apollo's virtual display is the
    display with the highest Windows DISPLAY<N> number.

    Example:
        DISPLAY1
        DISPLAY2
        DISPLAY31    <- Apollo

    The monitor can also be selected explicitly using -MonitorIndex.

    The script can:
      - automatically select the Apollo display;
      - move an application window to the Apollo display;
      - wait for an application window to appear;
      - select a process by name or PID;
      - optionally filter by window title;
      - list monitors;
      - list processes with visible windows;
      - test operations with -WhatIf.

.EXAMPLE
    .\switch_display.ps1 -ListMonitors

.EXAMPLE
    .\switch_display.ps1 -ListProcesses

.EXAMPLE
    .\switch_display.ps1 -ProcessName factorio.exe

.EXAMPLE
    .\switch_display.ps1 -ProcessName factorio.exe -MonitorIndex 2

.EXAMPLE
    .\switch_display.ps1 -ProcessId 12345

.EXAMPLE
    .\switch_display.ps1 -ProcessName factorio.exe -WindowTitle "*Factorio*"

.EXAMPLE
    .\switch_display.ps1 -ProcessName factorio.exe -WaitSeconds 120

.EXAMPLE
    .\switch_display.ps1 -ProcessName factorio.exe -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(
        Position = 0,
        HelpMessage = "Process name, with or without .exe"
    )]
    [string]$ProcessName,

    [Parameter(
        HelpMessage = "Exact process ID"
    )]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$ProcessId,

    [Parameter(
        HelpMessage = "Optional window title filter. Supports PowerShell wildcards."
    )]
    [string]$WindowTitle,

    [Parameter(
        HelpMessage = "Monitor index shown by -ListMonitors"
    )]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$MonitorIndex = -1,

    [Parameter(
        HelpMessage = "Seconds to wait for the process window"
    )]
    [ValidateRange(0, 3600)]
    [int]$WaitSeconds = 60,

    [Parameter(
        HelpMessage = "Milliseconds between process/window checks"
    )]
    [ValidateRange(50, 10000)]
    [int]$PollMilliseconds = 350,

    [Parameter(
        HelpMessage = "List all detected monitors"
    )]
    [switch]$ListMonitors,

    [Parameter(
        HelpMessage = "List processes that have visible windows"
    )]
    [switch]$ListProcesses
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# Dependencies
# ============================================================================

try {
    Add-Type -AssemblyName System.Windows.Forms
}
catch {
    throw (
        "System.Windows.Forms could not be loaded. " +
        "This script requires Windows."
    )
}

# ============================================================================
# Win32 API
# ============================================================================

if (-not ('SwitchDisplay.Win32' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;

namespace SwitchDisplay
{
    public static class Win32
    {
        public const int SW_RESTORE = 9;

        [DllImport(
            "user32.dll",
            SetLastError = true
        )]
        public static extern bool MoveWindow(
            IntPtr hWnd,
            int X,
            int Y,
            int nWidth,
            int nHeight,
            bool bRepaint
        );

        [DllImport(
            "user32.dll",
            SetLastError = true
        )]
        public static extern bool ShowWindow(
            IntPtr hWnd,
            int nCmdShow
        );

        [DllImport(
            "user32.dll",
            SetLastError = true
        )]
        public static extern bool SetForegroundWindow(
            IntPtr hWnd
        );

        [DllImport(
            "user32.dll",
            SetLastError = true
        )]
        public static extern bool IsWindow(
            IntPtr hWnd
        );
    }
}
'@
}

# ============================================================================
# Process helpers
# ============================================================================

function Get-CleanProcessName {
    <#
    .SYNOPSIS
        Normalizes a process name by removing a trailing .exe.
    #>

    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $clean = $Name.Trim()

    if ([string]::IsNullOrWhiteSpace($clean)) {
        return $null
    }

    if ($clean.EndsWith(
        '.exe',
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        $clean = $clean.Substring(
            0,
            $clean.Length - 4
        )
    }

    return $clean
}

# ============================================================================
# Monitor helpers
# ============================================================================

function Get-MonitorInventory {
    <#
    .SYNOPSIS
        Returns all Windows monitors with their display number and geometry.
    #>

    $screens = @(
        [System.Windows.Forms.Screen]::AllScreens
    )

    $result = @()
    $index = 0

    foreach ($screen in $screens) {

        $displayNumber = $null

        if ($screen.DeviceName -match '^\\\\\.\\DISPLAY(\d+)$') {
            $displayNumber = [int]$Matches[1]
        }

        $result += [PSCustomObject]@{
            Index         = $index
            DeviceName    = $screen.DeviceName
            DisplayNumber = $displayNumber
            Primary       = $screen.Primary
            Width         = $screen.Bounds.Width
            Height        = $screen.Bounds.Height
            X             = $screen.Bounds.X
            Y             = $screen.Bounds.Y
            Screen        = $screen
        }

        $index++
    }

    return $result
}

function Show-Monitors {
    <#
    .SYNOPSIS
        Displays all detected monitors.
    #>

    $monitors = @(Get-MonitorInventory)

    Write-Host ''
    Write-Host '=== Monitors ===' -ForegroundColor Cyan
    Write-Host ''

    if ($monitors.Count -eq 0) {
        Write-Host 'No monitors detected.' -ForegroundColor Yellow
        return
    }

    foreach ($monitor in $monitors) {

        $primaryText = ''

        if ($monitor.Primary) {
            $primaryText = '  <-- PRIMARY'
        }

        Write-Host (
            '[{0}] {1}{2}' -f
            $monitor.Index,
            $monitor.DeviceName,
            $primaryText
        )

        Write-Host (
            '     DISPLAY number : {0}' -f
            $monitor.DisplayNumber
        )

        Write-Host (
            '     Resolution     : {0}x{1}' -f
            $monitor.Width,
            $monitor.Height
        )

        Write-Host (
            '     Position       : ({0}, {1})' -f
            $monitor.X,
            $monitor.Y
        )

        Write-Host ''
    }
}

function Find-ApolloMonitor {
    <#
    .SYNOPSIS
        Selects Apollo's virtual display.

    .DESCRIPTION
        Apollo is expected to create a Windows display with the highest
        DISPLAY<N> number.

        Example:

            DISPLAY1
            DISPLAY2
            DISPLAY31

        DISPLAY31 is selected.

        This is intentionally specific to Apollo rather than being presented
        as a generic virtual-monitor detection method.
    #>

    param(
        [Parameter(Mandatory)]
        [object[]]$Monitors
    )

    $candidates = @(
        $Monitors |
            Where-Object {
                $null -ne $_.DisplayNumber
            } |
            Sort-Object DisplayNumber -Descending
    )

    if ($candidates.Count -eq 0) {
        throw (
            "Could not determine the Windows DISPLAY number " +
            "for any monitor."
        )
    }

    $apollo = $candidates[0]

    Write-Host (
        "Automatically selected Apollo monitor: {0} (DISPLAY{1})" -f
        $apollo.DeviceName,
        $apollo.DisplayNumber
    ) -ForegroundColor Cyan

    return $apollo
}

function Select-TargetMonitor {
    <#
    .SYNOPSIS
        Selects the target monitor.

    .DESCRIPTION
        If -MonitorIndex is supplied, it always takes priority.
        Otherwise Apollo's monitor is detected automatically.
    #>

    param(
        [Parameter(Mandatory)]
        [object[]]$Monitors,

        [int]$Index = -1
    )

    if ($Index -ge 0) {

        $target = @(
            $Monitors |
                Where-Object {
                    $_.Index -eq $Index
                }
        )

        if ($target.Count -eq 0) {
            throw (
                "Monitor index [$Index] does not exist. " +
                "Run -ListMonitors to see available monitors."
            )
        }

        Write-Host (
            "Using monitor by index [{0}]." -f $Index
        ) -ForegroundColor Cyan

        return $target[0]
    }

    return Find-ApolloMonitor -Monitors $Monitors
}

# ============================================================================
# Window helpers
# ============================================================================

function Find-WindowProcess {
    <#
    .SYNOPSIS
        Finds a process that owns a visible main window.
    #>

    param(
        [string]$CleanName,

        [int]$TargetProcessId,

        [string]$TitleFilter
    )

    $processes = @(
        Get-Process -ErrorAction SilentlyContinue
    )

    if ($TargetProcessId -gt 0) {

        $processes = @(
            $processes |
                Where-Object {
                    $_.Id -eq $TargetProcessId
                }
        )
    }
    else {

        $processes = @(
            $processes |
                Where-Object {
                    $_.ProcessName.Equals(
                        $CleanName,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                }
        )
    }

    $processes = @(
        $processes |
            Where-Object {
                $_.MainWindowHandle -ne [IntPtr]::Zero
            }
    )

    if (-not [string]::IsNullOrWhiteSpace($TitleFilter)) {

        $processes = @(
            $processes |
                Where-Object {
                    $_.MainWindowTitle -like $TitleFilter
                }
        )
    }

    if ($processes.Count -eq 0) {
        return $null
    }

    return $processes[0]
}

function Find-Window {
    <#
    .SYNOPSIS
        Waits for a process to expose a main window.
    #>

    param(
        [string]$CleanName,

        [int]$TargetProcessId,

        [string]$TitleFilter,

        [int]$TimeoutSeconds,

        [int]$PollMs
    )

    $deadline = (
        Get-Date
    ).AddSeconds(
        $TimeoutSeconds
    )

    Write-Host (
        "Waiting for application window " +
        "(timeout: {0}s)..." -f
        $TimeoutSeconds
    ) -ForegroundColor Yellow

    do {

        $process = Find-WindowProcess `
            -CleanName $CleanName `
            -TargetProcessId $TargetProcessId `
            -TitleFilter $TitleFilter

        if ($null -ne $process) {
            return $process
        }

        if ((Get-Date) -ge $deadline) {
            break
        }

        Start-Sleep -Milliseconds $PollMs

    } while ($true)

    return $null
}

function Test-Window {
    param(
        [Parameter(Mandatory)]
        [IntPtr]$Handle
    )

    return [SwitchDisplay.Win32]::IsWindow($Handle)
}

function Restore-Window {
    <#
    .SYNOPSIS
        Restores a minimized/maximized window before moving it.
    #>

    param(
        [Parameter(Mandatory)]
        [IntPtr]$Handle
    )

    if (-not (Test-Window -Handle $Handle)) {
        throw 'The target window no longer exists.'
    }

    [SwitchDisplay.Win32]::ShowWindow(
        $Handle,
        [SwitchDisplay.Win32]::SW_RESTORE
    ) | Out-Null

    Start-Sleep -Milliseconds 100
}

function Move-WindowToMonitor {
    <#
    .SYNOPSIS
        Moves and resizes a window to the target monitor bounds.
    #>

    param(
        [Parameter(Mandatory)]
        [IntPtr]$Handle,

        [Parameter(Mandatory)]
        [object]$Monitor
    )

    if (-not (Test-Window -Handle $Handle)) {
        throw 'The target window disappeared before it could be moved.'
    }

    $bounds = $Monitor.Screen.Bounds

    $success = [SwitchDisplay.Win32]::MoveWindow(
        $Handle,
        $bounds.X,
        $bounds.Y,
        $bounds.Width,
        $bounds.Height,
        $true
    )

    if (-not $success) {

        $errorCode = (
            [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        )

        throw (
            "MoveWindow failed. Win32 error code: {0}" -f
            $errorCode
        )
    }
}

function Activate-Window {
    <#
    .SYNOPSIS
        Attempts to bring the moved window to the foreground.
    #>

    param(
        [Parameter(Mandatory)]
        [IntPtr]$Handle
    )

    if (-not (Test-Window -Handle $Handle)) {
        throw 'The target window disappeared before it could be activated.'
    }

    $success = [SwitchDisplay.Win32]::SetForegroundWindow(
        $Handle
    )

    if (-not $success) {

        $errorCode = (
            [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        )

        Write-Warning (
            "SetForegroundWindow failed. Win32 error code: {0}. " +
            "The window was moved, but Windows did not allow it " +
            "to become the foreground window." -f
            $errorCode
        )
    }
}

# ============================================================================
# Usage
# ============================================================================

function Show-Usage {

    @'
Usage:

  List monitors:
    .\switch_display.ps1 -ListMonitors

  List processes with visible windows:
    .\switch_display.ps1 -ListProcesses

  Move process to automatically detected Apollo display:
    .\switch_display.ps1 -ProcessName factorio.exe

  Move process to a specific monitor:
    .\switch_display.ps1 -ProcessName factorio.exe -MonitorIndex 2

  Select a specific process instance:
    .\switch_display.ps1 -ProcessId 12345

  Filter by window title:
    .\switch_display.ps1 -ProcessName factorio.exe -WindowTitle "*Factorio*"

  Wait longer for the application:
    .\switch_display.ps1 -ProcessName factorio.exe -WaitSeconds 120

  Test without moving:
    .\switch_display.ps1 -ProcessName factorio.exe -WhatIf

Apollo detection:

  By default, the script selects the monitor with the highest
  Windows DISPLAY<N> number.

  Example:
    DISPLAY1
    DISPLAY2
    DISPLAY31  <- selected as Apollo

If automatic detection does not match your setup, use -MonitorIndex.
'@
}

# ============================================================================
# Main
# ============================================================================

try {

    # ------------------------------------------------------------------------
    # Diagnostic commands
    # ------------------------------------------------------------------------

    if ($ListMonitors) {
        Show-Monitors
        exit 0
    }

    if ($ListProcesses) {
        Show-WindowedProcesses
        exit 0
    }

    # ------------------------------------------------------------------------
    # Validate process selection
    # ------------------------------------------------------------------------

    if (
        $ProcessId -gt 0 -and
        -not [string]::IsNullOrWhiteSpace($ProcessName)
    ) {
        throw (
            'Use either -ProcessName or -ProcessId, not both.'
        )
    }

    if (
        $ProcessId -le 0 -and
        [string]::IsNullOrWhiteSpace($ProcessName)
    ) {
        Write-Host (Show-Usage)
        exit 1
    }

    $cleanName = $null

    if (-not [string]::IsNullOrWhiteSpace($ProcessName)) {

        $cleanName = Get-CleanProcessName `
            -Name $ProcessName

        if ([string]::IsNullOrWhiteSpace($cleanName)) {
            throw 'Invalid process name.'
        }
    }

    # ------------------------------------------------------------------------
    # Header
    # ------------------------------------------------------------------------

    Write-Host ''
    Write-Host '=== Apollo Screen Switcher ===' -ForegroundColor Cyan
    Write-Host ''

    # ------------------------------------------------------------------------
    # Monitor selection
    # ------------------------------------------------------------------------

    $monitors = @(
        Get-MonitorInventory
    )

    if ($monitors.Count -eq 0) {
        throw 'No monitors were detected.'
    }

    $targetMonitor = Select-TargetMonitor `
        -Monitors $monitors `
        -Index $MonitorIndex

    Write-Host ''
    Write-Host 'Target monitor:' -ForegroundColor Cyan
    Write-Host "  Index      : $($targetMonitor.Index)"
    Write-Host "  Device     : $($targetMonitor.DeviceName)"
    Write-Host "  DISPLAY    : $($targetMonitor.DisplayNumber)"
    Write-Host "  Resolution : $($targetMonitor.Width)x$($targetMonitor.Height)"
    Write-Host "  Position   : ($($targetMonitor.X), $($targetMonitor.Y))"
    Write-Host ''

    # ------------------------------------------------------------------------
    # Find application window
    # ------------------------------------------------------------------------

    if ($ProcessId -gt 0) {

        Write-Host (
            "Looking for window belonging to PID {0}..." -f
            $ProcessId
        ) -ForegroundColor Yellow
    }
    else {

        Write-Host (
            "Looking for process '{0}'..." -f
            $cleanName
        ) -ForegroundColor Yellow
    }

    if (-not [string]::IsNullOrWhiteSpace($WindowTitle)) {

        Write-Host (
            "Window title filter: {0}" -f
            $WindowTitle
        ) -ForegroundColor DarkGray
    }

    $process = Find-Window `
        -CleanName $cleanName `
        -TargetProcessId $ProcessId `
        -TitleFilter $WindowTitle `
        -TimeoutSeconds $WaitSeconds `
        -PollMs $PollMilliseconds

    if ($null -eq $process) {

        if ($ProcessId -gt 0) {
            throw (
                "No visible window was found for PID $ProcessId " +
                "within $WaitSeconds seconds."
            )
        }

        throw (
            "No visible window was found for process '$cleanName' " +
            "within $WaitSeconds seconds."
        )
    }

    $hwnd = $process.MainWindowHandle

    if (-not (Test-Window -Handle $hwnd)) {
        throw (
            'The process was found, but its window handle is no longer valid.'
        )
    }

    # ------------------------------------------------------------------------
    # Show information
    # ------------------------------------------------------------------------

    Write-Host ''
    Write-Host 'Found window:' -ForegroundColor Green
    Write-Host "  Process : $($process.ProcessName)"
    Write-Host "  PID     : $($process.Id)"
    Write-Host "  Title   : $($process.MainWindowTitle)"
    Write-Host "  HWND    : $hwnd"
    Write-Host ''

    # ------------------------------------------------------------------------
    # Move
    # ------------------------------------------------------------------------

    $operation = (
        "Move '$($process.MainWindowTitle)' " +
        "(PID $($process.Id)) to " +
        "$($targetMonitor.DeviceName)"
    )

    if ($PSCmdlet.ShouldProcess($operation)) {

        Restore-Window -Handle $hwnd

        Move-WindowToMonitor `
            -Handle $hwnd `
            -Monitor $targetMonitor

        Activate-Window -Handle $hwnd

        Write-Host ''
        Write-Host 'Done! Window moved successfully.' -ForegroundColor Green
    }
    else {

        Write-Host ''
        Write-Host 'WhatIf: no changes were made.' -ForegroundColor Yellow
    }

    exit 0
}
catch {

    Write-Error $_.Exception.Message
    exit 1
}
