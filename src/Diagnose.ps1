<#
.SYNOPSIS
    Shows what auto-DND can see, so you can tune config.json for your own apps.

.DESCRIPTION
    Run this, then start a screen share in Slack / Teams / Google Meet and watch which
    rows flip to InUse = True. Whatever appears there is what belongs in WatchedApps.
    If nothing appears while you are genuinely sharing, your app is not using the
    Windows Graphics Capture API and you need the window-title fallback instead --
    the second section lists candidate window titles.

.PARAMETER Seconds
    How long to keep sampling. Default 60.

.PARAMETER IntervalSeconds
    Seconds between samples. Default 2.

.EXAMPLE
    .\src\Diagnose.ps1 -Seconds 90
#>

[CmdletBinding()]
param(
    [int]$Seconds = 60,
    [int]$IntervalSeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'AutoDnd.Detection.ps1')
. (Join-Path $PSScriptRoot 'AutoDnd.Dnd.ps1')

Write-Host ''
Write-Host 'auto-DND diagnostics' -ForegroundColor Cyan
Write-Host '--------------------'
Write-Host "Notifications currently enabled : $(Get-NotificationsEnabled)"
Write-Host "Sampling for $Seconds seconds. Start and stop a screen share now."
Write-Host ''

$deadline = (Get-Date).AddSeconds($Seconds)
$previous = @{}

while ((Get-Date) -lt $deadline) {
    $current = @{}
    foreach ($entry in (Get-ConsentStoreCaptureState)) {
        $current[$entry.Identity] = $entry.InUse
        $wasInUse = $false
        if ($previous.ContainsKey($entry.Identity)) { $wasInUse = $previous[$entry.Identity] }

        if ($entry.InUse -ne $wasInUse) {
            $verb = if ($entry.InUse) { 'STARTED capturing' } else { 'stopped capturing' }
            $colour = if ($entry.InUse) { 'Green' } else { 'DarkGray' }
            Write-Host ('{0}  {1,-17} {2}' -f (Get-Date -Format 'HH:mm:ss'), $verb, $entry.Identity) -ForegroundColor $colour
        }
    }
    $previous = $current
    Start-Sleep -Seconds $IntervalSeconds
}

Write-Host ''
Write-Host 'Final ConsentStore snapshot' -ForegroundColor Cyan
Get-ConsentStoreCaptureState |
    Sort-Object -Property InUse -Descending |
    Format-Table -AutoSize -Property InUse, Name, Kind, Root, Identity

Write-Host 'Visible window titles that mention sharing or presenting' -ForegroundColor Cyan
$hits = [AutoDnd.NativeWindows]::GetVisibleWindows() |
    Where-Object { $_[0] -match 'shar|present|meet|teams|slack|zoom' }
if ($hits) {
    $hits | ForEach-Object { Write-Host ('  pid {0,-7} {1}' -f $_[1], $_[0]) }
}
else {
    Write-Host '  (none)'
}
Write-Host ''
