# Epics & User Stories — The List

| | |
|---|---|
| Source | [PRD - The List.md](PRD%20-%20The%20List.md) (v0.3) |
| Date | 2026-09-26 |
| Status | Draft v0.1 |

How to use this: build the stories **in order, top to bottom**. Each story leaves the product in a working state, so you can stop after any one of them and still use what exists. Checkpoints mark the points where the product becomes noticeably more useful.

Each story heading shows: size · **model** · [PRD requirement IDs].

Sizes: **S** = under 2 hours, **M** = half a day, **L** = about a day (building with Claude Code).

### Which model builds what

| Model | Used for | Stories |
|---|---|---|
| **Haiku** | Mechanical work with an obvious right answer: setup, config, small UI additions on top of existing code | 10 |
| **Sonnet** | Standard coding against a clear spec and tests: parsers, MCP tools, SwiftUI screens | 18 |
| **Opus** | Judgment calls and code where a subtle mistake costs data or hours: the file format spec, concurrent writes, how Claude decides what's your task, per-pixel click-through, the session-resume spike | 6 |

Two rules on top of the per-story pick:
- **Opus reviews at every checkpoint.** Haiku and Sonnet stories get checked against their acceptance criteria before the next story starts.
- **Step up after two failed tries.** If a Haiku story fails its checks twice, retry it on Sonnet; if a Sonnet story fails twice, retry on Opus.

---

## Overview

| Epic | Goal | Stories | Milestone |
|---|---|---|---|
| **E0 — Foundation** | Folder layout, file format spec, shared test fixtures | 3 | M1 |
| **E1 — The file** | `TODO.md` that can be read and written safely | 3 | M1 |
| **E2 — Capture (MCP server)** | Claude can add, list, finish, and update tasks | 5 | M1 |
| **E3 — Claude behavior** | Claude notices my tasks, asks first, and respects the on/off switch | 4 | M1 |
| **E4 — Menu bar app** | The List shows in the menu bar and stays in sync with the file | 4 | M2 |
| **E5 — Acting on tasks** | Tick, re-prioritize, quick-add, click through to links | 4 | M2 |
| **E6 — The dog** | *Dropped 2026-10-19, replaced by the E11 stickmen* | 6 | — |
| **E7 — Polish** | Settings, archive, session resume, launch at login, widget | 5 | M4 |
| **E8 — Groups & Reminders** | Split tasks into groups (BYC, personal, …); one-way export to Apple Reminders | 4 | M4 |

**Total:** 38 stories. Rough effort: M1 ≈ 3 days, M2 ≈ 3 days, M3 ≈ 3 days, M4 ≈ 3 days.

---

## Two recommendations before you start

**1. Keep runtime data in a `data/` subfolder.** The PRD puts `TODO.md` directly in `AI Companion/`. If this folder becomes a git repo (PRD open question 1), your personal tasks would sit next to the code and could get committed. Suggested layout:

```
AI Companion/
├── PRD - The List.md
├── EPICS - The List.md
├── spec/            format.md + fixtures/ (shared by MCP server and app)
├── mcp/             the-list-mcp (TypeScript)
├── app/             The List (Xcode / SwiftUI)
└── data/            TODO.md, settings.json, archive/   ← gitignored
```

If you agree, update PRD §6.1 to `AI Companion/data/TODO.md`. The stories below assume this layout.

**2. The file format needs one spec and one set of test files.** The MCP server (TypeScript) and the app (Swift) each parse `TODO.md`, in two languages. If they disagree even slightly, one will corrupt what the other wrote. Story E0.2 writes a set of example files with expected results, and both parsers test against the same set.

---

## E0 — Foundation

### E0.1 Project scaffold · S · **Haiku**
*As the builder, I want a clear folder layout so that code, docs, and my personal data don't mix.*
- [x] Folders created as in the layout above.
- [x] `data/` holds a starter `TODO.md` with the five headings (P0–P3, Done) and a `settings.json` with `{"proactive": true}`.
- [x] A `.gitignore` excludes `data/` (ready for when this becomes a repo).
- [x] A short `README.md` explains the layout and points to the PRD.

