// Runs spec/fixtures/ (parse + write) and the file-safety checks against TheListCore.
// Usage: swift run fixture-check [path/to/spec]    Exit code 1 if anything fails.
import Foundation
import TheListCore

let specDir: URL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: #filePath) // app/TheListCore/Sources/fixture-check/main.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("spec")
let projectDir = specDir.deletingLastPathComponent()

var passed = 0
var failed = 0

func check(_ name: String, _ body: () throws -> String?) {
    do {
        if let problem = try body() {
            failed += 1
            print("  FAIL \(name)\n\(problem.split(separator: "\n", omittingEmptySubsequences: false).map { "       \($0)" }.joined(separator: "\n"))")
        } else {
            passed += 1
            print("  PASS \(name)")
        }
    } catch {
        failed += 1
        print("  FAIL \(name): threw \(error)")
    }
}

func cases(_ kind: String) -> [URL] {
    let dir = specDir.appendingPathComponent("fixtures").appendingPathComponent(kind)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { !$0.hasPrefix(".") }.sorted().map { dir.appendingPathComponent($0) }
}

func bytes(_ url: URL) throws -> [UInt8] { [UInt8](try Data(contentsOf: url)) }

func orNull(_ s: String?) -> Any {
    if let s { return s }
    return NSNull()
}

func normalizedJSON(_ object: Any) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: object))
}

func pretty(_ object: Any) -> String {
    let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\(object)"
}

func visible(_ b: [UInt8]) -> String {
    String(decoding: b, as: UTF8.self).replacingOccurrences(of: "\r", with: "\\r")
}

// MARK: - Parse fixtures

print("Parse fixtures:")
for dir in cases("parse") {
    let raw = try bytes(dir.appendingPathComponent("input.md"))
    check("parse \(dir.lastPathComponent)") {
        let doc = parseDocument(raw)
        let (headings, items) = deriveViews(doc)
        let actual: [String: Any] = [
            "lineEnding": doc.lineEnding.rawValue,
            "finalNewline": doc.finalNewline,
            "bom": doc.bom,
            "headings": headings.map { ["line": $0.line, "raw": $0.raw, "section": orNull($0.section?.rawValue)] },
            "items": items.map {
                [
                    "line": $0.line, "section": orNull($0.section?.rawValue), "priority": $0.priority.rawValue,
                    "done": $0.done, "title": $0.title, "id": orNull($0.id), "meta": $0.meta, "body": $0.body,
                ] as [String: Any]
            },
        ]
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("expected.json")))
        let got = try normalizedJSON(actual)
        if (got as! NSDictionary).isEqual(expected) { return nil }
        return "expected:\n\(pretty(expected))\ngot:\n\(pretty(got))"
    }
    check("round-trip \(dir.lastPathComponent)") {
        let out = serialize(parseDocument(raw))
        return out == raw ? nil : "serialize(parse(x)) != x\nexpected: \(visible(raw))\ngot:      \(visible(out))"
    }
}

// MARK: - Write fixtures

func change(_ fields: [String: Any], _ key: String) -> FieldChange {
    guard let value = fields[key] else { return .keep }
    if value is NSNull { return .remove }
    return .set(value as! String)
}

print("Write fixtures:")
for dir in cases("write") {
    check("write \(dir.lastPathComponent)") {
        let input = try bytes(dir.appendingPathComponent("input.md"))
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("ops.json"))) as! [String: Any]
        let ids = spec["idSequence"] as! [String]
        var next = 0
        var exhausted = false
        let nextId: () -> String = {
            guard next < ids.count else {
                exhausted = true
                return "t_exhausted_\(next)"
            }
            defer { next += 1 }
            return ids[next]
        }

        let doc = parseDocument(input)
        for op in spec["ops"] as! [[String: Any]] {
            assignMissingIds(doc, idGen: nextId) // spec §3.2: every operation runs this first
            let id = op["id"] as? String ?? ""
            switch op["op"] as! String {
            case "assignMissingIds":
                break
            case "add":
                let item = op["item"] as! [String: Any]
                addTodo(doc, AddInput(
                    title: item["title"] as! String,
                    priority: (item["priority"] as? String).flatMap(Priority.init(rawValue:)),
                    due: item["due"] as? String, project: item["project"] as? String, group: item["group"] as? String,
                    src: item["src"] as? String,
                    link: item["link"] as? String, note: item["note"] as? String, added: item["added"] as? String
                ), idGen: nextId)
            case "complete":
                guard completeTodo(doc, id: id, date: op["date"] as! String) != nil else { return "complete: no item \(id)" }
            case "reopen":
                let priority = (op["priority"] as? String).flatMap(Priority.init(rawValue:)) ?? .p2
                guard reopenTodo(doc, id: id, priority: priority) != nil else { return "reopen: no item \(id)" }
            case "update":
                let f = op["fields"] as! [String: Any]
                let fields = UpdateFields(
                    title: f["title"] as? String,
                    priority: (f["priority"] as? String).flatMap(Priority.init(rawValue:)),
                    due: change(f, "due"), project: change(f, "project"), group: change(f, "group"),
                    link: change(f, "link"), note: change(f, "note")
                )
                guard updateTodo(doc, id: id, fields) != nil else { return "update: no item \(id)" }
            case "remove":
                guard removeTodo(doc, id: id) else { return "remove: no item \(id)" }
            case let other:
                return "unknown op \(other)"
            }
        }
        if exhausted { return "idSequence exhausted — the fixture needs more ids" }

        let out = serialize(doc)
        let expected = try bytes(dir.appendingPathComponent("expected.md"))
        return out == expected ? nil : "expected:\n\(visible(expected))\ngot:\n\(visible(out))"
    }
}

// MARK: - File safety (spec §3.5)

func tempTodoPath() throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("the-list-swift-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("TODO.md").path
}

func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: path)) }
func read(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }
func entries(nextTo path: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path).sorted()
}
func mtime(_ path: String) throws -> Date {
    try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as! Date
}
func itemTitles(_ path: String) throws -> [String] {
    deriveViews(try readTodoFile(at: path)).items.map(\.title)
}

print("File safety:")

check("atomic write leaves only the target file, with the new content") {
    let path = try tempTodoPath()
    try write(path, "version 1\n")
    try writeFileAtomic(path, Array("version 2\n".utf8))
    if try read(path) != "version 2\n" { return "content not replaced" }
    let names = try entries(nextTo: path)
    return names == ["TODO.md"] ? nil : "leftover files: \(names)"
}

