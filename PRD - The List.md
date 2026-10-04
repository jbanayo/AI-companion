# PRD — The List (AI Companion project)

| | |
|---|---|
| Owner | Julius |
| Type | Personal project (not a BYC product) |
| App name | **The List** |
| Status | Draft v0.3 |
| Date | 2026-09-26 |
| Platform | macOS 26 (Apple Silicon), local-only |
| Home | `/BYC Ventures/AI Companion/` |
| Prototype | https://claude.ai/artifact/AZmj3cmg19fGAU6PxZPBkb |

---

## 1. Problem

Many of my action items come up while I work with Claude: "send Enzo the updated PRD", "review the Solomon extract PR", "ask Raph for the logo files". They stay in the chat transcript and I forget them. I want them in one place that is always visible on my Mac, without copy-pasting.

## 2. What it is

A small macOS menu bar app called **The List**. Claude writes to it. The list itself is stored as a plain Markdown file, kept locally at `/BYC Ventures/AI Companion/TODO.md` — not iCloud, so there's no sync-conflict risk.

- **Capture:** I say "put this in my todo list" in Claude and it gets added. Claude also notices on its own when something is my responsibility and offers to add it. Proactive suggestions can be switched off entirely from Settings (§6.2, §6.4); when off, Claude only adds what I explicitly ask for.
- **See:** a menu bar icon with a count badge. Click it to open the list, sorted by priority.
- **Act:** click an item to open what it points to: a file in VS Code, a URL, a ClickUp task, or the Claude session it came from.
- **Pet (optional):** a small pixel-art pet (first pet: a dog) that I can drag anywhere on the desktop. It reacts to the list and can be shown or hidden.

**Data location:** The List lives at `AI Companion/data/TODO.md` (local, not iCloud). Settings go in `AI Companion/data/settings.json`. This keeps the `data/` folder easily gitignored so my personal tasks never get committed along with the code.

**Naming:** the project — the folder, the PRD, the future codebase — is called **AI Companion**. The app itself, as I'll actually see it in the menu bar, is called **The List**. "Tally" was a placeholder and is retired.

**What this kind of thing is usually called:** "AI assistant" is too broad. The closer terms are an **AI task-capture tool** or **agentic todo list** (Claude writes the tasks), shown in a **menu bar app**, with a **desktop pet** (the Tamagotchi/Shimeji genre). In one line: *a menu bar todo list that Claude fills in, with a desktop pet.*

## 3. Goals / Non-goals

**Goals**
1. Adding a task from Claude takes one sentence and needs no manual step.
2. Claude detects my action items and proposes them, and adds nothing without my OK (see §6.2). I can turn this detection off entirely.
3. The list is always one click away and sorted by priority.
4. Every item links back to its context.
5. Lightweight: native, under 50 MB RAM, no account, no server, no cloud.

**Non-goals (v1)**
- Team or shared lists. This is just for me.
- Syncing to iPhone or other devices. *(The one-way Reminders export, A11, puts a copy on the iPhone through iCloud. That copy is read-only as far as The List is concerned: nothing syncs back.)*
- Mirroring ClickUp. **The List is the single source of truth for every task, BYC work included** — ClickUp items are linked to, never duplicated or synced.
- Calendar integration, and two-way sync with Reminders. *(Changed 2026-10-01: a one-way export to Apple Reminders is in scope, A11.)*
- The app calling an LLM itself. All intelligence comes from the Claude session I'm already in.

## 4. Feasibility: is it doable and quick?

Yes. There are three pieces and each one is small:

| Piece | What | Effort (building with Claude Code) |
|---|---|---|
| A. Data file | `AI Companion/TODO.md`, a Markdown checklist with metadata | Minutes |
| B. Capture | A local **MCP server** (`the-list-mcp`: `add_todo`, `list_todos`, `complete_todo`), a **global Claude instruction** telling Claude when to use it, and a `/todo` skill | ~0.5 day |
| C. App | A SwiftUI **menu bar app** (`MenuBarExtra`), "The List", that watches the file and renders it | ~1–2 days |
| D. Pet | A floating transparent window with a sprite-sheet animation | ~1 day + art |

**Fastest path:** piece B on its own works on day one. Claude writes to the `.md` file, and I read it in any editor. The app just gives that file a better view.

