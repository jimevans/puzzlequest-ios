import CoreText
import SwiftUI

// The brand's look (brand/README.md in the server repository): its colors are
// in Assets.xcassets, from which Xcode makes `Color.aubergine` and the rest,
// and the app's tint is its purple. Headings and clocks use the brand's
// display face, as on the website; body text, controls and navigation keep the
// system's, so the app feels at home on an iPhone.

/// Barlow Condensed Bold, the brand's display face (Fonts/, under the SIL Open
/// Font License).
enum BrandFont {
    static let name = "BarlowCondensed-Bold"

    /// Makes the font available to the app; once, at launch.
    static func register() {
        guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
            assertionFailure("\(name).ttf is missing from the app")
            return
        }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

extension Font {
    /// A heading in the brand's face, sized like `style` and growing and
    /// shrinking with it under Dynamic Type. A condensed face looks smaller
    /// than the system's at the same size, so it's set a little larger.
    static func brand(_ style: Font.TextStyle) -> Font {
        let size: CGFloat =
            switch style {
            case .largeTitle: 42
            case .title: 34
            case .title2: 27
            case .title3: 24
            default: 21
            }
        return .custom(BrandFont.name, size: size, relativeTo: style)
    }
}

extension View {
    /// iOS's filled button, in the brand's colors: white on purple, or in dark
    /// mode aubergine on lavender, where white wouldn't be readable.
    func prominentButton() -> some View {
        buttonStyle(.borderedProminent)
            .foregroundStyle(Color.onAccent)
    }
}

/// The logo beside the name, as at the top of the website.
struct BrandMark: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(.logo)
                .resizable()
                .scaledToFit()
                .frame(height: 52)
                .accessibilityHidden(true)
            Text(verbatim: "PuzzleQuest")
                .font(.brand(.largeTitle))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
