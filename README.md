# AI Companion

Personal project (not a BYC product). Home of **The List**: a macOS menu bar todo list that Claude fills in, with a draggable pixel dog.

- What and why: [PRD - The List.md](PRD%20-%20The%20List.md)
- Build plan, story by story: [EPICS - The List.md](EPICS%20-%20The%20List.md)
- Clickable prototype: https://claude.ai/artifact/AZmj3cmg19fGAU6PxZPBkb

## Layout

| Folder | What goes here |
|---|---|
| `spec/` | The `TODO.md` format spec (`format.md`) and `fixtures/`: example files with expected parse results. The MCP server and the app both test against these. |
| `mcp/` | `the-list-mcp`, the local MCP server Claude uses to add, list, and finish tasks. |
| `app/` | `app/TheList/` is the menu bar app. `app/TheListCore/` is the Swift package it uses to read and write `TODO.md`. |
| `pet/` | Dog sprite sheets. |
| `data/` | **My real tasks.** `TODO.md`, `settings.json`, `archive/`. Gitignored. |

## Data

- `data/TODO.md` is the single source of truth. It's plain Markdown and safe to edit by hand.
- `data/settings.json` holds `proactive` (`true`/`false`). When `false`, Claude stops suggesting tasks but still adds the ones I ask for.
- `data/settings.json` also holds `groups`, the menu in the popover header. Each group has an `id`, a `name`, and the `projects` it covers. A task shows under the group its `group:` key names, else under the group that lists its `project:` (spec §2.8). The app's New Group… adds one here, and edits by hand show up live.
- `data/reminders-map.json` remembers which Apple Reminder each task was exported to, so Export to Reminders updates them instead of duplicating them. Delete it to start over. The next export then creates fresh reminders, so delete the old "The List · …" lists in Reminders first.
- `data/archive/` gets Done items older than 14 days, one file per month.

## Stack

| Piece | Choice | Notes |
|---|---|---|
| `mcp/` | TypeScript on Node, official `@modelcontextprotocol/sdk`, stdio transport | Node 20.14 confirmed installed. `npm init`, one dependency (the SDK) plus a test runner. |
| `app/` | Swift 6.2, SwiftUI, `MenuBarExtra`, macOS 26 target | Swift toolchain confirmed (6.2.3), but only the Command Line Tools are installed — **no Xcode.app**. Building a `MenuBarExtra` app needs full Xcode (App Store) for the app target and code signing; the CLI tools alone aren't enough. Install Xcode before starting E4. |
| Tests | Node's built-in test runner (`node --test`) for `mcp/`; for `app/`, a `fixture-check` executable for now, XCTest once Xcode is installed. Both run against `spec/fixtures/` (E0.2). | The Command Line Tools ship neither XCTest nor Swift Testing, so `swift run fixture-check` stands in until then. It exits with status 1 on any failure. |
| Package manager | npm (`mcp/`), Swift Package Manager (`app/`) | `app/TheListCore/` is a Swift package. The app target and the Xcode project come in E4.1. |

### Building and running the app

```bash
cd app/TheList
./build-app.sh                  # builds build/The List.app (release), signed for this Mac only
open "build/The List.app"       # starts it in the menu bar; Quit is in the popover footer
```

The app reads `data/TODO.md` (the path is baked into the bundle at build time). To point it somewhere else, launch it with `open --env THE_LIST_TODO_PATH=/path/to/TODO.md "build/The List.app"`. To see the popover without clicking, `$(swift build --show-bin-path)/TheList --render out.png [--todo path] [--today YYYY-MM-DD] [--dark]` draws it to a PNG (add `--show-done` to open the Done section, `--group <id>` to show one group). `$(swift build --show-bin-path)/TheList --selftest` runs the popover's actions (tick, untick, move, quick-add, an outside edit) through the real store against a scratch list. The app logs each reload under the subsystem `com.jbanayo.thelist`.

**Export to Reminders** asks for Reminders access the first time. It only works from the bundled app, because macOS needs the usage text in `Info.plist`. The app is signed ad hoc, so macOS may ask again after a rebuild. If it says access is denied, turn The List back on in System Settings → Privacy & Security → Reminders.

### Running the checks

```bash
(cd mcp && npm test)                              # TypeScript: parse and write fixtures, unit and integration tests
(cd app/TheListCore && swift run fixture-check)   # Swift: parse and write fixtures, file-safety checks, a concurrent-write test against mcp/dist
python3 spec/reference.py                         # Python reference: parse fixtures only
```

The Swift concurrent-write test uses the built server in `mcp/dist`, so run `npm run build` (or `npm test`) in `mcp/` first.

Nothing else pulled in — this stays a small, native, offline app per the PRD's non-goals.