check("withTodoFile releases its lock") {
    let path = try tempTodoPath()
    try write(path, "# Todo\n\n## P2 — Soon\n")
    try withTodoFile(at: path) { addTodo($0, AddInput(title: "One", added: "2026-09-27")) }
    let names = try entries(nextTo: path)
    return names.contains { $0.hasSuffix(".lock") } ? "lock left behind: \(names)" : nil
}

check("a no-op mutation doesn't rewrite the file") {
    let path = try tempTodoPath()
    try write(path, "# Todo\n\n## P2 — Soon\n- [ ] Existing {id:t_a}\n")
    let before = try mtime(path)
    usleep(20_000)
    try withTodoFile(at: path) { _ in }
    return try mtime(path) == before ? nil : "file was rewritten"
}

check("a real change is written") {
    let path = try tempTodoPath()
    try write(path, "# Todo\n\n## P2 — Soon\n")
    let before = try mtime(path)
    usleep(20_000)
    try withTodoFile(at: path) { addTodo($0, AddInput(title: "New", added: "2026-09-27")) }
    return try mtime(path) != before ? nil : "file was not written"
}

check("a stale lock (older than 5 s) is cleared") {
    let path = try tempTodoPath()
    try write(path, "# Todo\n\n## P2 — Soon\n")
    let lock = path + ".lock"
    try write(lock, "")
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10)], ofItemAtPath: lock)
    try withTodoFile(at: path) { addTodo($0, AddInput(title: "After stale lock", added: "2026-09-27")) }
    return try itemTitles(path) == ["After stale lock"] ? nil : "add did not land"
}

check("10 concurrent in-process writers all land") {
    let path = try tempTodoPath()
    try write(path, "# Todo\n\n## P2 — Soon\n")
    let errors = NSMutableArray()
    DispatchQueue.concurrentPerform(iterations: 10) { i in
        do {
            try withTodoFile(at: path) { addTodo($0, AddInput(title: "Task \(i)", added: "2026-09-27")) }
        } catch {
            errors.add("\(error)")
        }
    }
    if errors.count > 0 { return "errors: \(errors)" }
    let titles = try itemTitles(path)
    let want = Set((0..<10).map { "Task \($0)" })
    return Set(titles) == want && titles.count == 10 ? nil : "got \(titles)"
}

check("Swift and the TypeScript server writing at once lose nothing") {
    let ioJS = projectDir.appendingPathComponent("mcp/dist/io.js").path
    guard FileManager.default.fileExists(atPath: ioJS) else { return "mcp/dist is missing — run `npm run build` in mcp/" }
    let path = try tempTodoPath()
    try write(path, "# Todo\n\n## P2 — Soon\n")
    let n = 30

    let node = Process()
    node.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    node.arguments = ["node", "--input-type=module", "-e", """
        const { withTodoFile } = await import(process.env.IO_JS);
        const { addTodo } = await import(process.env.OPS_JS);
        for (let i = 0; i < \(n); i++) {
          await withTodoFile(process.env.TODO_PATH, (doc) => addTodo(doc, { title: `node ${i}`, added: '2026-09-27' }));
          await new Promise((r) => setTimeout(r, 3));
        }
        """]
    var env = ProcessInfo.processInfo.environment
    env["IO_JS"] = ioJS
    env["OPS_JS"] = projectDir.appendingPathComponent("mcp/dist/ops.js").path
    env["TODO_PATH"] = path
    node.environment = env
    try node.run()

    // Start once node is actually writing, so the two really overlap.
    let deadline = Date().addingTimeInterval(10)
    while try itemTitles(path).isEmpty {
        if Date() > deadline { node.terminate(); return "node never wrote anything" }
        usleep(2_000)
    }
    for i in 0..<n {
        try withTodoFile(at: path) { addTodo($0, AddInput(title: "swift \(i)", added: "2026-09-27")) }
        usleep(3_000)
    }
    node.waitUntilExit()
    guard node.terminationStatus == 0 else { return "node exited with \(node.terminationStatus)" }

    let titles = try itemTitles(path)
    let want = Set((0..<n).map { "node \($0)" } + (0..<n).map { "swift \($0)" })
    guard Set(titles) == want, titles.count == 2 * n else {
        return "expected \(2 * n) distinct items, got \(titles.count): missing \(want.subtracting(titles).sorted())"
    }
    let origins = titles.map { $0.hasPrefix("node") }
    let switches = zip(origins, origins.dropFirst()).filter { $0 != $1 }.count
    return switches >= 2 ? nil : "writers didn't interleave (\(switches) switches) — the test proved nothing, retune timings"
}

// MARK: - List logic (E4.3, E4.4 badge)

func doc(_ text: String) -> Document { parseDocument(Array(text.utf8)) }
let monday = "2026-09-28" // a Monday

print("List logic:")

check("groups, effective priority, sort order, badge") {
    let d = doc("""
    # Todo

    ## P0 — Now
    - [ ] Urgent thing {id:t_1}

    ## P1 — This week
    - [ ] Overdue review {id:t_2 due:2026-09-26}
    - [ ] Due today {id:t_3 due:2026-09-28}
    - [ ] Friday send {id:t_4 due:2026-10-02}
    - [x] Done early {id:t_5 done:2026-09-27}

    ## P2 — Soon
    - [ ] Bad date {id:t_6 due:next-week}
    - [ ] Alpha {id:t_7}

    ## P3 — Someday

    ## Done
    - [ ] Unticked by hand {id:t_8}
    - [x] Old {id:t_9 done:2026-09-20}

    """)
    let s = makeSnapshot(d, today: monday)
    let got = s.groups.map { "\($0.title): \($0.items.compactMap(\.id))" }
    let want = ["Now: [\"t_2\", \"t_3\", \"t_1\"]", "This week: [\"t_4\"]", "Soon: [\"t_7\", \"t_6\", \"t_8\"]", "Someday: []"]
    if got != want { return "groups:\n  want \(want)\n  got  \(got)" }
    if s.done.compactMap(\.id) != ["t_5", "t_9"] { return "done: \(s.done.compactMap(\.id))" }
    return s.badge == Badge(count: 4, alert: true) ? nil : "badge: \(s.badge)"
}

