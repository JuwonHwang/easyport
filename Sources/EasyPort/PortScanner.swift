import Foundation

struct RemotePort: Identifiable, Hashable {
    let port: Int
    let bindAddress: String
    let process: String?
    /// -L 지정에 쓸 원격 측 대상 주소. 루프백이나 전체 주소에 bind된 포트는 localhost를 쓴다.
    let target: String
    var pid: Int? = nil
    var details: ProcessDetails? = nil
    var http: HTTPProbe? = nil
    var id: Int { port }

    /// 알려진 도구의 포트: VS Code 서버, Claude Code, ssh 터널, 80/443을 제외한 1024 미만 포트.
    var isKnownTool: Bool {
        if let process, process.hasPrefix("code-") || process == "ssh" || process == "sshd" { return true }
        if let command = details?.command {
            if command.contains("/.vscode-server/") || command.hasPrefix("claude ") { return true }
        }
        return port < 1024 && port != 80 && port != 443
    }

    /// HTML 응답이나 리다이렉트를 반환하면 브라우저로 여는 웹 페이지로 본다.
    var isWebPage: Bool {
        guard let http else { return false }
        return http.isHTML || (300..<400).contains(http.status)
    }

    /// 페이지 제목, 없으면 프로세스 이름.
    var displayName: String? {
        if let title = http?.title, !title.isEmpty { return title }
        return process
    }
}

struct HTTPProbe: Hashable {
    let status: Int
    let isHTML: Bool
    let title: String?
}

struct ProcessDetails: Hashable {
    let pid: Int
    let ppid: Int
    /// /proc/<pid>/comm. Linux가 15자까지만 저장한다.
    let name: String
    let command: String
    let directory: String?
    let elapsedSeconds: Int?

    /// Claude Code는 프로세스 이름이 버전 번호(예: 2.1.301)로 나오므로 명령줄로 판별한다.
    var displayName: String {
        command.hasPrefix("claude ") || command == "claude" ? "claude" : name
    }

    var directoryDeleted: Bool { directory?.hasSuffix(" (deleted)") ?? false }

    /// 실행 파일과 인터프리터 경로는 파일 이름만 남긴다.
    var shortCommand: String {
        if command.isEmpty { return name }
        var tokens = command.split(separator: " ").map(String.init)
        for i in tokens.indices.prefix(2) where tokens[i].contains("/") {
            tokens[i] = (tokens[i] as NSString).lastPathComponent
        }
        return tokens.joined(separator: " ")
    }

    var elapsedText: String? {
        guard let s = elapsedSeconds else { return nil }
        switch s {
        case ..<60: return "\(s)초"
        case ..<3600: return "\(s / 60)분"
        case ..<86400: return "\(s / 3600)시간"
        default: return "\(s / 86400)일"
        }
    }
}

struct HostScan {
    let ports: [RemotePort]
    /// 포트를 연 프로세스와 그 조상 프로세스(PID 1 제외).
    let processes: [Int: ProcessDetails]
}

struct TreeRow: Identifiable {
    /// 포트가 없고 자식이 하나뿐인 조상은 한 행으로 합친다. 마지막 원소가 이 행의 프로세스다.
    let chain: [ProcessDetails]
    let depth: Int
    /// 이 프로세스가 연 포트. 조상 프로세스만 표시하는 행은 비어 있다.
    let ports: [RemotePort]
    var process: ProcessDetails { chain[chain.count - 1] }
    var id: Int { process.pid }

    /// 거의 모든 프로세스 위에 있어 구분에 쓸모가 없는 단계.
    private static let plumbing: Set<String> = [
        "sshd", "sshd-session", "bash", "sh", "dash", "zsh", "fish", "login", "sudo", "su", "systemd", "(sd-pam)", "init",
    ]

    /// 조상 체인을 실행 경로로 요약한다. 셸과 sshd 단계는 빼고, 트리 최상위 행이면 시작점을 앞에 붙인다.
    /// 예: sshd › sshd › sshd › bash › claude › bash › uv → "SSH 로그인 › claude › uv"
    var summary: String {
        var parts: [String] = []
        var rest = chain[...]
        if depth == 0, let origin = Self.origin(of: chain[0]) {
            // 시작점 이름으로 바꾼 최상위 프로세스(예: "tmux: server")는 다시 넣지 않는다.
            parts.append(origin)
            rest = rest.dropFirst()
        }
        for p in rest where !Self.plumbing.contains(p.name) {
            let name = p.displayName
            if parts.last != name { parts.append(name) }
        }
        return parts.isEmpty ? process.displayName : parts.joined(separator: " › ")
    }

