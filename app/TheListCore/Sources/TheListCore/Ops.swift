// Mirrors mcp/src/ops.ts (every operation except the MCP-only duplicate check).
import Foundation

public func generateId() -> String {
    String(format: "t_%04x", UInt16.random(in: .min ... .max))
}

/// Today's date in the local timezone, `YYYY-MM-DD`.
public func today(_ date: Date = Date(), calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
}

/// Strips newlines from a free-text field so the rendered line can never split in two.
func sanitizeText(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    var inBreak = false
    for c in s.unicodeScalars {
        if c == "\r" || c == "\n" {
            if !inBreak { out.append(" ") }
            inBreak = true
        } else {
            out.append(c)
            inBreak = false
        }
    }
    return jsTrim(String(out))
}

private func isBlank(_ node: Node?) -> Bool {
    guard let node else { return true }
    if case let .other(raw) = node { return jsTrim(raw).isEmpty }
    return false
}

private func isHeading(_ node: Node, _ section: Section) -> Bool {
    if case let .heading(_, s) = node { return s == section }
    return false
}

func isEffectivelyEmpty(_ doc: Document) -> Bool {
    doc.nodes.allSatisfy { node in
        if case let .other(raw) = node { return jsTrim(raw).isEmpty }
        return false
    }
}

/// Spec §3.4 "Empty file": replace with the skeleton before inserting, and reset to lf with a final newline.
func ensureSkeleton(_ doc: Document) {
    guard isEffectivelyEmpty(doc) else { return }
    doc.nodes = parseDocument(Array(emptySkeleton.utf8)).nodes
    doc.lineEnding = .lf
    doc.finalNewline = true
    doc.bom = false
}

/// Finds or creates the first heading for `section`.
private func ensureSectionHeading(_ doc: Document, _ section: Section) -> (index: Int, created: Bool, atEnd: Bool) {
    if let existing = doc.nodes.firstIndex(where: { isHeading($0, section) }) {
        return (existing, false, false)
    }
    let pos = sectionOrder.firstIndex(of: section)!
    for later in sectionOrder[(pos + 1)...] {
        if let idx = doc.nodes.firstIndex(where: { isHeading($0, later) }) {
            doc.nodes.insert(.heading(raw: canonicalHeading[section]!, section: section), at: idx)
            return (idx, true, false)
        }
    }
    if !doc.nodes.isEmpty, !isBlank(doc.nodes.last) { doc.nodes.append(.other("")) }
    doc.nodes.append(.heading(raw: canonicalHeading[section]!, section: section))
    return (doc.nodes.count - 1, true, true)
}

/// Index just past the last item in the section's first run, or just past the heading if it has none.
private func endOfSectionRun(_ doc: Document, _ headingIndex: Int) -> Int {
    var insertAt = headingIndex + 1
    for i in (headingIndex + 1)..<doc.nodes.count {
        switch doc.nodes[i] {
        case .heading: return insertAt
        case .item: insertAt = i + 1
        case .other: break
        }
    }
    return insertAt
}

private enum Position { case top, end }

private func insert(_ doc: Document, _ section: Section, _ item: ItemNode, _ position: Position) {
    let (index, created, atEnd) = ensureSectionHeading(doc, section)
    let idx = position == .top ? index + 1 : endOfSectionRun(doc, index)
    doc.nodes.insert(.item(item), at: idx)
    if created, !atEnd { doc.nodes.insert(.other(""), at: idx + 1) }
}

private func findItemIndex(_ doc: Document, _ id: String) -> Int? {
    doc.nodes.firstIndex { node in
        if case let .item(item) = node { return item.fields.id == id }
        return false
    }
}

private func item(at index: Int, in doc: Document) -> ItemNode {
    guard case let .item(item) = doc.nodes[index] else { preconditionFailure("not an item at \(index)") }
    return item
}

private func collectIds(_ doc: Document) -> Set<String> {
    var used = Set<String>()
    for case let .item(item) in doc.nodes {
        if let id = item.fields.id { used.insert(id) }
    }
    return used
}

/// An id not already in `used`; the ones skipped are consumed (spec §2.7).
private func uniqueId(_ used: inout Set<String>, _ idGen: () -> String) -> String {
    var id = idGen()
    while used.contains(id) { id = idGen() }
    used.insert(id)
    return id
}

/// Every operation runs this first (spec §3.2). Idempotent.
public func assignMissingIds(_ doc: Document, idGen: () -> String = generateId) {
    var used = collectIds(doc)
    for case let .item(item) in doc.nodes where item.fields.id == nil {
        item.fields.id = uniqueId(&used, idGen)
        item.touched = true
    }
}