check("due today counts toward the badge and sets the alert; due tomorrow doesn't; empty list is empty") {
    let s = makeSnapshot(doc("# Todo\n\n## P2 — Soon\n- [ ] x {id:t_1 due:2026-09-28}\n"), today: monday)
    if s.badge != Badge(count: 1, alert: true) { return "badge: \(s.badge)" }
    let t = makeSnapshot(doc("# Todo\n\n## P1 — This week\n- [ ] x {id:t_1 due:2026-09-29}\n"), today: monday)
    if t.badge != Badge(count: 1, alert: false) { return "tomorrow badge: \(t.badge)" }
    let e = makeSnapshot(doc(""), today: monday)
    return e.isEmpty && e.badge == Badge(count: 0, alert: false) && e.groups.count == 4 ? nil : "empty: \(e)"
}

check("relative due labels") {
    let posix = Locale(identifier: "en_US_POSIX")
    let cases: [(String?, String?)] = [
        ("2026-09-28", "Today"), ("2026-09-29", "Tomorrow"), ("2026-09-30", "Wed"), ("2026-10-04", "Sun"),
        ("2026-10-05", "Oct 5"), ("2026-09-27", "Overdue 1d"), ("2026-09-26", "Overdue 2d"),
        ("2027-01-03", "Jan 3, 2027"), ("next-week", "next-week"), ("2026-02-30", "2026-02-30"), (nil, nil),
    ]
    let wrong = cases.compactMap { due, want -> String? in
        let got = relativeDueLabel(due, today: monday, locale: posix)
        return got == want ? nil : "\(due ?? "nil"): want \(want ?? "nil"), got \(got ?? "nil")"
    }
    return wrong.isEmpty ? nil : wrong.joined(separator: "\n")
}

check("click targets (PRD §6.5)") {
    let todo = "/Users/me/AI Companion/data/TODO.md"
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let cases: [(String, String)] = [
        ("{id:t_1 link:https://github.com/x/pull/42}", "https://github.com/x/pull/42"),
        ("{id:t_1 link:vscode://file/Users/me/a.md:12}", "vscode://file/Users/me/a.md:12"),
        ("{id:t_1 link:thelist://session/abc}", "thelist://session/abc"),
        ("{id:t_1 link:/Users/me/Desktop/file.pdf}", "file:///Users/me/Desktop/file.pdf"),
        ("{id:t_1 link:\"~/Documents/x.md\"}", URL(fileURLWithPath: home + "/Documents/x.md").absoluteString),
        ("{id:t_1 link:\"vscode://file/Users/me/My Docs/a.md\"}", "vscode://file/Users/me/My%20Docs/a.md"),
        ("{id:t_1}", "vscode://file/Users/me/AI%20Companion/data/TODO.md:4"),
        ("{id:t_1 link:\"not a link\"}", "vscode://file/Users/me/AI%20Companion/data/TODO.md:4"),
    ]
    let wrong = cases.compactMap { block, want -> String? in
        let item = deriveViews(doc("# Todo\n\n## P2 — Soon\n- [ ] Task \(block)\n")).items[0]
        let got = clickTarget(for: item, todoPath: todo).absoluteString
        return got == want ? nil : "\(block): want \(want), got \(got)"
    }
    return wrong.isEmpty ? nil : wrong.joined(separator: "\n")
}

check("link kinds, and the file behind each for Show in Finder") {
    let todo = "/Users/me/AI Companion/data/TODO.md"
    let cases: [(String, String, String?)] = [ // metadata block, kind, file path
        ("{id:t_1 link:https://github.com/x/pull/42}", "web", nil),
        ("{id:t_1 link:HTTP://example.com}", "web", nil),
        ("{id:t_1 link:vscode://file/Users/me/a.md:12}", "vscodeFile", "/Users/me/a.md"),
        ("{id:t_1 link:vscode://file/Users/me/My%20Docs/a.md:12:3}", "vscodeFile", "/Users/me/My Docs/a.md"),
        ("{id:t_1 link:vscode://file/Users/me/plain.md}", "vscodeFile", "/Users/me/plain.md"),
        ("{id:t_1 link:\"/Users/me/Desk top/f.pdf\"}", "file", "/Users/me/Desk top/f.pdf"),
        ("{id:t_1 link:thelist://session/abc}", "other", nil),
        ("{id:t_1 link:vscode://extension/foo}", "other", nil),
        ("{id:t_1}", "todoLine", nil),
    ]
    let wrong = cases.compactMap { block, kind, path -> String? in
        let item = deriveViews(doc("# Todo\n\n## P2 — Soon\n- [ ] Task \(block)\n")).items[0]
        let t = linkTarget(for: item, todoPath: todo)
        let gotKind = switch t {
        case .web: "web"
        case .vscodeFile: "vscodeFile"
        case .file: "file"
        case .other: "other"
        case .todoLine: "todoLine"
        }
        return gotKind == kind && t.filePath == path ? nil : "\(block): want \(kind) \(path ?? "nil"), got \(gotKind) \(t.filePath ?? "nil")"
    }
    return wrong.isEmpty ? nil : wrong.joined(separator: "\n")
}

check("formatted days") {
    let posix = Locale(identifier: "en_US_POSIX")
    let got = [formattedDay("2026-09-26", today: monday, locale: posix), formattedDay("2027-01-03", today: monday, locale: posix),
               formattedDay("soon", today: monday, locale: posix)]
    return got == ["Sat, Sep 26", "Sun, Jan 3, 2027", "soon"] ? nil : "got \(got)"
}

// MARK: - File watcher (E4.4)

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [[UInt8]?] = []
    private let signal = DispatchSemaphore(value: 0)

    func record(_ bytes: [UInt8]?) {
        lock.lock(); events.append(bytes); lock.unlock()
        signal.signal()
    }

    /// The next event and how long it took, or nil on timeout.
    func next(within timeout: TimeInterval) -> (bytes: [UInt8]?, after: TimeInterval)? {
        let start = Date()
        guard signal.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return (events.removeFirst(), Date().timeIntervalSince(start))
    }
}

print("File watcher:")

