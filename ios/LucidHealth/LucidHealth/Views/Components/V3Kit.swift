import SwiftUI
import Charts

// MARK: - V3: the approved board (minerva/jobs/lh3-full/index.html), dark and light.
// Every colour has a dark value (the board) and a light value (the board's light row).
// The app follows the phone's appearance unless Settings overrides it.

enum V3 {
    static func dyn(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(v3Hex: dark) : UIColor(v3Hex: light) })
    }
    static func dynA(_ dark: (UInt32, CGFloat), _ light: (UInt32, CGFloat)) -> Color {
        Color(uiColor: UIColor {
            $0.userInterfaceStyle == .dark ? UIColor(v3Hex: dark.0, alpha: dark.1) : UIColor(v3Hex: light.0, alpha: light.1)
        })
    }

    // neutrals
    static let bg = dyn(0x000000, 0xF2F2F7)
    static let card = dyn(0x121417, 0xFFFFFF)
    static let card2 = dyn(0x1A1D21, 0xECEEF1)
    static let chrome = dyn(0x2C3036, 0xDFE2E6)       // grabber, toggle off, avatar
    static let segOn = dyn(0x2C3036, 0xFFFFFF)
    static let bar = dyn(0x0B0C0E, 0xF9F9FB)          // tab bar
    static let sheet = dyn(0x0B0C0E, 0xF2F2F7)
    static let line = dynA((0xFFFFFF, 0.07), (0x000000, 0.08))
    static let track = dynA((0xFFFFFF, 0.08), (0x000000, 0.07))
    static let trackSoft = dynA((0xFFFFFF, 0.04), (0x000000, 0.05))
    static let grid = dynA((0xFFFFFF, 0.06), (0x000000, 0.06))
    static let t1 = dyn(0xF4F5F7, 0x0B0C0E)
    static let t2 = dyn(0x8B9099, 0x6B7079)
    static let t3 = dyn(0x545A63, 0xA3A8B0)
    static let ink = dyn(0x000000, 0xFFFFFF)          // text on a t1 button

    // metric colours, one job each
    static let green = dyn(0x34D27B, 0x25A960)
    static let amber = dyn(0xF5C542, 0xE3A600)
    static let red = dyn(0xFF5D5D, 0xFF5D5D)
    static let sleep = dyn(0x8B7BFF, 0x8B7BFF)
    static let strain = dyn(0xFF8A3D, 0xF56A12)
    static let energy = dyn(0x2FD3C3, 0x23A598)
    static let kcal = dyn(0xFFB547, 0xD68000)
    static let protein = dyn(0xFF6F91, 0xFF587F)
    static let carbs = dyn(0x59C7FF, 0x1A9DE0)
    static let fat = dyn(0xB69CFF, 0x9F7DFF)
    static let heart = dyn(0xFF5A6E, 0xFF5A6E)
    static let awake = dyn(0xFF9F7A, 0xF97447)
    static let rem = dyn(0x59C7FF, 0x1A9DE0)
    static let lightSleep = dyn(0x4F7BFF, 0x4F7BFF)
    static let deep = dyn(0x6B45E8, 0x6B45E8)

    /// Keled's brand violet. Only the mark uses it.
    static let keled = Color(uiColor: UIColor(v3Hex: 0x6D4ECC))

    // block kinds on the Strain tab
    static let ride = strain
    static let work = rem
    static let play = fat
    static let rest = t3

    static func recovery(_ v: Double) -> Color { v >= 67 ? green : v >= 34 ? amber : red }
    static func recoveryWord(_ v: Double) -> String { v >= 67 ? "Ready to push" : v >= 34 ? "Take it easy" : "Rest today" }
    static func strainWord(_ v: Double) -> String {
        v >= 18 ? "Hard day" : v >= 14 ? "Solid day" : v >= 10 ? "Moderate" : "Light day"
    }
}

