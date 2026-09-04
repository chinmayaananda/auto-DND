# auto-DND

Automatically silences Windows 11 notifications while you are sharing your screen in
Slack, Microsoft Teams, Google Meet or Zoom — and turns them back on the moment you stop.

---

## First, the honest answer to "is this built into Windows 11?"

**No.** Not for app-based screen sharing, and PowerToys has nothing for it either.

What exists and why it does not cover you:

| Feature | What it actually does | Why it misses your case |
|---|---|---|
| Focus assist rule **"When I'm duplicating my display"** (Settings → System → Notifications → Turn on do not disturb automatically) | Fires when you extend or duplicate to a *physical* second display or projector | Sharing a window inside Teams/Slack/Meet is not a display change. The rule never fires. |
| Focus assist rule **"When playing a game" / "full screen mode"** | Fires on exclusive-fullscreen apps | A meeting window is not fullscreen-exclusive |
| **PowerToys** | Awake, FancyZones, Run, etc. | No notification or focus module at all |
| **Task Scheduler** | Runs on event-log events | Windows publishes no event when an app starts capturing the screen |
| **Teams / Slack built-in** | Both suppress *their own* notification content while you present | Neither one silences Outlook, WhatsApp, Windows Update, or anything else |

That last row is the real gap. Teams protecting you from Teams toasts is not the problem;
the Outlook banner with a salary line in it is. So this repo fills that gap.

## What this actually does, including the limitation

**Detection.** Every app that captures your screen through the modern Windows Graphics
Capture API leaves a record in the registry under
`CapabilityAccessManager\ConsentStore\graphicsCaptureProgrammatic`. While the capture is
live, that app's `LastUsedTimeStop` value is `0`. This is exactly the bookkeeping Windows
itself uses to decide when to show the "an app is using your screen" privacy indicator, so
it is as accurate as that indicator. Chrome, Edge, Slack and the new Teams all take this
path. A window-title fallback is included for anything that does not.

**Suppression — read this bit.** Windows 11 exposes **no supported API** for the Do Not
Disturb toggle you see in the notification centre. Its state is an undocumented binary blob
in `CloudStore`, and writing it does not reliably tell the shell to re-read it. Projects
that claim to flip it are usually broken on the next Windows build. So this one does not
try. It flips the notification-banner master switch instead, which is a plain registry
value and takes effect immediately:

```
HKCU\...\Notifications\Settings\NOC_GLOBAL_SETTING_TOASTS_ENABLED = 0
HKCU\...\PushNotifications\ToastEnabled = 0
```

**The practical effect is what you asked for**: no banners, no notification sounds, from
any app, while you share. **The cosmetic difference**: the moon icon in your taskbar will
not light up, and Settings will not show "Do not disturb: on". If that visible toggle
matters to you, the `OnShareStart` / `OnShareStop` hooks in `config.json` let you run any
command you like alongside the suppression.

**Safety.** Three things ensure you are never left silently muted:

- The watcher only restores notifications if *it* was the thing that turned them off. If
  you had already switched them off manually, it leaves your setting alone.
- State is written to disk, so a crash or reboot mid-meeting is detected and undone the
  next time the watcher starts.
- `uninstall.ps1` always re-enables notifications, even if the watcher is already dead.

---

## Install (no GitHub knowledge needed)

You need Windows 11 and nothing else. No admin rights required.

### 1. Download the code

Open your browser to the repository, click the green **Code** button, choose **Download
ZIP**, then right-click the downloaded file → **Extract All**. Put the extracted folder
somewhere permanent, for example `C:\Tools\auto-DND` — if you later delete or move it, the
automation stops working.

*(If you would rather use git: `git clone https://github.com/chinmayaananda/auto-DND.git`)*

### 2. Open PowerShell in that folder

Open the folder in File Explorer, click the address bar, type `powershell` and press Enter.

### 3. Check that it detects your apps — before installing anything

Run the diagnostic, then start a screen share in Slack or Teams or Meet while it is
running:

```powershell
powershell -ExecutionPolicy Bypass -File .\src\Diagnose.ps1 -Seconds 90
```