### E0.2 File format spec + golden fixtures · M · **Opus** · [D1–D3]
*As the builder, I want one written spec and a set of test files so that both parsers agree on every edge case.*
- [x] `spec/format.md` defines: headings, checkbox syntax, the `{key:value}` metadata block, allowed keys, date format (`YYYY-MM-DD`), and how to treat anything unrecognized (keep it untouched).
- [x] `spec/fixtures/` contains pairs of `input.md` + `expected.json`, covering at least: a normal file, hand-typed lines with no metadata, a title containing `{` or `}`, an unknown heading, extra blank lines, CRLF line endings, an empty file, and an item under the wrong heading.
- [x] Round-trip rule: parse → write → parse gives the same result, and lines the parser didn't change keep their exact bytes.

### E0.3 Pick the stack · S · **Haiku**
*As the builder, I want the tech choices written down so that I don't re-decide them mid-build.*
- [x] MCP server: TypeScript + the official MCP SDK, stdio transport (recommended; Python also works).
- [x] App: SwiftUI, macOS 26 target, `MenuBarExtra`.
- [x] Choices recorded in `README.md`.

---

## E1 — The file

### E1.1 Parser + writer (TypeScript) · M · **Sonnet** · [D1–D3]
*As the MCP server, I want to read and write `TODO.md` exactly per spec so that Claude's edits never damage the file.*
- [x] Passes every fixture in `spec/fixtures/`.
- [x] Hand-typed lines get an `id` the next time the file is written (D3).
- [x] Unknown content is kept as it was.

### E1.2 Safe writes · S · **Sonnet** · [D4]
*As the user, I want writes to never corrupt the file so that I never lose a task.*
- [x] Every write goes to a temp file and then renames it over `TODO.md`.
- [x] Killing the process mid-write leaves either the old file or the new one, never a half-written file.

### E1.3 No lost updates · S · **Opus** · [D4]
*As the user, I want edits from the app, Claude, and my own editor to never overwrite each other.*
- [x] Every change re-reads the file right before writing and applies itself to that fresh copy. It never writes back an old copy held in memory.
- [x] Test: two writers add different items 10 ms apart → both items are in the file.

> **Checkpoint:** nothing visible yet, but the most dangerous part (data integrity) is done and tested.

---

## E2 — Capture (MCP server)

### E2.1 `add_todo` · M · **Sonnet** · [C1]
*As me, I want to say "put X in my todo list" and have it written to the file.*
- [x] Tool `add_todo(title, priority?, due?, link?, project?, note?)` appends the item under the right heading.
- [x] Defaults: priority P2, `src:claude-code`, `added:<today>`.
- [x] Returns the new item, including its `id`, so Claude can confirm it.

### E2.2 Register with Claude Code · S · **Haiku** · [C2]
*As me, I want the server available in every Claude Code session without extra setup.*
- [x] `claude mcp add --scope user the-list …` works, and the server appears in `/mcp`. (2026-09-27: `claude mcp list` shows `the-list` ✔ Connected. The CLI lives at `~/.local/bin/claude`, now on PATH through `~/.zshrc`.)
- [x] In a fresh session, "put 'test task' in my todo list" writes a correct line to `data/TODO.md`.

> **Checkpoint — first usable version.** Claude writes tasks, and I read `TODO.md` in VS Code. Use it for a day before going further.

### E2.3 `list_todos`, `complete_todo`, `update_todo` · M · **Sonnet** · [C1]
*As me, I want to ask Claude what's on my list, tick things off, and change them without opening the file.*
- [x] `list_todos(filter?)` supports filtering by status, priority, and project, and sorts by effective priority (§6.3: overdue or due today counts as P0).
- [x] `complete_todo(id)` moves the item to Done with `done:<today>`.
- [x] `update_todo(id, …)` changes any field. A priority change moves the line to the new heading.

### E2.4 Duplicate check · S · **Sonnet** · [C7]
*As me, I want Claude to notice when a task is already on the list so that I don't get duplicates.*
- [x] `add_todo` fuzzy-matches the title against open items. On a close match it doesn't add; it returns the existing item and `duplicate: true`.
- [x] Claude then asks "Update the existing one instead?"

### E2.5 Register with Claude Desktop · S · **Haiku** · [C2]
*As me, I want the same capture to work in the Claude Desktop app.*
- [x] Added to `claude_desktop_config.json` (`mcpServers.the-list`, pointing at `mcp/dist/index.js`, `THE_LIST_SRC=claude-desktop`). Restart Claude Desktop and check `the-list`'s tools appear.
- [x] Items added from Desktop carry `src:claude-desktop` — covered by the integration test (`server.integration.test.ts`); confirm once more with a real add from the Desktop app.