check("notices every kind of outside change within 1 s, and ignores non-changes") {
    let path = try tempTodoPath()
    try write(path, "# Todo\n\n## P2 — Soon\n")
    let recorder = Recorder()
    let watcher = TodoFileWatcher(path: path) { recorder.record($0) }
    watcher.start()
    defer { watcher.stop() }
    usleep(200_000) // let the stream settle

    var problems: [String] = []
    func expectChange(_ what: String, _ act: () throws -> Void) throws {
        let startedAt = Date()
        try act()
        let actedFor = Date().timeIntervalSince(startedAt)
        guard let event = recorder.next(within: 1.0) else { problems.append("\(what): no event within 1 s"); return }
        let onDisk = try? bytes(URL(fileURLWithPath: path))
        if event.bytes != onDisk { problems.append("\(what): event bytes don't match the file") }
        print("       \(what): noticed \(Int((event.after + actedFor) * 1000)) ms after the write started")
        usleep(300_000)
        while recorder.next(within: 0) != nil {} // drain duplicates from the same write
    }

    try expectChange("atomic rename (the MCP server's write)") {
        _ = try withTodoFile(at: path) { addTodo($0, AddInput(title: "Renamed in", added: "2026-09-27")) }
    }
    try expectChange("in-place rewrite (an editor's save)") {
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try fh.truncate(atOffset: 0)
        try fh.write(contentsOf: Data("# Todo\n\n## P2 — Soon\n- [ ] Typed by hand\n".utf8))
        try fh.close()
    }
    let ioJS = projectDir.appendingPathComponent("mcp/dist/io.js").path
    if FileManager.default.fileExists(atPath: ioJS) {
        try expectChange("the real TypeScript server") {
            let node = Process()
            node.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            node.arguments = ["node", "--input-type=module", "-e", """
                const { withTodoFile } = await import(process.env.IO_JS);
                const { addTodo } = await import(process.env.OPS_JS);
                await withTodoFile(process.env.TODO_PATH, (doc) => addTodo(doc, { title: 'From node', added: '2026-09-27' }));
                """]
            var env = ProcessInfo.processInfo.environment
            env["IO_JS"] = ioJS
            env["OPS_JS"] = projectDir.appendingPathComponent("mcp/dist/ops.js").path
            env["TODO_PATH"] = path
            node.environment = env
            try node.run()
            node.waitUntilExit()
        }
    } else {
        problems.append("mcp/dist is missing — run `npm run build` in mcp/")
    }

    // Non-changes: a no-op write (takes and drops the lock), and a stray file in the folder.
    try withTodoFile(at: path) { _ in }
    try write(URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(".scratch.tmp").path, "x")
    if let spurious = recorder.next(within: 0.6) {
        problems.append("fired for a non-change (\(spurious.bytes?.count ?? -1) bytes)")
    }

    try expectChange("deleted") { try FileManager.default.removeItem(atPath: path) }
    return problems.isEmpty ? nil : problems.joined(separator: "\n")
}

// MARK: - Archive (E7.2, spec §3.6)

print("Archive:")

let archiveTodo = """
# Todo

## P1 — This week
- [ ] Still open, old due {id:t_open due:2026-08-01}
- [x] Ticked under P1, old {id:t_p1 done:2026-08-20}

## Done
- [x] Done 15 days ago {id:t_15 done:2026-09-13}
  with a body line
- [x] Done 14 days ago {id:t_14 done:2026-09-14}
- [x] Done yesterday {id:t_1 done:2026-09-27}
- [x] Bad date {id:t_bad done:sometime}
- [x] No done date {id:t_none}
* [X] Hand   formatted {done:2026-07-31   id:t_hand}

"""
let archiveTodoAfter = """
# Todo

## P1 — This week
- [ ] Still open, old due {id:t_open due:2026-08-01}

## Done
- [x] Done 14 days ago {id:t_14 done:2026-09-14}
- [x] Done yesterday {id:t_1 done:2026-09-27}
- [x] Bad date {id:t_bad done:sometime}
- [x] No done date {id:t_none}

"""
let sept15 = "- [x] Done 15 days ago {id:t_15 done:2026-09-13}\n  with a body line\n"

func archiveSetup(_ todo: String = archiveTodo) throws -> (todo: String, dir: String) {
    let todo_ = try tempTodoPath()
    try write(todo_, todo)
    return (todo_, URL(fileURLWithPath: todo_).deletingLastPathComponent().appendingPathComponent("archive").path)
}
func archived(_ dir: String, _ month: String) throws -> String? {
    let path = "\(dir)/\(month).md"
    return FileManager.default.fileExists(atPath: path) ? try read(path) : nil
}
func diff(_ what: String, _ want: String?, _ got: String?) -> String? {
    want == got ? nil : "\(what):\n  want \(String(reflecting: want))\n  got  \(String(reflecting: got))"
}

check("moves ticked items done more than 14 days ago, one file per month") {
    let (todo, dir) = try archiveSetup()
    let r = try archiveOldDone(todoPath: todo, archiveDir: dir, today: monday)
    let problems = [
        diff("moved ids", "[\"t_p1\", \"t_15\", \"t_hand\"]", "\(r.movedIds)"),
        diff("files", "[\"2026-07.md\", \"2026-08.md\", \"2026-09.md\"]", "\(r.filesWritten.map { URL(fileURLWithPath: $0).lastPathComponent })"),
        diff("TODO.md", archiveTodoAfter, try read(todo)),
        diff("2026-07", "# Archive — 2026-07\n\n* [X] Hand   formatted {done:2026-07-31   id:t_hand}\n", try archived(dir, "2026-07")),
        diff("2026-08", "# Archive — 2026-08\n\n- [x] Ticked under P1, old {id:t_p1 done:2026-08-20}\n", try archived(dir, "2026-08")),
        diff("2026-09", "# Archive — 2026-09\n\n" + sept15, try archived(dir, "2026-09")),
    ].compactMap { $0 }
    return problems.isEmpty ? nil : problems.joined(separator: "\n")
}

check("running again moves nothing and touches no file") {
    let (todo, dir) = try archiveSetup()
    try archiveOldDone(todoPath: todo, archiveDir: dir, today: monday)
    let before = try [todo, "\(dir)/2026-09.md"].map(mtime)
    usleep(20_000)
    let r = try archiveOldDone(todoPath: todo, archiveDir: dir, today: monday)
    if !r.movedIds.isEmpty || !r.filesWritten.isEmpty { return "second run: \(r)" }
    return try [todo, "\(dir)/2026-09.md"].map(mtime) == before ? nil : "a file was rewritten"
}

