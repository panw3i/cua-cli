// CUA settings window: permissions, runtime setup, and which local agents get the `cua` skill.
import AppKit
import SwiftUI

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
let home = FileManager.default.homeDirectoryForCurrentUser.path
let cliPath = "\(home)/.local/bin/cua"
let lcuPath = "\(home)/.local/share/lcu/current/bin/lcu"

@main
struct CUAApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            SettingsView()
                .frame(width: 540)
                .fixedSize(horizontal: false, vertical: true)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// `CUA --snapshot FILE.png` writes the window's contents to FILE.png and quits (for docs and checks).
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let view = NSApp.windows.first?.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
    }
}

// MARK: - Shell

@discardableResult
func run(_ path: String, _ args: [String] = [], timeout: TimeInterval = 120) async -> (status: Int32, output: String) {
    await withCheckedContinuation { done in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { p in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
        }
        do { try process.run() } catch {
            done.resume(returning: (127, error.localizedDescription))
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
    }
}

// MARK: - Model

enum CheckState: Equatable {
    case unknown, checking, ok, failed(String)
}

struct Agent: Identifiable {
    let id: String
    let name: String
    let note: String
    let configDir: String      // the agent's home; it counts as installed when this exists
    let symbol: String
    let tint: Color
    var skillDir: String { "\(configDir)/skills/cua" }
}

let agents = [
    Agent(id: "claude", name: "Claude Code", note: "安装为 Skill，新会话生效", configDir: "\(home)/.claude",
          symbol: "sparkle", tint: Color(red: 0.85, green: 0.47, blue: 0.34)),
    Agent(id: "codex", name: "Codex CLI", note: "安装为 Skill，重启 Codex 后生效", configDir: "\(home)/.codex",
          symbol: "chevron.left.forwardslash.chevron.right", tint: Color(red: 0.42, green: 0.36, blue: 0.9)),
]

let skillMarker = ".installed-by-cua"

func skillText() -> String {
    """
    ---
    name: cua
    description: Control desktop apps on this Mac (read UI, click, type, scroll, screenshot) with the `cua` command-line tool. Use when the user asks to operate, inspect or test a native macOS app or its windows.
    ---

    # cua — computer use from the shell

    Run `\(cliPath) instructions` once first and follow what it says: it prints the runtime's own
    instructions, its JavaScript API and its safety rules.

    - Run code: `\(cliPath) js '<javascript>'` (or `-f FILE`, or pipe code on stdin). Variables persist between calls.
    - Start with exactly one of `await cua.getState()` or `let app = await cua.getApp("App Name")`.
    - Images in results are saved to files and printed as `[image: PATH]`; open that file to see the screenshot.
    - Exit status 1 means the runtime reported an error; read its message.
    - `\(cliPath) reset` clears the REPL; run `\(cliPath) end-turn` when the task is done.
    - The first use of each app shows the user an approval dialog. If it is declined, do not retry; ask the user.
    """
}

let otherAgentPrompt = """
你可以用 `\(cliPath)` 命令操作这台 Mac 上的桌面 App。先运行 `\(cliPath) instructions` 阅读说明，\
然后用 `\(cliPath) js '<代码>'` 执行（变量在多次调用之间保留）。返回的 [image: 路径] 是截图文件。\
任务结束后运行 `\(cliPath) end-turn`。
"""

@MainActor
final class Store: ObservableObject {
    @Published var runtimeInstalled = false
    @Published var runtimeLine = ""
    @Published var installing = false
    @Published var installLog = ""
    @Published var accessibility: CheckState = .unknown
    @Published var screen: CheckState = .unknown
    @Published var enabled: [String: Bool] = [:]
    @Published var copied = false

    init() {
        if UserDefaults.standard.bool(forKey: "verified") { accessibility = .ok; screen = .ok }
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        runtimeInstalled = fm.isExecutableFile(atPath: cliPath) && fm.isExecutableFile(atPath: lcuPath)
        for agent in agents {
            enabled[agent.id] = fm.fileExists(atPath: "\(agent.skillDir)/SKILL.md")
        }
        guard fm.isExecutableFile(atPath: lcuPath) else { runtimeLine = "未安装"; return }
        Task {
            let (_, out) = await run(lcuPath, ["--version"], timeout: 30)
            // "lcu 0.13.1 (ChatGPT darwin 26.1013.40934; CUA 0.0.30/...)"
            let line = out.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = line.split(whereSeparator: { " ();".contains($0) })
            if words.count >= 5, words[0] == "lcu", words[2] == "ChatGPT" {
                runtimeLine = "LCU \(words[1]) · ChatGPT \(words[4])"
            } else {
                runtimeLine = line
            }
        }
    }

    func install() {
        guard let script = Bundle.main.path(forResource: "install", ofType: "sh", inDirectory: "cli") else {
            installLog = "App 内缺少 install.sh"
            return
        }
        installing = true
        installLog = ""
        Task {
            let (status, out) = await run("/bin/sh", [script], timeout: 600)
            installing = false
            installLog = status == 0 ? "" : out.split(separator: "\n").suffix(4).joined(separator: "\n")
            refresh()
        }
    }

    /// A real call: select Finder and take a screenshot. The first time, the runtime asks the user to approve
    /// Finder in a dialog, and macOS may ask for Accessibility / Screen Recording.
    func verify() {
        accessibility = .checking
        screen = .checking
        Task {
            let code = #"const app = await cua.getApp("Finder"); const shot = await app.getScreenshot({ emit: false }); nodeRepl.write("CUA_OK " + shot.length)"#
            let (status, out) = await run(cliPath, ["js", code], timeout: 300)
            let lower = out.lowercased()
            if status == 0 && out.contains("CUA_OK") {
                accessibility = .ok
                screen = .ok
                UserDefaults.standard.set(true, forKey: "verified")
            } else {
                let reason = out.split(separator: "\n").last.map(String.init) ?? "验证失败"
                UserDefaults.standard.set(false, forKey: "verified")
                accessibility = lower.contains("accessibility") ? .failed("未授权") : .failed(reason)
                screen = lower.contains("screen") || lower.contains("capture") ? .failed("未授权") : (accessibility == .failed("未授权") ? .unknown : .failed(reason))
            }
            await run(cliPath, ["end-turn"], timeout: 30)
        }
    }

    func setAgent(_ agent: Agent, on: Bool) {
        let fm = FileManager.default
        do {
            if on {
                try fm.createDirectory(atPath: agent.skillDir, withIntermediateDirectories: true)
                try skillText().write(toFile: "\(agent.skillDir)/SKILL.md", atomically: true, encoding: .utf8)
                try "".write(toFile: "\(agent.skillDir)/\(skillMarker)", atomically: true, encoding: .utf8)
            } else if fm.fileExists(atPath: "\(agent.skillDir)/\(skillMarker)") {
                // Only remove a skill this app wrote.
                try fm.removeItem(atPath: agent.skillDir)
            }
        } catch {
            NSSound.beep()
        }
        refresh()
    }

    func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(otherAgentPrompt, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
    }
}

// MARK: - Views

struct SettingsView: View {
    @StateObject private var store = Store()

    var body: some View {
        ZStack {
            Background()
            VStack(alignment: .leading, spacing: 0) {
                Header()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 36)
                    .padding(.bottom, 28)

                if !store.runtimeInstalled {
                    SetupCard(store: store).padding(.bottom, 24)
                }

                SectionTitle(title: "权限", subtitle: "读取屏幕并操作应用所需，只在 agent 发起任务时使用")
                Card {
                    PermissionRow(symbol: "accessibility", title: "辅助功能", detail: "访问应用界面，执行点击、输入与滚动",
                                  state: store.accessibility, pane: "Privacy_Accessibility")
                    Divider().opacity(0.5)
                    PermissionRow(symbol: "rectangle.dashed.badge.record", title: "屏幕录制", detail: "读取屏幕内容，识别需要操作的位置",
                                  state: store.screen, pane: "Privacy_ScreenCapture")
                }
                HStack {
                    Text("系统设置里对应的条目是 ChatGPT Computer Use 和 ChatGPT")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(store.accessibility == .checking ? "验证中…" : "验证权限") { store.verify() }
                        .buttonStyle(PillButton())
                        .disabled(!store.runtimeInstalled || store.accessibility == .checking)
                }
                .padding(.top, 10)
                .padding(.bottom, 26)

                HStack(alignment: .bottom) {
                    SectionTitle(title: "接入本地 Agent", subtitle: "打开后，agent 会学会调用 cua 命令")
                    Spacer()
                    Button { store.copyPrompt() } label: {
                        Label(store.copied ? "已复制提示词" : "其他 Agent", systemImage: store.copied ? "checkmark" : "plus")
                    }
                    .buttonStyle(PillButton())
                    .padding(.bottom, 12)
                }
                Card {
                    ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                        if index > 0 { Divider().opacity(0.5) }
                        AgentRow(agent: agent, isOn: Binding(
                            get: { store.enabled[agent.id] ?? false },
                            set: { store.setAgent(agent, on: $0) }))
                    }
                }
                .disabled(!store.runtimeInstalled)
                .opacity(store.runtimeInstalled ? 1 : 0.55)

                HStack {
                    Text("v\(appVersion)")
                    Spacer()
                    Text(store.runtimeLine)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.top, 26)
                .padding(.bottom, 22)
            }
            .padding(.horizontal, 30)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refresh()
        }
    }
}