---

## E3 — Claude behavior

### E3.1 Global instruction · S · **Opus** · [C3, C4, C5]
*As me, I want Claude to spot tasks that are mine and ask before adding them.*
- [x] The instruction is added to `~/.claude/CLAUDE.md` (text from PRD C3).
- [x] An explicit "put this in my todo list" adds straight away. Anything Claude detects on its own gets proposed with a suggested priority and waits for "yes" (C4).
- [x] Test with 10 sample prompts: tasks that are mine get proposed; tasks Claude is doing itself, tasks owned by others, and vague ideas don't (C5). (Passed in a fresh session, 2026-09-27.)

### E3.2 Priority suggestion · S · **Opus** · [§6.3]
*As me, I want Claude's suggested priority to follow my rules so that I rarely have to correct it.*
- [x] The instruction includes the P0–P3 rules from §6.3.
- [x] Mentions of dates ("by Friday", "tomorrow") become a `due` date.

### E3.3 Auto-link · S · **Sonnet** · [C6]
*As me, I want each task to link back to where it came from.*
- [x] Claude attaches, in this order: the file being worked on (`vscode://file/…`), then a URL from the conversation, then a ClickUp task.
- [x] If none of those exist, the task has no link for now. Session links come in E7.3.

### E3.4 Proactive on/off switch · S · **Sonnet** · [C9]
*As me, I want to turn off Claude's suggestions when they get in the way, without losing explicit adds.*
- [x] `add_todo` still works when `data/settings.json` has `"proactive": false`.
- [x] A new tool `get_settings` returns the settings, and the instruction tells Claude to check it before proposing anything.
- [x] With proactive off, the 10 test prompts produce no proposals, and explicit adds still work. (Passed, 2026-09-27.)
- [x] Until the app's Settings screen exists (E7.1), I flip the switch by editing the JSON or by asking Claude ("turn off todo suggestions").

> **Checkpoint — M1 done.** The whole capture loop works with no app at all.

---

## E4 — Menu bar app

### E4.1 Menu bar shell · M · **Sonnet** · [A1]
*As me, I want The List in my menu bar so that it's always one click away.*
- [x] A SwiftUI `MenuBarExtra` app with no Dock icon. It's in `app/TheList/`, and `./build-app.sh` builds `build/The List.app`, signed for this Mac only. Confirmed as a `UIElement` process via `lsappinfo`. It's a Swift package, not an Xcode project: that keeps it buildable from the command line, and the optional widget (E7.5) is the only piece that would need a project.
- [ ] Clicking the icon opens a popover titled "The List". **Needs a human look:** macOS blocks screenshots from Claude's process, so the icon's presence and the click haven't been seen, only checked in code and in `--render` output.

### E4.2 Swift parser · M · **Sonnet** · [D1–D3]
*As the app, I want to read `TODO.md` exactly the way the MCP server does.*
- [x] Passes every fixture in `spec/fixtures/` (the same set E1.1 uses). Built as `app/TheListCore/` and checked by `swift run fixture-check`: 13 parse and 17 write fixtures. Move these into XCTest once Xcode is installed.
- [x] Writes are safe (E1.2) and don't lose updates (E1.3). It uses the same `TODO.md.lock` protocol as the MCP server. A test runs 30 writes each from Swift and the real TypeScript server at the same time, and none are lost.

### E4.3 Show the list · M · **Sonnet** · [A3, §6.3]
*As me, I want to see my tasks grouped by priority, with the urgent ones first.*
- [x] Groups for Now, This week, Soon, and Someday, with a count on each.
- [x] Each row shows the title, project tag, and a relative due date ("Today", "Tomorrow", "Wed", "Overdue 2d").
- [x] Anything overdue or due today appears under Now, without the file being rewritten.
- Logic: `makeSnapshot` and `relativeDueLabel` in `TheListCore`, tested in `fixture-check`. View: `app/TheList/Sources/TheList/PopoverView.swift`. Checked in light and dark mode with `TheList --render out.png --todo <file> --today <date>`, which draws the real view to a PNG. The renderer can't draw buttons, so the footer's Quit button appears as a placeholder in those images only.

