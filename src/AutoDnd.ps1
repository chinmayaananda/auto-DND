<#
.SYNOPSIS
    Watches for screen sharing and suppresses Windows notifications while it lasts.

.DESCRIPTION
    Polls for an active screen capture (Slack, Teams, Google Meet in Chrome/Edge, or
    anything else you list in config.json). When one starts, notification banners are
    switched off; when it stops, they are switched back on -- but only if this watcher
    was the thing that switched them off in the first place.

.PARAMETER ConfigPath
    Path to config.json. Defaults to config.json next to the repository root, falling
    back to config.example.json.

.PARAMETER Once
    Evaluate detection a single time, print the result, and exit. Useful for testing.

.PARAMETER NoAct
    Detect and log, but never touch notification settings. Useful for tuning WatchedApps.

.EXAMPLE
    .\src\AutoDnd.ps1 -Once -NoAct
    Print what the watcher can currently see without changing anything.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Once,
    [switch]$NoAct
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'AutoDnd.Detection.ps1')
. (Join-Path $PSScriptRoot 'AutoDnd.Dnd.ps1')

# The watcher functions below need these switches. Promote them into script scope
# explicitly rather than relying on PowerShell's dynamic scoping to find the param
# block from inside a function: that works, but it is invisible to a reader and to
# static analysis, and it breaks the moment a function is moved into a module.
$script:NoAct       = [bool]$NoAct
$script:Interactive = [bool]$Once

$script:DataDir   = Join-Path $env:LOCALAPPDATA 'AutoDnd'
$script:LogPath   = Join-Path $script:DataDir 'autodnd.log'
$script:StatePath = Join-Path $script:DataDir 'state.json'
$script:LogLevels = @{ DEBUG = 0; INFO = 1; WARN = 2; ERROR = 3 }
$script:MinLevel  = 1
$script:MaxLogKB  = 512

if (-not (Test-Path -LiteralPath $script:DataDir)) {
    New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
}

function Write-AutoDndLog {
    param(
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Message
    )

    if ($script:LogLevels[$Level] -lt $script:MinLevel) { return }
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    try {
        $existing = Get-Item -LiteralPath $script:LogPath -ErrorAction SilentlyContinue
        if ($existing -and $existing.Length -gt ($script:MaxLogKB * 1KB)) {
            Move-Item -LiteralPath $script:LogPath -Destination "$script:LogPath.1" -Force
        }
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    }
    catch {
        # Logging must never take the watcher down.
        $null = $_
    }

    Write-Verbose $line
    if ($script:Interactive -or $VerbosePreference -eq 'Continue') { Write-Host $line }
}

$script:Logger = { param($lvl, $msg) Write-AutoDndLog -Level $lvl -Message $msg }

function Get-Config {
    param([string]$Path)

    $candidates = @()
    if ($Path) { $candidates += $Path }
    $candidates += (Join-Path $script:Root 'config.json')
    $candidates += (Join-Path $script:Root 'config.example.json')

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            Write-AutoDndLog -Level DEBUG -Message "Using config: $candidate"
            return (Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json)
        }
    }
    throw "No configuration file found. Looked in: $($candidates -join ', ')"
}

function Get-State {
    if (-not (Test-Path -LiteralPath $script:StatePath)) {
        return [pscustomobject]@{ SuppressedByUs = $false; SuppressedSince = $null }
    }
    try {
        return (Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json)
    }
    catch {
        Write-AutoDndLog -Level WARN -Message "State file unreadable, resetting: $($_.Exception.Message)"
        return [pscustomobject]@{ SuppressedByUs = $false; SuppressedSince = $null }
    }
}

function Set-State {
    param([Parameter(Mandatory)][bool]$SuppressedByUs)

    $state = [pscustomobject]@{
        SuppressedByUs  = $SuppressedByUs
        SuppressedSince = if ($SuppressedByUs) { (Get-Date).ToString('o') } else { $null }
    }
    $state | ConvertTo-Json | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
}

function Restore-StrandedSuppression {
    <#
    .SYNOPSIS
        Undo a suppression left behind by a crash, reboot or forced kill.
    .DESCRIPTION
        Without this, a watcher that dies mid-meeting leaves notifications off forever
        and the user has no idea why. Startup always assumes any suppression we recorded
        is stale, because a fresh start means no share is currently being tracked.
    #>
    $state = Get-State
    if ($state.SuppressedByUs) {
        Write-AutoDndLog -Level WARN -Message 'Found a suppression left over from a previous run; restoring notifications.'
        if (-not $script:NoAct) { Set-NotificationsEnabled -Enabled $true }
        Set-State -SuppressedByUs $false
    }
}

