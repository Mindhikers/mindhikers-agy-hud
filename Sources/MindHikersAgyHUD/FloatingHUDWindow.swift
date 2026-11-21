import AppKit
import Combine
import CoreGraphics
import SwiftUI

enum HUDPositionPreset {
    case composerAligned
    case topRight
    case topLeftNotchSafe
    case topCenter
    case bottomLeft
    case bottomRight
}

/// Borderless panel that forwards right-clicks to a context menu without activating.
final class PillPanel: NSPanel {
    var onRightClick: ((NSEvent) -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }
}

final class FloatingHUDController: NSObject, NSWindowDelegate {
    private let pillPanel: PillPanel
    private let detailPanel: NSPanel
    private let service: TelemetryService
    private let uiState = HUDUIState()
    private let onCopyCallback: () -> Void
    private let onQuitCallback: () -> Void

    private var pillHostingView: NSHostingView<FloatingPillBarView>!
    private var detailHostingView: NSHostingView<FloatingDetailCardView>?
    private var cancellables = Set<AnyCancellable>()
    private var isProgrammaticMove = false
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?

    private let fixedPillHeight: CGFloat = 40
    private var latestMeasuredWidth: CGFloat = 432
    private let posXKey = "MindHikersAgyHUD.floatingX_v7"
    private let posYKey = "MindHikersAgyHUD.floatingY_v7"
    private let screenPrefKey = "MindHikersAgyHUD.preferredScreen"
    private let miniModeKey = "MindHikersAgyHUD.miniMode"

    var preferredScreenName: String {
        get { UserDefaults.standard.string(forKey: screenPrefKey) ?? "auto" }
        set {
            UserDefaults.standard.set(newValue, forKey: screenPrefKey)
            moveToPreset(.topRight)
        }
    }

    init(service: TelemetryService, onCopy: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.service = service
        self.onCopyCallback = onCopy
        self.onQuitCallback = onQuit

        self.pillPanel = PillPanel(
            contentRect: NSRect(x: 0, y: 0, width: 452, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.detailPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 376, height: 260),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        if UserDefaults.standard.object(forKey: miniModeKey) != nil {
            uiState.isMiniMode = UserDefaults.standard.bool(forKey: miniModeKey)
        }

        for panel in [pillPanel, detailPanel] as [NSPanel] {
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hidesOnDeactivate = false
        }
        pillPanel.hasShadow = false
        // Native macOS WindowServer shadow follows the rounded contour with ZERO rectangular clipping box!
        detailPanel.hasShadow = true
        pillPanel.isMovableByWindowBackground = true
        pillPanel.delegate = self
        pillPanel.onRightClick = { [weak self] event in
            self?.presentContextMenu(with: event)
        }

        let pillView = FloatingPillBarView(
            service: service,
            uiState: uiState,
            onSelectCapsule: { [weak self] cap in
                self?.toggleDetail(cap)
            },
            onRightClickMenu: { [weak self] in
                self?.presentContextMenuAtPill()
            },
            onContentWidth: { [weak self] width in
                self?.applyReportedPillWidth(width)
            }
        )
        self.pillHostingView = NSHostingView(rootView: pillView)
        // CRITICAL: Disable automatic window resizing by NSHostingView to prevent 1px upward ratchet drift!
        self.pillHostingView.sizingOptions = []
        pillPanel.contentView = pillHostingView

        // React to tab switches inside the open detail card cleanly
        uiState.$activeCapsule
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] next in
                guard let self = self else { return }
                if let cap = next {
                    self.positionAndShowDetail(cap)
                    self.installDismissMonitors()
                } else {
                    self.detailPanel.orderOut(nil)
                    self.removeDismissMonitors()
                }
            }
            .store(in: &cancellables)

