// BalanceMenuBar — macOS 菜单栏余额/额度显示（AppKit 原生版，两行）
// 上面一行：DeepSeek 总余额（¥197）；下面一行：Codex 剩余额度（9%）
// DeepSeek: 读取 ~/.dsh/.credentials.yaml 的 DEEPSEEK_API_KEY，查询 /user/balance
// Codex:    调用 codex app-server --stdio 的 account/rateLimits/read
import AppKit
import Foundation

// MARK: - DeepSeek 余额

struct DeepSeekInfo {
    var total: String = "¥--"
    var available: Bool = false
    var updatedAt: Date?
    var error: String?
}

// MARK: - Codex 额度

struct CodexLimitWindow {
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?
    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
}

struct CodexBucket {
    let id: String
    let name: String
    let primary: CodexLimitWindow?
    let secondary: CodexLimitWindow?
    var headlineRemaining: Int? {
        [primary, secondary].compactMap { $0?.remainingPercent }.min()
    }
}

struct CodexInfo {
    var remaining: String = "--%"
    var buckets: [CodexBucket] = []
    var updatedAt: Date?
    var error: String?
}

enum CodexQuotaError: LocalizedError {
    case codexNotFound
    case serverStopped(String)
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "未找到 Codex。请确认 ChatGPT/Codex 已安装在“应用程序”文件夹。"
        case .serverStopped(let details):
            return details.isEmpty ? "Codex 本地服务没有响应。" : "Codex 本地服务没有响应：\(details)"
        case .invalidResponse:
            return "Codex 返回了无法识别的额度数据。"
        case .serverError(let message):
            return message
        }
    }
}

// MARK: - 数据抓取

@MainActor
final class BalanceStore {
    var deepseek = DeepSeekInfo()
    var codex = CodexInfo()
    var onUpdate: (() -> Void)?

