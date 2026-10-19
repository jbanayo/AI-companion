# AI Companion

Personal project. Home of **The Companion** (formerly The List): a macOS menu bar app with a todo list that Claude fills in, an agent mode that keeps Claude Code and Codex running, and a draggable pixel dog. The todo view inside it is still called The List.

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

### Connecting Claude and Codex

The MCP server runs over stdio from `mcp/dist/index.js` (`npm run build` in `mcp/` first). Each client sets `THE_LIST_SRC`, which tags the tasks it adds:

- **Claude Code:** `claude mcp add the-list -s user -- node "<repo>/mcp/dist/index.js"` (tasks get `src:claude-code`).
- **Codex:** in `~/.codex/config.toml`, use an absolute path to Node 20, because the Codex app doesn't load the shell's asdf or nvm setup:
  ```toml
  [mcp_servers.the-list]
  command = "/Users/catherinebanayo/.asdf/installs/nodejs/20.14.0/bin/node"
  args = ["<repo>/mcp/dist/index.js"]

  [mcp_servers.the-list.env]
  THE_LIST_SRC = "codex"
  ```
  Restart Codex after editing.

### "Waiting on you" dot

A yellow dot on the menu bar icon means a Claude Code or Codex session is waiting on me. Either it's stuck on a permission prompt or a question, or it finished its turn and wants my next message. The popover lists each one ("Claude · AI Companion, needs permission · 4m"), and × dismisses a stale one. The dot clears when I reply.

Hooks in both tools run `hooks/agent-status.sh <claude|codex> <state>`. The script writes one file per waiting session to `data/agents/` and deletes it when work resumes, and the app watches that folder. Files older than 12 hours are ignored, which covers sessions killed without saying so.

- **Claude Code:** the `hooks` block in `~/.claude/settings.json`.
  - Waiting: `PermissionRequest`, `Notification` (permission and input prompts), `PreToolUse` on `AskUserQuestion`.
  - Finished: `Stop`.
  - Working: `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `PermissionDenied`.
  - Ended: `SessionEnd`.
- **Codex:** `~/.codex/hooks.json`.
  - Waiting: `PermissionRequest`. Finished: `Stop`.
  - Working: `UserPromptSubmit`, `PostToolUse`, `Interrupt`. Ended: `SessionEnd`.
  - Codex runs a new hook only after it has been trusted. Open the Codex CLI once (`/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`), type `/hooks`, and trust them.
  - Codex's `notify` setting is left alone. It only reports finished turns, and Computer Use already uses it.

### Building and running the app

```bash
cd app/TheList
./build-app.sh                  # builds build/The Companion.app (release) with its icon, signed for this Mac only
open "build/The Companion.app"  # starts it in the menu bar; Quit is in the popover footer
```

The app reads `data/TODO.md` (the path is baked into the bundle at build time). To point it somewhere else, launch it with `open --env THE_LIST_TODO_PATH=/path/to/TODO.md "build/The Companion.app"`. To see the popover without clicking, `$(swift build --show-bin-path)/TheList --render out.png [--todo path] [--today YYYY-MM-DD] [--dark]` draws it to a PNG (add `--show-done` to open the Done section, `--group <id>` to show one group, `--agent-on` to show agent mode switched on). `$(swift build --show-bin-path)/TheList --selftest` runs the popover's actions (tick, untick, move, quick-add, an outside edit) through the real store against a scratch list, and agent mode against a fake that never touches power settings. The app logs each reload under the subsystem `com.jbanayo.thelist`.

The logo is drawn in code in `Logo.swift` (chosen 2026-10-19, replacing the 2026-10-04 "Stack" design). The menu bar shows Goku's hair in one color that follows the menu bar. It turns into upright Super Saiyan hair while agent mode is on, and a coral dot appears when something is due today or overdue. The app icon is a Saiyan monkey tail with a coral tip. `build-app.sh` runs `TheList --make-iconset` and `iconutil` to make `AppIcon.icns`.

**Export to Reminders** asks for Reminders access the first time. It only works from the bundled app, because macOS needs the usage text in `Info.plist`. The app is signed ad hoc, so macOS may ask again after a rebuild. If it says access is denied, turn The Companion back on in System Settings → Privacy & Security → Reminders.

**Agent mode** is the switch above the footer. It keeps the Mac awake so Claude Code and Codex keep working:

- With the screen off, it holds a power assertion, the same as `caffeinate -i`. This needs no password. The screen can still dim and lock.
- With the lid closed, it runs `pmset -a disablesleep 1`, which asks for your Mac password. If you cancel, agent mode stays on for the screen only, and the footer says so.
- Turning it off, or quitting, runs `pmset -a disablesleep 0`, which asks for the password again.
- It isn't remembered across launches. If a crash leaves the lid setting on, the switch shows on at the next launch, so you can turn it off. You can also check by hand with `pmset -g | grep SleepDisabled`.
- A closed MacBook that stays awake can get hot. Don't put it in a bag with agent mode on.
- While it's on, a ⚡ shows next to the menu bar icon.

The rename to The Companion changed only the app's display name. The bundle id (`com.jbanayo.thelist`), the MCP server name (`the-list`) and the Reminders list names ("The List · …") are unchanged, so existing permissions, Claude and Codex configs, and exported lists keep working.

### Running the checks

```bash
(cd mcp && npm test)                              # TypeScript: parse and write fixtures, unit and integration tests
(cd app/TheListCore && swift run fixture-check)   # Swift: parse and write fixtures, file-safety checks, a concurrent-write test against mcp/dist
python3 spec/reference.py                         # Python reference: parse fixtures only
```

The Swift concurrent-write test uses the built server in `mcp/dist`, so run `npm run build` (or `npm test`) in `mcp/` first.

Nothing else pulled in — this stays a small, native, offline app per the PRD's non-goals.