check("nothing old enough: no archive folder, TODO.md untouched") {
    let (todo, dir) = try archiveSetup("# Todo\n\n## Done\n- [x] Recent {id:t_r done:2026-09-27}\n")
    let before = try mtime(todo)
    usleep(20_000)
    try archiveOldDone(todoPath: todo, archiveDir: dir, today: monday)
    if FileManager.default.fileExists(atPath: dir) { return "archive folder was created" }
    return try mtime(todo) == before ? nil : "TODO.md was rewritten"
}

check("after a crash between the two writes, the item isn't archived twice") {
    let (todo, dir) = try archiveSetup()
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let alreadyArchived = "# Archive — 2026-09\n\n" + sept15
    try write("\(dir)/2026-09.md", alreadyArchived)
    try archiveOldDone(todoPath: todo, archiveDir: dir, today: monday)
    if let problem = diff("2026-09", alreadyArchived, try archived(dir, "2026-09")) { return problem }
    return try read(todo).contains("t_15") ? "t_15 is still in TODO.md" : nil
}

check("appends to an existing archive, adding a missing final newline") {
    let (todo, dir) = try archiveSetup()
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try write("\(dir)/2026-09.md", "# Archive — 2026-09\n\n- [x] Earlier {id:t_e done:2026-09-01}")
    try archiveOldDone(todoPath: todo, archiveDir: dir, today: monday)
    return diff("2026-09", "# Archive — 2026-09\n\n- [x] Earlier {id:t_e done:2026-09-01}\n" + sept15, try archived(dir, "2026-09"))
}

check("keeps a CRLF archive CRLF, with no stray blank line") {
    let (todo, dir) = try archiveSetup()
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try write("\(dir)/2026-09.md", "# Archive — 2026-09\r\n\r\n- [x] Earlier {id:t_e done:2026-09-01}\r\n")
    try archiveOldDone(todoPath: todo, archiveDir: dir, today: monday)
    return diff(
        "2026-09",
        "# Archive — 2026-09\r\n\r\n- [x] Earlier {id:t_e done:2026-09-01}\r\n- [x] Done 15 days ago {id:t_15 done:2026-09-13}\r\n  with a body line\r\n",
        try archived(dir, "2026-09")
    )
}

check("the window is configurable") {
    let (todo, dir) = try archiveSetup()
    let r = try archiveOldDone(todoPath: todo, archiveDir: dir, afterDays: 0, today: monday)
    return diff("moved ids", "[\"t_p1\", \"t_15\", \"t_14\", \"t_1\", \"t_hand\"]", "\(r.movedIds)")
}

// MARK: - Actions (E5)

print("Actions:")

func ref(_ path: String, title: String) throws -> ItemRef {
    ItemRef(deriveViews(try readTodoFile(at: path)).items.first { $0.title == title }!)
}

check("tick moves the item to the top of Done; untick puts it back") {
    let path = try tempTodoPath()
    try write(path, "# Todo\n\n## P1 — This week\n- [ ] Task A {id:t_a}\n- [ ] Task B {id:t_b}\n\n## Done\n- [x] Old {id:t_o done:2026-09-01}\n")
    guard try completeItem(todoPath: path, ref(path, title: "Task A"), today: monday) == .done else { return "complete refused" }
    if let d = diff("after tick", "# Todo\n\n## P1 — This week\n- [ ] Task B {id:t_b}\n\n## Done\n- [x] Task A {id:t_a done:2026-09-28}\n- [x] Old {id:t_o done:2026-09-01}\n", try read(path)) { return d }
    guard try reopenItem(todoPath: path, ref(path, title: "Task A"), priority: .p1) == .done else { return "reopen refused" }
    return diff("after untick", "# Todo\n\n## P1 — This week\n- [ ] Task B {id:t_b}\n- [ ] Task A {id:t_a}\n\n## Done\n- [x] Old {id:t_o done:2026-09-01}\n", try read(path))
}

check("a hand-typed item (no id yet) is found by line and title") {
    let path = try tempTodoPath()
    try write(path, "# Todo\n\n## P2 — Soon\n- [ ] Typed by hand\n")
    let r = try ref(path, title: "Typed by hand")
    if r.id != nil { return "expected no id before the write" }
    guard try completeItem(todoPath: path, r, today: monday) == .done else { return "complete refused" }
    let item = deriveViews(try readTodoFile(at: path)).items.first!
    return item.done && item.id != nil && item.meta["done"] == monday ? nil : "got \(item)"
}

check("a stale ref is refused and the item left alone") {
    let path = try tempTodoPath()
    try write(path, "# Todo\n\n## P2 — Soon\n- [ ] Typed by hand\n")
    let stale = try ref(path, title: "Typed by hand")
    try write(path, "# Todo\n\n## P2 — Soon\n- [ ] Someone added this first\n- [ ] Typed by hand\n") // line moved
    if try completeItem(todoPath: path, stale, today: monday) != .listChanged { return "hand-typed: expected listChanged" }
    if deriveViews(try readTodoFile(at: path)).items.contains(where: \.done) { return "hand-typed: something got ticked" }

    try write(path, "# Todo\n\n## P2 — Soon\n- [ ] Gone soon {id:t_g}\n")
    let gone = try ref(path, title: "Gone soon")
    try write(path, "# Todo\n\n## P2 — Soon\n")
    return try setPriority(todoPath: path, gone, .p0) == .listChanged ? nil : "removed item: expected listChanged"
}

check("change priority moves the item to the end of the new heading") {
    let path = try tempTodoPath()
    try write(path, "# Todo\n\n## P0 — Now\n- [ ] Urgent {id:t_u}\n\n## P2 — Soon\n- [ ] Task A {id:t_a}\n")
    try setPriority(todoPath: path, ref(path, title: "Task A"), .p0)
    return diff("file", "# Todo\n\n## P0 — Now\n- [ ] Urgent {id:t_u}\n- [ ] Task A {id:t_a}\n\n## P2 — Soon\n", try read(path))
}

check("quick-add adds at P2 with src:manual; a blank title does nothing") {
    let path = try tempTodoPath()
    try write(path, "# Todo\n\n## P2 — Soon\n")
    guard let id = try quickAdd(todoPath: path, title: "  Buy\nmilk  ", today: monday) else { return "nothing added" }
    if let d = diff("file", "# Todo\n\n## P2 — Soon\n- [ ] Buy milk {id:\(id) added:2026-09-28 src:manual}\n", try read(path)) { return d }
    let before = try read(path)
    if try quickAdd(todoPath: path, title: " \n ", today: monday) != nil { return "blank title was added" }
    return diff("after blank", before, try read(path))
}