**Main constraint:** Claude can only write to my Mac from **Claude Code** (terminal/VS Code) and the **Claude Desktop app** (through a local MCP server). **claude.ai in the browser and on mobile can't reach a local file.** v1 supports Claude Code and Claude Desktop. Web/mobile capture is v2 (§10).

## 5. Users & core scenarios

Single user: me.

1. **Explicit add.** In Claude Code I say "put 'send Enzo the Prismo rulings summary' in my todo list, due Friday." Claude calls `add_todo` and the menu bar count goes from 4 to 5 within 1 second.
2. **Proactive detect.** While we work on a PRD, Claude writes: "You'll need to confirm the pricing tier with Raph. **Add to your todo list? (P2)**" I say yes and it gets added with a link to the PRD file. If I've turned proactive suggestions off in Settings, Claude skips this step and only adds tasks I explicitly ask for.
3. **Triage.** I click the menu bar icon. P0 items are at the top in red, and overdue items are flagged. I click an item, VS Code opens the linked file, and I tick it off.
4. **Pet.** I drag the dog to a corner of my screen and it stays there. While anything is in Now (P0) it runs in place. When only lower-priority tasks are open it walks around its spot. When the list is clear it sleeps. I hide it before a screen-share with one toggle.

## 6. Functional requirements

### 6.1 Data model: `AI Companion/data/TODO.md`

The file is the single source of truth, kept locally at `AI Companion/data/TODO.md` (inside a gitignored folder). It must stay readable and hand-editable, and the app must survive my manual edits.

```markdown
# Todo

## P0 — Now
- [ ] Reply to Enzo on Prismo pricing ruling {id:t_8f2a due:2026-09-27 link:https://app.clickup.com/t/abc123 src:claude-code}

## P1 — This week
- [ ] Review Solomon extract PR #42 {id:t_1c9d due:2026-10-01 link:https://github.com/... src:claude-desktop}

## P2 — Soon
- [ ] Ask Raph for Lumen logo source files {id:t_77b0 link:vscode://file/Users/catherinebanayo/Documents/BYC%20Ventures/product-docs/... src:claude-code}

## P3 — Someday

## Done
- [x] Push product-docs update {id:t_0a11 done:2026-09-25}
```

Fields in `{...}` (all optional except `id`): `id`, `due`, `link`, `src` (claude-code | claude-desktop | manual), `added`, `done`, `note`, `project` (e.g. Solomon, Lumen, Prismo, personal).

| # | Requirement |
|---|---|
| D1 | Items live under priority headings P0–P3, plus Done. The heading sets the priority. |
| D2 | Metadata goes in a trailing `{key:value ...}` block so the line still reads naturally. |
| D3 | Lines without metadata (typed by hand) are still valid. The app assigns them an `id` on the next write. |
| D4 | Writes are atomic (write a temp file, then rename) so the app and the MCP server can't corrupt the file. |
| D5 | Done items older than 14 days move to `AI Companion/data/archive/YYYY-MM.md`. |

### 6.2 Capture (Claude side)

| # | Requirement |
|---|---|
| C1 | **Local MCP server** (`the-list-mcp`, Node or Python, stdio) with tools: `add_todo(title, priority?, due?, link?, project?, note?)`, `list_todos(filter?)`, `complete_todo(id)`, `update_todo(id, ...)`. |
| C2 | Registered for **Claude Code** (`claude mcp add --scope user`) and **Claude Desktop** (`claude_desktop_config.json`). |
| C3 | **Global instruction** in `~/.claude/CLAUDE.md` (and in Claude Desktop project instructions): *"When the conversation produces an action item that Julius personally owns (a decision, reply, review, send, or approval), propose it as a todo with a suggested priority and link. Add it only after he confirms, unless he said 'put this in my todo list'."* |
| C4 | **Confirm by default.** Claude proposes and I confirm with "yes", "add", or a priority override. An explicit "put this in my todo list" skips the confirmation. |
| C5 | **Ownership test:** Claude only proposes items where I am the actor. Tasks Claude is doing now, tasks owned by others, and vague ideas are excluded. |
| C6 | **Auto-link:** Claude attaches the most relevant context. That's the file being worked on (`vscode://file/...`), the URL discussed, the ClickUp task, or, as a fallback, the session reference (see L3). |
| C7 | **Dedup:** before adding, the server fuzzy-matches open items. If one matches, it returns the existing item and Claude asks whether to update it instead. |
| C8 | `/todo` skill in Claude Code for quick use: `/todo`, `/todo add ...`, `/todo done ...`. |
| C9 | **Proactive on/off.** A single Settings toggle (A8) turns proactive suggestions off entirely. It's stored in `AI Companion/settings.json` (`proactive: true|false`), which the global instruction (C3) tells Claude to check before proposing anything. Off doesn't touch explicit adds (C4) — those keep working. |

