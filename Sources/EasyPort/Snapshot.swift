import AppKit
import SwiftUI

/// `EasyPort --snapshot <디렉터리>`: 실제 서버를 조회해 패널을 PNG로 렌더링하고 종료한다.
/// 포워딩은 시작하지 않는다. 레이아웃 점검용이다.
/// `--demo`를 붙이면 서버에 접속하지 않고 가상 데이터로 README용 스크린샷을 만든다.
@MainActor
enum Snapshot {
    static func run(outputDir: String, demo: Bool) {
        if demo {
            runDemo(outputDir: outputDir)
            return
        }
        let manager = ForwardManager.shared
        manager.loadState()
        if manager.forwards.isEmpty {
            manager.addPreviewForward(Forward(host: "dev-server", remotePort: 8000, localPort: 8000, label: "Dashboard", enabled: true))
            manager.addPreviewForward(Forward(host: "gpu-server-with-a-long-name", remotePort: 47800, localPort: 47800, label: "python -m some.module.with.a.long.name serve --host 127.0.0.1 --port 47800", enabled: true))
            manager.addPreviewForward(Forward(host: "gpu-server", remotePort: 54857, remoteTarget: "[fd00::1234:5678]", localPort: 54857, enabled: false))
        }
        if let first = manager.forwards.first {
            manager.setPreviewStatus(first.id, .failed("ssh: connect to host 192.0.2.10 port 22: No route to host\n시스템 설정 > 개인정보 보호 및 보안 > 로컬 네트워크에서 EasyPort가 꺼져 있으면 이 오류가 난다. 4초 후 재연결한다."))
        }
        if manager.forwards.count > 1 { manager.setPreviewStatus(manager.forwards[1].id, .connected) }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for host in manager.hosts {
                    group.addTask { await manager.scanAndWait(host: host) }
                }
            }
            for (name, tree) in [("list", false), ("tree", true)] {
                UserDefaults.standard.set(tree, forKey: "treeView")
                for scheme in [NSAppearance.Name.aqua, .darkAqua] {
                    render(manager, appearance: scheme, to: "\(outputDir)/panel-\(name)-\(scheme == .aqua ? "light" : "dark").png")
                }
            }
            NSApp.terminate(nil)
        }
    }

    // MARK: - 데모

    private static func runDemo(outputDir: String) {
        let manager = ForwardManager.shared
        manager.setPreviewHosts(["gpu-box", "dev-server", "staging"], scans: ["gpu-box": DemoData.gpuBox])
        let forwards = [
            Forward(host: "gpu-box", remotePort: 6006, localPort: 6006, label: "TensorBoard", enabled: true),
            Forward(host: "gpu-box", remotePort: 8888, localPort: 8888, label: "JupyterLab", enabled: true),
            Forward(host: "dev-server", remotePort: 3000, localPort: 3000, label: "Grafana", enabled: false),
        ]
        for f in forwards { manager.addPreviewForward(f) }
        manager.setPreviewStatus(forwards[0].id, .connected)
        manager.setPreviewStatus(forwards[1].id, .connected)
        for (name, tree) in [("list", false), ("tree", true)] {
            UserDefaults.standard.set(tree, forKey: "treeView")
            for scheme in [NSAppearance.Name.aqua, .darkAqua] {
                render(
                    manager, appearance: scheme, expanded: ["gpu-box"], framed: true,
                    to: "\(outputDir)/screenshot-\(name)-\(scheme == .aqua ? "light" : "dark").png"
                )
            }
        }
        NSApp.terminate(nil)
    }

    private static func render(
        _ manager: ForwardManager, appearance: NSAppearance.Name,
        expanded: Set<String>? = nil, framed: Bool = false, to path: String
    ) {
        let panel = PanelView(initialExpanded: expanded ?? Set(manager.hosts))
            .environmentObject(manager)
            .background(Color(nsColor: .windowBackgroundColor))
        let view = Group {
            if framed {
                // README용: 둥근 패널과 배경을 붙인다.
                panel
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.12)))
                    .padding(28)
                    .background(appearance == .aqua ? Color(white: 0.94) : Color(white: 0.09))
            } else {
                panel
            }
        }
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        let size = hosting.fittingSize
        // 비활성 창으로 그리면 켜진 스위치가 회색으로 나오므로, 화면 밖에 띄워 활성 창으로 만든다.
        let window = KeyWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
        print("저장: \(path) \(Int(size.width))x\(Int(size.height))")
    }
}