        restoreOrDefaultPosition()
        syncPillWidthKeepingPosition()
    }

    deinit {
        removeDismissMonitors()
    }

    func show() {
        syncPillWidthKeepingPosition()
        pillPanel.orderFrontRegardless()
    }

    func onTelemetryUpdated() {
        // Wait one runloop tick so SwiftUI finishes applying @Published payload before measuring width.
        DispatchQueue.main.async { [weak self] in
            self?.syncPillWidthKeepingPosition()
        }
    }

    private func toggleMiniMode() {
        uiState.isMiniMode.toggle()
        UserDefaults.standard.set(uiState.isMiniMode, forKey: miniModeKey)
        DispatchQueue.main.async { [weak self] in
            self?.syncPillWidthKeepingPosition()
        }
    }

    // MARK: - Independent Detail Panel

    private func toggleDetail(_ cap: ActiveCapsule) {
        if uiState.activeCapsule == cap && detailPanel.isVisible {
            hideDetail()
        } else {
            uiState.activeCapsule = cap
        }
    }

    func hideDetail() {
        uiState.activeCapsule = nil
        detailPanel.orderOut(nil)
        removeDismissMonitors()
    }

    private func positionAndShowDetail(_ cap: ActiveCapsule) {
        let card = FloatingDetailCardView(
            service: service,
            uiState: uiState,
            capsule: cap,
            onClose: { [weak self] in self?.hideDetail() },
            onCopyReport: onCopyCallback,
            onOpenSettingsMenu: { [weak self] in self?.presentContextMenuAtDetail() },
            onToggleMiniMode: { [weak self] in self?.toggleMiniMode() },
            onQuit: onQuitCallback
        )
        let host = NSHostingView(rootView: card)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let w = max(360, ceil(size.width))
        let h = max(190, ceil(size.height))
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.cornerRadius = 14
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true

        self.detailHostingView = host
        detailPanel.contentView = host

        let pillFrame = pillPanel.frame
        let screen = screenContaining(rect: pillFrame) ?? targetScreen()
        let vis = screen.visibleFrame
        let expandDownward = pillFrame.midY >= vis.midY

        var x = pillFrame.maxX - w
        var y = expandDownward ? (pillFrame.minY - h - 8) : (pillFrame.maxY + 8)

        if x + w > vis.maxX - 8 { x = vis.maxX - w - 8 }
        if x < vis.minX + 8 { x = vis.minX + 8 }
        if y < vis.minY + 8 { y = pillFrame.maxY + 8 }
        if y + h > vis.maxY - 8 { y = vis.maxY - h - 8 }

        detailPanel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true, animate: false)
        detailPanel.invalidateShadow()
        detailPanel.orderFrontRegardless()
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.detailPanel.isVisible else { return }
            let loc = NSEvent.mouseLocation
            if !self.pillPanel.frame.contains(loc) && !self.detailPanel.frame.contains(loc) {
                self.hideDetail()
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53, self?.detailPanel.isVisible == true {
                self?.hideDetail()
                return nil
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
    }

    // MARK: - Context / Settings Menu (Right-click pill OR click '⋯' in card)

    private func buildSettingsMenu() -> NSMenu {
        let menu = NSMenu()

        let miniItem = NSMenuItem(
            title: uiState.isMiniMode ? "切换为三胶囊完整模式" : "切换为单胶囊迷你模式",
            action: #selector(menuToggleMini),
            keyEquivalent: ""
        )
        miniItem.target = self
        menu.addItem(miniItem)

        let autoFollowItem = NSMenuItem(
            title: "自动跟随反重力当前会话",
            action: #selector(menuAutoFollow),
            keyEquivalent: ""
        )
        autoFollowItem.state = service.pinnedConversationId == nil ? .on : .off
        autoFollowItem.target = self
        menu.addItem(autoFollowItem)

        menu.addItem(.separator())

        let posMenu = NSMenu()
        let presets: [(String, Selector)] = [
            ("对齐反重力输入栏（推荐）", #selector(menuPosComposer)),
            ("停靠右上角", #selector(menuPosTopRight)),
            ("停靠左上角（刘海安全区）", #selector(menuPosTopLeft)),
            ("停靠顶部居中（刘海下方）", #selector(menuPosTopCenter)),
            ("停靠左下角", #selector(menuPosBottomLeft)),
            ("停靠右下角（避开输入框）", #selector(menuPosBottomRight)),
        ]
        for (title, sel) in presets {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            posMenu.addItem(item)
        }
        let posRoot = NSMenuItem(title: "停靠位置", action: nil, keyEquivalent: "")
        posRoot.submenu = posMenu
        menu.addItem(posRoot)

        let screenMenu = NSMenu()
        let currentPref = preferredScreenName
        let autoScreen = NSMenuItem(title: "跟随 Antigravity 所在屏幕（推荐）", action: #selector(menuSelectScreen(_:)), keyEquivalent: "")
        autoScreen.representedObject = "auto"
        autoScreen.state = currentPref == "auto" ? .on : .off
        autoScreen.target = self
        screenMenu.addItem(autoScreen)
        screenMenu.addItem(.separator())
        for name in NSScreen.screens.map({ $0.localizedName }) {
            let item = NSMenuItem(title: name, action: #selector(menuSelectScreen(_:)), keyEquivalent: "")
            item.representedObject = name
            item.state = currentPref == name ? .on : .off
            item.target = self
            screenMenu.addItem(item)
        }
        let screenRoot = NSMenuItem(title: "显示屏幕", action: nil, keyEquivalent: "")
        screenRoot.submenu = screenMenu
        menu.addItem(screenRoot)

        menu.addItem(.separator())

        let copyItem = NSMenuItem(title: "复制 CLI 格式报告", action: #selector(menuCopy), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(menuRefresh), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 MindHikers AGY HUD", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func presentContextMenu(with event: NSEvent) {
        let menu = buildSettingsMenu()
        if let contentView = pillPanel.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
        }
    }

    private func presentContextMenuAtPill() {
        let menu = buildSettingsMenu()
        if let contentView = pillPanel.contentView {
            menu.popUp(positioning: nil, at: NSPoint(x: 10, y: 0), in: contentView)
        }
    }

    private func presentContextMenuAtDetail() {
        let menu = buildSettingsMenu()
        if let contentView = detailPanel.contentView {
            let pt = NSPoint(x: contentView.bounds.maxX - 36, y: contentView.bounds.maxY - 34)
            menu.popUp(positioning: nil, at: pt, in: contentView)
        }
    }

    @objc private func menuToggleMini() { toggleMiniMode() }
    @objc private func menuAutoFollow() { service.pinnedConversationId = nil }
    @objc private func menuPosComposer() { moveToPreset(.composerAligned) }
    @objc private func menuPosTopRight() { moveToPreset(.topRight) }
    @objc private func menuPosTopLeft() { moveToPreset(.topLeftNotchSafe) }
    @objc private func menuPosTopCenter() { moveToPreset(.topCenter) }
    @objc private func menuPosBottomLeft() { moveToPreset(.bottomLeft) }
    @objc private func menuPosBottomRight() { moveToPreset(.bottomRight) }
    @objc private func menuSelectScreen(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        preferredScreenName = name
    }
    @objc private func menuCopy() { onCopyCallback() }
    @objc private func menuRefresh() { service.refreshNow() }
    @objc private func menuQuit() { onQuitCallback() }

    // MARK: - Multi-Monitor & MacBook Notch Awareness

    private func screenContaining(rect: NSRect) -> NSScreen? {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    private func detectAntigravityFrame() -> NSRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let primaryHeight = primary.frame.height
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var bestArea: CGFloat = 0
        var bestRect: NSRect? = nil
        for w in list {
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
            guard layer == 0, owner.lowercased().contains("antigravity") else { continue }
            if let dict = w[kCGWindowBounds as String] as? [String: Any],
               let x = dict["X"] as? CGFloat,
               let y = dict["Y"] as? CGFloat,
               let width = dict["Width"] as? CGFloat,
               let height = dict["Height"] as? CGFloat,
               width > 200, height > 200 {
                let area = width * height
                if area > bestArea {
                    bestArea = area
                    let appKitY = primaryHeight - (y + height)
                    bestRect = NSRect(x: x, y: appKitY, width: width, height: height)
                }
            }
        }
        return bestRect
    }

    private func detectAntigravityScreen() -> NSScreen? {
        guard let rect = detectAntigravityFrame() else { return nil }
        return screenContaining(rect: rect)
    }

    /// Computes default composer-aligned origin: left edge of the grip aligns right beside
    /// Antigravity's model/reasoning selector while reserving safe right clearance before Turbo.
    private func composerAlignedOrigin(width: CGFloat, on screen: NSScreen) -> NSPoint {
        let vis = screen.visibleFrame
        if let agy = detectAntigravityFrame(),
           screenContaining(rect: agy) == screen,
           agy.width >= 960 {
            let desiredX = agy.minX + round(agy.width * 0.382)
            // Reserve 260pt on the right side of Antigravity's composer for Turbo + voice + action buttons
            let maxSafeX = agy.maxX - 260 - width
            let x = max(agy.minX + 240, min(desiredX, maxSafeX))
            let y = agy.minY + 25
            return NSPoint(x: x, y: y)
        }
        return NSPoint(x: vis.maxX - width - 16, y: vis.maxY - fixedPillHeight - 8)
    }

    private func targetScreen() -> NSScreen {
        let pref = preferredScreenName
        if pref != "auto", let matched = NSScreen.screens.first(where: { $0.localizedName == pref }) {
            return matched
        }
        if let agyScreen = detectAntigravityScreen() {
            return agyScreen
        }
        if let builtIn = NSScreen.screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains("built-in") || $0.safeAreaInsets.top > 0 }) {
            return builtIn
        }
        return NSScreen.screens.first ?? NSScreen.main!
    }

    private func notchRect(on screen: NSScreen) -> NSRect? {
        guard screen.safeAreaInsets.top > 0,
              let auxL = screen.auxiliaryTopLeftArea,
              let auxR = screen.auxiliaryTopRightArea else {
            return nil
        }
        let notchX = auxL.maxX
        let notchW = auxR.minX - auxL.maxX
        guard notchW > 10 else { return nil }
        return NSRect(x: notchX - 8, y: auxL.minY - 4, width: notchW + 16, height: auxL.height + 8)
    }

    private func adjustFrameAvoidingNotch(_ raw: NSRect, on screen: NSScreen) -> NSRect {
        var frame = raw
        let vis = screen.visibleFrame

        if let notch = notchRect(on: screen), frame.intersects(notch) {
            if frame.midX < notch.midX, let auxL = screen.auxiliaryTopLeftArea, frame.width <= auxL.width - 12 {
                frame.origin.x = notch.minX - frame.width
            } else if let auxR = screen.auxiliaryTopRightArea, frame.width <= auxR.width - 12 {
                frame.origin.x = notch.maxX
            } else {
                frame.origin.y = vis.maxY - frame.height - 8
            }
        }

        if frame.maxX > vis.maxX - 8 { frame.origin.x = vis.maxX - frame.width - 8 }
        if frame.minX < vis.minX + 8 { frame.origin.x = vis.minX + 8 }
        if frame.maxY > vis.maxY - 6 { frame.origin.y = vis.maxY - frame.height - 6 }
        if frame.minY < vis.minY + 8 { frame.origin.y = vis.minY + 8 }
        return frame
    }

    func moveToPreset(_ preset: HUDPositionPreset) {
        hideDetail()
        let screen = targetScreen()
        let vis = screen.visibleFrame
        let w = measuredPillWidth()
        let h = fixedPillHeight

        let rawOrigin: NSPoint
        switch preset {
        case .composerAligned:
            rawOrigin = composerAlignedOrigin(width: w, on: screen)
        case .topRight:
            rawOrigin = NSPoint(x: vis.maxX - w - 16, y: vis.maxY - h - 8)
        case .topLeftNotchSafe:
            rawOrigin = NSPoint(x: vis.minX + 16, y: vis.maxY - h - 8)
        case .topCenter:
            rawOrigin = NSPoint(x: vis.midX - w / 2.0, y: vis.maxY - h - 8)
        case .bottomLeft:
            rawOrigin = NSPoint(x: vis.minX + 16, y: vis.minY + 16)
        case .bottomRight:
            rawOrigin = NSPoint(x: vis.maxX - w - 16, y: vis.minY + 96)
        }
        let safeFrame = adjustFrameAvoidingNotch(NSRect(origin: rawOrigin, size: NSSize(width: w, height: h)), on: screen)
        isProgrammaticMove = true
        pillPanel.setFrame(safeFrame, display: true, animate: true)
        isProgrammaticMove = false
        saveOrigin(safeFrame.origin)
    }

    private func measuredPillWidth() -> CGFloat {
        let minW: CGFloat = uiState.isMiniMode ? 104 : 320
        return max(minW, ceil(latestMeasuredWidth))
    }

    private func applyReportedPillWidth(_ rawWidth: CGFloat) {
        guard rawWidth > 40 else { return }
        latestMeasuredWidth = ceil(rawWidth)
        DispatchQueue.main.async { [weak self] in
            self?.syncPillWidthKeepingPosition()
        }
    }

    /// Updates horizontal width only while keeping origin.y strictly constant (ZERO vertical drift!).
    private func syncPillWidthKeepingPosition() {
        let newWidth = measuredPillWidth()
        var frame = pillPanel.frame
        let heightChanged = abs(frame.size.height - fixedPillHeight) > 0.5
        let widthChanged = abs(newWidth - frame.size.width) > 2
        guard heightChanged || widthChanged else { return }

        // Keep left edge pinned (aligned beside model selector) unless docked flush at screen right edge
        if let screen = screenContaining(rect: frame), screen.visibleFrame.maxX - frame.maxX <= 48 {
            let rightEdge = frame.origin.x + frame.size.width
            frame.origin.x = rightEdge - newWidth
        }
        frame.size.width = newWidth
        frame.size.height = fixedPillHeight
        // Notice: frame.origin.y is NEVER touched here!

        if let screen = screenContaining(rect: frame) {
            let vis = screen.visibleFrame
            if frame.maxX > vis.maxX - 8 { frame.origin.x = vis.maxX - frame.width - 8 }
            if frame.minX < vis.minX + 8 { frame.origin.x = vis.minX + 8 }
        }
        isProgrammaticMove = true
        pillPanel.setFrame(frame, display: true, animate: false)
        isProgrammaticMove = false
    }

    private func restoreOrDefaultPosition() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: posXKey) != nil && defaults.object(forKey: posYKey) != nil {
            let savedOrigin = NSPoint(x: defaults.double(forKey: posXKey), y: defaults.double(forKey: posYKey))
            let probeRect = NSRect(origin: savedOrigin, size: NSSize(width: pillPanel.frame.width, height: fixedPillHeight))
            if let screen = screenContaining(rect: probeRect) {
                let safe = adjustFrameAvoidingNotch(probeRect, on: screen)
                isProgrammaticMove = true
                pillPanel.setFrame(safe, display: false, animate: false)
                isProgrammaticMove = false
                return
            }
        }
        let screen = targetScreen()
        let w = measuredPillWidth()
        let origin = composerAlignedOrigin(width: w, on: screen)
        let raw = NSRect(origin: origin, size: NSSize(width: w, height: fixedPillHeight))
        let safe = adjustFrameAvoidingNotch(raw, on: screen)
        isProgrammaticMove = true
        pillPanel.setFrame(safe, display: false, animate: false)
        isProgrammaticMove = false
    }

    private func saveOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set(Double(origin.x), forKey: posXKey)
        UserDefaults.standard.set(Double(origin.y), forKey: posYKey)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove else { return }
        if detailPanel.isVisible {
            hideDetail()
        }
        let frame = pillPanel.frame
        if let screen = screenContaining(rect: frame), let notch = notchRect(on: screen), frame.intersects(notch) {
            let safe = adjustFrameAvoidingNotch(frame, on: screen)
            isProgrammaticMove = true
            pillPanel.setFrameOrigin(safe.origin)
            isProgrammaticMove = false
            saveOrigin(safe.origin)
            return
        }
        saveOrigin(frame.origin)
    }
}
