import AppKit
import Foundation

private struct LimitWindow {
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }
}

private struct LimitBucket {
    let id: String
    let name: String
    let primary: LimitWindow?
    let secondary: LimitWindow?

    var headlineRemaining: Int? {
        [primary, secondary].compactMap { $0?.remainingPercent }.min()
    }
}

private enum QuotaError: LocalizedError {
    case codexNotFound
    case serverStopped(String)
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "未找到 Codex。请安装并登录 Codex / ChatGPT 桌面版，或安装 Codex CLI。"
        case .serverStopped(let details):
            return details.isEmpty ? "Codex 本地服务没有响应。" : "Codex 本地服务没有响应：\(details)"
        case .invalidResponse:
            return "Codex 返回了无法识别的额度数据。"
        case .serverError(let message):
            return message
        }
    }
}

private final class QuotaClient {
    private let queue = DispatchQueue(label: "com.local.CodexQuota.fetch", qos: .utility)

    func fetch(completion: @escaping (Result<[LimitBucket], Error>) -> Void) {
        queue.async {
            let result = Result { try self.fetchSynchronously() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func fetchSynchronously() throws -> [LimitBucket] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        for root in ["/Applications", home + "/Applications"] {
            for app in ["Codex.app", "ChatGPT.app"] {
                let resources = root + "/" + app + "/Contents/Resources/"
                candidates.append(resources + "codex-cli/CodexCLI.app/Contents/MacOS/codex")
                candidates.append(resources + "codex")
            }
        }
        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex"]
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates += searchPath.split(separator: ":").map { String($0) + "/codex" }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw QuotaError.codexNotFound
        }

        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12, execute: timeout)

        defer {
            timeout.cancel()
            try? standardInput.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        try send([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": ["name": "codex-quota-menubar", "version": "1.1.0"],
                "capabilities": ["experimentalApi": true]
            ]
        ], to: standardInput.fileHandleForWriting)

        var buffer = Data()
        let initialization = try readResponse(id: 1, from: standardOutput.fileHandleForReading, process: process, buffer: &buffer, errorPipe: standardError)
        if let error = initialization["error"] as? [String: Any] {
            throw QuotaError.serverError(error["message"] as? String ?? "Codex 初始化失败，请更新 Codex。")
        }

        try send(["method": "initialized"], to: standardInput.fileHandleForWriting)
        try send(["id": 2, "method": "account/rateLimits/read", "params": NSNull()], to: standardInput.fileHandleForWriting)

        let response = try readResponse(id: 2, from: standardOutput.fileHandleForReading, process: process, buffer: &buffer, errorPipe: standardError)
        if let error = response["error"] as? [String: Any] {
            throw QuotaError.serverError(error["message"] as? String ?? "读取 Codex 额度失败。")
        }
        guard let result = response["result"] as? [String: Any] else {
            throw QuotaError.invalidResponse
        }
        let byId: [String: Any]
        if let mapped = result["rateLimitsByLimitId"] as? [String: Any], !mapped.isEmpty {
            byId = mapped
        } else if let legacy = result["rateLimits"] as? [String: Any] {
            byId = ["codex": legacy]
        } else {
            throw QuotaError.invalidResponse
        }

        let preferredOrder = ["codex", "codex_bengalfox"]
        let orderedIds = preferredOrder.filter { byId[$0] != nil }
            + byId.keys.filter { !preferredOrder.contains($0) }.sorted()

        let buckets = orderedIds.compactMap { id -> LimitBucket? in
            guard let raw = byId[id] as? [String: Any] else { return nil }
            let backendName = raw["limitName"] as? String
            let displayName: String
            if id == "codex" {
                displayName = "Codex"
            } else if let backendName, !backendName.isEmpty {
                displayName = backendName
            } else {
                displayName = id
            }
            return LimitBucket(
                id: id,
                name: displayName,
                primary: parseWindow(raw["primary"]),
                secondary: parseWindow(raw["secondary"])
            )
        }

        guard !buckets.isEmpty else { throw QuotaError.invalidResponse }
        return buckets
    }