### E4.4 Live sync + badge · M · **Sonnet** · [A2, A6, A9]
*As me, I want the list to update by itself when Claude adds something.*
- [x] The app watches the file (FSEvents) and updates within 1 second of any outside change. In the running app, a write from the TypeScript server reloaded it 12 ms later, and an in-place edit was also picked up. Both were confirmed from the app's log (`log show --info --predicate 'subsystem == "com.jbanayo.thelist"'`).
- [x] The badge shows the number of open P0 + P1 tasks and turns red when anything is overdue. The count and red state were checked in the log and in `--render`'s icon output. The red is a non-template image because menu bar templates ignore color, so it still needs a human look in the real menu bar.
- [x] At idle: under 50 MB of memory and about 0% CPU. Measured 14 MB footprint (29 MB RSS) and 0.0% CPU over 10 seconds idle.

> **Checkpoint:** a Claude add now shows up in the menu bar within a second.

---

## E5 — Acting on tasks

### E5.1 Tick off · S · **Sonnet** · [A5]
*As me, I want to mark a task done with one click.*
- [x] Clicking the checkbox moves the item to Done, with `done:<today>`.
- [x] A collapsible "Done (n)" section; clicking the checkbox again un-ticks an item. Unticking returns the item to the heading it was ticked from in this session (or the one it sits under, else Soon), not always P2.
- A task you typed by hand has no id yet, so the action finds it by line and title. If the file changed underneath, it refuses rather than guess. Covered by `fixture-check` and `TheList --selftest`, which drives the real store against a scratch list; a deliberately broken untick was caught.

### E5.2 Click through · M · **Sonnet** · [A4, L1, L2, L4]
*As me, I want clicking a task to take me to its context.*
- [x] `https://` links open in the browser, `vscode://` links open VS Code at that file, and local paths open in Finder. Clicking a title opens `clickTarget(for:todoPath:)` with `NSWorkspace`. The targets are checked in `fixture-check`; actually opening them needs a human click.
- [x] A task with no link opens `TODO.md` in VS Code at that line.

### E5.3 Change priority · S · **Haiku** · [A5]
*As me, I want to move a task between priorities.*
- [x] A right-click menu offers P0–P3. The line moves to the new heading in the file. The menu marks and disables the item's current heading. The move is covered by the self-test; the menu itself needs a human click.
- [ ] Drag-and-drop between groups (optional; the right-click menu is enough for v1). Not built.

### E5.4 Quick-add · S · **Haiku** · [A7]
*As me, I want to add a task by hand without Claude.*
- [x] A text field at the top of the popover. Enter adds the task as P2 with `src:manual`. It has no duplicate check, since a hand-typed add is deliberate. Blank input does nothing, and newlines are stripped.

### E5.5 Task details · S · **Opus** · [A4, added 2026-09-29]
*As me, I want clicking a task to show its full context first, then take me to its link, file, or Finder.*
- [x] Clicking a title shows the task's details in the popover: note plus the indented lines under it, priority (with why it's under Now if it's only overdue), due date, added date and source, and done date. It has a Back button and a checkbox.
- [x] Buttons fit where the link points: **Open link** (web), **Open in VS Code** and **Show in Finder** (`vscode://file/…`), **Open** and **Show in Finder** (a local path), **Open** (any other scheme), or **Open in TODO.md** (no link). A missing file is flagged in red and Show in Finder is disabled. **Edit in TODO.md** opens the task's line.
- The link kinds and Finder paths are handled by `linkTarget(for:todoPath:)` in `TheListCore`, checked in `fixture-check`. All five kinds were rendered with `TheList --render … --detail "<title>"` in light and dark.
- Right-click still offers a direct **Open**, plus **Show Details**.

**Still needs a human look:** typing in the field, right-click, clicking a task, and the details view's buttons in the real popover. macOS blocks screenshots from Claude's process, so these were tested through the store, not by clicking.

> **Checkpoint — M2 done.** Daily driver: I no longer open the `.md` file directly.

---

## E6 — The dog

*Dropped 2026-10-19. A floating desktop pet would cost memory and attention all the time. The stickmen in the popover (E11) show agent state instead, and only draw while the popover is open. Kept below for the record.*

### E6.1 Floating pet window · M · **Opus** · [P1]
*As me, I want a small window on my desktop where the dog lives.*
- [ ] A transparent, borderless, always-on-top panel about 64–96 px wide, visible on all Spaces.
- [ ] Only the dog's own pixels take clicks. Clicks anywhere else in the window reach whatever is behind it.

