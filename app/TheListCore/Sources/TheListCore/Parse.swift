// Mirrors mcp/src/parse.ts. Works on Unicode scalars, never Characters: Swift treats "\r\n" as a
// single Character, so splitting or suffix-checking at the Character level would mis-handle CRLF.

typealias Scalars = [Unicode.Scalar]

func scalars(_ s: String) -> Scalars { Array(s.unicodeScalars) }

func string<S: Sequence>(_ s: S) -> String where S.Element == Unicode.Scalar {
    var v = String.UnicodeScalarView()
    v.append(contentsOf: s)
    return String(v)
}

func isSpaceOrTab(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" }

/// Exactly the set JavaScript's `\s` and `String.prototype.trim` treat as whitespace.
func isJSWhitespace(_ c: Unicode.Scalar) -> Bool {
    switch c.value {
    case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
        true
    default:
        false
    }
}

func jsTrim(_ s: String) -> String {
    let v = scalars(s)
    guard let start = v.firstIndex(where: { !isJSWhitespace($0) }),
          let end = v.lastIndex(where: { !isJSWhitespace($0) }) else { return "" }
    return string(v[start...end])
}

func trimTrailingSpaceOrTab(_ v: ArraySlice<Unicode.Scalar>) -> ArraySlice<Unicode.Scalar> {
    var v = v
    while let last = v.last, isSpaceOrTab(last) { v.removeLast() }
    return v
}

private func isASCIIWordChar(_ c: Unicode.Scalar) -> Bool {
    switch c {
    case "a"..."z", "A"..."Z", "0"..."9", "_": true
    default: false
    }
}

private func asciiUpper(_ c: Unicode.Scalar) -> Unicode.Scalar {
    ("a"..."z").contains(c) ? Unicode.Scalar(c.value - 32)! : c
}

private let headingKeys: [(Scalars, Section)] = [
    (scalars("P0"), .p0), (scalars("P1"), .p1), (scalars("P2"), .p2), (scalars("P3"), .p3), (scalars("DONE"), .done),
]

/// Spec §2.2/§2.3: `## ` prefix, then `^(P0|P1|P2|P3|Done)\b`, case-insensitive, ASCII word boundary.
/// Returns nil if the line isn't a heading; `.some(nil)` for an unknown heading.
private func headingSection(_ line: Scalars) -> Section?? {
    guard line.count >= 3, line[0] == "#", line[1] == "#", line[2] == " " else { return nil }
    let rest = line[3...]
    for (key, section) in headingKeys {
        guard rest.count >= key.count else { continue }
        let matches = zip(rest, key).allSatisfy { asciiUpper($0) == $1 }
        guard matches else { continue }
        let after = rest.index(rest.startIndex, offsetBy: key.count)
        if after == rest.endIndex || !isASCIIWordChar(rest[after]) { return .some(section) }
    }
    return .some(nil)
}

/// Spec §2.2: `^[-*+][ \t]+\[( |x|X)\][ \t]+(.+)$`. JavaScript's `.` excludes line terminators,
/// so a line with a stray \r, U+2028 or U+2029 after the checkbox isn't an item.
private func itemParts(_ line: Scalars) -> (done: Bool, content: Scalars)? {
    guard let first = line.first, first == "-" || first == "*" || first == "+" else { return nil }
    var i = 1
    let spacesStart = i
    while i < line.count, isSpaceOrTab(line[i]) { i += 1 }
    guard i > spacesStart, i + 3 <= line.count, line[i] == "[", line[i + 2] == "]" else { return nil }
    let box = line[i + 1]
    guard box == " " || box == "x" || box == "X" else { return nil }
    i += 3
    let gapStart = i
    while i < line.count, isSpaceOrTab(line[i]) { i += 1 }
    guard i > gapStart, i < line.count else { return nil } // nothing after the gap: no title, not an item
    let content = Array(line[i...])
    if content.contains(where: { $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" }) { return nil }
    return (box != " ", content)
}

/// Spec §2.5: the block is the shortest trailing `{...}`, preceded by whitespace, that parses fully.
/// Candidates are tried rightmost first and validated by the grammar, not by counting braces.
func parseMetadata(_ content: Scalars) -> (title: String, meta: Meta) {
    let stripped = trimTrailingSpaceOrTab(content[...])
    let fallback = (jsTrim(string(content)), Meta())
    guard stripped.last == "}" else { return fallback }

    let base = stripped.startIndex
    let candidates = stripped.indices.dropFirst().filter { stripped[$0] == "{" && isSpaceOrTab(stripped[$0 - 1]) }
    for open in candidates.reversed() {
        guard let meta = parseBlock(Array(stripped[(open + 1)..<(stripped.endIndex - 1)])) else { continue }
        let title = trimTrailingSpaceOrTab(stripped[base..<open])
        if title.isEmpty { break }
        return (string(title), meta)
    }
    return fallback
}

/// Returns nil if the block content doesn't fully parse as `pair (ws+ pair)*`.
func parseBlock(_ block: Scalars) -> Meta? {
    var meta = Meta()
    var i = 0
    let n = block.count

    while i < n {
        while i < n, isSpaceOrTab(block[i]) { i += 1 }
        if i >= n { break }

        let keyStart = i
        guard ("a"..."z").contains(block[i]) else { return nil }
        i += 1
        while i < n, ("a"..."z").contains(block[i]) || ("0"..."9").contains(block[i]) || block[i] == "_" { i += 1 }
        let key = string(block[keyStart..<i])

        while i < n, isSpaceOrTab(block[i]) { i += 1 }
        guard i < n, block[i] == ":" else { return nil }
        i += 1
        while i < n, isSpaceOrTab(block[i]) { i += 1 }

        var value = String.UnicodeScalarView()
        if i < n, block[i] == "\"" {
            i += 1
            var closed = false
            while i < n {
                if block[i] == "\\", i + 1 < n, block[i + 1] == "\"" || block[i + 1] == "\\" {
                    value.append(block[i + 1])
                    i += 2
                } else if block[i] == "\"" {
                    i += 1
                    closed = true
                    break
                } else {
                    value.append(block[i])
                    i += 1
                }
            }
            guard closed else { return nil }
        } else {
            let valueStart = i
            while i < n, !(isSpaceOrTab(block[i]) || block[i] == "{" || block[i] == "}" || block[i] == "\"") { i += 1 }
            guard i > valueStart else { return nil } // empty bare value is not valid
            value.append(contentsOf: block[valueStart..<i])
        }

        meta[key] = String(value) // last one wins on duplicate keys
    }

    return meta
}

public func parseDocument(_ raw: [UInt8]) -> Document {
    var text = Array(String(decoding: raw, as: UTF8.self).unicodeScalars)
    let bom = text.first == "\u{FEFF}"
    if bom { text.removeFirst() }

    // Spec §2.1: the first line's ending decides the whole file.
    let firstNewline = text.firstIndex(of: "\n")
    let lineEnding: LineEnding = if let nl = firstNewline, nl > 0, text[nl - 1] == "\r" { .crlf } else { .lf }
    let finalNewline = text.last == "\n"

    var lines: [Scalars] = text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map {
        var line = Array($0)
        if line.last == "\r" { line.removeLast() }
        return line
    }
    if lines.last?.isEmpty == true { lines.removeLast() }

    var nodes: [Node] = []
    var seenIds = Set<String>()
    var currentItem: ItemNode?

    for line in lines {
        let raw = string(line)

        if let section = headingSection(line) {
            nodes.append(.heading(raw: raw, section: section))
            currentItem = nil
            continue
        }

        if let parts = itemParts(line) {
            var (title, meta) = parseMetadata(parts.content)
            if title.isEmpty {
                nodes.append(.other(raw))
                currentItem = nil
                continue
            }
            var id = meta["id"]
            meta["id"] = nil
            if let existing = id {
                if seenIds.contains(existing) { id = nil } else { seenIds.insert(existing) }
            }
            let node = ItemNode(raw: raw, touched: false, fields: ItemFields(title: title, id: id, meta: meta, done: parts.done), body: [])
            nodes.append(.item(node))
            currentItem = node
            continue
        }

        if let item = currentItem, let first = line.first, isSpaceOrTab(first), !jsTrim(raw).isEmpty {
            item.body.append(raw)
            continue
        }

        // Any other line breaks the "directly after" chain (spec §2.2).
        nodes.append(.other(raw))
        currentItem = nil
    }

    return Document(lineEnding: lineEnding, finalNewline: finalNewline, bom: bom, nodes: nodes)
}

private func effectivePriority(_ section: Section?) -> Section {
    section ?? .p2
}

/// Derives the read-only heading and item views (the expected.json shape).
public func deriveViews(_ doc: Document) -> (headings: [HeadingView], items: [ItemView]) {
    var headings: [HeadingView] = []
    var items: [ItemView] = []
    var currentSection: Section?
    var lineNo = 0

    for node in doc.nodes {
        lineNo += 1
        switch node {
        case let .heading(raw, section):
            currentSection = section
            headings.append(HeadingView(line: lineNo, raw: raw, section: section))
        case let .item(item):
            items.append(ItemView(
                line: lineNo,
                section: currentSection,
                priority: effectivePriority(currentSection),
                done: item.fields.done,
                title: item.fields.title,
                id: item.fields.id,
                meta: item.fields.meta.dictionary,
                body: item.body.map(jsTrim)
            ))
            lineNo += item.body.count
        case .other:
            break
        }
    }

    return (headings, items)
}
