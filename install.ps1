<#
.SYNOPSIS
    Registers auto-DND to start automatically when you log in.

.DESCRIPTION
    Creates a Scheduled Task that launches the watcher at logon, running as you (it has
    to be you: the notification settings it changes live in your own HKCU registry hive).
    Safe to re-run; it replaces any existing task with the same name.

.PARAMETER TaskName
    Name of the scheduled task. Default 'auto-DND'.

.PARAMETER Headless
    Launch through 'conhost.exe --headless', which avoids the brief console flash at
    logon on Windows 11. Falls back automatically if conhost does not accept it.

.EXAMPLE
    .\install.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TaskName = 'auto-DND',
    [switch]$Headless
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$watcher = Join-Path $root 'src\AutoDnd.ps1'
$config = Join-Path $root 'config.json'
$example = Join-Path $root 'config.example.json'

if (-not (Test-Path -LiteralPath $watcher)) {
    throw "Cannot find $watcher. Run install.ps1 from inside the cloned repository folder."
}

if (-not (Test-Path -LiteralPath $config)) {
    Copy-Item -LiteralPath $example -Destination $config
    Write-Host "Created config.json from the example. Edit it later if your apps are not detected." -ForegroundColor Yellow
}

$psArgs = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcher`""

if ($Headless) {
    $execute = "$env:SystemRoot\System32\conhost.exe"
    $arguments = "--headless powershell.exe $psArgs"
}
else {
    $execute = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = $psArgs
}

$action = New-ScheduledTaskAction -Execute $execute -Argument $arguments -WorkingDirectory $root
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

# The watcher is a long-lived poll loop, so every "tidy up idle tasks" default has to go.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -DontStopOnIdleEnd `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable `
    -Hidden

if ($PSCmdlet.ShouldProcess($TaskName, 'register scheduled task')) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description 'Suppresses Windows notifications while you are sharing your screen.' | Out-Null

    Start-ScheduledTask -TaskName $TaskName
    Write-Host ''
    Write-Host "Installed and started '$TaskName'." -ForegroundColor Green
    Write-Host "Log file: $env:LOCALAPPDATA\AutoDnd\autodnd.log"
    Write-Host "Test it:  .\src\AutoDnd.ps1 -Once -NoAct"
    Write-Host ''
}