You should see a green `STARTED capturing` line naming your app within a second or two of
starting the share, and a grey `stopped capturing` line when you stop. If you do, you are
good. If you see nothing, see [Troubleshooting](#troubleshooting).

### 4. Install

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

That registers a Scheduled Task named `auto-DND` that starts the watcher every time you log
in, and starts it now. There is no window and no tray icon — it just runs.

### 5. Confirm it works

Start a screen share, wait a couple of seconds, and check Settings → System →
Notifications: the top toggle should be **off**. Stop sharing and it should return to
**on** within about five seconds.

The log tells you everything it did:

```powershell
Get-Content $env:LOCALAPPDATA\AutoDnd\autodnd.log -Tail 30
```

### Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

---

## Configuration

`install.ps1` creates `config.json` from `config.example.json`. Edit it and restart the
task (`Restart-ScheduledTask -TaskName auto-DND`) to apply changes.

| Setting | Meaning |
|---|---|
| `PollSeconds` | How often to check. `2` is cheap — it is a registry read, not a scan. |
| `StartDebounceSeconds` | Wait this long after a share is seen before silencing. Prevents flapping while you pick a window. |
| `StopDebounceSeconds` | Wait this long after a share disappears before un-silencing. Raise it if you switch between shared windows a lot. |
| `WatchedApps` | Regex patterns matched against the capturing app's path or package name. **This list is deliberately not empty** — screenshot tools, OBS and remote-support agents also capture the screen, and you do not want those silencing you. |
| `EnableWindowTitleFallback` | Also treat a visible "you are sharing your screen" toolbar as a share. |
| `WindowTitlePatterns` | Regexes for that fallback. |
| `OnShareStart` / `OnShareStop` | Optional PowerShell command run on each transition. Use for Slack's own DND API, pausing music, etc. Only put commands there that you wrote — they run as you. |
| `LogLevel` | `DEBUG`, `INFO`, `WARN`, `ERROR`. |

---

## Troubleshooting

**The diagnostic shows nothing while I am sharing.** Your app is capturing through an older
path that skips the ConsentStore. Look at the *"Visible window titles"* section that
`Diagnose.ps1` prints at the end, find the row that only appears while you are sharing, and
add a distinctive fragment of that title to `WindowTitlePatterns` in `config.json`.

**It detects a share I did not start.** Something else is capturing your screen — a
screenshot tool, a recording app, or a remote-support agent. `Diagnose.ps1` names it.
Either tighten `WatchedApps` or, if you did not install that app, find out what it is.

**Notifications are stuck off.** Run `.\uninstall.ps1`, or set the toggle back manually in
Settings → System → Notifications. The watcher restores it on next start anyway.

**Nothing happens at all.** Check the task is running:

```powershell
Get-ScheduledTask -TaskName auto-DND | Get-ScheduledTaskInfo
Get-Content $env:LOCALAPPDATA\AutoDnd\autodnd.log -Tail 40
```

**Test without touching any settings:**

```powershell
powershell -ExecutionPolicy Bypass -File .\src\AutoDnd.ps1 -Once -NoAct
```

---

## Repository layout

```
src/AutoDnd.ps1             Watcher loop, debouncing, state, logging
src/AutoDnd.Detection.ps1   ConsentStore + window-title screen-share detection
src/AutoDnd.Dnd.ps1         Notification suppression and the command hooks
src/Diagnose.ps1            Live diagnostic for tuning config.json
install.ps1 / uninstall.ps1 Scheduled Task registration and clean removal
config.example.json         Template copied to config.json on install
```

## Known limitations

- The visible Windows DND toggle and the taskbar moon icon are not driven (see above).
- Detection is polling-based, so there is a `PollSeconds + StartDebounceSeconds` window at
  the very start of a share where a notification can still land. Lower both if that matters
  more to you than flap resistance.
- Windows 10 is untested. The ConsentStore keys exist from Windows 10 2004 onward, so it
  will probably work, but nothing here has been verified against it.

## Licence

MIT — see [LICENSE](LICENSE).
