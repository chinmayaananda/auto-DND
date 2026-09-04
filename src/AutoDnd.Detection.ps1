<#
.SYNOPSIS
    Screen-capture detection for auto-DND.

.DESCRIPTION
    Primary signal: the Windows Capability Access Manager ConsentStore. Every app that
    captures the screen through the Windows.Graphics.Capture API leaves a per-app key
    under ConsentStore\graphicsCaptureProgrammatic (and graphicsCaptureWithoutBorder).
    While a capture is running, LastUsedTimeStop is 0. This is the same bookkeeping the
    OS uses for the camera and microphone privacy indicators, so it is as accurate as
    the "app is using your screen" indicator itself.

    Fallback signal: top-level window titles. Some capture paths (older Electron builds,
    apps still on the legacy GDI/DXGI duplication path) never touch the ConsentStore.
    Those apps almost always pop a "you are sharing your screen" toolbar window instead.
    Run src/Diagnose.ps1 while sharing to find out which signal your apps produce.
#>

Set-StrictMode -Version Latest

$script:ConsentStoreRoots = @(
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\graphicsCaptureProgrammatic'
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\graphicsCaptureWithoutBorder'
)

# P/Invoke for the window-title fallback. Added once per session.
if (-not ('AutoDnd.NativeWindows' -as [type])) {
    Add-Type -Namespace 'AutoDnd' -Name 'NativeWindows' -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern int GetWindowTextW(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);

[DllImport("user32.dll")]
public static extern bool IsWindowVisible(IntPtr hWnd);

[DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

public static System.Collections.Generic.List<string[]> GetVisibleWindows()
{
    var results = new System.Collections.Generic.List<string[]>();
    EnumWindows(delegate (IntPtr hWnd, IntPtr lParam)
    {
        if (!IsWindowVisible(hWnd)) { return true; }
        var sb = new System.Text.StringBuilder(512);
        int len = GetWindowTextW(hWnd, sb, sb.Capacity);
        if (len <= 0) { return true; }
        uint pid;
        GetWindowThreadProcessId(hWnd, out pid);
        results.Add(new string[] { sb.ToString(), pid.ToString() });
        return true;
    }, IntPtr.Zero);
    return results;
}
'@
}

function ConvertFrom-ConsentStoreKeyName {
    <#
    .SYNOPSIS
        Turns a ConsentStore subkey name into something human-readable.
    .DESCRIPTION
        Non-packaged (classic .exe) apps are stored with their full path and '#' in place
        of the path separator, e.g. "C:#Program Files#Google#Chrome#Application#chrome.exe".
        Packaged (Store/MSIX) apps are stored as a package family name, e.g.
        "MSTeams_8wekyb3d8bbwe".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$KeyName,
        [switch]$NonPackaged
    )

    if ($NonPackaged) {
        $path = $KeyName -replace '#', '\'
        return [pscustomobject]@{
            Identity = $path
            Name     = [System.IO.Path]::GetFileName($path)
            Kind     = 'NonPackaged'
        }
    }

    return [pscustomobject]@{
        Identity = $KeyName
        Name     = ($KeyName -split '_')[0]
        Kind     = 'Packaged'
    }
}

function Get-ConsentStoreCaptureState {
    <#
    .SYNOPSIS
        Enumerates every app the ConsentStore knows about for screen capture.
    .OUTPUTS
        One object per app with Identity, Name, Kind, InUse, Root.
    #>
    [CmdletBinding()]
    param()

    foreach ($root in $script:ConsentStoreRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }

        $leaves = @()
        foreach ($child in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            if ($child.PSChildName -eq 'NonPackaged') {
                foreach ($grandchild in (Get-ChildItem -LiteralPath $child.PSPath -ErrorAction SilentlyContinue)) {
                    $leaves += [pscustomobject]@{ Item = $grandchild; NonPackaged = $true }
                }
            }
            else {
                $leaves += [pscustomobject]@{ Item = $child; NonPackaged = $false }
            }
        }

        foreach ($leaf in $leaves) {
            $props = Get-ItemProperty -LiteralPath $leaf.Item.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) { continue }

            $start = 0L
            $stop = 0L
            if ($props.PSObject.Properties.Name -contains 'LastUsedTimeStart') { $start = [int64]$props.LastUsedTimeStart }
            if ($props.PSObject.Properties.Name -contains 'LastUsedTimeStop') { $stop = [int64]$props.LastUsedTimeStop }

            # A capture is live when it has started and has not yet been stamped as stopped.
            $inUse = ($start -gt 0) -and ($stop -eq 0)

            $identity = ConvertFrom-ConsentStoreKeyName -KeyName $leaf.Item.PSChildName -NonPackaged:$leaf.NonPackaged
            [pscustomobject]@{
                Identity = $identity.Identity
                Name     = $identity.Name
                Kind     = $identity.Kind
                InUse    = $inUse
                Root     = Split-Path -Leaf $root
                Source   = 'ConsentStore'
            }
        }
    }
}

function Test-AppIsWatched {
    <#
    .SYNOPSIS
        Returns $true when an app identity matches one of the configured patterns.
    .DESCRIPTION
        An empty pattern list means "any app that captures the screen counts", which is
        deliberately not the default: screenshot tools, OBS and remote-support agents all
        capture the screen without you being in a meeting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Identity,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Patterns
    )

    if ($Patterns.Count -eq 0) { return $true }
    foreach ($pattern in $Patterns) {
        if ($Identity -match $pattern) { return $true }
    }
    return $false
}

function Get-WindowTitleCaptureState {
    <#
    .SYNOPSIS
        Fallback detection: look for the "you are sharing your screen" toolbar windows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Patterns
    )

    if ($Patterns.Count -eq 0) { return }

    foreach ($window in [AutoDnd.NativeWindows]::GetVisibleWindows()) {
        $title = $window[0]
        foreach ($pattern in $Patterns) {
            if ($title -match $pattern) {
                $processName = $null
                try { $processName = (Get-Process -Id ([int]$window[1]) -ErrorAction Stop).ProcessName } catch { $processName = 'unknown' }
                [pscustomobject]@{
                    Identity = $title
                    Name     = $processName
                    Kind     = 'Window'
                    InUse    = $true
                    Root     = 'WindowTitle'
                    Source   = 'WindowTitle'
                }
                break
            }
        }
    }
}

function Get-ActiveScreenShare {
    <#
    .SYNOPSIS
        Returns every currently-detected screen share that matches the configuration.
    .OUTPUTS
        Zero or more detection objects. Zero means "not sharing".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config
    )

    $watched = [string[]]$Config.WatchedApps
    $found = @()

    foreach ($entry in (Get-ConsentStoreCaptureState)) {
        if (-not $entry.InUse) { continue }
        if (Test-AppIsWatched -Identity $entry.Identity -Patterns $watched) { $found += $entry }
    }

    if ($Config.EnableWindowTitleFallback) {
        $found += @(Get-WindowTitleCaptureState -Patterns ([string[]]$Config.WindowTitlePatterns))
    }

    return $found
}
