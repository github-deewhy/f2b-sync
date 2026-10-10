# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Planned
- Scheduling: minutes, hourly, daily, weekly and monthly runs, via launchd
  agents (CLI first, then a GUI editor).
- Menu bar mode with "Sync now" and last-run status.
- Optional `rsync` transfer mode for multiple or large files.

## [2.1.0] - 2026-10-10

The repository now contains the complete project: server script, dashboard and
Mac client. **No functional changes** to any script or to the app.

### Added
- `server/f2b.sh`: the Fail2Ban report and `--json` export. It discovers every
  active jail automatically, so it works on any Fail2Ban setup.
- `dashboard/f2b.html`: the local dashboard. Open it in a browser and use
  **Load JSON** to view a synced `f2b_status.json`; no web server is needed.
- `server/f2b_api.py`: the optional standalone HTTP API with pre-configured
  statistics (`/api/v1/bans`, `/api/v1/bans/{ip}`, `/api/v1/stats`). It is
  independent: neither the sync client nor the dashboard uses it.
- README: scope table, step-by-step flow (server, Mac app, local dashboard),
  API skeleton and endpoints, a complete ordered command list and
  troubleshooting.

### Changed
- Repository layout: `server/`, `dashboard/` and `mac/` (Mac files moved
  unchanged into `mac/`; `build_app.sh` works from there as before).

### Notes
- `f2b_api.py` is included as provided: it reads a single jail (`ai-watchdog`
  by default), listens on `0.0.0.0:3000` and has no authentication. The README
  recommends an SSH tunnel and a closed firewall port.

## [2.0.0] - 2026-10-10

### Added
- Native single-window macOS app (Swift / AppKit) replacing the AppleScript
  applet: icon, title, live status line, **determinate progress bar** and the
  final result in the same window.
- Real progress stages reported by the sync itself (key check 3%, connect 10%,
  server script running 35%, download 70%, validate 85%, save 95%, done 100%),
  with smooth easing between stages and a slow crawl while waiting.
- Final result panel with **Close**, **Show Log** and, on failure, **Retry**.
- `--progress` flag on `f2b_sync.sh`: machine-readable `@@PROGRESS <pct> <msg>`
  and `@@DONE <code> <msg>` lines on stdout. Terminal output without the flag
  is unchanged.
- Server-side stage markers sent over the same SSH connection (still a single
  connection).
- `f2b_sync.conf.example`, `LICENSE`, `.gitignore`, README.

### Changed
- `build_app.sh` now compiles `main.swift` with `swiftc` (needs Xcode Command
  Line Tools). The previous build is kept as `build_app_applescript.sh`.
- Built-in defaults in `f2b_sync.sh` are now generic placeholders; put your real
  host in `~/.config/f2b_sync.conf`.
- App declares `NSDesktopFolderUsageDescription` for a clearer permission prompt.

## [1.1.0] - 2026-10-09

### Added
- AppleScript applet app with a native progress window, Dock progress bar and
  a result dialog, because notifications from the bare shell launcher did not
  appear.

### Changed
- App now shows in the Dock while running (needed for the progress display).

## [1.0.0] - 2026-10-09

### Added
- `f2b_sync.sh`: fetches `f2b_status.json` from the remote Ubuntu server over a
  **single SSH connection** (run `f2b.sh --json`, then stream the file back).
- Connection timeouts (`ConnectTimeout`, `ServerAlive*`), `BatchMode` so
  scheduled runs never hang on a prompt, and 3 retries with a 5 s delay.
- Safe writes: download to a temp file, validate the JSON (`jq`, `python3` or
  `plutil`), then atomically replace the target. A failed sync never overwrites
  a good file.
- Timestamped log at `~/Library/Logs/f2b_sync.log`; optional macOS notification
  (`--notify`) and `--quiet`.
- Settings overridable in `~/.config/f2b_sync.conf`.
- `build_app.sh`: builds `F2B Sync.app` with a custom icon (generated from
  `icon.png`) and ad-hoc code signing.

### Replaced
- The original two-step manual workflow (`ssh ... "./f2b.sh --json"` followed by
  `scp`) with the single-connection script above.

[Unreleased]: https://github.com/github-deewhy/f2b-sync/compare/v2.1.0...HEAD
[2.1.0]: https://github.com/github-deewhy/f2b-sync/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/github-deewhy/f2b-sync/compare/v1.1.0...v2.0.0
[1.1.0]: https://github.com/github-deewhy/f2b-sync/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/github-deewhy/f2b-sync/releases/tag/v1.0.0
