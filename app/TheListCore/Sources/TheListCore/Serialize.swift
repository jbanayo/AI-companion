// Mirrors mcp/src/render.ts and mcp/src/serialize.ts.

/// Quote a value if it needs it, per spec §3.3.
func renderValue(_ value: String) -> String {
    let v = scalars(value)
    let needsQuotes = v.isEmpty || v.contains { isJSWhitespace($0) || $0 == "{" || $0 == "}" || $0 == "\"" }
    guard needsQuotes else { return value }
    var out = String.UnicodeScalarView()
    out.append("\"")
    for c in v {
        if c == "\\" || c == "\"" { out.append("\\") }
        out.append(c)
    }
    out.append("\"")
    return String(out)
}

/// Renders one item line in canonical form (spec §3.3). Never touches body lines.
func renderItemLine(_ fields: ItemFields) -> String {
    var pairs: [String] = []
    if let id = fields.id, !id.isEmpty { pairs.append("id:\(renderValue(id))") }
    for key in knownKeys {
        if let v = fields.meta[key] { pairs.append("\(key):\(renderValue(v))") }
    }
    for key in fields.meta.keys where !knownKeys.contains(key) {
        pairs.append("\(key):\(renderValue(fields.meta[key]!))")
    }
    let checkbox = fields.done ? "[x]" : "[ ]"
    let suffix = pairs.isEmpty ? "" : " {\(pairs.joined(separator: " "))}"
    return "- \(checkbox) \(fields.title)\(suffix)"
}

/// The item line (re-rendered only if touched) followed by its body lines, unchanged.
func itemLines(_ item: ItemNode) -> [String] {
    [item.touched ? renderItemLine(item.fields) : item.raw] + item.body
}

/// Rebuilds the file bytes. Untouched nodes come out byte-for-byte; only touched item lines are re-rendered.
public func serialize(_ doc: Document) -> [UInt8] {
    let eol = doc.lineEnding == .crlf ? "\r\n" : "\n"
    var lines: [String] = []

    for node in doc.nodes {
        switch node {
        case let .heading(raw, _), let .other(raw):
            lines.append(raw)
        case let .item(item):
            lines.append(contentsOf: itemLines(item))
        }
    }

    var text = lines.joined(separator: eol)
    if doc.finalNewline, !lines.isEmpty { text += eol }
    if doc.bom { text = "\u{FEFF}" + text }
    return Array(text.utf8)
}
