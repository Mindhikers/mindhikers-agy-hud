import SwiftUI
import AppKit

enum ActiveCapsule: Equatable {
    case session
    case tokens
    case context
}

final class HUDUIState: ObservableObject {
    @Published var activeCapsule: ActiveCapsule? = nil
    @Published var isMiniMode: Bool = false
}

struct FloatingPillBarView: View {
    @ObservedObject var service: TelemetryService
    @ObservedObject var uiState: HUDUIState
    var onSelectCapsule: (ActiveCapsule) -> Void
    var onRightClickMenu: () -> Void
    var onContentWidth: (CGFloat) -> Void

    private var payload: HudPayload? { service.payload }
    private var isOk: Bool { payload?.status == "ok" }

    private var usedPct: Double { payload?.usedPct ?? 0 }
    private var budgetPct: Double { payload?.budgetPct ?? 0 }
    private var overBudget: Bool { payload?.overBudget ?? false }
    private var isRunning: Bool { payload?.isRunning ?? false }
    private var checkpointCount: Int { payload?.checkpointCount ?? 0 }
    private var level: HudLevel { HudFormat.level(usedPct: usedPct, budgetPct: budgetPct, overBudget: overBudget) }

    var body: some View {
        HStack(spacing: 6) {
            if uiState.isMiniMode {
                miniCapsule
            } else {
                fullCapsules
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 40)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { onContentWidth(geo.size.width) }
                    .onChange(of: geo.size.width) { w in onContentWidth(w) }
            }
        )
    }

    private var miniCapsule: some View {
        HStack(spacing: 5) {
            dragGrip
            capsuleButton(active: uiState.activeCapsule != nil) {
                HStack(spacing: 6) {
                    statusDot
                    if isOk {
                        Text(String(format: "%.1f%%", usedPct))
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(level == .normal ? .primary : level.swiftUIColor)
                            .fixedSize(horizontal: true, vertical: false)
                    } else {
                        Text("AGY")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            } action: {
                onSelectCapsule(.context)
            }
        }
    }

    private var fullCapsules: some View {
        HStack(spacing: 6) {
            dragGrip

            // Capsule 1: Live status + Turns + Short model name
            capsuleButton(active: uiState.activeCapsule == .session) {
                HStack(spacing: 5) {
                    statusDot
                    if isOk {
                        Text("\(payload?.userTurns ?? 0) 轮 · \(HudFormat.shortModel(payload?.model ?? "AGY"))")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                    } else {
                        Text(service.errorMessage != nil ? "读取异常" : "等待对话…")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            } action: {
                onSelectCapsule(.session)
            }

            // Capsule 2: Cumulative Tokens + Cache Hit Rate
            if isOk, let totals = payload?.sessionTotals {
                capsuleButton(active: uiState.activeCapsule == .tokens) {
                    HStack(spacing: 4) {
                        Text("✦")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(nsColor: .systemBlue))
                        Text("\(HudFormat.tokens(totals.totalTokens)) · 缓存 \(Int(totals.cacheHitPct.rounded()))%")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                    }
                } action: {
                    onSelectCapsule(.tokens)
                }
            }

            // Capsule 3: Checkpoint badge + Progress bar + Context % (~87% compact width to leave plenty of room before Turbo)
            if isOk {
                capsuleButton(active: uiState.activeCapsule == .context, horizontalPadding: 8.5) {
                    HStack(spacing: 5) {
                        if checkpointCount > 0 {
                            Text("\(checkpointCount)")
                                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(.white)
                                .frame(width: 14.5, height: 14.5)
                                .background(
                                    Circle().fill(
                                        checkpointCount >= 3
                                            ? Color(nsColor: .systemRed)
                                            : checkpointCount == 2
                                                ? Color(nsColor: .systemOrange)
                                                : Color(nsColor: .systemBlue)
                                    )
                                )
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.primary.opacity(0.15))
                                Capsule()
                                    .fill(level.swiftUIColor)
                                    .frame(width: max(4, geo.size.width * CGFloat(min(100, max(0, usedPct)) / 100.0)))
                            }
                        }
                        .frame(width: 34, height: 5.5)

                        Text(String(format: "%.1f%%", usedPct))
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(level == .normal ? .primary : level.swiftUIColor)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                } action: {
                    onSelectCapsule(.context)
                }
            }
        }
    }

    private var dragGrip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary.opacity(0.8))
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
            )
            .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 1.5)
            .help("按住拖动位置 · 右键打开菜单")
    }

    private var statusDot: some View {
        ZStack {
            if isRunning {
                Circle()
                    .fill(Color(nsColor: .systemBlue).opacity(0.28))
                    .frame(width: 11, height: 11)
            }
            Circle()
                .fill(isRunning ? Color(nsColor: .systemBlue) : Color(nsColor: .systemGreen))
                .frame(width: 7, height: 7)
        }
    }

    private func capsuleButton<Content: View>(
        active: Bool,
        horizontalPadding: CGFloat = 10,
        @ViewBuilder label: () -> Content,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            label()
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(
                            active
                                ? Color(nsColor: .controlAccentColor).opacity(0.20)
                                : Color(nsColor: .windowBackgroundColor).opacity(0.92)
                        )
                )
                .overlay(
                    Capsule()
                        .stroke(
                            active
                                ? Color.accentColor.opacity(0.8)
                                : Color.primary.opacity(0.08),
                            lineWidth: active ? 1.0 : 0.5
                        )
                )
                .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 1.5)
        }
        .buttonStyle(.plain)
    }
}

