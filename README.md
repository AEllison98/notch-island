# Notch Island

A Dynamic Island for the MacBook notch. It lives around the notch and in the menu bar (no Dock icon),
and shows what you are listening to, the weather, your next meeting, a focus timer, little bubbles when
things happen, and what Claude Code is doing, including its permission requests, which you can answer
right from the notch.

- **The island**: Liquid Glass around the notch, clear like the menu bar while it is a small pill and
  tinted to your theme when open. Rest the pointer on the notch for a moment to open it; move away and it
  closes; click it to keep it open; click anywhere else to close it.
- **Tiles**: music (Apple Music and Spotify, with synced lyrics), weather, your next calendar event, and a
  25-minute focus timer. Show, hide and reorder them from the menu bar, or drag them in the open island.
- **Peeks**: a bubble when an app opens or quits, when you plug in the charger, when the battery reaches
  20% and 10%, and when a Focus turns on or off.
- **Claude Code**: what Claude is doing right now, permission requests with Allow and Deny (or ⌃⌥⌘Y and
  ⌃⌥⌘N), and "Done" with how long it took.
- **Two themes**: Dark Matte and White Matte.

## Requirements

- A Mac with Apple Silicon, running macOS 14 (Sonoma) or later.
- Liquid Glass needs macOS 26 or later; on 14 and 15 the island uses the menu bar's frosted look instead.
- Macs without a notch get a drawn one at the top centre of the screen.
- For the Claude Code part: Claude Code 2.1 or later (tested with 2.1.284).

## Install

### Download (easiest)

