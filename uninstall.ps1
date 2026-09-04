<#
.SYNOPSIS
    Removes the auto-DND scheduled task and makes sure notifications are back on.

.PARAMETER TaskName
    Name of the scheduled task to remove. Default 'auto-DND'.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TaskName = 'auto-DND'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'src\AutoDnd.Dnd.ps1')

if ($PSCmdlet.ShouldProcess($TaskName, 'unregister scheduled task')) {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
    }
    else {
        Write-Host "No scheduled task named '$TaskName' was registered." -ForegroundColor Yellow
    }

    # Never leave the machine silent because someone uninstalled mid-meeting.
    Set-NotificationsEnabled -Enabled $true
    $state = Join-Path $env:LOCALAPPDATA 'AutoDnd\state.json'
    if (Test-Path -LiteralPath $state) { Remove-Item -LiteralPath $state -Force }
    Write-Host 'Notifications re-enabled.' -ForegroundColor Green
}