private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - 데모 데이터

/// README 스크린샷용 가상 서버. 실제 서버 정보를 담지 않는다.
private enum DemoData {
    private static func proc(
        _ pid: Int, _ ppid: Int, _ name: String, _ command: String = "",
        dir: String? = nil, elapsed: Int = 86400 * 3, claude: Bool = false
    ) -> ProcessDetails {
        ProcessDetails(
            pid: pid, ppid: ppid, name: name, command: command, directory: dir,
            elapsedSeconds: elapsed, launchedByClaude: claude
        )
    }

    private static func port(
        _ port: Int, _ p: ProcessDetails?, http: HTTPProbe?, bind: String = "127.0.0.1"
    ) -> RemotePort {
        RemotePort(
            port: port, bindAddress: bind, process: p?.name, target: "localhost",
            pid: p?.pid, details: p, http: http
        )
    }

    static let gpuBox: HostScan = {
        let procs: [ProcessDetails] = [
            proc(900, 1, "systemd", "/lib/systemd/systemd --user", elapsed: 86400 * 40),
            proc(1200, 900, "uv", "uv run uvicorn app:app --port 8000", dir: "~/model-dashboard", elapsed: 86400 * 12),
            proc(1201, 1200, "uvicorn", "~/model-dashboard/.venv/bin/python uvicorn app:app --port 8000", dir: "~/model-dashboard", elapsed: 86400 * 12),
            proc(3000, 1, "tmux: server", "tmux new -s train", elapsed: 86400 * 6),
            proc(3001, 3000, "bash", "-bash", dir: "~/research", elapsed: 86400 * 6),
            proc(3050, 3001, "tensorboard", "python tensorboard --logdir runs --port 6006", dir: "~/research", elapsed: 86400 * 6),
            proc(3100, 3001, "python", "python serve_api.py --port 8001", dir: "~/research", elapsed: 3600 * 5),
            proc(4100, 1, "sshd", "sshd: me [priv]", elapsed: 3600 * 2),
            proc(4101, 4100, "sshd", "sshd: me@pts/1", elapsed: 3600 * 2),
            proc(4102, 4101, "bash", "-bash", elapsed: 3600 * 2),
            proc(4200, 4102, "jupyter-lab", "python jupyter-lab --no-browser --port 8888", dir: "~/notebooks", elapsed: 3600 * 2),
            proc(4300, 4102, "claude", "claude", dir: "~/research", elapsed: 3600),
            proc(4310, 4300, "bash", "/bin/bash -c uv run python monitor.py --port 8790", dir: "~/research", elapsed: 1800, claude: true),
            proc(4311, 4310, "python", "python monitor.py --port 8790", dir: "~/research", elapsed: 1800, claude: true),
            proc(5000, 1, "python", "python -m vllm.entrypoints.openai.api_server --port 8080", dir: "~/serving", elapsed: 86400 * 9),
            proc(5001, 5000, "VLLM::EngineCor", "VLLM::EngineCore", dir: "~/serving", elapsed: 86400 * 9),
            proc(700, 1, "code-1a2b3c4d5e", "~/.vscode-server/code-1a2b3c4d5e agent host", elapsed: 86400 * 20),
        ]
        let byPid = Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) })
        let ports = [
            port(6006, byPid[3050], http: HTTPProbe(status: 200, isHTML: true, title: "TensorBoard")),
            port(8000, byPid[1201], http: HTTPProbe(status: 200, isHTML: true, title: "Model Dashboard"), bind: "0.0.0.0"),
            port(8001, byPid[3100], http: HTTPProbe(status: 404, isHTML: false, title: nil)),
            port(8080, byPid[5000], http: HTTPProbe(status: 404, isHTML: false, title: nil)),
            port(8790, byPid[4311], http: HTTPProbe(status: 200, isHTML: true, title: "Experiment Monitor")),
            port(8888, byPid[4200], http: HTTPProbe(status: 302, isHTML: false, title: "JupyterLab")),
            port(11434, nil, http: HTTPProbe(status: 200, isHTML: false, title: nil)),
            port(35111, byPid[700], http: HTTPProbe(status: 403, isHTML: false, title: nil)),
            port(41231, byPid[5001], http: nil),
            port(41232, byPid[5001], http: nil),
        ]
        return HostScan(ports: ports, processes: byPid)
    }()
}
