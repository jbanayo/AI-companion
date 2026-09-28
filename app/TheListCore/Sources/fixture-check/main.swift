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

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