1. Download **NotchIsland-0.1.1.zip** (or the newest version) from the
   [Releases page](https://github.com/AEllison98/notch-island/releases/latest) and double-click it to
   unzip.
2. Drag **NotchIsland.app** into your **Applications** folder.
3. Open it. Because it is not notarized by Apple, macOS stops it the first time:
   1. In the message that says Apple could not verify it, click **Done**.
   2. Open **System Settings > Privacy & Security**, scroll down to **Security**, and next to the line
      about NotchIsland being blocked, click **Open Anyway**. Enter your password.
   3. Click **Open** in the last message.

   You only do this once. (Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/NotchIsland.app`.)
4. A capsule icon appears in the menu bar. That is Notch Island's menu.

The download is signed ad-hoc, so after you install a newer version, macOS asks again for the permissions
you had granted. Building it yourself avoids that (below).

### Build it yourself

You need Xcode, or just the Command Line Tools (`xcode-select --install`), with Swift 6.

```bash
git clone https://github.com/AEllison98/notch-island.git
cd notch-island
./build.sh --run
```

This compiles, signs, installs to `~/Applications/NotchIsland.app` and opens it. `build.sh` signs with the
first Apple Development (or Developer ID) certificate in your keychain, so macOS keeps your permissions
from one build to the next; a free Apple ID added in **Xcode > Settings > Accounts** gives you one.
Without a certificate it signs ad-hoc and tells you so. To choose a certificate yourself:
`SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./build.sh`.

## Using it

**The island.** Rest the pointer on the notch to open it, click to keep it open, click anywhere else to
close it. While something is going on (music, the timer, Claude working) the notch grows into a small
pill; click the pill to open the island.

**The menu** (the capsule icon in the menu bar):

| Item | What it does |
|---|---|
| Tiles | Click a tile to show or hide it |
| Arrange Tiles | Move a tile left or right (or drag tiles in the open island) |
| Weather | **My Location**, or a city you type with **Set City…** |
| Theme | Dark Matte or White Matte |
| Launch at Login | Start Notch Island when you log in |
| Peeks | Turn each kind of bubble on or off |
| Preview | Show a bubble, the pill or the open island, to see how they look |
| Quit Notch Island | |

**Tiles.**

- **Music**: works with Apple Music and Spotify. When a player is open, the tile shows a **Connect**
  button; click it once and macOS asks whether Notch Island may control that player. Then you get the cover
  (Spotify shows its app icon instead; see Privacy), title, artist, a progress bar, play/pause/next/previous
  and the current line of the lyrics, synced, under the tiles.
- **Weather**: temperature, conditions, and the day's high and low, for your location or a city. Updates
  every 30 minutes and when you open the island. Uses °F where your region does.
- **Calendar**: click **Connect Calendar** once; then the tile shows the event that is on now, or the next
  one in the coming week. All-day events and meetings you declined are left out.
- **Focus timer**: 25 minutes. Start, pause and reset; the pill counts down while it runs, and a bubble
  says when it is done.

**Peeks.** Apps opening and quitting, the charger, and the battery at 20% and 10% need nothing. **Focus On
and Off** is off until you turn it on under **Peeks**, which is when macOS asks for Focus permission. macOS
only tells apps whether *some* Focus is on (there is no public Do Not Disturb API), and it may refuse the
permission to apps that are not from the App Store. If so, **Peeks > Show Do Not Disturb with a Shortcut…**
walks you through a two-minute Shortcuts automation that needs no permission and can name Do Not Disturb.

## Claude Code

Notch Island gets Claude Code's events through hooks: a small script that Claude Code runs on each event,
which passes it to the app. You add the hooks to Claude Code's settings file, `~/.claude/settings.json`,
once. Open Notch Island at least once first: it puts the script where the settings point
(`~/Library/Application Support/NotchIsland/notch-island-hook`), wherever the app itself lives.

### Set it up with the script

Download [`scripts/install-claude-hooks.sh`](scripts/install-claude-hooks.sh) (it is also on the Releases
page), read it if you like, and run it:

```bash
bash install-claude-hooks.sh
```

It backs up your settings file, adds Notch Island's hooks, and keeps everything else as it was, including
hooks you already have (and if your settings file is a symlink, it edits the file the link points to).
Running it again changes nothing. `bash install-claude-hooks.sh --uninstall` takes them out again.

### Or add them by hand

[`claude-hooks.json`](claude-hooks.json) has every entry. Open `~/.claude/settings.json` in a text editor
(create it containing `{}` if it does not exist), then:

- **If it has no `"hooks"` section**, copy the whole `"hooks": { ... }` part of `claude-hooks.json` into
  it, next to the other settings (mind the comma between entries).
- **If it already has a `"hooks"` section**, add Notch Island's entry to each event's list, after the ones
  already there. Add the event if it is not listed yet.

For every event except `PermissionRequest`, the entry is:

```json
{ "hooks": [ { "type": "command", "command": "\"$HOME/Library/Application Support/NotchIsland/notch-island-hook\"", "async": true } ] }
```

For `PermissionRequest`, which waits for your answer, it is:

```json
{ "hooks": [ { "type": "command", "command": "\"$HOME/Library/Application Support/NotchIsland/notch-island-hook\"", "timeout": 600 } ] }
```

The events are `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PermissionDenied`, `PostToolUse`,
`PostToolUseFailure`, `Notification`, `SubagentStop`, `Stop`, `StopFailure` and `SessionEnd`. For example, a
settings file that already had another `Stop` hook ends up like this:

```json
"Stop": [
  { "hooks": [ { "type": "command", "command": "/path/to/your/other-hook" } ] },
  { "hooks": [ { "type": "command", "command": "\"$HOME/Library/Application Support/NotchIsland/notch-island-hook\"", "async": true } ] }
]
```

Keep the quotes around the path exactly as shown: the path has a space in it ("Application Support").

### Check it worked

Start a new Claude Code session (hooks are read when a session starts) and type `/hooks`: the events above
should list `notch-island-hook`. Then ask Claude to do something; the notch shows what it is doing.

### What you will see

- **While Claude works**, the pill shows the step (reading, editing, running a command, searching the web)
  and a small animated grid.
- **When Claude asks for permission**, the island opens with the request: the whole command, or everything
  the tool will do, never a shortened version. Settings that widen what it may do, such as
  `dangerouslyDisableSandbox`, are listed first, every line of an edit is marked `-` or `+`, and invisible
  or direction-changing characters show as `⟦U+202E⟧`.
  - **Deny** (⌃⌥⌘N) works at once.
  - **Allow** (⌃⌥⌘Y) unlocks only once the end of the request has been on screen, for at least half a
    second. A long command has to be scrolled to the end first.
  - The shortcuts exist only while a request is on screen and need no special permission.
  - The terminal's own prompt stays live too. Whichever you answer first wins. If you answer in the
    terminal, the card stays until the command has run (or the next step starts, or the turn ends),
    because Claude Code does not tell hooks about an answer given in the terminal.
  - Clicking elsewhere tucks the request into an "Allow?" pill. Rest on the notch to bring it back (and
    read it to the end again).
  - Requests from several sessions, or subagents, wait in line, one card at a time.
- **When auto mode blocks something on its own**: a bubble, "Auto mode blocked a command", with the
  command.
- **When Claude finishes**: "Done in 1 min 12 s · your-project".

### In auto mode

In **auto** permission mode, Claude Code's classifier decides by itself and does not ask you, so the
Allow/Deny card rarely appears. In testing with Claude Code 2.1.284 it ran, without asking, creating files
inside and outside the project, deleting a folder outside the project and a force-push, and it blocked
piping a download into the shell outright. So in auto mode you mostly see the working pill, a bubble when
something is blocked, and "Done".

Auto mode is not available on every model. On Haiku, for example, Claude Code says "auto mode unavailable for
this model" and switches to asking you, so every command that is not read-only brings up a card.

### Good to know

- `claude --bare` skips hooks entirely.
- If another of your hooks also answers permission requests, the first to answer wins.
- If Notch Island is not running, the hook does nothing and Claude Code works exactly as before.

## Permissions

Each is asked the first time you use what needs it, never at launch.

| Permission | Asked when |
|---|---|
| Automation > Music, Automation > Spotify | you click Connect in the Music tile (once per player) |
| Calendars | you click Connect Calendar |
| Location | you choose Weather > My Location |
| Focus | you turn on Peeks > Focus On and Off |
| Login item | you turn on Launch at Login |

Not needed: Accessibility, Input Monitoring, Bluetooth, Screen Recording, Full Disk Access, Notifications.

## Privacy

Nothing leaves your Mac except the requests below, and the app refuses any other address in code
([`Net.swift`](Sources/NotchIsland/Net.swift)), including a redirect to one.

| Where | What is sent | When |
|---|---|---|
| `lrclib.net` | the song's title, artist, album and length | a new song plays and the Music tile is shown (answers are cached) |
| `geocoding-api.open-meteo.com` | the city you typed | once per city |
| `api.open-meteo.com` | coordinates, rounded to about 10 km | every 30 minutes |

No analytics, no accounts, no cookies. Spotify cover art is not shown, because Spotify only offers it from
its own image server, which would be a third address; the Spotify icon stands in. Your location comes from
macOS (Apple's Location Services). The Claude Code connection is a socket in your Library folder that only
your user can open.

## Remove

1. Take the hooks out of Claude Code: `bash install-claude-hooks.sh --uninstall` (or delete the
   `notch-island-hook` entries by hand).
2. In Notch Island's menu, turn off **Launch at Login** if you turned it on, then **Quit Notch Island**.
3. Delete the app and what it stored:

```bash
rm -rf /Applications/NotchIsland.app ~/Applications/NotchIsland.app
defaults delete local.NotchIsland
rm -rf ~/Library/Caches/local.NotchIsland ~/Library/Application\ Support/NotchIsland
tccutil reset All local.NotchIsland
```

`tccutil reset` removes the permissions you granted it.

## Troubleshooting

- **No island and no menu bar icon**: open the app again; check Activity Monitor for NotchIsland. Another
  notch app may draw over it.
- **No Claude Code activity**: open Notch Island first, then start a *new* Claude Code session and check
  `/hooks`. The file `~/Library/Application Support/NotchIsland/notch-island-hook` should exist.
- **Claude Code shows "No such file or directory" for notch-island-hook**: the hooks are in your settings
  but Notch Island has not been opened yet (it puts the hook there when it starts). Open it once.
- **Permissions asked again after updating**: expected with the downloaded build (see Install).
- **"Focus status isn't available"**: macOS refused it; use the Shortcuts automation under Peeks.

## Checking it

The app can test itself: it walks the island through every state and checks the results with macOS's
window server, with real clicks, drags and Claude Code hook events, and with rendered pixels. It uses its
own settings and socket, never talks to your music players, and makes no network request unless you add
`--network`. Quit Notch Island first.

```bash
open -g -W --stderr /tmp/island.log -a NotchIsland --args --self-test; grep -E "FAIL|ALL PASS" /tmp/island.log
```

## How it is built

| File | What it does |
|---|---|
| `App.swift` | Starts everything; the menu bar menu |
| `IslandPanel.swift`, `IslandController.swift`, `IslandView.swift` | The windows, the states and when they change, how it looks |
| `Tiles.swift` | The tiles and the focus timer |
| `Weather.swift`, `CalendarService.swift`, `Music.swift`, `Lyrics.swift` | What the tiles show |
| `Peeks.swift` | App, power and Focus bubbles |
| `ClaudeBridge.swift`, `hooks/notch-island-hook` | Claude Code |
| `Net.swift` | The only network access, and its allowlist |
| `Settings.swift` | Themes and settings |
| `Diagnostics.swift` | The self-test |
| `build.sh` | Build, sign, install, or make a release zip |
| `scripts/install-claude-hooks.sh` | Adds or removes the Claude Code hooks |

## License

MIT. See [LICENSE](LICENSE).