function Format-DetectionList {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Detections)
    if ($Detections.Count -eq 0) { return '(none)' }
    return (($Detections | ForEach-Object { "$($_.Name) [$($_.Source)]" }) -join ', ')
}

function Start-Suppression {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Detections, [Parameter(Mandatory)]$Config)

    if (-not (Get-NotificationsEnabled)) {
        Write-AutoDndLog -Level INFO -Message 'Screen share started, but notifications were already off. Leaving your setting alone.'
        Set-State -SuppressedByUs $false
        return $false
    }

    Write-AutoDndLog -Level INFO -Message "Screen share started: $(Format-DetectionList -Detections $Detections). Suppressing notifications."
    if (-not $script:NoAct) {
        Set-NotificationsEnabled -Enabled $false
        Set-State -SuppressedByUs $true
        Invoke-ConfiguredHook -Command $Config.OnShareStart -Logger $script:Logger
    }
    return $true
}

function Stop-Suppression {
    param([Parameter(Mandatory)]$Config)

    $state = Get-State
    if (-not $state.SuppressedByUs) {
        Write-AutoDndLog -Level INFO -Message 'Screen share ended. Notifications were not suppressed by us, so nothing to restore.'
        return
    }

    Write-AutoDndLog -Level INFO -Message 'Screen share ended. Restoring notifications.'
    if (-not $script:NoAct) {
        Set-NotificationsEnabled -Enabled $true
        Set-State -SuppressedByUs $false
        Invoke-ConfiguredHook -Command $Config.OnShareStop -Logger $script:Logger
    }
}

function Invoke-Watcher {
    param([Parameter(Mandatory)]$Config)

    $sharing = $false
    $pendingState = $null
    $pendingSince = $null

    Write-AutoDndLog -Level INFO -Message "auto-DND watcher started (poll $($Config.PollSeconds)s, NoAct=$($script:NoAct))."

    while ($true) {
        try {
            $detections = @(Get-ActiveScreenShare -Config $Config)
            $observed = $detections.Count -gt 0

            if ($observed -ne $sharing) {
                # Debounce: a click-through between "share window" and "share screen" can
                # briefly drop the signal, and we do not want to flap the setting.
                if ($pendingState -ne $observed) {
                    $pendingState = $observed
                    $pendingSince = Get-Date
                    Write-AutoDndLog -Level DEBUG -Message "Pending transition to sharing=$observed."
                }
                else {
                    $needed = if ($observed) { $Config.StartDebounceSeconds } else { $Config.StopDebounceSeconds }
                    if (((Get-Date) - $pendingSince).TotalSeconds -ge $needed) {
                        if ($observed) {
                            Start-Suppression -Detections $detections -Config $Config | Out-Null
                        }
                        else {
                            Stop-Suppression -Config $Config
                        }
                        $sharing = $observed
                        $pendingState = $null
                        $pendingSince = $null
                    }
                }
            }
            elseif ($null -ne $pendingState) {
                $pendingState = $null
                $pendingSince = $null
            }
        }
        catch {
            Write-AutoDndLog -Level ERROR -Message "Poll failed: $($_.Exception.Message)"
        }

        Start-Sleep -Seconds $Config.PollSeconds
    }
}

# ---------------------------------------------------------------------------

$config = Get-Config -Path $ConfigPath
if ($config.PSObject.Properties.Name -contains 'LogLevel') { $script:MinLevel = $script:LogLevels[$config.LogLevel] }
if ($config.PSObject.Properties.Name -contains 'MaxLogSizeKB') { $script:MaxLogKB = [int]$config.MaxLogSizeKB }

if ($Once) {
    $detections = @(Get-ActiveScreenShare -Config $config)
    Write-AutoDndLog -Level INFO -Message "Detected: $(Format-DetectionList -Detections $detections)"
    Write-AutoDndLog -Level INFO -Message "Notifications currently enabled: $(Get-NotificationsEnabled)"
    return
}

Restore-StrandedSuppression

try {
    Invoke-Watcher -Config $config
}
finally {
    # Ctrl-C, logoff or task-stop must not leave the machine silent.
    Stop-Suppression -Config $config
}
