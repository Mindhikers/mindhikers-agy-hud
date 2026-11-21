import Foundation
import Combine

final class TelemetryService: ObservableObject {
    @Published var payload: HudPayload?
    @Published var errorMessage: String?
    @Published var lastRefreshedAt: Date?
    @Published var pinnedConversationId: String? = nil {
        didSet {
            lastQuickStamp = ""
            refreshNow()
        }
    }

    var onPayloadChanged: ((HudPayload?) -> Void)?

    private var timer: Timer?
    private let workQueue = DispatchQueue(label: "com.mindhikers.agyhud.telemetry", qos: .utility)
    private var isFetching = false
    private var lastQuickStamp = ""
    private let conversationsDir: URL
    private let annotationsDir: URL
    private let parserPath: String?

    init() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity", isDirectory: true)
        self.conversationsDir = base.appendingPathComponent("conversations", isDirectory: true)
        self.annotationsDir = base.appendingPathComponent("annotations", isDirectory: true)
        self.parserPath = TelemetryService.locateParserScript()
    }

    static func locateParserScript() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []

        if let resURL = Bundle.main.resourceURL {
            candidates.append(resURL.appendingPathComponent("hud_parser.py").path)
        }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent("Resources/hud_parser.py").path)
        candidates.append(exeDir.appendingPathComponent("../Resources/hud_parser.py").path)
        candidates.append(exeDir.appendingPathComponent("../../Resources/hud_parser.py").path)
        candidates.append(fm.currentDirectoryPath + "/Resources/hud_parser.py")

        for path in candidates {
            let std = URL(fileURLWithPath: path).standardized.path
            if fm.fileExists(atPath: std) {
                return std
            }
        }
        return nil
    }

    func start() {
        refreshNow()
        timer?.invalidate()
        // 1.5s lightweight stat-only check for snappy conversation-switch tracking
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pollIfNeeded()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refreshNow() {
        lastQuickStamp = ""
        pollIfNeeded(force: true)
    }

    private func scanDirStamp(_ dir: URL, suffixes: [String], pinned: String?) -> String {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "empty"
        }

        var bestId = ""
        var bestMtime: TimeInterval = 0
        var bestSize: Int = 0
        var count = 0

        for url in items {
            let name = url.lastPathComponent
            guard let matched = suffixes.first(where: { name.hasSuffix($0) }) else { continue }
            let baseId = String(name.dropLast(matched.count))
            if let pinned = pinned, baseId != pinned { continue }
            count += 1
            if let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) {
                let mt = vals.contentModificationDate?.timeIntervalSince1970 ?? 0
                let sz = vals.fileSize ?? 0
                if mt > bestMtime {
                    bestMtime = mt
                    bestId = baseId
                    bestSize = sz
                }
            }
        }
        return "\(count)|\(bestId)|\(Int64(bestMtime * 1000))|\(bestSize)"
    }

    private func computeQuickStamp(pinned: String?) -> String {
        let convStamp = scanDirStamp(conversationsDir, suffixes: [".db-wal", ".db"], pinned: pinned)
        // Always include annotations dir stamp in auto mode so switching tabs in Antigravity triggers immediately!
        let annStamp = scanDirStamp(annotationsDir, suffixes: [".pbtxt"], pinned: pinned)
        return "\(pinned ?? "auto")::\(convStamp)::\(annStamp)"
    }

    private func pollIfNeeded(force: Bool = false) {
        let pinned = self.pinnedConversationId
        workQueue.async { [weak self] in
            guard let self = self else { return }
            if self.isFetching { return }

            let stamp = self.computeQuickStamp(pinned: pinned)
            if !force && stamp == self.lastQuickStamp && self.payload != nil {
                return
            }

            guard let script = self.parserPath else {
                DispatchQueue.main.async {
                    self.errorMessage = "未找到解析脚本 hud_parser.py"
                }
                return
            }

            self.isFetching = true
            defer { self.isFetching = false }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            var args = [script, "--recent-limit", "8"]
            if let pinned = pinned, !pinned.isEmpty {
                args.append(contentsOf: ["--conversation-id", pinned])
            }
            process.arguments = args

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    DispatchQueue.main.async {
                        self.errorMessage = msg?.isEmpty == false ? msg : "本地解析退出码 \(process.terminationStatus)"
                    }
                    return
                }

                let decoded = try JSONDecoder().decode(HudPayload.self, from: data)
                self.lastQuickStamp = stamp
                DispatchQueue.main.async {
                    self.payload = decoded
                    self.errorMessage = decoded.status == "error" ? (decoded.message ?? "读取失败") : nil
                    self.lastRefreshedAt = Date()
                    self.onPayloadChanged?(decoded)
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "读取本地对话失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
