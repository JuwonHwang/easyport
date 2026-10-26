import AppKit
import UniformTypeIdentifiers
import Foundation

struct Forward: Codable, Identifiable, Hashable {
    var id = UUID()
    var host: String
    var remotePort: Int
    var remoteTarget: String = "localhost"
    var localPort: Int
    /// 포트 목록에서 만든 포워딩은 원격 프로세스 이름을 기록한다.
    var label: String? = nil
    /// 켜 둔 포워딩은 끊기면 재연결하고, 앱을 다시 실행하면 복원한다.
    var enabled: Bool

    var url: URL { URL(string: "http://localhost:\(localPort)")! }
}

enum ForwardStatus: Equatable {
    case stopped
    case connecting
    case connected
    case failed(String)
}

enum PortCategory {
    case web, service, hidden
}

/// 사용자가 포트에 직접 지정한 분류. 서버와 포트 번호로 저장한다.
enum PortOverride: String, Codable {
    case pinned, hidden
}

enum ScanState {
    case loading
    case loaded(HostScan)
    case failed(String)
}

/// ssh stderr를 스레드 안전하게 모은다.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ data: Data) {
        lock.lock()
        text += String(decoding: data, as: UTF8.self)
        if text.count > 8000 { text = String(text.suffix(4000)) }
        lock.unlock()
    }

    var contents: String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

@MainActor
final class ForwardManager: ObservableObject {
    static let shared = ForwardManager()

    @Published private(set) var forwards: [Forward] = []
    @Published private(set) var status: [UUID: ForwardStatus] = [:]
    @Published private(set) var hosts: [String] = []
    @Published private(set) var scans: [String: ScanState] = [:]
    /// 기존 결과를 보여 주면서 다시 조회 중인 서버.
    @Published private(set) var refreshing: Set<String> = []
    private var lastScan: [String: Date] = [:]
    /// 앱 실행 중 조회에서 열려 있는 것을 확인한 "호스트:포트". 이 포트가 사라지면 포워딩을 지운다.
    private var seenListening: Set<String> = []
    /// 포워딩을 자동으로 지운 이유. 다음에 패널을 열 때 지운다.
    @Published private(set) var notices: [String] = []
    /// 데모 데이터를 직접 넣은 스냅샷 렌더링 중이면 참. 이때는 실제 ssh 조회를 하지 않는다.
    private var previewMode = false
    @Published private(set) var overrides: [String: PortOverride] = [:]
    /// 포워딩한 적이 있는 "호스트:포트".
    @Published private(set) var usedPorts: Set<String> = []

    private var processes: [UUID: Process] = [:]
    private var retryCounts: [UUID: Int] = [:]
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var openWhenReady: Set<UUID> = []

    private let supportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EasyPort", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private var forwardsFile: URL { supportDir.appendingPathComponent("forwards.json") }
    private var prefsFile: URL { supportDir.appendingPathComponent("ports.json") }

    private struct PortPrefs: Codable {
        var overrides: [String: PortOverride] = [:]
        var used: Set<String> = []
    }

    var connectedCount: Int { status.values.filter { $0 == .connected }.count }

    // MARK: - 수명 주기