struct FloatingDetailCardView: View {
    @ObservedObject var service: TelemetryService
    @ObservedObject var uiState: HUDUIState
    var capsule: ActiveCapsule
    var onClose: () -> Void
    var onCopyReport: () -> Void
    var onOpenSettingsMenu: () -> Void
    var onToggleMiniMode: () -> Void
    var onQuit: () -> Void

    @State private var copied = false

    private var payload: HudPayload? { service.payload }
    private var usedTokens: Int { payload?.usedTokens ?? 0 }
    private var limitTokens: Int { payload?.limitTokens ?? 0 }
    private var usedPct: Double { payload?.usedPct ?? 0 }
    private var budgetTokens: Int { payload?.requestBudgetTokens ?? 0 }
    private var budgetPct: Double { payload?.budgetPct ?? 0 }
    private var overBudget: Bool { payload?.overBudget ?? false }
    private var isRunning: Bool { payload?.isRunning ?? false }
    private var checkpointCount: Int { payload?.checkpointCount ?? 0 }
    private var level: HudLevel { HudFormat.level(usedPct: usedPct, budgetPct: budgetPct, overBudget: overBudget) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top bar with tab switcher + actions
            HStack(spacing: 6) {
                tabPill("会话", target: .session)
                tabPill("用量", target: .tokens)
                tabPill("水位", target: .context)

                Spacer()

                Button(action: { service.refreshNow() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("立即刷新")

                Button(action: onOpenSettingsMenu) {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("位置与屏幕设置")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }

            Divider().opacity(0.45)

            if let err = service.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(err)
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(nsColor: .systemRed))
                    if service.pinnedConversationId != nil {
                        Button("切回自动追踪最新对话") {
                            service.pinnedConversationId = nil
                        }
                        .controlSize(.small)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.1)))
            } else {
                switch capsule {
                case .context:
                    contextDetailBody
                case .tokens:
                    tokensDetailBody
                case .session:
                    sessionDetailBody
                }
            }

            Divider().opacity(0.35)

