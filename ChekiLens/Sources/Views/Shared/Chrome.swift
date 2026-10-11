import SwiftUI

// MARK: - 尺寸（全 App chrome 的唯一數字來源）

enum ChromeMetrics {
    static let circle: CGFloat = 44
    static let capsuleHeight: CGFloat = 44
    static let iconPointSize: CGFloat = 17
    static let capsuleHPadding: CGFloat = 16
    static let edgeHorizontal: CGFloat = 16
    static let edgeBottom: CGFloat = 12
    static let groupSpacing: CGFloat = 12
}

enum ChromeID {
    static let libraryCamera = "chrome.library.camera"
    static let libraryImport = "chrome.library.import"
    static let libraryFilter = "chrome.library.filter"
    static let librarySelect = "chrome.library.select"
    static let libraryPhoto = "chrome.library.photo"
    static let librarySelectionShare = "chrome.library.selection.share"
    static let librarySelectionDelete = "chrome.library.selection.delete"
    static let detailBack = "chrome.detail.back"
    static let detailMore = "chrome.detail.more"
    static let detailShare = "chrome.detail.share"
    static let detailDelete = "chrome.detail.delete"
}

enum ChromeInk {
    case primary
    case white

    var color: Color {
        switch self {
        case .primary: return .primary
        case .white: return .white
        }
    }
}

enum ChromeFallbackStroke {
    case primary
    case white

    var color: Color {
        switch self {
        case .primary: return .primary.opacity(0.14)
        case .white: return .white.opacity(0.16)
        }
    }
}

// MARK: - 單一液態玻璃實作

extension View {
    func liquidGlassCircle(
        size: CGFloat,
        ink: ChromeInk? = nil,
        fallbackStroke: ChromeFallbackStroke = .primary
    ) -> some View {
        modifier(LiquidGlassCircleModifier(size: size, ink: ink, fallbackStroke: fallbackStroke))
    }

    func liquidGlassCapsule(
        height: CGFloat? = nil,
        horizontalPadding: CGFloat? = nil,
        ink: ChromeInk? = nil,
        interactive: Bool = true,
        fallbackStroke: ChromeFallbackStroke = .primary
    ) -> some View {
        modifier(
            LiquidGlassCapsuleModifier(
                height: height,
                horizontalPadding: horizontalPadding,
                ink: ink,
                interactive: interactive,
                fallbackStroke: fallbackStroke
            )
        )
    }
}

private struct ChromeInkModifier: ViewModifier {
    var ink: ChromeInk?

    func body(content: Content) -> some View {
        if let ink {
            content.foregroundStyle(ink.color).tint(ink.color)
        } else {
            content
        }
    }
}

private struct OptionalHorizontalPadding: ViewModifier {
    var padding: CGFloat?

    func body(content: Content) -> some View {
        if let padding {
            content.padding(.horizontal, padding)
        } else {
            content
        }
    }
}

private struct OptionalFixedHeight: ViewModifier {
    var height: CGFloat?

    func body(content: Content) -> some View {
        if let height {
            content.frame(height: height)
        } else {
            content
        }
    }
}

private struct LiquidGlassCircleModifier: ViewModifier {
    var size: CGFloat
    var ink: ChromeInk?
    var fallbackStroke: ChromeFallbackStroke

    func body(content: Content) -> some View {
        let framed = content
            .modifier(ChromeInkModifier(ink: ink))
            .frame(width: size, height: size)
        if #available(iOS 26.0, *) {
            framed
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            framed
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(fallbackStroke.color, lineWidth: 0.6))
        }
    }
}

private struct LiquidGlassCapsuleModifier: ViewModifier {
    var height: CGFloat?
    var horizontalPadding: CGFloat?
    var ink: ChromeInk?
    var interactive: Bool
    var fallbackStroke: ChromeFallbackStroke

    func body(content: Content) -> some View {
        let framed = content
            .modifier(ChromeInkModifier(ink: ink))
            .modifier(OptionalHorizontalPadding(padding: horizontalPadding))
            .modifier(OptionalFixedHeight(height: height))
        if #available(iOS 26.0, *) {
            if interactive {
                framed
                    .contentShape(Capsule())
                    .glassEffect(.regular.interactive(), in: .capsule)
            } else {
                framed.glassEffect(.regular, in: .capsule)
            }
        } else {
            framed
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(fallbackStroke.color, lineWidth: 0.6))
        }
    }
}

// MARK: - 舊名稱轉接（版面尺寸由呼叫端傳入，玻璃只剩這一條路）

extension View {
    func darkSystemCircleChrome(size: CGFloat = 36) -> some View {
        liquidGlassCircle(size: size, ink: .primary, fallbackStroke: .primary)
    }

    func darkSystemCapsuleChrome(height: CGFloat = 36, horizontalPadding: CGFloat = 14) -> some View {
        liquidGlassCapsule(
            height: height,
            horizontalPadding: horizontalPadding,
            ink: .primary,
            fallbackStroke: .primary
        )
    }

    func pairingLiquidGlassCircle(size: CGFloat) -> some View {
        liquidGlassCircle(size: size, fallbackStroke: .primary)
    }

    func pairingLiquidGlassCapsule() -> some View {
        liquidGlassCapsule(fallbackStroke: .primary)
    }

    func detailLiquidGlassCircle(size: CGFloat) -> some View {
        liquidGlassCircle(size: size, fallbackStroke: .white)
    }

    func detailLiquidGlassCapsule(interactive: Bool = true) -> some View {
        liquidGlassCapsule(interactive: interactive, fallbackStroke: .white)
    }

    func cameraLiquidGlassCircle(size: CGFloat) -> some View {
        liquidGlassCircle(size: size, fallbackStroke: .white)
    }

    func cameraLiquidGlassCapsule() -> some View {
        liquidGlassCapsule(fallbackStroke: .white)
    }
}

// MARK: - 共用按鈕（後續任務改呼叫端時使用；尺寸固定為 ChromeMetrics）

struct ChromeCircleButton: View {
    let systemName: String
    var ink: ChromeInk = .primary
    var accessibilityLabel: String
    var accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: ChromeMetrics.iconPointSize, weight: .semibold))
                .liquidGlassCircle(size: ChromeMetrics.circle, ink: ink)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct ChromeCapsuleButton<Label: View>: View {
    var ink: ChromeInk = .primary
    var accessibilityLabel: String
    var accessibilityIdentifier: String
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .liquidGlassCapsule(
                    height: ChromeMetrics.capsuleHeight,
                    horizontalPadding: ChromeMetrics.capsuleHPadding,
                    ink: ink
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct CloseToolbarButton: View {
    var accessibilityIdentifier: String = "chrome.close"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
        }
        .accessibilityLabel(L10n.tr("取消", "キャンセル"))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct ConfirmToolbarButton: View {
    var accessibilityIdentifier: String = "chrome.confirm"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark")
        }
        .accessibilityLabel(L10n.tr("完成", "完了"))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