    private let keyFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".dsh/.credentials.yaml")
    private let apiURL = URL(string: "https://api.deepseek.com/user/balance")!
    private var timer: Timer?

    init() {
        refreshAll()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    func refreshAll() {
        fetchDeepSeek()
        fetchCodex()
    }

    private func notify() {
        onUpdate?()
    }

    // MARK: DeepSeek

    private func fetchDeepSeek() {
        guard let key = readAPIKey() else {
            deepseek.error = "未找到 DEEPSEEK_API_KEY（~/.dsh/.credentials.yaml）"
            notify()
            return
        }
        var request = URLRequest(url: apiURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.deepseek.error = "请求失败: \(error.localizedDescription)"
                    self.notify()
                    return
                }
                guard let data,
                      let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    self.deepseek.error = "接口返回异常 (HTTP \(String(describing: (response as? HTTPURLResponse)?.statusCode ?? -1)))"
                    self.notify()
                    return
                }
                do {
                    let decoded = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data)
                    if let bal = decoded.balance_infos.first {
                        let raw = Double(bal.total_balance) ?? 0
                        self.deepseek = DeepSeekInfo(
                            total: "¥\(Int(raw.rounded()))",
                            available: decoded.is_available,
                            updatedAt: Date(),
                            error: nil
                        )
                    } else {
                        self.deepseek.error = "响应中没有余额数据"
                    }
                } catch {
                    self.deepseek.error = "解析失败: \(error.localizedDescription)"
                }
                self.notify()
            }
        }.resume()
    }

    private func readAPIKey() -> String? {
        guard let content = try? String(contentsOf: keyFile, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("DEEPSEEK_API_KEY:") {
                let value = trimmed.dropFirst("DEEPSEEK_API_KEY:".count)
                    .trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    // MARK: Codex

    func fetchCodex() {
        codex.error = nil
        Task.detached(priority: .utility) {
            do {
                let buckets = try Self.fetchCodexSynchronously()
                await MainActor.run {
                    self.codex = CodexInfo(
                        remaining: Self.remainingLabel(buckets),
                        buckets: buckets,
                        updatedAt: Date(),
                        error: nil
                    )
                    self.notify()
                }
            } catch {
                await MainActor.run {
                    self.codex = CodexInfo(remaining: "--%", buckets: [], updatedAt: nil, error: error.localizedDescription)
                    self.notify()
                }
            }
        }
    }

    nonisolated private static func remainingLabel(_ buckets: [CodexBucket]) -> String {
        let codex = buckets.first(where: { $0.id == "codex" }) ?? buckets.first
        if let remaining = codex?.headlineRemaining {
            return "\(remaining)%"
        }
        return "--%"
    }

    nonisolated private static func fetchCodexSynchronously() throws -> [CodexBucket] {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex"
        ]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CodexQuotaError.codexNotFound
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
                "clientInfo": ["name": "balance-menubar", "version": "1.0.0"],
                "capabilities": ["experimentalApi": true]
            ]
        ], to: standardInput.fileHandleForWriting)

        var buffer = Data()
        _ = try readResponse(id: 1, from: standardOutput.fileHandleForReading, process: process, buffer: &buffer, errorPipe: standardError)

        try send(["method": "initialized"], to: standardInput.fileHandleForWriting)
        try send(["id": 2, "method": "account/rateLimits/read", "params": NSNull()], to: standardInput.fileHandleForWriting)

        let response = try readResponse(id: 2, from: standardOutput.fileHandleForReading, process: process, buffer: &buffer, errorPipe: standardError)
        if let error = response["error"] as? [String: Any] {
            throw CodexQuotaError.serverError(error["message"] as? String ?? "读取 Codex 额度失败。")
        }
        guard
            let result = response["result"] as? [String: Any],
            let byId = result["rateLimitsByLimitId"] as? [String: Any]
        else {
            throw CodexQuotaError.invalidResponse
        }

        let preferredOrder = ["codex", "codex_bengalfox"]
        let orderedIds = preferredOrder.filter { byId[$0] != nil }
            + byId.keys.filter { !preferredOrder.contains($0) }.sorted()

        let buckets = orderedIds.compactMap { id -> CodexBucket? in
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
            return CodexBucket(
                id: id,
                name: displayName,
                primary: parseWindow(raw["primary"]),
                secondary: parseWindow(raw["secondary"])
            )
        }

        guard !buckets.isEmpty else { throw CodexQuotaError.invalidResponse }
        return buckets
    }

    nonisolated private static func parseWindow(_ value: Any?) -> CodexLimitWindow? {
        guard let raw = value as? [String: Any], let used = raw["usedPercent"] as? NSNumber else {
            return nil
        }
        let minutes = (raw["windowDurationMins"] as? NSNumber)?.intValue
        let resetSeconds = (raw["resetsAt"] as? NSNumber)?.doubleValue
        return CodexLimitWindow(
            usedPercent: used.intValue,
            durationMinutes: minutes,
            resetsAt: resetSeconds.map { Date(timeIntervalSince1970: $0) }
        )
    }

    nonisolated private static func send(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    nonisolated private static func readResponse(
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
                throw CodexQuotaError.serverStopped(details)
            }
            buffer.append(chunk)
            if !process.isRunning && buffer.isEmpty {
                throw CodexQuotaError.serverStopped("")
            }
        }
    }

    nonisolated static func durationLabel(_ minutes: Int?) -> String {
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

    nonisolated static func resetLabel(_ date: Date?) -> String {
        guard let date else { return "未知时间" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 接口响应结构

struct DeepSeekBalanceResponse: Decodable {
    struct BalanceInfoDTO: Decodable {
        let currency: String
        let total_balance: String
        let granted_balance: String
        let topped_up_balance: String
    }
    let is_available: Bool
    let balance_infos: [BalanceInfoDTO]
}

// MARK: - 状态栏两行文本

@MainActor
func updateStatusTitle(button: NSStatusBarButton?, top: String, bottom: String) {
    guard let button else { return }
    let text = "\(top)\n\(bottom)"
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    // 状态栏按钮会限制 paragraph 的负行距，因此用第二行独立的基线偏移
    // 直接收紧两行之间的距离，视觉上约缩短一半。
    para.lineSpacing = -1
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
        .foregroundColor: NSColor.labelColor,
        // 两行文字本身保持固定的紧凑行距；整体位置由下面的图层平移独立控制。
        .baselineOffset: -5.25,
        .paragraphStyle: para
    ]
    let attributed = NSMutableAttributedString(string: text, attributes: attrs)
    let bottomStart = (top as NSString).length + 1 // 换行符
    let bottomLength = (bottom as NSString).length
    attributed.addAttribute(
        .baselineOffset,
        value: -0.5,
        range: NSRange(location: bottomStart, length: bottomLength)
    )
    button.attributedTitle = attributed
    button.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)

    // 只移动整个标题图层，不改变两行文字之间的相对距离。
    // 1.5pt ≈ 3 个 Retina 屏幕像素；重复刷新时 setAffineTransform 不会累加。
    button.wantsLayer = true
    button.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: -1.5))
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = BalanceStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.autosaveName = "DeepSeekBalanceStatusItem"

        store.onUpdate = { [weak self] in
            self?.refreshUI()
        }

        rebuildMenu()
        refreshUI()
    }

    private func refreshUI() {
        if let button = statusItem.button {
            updateStatusTitle(button: button, top: store.deepseek.total, bottom: store.codex.remaining)
            button.toolTip = "DeepSeek \(store.deepseek.total) · Codex 剩余 \(store.codex.remaining)"
        }
        rebuildMenu()
    }

    /// 创建信息展示菜单项：用 noop action（保证系统按正常 enabled 菜单项渲染，文字为 labelColor 而非灰色）
    private func makeInfoItem(_ title: String, bold: Bool = false, color: NSColor? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(infoAction(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        let effectiveColor = color ?? NSColor.labelColor
        let font = bold
            ? NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            : NSFont.systemFont(ofSize: NSFont.systemFontSize)
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: effectiveColor
        ])
        return item
    }

    /// 信息项点击无操作（仅保证正常渲染）
    @objc private func infoAction(_ sender: Any?) {}

    private func rebuildMenu() {
        let menu = NSMenu()

        // DeepSeek 区块
        let dsHeading = makeInfoItem("DeepSeek 余额", bold: true)
        menu.addItem(dsHeading)
        let dsTotal = makeInfoItem("总余额：\(store.deepseek.total)")
        menu.addItem(dsTotal)
        if let err = store.deepseek.error {
            menu.addItem(makeInfoItem(err, color: .orange))
        }

        menu.addItem(.separator())

        // Codex 区块
        let cxHeading = makeInfoItem("Codex 剩余额度", bold: true)
        menu.addItem(cxHeading)

        if store.codex.buckets.isEmpty {
            let message = store.codex.error ?? (store.codex.remaining == "--%" ? "正在刷新…" : store.codex.remaining)
            menu.addItem(makeInfoItem(message))
        } else {
            for bucket in store.codex.buckets {
                let remainingText = bucket.headlineRemaining.map { "\($0)% 剩余" } ?? "--"
                let bucketItem = makeInfoItem("\(bucket.name) — \(remainingText)", bold: true)
                menu.addItem(bucketItem)
                if let primary = bucket.primary {
                    let detail = makeInfoItem(
                        "  \(BalanceStore.durationLabel(primary.durationMinutes))：\(primary.remainingPercent)% · \(BalanceStore.resetLabel(primary.resetsAt)) 重置",
                        color: .labelColor
                    )
                    menu.addItem(detail)
                }
                if let secondary = bucket.secondary {
                    let detail = makeInfoItem(
                        "  \(BalanceStore.durationLabel(secondary.durationMinutes))：\(secondary.remainingPercent)% · \(BalanceStore.resetLabel(secondary.resetsAt)) 重置",
                        color: .labelColor
                    )
                    menu.addItem(detail)
                }
            }
        }

        let times = [store.deepseek.updatedAt, store.codex.updatedAt].compactMap { $0 }
        if let latest = times.max() {
            menu.addItem(.separator())
            let updated = makeInfoItem("更新于 \(Self.timeFormatter.string(from: latest)) · 每 5 分钟自动刷新")
            menu.addItem(updated)
        }

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let openItem = NSMenuItem(title: "打开 DeepSeek 控制台", action: #selector(openDeepSeek), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let openCodexItem = NSMenuItem(title: "打开 ChatGPT / Codex", action: #selector(openCodex), keyEquivalent: "")
        openCodexItem.target = self
        menu.addItem(openCodexItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func refreshFromMenu() {
        store.refreshAll()
    }

    @objc private func openDeepSeek() {
        if let url = URL(string: "https://platform.deepseek.com/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openCodex() {
        let appURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
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
}

// MARK: - Main

@main
private enum BalanceMenuBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
