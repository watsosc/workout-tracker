import SwiftUI

// Edgerunners theme: inky blacks, neon yellow / magenta / cyan, hard cut-corner edges.
// Shared by the app and the WorkoutLiveActivity extension. Design reference: design/preview/.
//
// The rest clock (SegmentedDigitalClock in WorkoutView.swift) is intentionally NOT themed: it keeps
// its original system green / orange / red retro look.

enum Neon {
    static let ink = Color(hex: 0x040406)
    static let ink2 = Color(hex: 0x0A0A10)
    static let panel = Color(hex: 0x0D0D15)
    static let line = Color(hex: 0x262633)
    static let white = Color(hex: 0xF6F6F8)
    static let muted = Color(hex: 0x8C8CA3)

    static let yellow = Color(hex: 0xFCEE0A)
    static let pink = Color(hex: 0xFF2E97)
    static let cyan = Color(hex: 0x00F0FF)
    static let red = Color(hex: 0xFF003C)
    static let blue = Color(hex: 0x1E9BFF)

    /// Rest-clock colours (iOS dark-mode system colours), shared with the Live Activity countdown.
    static let clockGreen = Color(hex: 0x30D158)
    static let clockOrange = Color(hex: 0xFF9F0A)
    static let clockRed = Color(hex: 0xFF453A)

    enum Weight { case medium, semibold, bold }

    /// Headline face (Chakra Petch). Scales with Dynamic Type relative to `style`.
    static func head(_ size: CGFloat, _ weight: Weight = .bold, relativeTo style: Font.TextStyle = .body) -> Font {
        let name: String
        switch weight {
        case .medium: name = "ChakraPetch-Medium"
        case .semibold: name = "ChakraPetch-SemiBold"
        case .bold: name = "ChakraPetch-Bold"
        }
        return .custom(name, size: size, relativeTo: style)
    }

    /// Data / label face (Share Tech Mono).
    static func mono(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("ShareTechMono-Regular", size: size, relativeTo: style)
    }

    /// Edge used on the main workout card.
    static let heroEdge = LinearGradient(
        stops: [
            .init(color: yellow, location: 0),
            .init(color: yellow.opacity(0.15), location: 0.3),
            .init(color: line, location: 0.6),
            .init(color: pink, location: 1)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let coolEdge = LinearGradient(
        stops: [
            .init(color: cyan, location: 0),
            .init(color: line, location: 0.4),
            .init(color: line, location: 0.7),
            .init(color: pink, location: 1)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Cut-corner shape

/// Rectangle with the top-right and bottom-left corners cut at 45°.
struct CutCornerShape: InsettableShape {
    var cut: CGFloat = 14
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let c = min(max(0, cut - inset * 0.4), min(r.width, r.height) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + c))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - c))
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> CutCornerShape {
        var copy = self
        copy.inset += amount
        return copy
    }
}

// MARK: - Panels, tags, labels

struct NeonPanel<Edge: ShapeStyle>: ViewModifier {
    var edge: Edge
    var fill: Color = Neon.panel
    var cut: CGFloat = 14
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: CutCornerShape(cut: cut))
            .overlay(CutCornerShape(cut: cut).strokeBorder(edge, lineWidth: 1))
    }
}

extension View {
    func neonPanel<Edge: ShapeStyle>(edge: Edge, fill: Color = Neon.panel, cut: CGFloat = 14, padding: CGFloat = 14) -> some View {
        modifier(NeonPanel(edge: edge, fill: fill, cut: cut, padding: padding))
    }

    func neonPanel(fill: Color = Neon.panel, cut: CGFloat = 14, padding: CGFloat = 14) -> some View {
        modifier(NeonPanel(edge: Neon.line, fill: fill, cut: cut, padding: padding))
    }

    /// Red/cyan offset "glitch" on big headings.
    func glitch(_ amount: CGFloat = 2) -> some View {
        shadow(color: Neon.pink, radius: 0, x: -amount, y: 0)
            .shadow(color: Neon.cyan.opacity(0.9), radius: 0, x: amount, y: 0)
    }

    func neonGlow(_ color: Color, radius: CGFloat = 10) -> some View {
        shadow(color: color.opacity(0.6), radius: radius)
    }
}

struct NeonTag: View {
    enum Style { case plain, yellow, pink, cyan }
    let text: String
    var style: Style = .plain

