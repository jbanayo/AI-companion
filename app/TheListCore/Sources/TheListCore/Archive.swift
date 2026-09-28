// E7.2 / PRD D5 / spec §3.6: move old Done items out of TODO.md into data/archive/YYYY-MM.md.
import Foundation

public struct ArchiveResult: Equatable, Sendable {
    /// Ids removed from TODO.md, in file order.
    public let movedIds: [String]
    /// Archive files that were written, sorted.
    public let filesWritten: [String]
}

/// Moves every ticked item whose `done` date is more than `afterDays` days before `today` into
/// `archiveDir/YYYY-MM.md` (the month it was completed). Runs under the TODO.md lock.
///
/// The archive is written before TODO.md, so a crash in between leaves an item in both places,
/// never neither. An item whose id is already in its archive file isn't appended again, so the
/// next run just finishes removing it — running this any number of times is safe.
@discardableResult
public func archiveOldDone(
    todoPath: String,
    archiveDir: String,
    afterDays: Int = 14,
    today: String = today()
) throws -> ArchiveResult {
    precondition(isValidDate(today), "today must be YYYY-MM-DD, got \(today)")

    return try withTodoFile(at: todoPath) { doc in
        var byMonth: [String: [ItemNode]] = [:]
        var moved: [ItemNode] = []
        for case let .item(item) in doc.nodes where item.fields.done {
            // No real `done` date means no way to tell its age: it stays (spec §2.6).
            guard let done = item.fields.meta["done"], let age = daysBetween(done, today), age > afterDays else { continue }
            byMonth[String(done.prefix(7)), default: []].append(item)
            moved.append(item)
        }
        guard !moved.isEmpty else { return ArchiveResult(movedIds: [], filesWritten: []) }

        try FileManager.default.createDirectory(atPath: archiveDir, withIntermediateDirectories: true)
        var written: [String] = []
        for month in byMonth.keys.sorted() {
            let path = URL(fileURLWithPath: archiveDir).appendingPathComponent("\(month).md").path
            if try appendToArchive(path: path, month: month, items: byMonth[month]!) { written.append(path) }
        }

        let movedSet = Set(moved.map(ObjectIdentifier.init))
        doc.nodes.removeAll { node in
            if case let .item(item) = node { return movedSet.contains(ObjectIdentifier(item)) }
            return false
        }
        return ArchiveResult(movedIds: moved.compactMap(\.fields.id), filesWritten: written)
    }
}

/// Appends the items not already in the file. Returns whether the file was written.
private func appendToArchive(path: String, month: String, items: [ItemNode]) throws -> Bool {
    let existing: [UInt8]?
    do {
        existing = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        existing = nil
    }

    let archived = existing.map(parseDocument)
    var alreadyThere = Set<String>()
    if let archived {
        for case let .item(item) in archived.nodes {
            if let id = item.fields.id { alreadyThere.insert(id) }
        }
    }
    let fresh = items.filter { $0.fields.id.map { !alreadyThere.contains($0) } ?? true }
    guard !fresh.isEmpty else { return false }

    let eol = archived?.lineEnding == .crlf ? "\r\n" : "\n"
    var text = existing.map { String(decoding: $0, as: UTF8.self) } ?? "# Archive — \(month)\n\n"
    // Scalar check, not hasSuffix: Swift treats "\r\n" as one Character, so "…\r\n".hasSuffix("\n") is false.
    if let last = text.unicodeScalars.last, last != "\n" { text += eol }
    text += fresh.flatMap(itemLines).joined(separator: eol) + eol
    try writeFileAtomic(path, Array(text.utf8))
    return true
}