### 6.3 Priority rules (Claude assigns, I can override)

| Priority | Rule of thumb |
|---|---|
| **P0 — Now** | Due today or overdue, or blocking someone else right now |
| **P1 — This week** | Due within 7 days, or someone is waiting on me |
| **P2 — Soon** | Has a clear next step and no hard date |
| **P3 — Someday** | Nice-to-have or an idea |

The app re-sorts automatically when a due date passes: an overdue P1 is shown as P0 without rewriting the file.

### 6.4 App (menu bar)

| # | Requirement |
|---|---|
| A1 | Native SwiftUI `MenuBarExtra` app, named **The List**. It has no Dock icon and starts at login (optional). |
| A2 | The menu bar icon shows the count of open P0+P1 items. It turns red if any P0 is overdue. |
| A3 | Clicking the icon opens a popover grouped by priority, showing title, project tag, and due date (relative, e.g. "in 2d" or "overdue"). |
| A4 | Clicking an item shows its details in the popover: title, note and body lines, priority, due date, and when it was added and by whom. The details have buttons that fit the link: Open link; Open in VS Code and Show in Finder; Open and Show in Finder for a local file; or Open in TODO.md when there's no link. Right-click keeps a direct Open. *(Changed 2026-09-29: it used to open the link straight away.)* |
| A5 | A checkbox marks the item done. Changing priority uses a right-click menu or drag. |
| A6 | The app watches the file (FSEvents) and updates within 1 second of any external write. |
| A7 | A quick-add field at the top for manual entry. It defaults to P2. |
| A8 | Settings: file location, launch at login, pet on/off, pet position, archive window, **proactive suggestions on/off** (C9). |
| A9 | Budget: under 50 MB RAM idle, ~0% CPU idle, app bundle under 20 MB. |
| A10 | **Groups** *(added 2026-10-01)*. A menu in the popover header switches between All, each group (e.g. BYC, Personal projects), and Ungrouped. Groups live in `data/settings.json`, and each group lists the projects it covers, so a task tagged `project:prismo` shows under BYC without a `group` key. A task's own `group` key overrides its project. The menu can add a new group. Right-click a task to move it to another group. Quick-add files a task in the group showing. The menu bar badge always counts every group. |
| A11 | **Export to Reminders** *(added 2026-10-01)*. A footer action copies open tasks into Apple Reminders, one list per group ("The List · BYC"). Priority, due date, link and note carry over. Exporting again updates the same reminders instead of adding new ones, and ticks the reminders of tasks finished since. One way only: nothing in Reminders comes back to `TODO.md`, and nothing in Reminders is deleted. |

**Optional:** a macOS **desktop widget** (WidgetKit) showing the top 5 items. Widgets refresh on the system's schedule and have limited interactivity, so they're a secondary view, not the main UI.

### 6.5 Links / "redirect on click"

| # | Link type | Opens |
|---|---|---|
| L1 | `https://...` (ClickUp, GitHub, Google Drive, etc.) | Default browser |
| L2 | `vscode://file/<path>:<line>` | VS Code at that file and line |
| L3 | `thelist://session/<id>` | Custom scheme. The app opens Terminal/VS Code and runs `claude --resume <id>` to reopen the Claude Code session the task came from |
| L4 | Local path | Finder / default app |

### 6.6 Pixel pet (optional)

First pet: **a dog** (tan fur, floppy dark ear, wagging tail). More pets can come later (§10).

