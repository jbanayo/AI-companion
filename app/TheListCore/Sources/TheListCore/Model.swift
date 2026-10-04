/// Types shared across the parser, renderer, and operations. Mirrors spec/format.md and mcp/src/model.ts.

public enum LineEnding: String, Sendable {
    case lf, crlf
}

public enum Section: String, Sendable, CaseIterable {
    case p0 = "P0", p1 = "P1", p2 = "P2", p3 = "P3", done = "Done"
}

public enum Priority: String, Sendable, CaseIterable {
    case p0 = "P0", p1 = "P1", p2 = "P2", p3 = "P3"

    public var section: Section {
        switch self {
        case .p0: .p0
        case .p1: .p1
        case .p2: .p2
        case .p3: .p3
        }
    }
}

/// The known metadata keys, in the canonical order spec §3.3 requires on render.
public let knownKeys = ["due", "done", "added", "project", "group", "src", "link", "note"]

/// Metadata pairs with JavaScript `Map` semantics: setting an existing key keeps its position.
/// Unknown keys are written back in this order, so it has to survive edits.
public struct Meta: Equatable, Sendable {
    public private(set) var keys: [String] = []
    private var values: [String: String] = [:]

    public init() {}

    public subscript(key: String) -> String? {
        get { values[key] }
        set {
            if let newValue {
                if values[key] == nil { keys.append(key) }
                values[key] = newValue
            } else if values.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var dictionary: [String: String] { values }
}

public struct ItemFields: Sendable {
    public var title: String
    public var id: String?
    /// Every metadata key except `id`, in original encounter order.
    public var meta: Meta
    public var done: Bool
}

public final class ItemNode {
    public var raw: String
    public var touched: Bool
    public var fields: ItemFields
    /// Exact original text of each body line, indentation included. Never rewritten.
    public var body: [String]

    init(raw: String, touched: Bool, fields: ItemFields, body: [String]) {
        self.raw = raw
        self.touched = touched
        self.fields = fields
        self.body = body
    }
}

public enum Node {
    /// `section` is nil for an unrecognized heading (e.g. "## Ideas").
    case heading(raw: String, section: Section?)
    case item(ItemNode)
    /// Blank lines, `# Todo`, prose, malformed items. Always passed through verbatim.
    case other(String)
}

public final class Document {
    public var lineEnding: LineEnding
    public var finalNewline: Bool
    public var bom: Bool
    public var nodes: [Node]

    init(lineEnding: LineEnding, finalNewline: Bool, bom: Bool, nodes: [Node]) {
        self.lineEnding = lineEnding
        self.finalNewline = finalNewline
        self.bom = bom
        self.nodes = nodes
    }
}

/// Read-only item shape handed to the UI. Matches the parse fixtures' expected.json `items[]`.
public struct ItemView: Equatable, Sendable {
    public let line: Int
    public let section: Section?
    public let priority: Section
    public let done: Bool
    public let title: String
    public let id: String?
    public let meta: [String: String]
    public let body: [String]
}

public struct HeadingView: Equatable, Sendable {
    public let line: Int
    public let raw: String
    public let section: Section?
}

let canonicalHeading: [Section: String] = [
    .p0: "## P0 — Now",
    .p1: "## P1 — This week",
    .p2: "## P2 — Soon",
    .p3: "## P3 — Someday",
    .done: "## Done",
]

/// Order sections are inserted in when a heading is missing (spec §3.4).
let sectionOrder: [Section] = [.p0, .p1, .p2, .p3, .done]

let emptySkeleton = "# Todo\n\n## P0 — Now\n\n## P1 — This week\n\n## P2 — Soon\n\n## P3 — Someday\n\n## Done\n"
