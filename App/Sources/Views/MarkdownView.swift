import AppKit
import SwiftUI

/// Renders chat Markdown: headings, lists, quotes, code blocks (with copy) and
/// inline formatting. Tables are shown as monospaced text.
struct MarkdownView: View {
    let text: String

    enum Block: Hashable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(indent: Int, marker: String, text: String)
        case quote(String)
        case code(language: String, code: String)
        case table(String)
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let t):
            Text(inline(t)).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
        case .paragraph(let t):
            Text(inline(t))
        case .bullet(let indent, let marker, let t):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
                Text(inline(t))
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let t):
            Text(inline(t)).foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
        case .code(let language, let code):
            CodeBlock(language: language, code: code)
        case .table(let t):
            ScrollView(.horizontal) {
                Text(t).font(.system(.callout, design: .monospaced)).fixedSize()
            }
        case .rule:
            Divider()
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                          failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(s)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var lines = text.components(separatedBy: "\n")[...]

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                while let next = lines.first {
                    lines = lines.dropFirst()
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    code.append(next)
                }
                blocks.append(.code(language: language, code: code.joined(separator: "\n")))
            } else if trimmed.isEmpty {
                flush()
            } else if let level = heading(trimmed) {
                flush()
                blocks.append(.heading(level: level, text: String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
            } else if trimmed == "---" || trimmed == "***" {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix(">") {
                flush()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("|") {
                flush()
                var rows = [line]
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(next)
                    lines = lines.dropFirst()
                }
                blocks.append(.table(rows.joined(separator: "\n")))
            } else if let (marker, rest) = listItem(trimmed) {
                flush()
                let indent = (line.prefix(while: { $0 == " " }).count) / 2
                blocks.append(.bullet(indent: indent, marker: marker, text: rest))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    private static func heading(_ s: String) -> Int? {
        let hashes = s.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), s.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ s: String) -> (String, String)? {
        for m in ["- ", "* ", "• "] where s.hasPrefix(m) {
            var rest = String(s.dropFirst(2))
            if rest.hasPrefix("[ ] ") { return ("☐", String(rest.dropFirst(4))) }
            if rest.hasPrefix("[x] ") { rest = String(rest.dropFirst(4)); return ("☑", rest) }
            return ("•", rest)
        }
        let digits = s.prefix(while: \.isNumber)
        if !digits.isEmpty, s.dropFirst(digits.count).hasPrefix(". ") {
            return ("\(digits).", String(s.dropFirst(digits.count + 2)))
        }
        return nil
    }
}

private struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            ScrollView(.horizontal) {
                Text(code).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize().padding(8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    }
}