struct Background: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.62, green: 0.84, blue: 0.97), Color(red: 0.80, green: 0.90, blue: 0.97),
                                Color(red: 0.93, green: 0.95, blue: 0.98)],
                       startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .top) {
                RadialGradient(colors: [Color.white.opacity(0.6), Color.white.opacity(0)], center: .center,
                               startRadius: 0, endRadius: 260)
                    .frame(width: 520, height: 520)
                    .offset(y: -200)
            }
            .ignoresSafeArea()
    }
}

struct Header: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 104, height: 104)
            Text("Computer Use").font(.system(size: 28, weight: .bold))
            Text("让本地 Agent 使用你的电脑").font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }
}

struct SectionTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.bottom, 12)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.7), lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }
}

struct RowIcon: View {
    let symbol: String
    var tint: Color = Color(red: 0.2, green: 0.5, blue: 0.95)
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 38, height: 38)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let state: CheckState
    let pane: String

    var body: some View {
        HStack(spacing: 14) {
            RowIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            status
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder var status: some View {
        switch state {
        case .ok:
            Label { Text("已授权") } icon: { Circle().fill(.green).frame(width: 8, height: 8) }
                .font(.system(size: 13)).foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small)
        case .unknown, .failed:
            VStack(alignment: .trailing, spacing: 4) {
                Button("前往设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
                .buttonStyle(PillButton())
                if case .failed(let reason) = state {
                    Text(reason).font(.system(size: 10)).foregroundStyle(.red).lineLimit(1).frame(maxWidth: 150, alignment: .trailing)
                } else {
                    Text("未验证").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct AgentRow: View {
    let agent: Agent
    @Binding var isOn: Bool
    private var installed: Bool { FileManager.default.fileExists(atPath: agent.configDir) }

    var body: some View {
        HStack(spacing: 14) {
            RowIcon(symbol: agent.symbol, tint: agent.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name).font(.system(size: 14, weight: .semibold))
                Text(installed ? agent.note : "未检测到 \(agent.configDir.replacingOccurrences(of: home, with: "~"))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.large).disabled(!installed)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

struct SetupCard: View {
    @ObservedObject var store: Store
    var body: some View {
        Card {
            HStack(spacing: 14) {
                RowIcon(symbol: "shippingbox", tint: .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("安装运行环境").font(.system(size: 14, weight: .semibold))
                    Text(store.installLog.isEmpty ? "下载 LCU 并安装 cua 命令行工具，需要已安装 ChatGPT 桌面版" : store.installLog)
                        .font(.system(size: 12)).foregroundStyle(store.installLog.isEmpty ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if store.installing { ProgressView().controlSize(.small) } else {
                    Button("安装") { store.install() }.buttonStyle(PillButton(prominent: true))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }
}

struct PillButton: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.white.opacity(configuration.isPressed ? 0.4 : 0.65)),
                        in: Capsule())
            .opacity(isEnabled ? 1 : 0.5)
    }
}
