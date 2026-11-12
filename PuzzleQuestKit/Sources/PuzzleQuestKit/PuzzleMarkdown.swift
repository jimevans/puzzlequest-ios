import Foundation
import Markdown

/// A text puzzle's Markdown, read into blocks for the app to draw, with the
/// same GitHub-flavored Markdown the web app shows. HTML in it shows as plain
/// text, as on the web, so an author can't put anything on screen that
/// isn't Markdown.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, AttributedString)
    case paragraph(AttributedString)
    /// A paragraph of nothing but pictures, shown as pictures.
    case images([MarkdownImage])
    /// Each item is blocks of its own.
    case list(ordered: Bool, start: Int, items: [[MarkdownBlock]])
    case quote([MarkdownBlock])
    case code(String)
    case table(MarkdownTable)
    case rule

    /// Reads Markdown.
    /// - Parameter server: the site, which relative links and pictures are on.
    public static func blocks(from markdown: String, server: URL) -> [MarkdownBlock] {
        var reader = Reader(server: server)
        return reader.blocks(Document(parsing: markdown).children)
    }
}

public struct MarkdownImage: Equatable, Sendable {
    public var url: URL
    /// The picture's description, for VoiceOver.
    public var alt: String
}

public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case leading, center, trailing }

    /// Each column's alignment; nil for the default.
    public var alignments: [Alignment?]
    public var header: [AttributedString]
    public var rows: [[AttributedString]]
}

private struct Reader {
    let server: URL

    mutating func blocks(_ markups: some Sequence<any Markup>) -> [MarkdownBlock] {
        markups.compactMap { block($0) }
    }

    mutating func block(_ markup: any Markup) -> MarkdownBlock? {
        switch markup {
        case let heading as Heading:
            return .heading(level: heading.level, inlines(heading.children))
        case let paragraph as Paragraph:
            let children = Array(paragraph.children)
            let images = children.compactMap { $0 as? Markdown.Image }
            let onlyImages =
                !images.isEmpty
                && children.allSatisfy {
                    $0 is Markdown.Image || $0 is SoftBreak || $0 is LineBreak
                        || ($0 as? Markdown.Text)?.string.allSatisfy(\.isWhitespace) == true
                }
            if onlyImages {
                let found = images.compactMap { image -> MarkdownImage? in
                    guard let url = url(image.source, allowing: ["http", "https"]) else {
                        return nil
                    }
                    return MarkdownImage(url: url, alt: image.plainText)
                }
                if found.count == images.count {
                    return .images(found)
                }
            }
            return .paragraph(inlines(paragraph.children))
        case let list as UnorderedList:
            return .list(ordered: false, start: 1, items: items(list.listItems))
        case let list as OrderedList:
            return .list(ordered: true, start: Int(list.startIndex), items: items(list.listItems))
        case let quote as BlockQuote:
            return .quote(blocks(quote.children))
        case let code as CodeBlock:
            return .code(trimmingFinalNewline(code.code))
        case let html as HTMLBlock:
            return .paragraph(AttributedString(trimmingFinalNewline(html.rawHTML)))
        case let table as Markdown.Table:
            return .table(
                MarkdownTable(
                    alignments: table.columnAlignments.map { alignment in
                        switch alignment {
                        case .left: .leading
                        case .center: .center
                        case .right: .trailing
                        case nil: nil
                        }
                    },
                    header: table.head.cells.map { inlines($0.children) },
                    rows: table.body.rows.map { row in row.cells.map { inlines($0.children) } }))
        case is ThematicBreak:
            return .rule
        default:
            return nil
        }
    }

    mutating func items(_ listItems: some Sequence<ListItem>) -> [[MarkdownBlock]] {
        listItems.map { item in
            var content = blocks(item.children)
            if let checkbox = item.checkbox {
                // A task list's box, as a character VoiceOver reads.
                let box = AttributedString(checkbox == .checked ? "☑ " : "☐ ")
                if case .paragraph(let text) = content.first {
                    content[0] = .paragraph(box + text)
                } else {
                    content.insert(.paragraph(box), at: 0)
                }
            }
            return content
        }
    }

    func inlines(_ markups: some Sequence<any Markup>) -> AttributedString {
        markups.reduce(into: AttributedString()) { text, markup in
            text += inline(markup)
        }
    }

    func inline(_ markup: any Markup) -> AttributedString {
        switch markup {
        case let text as Markdown.Text:
            return AttributedString(text.string)
        case is SoftBreak:
            return AttributedString(" ")
        case is LineBreak:
            return AttributedString("\n")
        case let code as InlineCode:
            return styled(AttributedString(code.code), .code)
        case let emphasis as Emphasis:
            return styled(inlines(emphasis.children), .emphasized)
        case let strong as Strong:
            return styled(inlines(strong.children), .stronglyEmphasized)
        case let strikethrough as Strikethrough:
            return styled(inlines(strikethrough.children), .strikethrough)
        case let link as Markdown.Link:
            var text = inlines(link.children)
            if let destination = link.destination,
                let url = url(destination, allowing: ["http", "https", "mailto"])
            {
                text.link = url
            }
            return text
        case let image as Markdown.Image:
            // A picture within a sentence shows as its description.
            return AttributedString(image.plainText)
        case let html as InlineHTML:
            return AttributedString(html.rawHTML)
        default:
            return inlines(markup.children)
        }
    }

    func styled(
        _ text: AttributedString, _ intent: InlinePresentationIntent
    ) -> AttributedString {
        var text = text
        for run in text.runs {
            let existing = run.inlinePresentationIntent ?? []
            text[run.range].inlinePresentationIntent = existing.union(intent)
        }
        return text
    }

    /// An address in the puzzle, resolved against the site, if it uses one
    /// of the schemes allowed.
    func url(_ string: String?, allowing schemes: Set<String>) -> URL? {
        guard let string, let url = URL(string: string, relativeTo: server)?.absoluteURL,
            let scheme = url.scheme?.lowercased(), schemes.contains(scheme)
        else { return nil }
        return url
    }

    func trimmingFinalNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? String(text.dropLast()) : text
    }
}
