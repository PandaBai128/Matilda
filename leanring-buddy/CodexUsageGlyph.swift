import SwiftUI

struct CodexUsageGlyph: View {
    var color: Color = DS.Colors.blue400

    private let normalizedBarHeights: [CGFloat] = [0.36, 0.7, 1, 0.58, 0.82, 0.48]

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: max(1, geometry.size.width * 0.075)) {
                ForEach(Array(normalizedBarHeights.enumerated()), id: \.offset) { _, height in
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: geometry.size.height * height
                        )
                }
            }
        }
        .accessibilityHidden(true)
    }
}
