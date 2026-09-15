# FableUsage

<img src="icon/preview.png" width="128" alt="FableUsage icon">

A macOS menu bar app that shows your Claude **Fable weekly limit usage**, and when opened, which Claude Code sessions used how much Fable this week.

- Menu bar: Fable weekly limit % (turns orange/red when the server flags a warning)
- Menu: plan limits (session, weekly, Fable), usage by surface, per-session Fable usage (weighted tokens), and whether each session is running
- Session submenu: copy resume command, copy session ID, open folder in Finder
- A notification once per weekly window when the Fable limit passes 80%

## Build and install

Only the Command Line Tools (`swiftc`) are required; no Xcode.

```sh
./build.sh
```

This installs and launches `~/Applications/FableUsage.app` and registers it to launch at login.

The icon (`AppIcon.icns`) is drawn by `icon/make_icon.swift`. After editing it, delete `AppIcon.icns` and run `./build.sh` to regenerate.

## Command-line options

```sh
APP=~/Applications/FableUsage.app/Contents/MacOS/FableUsage
$APP --dump            # print limits and per-session usage as text
$APP --login on|off    # turn launch at login on/off
$APP --test-alert      # send a test notification and print the permission state
```

## How it works and caveats

- **Per-session usage** is computed from the token usage of Fable responses in the Claude Code transcripts under `~/.claude/projects/**/*.jsonl`. Only newly appended data is read on each refresh.
  - Values are weighted tokens (input 1, output 5, cache write 1.25/2, cache read 0.1) and may not match actual credit consumption.
  - Only Claude Code transcripts on this Mac are included. claude.ai chats, Cowork, and other devices are not.
- **Plan limits** come from `api.anthropic.com/api/oauth/usage`, the endpoint Claude Code's `/usage` uses.
  - It is undocumented, so this part may stop working if the response format changes.
  - The app only reads the token Claude Code stores in the keychain (`Claude Code-credentials`); it never refreshes or modifies it. If the token has expired, run Claude Code once.
- If limits can't be fetched, the week start falls back to `resetWeekday`/`resetHour` in `main.swift` (default: Sunday 06:00).
- If the Command Line Tools contain a stale `usr/include/swift/module.modulemap` that makes `import Cocoa` fail, `build.sh` hides it with a VFS overlay during the build.
