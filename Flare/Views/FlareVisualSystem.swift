import SwiftUI

/// A compact visual language for Flare: paper, ink, ember, and the practical
/// details of a well-used field notebook.
enum FlareVisual {
    static let ink = Color(red: 0.13, green: 0.11, blue: 0.10)
    static let soot = Color(red: 0.22, green: 0.19, blue: 0.17)
    static let paper = Color(red: 0.96, green: 0.93, blue: 0.86)
    static let paperShadow = Color(red: 0.88, green: 0.83, blue: 0.73)
    static let canvas = Color(red: 0.93, green: 0.90, blue: 0.83)
    static let ember = Color(red: 0.88, green: 0.28, blue: 0.12)
    static let brass = Color(red: 0.72, green: 0.50, blue: 0.20)
    static let moss = Color(red: 0.20, green: 0.43, blue: 0.31)
    static let fadedInk = Color(red: 0.38, green: 0.34, blue: 0.30)
    static let corner: CGFloat = 12
}

extension JobSource {
    var flareMarkForeground: Color {
        switch self {
        case .snap, .jazzhr, .recruitee, .lever:
            return FlareVisual.ink
        default:
            return FlareVisual.paper
        }
    }
}

struct FlarePaper: ViewModifier {
    var raised = false

    func body(content: Content) -> some View {
        content
            .background(FlareVisual.paper)
            .overlay(
                RoundedRectangle(cornerRadius: FlareVisual.corner, style: .continuous)
                    .stroke(FlareVisual.ink.opacity(0.18), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: FlareVisual.corner, style: .continuous))
            .shadow(color: raised ? FlareVisual.ink.opacity(0.18) : .clear, radius: 0, x: 3, y: 3)
    }
}

extension View {
    func flarePaper(raised: Bool = false) -> some View {
        modifier(FlarePaper(raised: raised))
    }
}

struct FlareLabel: View {
    let text: String
    var color: Color = FlareVisual.ember

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .black, design: .rounded))
            .tracking(1.1)
            .foregroundStyle(color)
    }
}