    private static func origin(of root: ProcessDetails) -> String? {
        switch root.name {
        case "sshd", "sshd-session": return "SSH 로그인"
        case "systemd": return "systemd 서비스"
        case let n where n.hasPrefix("tmux"): return "tmux"
        case let n where n.hasPrefix("code-"): return "VS Code"
        default: return nil
        }
    }
}

extension HostScan {
    /// 주어진 포트를 연 프로세스와 그 조상을 부모-자식 순서로 펼친 행 목록을 만든다.
    func treeRows(for visible: [RemotePort]) -> [TreeRow] {
        var portsByPid: [Int: [RemotePort]] = [:]
        for p in visible {
            if let pid = p.pid { portsByPid[pid, default: []].append(p) }
        }
        var included = Set<Int>()
        for pid in portsByPid.keys {
            var current = pid
            while let d = processes[current], included.insert(current).inserted {
                current = d.ppid
            }
        }
        var children: [Int: [Int]] = [:]
        var roots: [Int] = []
        for pid in included {
            let ppid = processes[pid]!.ppid
            if included.contains(ppid) { children[ppid, default: []].append(pid) } else { roots.append(pid) }
        }
        var rows: [TreeRow] = []
        func visit(_ pid: Int, _ depth: Int) {
            var chain = [processes[pid]!]
            var current = pid
            while portsByPid[current] == nil, let kids = children[current], kids.count == 1, portsByPid[kids[0]] == nil {
                current = kids[0]
                chain.append(processes[current]!)
            }
            rows.append(TreeRow(chain: chain, depth: depth, ports: portsByPid[current] ?? []))
            for child in (children[current] ?? []).sorted() { visit(child, depth + 1) }
        }
        for root in roots.sorted() { visit(root, 0) }
        return rows
    }
}

struct ScanError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum PortScanner {
    private static let hiddenPorts: Set<Int> = [22, 53]

    static func scan(host: String) async throws -> HostScan {
        let (status, out, err) = try await run(
            "/usr/bin/ssh",
            ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", host, "sh", "-s"],
            input: RemoteScript.scan
        )
        guard status == 0 else {
            throw ScanError(message: SSHError.summarize(err) ?? "포트 목록을 가져오지 못했다 (종료 코드 \(status)).")
        }
        let parts = out.components(separatedBy: RemoteScript.procMarker + "\n")
        let ports = parse(parts[0])
        guard parts.count > 1 else { return HostScan(ports: ports, processes: [:]) }
        let rest = parts[1].components(separatedBy: RemoteScript.httpMarker + "\n")
        let details = parseDetails(rest[0])
        let probes = rest.count > 1 ? parseHTTP(rest[1]) : [:]
        let merged = ports.map { p in
            var p = p
            if let pid = p.pid { p.details = details[pid] }
            p.http = probes[p.port]
            return p
        }
        return HostScan(ports: merged, processes: details)
    }