            HStack(spacing: 8) {
                Text("100% 本地只读")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(Color(nsColor: .systemGreen))

                Spacer()

                Button(uiState.isMiniMode ? "展开三胶囊" : "迷你模式", action: onToggleMiniMode)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .buttonStyle(.plain)

                Text("·").foregroundColor(.secondary.opacity(0.5))

                Button(action: {
                    onCopyReport()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }) {
                    Text(copied ? "已复制" : "复制报告")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(copied ? Color(nsColor: .systemBlue) : .secondary)
                }
                .buttonStyle(.plain)

                Text("·").foregroundColor(.secondary.opacity(0.5))

                Button("退出", action: onQuit)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(13)
        .frame(width: 360)
        .background(
            ZStack {
                VisualEffectView(material: .popover, blendingMode: .behindWindow, cornerRadius: 14)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.94))
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 0.75)
        )
        .fixedSize(horizontal: true, vertical: true)
    }

    private func tabPill(_ label: String, target: ActiveCapsule) -> some View {
        let active = (capsule == target)
        return Button(action: { uiState.activeCapsule = target }) {
            Text(label)
                .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                .foregroundColor(active ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(active ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
    }

    private var contextDetailBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(payload?.model ?? "Unknown Model")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(HudFormat.tokens(usedTokens))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("/ \(HudFormat.tokens(limitTokens))")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Text(String(format: "%.1f%%", usedPct))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(level.swiftUIColor)
            }

            // Progress bar with request-budget vertical tick
            GeometryReader { geo in
                let usedFrac = limitTokens > 0 ? min(1.0, max(0.0, Double(usedTokens) / Double(limitTokens))) : 0
                let budgetFrac = (limitTokens > 0 && budgetTokens > 0 && budgetTokens < limitTokens)
                    ? Double(budgetTokens) / Double(limitTokens)
                    : nil

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(level.swiftUIColor)
                        .frame(width: max(4, geo.size.width * CGFloat(usedFrac)))

                    if let bf = budgetFrac {
                        Rectangle()
                            .fill(Color(nsColor: .systemOrange))
                            .frame(width: 2, height: 12)
                            .offset(x: geo.size.width * CGFloat(bf) - 1)
                    }
                }
            }
            .frame(height: 10)

            if budgetTokens > 0 {
                HStack(spacing: 4) {
                    Image(systemName: overBudget ? "exclamationmark.triangle.fill" : "gauge.medium")
                        .font(.system(size: 10.5))
                        .foregroundColor(overBudget ? Color(nsColor: .systemOrange) : .secondary)
                    Text(overBudget
                         ? "已超 \(HudFormat.tokens(budgetTokens)) 裁剪线，建议 /compact 或新开对话"
                         : "距 \(HudFormat.tokens(budgetTokens)) 裁剪线剩 \(HudFormat.tokens(max(0, budgetTokens - usedTokens)))（已用 \(String(format: "%.1f%%", budgetPct))）")
                        .font(.system(size: 11))
                        .foregroundColor(overBudget ? Color(nsColor: .systemOrange) : .secondary)
                        .lineLimit(1)
                }
            }

            if let cats = payload?.categories, !cats.isEmpty {
                ScrollView {
                    VStack(spacing: 4.5) {
                        ForEach(cats) { item in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(HudFormat.categoryColor(item.key))
                                    .frame(width: 6.5, height: 6.5)
                                Text(item.nameZh)
                                    .font(.system(size: 11.5))
                                Spacer()
                                Text(HudFormat.tokens(item.tokens))
                                    .font(.system(size: 11.5, design: .monospaced))
                                Text(String(format: "%.1f%%", item.pct))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 135)
            }
        }
    }

    private var tokensDetailBody: some View {
        let totals = payload?.sessionTotals
        return VStack(spacing: 6) {
            statRow("累计总消耗", HudFormat.tokens(totals?.totalTokens ?? 0))
            statRow("缓存读取复用", "\(HudFormat.tokens(totals?.cachedTokens ?? 0)) (\(String(format: "%.1f%%", totals?.cacheHitPct ?? 0)))")
            statRow("非缓存输入", HudFormat.tokens(totals?.inputTokens ?? 0))
            statRow("模型输出总计", HudFormat.tokens(totals?.outputTokens ?? 0))
            statRow("模型调用次数", "\(totals?.generations ?? 0) 次")
            statRow("剩余上下文空间", HudFormat.tokens(payload?.freeTokens ?? 0))
        }
    }

    private var sessionDetailBody: some View {
        let recent = payload?.recentConversations ?? []
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(payload?.title ?? "未命名对话")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(payload?.model ?? "-")
                    Text("·")
                    Text("\(payload?.userTurns ?? 0) 轮 \(payload?.totalSteps ?? 0) 步")
                    if checkpointCount > 0 {
                        Text("·")
                        Text("已压缩 \(checkpointCount) 次")
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }

            Divider().opacity(0.35)

            HStack {
                Text("切换监控会话")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { service.pinnedConversationId = nil }) {
                    HStack(spacing: 3) {
                        Image(systemName: service.pinnedConversationId == nil ? "checkmark.circle.fill" : "bolt.horizontal.circle")
                            .font(.system(size: 10.5))
                        Text("自动跟随反重力")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundColor(service.pinnedConversationId == nil ? Color(nsColor: .systemBlue) : .secondary)
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(recent) { item in
                        let isSelected = (payload?.conversationId == item.id)
                        Button(action: { service.pinnedConversationId = item.id }) {
                            HStack(spacing: 6) {
                                Image(systemName: service.pinnedConversationId == item.id ? "pin.fill" : (isSelected ? "circle.fill" : "circle"))
                                    .font(.system(size: 7))
                                    .foregroundColor(isSelected ? Color(nsColor: .systemBlue) : .secondary.opacity(0.5))
                                Text(item.title)
                                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                                    .foregroundColor(isSelected ? .primary : .secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4.5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 145)
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .lineLimit(1)
        }
    }
}