public struct AddInput: Sendable {
    public var title: String
    public var priority: Priority?
    public var due: String?
    public var project: String?
    public var src: String?
    public var link: String?
    public var note: String?
    public var added: String?

    public init(title: String, priority: Priority? = nil, due: String? = nil, project: String? = nil,
                src: String? = nil, link: String? = nil, note: String? = nil, added: String? = nil) {
        self.title = title
        self.priority = priority
        self.due = due
        self.project = project
        self.src = src
        self.link = link
        self.note = note
        self.added = added
    }
}

private func nonEmpty(_ s: String?) -> String? {
    guard let s, !s.isEmpty else { return nil }
    return s
}

@discardableResult
public func addTodo(_ doc: Document, _ input: AddInput, idGen: () -> String = generateId) -> ItemNode {
    ensureSkeleton(doc)
    var meta = Meta()
    if let due = nonEmpty(input.due) { meta["due"] = due }
    meta["added"] = input.added ?? today()
    if let project = nonEmpty(input.project) { meta["project"] = sanitizeText(project) }
    meta["src"] = input.src ?? "manual"
    if let link = nonEmpty(input.link) { meta["link"] = sanitizeText(link) }
    if let note = nonEmpty(input.note) { meta["note"] = sanitizeText(note) }

    var used = collectIds(doc)
    let item = ItemNode(
        raw: "",
        touched: true,
        fields: ItemFields(title: sanitizeText(input.title), id: uniqueId(&used, idGen), meta: meta, done: false),
        body: []
    )
    insert(doc, (input.priority ?? .p2).section, item, .end)
    return item
}

@discardableResult
public func completeTodo(_ doc: Document, id: String, date: String) -> ItemNode? {
    guard let idx = findItemIndex(doc, id) else { return nil }
    let item = item(at: idx, in: doc)
    doc.nodes.remove(at: idx)
    item.fields.done = true
    item.fields.meta["done"] = date
    item.touched = true
    insert(doc, .done, item, .top)
    return item
}

@discardableResult
public func reopenTodo(_ doc: Document, id: String, priority: Priority = .p2) -> ItemNode? {
    guard let idx = findItemIndex(doc, id) else { return nil }
    let item = item(at: idx, in: doc)
    doc.nodes.remove(at: idx)
    item.fields.done = false
    item.fields.meta["done"] = nil
    item.touched = true
    insert(doc, priority.section, item, .end)
    return item
}

/// A field in an update: leave it, remove it (`null` in the MCP tool), or set it.
public enum FieldChange: Equatable, Sendable {
    case keep, remove, set(String)
}

public struct UpdateFields: Sendable {
    public var title: String?
    public var priority: Priority?
    public var due: FieldChange = .keep
    public var project: FieldChange = .keep
    public var link: FieldChange = .keep
    public var note: FieldChange = .keep

    public init(title: String? = nil, priority: Priority? = nil, due: FieldChange = .keep,
                project: FieldChange = .keep, link: FieldChange = .keep, note: FieldChange = .keep) {
        self.title = title
        self.priority = priority
        self.due = due
        self.project = project
        self.link = link
        self.note = note
    }
}

private func currentSection(_ doc: Document, _ itemIndex: Int) -> Section? {
    for i in stride(from: itemIndex, through: 0, by: -1) {
        if case let .heading(_, section) = doc.nodes[i] { return section }
    }
    return nil
}

@discardableResult
public func updateTodo(_ doc: Document, id: String, _ fields: UpdateFields) -> ItemNode? {
    guard let idx = findItemIndex(doc, id) else { return nil }
    let item = item(at: idx, in: doc)

    if let title = fields.title { item.fields.title = sanitizeText(title) }
    for (key, change) in [("due", fields.due), ("project", fields.project), ("link", fields.link), ("note", fields.note)] {
        switch change {
        case .keep: break
        case .remove: item.fields.meta[key] = nil
        case let .set(value): item.fields.meta[key] = sanitizeText(value)
        }
    }
    item.touched = true

    if let priority = fields.priority, priority.section != currentSection(doc, idx) {
        doc.nodes.remove(at: idx)
        insert(doc, priority.section, item, .end)
    }
    return item
}

@discardableResult
public func removeTodo(_ doc: Document, id: String) -> Bool {
    guard let idx = findItemIndex(doc, id) else { return false }
    doc.nodes.remove(at: idx)
    return true
}
