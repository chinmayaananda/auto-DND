<#
.SYNOPSIS
    Do-Not-Disturb control for auto-DND.

.DESCRIPTION
    Windows 11 does not expose a supported API for the Focus / Do Not Disturb toggle you
    see in the notification centre. The state lives in an undocumented binary blob under
    CloudStore, and writing it does not reliably notify the shell, so this project does
    not pretend to drive it.

    What it drives instead is the notification-banner master switch, which IS a plain
    registry value, takes effect for the next toast that arrives, and produces the effect
    people actually want from DND: no banners, no notification sounds.

        HKCU\...\Notifications\Settings\NOC_GLOBAL_SETTING_TOASTS_ENABLED
        HKCU\...\PushNotifications\ToastEnabled

    Caveat, stated plainly: the Settings app and the notification-centre bell will not
    show "Do not disturb" as switched on while this is active. Notifications are simply
    suppressed. If you need the visible DND toggle too, use the OnShareStart /
    OnShareStop command hooks in config.json to call a tool of your choosing.
#>

Set-StrictMode -Version Latest

$script:NotificationSettingsKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings'
$script:PushNotificationsKey    = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications'

function Get-NotificationsEnabled {
    <#
    .SYNOPSIS
        Reads the current notification-banner master switch.
    .DESCRIPTION
        Both values are absent on a clean profile, and absent means "enabled".
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    foreach ($pair in @(
            @{ Key = $script:NotificationSettingsKey; Name = 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' }
            @{ Key = $script:PushNotificationsKey;    Name = 'ToastEnabled' }
        )) {
        $props = Get-ItemProperty -LiteralPath $pair.Key -Name $pair.Name -ErrorAction SilentlyContinue
        if ($null -ne $props -and $props.PSObject.Properties.Name -contains $pair.Name) {
            if ([int]$props.($pair.Name) -eq 0) { return $false }
        }
    }
    return $true
}

function Set-NotificationsEnabled {
    <#
    .SYNOPSIS
        Turns notification banners on or off for the current user.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][bool]$Enabled
    )

    $value = if ($Enabled) { 1 } else { 0 }
    $target = if ($Enabled) { 'enable notifications' } else { 'suppress notifications' }

    if (-not $PSCmdlet.ShouldProcess('HKCU notification settings', $target)) { return }

    foreach ($pair in @(
            @{ Key = $script:NotificationSettingsKey; Name = 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' }
            @{ Key = $script:PushNotificationsKey;    Name = 'ToastEnabled' }
        )) {
        if (-not (Test-Path -LiteralPath $pair.Key)) {
            New-Item -Path $pair.Key -Force | Out-Null
        }
        New-ItemProperty -LiteralPath $pair.Key -Name $pair.Name -Value $value -PropertyType DWord -Force | Out-Null
    }
}

function Invoke-ConfiguredHook {
    <#
    .SYNOPSIS
        Runs a user-supplied command hook, if one is configured.
    .DESCRIPTION
        This is the extension point for anything this project deliberately does not do
        itself: setting Slack's own DND through its Web API, pausing a music player,
        driving a third-party Focus Assist utility, and so on. The command runs with the
        same privileges as the watcher, so only put commands there that you wrote.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Command,
        [Parameter(Mandatory)][scriptblock]$Logger
    )

    if ([string]::IsNullOrWhiteSpace($Command)) { return }

    try {
        & $Logger 'INFO' "Running hook: $Command"
        $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $Command 2>&1
        if ($output) { & $Logger 'INFO' "Hook output: $($output -join ' | ')" }
    }
    catch {
        & $Logger 'WARN' "Hook failed: $($_.Exception.Message)"
    }
}
