import SwiftUI
import AppKit

// MARK: - 主题

enum Theme {
    static let accentStart = Color(red: 30 / 255, green: 111 / 255, blue: 224 / 255)  // #1E6FE0
    static let accentEnd = Color(red: 23 / 255, green: 195 / 255, blue: 178 / 255)    // #17C3B2

    static let accentGradient = LinearGradient(
        colors: [accentStart, accentEnd],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let glassGradient = LinearGradient(
        colors: [Color.white.opacity(0.18), Color.white.opacity(0.05)],
        startPoint: .top,
        endPoint: .bottom
    )

    static var cardBackground: Color { Color(nsColor: .controlBackgroundColor) }
    static var cardBorder: Color { Color.gray.opacity(0.12) }
    static var windowBackground: Color { Color(nsColor: .windowBackgroundColor) }

    // MARK: - 统一设计令牌（圆角 / 阴影尺度）
    /// 卡片圆角：柔和但有结构感
    static let radiusCard: CGFloat = 14
    /// 控件（按钮 / 输入框）圆角
    static let radiusControl: CGFloat = 10
    /// 小元素圆角
    static let radiusSmall: CGFloat = 7
    /// 卡片柔和投影，营造悬浮层次
    static let cardShadowColor: Color = Color.black.opacity(0.07)
    static let cardShadowRadius: CGFloat = 9
    static let cardShadowY: CGFloat = 3

    static func usageColor(_ percent: Double) -> Color {
        switch percent {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }
}

// MARK: - 卡片容器

struct Card<Content: View>: View {
    let content: Content
    let padding: CGFloat

    init(padding: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.radiusCard)
                        .fill(Theme.cardBackground)
                    // 顶部细微高光，制造「玻璃面板」的层次
                    RoundedRectangle(cornerRadius: Theme.radiusCard)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.10), Color.clear],
                                startPoint: .top,
                                endPoint: UnitPoint(x: 0.5, y: 0.35)
                            )
                        )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusCard)
                        .stroke(Theme.cardBorder, lineWidth: 1)
                )
            )
            .shadow(
                color: Theme.cardShadowColor,
                radius: Theme.cardShadowRadius,
                x: 0,
                y: Theme.cardShadowY
            )
    }
}

// MARK: - 区块标题

struct SectionHeader: View {
    let title: String
    let icon: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            trailing
        }
    }
}

extension SectionHeader {
    init(title: String, icon: String, @ViewBuilder trailing: () -> some View) {
        self.title = title
        self.icon = icon
        self.trailing = AnyView(trailing())
    }
}

// MARK: - 进度条

struct GradientProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15))

                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: max(0, min(geo.size.width, geo.size.width * progress)))
                    .overlay(
                        LinearGradient(
                            colors: [Color.white.opacity(0.25), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    )
            }
        }
        .frame(height: 6)
    }
}

// MARK: - 状态药丸

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.10))
        .clipShape(Capsule())
    }
}

// MARK: - 统一页面头部卡片

/// 各功能 Tab 顶部的大标题卡：图标 + 标题 + 副标题 + 右侧操作。
/// 所有「磁盘 / Metal / 启动 / 映射」等右侧页面统一使用此组件。
struct TabHeaderCard<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: Trailing

    init(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        Card {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Theme.accentStart.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.accentStart)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                trailing
            }
        }
    }
}

// MARK: - 页面顶栏（统一框架，每个功能页顶部复用）

struct PageHeader: View {
    let icon: String
    let title: String
    var subtitle: String = ""