    func bootstrap() {
        killOrphans()
        loadState()
        for f in forwards where f.enabled { start(f.id) }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in ForwardManager.shared.restartEnabled() }
        }
    }

    /// 저장된 포워딩과 포트 설정을 읽는다. ssh 프로세스는 시작하지 않는다.
    func loadState() {
        reloadHosts()
        if let data = try? Data(contentsOf: forwardsFile),
           let saved = try? JSONDecoder().decode([Forward].self, from: data) {
            forwards = saved
        }
        if let data = try? Data(contentsOf: prefsFile),
           let prefs = try? JSONDecoder().decode(PortPrefs.self, from: data) {
            overrides = prefs.overrides
            usedPorts = prefs.used
        }
        usedPorts.formUnion(forwards.map { portKey($0.host, $0.remotePort) })
        for f in forwards { status[f.id] = .stopped }
    }

    /// 데모 스냅샷용으로 서버 목록과 조회 결과를 직접 지정한다.
    func setPreviewHosts(_ names: [String], scans preview: [String: HostScan]) {
        previewMode = true
        hosts = names
        for (host, scan) in preview { scans[host] = .loaded(scan) }
    }

    /// 데모 스냅샷용으로 한 서버의 조회 상태를 직접 지정한다.
    func setPreviewScan(_ host: String, _ state: ScanState) {
        scans[host] = state
    }

    /// 미리보기용으로 다시 조회 중 상태를 직접 지정한다.
    func setPreviewRefreshing(_ host: String, _ on: Bool) {
        if on { refreshing.insert(host) } else { refreshing.remove(host) }
    }

    /// 데모 스냅샷용으로 포워딩 목록을 비운다. 저장하지 않는다.
    func clearPreviewForwards() {
        forwards.removeAll()
        status.removeAll()
    }

    /// 스냅샷 렌더링용으로 포워딩을 저장하지 않고 추가한다.
    func addPreviewForward(_ f: Forward) {
        forwards.append(f)
        status[f.id] = .stopped
    }

    /// 스냅샷 렌더링용으로 상태를 직접 지정한다.
    func setPreviewStatus(_ id: UUID, _ value: ForwardStatus) {
        status[id] = value
    }

    /// 스캔이 끝날 때까지 기다린다. 스냅샷 렌더링에서 쓴다.
    func scanAndWait(host: String) async {
        scans[host] = .loading
        do {
            scans[host] = .loaded(try await PortScanner.scan(host: host))
        } catch {
            scans[host] = .failed(error.localizedDescription)
        }
    }

    func shutdown() {
        for (_, p) in processes where p.isRunning { p.terminate() }
        processes.removeAll()
    }

    func reloadHosts() {
        let names = SSHConfig.hostNames()
        if names != hosts { hosts = names }
    }

    /// ~/.ssh/config를 기본 텍스트 편집기로 연다. 파일이 없으면 권한 600으로 만든다.
    func openSSHConfig() {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh", isDirectory: true)
        let file = dir.appendingPathComponent("config")
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        // 확장자가 없어 기본 앱이 정해지지 않으므로, 일반 텍스트의 기본 편집기로 연다.
        let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText)
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - 포워딩 조작

    /// 같은 호스트와 원격 포트의 포워딩이 있으면 켜고, 없으면 새로 만든다.
    func connect(host: String, remotePort: Int, remoteTarget: String = "localhost", label: String? = nil, open: Bool) {
        let id: UUID
        if let existing = forwards.first(where: {
            $0.host == host && $0.remotePort == remotePort && $0.remoteTarget == remoteTarget
        }) {
            id = existing.id
            if let label, let i = forwards.firstIndex(where: { $0.id == id }) { forwards[i].label = label }
        } else {
            let used = Set(forwards.map(\.localPort))
            let local = LocalPort.firstFree(from: remotePort, excluding: used)
            let f = Forward(host: host, remotePort: remotePort, remoteTarget: remoteTarget, localPort: local, label: label, enabled: true)
            forwards.append(f)
            status[f.id] = .stopped
            id = f.id
        }
        if usedPorts.insert(portKey(host, remotePort)).inserted { savePrefs() }
        if open {
            if status[id] == .connected {
                openInBrowser(id)
            } else {
                openWhenReady.insert(id)
            }
        }
        setEnabled(id, true)
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let i = forwards.firstIndex(where: { $0.id == id }) else { return }
        forwards[i].enabled = enabled
        save()
        if enabled {
            retryCounts[id] = 0
            start(id)
        } else {
            stop(id)
        }
    }

    func remove(_ id: UUID) {
        stop(id)
        forwards.removeAll { $0.id == id }
        status[id] = nil
        save()
    }

    /// 로컬 포트를 비어 있는 다른 번호로 바꾸고 다시 연결한다.
    func reassignLocalPort(_ id: UUID) {
        guard let i = forwards.firstIndex(where: { $0.id == id }) else { return }
        stop(id)
        let used = Set(forwards.map(\.localPort))
        forwards[i].localPort = LocalPort.firstFree(from: forwards[i].localPort + 1, excluding: used)
        save()
        if forwards[i].enabled { start(id) }
    }

    func openInBrowser(_ id: UUID) {
        guard let f = forwards.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(f.url)
    }

    func copyURL(_ id: UUID) {
        guard let f = forwards.first(where: { $0.id == id }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(f.url.absoluteString, forType: .string)
    }

    /// 서버의 포트를 조회한다. 이전 결과가 있으면 화면을 비우지 않고 뒤에서 다시 조회한다.
    func scan(host: String) {
        guard !previewMode, !refreshing.contains(host), scans[host].map({ if case .loading = $0 { false } else { true } }) ?? true else { return }
        if case .loaded = scans[host] {
            refreshing.insert(host)
        } else {
            scans[host] = .loading
        }
        lastScan[host] = Date()
        Task {
            do {
                let result = try await PortScanner.scan(host: host)
                scans[host] = .loaded(result)
                reconcileForwards(host: host, scan: result)
            } catch {
                scans[host] = .failed(error.localizedDescription)
            }
            refreshing.remove(host)
        }
    }

    /// 조회 결과로 이 서버의 포워딩을 맞춘다. 조회가 성공했을 때만 호출한다.
    /// - 포트가 열려 있으면 이름(페이지 제목, 명령줄)을 최신 정보로 바꾼다.
    /// - 이전에 열려 있던 포트가 사라졌으면 프로세스가 내려간 것으로 보고 포워딩을 지운다.
    ///   한 번도 열린 것을 확인하지 못한 포워딩(서버가 뜨기 전에 번호로 미리 연 경우)은 지우지 않는다.
    private func reconcileForwards(host: String, scan: HostScan) {
        let byPort = Dictionary(scan.ports.map { ($0.port, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = false
        for f in forwards where f.host == host {
            let key = portKey(host, f.remotePort)
            if let port = byPort[f.remotePort] {
                seenListening.insert(key)
                let label = port.http?.title ?? port.details?.shortCommand ?? port.process
                if let label, label != f.label, let i = forwards.firstIndex(where: { $0.id == f.id }) {
                    forwards[i].label = label
                    changed = true
                }
            } else if seenListening.contains(key) {
                seenListening.remove(key)
                notices.append("\(host):\(f.remotePort) \(f.label ?? "")의 프로세스가 종료되어 포워딩을 지웠다.")
                remove(f.id)
            }
        }
        if changed { save() }
    }

    /// 패널을 열 때 이전 알림을 지운다.
    func clearNotices() {
        notices.removeAll()
    }

    /// 처음 조회 중이거나 기존 결과를 두고 다시 조회 중이면 참.
    func isScanning(_ host: String) -> Bool {
        if refreshing.contains(host) { return true }
        if case .loading = scans[host] { return true }
        return false
    }

    /// 패널을 열 때 호출한다. 펼친 서버 중 마지막 조회 후 5초가 지난 서버만 다시 조회한다.
    func refreshOnOpen(_ hosts: Set<String>) {
        for host in hosts where Date().timeIntervalSince(lastScan[host] ?? .distantPast) > 5 {
            scan(host: host)
        }
    }

    // MARK: - 포트 분류

    private func portKey(_ host: String, _ port: Int) -> String { "\(host):\(port)" }

    func override(host: String, port: Int) -> PortOverride? {
        overrides[portKey(host, port)]
    }

    func setOverride(host: String, port: Int, _ value: PortOverride?) {
        overrides[portKey(host, port)] = value
        savePrefs()
    }

    /// 직접 지정, 사용 기록, 소유자, 알려진 도구, HTTP 응답 순서로 분류한다.
    func category(host: String, port: RemotePort) -> PortCategory {
        switch override(host: host, port: port.port) {
        case .pinned: return .web
        case .hidden: return .hidden
        case nil: break
        }
        if usedPorts.contains(portKey(host, port.port)) { return .web }
        if port.pid == nil || port.isKnownTool { return .hidden }
        return port.isWebPage ? .web : .service
    }

    // MARK: - 원격 프로세스 종료

    func confirmTerminate(host: String, process: ProcessDetails) {
        var ports: [Int] = []
        if case .loaded(let scan) = scans[host] {
            ports = scan.ports.filter { $0.pid == process.pid }.map(\.port)
        }
        var info = "\(host)에서 이 프로세스에 SIGTERM을 보낸다."
        if !ports.isEmpty { info += "\n포트: " + ports.map(String.init).joined(separator: ", ") }
        if !process.command.isEmpty { info += "\n명령: \(process.command)" }
        if let dir = process.directory { info += "\n디렉터리: \(dir)" }
        if !ports.isEmpty { info += "\n이 포트의 포워딩은 함께 끈다." }
        guard ask("\(process.name) (PID \(process.pid)) 종료", info, button: "종료") else { return }
        Task { await terminate(host: host, process: process, ports: ports, force: false) }
    }

    private func terminate(host: String, process: ProcessDetails, ports: [Int], force: Bool) async {
        let status: Int32
        let stderr: String
        do {
            (status, _, stderr) = try await PortScanner.run(
                "/usr/bin/ssh",
                ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", host, "sh", "-s"],
                input: RemoteScript.terminate(pid: process.pid, name: process.name, startTime: process.startTime, force: force)
            )
        } catch {
            inform("종료 실패", "ssh를 실행하지 못했다: \(error.localizedDescription)")
            return
        }
        switch status {
        case 0, 3:
            if status == 3 {
                inform("종료하지 않음", "PID \(process.pid)가 이미 종료되었거나, 조회 이후 다른 프로세스가 같은 PID를 쓰고 있다. 포트 목록을 다시 조회한다.")
            }
            for f in forwards where f.host == host && ports.contains(f.remotePort) {
                setEnabled(f.id, false)
            }
        case 5:
            if !force, ask(
                "\(process.name) (PID \(process.pid))가 실행 중",
                "SIGTERM을 보내고 3초가 지나도 종료되지 않았다. SIGKILL로 강제 종료하면 프로세스가 정리 작업 없이 즉시 종료된다.",
                button: "강제 종료"
            ) {
                await terminate(host: host, process: process, ports: ports, force: true)
                return
            }
        case 4:
            inform("종료 실패", "PID \(process.pid)에 신호를 보내지 못했다. 다른 사용자의 프로세스일 수 있다.")
        default:
            inform("종료 실패", SSHError.summarize(stderr) ?? "ssh가 종료 코드 \(status)로 끝났다.")
        }
        scan(host: host)
    }

    private func ask(_ title: String, _ info: String, button: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func inform(_ title: String, _ info: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.runModal()
    }

    // MARK: - ssh 프로세스

    private func start(_ id: UUID) {
        guard let f = forwards.first(where: { $0.id == id }), processes[id] == nil else { return }
        retryTasks[id]?.cancel()
        retryTasks[id] = nil

        // 포트를 점유한 것이 이전 실행에서 남은 EasyPort의 ssh라면 정리하고 다시 확인한다.
        if !LocalPort.isFree(f.localPort) { killOrphans() }
        guard LocalPort.isFree(f.localPort) else {
            status[id] = .failed("로컬 포트 \(f.localPort)를 다른 프로세스가 사용 중이다. 메뉴에서 로컬 포트를 바꿀 수 있다.")
            return
        }

        status[id] = .connecting
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = Self.sshOptions + [
            "-L", "127.0.0.1:\(f.localPort):\(f.remoteTarget):\(f.remotePort)",
            f.host,
        ]
        let err = Pipe()
        let buffer = OutputBuffer()
        err.fileHandleForReading.readabilityHandler = { handle in
            buffer.append(handle.availableData)
        }
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { proc in
            err.fileHandleForReading.readabilityHandler = nil
            let message = SSHError.summarize(buffer.contents)
            Task { @MainActor in
                ForwardManager.shared.processEnded(id, proc, message: message)
            }
        }
        do {
            try p.run()
        } catch {
            status[id] = .failed("ssh를 실행하지 못했다: \(error.localizedDescription)")
            return
        }
        processes[id] = p
        waitUntilListening(id, p, port: f.localPort)
    }

    private func stop(_ id: UUID) {
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        openWhenReady.remove(id)
        if let p = processes.removeValue(forKey: id) {
            p.terminate()
            }
        status[id] = .stopped
    }

    private func waitUntilListening(_ id: UUID, _ p: Process, port: Int) {
        Task {
            for _ in 0..<100 {
                try? await Task.sleep(for: .milliseconds(300))
                guard processes[id] === p else { return }
                if LocalPort.accepts(port) {
                    status[id] = .connected
                    retryCounts[id] = 0
                    if openWhenReady.remove(id) != nil { openInBrowser(id) }
                    return
                }
            }
        }
    }

    private func processEnded(_ id: UUID, _ p: Process, message: String?) {
        // stop()으로 종료했거나 이미 교체된 프로세스는 무시한다.
        guard processes[id] === p else { return }
        processes[id] = nil
        guard let f = forwards.first(where: { $0.id == id }), f.enabled else {
            status[id] = .stopped
            return
        }
        let attempt = (retryCounts[id] ?? 0) + 1
        retryCounts[id] = attempt
        let delay = min(30, 1 << min(attempt, 5))
        status[id] = .failed((message ?? "연결이 끊어졌다.") + " \(delay)초 후 재연결한다.")
        retryTasks[id] = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            start(id)
        }
    }

    private func restartEnabled() {
        for f in forwards where f.enabled {
            if let p = processes.removeValue(forKey: f.id) { p.terminate() }
            retryCounts[f.id] = 0
            start(f.id)
        }
    }

    // MARK: - 저장

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(forwards) {
            try? data.write(to: forwardsFile, options: .atomic)
        }
    }

    private func savePrefs() {
        if let data = try? JSONEncoder().encode(PortPrefs(overrides: overrides, used: usedPorts)) {
            try? data.write(to: prefsFile, options: .atomic)
        }
    }

    /// EasyPort가 띄우는 ssh의 고정 인자. 남은 프로세스를 찾을 때도 이 인자로 판별한다.
    private static let sshOptions = [
        "-N", "-T",
        "-o", "BatchMode=yes",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
    ]

    /// 앱이 정리하지 못하고 종료되어 남은 EasyPort의 ssh를 종료한다.
    /// 부모가 PID 1이고 명령줄이 EasyPort의 인자 조합으로 시작하는 프로세스만 대상으로 한다.
    /// 지금 실행 중인 앱의 ssh는 부모가 이 앱이므로 해당하지 않는다.
    @discardableResult
    private func killOrphans() -> Int {
        let prefix = (["/usr/bin/ssh"] + Self.sshOptions + ["-L", "127.0.0.1:"]).joined(separator: " ")
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return 0 }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()

        var killed: [pid_t] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let pid = pid_t(f[0]), f[1] == "1", f[2].hasPrefix(prefix) else { continue }
            if kill(pid, SIGTERM) == 0 { killed.append(pid) }
        }
        // 로컬 포트가 풀릴 때까지 최대 1초 기다린다.
        for _ in 0..<20 where killed.contains(where: { kill($0, 0) == 0 }) {
            usleep(50_000)
        }
        return killed.count
    }
}