extension UIColor {
    convenience init(v3Hex hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// System, light or dark. Stored by Settings, applied once at the root.
enum V3Appearance: String, CaseIterable {
    case system, light, dark
    static let key = "v3Appearance"
    var scheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
    var label: String { self == .system ? "System" : self == .light ? "Light" : "Dark" }
}

// MARK: - Type

enum V3Font {
    static func num(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { .system(size: size, weight: weight).monospacedDigit() }
    static func text(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight) }
}

// MARK: - Rings

struct V3Ring: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat
    var track: Color? = nil
    var dashed = false

    var body: some View {
        ZStack {
            if dashed {
                Circle().stroke(V3.t3, style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
            } else {
                Circle().stroke(track ?? color.opacity(0.17), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: max(0.001, min(progress, 1)))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(lineWidth / 2)
    }
}

/// 84 pt side ring of the hero: value inside, label and sub below.
struct V3SmallRing: View {
    let value: String
    let progress: Double
    let color: Color
    let label: String
    let sub: String
    var dashed = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                V3Ring(progress: progress, color: color, lineWidth: 8, dashed: dashed)
                Text(value).font(V3Font.num(22)).tracking(-0.66).foregroundStyle(dashed ? V3.t3 : V3.t1)
                    .minimumScaleFactor(0.7).lineLimit(1).padding(.horizontal, 10)
            }
            .frame(width: 84, height: 84)
            Text(label).font(V3Font.text(13, .semibold)).foregroundStyle(V3.t1).padding(.top, 10)
            Text(sub).font(V3Font.text(12)).foregroundStyle(V3.t2).padding(.top, 2)
        }
        .fixedSize()
    }
}

/// 172 pt centre ring of the hero.
struct V3HeroRing: View {
    let value: String
    var unit: String = "%"
    let progress: Double
    let color: Color
    var label: String = ""
    var sub: String = ""
    var subColor: Color? = nil
    var size: CGFloat = 172

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                V3Ring(progress: progress, color: color, lineWidth: 15)
                HStack(alignment: .firstTextBaseline, spacing: unit.count > 1 ? 6 : 2) {
                    Text(value).font(V3Font.num(size > 160 ? 58 : 50)).tracking(-2.6)
                    if !unit.isEmpty {
                        Text(unit).font(V3Font.text(22, .semibold)).foregroundStyle(V3.t2)
                    }
                }
                .foregroundStyle(V3.t1)
                .minimumScaleFactor(0.6).lineLimit(1).padding(.horizontal, 22)
            }
            .frame(width: size, height: size)
            if !label.isEmpty {
                Text(label).font(V3Font.text(15, .semibold)).foregroundStyle(V3.t1).padding(.top, 10)
            }
            if !sub.isEmpty {
                Text(sub).font(V3Font.text(12, .semibold)).foregroundStyle(subColor ?? V3.t2).padding(.top, 2)
            }
        }
        .fixedSize()
    }
}

/// The soft radial light behind the hero ring.
struct V3Glow: View {
    let color: Color
    var size: CGFloat = 300
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Circle()
            .fill(RadialGradient(stops: [
                .init(color: color.opacity(0.20), location: 0),
                .init(color: color.opacity(0.06), location: 0.6),
                .init(color: color.opacity(0), location: 1),
            ], center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
            .opacity(scheme == .light ? 0.6 : 1)
            .allowsHitTesting(false)
    }
}

/// Small ring, big ring, small ring, with the glow behind the centre.
struct V3HeroTrio<L: View, M: View, R: View>: View {
    let glow: Color
    @ViewBuilder var left: L
    @ViewBuilder var middle: M
    @ViewBuilder var right: R

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            left
            Spacer(minLength: 0)
            middle
            Spacer(minLength: 0)
            right
        }
        .padding(.horizontal, 2)
        .padding(.top, 26)
        .padding(.bottom, 4)
        .background(alignment: .top) { V3Glow(color: glow).padding(.top, 2) }
    }
}

// MARK: - Chrome