### E6.2 Dog sprite sheet · M · **Sonnet** · [P4, P8]
*As me, I want the dog's art ready for every state.*
- [ ] Frames generated with AI image tools, using the prototype's 16×12 dog as the reference: walk (2 frames), run (2), sit/wag (2), sleep (1), jump (1), held (1).
- [ ] Claude models can't generate images. Either you generate the frames with an image tool and Sonnet slices them into a sheet, or Sonnet writes a script that renders the sheet from pixel grids, the way the prototype draws the dog.
- [ ] Exported as a PNG sheet and drawn with nearest-neighbor scaling (no blur) at 8–12 fps.

### E6.3 Drag anywhere · M · **Sonnet** · [P2, P3]
*As me, I want to put the dog wherever I like.*
- [ ] Dragging moves it to any spot on any screen. While held, it shows the "held" frame.
- [ ] Its position is saved and restored after a restart.
- [ ] A press without movement opens the list popover.

### E6.4 States from the list · M · **Sonnet** · [P5]
*As me, I want the dog to show at a glance how urgent my list is.*
- [ ] Highest-priority state wins: **Jump** (~2 s after an add or finish) → **Run in place** (any effective P0 is open; bubble shows e.g. "2 in Now!") → **Walk** (open tasks, none P0; stays within ~90 px of its spot) → **Sleep** (list empty).
- [ ] States update within 1 second of any change to the file.

### E6.5 Show / hide · S · **Haiku** · [P6]
*As me, I want to hide the dog quickly, for example before a screen-share.*
- [ ] A toggle in the popover footer and a global hotkey (default to be decided; PRD open question 3).
- [ ] Hidden or shown is remembered across restarts.

### E6.6 Reduce Motion · S · **Haiku** · [P7]
*As me, I want the dog to respect my Mac's Reduce Motion setting.*
- [ ] With Reduce Motion on: no walking or bouncing, but the pose still changes with each state.

> **Checkpoint — M3 done.** Matches the prototype.

---

## E7 — Polish

### E7.1 Settings screen · M · **Sonnet** · [A8, C9]
*As me, I want one place to change how The List behaves.*
- [ ] Settings: file location, launch at login, archive window (days), **proactive suggestions on/off**.
- [ ] The proactive switch writes to `data/settings.json`, so Claude picks up the change on its next check.

### E7.2 Archive · S · **Haiku** · [D5]
*As me, I want old Done items cleared out so that the file stays short.*
- [x] Done items older than 14 days (configurable) move to `data/archive/YYYY-MM.md`. This is `archiveOldDone` in `TheListCore`, specified in spec §3.6 and covered by 7 checks in `fixture-check`. It is safe to run repeatedly and survives a crash partway through.
- [x] Runs when the app starts and once a day, when the date changes. Checked by launching the app on a scratch list: the old item moved to `archive/2026-08.md` and the recent one stayed.

### E7.3 Session resume links · L · **Opus** · [L3, C6]
*As me, I want a task to reopen the Claude Code session it came from.*
- [x] **Spike first (S):** check whether the MCP server can learn the current Claude Code session id, for example from an environment variable or through a hook. If it can't, drop this story.
  **Result (2026-09-28): it can, so the story stays.** Claude Code 2.1.283 starts each MCP server with `CLAUDE_CODE_SESSION_ID` in its environment. I checked the live `the-list` server behind a running session: its variable held that session's id, and the transcript `~/.claude/projects/<folder>/<id>.jsonl` carries the same id. No hook is needed.
  - **Resume has to run in the session's folder.** Sessions are stored per project, so run `cd <cwd> && claude --resume <id>`. The folder name in `~/.claude/projects/` is a lossy encoding (spaces become `-`), so get `cwd` from the transcript's first entry instead. The app can find the transcript by id alone, which keeps the link short.
  - **A running session may have no transcript yet.** One open VS Code panel had a server and an id but no file, because Claude Code writes the file on the first message. By the time `add_todo` runs there has been a message, but the app should still say "session no longer available" when the file is missing, for example after it's been deleted.
  - **Claude Desktop chats get no session link.** Desktop isn't Claude Code and its chats can't be resumed with the CLI. When the variable is absent, the server adds no link.
  - **Untested risk: `/clear`.** `/clear` starts a new session id. If the MCP server keeps running across `/clear`, its variable still holds the old id, and new tasks would link to the conversation before the clear. I can't test this without clearing a live session. Check it by hand before building: in a fresh session, add a task, run `/clear`, add another, and compare the ids against the transcript files. If it's stale, a `PreToolUse` hook on `mcp__the-list__add_todo` receives the live `session_id` and can pass it along.
  - **Opening Terminal:** use a temporary `.command` script opened with `open`, not AppleScript. AppleScript would trigger a macOS Automation permission prompt.