| # | Requirement |
|---|---|
| P1 | A transparent, borderless, always-on-top floating window (~64–96 px). Only the pet itself takes clicks; the rest of the window passes clicks through. |
| P2 | **Drag anywhere.** I can drag the pet to any spot on any screen. It stays there and the position is remembered across restarts. While held, it dangles. |
| P3 | A short press without movement counts as a click and opens the list popover. |
| P4 | Sprite-sheet animation (PNG, 16×16 or 32×32 upscaled, nearest-neighbor) at 8–12 fps. |
| P5 | States driven by the list, highest first: |
| | • **Jump:** for ~2 s after I add or finish a task. |
| | • **Run in place:** while any open task is effectively P0 (including overdue or due today). Fast legs, tongue out, no movement. Speech bubble shows the count (e.g. "2 in Now!"). |
| | • **Walk:** while tasks are open but none are P0. Walks back and forth within ~90 px of where I dropped it, with occasional sit-and-wag pauses. |
| | • **Sleep:** when the list is empty. |
| P6 | Show/hide from the menu bar with a global hotkey. It auto-hides during screen sharing (optional, v1.1). |
| P7 | Respects Reduce Motion: no walking or bouncing, but state changes still show. |
| P8 | **Art:** generate the sprite with AI image tools for v1, using the prototype's 16×12 dog as the reference, rather than commissioning custom art. The dog stays unnamed — I refer to it as "the dog." |

## 7. Architecture

```
 Claude Code ──┐                       ┌── The List (menu bar app)
               ├─ the-list-mcp ───────►│    watches file, renders list,
 Claude Desktop┘   (local, stdio)      │    opens links, drives the dog
                          │            │
                          ▼            │
        AI Companion/TODO.md ◄─────────┘   (single source of truth;
                                            also hand-editable)
```

- The app and the MCP server only communicate through the file. Neither depends on the other being running.
- No network calls and no API keys. The Claude session I'm already using does the "AI" part.

## 8. Success criteria

- Within 2 weeks of use, at least 80% of my action items that come up in Claude conversations end up in the list without manual copying.
- Proactive suggestions are accepted at least 60% of the time. Below that, the ownership test (C5) is too loose and needs tightening — or I switch proactive mode off (C9).
- Zero data loss from concurrent writes.
- I open the list at least once a day without being reminded.

## 9. Milestones

| Phase | Scope | Done when |
|---|---|---|
| **M1 — Capture works** | `TODO.md` format, `the-list-mcp`, global CLAUDE.md rule, `/todo` skill, proactive on/off flag (C9) | Saying "put this in my todo list" in Claude Code writes a correct line |
| **M2 — Menu bar app** | A1–A7, link handling L1/L2/L4 | Daily driver; I stop opening the .md directly |
| **M3 — Pet** | P1–P5 with the dog sprite | Dog can be dragged anywhere, reacts to list state; toggle works |
| **M4 — Polish** | L3 session resume, archive, widget, settings, launch at login | — |

## 10. Later (v2+)

- **Capture from claude.ai web/mobile:** host the MCP server remotely (e.g. a small Cloudflare Worker behind auth) and sync the file with the Mac. Alternatively, capture into a ClickUp personal list and have the app read from there.
- Morning digest: the pet (or a notification) summarizes today's P0/P1 items at 9 am.
- More pets beyond the dog (cat, etc.) and skins, and pet "growth" tied to completed tasks.
- Natural-language due dates in quick-add ("fri", "next week").

## 11. Decisions (resolved 2026-09-26)

1. **File location.** Local, inside a new project folder `/BYC Ventures/AI Companion/` — not iCloud, so there's no sync-conflict risk.
2. **Proactive mode.** Stays on by default. Added a single Settings toggle to switch it off entirely (C9, A8) rather than batching or weakening it by default.
3. **BYC vs personal.** Everything lives in The List. ClickUp tasks are linked to, never mirrored.
4. **Name.** The app is **The List**; the project/folder is **AI Companion**. "Tally" is retired.
5. **Pet art.** Generate the sprite with AI for v1 instead of commissioning. The dog stays unnamed.

## 12. Open questions

1. Does `/BYC Ventures/AI Companion/` become its own git repo once code exists, or stay untracked like this PRD?
2. Which AI image tool/style to standardize on for the dog sprite, once we move past the prototype's placeholder art?
3. Exact hotkey for show/hide pet (P6) and for opening the popover (A3) — any preference, or pick sensible defaults?