struct V3Header<Trailing: View>: View {
    let date: String
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(date).font(V3Font.text(13)).foregroundStyle(V3.t2)
                Text(title).font(.system(size: 32, weight: .bold)).tracking(-0.96).foregroundStyle(V3.t1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) { trailing }.padding(.bottom, 3)
        }
        .padding(.top, 14)
        .padding(.horizontal, 4)
    }
}

/// Keled's K tile in the header's top-right slot. Opens Settings.
struct V3KeledMark: View {
    var size: CGFloat = 34

    var body: some View {
        Text("K")
            .font(.system(size: size * 0.62, weight: .medium))
            .tracking(-size * 0.03)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(V3.keled, in: RoundedRectangle(cornerRadius: size / 8, style: .continuous))
            .accessibilityLabel("Keled. Settings")
    }
}

struct V3KeledButton: View {
    @State private var showSettings = false
    @EnvironmentObject private var bleManager: BLEManager

    var body: some View {
        Button { showSettings = true } label: { V3KeledMark() }
            .buttonStyle(.plain)
            .sheet(isPresented: $showSettings) {
                NavigationStack { SettingsView() }
                    .environmentObject(bleManager)
            }
    }
}

struct V3IconButton: View {
    let symbol: String
    var size: CGFloat = 34
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(V3.t1)
                .frame(width: size, height: size)
                .background(V3.card2, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct V3Pill: View {
    var dot: Color? = nil
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            Text(text).font(V3Font.text(13, .semibold)).foregroundStyle(V3.t1).monospacedDigit()
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(V3.card2, in: Capsule())
    }
}

/// Strap pill from the live BLE state.
struct V3StrapPill: View {
    @EnvironmentObject private var bleManager: BLEManager

    var body: some View {
        switch bleManager.connectionState {
        case .connected, .syncing, .streaming:
            V3Pill(dot: V3.green, text: bleManager.battery > 0 ? "Strap \(Int(bleManager.battery.rounded()))%" : "Strap")
        case .scanning, .connecting:
            V3Pill(dot: V3.amber, text: "Connecting")
        case .disconnected:
            V3Pill(dot: V3.red, text: "No strap")
        }
    }
}

struct V3Callout: View {
    let color: Color
    let bold: String
    var rest: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(color).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            (Text(bold).font(V3Font.text(14, .semibold)).foregroundColor(V3.t1)
             + Text(rest.isEmpty ? "" : " " + rest).font(V3Font.text(14)).foregroundColor(V3.t2))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }
}

struct V3PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle().fill(i == index ? V3.t1 : V3.t3).frame(width: 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct V3Segmented: View {
    let options: [String]
    @Binding var selection: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { o in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = o }
                } label: {
                    Text(o)
                        .font(V3Font.text(13, .semibold))
                        .foregroundStyle(selection == o ? V3.t1 : V3.t2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            if selection == o {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(V3.segOn)
                                    .shadow(color: .black.opacity(scheme == .light ? 0.12 : 0), radius: 1.5, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(V3.card2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .sensoryFeedback(.selection, trigger: selection)
    }
}

// MARK: - Cards

struct V3Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(V3.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct V3IconWell: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.31, style: .continuous))
    }
}

struct V3CardHeader: View {
    var icon: String? = nil
    var iconColor: Color = V3.t2
    let title: String
    var trailing: String? = nil
    var chevron = false

    var body: some View {
        HStack(spacing: 8) {
            if let icon { V3IconWell(symbol: icon, color: iconColor) }
            Text(title).font(V3Font.text(15, .semibold)).tracking(-0.15).foregroundStyle(V3.t1).lineLimit(1)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).font(V3Font.text(13)).foregroundStyle(V3.t2).lineLimit(1).monospacedDigit()
            }
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(V3.t3)
            }
        }
        .padding(.bottom, 12)
    }
}

