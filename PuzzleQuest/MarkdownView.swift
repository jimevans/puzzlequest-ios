import PuzzleQuestKit
import SwiftUI

/// A text puzzle's Markdown, drawn with the app's own fonts, so it follows
/// Dynamic Type. PuzzleQuestKit reads it into blocks (`MarkdownBlock`); this
/// draws each.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A block's place in the list is its identity: the blocks only
            // change all together, when the puzzle does.
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(Self.font(forHeading: level))
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(text)
        case .images(let images):
            ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                MarkdownImageView(image: image)
            }
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: ordered ? "\(start + index)." : "•")
                            .monospacedDigit()
                        MarkdownView(blocks: item)
                    }
                    // Read as one item, starting with its number.
                    .accessibilityElement(children: .combine)
                }
            }
        case .quote(let blocks):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.secondary)
                    .frame(width: 4)
                    .accessibilityHidden(true)
                MarkdownView(blocks: blocks)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.body.monospaced())
                    .padding(10)
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        case .table(let table):
            MarkdownTableView(table: table)
        case .rule:
            Divider()
        }
    }

    static func font(forHeading level: Int) -> Font {
        switch level {
        case 1: .title.weight(.bold)
        case 2: .title2.weight(.bold)
        case 3: .title3.weight(.semibold)
        default: .headline
        }
    }
}

/// A picture in a puzzle's Markdown, as wide as the screen at most.
private struct MarkdownImageView: View {
    let image: MarkdownImage

    var body: some View {
        AsyncImage(url: image.url) { phase in
            switch phase {
            case .success(let picture):
                picture
                    .resizable()
                    .scaledToFit()
            case .failure:
                Label("Couldn't load this picture", systemImage: "photo")
                    .foregroundStyle(.secondary)
            default:
                ProgressView()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(image.alt.isEmpty ? Text("Picture") : Text(image.alt))
        .accessibilityAddTraits(.isImage)
    }
}

/// A table: in a grid, scrolling sideways if it's wider than the screen.
private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        cellView(cell, column: column).fontWeight(.semibold)
                    }
                }
                Divider()
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            cellView(cell, column: column)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func cellView(_ text: AttributedString, column: Int) -> some View {
        let alignment: HorizontalAlignment =
            switch column < table.alignments.count ? table.alignments[column] : nil {
            case .center: .center
            case .trailing: .trailing
            case .leading, nil: .leading
            }
        return Text(text).gridColumnAlignment(alignment)
    }
}

#Preview {
    ScrollView {
        MarkdownView(
            blocks: MarkdownBlock.blocks(
                from: """
                    # The quay
                    Find the *red* door, then **knock** three times.

                    1. Count the bollards
                    2. Add the year on the sign

                    > The sea gives, and the sea takes.

                    | Clue | Answer |
                    |:--|--:|
                    | Anchor | 7 |
                    """,
                server: URL(string: "https://example.com")!)
        )
        .padding()
    }
}