    static func parseHTTP(_ output: String) -> [Int: HTTPProbe] {
        var result: [Int: HTTPProbe] = [:]
        for line in output.split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, let port = Int(f[0]), let status = Int(f[1]) else { continue }
            let title = f.count == 4 ? decodeEntities(f[3]).trimmingCharacters(in: .whitespaces) : ""
            result[port] = HTTPProbe(status: status, isHTML: f[2] == "1", title: title.isEmpty ? nil : title)
        }
        return result
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    static func parseDetails(_ output: String) -> [Int: ProcessDetails] {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return [:] }
        let home = lines.removeFirst()
        var result: [Int: ProcessDetails] = [:]
        for line in lines {
            let f = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6, let pid = Int(f[0]) else { continue }
            var dir = f[4]
            if !home.isEmpty, dir == home || dir.hasPrefix(home + "/") {
                dir = "~" + dir.dropFirst(home.count)
            }
            result[pid] = ProcessDetails(
                pid: pid,
                ppid: Int(f[1]) ?? 0,
                name: f[3],
                command: f[5].trimmingCharacters(in: .whitespaces),
                directory: dir.isEmpty ? nil : dir,
                elapsedSeconds: Int(f[2])
            )
        }
        return result
    }

    static func parse(_ output: String) -> [RemotePort] {
        var byPort: [Int: RemotePort] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 4, fields[0] == "LISTEN" else { continue }
            let local = String(fields[3])
            guard let colon = local.lastIndex(of: ":"),
                  let port = Int(local[local.index(after: colon)...]),
                  !hiddenPorts.contains(port) else { continue }
            var address = String(local[..<colon])
            address = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }

            let rest = fields.dropFirst(5).joined(separator: " ")
            var process: String?
            if let range = rest.range(of: #"users:\(\("([^"]+)""#, options: .regularExpression) {
                process = String(rest[range].dropFirst(9).dropLast())
            }
            var pid: Int?
            if let range = rest.range(of: #"pid=[0-9]+"#, options: .regularExpression) {
                pid = Int(rest[range].dropFirst(4))
            }

            let entry = RemotePort(port: port, bindAddress: address, process: process, target: target(for: address), pid: pid)
            if let existing = byPort[port] {
                // IPv4/IPv6로 중복된 항목은 localhost로 닿는 쪽과 프로세스 이름이 있는 쪽을 남긴다.
                let better = (existing.target != "localhost" && entry.target == "localhost")
                    || (existing.process == nil && entry.process != nil && entry.target == existing.target)
                if better { byPort[port] = entry }
            } else {
                byPort[port] = entry
            }
        }
        return byPort.values.sorted { $0.port < $1.port }
    }

    private static func target(for address: String) -> String {
        switch address {
        case "0.0.0.0", "*", "::", "127.0.0.1", "::1", "localhost":
            return "localhost"
        default:
            return address.contains(":") ? "[\(address)]" : address
        }
    }

    static func run(_ path: String, _ args: [String], input: String? = nil) async throws -> (Int32, String, String) {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            let inPipe = Pipe()
            p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
            // 출력이 파이프 버퍼보다 크면 종료를 기다린 뒤 읽을 때 교착되므로 별도 스레드에서 읽는다.
            let group = DispatchGroup()
            let outData = DataBox(), errData = DataBox()
            group.enter()
            DispatchQueue.global().async { outData.value = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            DispatchQueue.global().async { errData.value = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            p.terminationHandler = { proc in
                group.notify(queue: .global()) {
                    cont.resume(returning: (
                        proc.terminationStatus,
                        String(decoding: outData.value, as: UTF8.self),
                        String(decoding: errData.value, as: UTF8.self)
                    ))
                }
            }
            do {
                try p.run()
                if let input {
                    inPipe.fileHandleForWriting.write(Data(input.utf8))
                    try? inPipe.fileHandleForWriting.close()
                }
            } catch {
                // 읽기 스레드가 EOF를 받도록 쓰기 쪽을 닫는다.
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                cont.resume(throwing: error)
            }
        }
    }
}

enum SSHError {
    private static let keywords = [
        "ssh:", "error", "denied", "refused", "timed out", "could not", "bind", "forward",
        "connection", "closed", "resolve", "unreachable", "host key", "permission",
    ]

    /// ssh stderr에서 배너를 제외하고 오류로 보이는 마지막 줄을 고른다.
    static func summarize(_ stderr: String) -> String? {
        let line = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { line in
                let lower = line.lowercased()
                return keywords.contains { lower.contains($0) }
            }
        // 로컬 네트워크 권한이 없으면 사설 IP 접속이 EHOSTUNREACH로 실패한다.
        if let line, line.contains("No route to host") {
            return line + "\n시스템 설정 > 개인정보 보호 및 보안 > 로컬 네트워크에서 EasyPort가 꺼져 있으면 이 오류가 난다."
        }
        return line
    }
}

/// 읽기 스레드 하나가 쓰고, DispatchGroup 완료 후에만 읽는다.
private final class DataBox: @unchecked Sendable {
    var value = Data()
}
