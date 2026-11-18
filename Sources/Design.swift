import SwiftUI

// Direction: a disk ledger. Quiet surfaces, aligned figures, and capacity marks.
enum SweepStyle {
    static let accent = Color(red: 0.66, green: 0.27, blue: 0.13)
    static let background = Color(red: 0.965, green: 0.965, blue: 0.955)
    static let surface = Color.white
    static let ink = Color(red: 0.14, green: 0.15, blue: 0.15)
    static let secondary = Color(red: 0.40, green: 0.41, blue: 0.40)
    static let line = Color.black.opacity(0.09)
    static let rail = Color(red: 0.105, green: 0.12, blue: 0.12)
    static let warning = accent
}
struct SweepPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var color: Color = SweepStyle.ink
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 20).frame(height: 36)
            .foregroundStyle(isEnabled ? .white : SweepStyle.secondary)
            .background(isEnabled ? color.opacity(configuration.isPressed ? 0.8 : 1) : SweepStyle.line, in: RoundedRectangle(cornerRadius: 6))
    }
}
struct SweepOutlineButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).padding(.horizontal, 12).frame(height: 32)
            .foregroundStyle(isEnabled ? SweepStyle.ink : SweepStyle.secondary.opacity(0.5))
            .background(configuration.isPressed ? SweepStyle.line : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(SweepStyle.line))
    }
}
extension View {
    func sweepCard() -> some View {
        background(SweepStyle.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(SweepStyle.line))
    }
}
struct LedgerHeading: View {
    let number: String
    let title: String
    var body: some View {
        HStack(spacing: 12) {
            Text(L(number)).font(.system(size: 12, design: .monospaced)).foregroundStyle(SweepStyle.accent)
            Text(L(title)).font(.system(size: 14, weight: .medium))
        }
    }
}
struct CapacityRuler: View {
    let used: Double
    var body: some View {
        Canvas { context, size in
            let step = size.width / 48
            let boundary = size.width * min(1, max(0, used))
            for index in 0..<48 {
                let x = CGFloat(index) * step
                let width = max(0, step - 2)
                let rect = CGRect(x: x, y: 0, width: width, height: size.height)
                context.fill(Path(rect), with: .color(SweepStyle.accent.opacity(0.15)))
                let filled = min(width, max(0, boundary - x))
                context.fill(Path(CGRect(x: x, y: 0, width: filled, height: size.height)), with: .color(SweepStyle.ink))
            }
        }.frame(height: 48).accessibilityHidden(true)
    }
}

// These are cleanup scopes, not severity levels. Keep text and icons alongside color.
extension CleanupScope {
    var color: Color {
        switch self {
        case .recommended: return Color(red: 0.70, green: 0.16, blue: 0.20)
        case .optional: return Color(red: 0.16, green: 0.36, blue: 0.66)
        case .protected: return Color(red: 0.43, green: 0.28, blue: 0.65)
        }
    }
    var symbol: String {
        switch self { case .recommended: return "checklist"; case .optional: return "slider.horizontal.3"; case .protected: return "person.crop.circle" }
    }
    var guidance: String {
        switch self {
        case .recommended: return "已识别的旧安装包和下载缓存，可添加当前推荐项"
        case .optional: return "缓存、日志与重装介质，查看影响后选择"
        case .protected: return "素材和项目默认不选，手动选择后需二次确认"
        }
    }
}

struct CleanupScopeCard: View {
    let scope: CleanupScope
    let capacity: String
    let count: Int?
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: scope.symbol).font(.system(size: 15, weight: .medium)).frame(width: 20)
                    Text(L(scope.rawValue)).font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "chevron.right").font(.system(size: 13))
                }.foregroundStyle(scope.color)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L(capacity)).font(.system(size: 24, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                    if let count { Text(L("\(count) 项")).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary) }
                }
                Text(L(scope.shortDescription)).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary).lineLimit(1)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(scope.color.opacity(selected ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(scope.color.opacity(selected ? 0.85 : 0.22), lineWidth: selected ? 2 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct CleanupScopeLabel: View {
    let scope: CleanupScope
    var body: some View {
        Label(L(scope.rawValue), systemImage: scope.symbol)
            .font(.system(size: 12, weight: .medium)).foregroundStyle(scope.color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(scope.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct ModuleStat: View {
    let title: String
    let value: String
    let color: Color
    var detail: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(title)).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
            Text(L(value)).font(.system(size: 24, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
            if !detail.isEmpty { Text(L(detail)).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(color.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.20)))
    }
}

struct ScopeSidebarCard: View {
    let scope: CleanupScope
    let capacity: String
    let count: Int?
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(L(scope.rawValue)).font(.system(size: 18, weight: .semibold))
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 14)) }
                }.foregroundStyle(scope.color)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L(capacity)).font(.system(size: 21, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    if let count { Text(L("\(count) 项")).font(.system(size: 11)).foregroundStyle(SweepStyle.secondary) }
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(scope.color.opacity(selected ? 0.11 : 0.04), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(scope.color.opacity(selected ? 0.85 : 0.20), lineWidth: selected ? 2 : 1))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