/// "62 / 100" style: big number with a quiet unit.
struct V3BigNumber: View {
    let value: String
    var unit: String = ""
    var size: CGFloat = 30
    var color: Color = V3.t1

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(V3Font.num(size)).tracking(-size * 0.03).foregroundStyle(color)
            if !unit.isEmpty { Text(unit).font(V3Font.text(14)).foregroundStyle(V3.t2) }
        }
    }
}

/// Two-column metric tile with a sparkline (HRV, Resting HR, Bedtime, Respiration).
struct V3Tile: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String
    var unit: String = ""
    var delta: String? = nil
    var deltaColor: Color = V3.t2
    var spark: [Double] = []
    var sparkColor: Color = V3.t2
    var empty: String? = nil

    var body: some View {
        V3Card(padding: 14) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(iconColor)
                Text(title).font(V3Font.text(13, .semibold)).foregroundStyle(V3.t2).lineLimit(1)
            }
            if let empty {
                Text(empty).font(V3Font.text(15, .semibold)).foregroundStyle(V3.t2).padding(.top, 12)
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value).font(V3Font.num(26)).tracking(-0.78).foregroundStyle(V3.t1)
                    if !unit.isEmpty { Text(unit).font(V3Font.text(14)).foregroundStyle(V3.t2) }
                }
                .padding(.top, 10)
                if let delta {
                    Text(delta).font(V3Font.text(12, .semibold)).foregroundStyle(deltaColor).padding(.top, 3)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                if spark.count > 1 {
                    V3Sparkline(values: spark, color: sparkColor).frame(height: 34).padding(.top, 8)
                }
            }
        }
    }
}

/// Label on top, bold value below, as in the board's legends.
struct V3LegendItem: View {
    var dot: Color? = nil
    let label: String
    let value: String
    var valueColor: Color = V3.t1

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(label).font(V3Font.text(12)).foregroundStyle(V3.t2).lineLimit(1)
            }
            Text(value).font(V3Font.text(15, .semibold)).tracking(-0.15).foregroundStyle(valueColor)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A thin labelled progress bar (strain parts, macros).
struct V3MacroBar: View {
    let label: String
    let value: String
    var unit: String = ""
    let fraction: Double
    let color: Color
    var labelColored = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(V3Font.text(12, .semibold)).foregroundStyle(labelColored ? color : V3.t2)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(V3Font.num(17)).tracking(-0.34).foregroundStyle(V3.t1)
                if !unit.isEmpty { Text(unit).font(V3Font.text(12)).foregroundStyle(V3.t2) }
            }
            .padding(.top, 3)
            V3Bar(fraction: fraction, color: color).padding(.top, 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct V3Bar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 6
    var dashed = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(V3.track)
                if dashed {
                    Capsule().strokeBorder(V3.t2, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        .frame(width: max(height, g.size.width * min(max(fraction, 0), 1)))
                } else {
                    Capsule().fill(color).frame(width: max(fraction > 0 ? height : 0, g.size.width * min(max(fraction, 0), 1)))
                }
            }
        }
        .frame(height: height)
    }
}

/// Name, horizontal bar, value: "Late night ▬▬▬ −20".
struct V3BarRow: View {
    let name: String
    let fraction: Double
    let color: Color
    let value: String
    var dashed = false

    var body: some View {
        HStack(spacing: 10) {
            Text(name).font(V3Font.text(12)).foregroundStyle(V3.t2).frame(width: 86, alignment: .leading).lineLimit(1)
            V3Bar(fraction: fraction, color: color, height: 14, dashed: dashed)
            Text(value).font(V3Font.text(13, .semibold)).foregroundStyle(V3.t1).monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.top, 9)
    }
}