    private func parseWindow(_ value: Any?) -> LimitWindow? {
        guard let raw = value as? [String: Any], let used = raw["usedPercent"] as? NSNumber else {
            return nil
        }
        let minutes = (raw["windowDurationMins"] as? NSNumber)?.intValue
        let resetSeconds = (raw["resetsAt"] as? NSNumber)?.doubleValue
        return LimitWindow(
            usedPercent: used.intValue,
            durationMinutes: minutes,
            resetsAt: resetSeconds.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private func send(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func readResponse(
        id: Int,
        from handle: FileHandle,
        process: Process,
        buffer: inout Data,
        errorPipe: Pipe
    ) throws -> [String: Any] {
        while true {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard
                    !line.isEmpty,
                    let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                    (object["id"] as? NSNumber)?.intValue == id
                else { continue }
                return object
            }

            let chunk = handle.availableData
            if chunk.isEmpty {
                let details = String(data: errorPipe.fileHandleForReading.availableData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw QuotaError.serverStopped(details)
            }
            buffer.append(chunk)
            if !process.isRunning && buffer.isEmpty {
                throw QuotaError.serverStopped("")
            }
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let client = QuotaClient()
    private var buckets: [LimitBucket] = []
    private var lastUpdated: Date?
    private var lastError: String?
    private var isRefreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.autosaveName = "CodexQuotaStatusItem"
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.title = "Codex …"
            button.toolTip = "Codex 剩余额度"
        }
        rebuildMenu()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil
        rebuildMenu()

        client.fetch { [weak self] result in
            guard let self else { return }
            self.isRefreshing = false
            switch result {
            case .success(let buckets):
                self.buckets = buckets
                self.lastUpdated = Date()
                self.lastError = nil
            case .failure(let error):
                self.buckets = []
                self.lastError = error.localizedDescription
            }
            self.updateStatusTitle()
            self.rebuildMenu()
        }
    }

    private func updateStatusTitle() {
        statusItem.isVisible = true
        guard let button = statusItem.button else { return }
        let codex = buckets.first(where: { $0.id == "codex" }) ?? buckets.first
        if let remaining = codex?.headlineRemaining {
            button.title = "\(remaining)%"
            button.toolTip = "Codex 剩余 \(remaining)%"
        } else {
            button.title = "--%"
            button.toolTip = lastError ?? "暂时无法读取 Codex 额度"
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let heading = NSMenuItem(title: "Codex 剩余额度", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)

        if buckets.isEmpty {
            let message = isRefreshing ? "正在刷新…" : (lastError ?? "暂无额度数据")
            let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for (index, bucket) in buckets.enumerated() {
                if index > 0 { menu.addItem(.separator()) }
                let remainingText = bucket.headlineRemaining.map { "\($0)% 剩余" } ?? "--"
                let bucketItem = NSMenuItem(title: "\(bucket.name) — \(remainingText)", action: nil, keyEquivalent: "")
                bucketItem.isEnabled = false
                menu.addItem(bucketItem)

                if let primary = bucket.primary {
                    menu.addItem(detailItem(for: primary))
                }
                if let secondary = bucket.secondary {
                    menu.addItem(detailItem(for: secondary))
                }
            }
        }

        menu.addItem(.separator())
        if let lastUpdated {
            let updated = NSMenuItem(title: "更新于 \(Self.timeFormatter.string(from: lastUpdated)) · 每 5 分钟自动刷新", action: nil, keyEquivalent: "")
            updated.isEnabled = false
            menu.addItem(updated)
        }
        if let lastError, !isRefreshing {
            let errorItem = NSMenuItem(title: lastError, action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        let refreshItem = NSMenuItem(title: isRefreshing ? "正在刷新…" : "立即刷新", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !isRefreshing
        menu.addItem(refreshItem)

        let openItem = NSMenuItem(title: "打开 ChatGPT / Codex", action: #selector(openCodex), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Codex Quota", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func detailItem(for window: LimitWindow) -> NSMenuItem {
        let duration = durationLabel(window.durationMinutes)
        let reset = window.resetsAt.map { Self.resetFormatter.string(from: $0) } ?? "未知时间"
        let item = NSMenuItem(
            title: "  \(duration)：\(window.remainingPercent)% · \(reset) 重置",
            action: nil,
            keyEquivalent: ""
        )
        item.isEnabled = false
        return item
    }

    private func durationLabel(_ minutes: Int?) -> String {
        guard let minutes else { return "额度周期" }
        switch minutes {
        case 300: return "5 小时"
        case 1_440: return "24 小时"
        case 10_080: return "7 天"
        default:
            if minutes % 1_440 == 0 { return "\(minutes / 1_440) 天" }
            if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
            return "\(minutes) 分钟"
        }
    }

    @objc private func refreshFromMenu() {
        refresh()
    }

    @objc private func openCodex() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/Applications", home + "/Applications"].flatMap { root in
            [root + "/Codex.app", root + "/ChatGPT.app"]
        }
        if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
        } else {
            let alert = NSAlert()
            alert.messageText = "未找到桌面版"
            alert.informativeText = "如果使用 Codex CLI，请在终端中运行 codex login 并登录自己的 ChatGPT 账号。"
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}

@main
private enum CodexQuotaApp {
    static func main() {
        if CommandLine.arguments.contains("--check") {
            do {
                let buckets = try QuotaClient().fetchSynchronously()
                for bucket in buckets {
                    let value = bucket.headlineRemaining.map { "\($0)%" } ?? "未知"
                    print("\(bucket.name)：剩余 \(value)")
                }
                exit(EXIT_SUCCESS)
            } catch {
                fputs("读取失败：\(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