    var body: some View {
        Text(text.uppercased())
            .font(Neon.mono(11, relativeTo: .caption))
            .tracking(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(foreground)
            .background(style == .yellow ? Neon.yellow : Color.clear)
            .overlay(Rectangle().strokeBorder(border, lineWidth: 1))
            .fixedSize()
    }

    private var foreground: Color {
        switch style {
        case .plain: return Neon.muted
        case .yellow: return .black
        case .pink: return Neon.pink
        case .cyan: return Neon.cyan
        }
    }

    private var border: Color {
        switch style {
        case .plain: return Neon.line
        case .yellow: return Neon.yellow
        case .pink: return Neon.pink.opacity(0.6)
        case .cyan: return Neon.cyan.opacity(0.6)
        }
    }
}

/// Small spaced-out mono label, e.g. "// QUEUE".
struct Kicker: View {
    let text: String
    var color: Color = Neon.muted

    var body: some View {
        Text(text.uppercased())
            .font(Neon.mono(11, relativeTo: .caption))
            .tracking(2)
            .foregroundStyle(color)
    }
}

/// Underlined mono text button, e.g. "CHANGE WEIGHT".
struct NeonLinkStyle: ButtonStyle {
    var color: Color = Neon.yellow

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Neon.mono(13, relativeTo: .footnote))
            .tracking(1.2)
            .textCase(.uppercase)
            .underline()
            .foregroundStyle(color)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - Buttons

struct NeonButtonStyle: ButtonStyle {
    enum Kind { case primary, danger, ghost, hazard }
    var kind: Kind = .primary
    var height: CGFloat = 54
    var fontSize: CGFloat = 17
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = CutCornerShape(cut: 12)
        return configuration.label
            .font(Neon.head(fontSize, .bold, relativeTo: .headline))
            .tracking(1.6)
            .textCase(.uppercase)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, kind == .hazard ? 12 : 8)
            .padding(.vertical, kind == .hazard ? 5 : 0)
            .background(kind == .hazard ? Color.black : Color.clear)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(background, in: shape)
            .overlay(border.map { shape.strokeBorder($0, lineWidth: kind == .danger ? 2 : 1) })
            .shadow(color: kind == .primary ? Neon.yellow.opacity(0.35) : .clear, radius: 12)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .black
        case .danger: return Neon.pink
        case .ghost: return Neon.cyan
        case .hazard: return Neon.yellow
        }
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .primary: return AnyShapeStyle(Neon.yellow)
        case .danger, .ghost: return AnyShapeStyle(Color.clear)
        case .hazard: return AnyShapeStyle(HazardStripes.paint)
        }
    }

    private var border: Color? {
        switch kind {
        case .danger: return Neon.pink
        case .ghost: return Neon.cyan.opacity(0.55)
        case .primary, .hazard: return nil
        }
    }
}

/// Diagonal yellow hazard stripes (Finish workout).
enum HazardStripes {
    static let paint: ImagePaint = {
        let size = 28
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let s = CGFloat(size)
        context.setFillColor(CGColor(red: 0xE5 / 255, green: 0xD8 / 255, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: s, height: s))
        context.setFillColor(CGColor(red: 0xFC / 255, green: 0xEE / 255, blue: 0x0A / 255, alpha: 1))
        // Two parallel diagonal bands per tile so the pattern repeats seamlessly.
        for offset in [-s, 0, s] {
            context.move(to: CGPoint(x: offset, y: 0))
            context.addLine(to: CGPoint(x: offset + s / 2, y: 0))
            context.addLine(to: CGPoint(x: offset + s / 2 + s, y: s))
            context.addLine(to: CGPoint(x: offset + s, y: s))
            context.closePath()
        }
        context.fillPath()
        return ImagePaint(image: Image(decorative: context.makeImage()!, scale: 1))
    }()
}

// MARK: - Backgrounds

/// Ink background with faint scanlines, used behind every screen.
struct NeonBackground: View {
    var body: some View {
        ZStack {
            Neon.ink
            Canvas { context, size in
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.white.opacity(0.018)))
                    y += 3
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Forms and lists

extension View {
    /// Dark themed Form/List: ink background instead of the default grouped grey.
    func neonForm() -> some View {
        scrollContentBackground(.hidden)
            .background(NeonBackground())
            .font(Neon.head(16, .medium))
    }

    /// Panel-coloured list row, used on each Section of a neonForm.
    func neonRows() -> some View {
        listRowBackground(Neon.panel)
    }
}

/// Section header for neon forms, e.g. "// UPLOADS".
struct NeonSectionHeader: View {
    let text: String
    var color: Color = Neon.pink

    var body: some View {
        Text("// \(text)".uppercased())
            .font(Neon.mono(12, relativeTo: .caption))
            .tracking(2)
            .foregroundStyle(color)
    }
}

/// Mono footnote for neon forms.
struct NeonFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Neon.mono(12, relativeTo: .footnote))
            .foregroundStyle(Neon.muted)
    }
}