/// One list row inside a card: icon well, name and detail, a value on the right.
struct V3ListRow<Accessory: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    var detail: String = ""
    var value: String = ""
    var valueColor: Color = V3.t1
    var valueSub: String = ""
    var first = false
    var dashedIcon = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 0) {
            if !first { Rectangle().fill(V3.line).frame(height: 1) }
            HStack(spacing: 12) {
                if dashedIcon {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(V3.t2)
                        .frame(width: 26, height: 26)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(V3.t2, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])))
                } else {
                    V3IconWell(symbol: icon, color: iconColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(V3Font.text(15, .semibold)).tracking(-0.15).foregroundStyle(V3.t1).lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail).font(V3Font.text(12)).foregroundStyle(V3.t2).lineLimit(1).monospacedDigit()
                    }
                    accessory
                }
                Spacer(minLength: 8)
                if !value.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(value).font(V3Font.text(15, .semibold)).foregroundStyle(valueColor).monospacedDigit()
                        if !valueSub.isEmpty { Text(valueSub).font(V3Font.text(12)).foregroundStyle(V3.t2) }
                    }
                }
            }
            .padding(.top, first ? 2 : 12)
            .padding(.bottom, 12)
        }
    }
}

extension V3ListRow where Accessory == EmptyView {
    init(icon: String, iconColor: Color, title: String, detail: String = "", value: String = "",
         valueColor: Color = V3.t1, valueSub: String = "", first: Bool = false, dashedIcon: Bool = false) {
        self.init(icon: icon, iconColor: iconColor, title: title, detail: detail, value: value, valueColor: valueColor,
                  valueSub: valueSub, first: first, dashedIcon: dashedIcon) { EmptyView() }
    }
}

struct V3Toggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn).labelsHidden().tint(V3.green)
    }
}

struct V3Button: View {
    let title: String
    var symbol: String? = nil
    var secondary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 16, weight: .semibold)) }
                Text(title).font(V3Font.text(16, .semibold)).tracking(-0.16)
            }
            .foregroundStyle(secondary ? V3.t1 : V3.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(secondary ? V3.card2 : V3.t1, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Empty or dead data, drawn the board's way: quiet label, no fake number.
struct V3EmptyLine: View {
    let text: String
    var body: some View {
        Text(text).font(V3Font.text(13)).foregroundStyle(V3.t2)
    }
}

// MARK: - Charts

/// Catmull-Rom path through points, the board's `smooth()` (tension 0.18).
func v3SmoothPath(_ pts: [CGPoint]) -> Path {
    var p = Path()
    guard let first = pts.first else { return p }
    p.move(to: first)
    guard pts.count > 1 else { return p }
    let t: CGFloat = 0.18
    for i in 0..<(pts.count - 1) {
        let p0 = i > 0 ? pts[i - 1] : pts[i], p1 = pts[i], p2 = pts[i + 1]
        let p3 = i + 2 < pts.count ? pts[i + 2] : p2
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) * t, y: p1.y + (p2.y - p0.y) * t)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) * t, y: p2.y - (p3.y - p1.y) * t)
        p.addCurve(to: p2, control1: c1, control2: c2)
    }
    return p
}

struct V3Sparkline: View {
    let values: [Double]
    let color: Color
    var fill = true
    var lo: Double? = nil
    var hi: Double? = nil

    var body: some View {
        GeometryReader { g in
            let pts = points(g.size)
            ZStack {
                if fill, let a = pts.first, let z = pts.last {
                    v3SmoothPath(pts)
                        .addingLine(to: CGPoint(x: z.x, y: g.size.height))
                        .addingLine(to: CGPoint(x: a.x, y: g.size.height))
                        .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                }
                v3SmoothPath(pts).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                if let z = pts.last {
                    Circle().fill(color).frame(width: 7, height: 7)
                        .overlay(Circle().stroke(V3.card, lineWidth: 2))
                        .position(z)
                }
            }
        }
    }

    private func points(_ s: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let pad: CGFloat = 5
        let mn = lo ?? values.min()!, mx = hi ?? values.max()!, rg = (mx - mn) == 0 ? 1 : (mx - mn)
        return values.enumerated().map { i, v in
            CGPoint(x: pad + CGFloat(i) * (s.width - 2 * pad) / CGFloat(values.count - 1),
                    y: pad + CGFloat(1 - (v - mn) / rg) * (s.height - 2 * pad))
        }
    }
}