// MARK: - Groups (E8.1–E8.3)

print("Groups:")

let testGroups = [
    TaskGroup(id: "byc", name: "BYC", projects: ["Solomon", "prismo"]),
    TaskGroup(id: "personal", name: "Personal projects", projects: ["personal"]),
]

func groupedDoc() -> Document {
    parseDocument(Array("""
    # Todo

    ## P0 — Now
    - [ ] Overdue personal {id:t_1 due:2026-09-01 group:personal}

    ## P1 — This week
    - [ ] Solomon review {id:t_2 project:SOLOMON}
    - [ ] Moved out of BYC {id:t_3 project:prismo group:Personal}

    ## P2 — Soon
    - [ ] Loose end {id:t_4}
    - [ ] Unknown group falls back {id:t_5 project:prismo group:gone}

    ## Done
    - [x] Shipped prismo {id:t_6 project:prismo done:2026-09-27}

    """.utf8))
}

check("effectiveGroup: explicit key, then project, then none; case-insensitive") {
    let items = deriveViews(groupedDoc()).items
    let got = items.map { effectiveGroup($0, groups: testGroups)?.id ?? "-" }
    let want = ["personal", "byc", "personal", "-", "byc", "byc"]
    return got == want ? nil : "expected \(want), got \(got)"
}

check("snapshot filters by group; the badge still counts every group") {
    let all = makeSnapshot(groupedDoc(), today: "2026-09-28", groups: testGroups)
    let byc = makeSnapshot(groupedDoc(), today: "2026-09-28", groups: testGroups, filter: .group("byc"))
    let loose = makeSnapshot(groupedDoc(), today: "2026-09-28", groups: testGroups, filter: .ungrouped)
    let titles = { (s: ListSnapshot) in s.groups.flatMap(\.items).map(\.title) }
    if titles(byc) != ["Solomon review", "Unknown group falls back"] { return "byc open: \(titles(byc))" }
    if byc.done.map(\.title) != ["Shipped prismo"] { return "byc done: \(byc.done.map(\.title))" }
    if titles(loose) != ["Loose end"] || !loose.done.isEmpty { return "ungrouped: \(titles(loose))" }
    if byc.badge != all.badge || all.badge != Badge(count: 3, alert: true) { return "badge: \(all.badge) vs \(byc.badge)" }
    let counts = all.openCounts
    if counts != [.all: 5, .group("byc"): 2, .group("personal"): 2, .ungrouped: 1] { return "counts: \(counts)" }
    if byc.filterName != "BYC" || byc.openCount != 2 { return "byc name/count: \(byc.filterName) \(byc.openCount)" }
    return nil
}

check("a filter for a group that's gone shows All") {
    let s = makeSnapshot(groupedDoc(), today: "2026-09-28", groups: testGroups, filter: .group("deleted"))
    if s.filter != .all || s.openCount != 5 { return "filter \(s.filter), \(s.openCount) open" }
    for f in [GroupFilter.all, .ungrouped, .group("byc")] where GroupFilter(storageKey: f.storageKey) != f {
        return "storage key round trip failed for \(f)"
    }
    return nil
}

