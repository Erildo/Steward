import Foundation

/// Steward's words, read as the light Markdown models write: headings,
/// bullet and numbered lists, quotes and paragraphs. Inline marks (bold,
/// italics, links) stay in the text for the app to style.
///
/// Short, flat replies stay chat bubbles; a reply with structure becomes a
/// formatted answer, so a plan never arrives as one grey wall.
public enum ReplyText {
    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullets([String])
        case numbered([String])
        case quote(String)
    }

    /// Longer than this, with more than one paragraph, reads better as an answer than a bubble.
    public static let longReply = 320

    public static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var list: (numbered: Bool, items: [String])?
        var quote: [String] = []

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            if let list { blocks.append(list.numbered ? .numbered(list.items) : .bullets(list.items)) }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            paragraph = []
            list = nil
            quote = []
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                continue
            }
            if let heading = heading(line) {
                flush()
                blocks.append(heading)
            } else if let item = bullet(line) {
                if list?.numbered != false { flush(); list = (false, []) }
                list?.items.append(item)
            } else if let item = numberedItem(line) {
                if list?.numbered != true { flush(); list = (true, []) }
                list?.items.append(item)
            } else if line.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if let open = list, !open.items.isEmpty, raw.first == " " || raw.first == "\t" {
                // An indented line carries on the item above it.
                list?.items[open.items.count - 1] += " " + line
            } else {
                if list != nil || !quote.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    /// Whether the reply has structure worth laying out: a heading, a list,
    /// a quote, or several paragraphs of some length.
    public static func isStructured(_ text: String) -> Bool {
        let blocks = parse(text)
        if blocks.contains(where: { if case .paragraph = $0 { false } else { true } }) { return true }
        return blocks.count > 1 && text.count > longReply
    }

    /// The words without Markdown marks, for previews and VoiceOver.
    public static func plain(_ text: String) -> String {
        parse(text).map { block in
            switch block {
            case .heading(_, let text), .paragraph(let text), .quote(let text): stripInline(text)
            case .bullets(let items), .numbered(let items): items.map(stripInline).joined(separator: ", ")
            }
        }
        .joined(separator: " ")
    }

    // MARK: Lines

    private static func heading(_ line: String) -> Block? {
        let hashes = line.prefix { $0 == "#" }.count
        if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
            let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : .heading(level: min(hashes, 3), text: text)
        }
        // A line that is only bold reads as a small heading: models write them often.
        if line.count > 4, line.hasPrefix("**"), line.hasSuffix("**"), !line.dropFirst(2).dropLast(2).contains("**") {
            let text = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : .heading(level: 3, text: text.hasSuffix(":") ? String(text.dropLast()) : text)
        }
        return nil
    }

    private static func bullet(_ line: String) -> String? {
        for mark in ["- ", "* ", "• ", "– "] where line.hasPrefix(mark) {
            let item = line.dropFirst(mark.count).trimmingCharacters(in: .whitespaces)
            return item.isEmpty ? nil : item
        }
        return nil
    }

    private static func numberedItem(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard (1...3).contains(digits.count) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        let item = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return item.isEmpty ? nil : item
    }

    private static func stripInline(_ text: String) -> String {
        var out = text
        for mark in ["**", "__", "`"] { out = out.replacingOccurrences(of: mark, with: "") }
        // [label](url) → label
        while let open = out.range(of: "["), let close = out.range(of: "](", range: open.upperBound..<out.endIndex),
              let end = out.range(of: ")", range: close.upperBound..<out.endIndex) {
            out.replaceSubrange(open.lowerBound..<end.upperBound, with: out[open.upperBound..<close.lowerBound])
        }
        return out
    }
}