extension Path {
    func addingLine(to p: CGPoint) -> Path { var c = self; c.addLine(to: p); return c }
}

/// Area chart with a solid past, a dashed future, a "now" rule and an end dot.
/// x is in hours of the day (24+ means after midnight), y in the metric's units.
struct V3AreaChart: View {
    struct P: Identifiable {
        let x: Double
        let y: Double
        var id: Double { x }
    }
    let past: [P]
    var future: [P] = []
    let color: Color
    let xDomain: ClosedRange<Double>
    let yDomain: ClosedRange<Double>
    var ticks: [Double] = []
    var tickLabel: (Double) -> String = { String(format: "%02d", Int($0) % 24) }
    var gridLines: [Double] = []
    var height: CGFloat = 116
    var showNow = true

    var body: some View {
        Chart {
            ForEach(gridLines, id: \.self) { g in
                RuleMark(y: .value("g", g)).foregroundStyle(V3.grid).lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(past) { p in
                AreaMark(x: .value("t", p.x), yStart: .value("lo", yDomain.lowerBound), yEnd: .value("v", p.y))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.32), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
            }
            ForEach(past) { p in
                LineMark(x: .value("t", p.x), y: .value("v", p.y), series: .value("s", "past"))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .interpolationMethod(.catmullRom)
            }
            ForEach(future) { p in
                LineMark(x: .value("t", p.x), y: .value("v", p.y), series: .value("s", "future"))
                    .foregroundStyle(color.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 4]))
                    .interpolationMethod(.catmullRom)
            }
            if showNow, let last = past.last {
                RuleMark(x: .value("now", last.x))
                    .foregroundStyle(V3.t3)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                PointMark(x: .value("t", last.x), y: .value("v", last.y))
                    .symbol { Circle().fill(color).frame(width: 9, height: 9).overlay(Circle().stroke(V3.card, lineWidth: 2.5)) }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartLegend(.hidden)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: ticks) { v in
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(tickLabel(d)).font(V3Font.text(11)).foregroundStyle(V3.t3)
                    }
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Tab bar

extension AppTab {
    var v3Symbol: String {
        switch self {
        case .today: return "circle.circle"
        case .health: return "heart"
        case .strain: return "gauge.with.needle"
        case .insights: return "chart.bar"
        }
    }
}

struct V3TabBar: View {
    @Binding var selected: AppTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.rawValue) { tab in
                Button { selected = tab } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.v3Symbol)
                            .font(.system(size: 20, weight: selected == tab ? .semibold : .regular))
                            .frame(height: 24)
                        Text(tab.label).font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(selected == tab ? V3.t1 : V3.t2)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.label)
            }
        }
        .frame(height: 49, alignment: .top)
        .sensoryFeedback(.selection, trigger: selected)
        .background(alignment: .top) {
            V3.bar
                .overlay(alignment: .top) { Rectangle().fill(V3.line).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

// MARK: - Formatting

enum V3Format {
    static func duration(minutes m: Double) -> String {
        let total = Int(m.rounded())
        return total < 60 ? "\(total)m" : "\(total / 60)h " + String(format: "%02dm", total % 60)
    }
    static func duration(hours h: Double) -> String { duration(minutes: h * 60) }
    static func hhmm(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
    static func dayTitle(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEEE, d MMM"; return f.string(from: d)
    }
    static func shortDay(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEE d MMM"; return f.string(from: d)
    }
    static func signed(_ v: Double, decimals: Int = 0) -> String {
        let s = String(format: "%.\(decimals)f", abs(v))
        return (v < 0 ? "−" : "+") + s
    }
    /// Hours since local midnight, for chart x values.
    static func hourOfDay(_ d: Date, relativeTo day: Date = Date()) -> Double {
        let start = Calendar.current.startOfDay(for: day)
        return d.timeIntervalSince(start) / 3600
    }
}