    var body: some View {
        HStack(spacing: 13) {
            // 渐变图标徽章
            ZStack {
                RoundedRectangle(cornerRadius: 11)
                    .fill(Theme.accentGradient)
                    .frame(width: 40, height: 40)
                    .shadow(color: Theme.accentStart.opacity(0.25), radius: 4, y: 2)
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.primary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

// MARK: - 信息行

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Spacer()
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - 复用卡片组件（概览 / 系统页共用）

/// CPU / 内存 使用率卡
struct UsageCard: View {
    let title: String
    let icon: String
    let percent: Double
    let color: Color

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(color)
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                    Text("\(String(format: "%.1f", percent))%")
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                        .foregroundStyle(color)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.35), value: percent)
                }
                GradientProgressBar(progress: percent / 100, color: color)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 网速卡：下行为主，上行次要
struct NetworkCard: View {
    let down: Double
    let up: Double

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.blue)
                        Text("网速")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Spacer()
                    Text(formatRateShort(down))
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(.blue)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.35), value: down)
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(formatRateShort(up))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 温度卡
struct TempCard: View {
    let temperature: Double?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "thermometer")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text("温度")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Spacer()
                    Text(tempText(temperature))
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                        .foregroundStyle(temperature != nil ? Color.orange : .secondary)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.35), value: temperature)
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 磁盘使用行
struct DiskUsageRow: View {
    let disk: SystemInfoService.DiskUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "externaldrive")
                        .foregroundStyle(Theme.accentEnd)
                        .font(.system(size: 12))
                    Text(disk.volumeName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                Spacer()
                Text("\(formatBytes(disk.usedBytes)) / \(formatBytes(disk.totalBytes))")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GradientProgressBar(
                progress: disk.usagePercent / 100,
                color: Theme.usageColor(disk.usagePercent)
            )
            Text(disk.mountPoint)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// 趋势行 + 迷你折线
struct TrendRow: View {
    let title: String
    let value: String
    let values: [Double]
    let color: Color
    let max: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.35), value: value)
            }
            Sparkline(values: values, color: color, maxValue: max)
                .frame(height: 36)
        }
    }
}

/// 内存统计小格
@MainActor
func memoryStatView(_ label: String, _ bytes: Double, _ color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(label)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        Text(formatBytesShort(bytes))
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundStyle(color)
    }
}

/// 共享格式化器（静态缓存，避免每次刷新重复创建 ByteCountFormatter）
/// 仅主线程访问（格式化函数只在 View 中使用），故隔离到 MainActor。
@MainActor
private enum Formatters {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useAll]
        f.countStyle = .file
        return f
    }()
    static let bytesShort: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .memory
        return f
    }()
    static let rate: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB, .useKB]
        f.countStyle = .decimal
        return f
    }()
}

/// 短格式速率（去除空格，用于菜单栏/紧凑 UI）
@MainActor
func formatRateShort(_ bps: Double) -> String {
    Formatters.rate.string(fromByteCount: Int64(bps)).replacingOccurrences(of: " ", with: "")
}

/// 带 /s 后缀的速率（用于趋势行）
@MainActor
func formatRate(_ bytesPerSec: Double) -> String {
    "\(Formatters.rate.string(fromByteCount: Int64(bytesPerSec)))/s"
}

/// 温度文本（nil 显示破折号）
func tempText(_ t: Double?) -> String {
    guard let t = t else { return "—" }
    return String(format: "%.0f°C", t)
}

/// 磁盘字节（GB/MB/TB）
@MainActor
func formatBytes(_ bytes: Int64) -> String {
    Formatters.bytes.string(fromByteCount: bytes)
}

/// 内存字节（GB/MB）
@MainActor
func formatBytesShort(_ bytes: Double) -> String {
    Formatters.bytesShort.string(fromByteCount: Int64(bytes))
}

/// 解析人类可读的大小字符串（如 "212.5MB"、"1.2GB"、"800K"）为字节数。
/// 用于解析 brew cleanup -n 等命令输出。解析失败返回 0。
func parseByteSize(_ text: String) -> Int64 {
    let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
    guard !trimmed.isEmpty else { return 0 }
    // 分离数字与单位
    var numberPart = ""
    var unitPart = ""
    var hitNonDigit = false
    for ch in trimmed {
        if !hitNonDigit && (ch.isNumber || ch == ".") {
            numberPart.append(ch)
        } else {
            hitNonDigit = true
            unitPart.append(ch)
        }
    }
    guard let value = Double(numberPart), !value.isNaN else { return 0 }
    let multiplier: Int64
    switch unitPart {
    case "B":   multiplier = 1
    case "K", "KB": multiplier = 1024
    case "M", "MB": multiplier = 1024 * 1024
    case "G", "GB": multiplier = 1024 * 1024 * 1024
    case "T", "TB": multiplier = 1024 * 1024 * 1024 * 1024
    default:    multiplier = 1
    }
    return Int64(value * Double(multiplier))
}

// MARK: - 空状态

struct EmptyState: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.accentGradient)
                .padding(12)
                .background(
                    Circle()
                        .fill(Theme.accentGradient.opacity(0.08))
                )
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 毛玻璃材质

/// macOS 原生磨砂玻璃封装，是「精致感」的核心来源。
/// - 主窗口根背景用 `blendingMode: .behindWindow` 透出桌面壁纸；
/// - 侧栏/气泡用 `.withinWindow` 在窗口内做层叠质感。
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        // 允许子视图（卡片）落在材质之上，形成层次
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
