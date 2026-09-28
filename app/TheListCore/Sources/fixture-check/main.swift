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
                    due: item["due"] as? String, project: item["project"] as? String, src: item["src"] as? String,
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
                    due: change(f, "due"), project: change(f, "project"), link: change(f, "link"), note: change(f, "note")
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

check("due today counts toward the badge but isn't overdue; empty list is empty") {
    let s = makeSnapshot(doc("# Todo\n\n## P2 — Soon\n- [ ] x {id:t_1 due:2026-09-28}\n"), today: monday)
    if s.badge != Badge(count: 1, alert: false) { return "badge: \(s.badge)" }
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

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