- [ ] If the spike succeeds: tasks carry `link:thelist://session/<id>`, the app registers the `thelist://` scheme, and clicking a task opens Terminal and runs `claude --resume <id>`.

### E7.4 Launch at login · S · **Haiku** · [A1]
*As me, I want The List running whenever my Mac is on.*
- [ ] A "Launch at login" option (off by default) using `SMAppService`.

### E7.5 Desktop widget (optional) · M · **Sonnet** · [§6.4 optional]
*As me, I want my top tasks visible on the desktop without clicking anything.*
- [ ] A WidgetKit widget showing the top 5 items by effective priority.
- [ ] Clicking a task opens its link.

## E8 — Groups & Reminders

*Added 2026-10-01 (PRD A10, A11).*

### E8.1 Group key and groups in settings · M · **Opus** · [A10]
*As me, I want my tasks to know whether they're BYC work or a personal project.*
- [x] Spec 1.1: a `group` key (§2.6, pair order §3.3) and groups in `data/settings.json` (§2.8). The effective group is the `group` key, else the group that lists the task's project, else none.
- [x] MCP: `add_todo` and `update_todo` take `group`. `list_todos` filters by effective group, and each item reports it. `get_settings` returns the groups.
- [x] Swift: `effectiveGroup`, `readSettings`, and `makeSnapshot(…, groups:, filter:)` in TheListCore. Covered by the new write fixtures `add_with_group` and `update_sets_group`, `fixture-check`, and the TS tests.

### E8.2 Group picker · S · **Sonnet** · [A10]
*As me, I want to look at just BYC, or just my personal projects.*
- [x] The header title is a menu: All, each group with its open count, Ungrouped (when there is anything ungrouped), and New Group…. The choice is remembered.
- [x] Quick-add files a task in the group showing. The badge still counts every group.
- [x] Checked with `--render --group byc` and `--selftest`.

### E8.3 New group, move to group · S · **Sonnet** · [A10]
*As me, I want to add a group and move tasks into it without editing files.*
- [x] New Group… names a group, saves it to `settings.json` with every other key kept, and switches to it. A `settings.json` that isn't valid JSON is never overwritten.
- [x] Right-click → Move to Group sets the task's `group` key. Remove from Group takes the key off again.
- [x] Groups edited by hand, or by Claude, show up live (the app watches `settings.json`).

### E8.4 Export to Reminders · M · **Opus** · [A11]
*As me, I want my list in Apple Reminders so it's on my phone.*
- [x] Export to Reminders in the footer, using EventKit. Lists are named "The List · <group>", or "The List" for ungrouped tasks. P0/P1/P2/P3 become high/medium/low/none. A real due date becomes an all-day due date. Link becomes the URL. Note and body lines become the notes, with the task id at the end.
- [x] `data/reminders-map.json` maps task ids to reminders, so exporting again updates them. A task ticked in The List gets its reminder ticked. Nothing is unticked or deleted.
- [x] The mapping, `reminderDraft`, is covered by `fixture-check`.
- [ ] Checked by hand in the real app: grant permission, export, export again (no duplicates), tick a task, export (the reminder is ticked).

> **Checkpoint — M4 done.** v1 complete.

---

## E9 — Agent mode (Saiyan mode since E11)

*Added 2026-10-15. The app's display name becomes "The Companion". The bundle id, the MCP server name and the Reminders prefix stay the same.*