check("readSettings: groups parsed, bad entries dropped, broken file gives defaults") {
    let path = settingsPath(forTodoPath: try tempTodoPath())
    if readSettings(path: path) != Settings() { return "missing file" }
    try write(path, #"{"proactive":false,"groups":[{"id":"byc","name":"BYC","projects":["solomon",3]},{"name":"no id"},{"id":"BYC"},{"id":"home"}]}"#)
    let want = Settings(proactive: false, groups: [
        TaskGroup(id: "byc", name: "BYC", projects: ["solomon"]), TaskGroup(id: "home", name: "home"),
    ])
    if readSettings(path: path) != want { return "parsed: \(readSettings(path: path))" }
    try write(path, "{ not json")
    return readSettings(path: path) == Settings() ? nil : "broken file"
}

check("addGroup keeps other keys, picks a unique id, and won't touch a broken file") {
    let path = settingsPath(forTodoPath: try tempTodoPath())
    try write(path, #"{"proactive":false,"petVisible":true,"groups":[{"id":"health","name":"Old health","projects":["gym"]}]}"#)
    let g = try addGroup(name: "  Health ", settingsPath: path)
    if g.id != "health-2" || g.name != "Health" { return "added \(g)" }
    let again = try addGroup(name: "health", settingsPath: path)
    if again != g { return "re-adding returned \(again)" }
    let s = readSettings(path: path)
    if s.proactive != false || s.groups.map(\.id) != ["health", "health-2"] || s.groups[0].projects != ["gym"] { return "\(s)" }
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
    if json["petVisible"] as? Bool != true { return "lost petVisible" }
    if groupSlug("Health & Fitness!") != "health-fitness" || groupSlug("???") != "group" { return "slug" }

    let fresh = settingsPath(forTodoPath: try tempTodoPath())
    _ = try addGroup(name: "BYC", settingsPath: fresh)
    if readSettings(path: fresh) != Settings(proactive: true, groups: [TaskGroup(id: "byc", name: "BYC")]) { return "fresh file" }

    try write(path, "{ half typed")
    do {
        _ = try addGroup(name: "X", settingsPath: path)
        return "wrote over a broken file"
    } catch {}
    return try read(path) == "{ half typed" ? nil : "broken file changed"
}

check("setGroup sets and clears the group key; quick-add files into a group") {
    let path = try tempTodoPath()
    try write(path, "# Todo\n\n## P2 — Soon\n- [ ] Task A {id:t_a project:prismo}\n")
    try setGroup(todoPath: path, ref(path, title: "Task A"), "personal")
    if let d = diff("set", "# Todo\n\n## P2 — Soon\n- [ ] Task A {id:t_a project:prismo group:personal}\n", try read(path)) { return d }
    try setGroup(todoPath: path, ref(path, title: "Task A"), nil)
    if let d = diff("cleared", "# Todo\n\n## P2 — Soon\n- [ ] Task A {id:t_a project:prismo}\n", try read(path)) { return d }
    guard let id = try quickAdd(todoPath: path, title: "Gym", group: "health", today: monday) else { return "nothing added" }
    return diff("quick-add", "# Todo\n\n## P2 — Soon\n- [ ] Task A {id:t_a project:prismo}\n- [ ] Gym {id:\(id) added:2026-09-28 group:health src:manual}\n", try read(path))
}

// MARK: - Reminders mapping (E8.4)

print("Reminders mapping:")

check("reminderDraft maps priority, due, link, notes and list") {
    let doc = parseDocument(Array("""
    # Todo

    ## P1 — This week
    - [ ] Review PR {id:t_r due:2026-10-05 project:solomon link:https://example.com/pr/1 note:"OCR first"}
      Check the fallback path.
    - [ ] Due today {id:t_t due:2026-09-28 link:"vscode://file/Users/me/My Docs/a.md:3"}

    ## P3 — Someday
    - [ ] Someday {id:t_s link:~/notes.md}
    - [ ] No id yet

    ## Done
    - [x] Shipped {id:t_d done:2026-09-27 group:personal}

    """.utf8))
    let items = deriveViews(doc).items
    let drafts = items.map { reminderDraft(for: $0, groups: testGroups, today: "2026-09-28") }

    guard let r = drafts[0] else { return "no draft for t_r" }
    let want = ReminderDraft(
        taskId: "t_r", title: "Review PR", listName: "The List · BYC", priority: 5,
        due: DateComponents(year: 2026, month: 10, day: 5), url: URL(string: "https://example.com/pr/1"),
        notes: "OCR first\n\nCheck the fallback path.\n\nThe List · t_r", completed: false
    )
    if r != want { return "t_r:\n\(r)\nwant:\n\(want)" }
    if drafts[1]?.priority != 1 || drafts[1]?.listName != "The List" { return "due today: \(String(describing: drafts[1]))" }
    if drafts[1]?.url?.absoluteString != "vscode://file/Users/me/My%20Docs/a.md:3" { return "vscode url: \(String(describing: drafts[1]?.url))" }
    if drafts[2]?.priority != 0 || drafts[2]?.url?.isFileURL != true || drafts[2]?.due != nil { return "someday: \(String(describing: drafts[2]))" }
    if drafts[3] != nil { return "an item without an id got a draft" }
    if drafts[4]?.completed != true || drafts[4]?.listName != "The List · Personal projects" { return "done: \(String(describing: drafts[4]))" }
    return nil
}

print("Agents waiting on me (E10.1):")

func scratchDir(_ name: String) -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("thelist-\(name)-\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

check("loadAgentWaits: blocked first then oldest; malformed, stale and temp files skipped") {
    let dir = scratchDir("waits")
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let now = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z")!
    func put(_ name: String, _ body: String) { FileManager.default.createFile(atPath: "\(dir)/\(name)", contents: Data(body.utf8)) }
    put("claude-a.json", #"{"agent":"claude","session":"a","state":"finished","reason":"","cwd":"/x/Old","at":"2026-10-19T11:00:00Z"}"#)
    put("codex-b.json", #"{"agent":"codex","session":"b","state":"waiting","reason":"needs permission","cwd":"/x/AI Companion","at":"2026-10-19T11:50:00Z"}"#)
    put("claude-c.json", #"{"agent":"claude","session":"c","state":"finished","cwd":"","at":"2026-10-19T11:30:00Z"}"#)
    put("claude-stale.json", #"{"agent":"claude","session":"s","state":"waiting","at":"2026-10-18T23:00:00Z"}"#)
    put("claude-bad.json", "{not json")
    put("claude-odd.json", #"{"agent":"claude","session":"o","state":"thinking","at":"2026-10-19T11:59:00Z"}"#)
    put(".tmp.abc", #"{"agent":"claude","session":"t","state":"waiting","at":"2026-10-19T11:59:00Z"}"#)
    let w = loadAgentWaits(dir: dir, now: now)
    if w.map(\.session) != ["b", "a", "c"] { return "order: \(w.map(\.session))" }
    if w[0].agentName != "Codex" || w[0].project != "AI Companion" || w[0].reason != "needs permission" { return "first: \(w[0])" }
    if w[2].project != "" || waitedFor(w[1].since, now: now) != "1h" || waitedFor(w[0].since, now: now) != "10m" { return "labels" }
    return loadAgentWaits(dir: dir + "/missing").isEmpty ? nil : "missing folder should be empty"
}

check("hooks/agent-status.sh keeps each session's latest state and deletes it when the session ends") {
    let data = scratchDir("hook")
    defer { try? FileManager.default.removeItem(atPath: data) }
    func run(_ args: [String], _ stdin: String) throws {
        let p = Process()
        p.executableURL = projectDir.appendingPathComponent("hooks/agent-status.sh")
        p.arguments = args
        p.environment = ["THE_LIST_DATA_DIR": data, "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        p.standardInput = pipe
        try p.run()
        pipe.fileHandleForWriting.write(Data(stdin.utf8))
        try pipe.fileHandleForWriting.close()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw NSError(domain: "hook exited \(p.terminationStatus)", code: 1) }
    }
    let event = #"{"session_id":"s-1","cwd":"/x/proj","hook_event_name":"PermissionRequest"}"#
    try run(["claude", "waiting", "needs permission"], event)
    var w = loadAgentWaits(dir: data + "/agents")
    if w.count != 1 || w[0].session != "s-1" || w[0].state != .waiting || w[0].project != "proj" { return "after waiting: \(w)" }
    try run(["claude", "finished"], event)
    w = loadAgentWaits(dir: data + "/agents")
    if w.count != 1 || w[0].state != .finished { return "after finished: \(w)" }
    try run(["claude", "working"], event)
    if !loadAgentWaits(dir: data + "/agents").isEmpty { return "working isn't waiting on me" }
    if loadAgentSessions(dir: data + "/agents").map(\.state) != [.working] { return "working should be kept" }
    let fail = #"{"session_id":"s-1","cwd":"/x/proj","error":"rate_limit","last_assistant_message":"You've hit your session limit · resets 3:45pm"}"#
    try run(["claude", "limited", "out of tokens"], fail)
    let l = loadAgentSessions(dir: data + "/agents")
    if l.map(\.state) != [.limited] || l.first?.resets != "3:45pm" { return "limited: \(l)" }
    try run(["claude", "pretool"], #"{"session_id":"s-1","tool_name":"AskUserQuestion"}"#)
    if loadAgentSessions(dir: data + "/agents").first?.reason != "has a question" { return "pretool on a question is waiting" }
    try run(["claude", "pretool"], #"{"session_id":"s-1","tool_name":"Bash"}"#)
    if loadAgentSessions(dir: data + "/agents").map(\.state) != [.working] { return "pretool on any other tool is working" }
    try run(["claude", "ended"], event)
    if !loadAgentSessions(dir: data + "/agents").isEmpty { return "ended should delete it" }
    try run(["codex", "waiting"], "not json")
    try run(["someone", "waiting"], event)
    return loadAgentWaits(dir: data + "/agents").isEmpty ? nil : "bad input or agent wrote a file"
}

print("Stickman poses (E11):")

check("agentPose: out of usage beats working beats idle; stale work and old failures don't count") {
    let now = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z")!
    func s(_ agent: String, _ state: AgentWait.State, minutesAgo: Double, cwd: String = "/x/proj", resets: String = "") -> AgentWait {
        AgentWait(agent: agent, session: UUID().uuidString, state: state, reason: "", cwd: cwd,
                  since: now.addingTimeInterval(-minutesAgo * 60), path: "", resets: resets)
    }
    let pose = { (sessions: [AgentWait]) in agentPose(agent: "claude", sessions: sessions, now: now) }
    if pose([]) != .sitting { return "no sessions" }
    if pose([s("claude", .working, minutesAgo: 2, cwd: "/x/AI Companion"), s("codex", .working, minutesAgo: 1)])
        != .running(project: "AI Companion") { return "working" }
    if pose([s("claude", .working, minutesAgo: 16)]) != .sitting { return "16 minutes of silence is idle" }
    if pose([s("claude", .finished, minutesAgo: 1), s("claude", .waiting, minutesAgo: 3)]) != .sitting { return "waiting on me sits" }
    if pose([s("claude", .limited, minutesAgo: 10, resets: "3:45pm"), s("claude", .working, minutesAgo: 30)])
        != .lying(resets: "3:45pm") { return "limited after the last work" }
    if pose([s("claude", .limited, minutesAgo: 10), s("claude", .working, minutesAgo: 1)])
        != .running(project: "proj") { return "working again clears it" }
    if pose([s("claude", .limited, minutesAgo: 6 * 60)]) != .sitting { return "an old failure expires" }
    let codex = AgentLimit(until: now.addingTimeInterval(600), resets: "12:10pm")
    if agentPose(agent: "codex", sessions: [s("codex", .working, minutesAgo: 1)], limit: codex, now: now)
        != .lying(resets: "12:10pm") { return "codex log limit" }
    return nil
}

check("codexLimit reads the last token_count line; full windows and reached flags count until reset") {
    let now = Date(timeIntervalSince1970: 1_792_400_000)
    func line(_ primary: Double, _ secondary: Double, reached: String?, primaryReset: Int = 1_792_402_927) -> String {
        let r = reached.map { "\"\($0)\"" } ?? "null"
        return #"{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"primary":{"used_percent":"#
            + "\(primary)" + #","window_minutes":300,"resets_at":"# + "\(primaryReset)" + #"},"secondary":{"used_percent":"#
            + "\(secondary)" + #","window_minutes":10080,"resets_at":1792882525},"rate_limit_reached_type":"# + r + "}}}"
    }
    let other = #"{"type":"event_msg","payload":{"type":"agent_message","message":"hi"}}"#
    if codexLimit(fromLogTail: [line(100, 50, reached: nil), line(48, 70, reached: nil), other].joined(separator: "\n"), now: now) != nil {
        return "only the last usage line counts"
    }
    guard let full = codexLimit(fromLogTail: line(100, 70, reached: nil), now: now),
          full.until == Date(timeIntervalSince1970: 1_792_402_927) else { return "primary at 100%" }
    guard let weekly = codexLimit(fromLogTail: line(40, 100, reached: "secondary"), now: now),
          weekly.until == Date(timeIntervalSince1970: 1_792_882_525) else { return "weekly reached" }
    if codexLimit(fromLogTail: line(100, 10, reached: nil, primaryReset: 1_792_399_000), now: now) != nil { return "a passed reset" }
    if codexLimit(fromLogTail: "not json\n" + other, now: now) != nil { return "no usage line" }
    return nil
}

check("newestCodexLog picks the log written to last, even in an older day folder; readTail keeps whole lines") {
    let root = scratchDir("codex")
    defer { try? FileManager.default.removeItem(atPath: root) }
    let fm = FileManager.default
    for (day, name) in [("2026/10/16", "rollout-2026-10-16T09-00-00-a.jsonl"), ("2026/10/18", "rollout-2026-10-18T08-00-00-b.jsonl"),
                        ("2026/10/18", "rollout-2026-10-18T17-00-00-c.jsonl"), ("2026/09/30", "rollout-2026-09-30T23-00-00-d.jsonl")] {
        try fm.createDirectory(atPath: "\(root)/\(day)", withIntermediateDirectories: true)
        fm.createFile(atPath: "\(root)/\(day)/\(name)", contents: Data("x\n".utf8))
    }
    fm.createFile(atPath: "\(root)/2026/10/18/notes.txt", contents: Data())
    // The conversation that started on the 16th is the one still being written to.
    let base = Date(timeIntervalSince1970: 1_792_300_000)
    for (path, minutes) in [("2026/10/16/rollout-2026-10-16T09-00-00-a.jsonl", 90.0), ("2026/10/18/rollout-2026-10-18T08-00-00-b.jsonl", 10),
                            ("2026/10/18/rollout-2026-10-18T17-00-00-c.jsonl", 30), ("2026/09/30/rollout-2026-09-30T23-00-00-d.jsonl", 0)] {
        try fm.setAttributes([.modificationDate: base.addingTimeInterval(minutes * 60)], ofItemAtPath: "\(root)/\(path)")
    }
    guard let newest = newestCodexLog(sessionsDir: root), newest.hasSuffix("2026/10/16/rollout-2026-10-16T09-00-00-a.jsonl") else {
        return "newest: \(String(describing: newestCodexLog(sessionsDir: root)))"
    }
    if newestCodexLog(sessionsDir: root + "/missing") != nil { return "missing folder" }
    let log = "\(root)/tail.jsonl"
    fm.createFile(atPath: log, contents: Data((String(repeating: "a", count: 50) + "\nsecond\nthird\n").utf8))
    if readTail(path: log, bytes: 16) != "second\nthird\n" { return "tail: \(String(describing: readTail(path: log, bytes: 16)))" }
    return readTail(path: log)?.hasPrefix("aaaa") == true ? nil : "a short file is read whole"
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