### E9.1 Keep agents running · M · **Opus**
*As me, I want Claude Code and Codex to keep working while the screen is off or the lid is closed, and to see at a glance that they are.*
- [x] An Agent mode switch above the footer. On: an IOKit `PreventUserIdleSystemSleep` assertion, plus `pmset -a disablesleep 1` through the admin password prompt. Off and Quit undo both.
- [x] Cancelling the password keeps the screen part on and says the lid will still sleep. The lid state is read back from `pmset -g`, so one left on by a crash shows as on.
- [x] A ⚡ next to the menu bar icon while it's on. The accessibility text says so.
- [x] `--selftest` covers on, off, a cancelled password and Quit against a fake `PowerControl`. `--render --agent-on` shows the switch.
- [ ] Checked by hand: toggle on, close the lid during a long job, then reopen it. Toggle off and check `pmset -g`.


## E10 — Waiting on you

*Added 2026-10-19.*

### E10.1 Yellow dot when an agent needs me · M · **Opus**
*As me, I want to see at a glance when Claude Code or Codex is waiting on me, so a long job doesn't sit blocked while I think it's working.*
- [x] `hooks/agent-status.sh`, run from Claude Code and Codex hooks, keeps one file per live session in `/tmp/the-companion-<uid>/agents/` (Codex's hook sandbox can write to `/tmp` but not the repo) and deletes it when the session ends. It always exits 0 and prints nothing.
- [x] A yellow dot (amber `#F5B800`) on the menu bar icon, next to the coral due-today dot. The accessibility text says so.
- [x] "Waiting on you" in the popover, above agent mode: agent, project, why, how long, and × to dismiss. Blocked sessions come first.
- [x] Files older than 12 h are ignored. `fixture-check` covers reading the files and the script; `--selftest` covers the icon; `--render --waiting` draws both.
- [ ] Checked by hand: a Claude Code permission prompt shows the dot, and approving it clears it.
- [ ] Checked by hand: Codex hooks trusted with `/hooks`, then an approval and a finished turn both show. Also check whether the ChatGPT Codex app runs hooks or only the CLI does.

## E11 — Stickmen and Saiyan mode

*Added 2026-10-19. Replaces E6 (the dog). The main rule: the app stays light.*

### E11.1 A stickman each for Claude and Codex · M · **Opus**
*As me, I want to see at a glance whether Claude and Codex are working, idle, or out of tokens, without the app costing anything when I'm not looking.*
- [x] At the bottom of the popover, above Saiyan mode: short stickmen on a floor line. Claude has a coral head and Codex a hollow one, each with a caption.
- [x] Running while working (a prompt or tool call in the last 15 min), sitting when idle or waiting on me, lying down when out of tokens with the reset time when known.
- [x] The hook script keeps working sessions and records `limited` from Claude's `StopFailure`. Codex's limit comes from the last 64 KB of its newest session log, read once a minute.
- [x] A `Canvas` of a few strokes at 12 fps, only while a figure runs and the popover window is visible (occlusion state). Still under Reduce Motion. Measured at 0.0% CPU and 13 MB with the popover closed and Claude running.
- [x] `fixture-check` covers poses, staleness, the Codex log reader and the script's new states. `--render --claude/--codex` draws a frame.
- [x] Checked by hand: Claude's hooks write its state and the stickman follows it.
- [ ] **Known issue (2026-10-19): Codex's stickman doesn't move yet.** The Codex desktop app runs the hooks (its log shows `hook/started`/`hook/completed`), but no state file appears. The likely cause is its sandbox blocking writes outside the session's folder, so the files moved to `/tmp`. That's unconfirmed; check `/tmp/the-companion-<uid>/hook-errors.log` after a Codex turn.
- [ ] Check CPU with the popover open while both run.

### E11.2 Saiyan mode, off without a password · S · **Opus**
*As me, I want turning the keep-awake switch off to be instant, with no password.*
- [x] "Agent mode" is now "Saiyan mode" everywhere in the UI. The type and `--agent-on` keep their names.
- [x] Turning it on still asks for the password, and that prompt also installs `/etc/sudoers.d/the-companion` (checked with `visudo`, root:wheel 0440), allowing only `pmset -a disablesleep 0` without a password.
- [x] Off and Quit use `sudo -n` with that rule, falling back to the prompt if it's missing. `--selftest` covers both paths.
- [ ] Checked by hand: on (password), off (no prompt), `pmset -g` shows `SleepDisabled 0`, `sudo -l` lists only that command.

---

## Deferred to v2 (PRD §10)

Not broken into stories yet: capture from claude.ai web/mobile, a morning digest, and natural-language due dates in quick-add.
