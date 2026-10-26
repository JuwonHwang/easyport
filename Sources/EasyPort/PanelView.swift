import ServiceManagement
import SwiftUI

struct PanelView: View {
    @EnvironmentObject private var manager: ForwardManager
    @AppStorage("lastHost") private var quickHost = ""
    @State private var quickPort = ""
    /// 서버는 기본으로 모두 펼친다. 사용자가 접은 서버만 기록하므로 SSH 설정에 새로 추가한 서버도 펼친 상태로 나온다.
    @State private var collapsed: Set<String>
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @AppStorage("treeView") private var treeView = false

    /// 화면에서 쓸 수 있는 높이에서 다른 구역이 차지하는 높이(약 360pt)를 뺀 값. 300~720pt로 제한한다.
    private static var hostListMaxHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return min(720, max(300, screen - 360))
    }

    /// initialExpanded를 주면 그 서버만 펼친다(스냅샷용). 주지 않으면 모두 펼친다.
    init(initialExpanded: Set<String>? = nil) {
        let hosts = Set(ForwardManager.shared.hosts)
        _collapsed = State(initialValue: initialExpanded.map { hosts.subtracting($0) } ?? [])
    }

    private var expanded: Set<String> {
        Set(manager.hosts).subtracting(collapsed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("포워딩") { forwardList }
            section("서버", trailing: { hostControls }) { hostList }
            section("번호 입력") { quickConnect }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 440)
        // 메뉴바 패널의 기본 배경은 반투명이라 뒤 창(어두운 터미널 등)이 비쳐 글자 대비가 떨어진다. 불투명한 창 배경색으로 칠한다.
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if quickHost.isEmpty || !manager.hosts.contains(quickHost) {
                quickHost = manager.hosts.first ?? ""
            }
            // 서버가 기본으로 펼쳐져 있어 펼칠 때 조회가 시작되지 않으므로, 처음 나타날 때 조회한다.
            manager.refreshOnOpen(expanded)
        }
        // 메뉴바 패널은 닫아도 뷰가 유지되어 onAppear가 다시 호출되지 않으므로, 창이 열릴 때(키 창이 될 때) 새로고침한다.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // 종료 확인 창(NSAlert)이 키 창이 될 때는 제외한다.
            guard let window = note.object as? NSWindow,
                  !String(describing: type(of: window)).contains("Alert") else { return }
            manager.clearNotices()
            manager.reloadHosts()
            manager.refreshOnOpen(expanded)
        }
    }

    // MARK: - 포워딩 목록

    @ViewBuilder private var forwardList: some View {
        ForEach(manager.notices, id: \.self) { notice in
            Label(notice, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if manager.forwards.isEmpty {
            Text("포워딩이 없다. 아래에서 서버의 포트를 고르거나 번호를 입력한다.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(manager.forwards) { f in
                        ForwardRow(forward: f, status: manager.status[f.id] ?? .stopped)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 번호 입력

    private var quickConnect: some View {
        HStack(spacing: 6) {
            Picker("서버", selection: $quickHost) {
                ForEach(manager.hosts, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            // 실제 패널에서는 팝업 버튼이 남는 폭을 모두 채우므로 내용 폭에 고정한다.
            .fixedSize()
            .accessibilityLabel("서버")
            Spacer()
            Text("포트")
                .foregroundStyle(.secondary)
                .fixedSize()
            TextField("8000", text: $quickPort)
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
                .accessibilityLabel("원격 포트")
                .onSubmit(submitQuick)
            Button("열기", action: submitQuick)
                .keyboardShortcut(.defaultAction)
                .disabled(Int(quickPort) == nil || quickHost.isEmpty)
        }
    }

    private func submitQuick() {
        guard let port = Int(quickPort), (1...65535).contains(port), !quickHost.isEmpty else { return }
        manager.connect(host: quickHost, remotePort: port, open: true)
        quickPort = ""
    }

    // MARK: - 서버 목록

    @ViewBuilder private var hostList: some View {
        if manager.hosts.isEmpty {
            Text("~/.ssh/config에 Host 항목이 없다.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(manager.hosts, id: \.self) { host in
                        HostSection(host: host, expanded: binding(for: host))
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: Self.hostListMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func binding(for host: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(host) },
            set: { open in
                if open {
                    collapsed.remove(host)
                    if manager.scans[host] == nil { manager.scan(host: host) }
                } else {
                    collapsed.insert(host)
                }
            }
        )
    }

    // MARK: - 하단

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("로그인 시 실행", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = "로그인 항목을 변경하지 못했다: \(error.localizedDescription)"
                        }
                    }
                Spacer()
                Button("SSH 설정 열기") { manager.openSSHConfig() }
                    .help("~/.ssh/config를 기본 텍스트 편집기로 연다. 고친 내용은 패널을 다시 열 때 반영된다.")
                    .buttonStyle(.link)
                    .fixedSize()
                Button("종료") { NSApp.terminate(nil) }
                    .buttonStyle(.link)
                    .fixedSize()
            }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
        }
        .font(.callout)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        section(title, trailing: { EmptyView() }, content: content)
    }

    private func section<Trailing: View, Content: View>(
        _ title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                trailing()
            }
            .frame(height: 16)
            content()
        }
    }

    /// 목록/트리 전환은 모든 서버에 함께 적용되고 새로고침은 모든 서버를 다시 조회하므로, 제목 줄에 한 번만 둔다.
    /// 펼침 여부와 관계없이 항상 보인다.
    @ViewBuilder private var hostControls: some View {
        IconButton(
            symbol: treeView ? "list.bullet" : "list.bullet.indent",
            label: treeView ? "목록 보기" : "프로세스 트리 보기"
        ) { treeView.toggle() }
        IconButton(symbol: "arrow.clockwise", label: "모든 서버 다시 조회") {
            for host in manager.hosts { manager.scan(host: host) }
        }
        .disabled(manager.hosts.contains { manager.isScanning($0) })
    }
}

// MARK: - 포워딩 행

private struct ForwardRow: View {
    @EnvironmentObject private var manager: ForwardManager
    let forward: Forward
    let status: ForwardStatus
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .accessibilityLabel(statusText)
                .help(statusText)
            VStack(alignment: .leading, spacing: 2) {
                // 1행: 서비스 이름, 2행: 주소. 둘 다 한 줄로 고정하고 넘치면 말줄임으로 자른다.
                Text(forward.label ?? "\(forward.host):\(String(forward.remotePort))")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("localhost:\(String(forward.localPort)) ← \(forward.host):\(String(forward.remotePort))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                IconButton(symbol: "safari", label: "브라우저에서 열기") { manager.openInBrowser(forward.id) }
                    .disabled(status != .connected)
                IconButton(symbol: "doc.on.doc", label: "URL 복사") { manager.copyURL(forward.id) }
                Toggle("포워딩 켜기", isOn: Binding(
                    get: { forward.enabled },
                    set: { manager.setEnabled(forward.id, $0) }
                ))
                .toggleStyle(StatusSwitchStyle())
                .labelsHidden()
                .padding(.horizontal, 2)
                Menu {
                    Button("로컬 포트 변경") { manager.reassignLocalPort(forward.id) }
                    Divider()
                    Button("삭제", role: .destructive) { manager.remove(forward.id) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("포워딩 메뉴")
            }
            .fixedSize()
        }
        .modifier(ErrorFooter(status: status))
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if status == .connected { manager.openInBrowser(forward.id) } }
        .help("localhost:\(String(forward.localPort)) ← \(forward.host):\(String(forward.remotePort))\n더블클릭하면 브라우저에서 연다.")
    }

    private var color: Color {
        switch status {
        case .stopped: .gray
        case .connecting: .yellow
        case .connected: .green
        case .failed: .red
        }
    }

    private var statusText: String {
        switch status {
        case .stopped: "꺼짐"
        case .connecting: "연결 중"
        case .connected: "연결됨"
        case .failed: "오류"
        }
    }
}

/// 오류 문장을 행 아래에 전체 폭으로 붙인다. 잘리면 원인을 알 수 없으므로 줄바꿈해 전부 보여 준다.
private struct ErrorFooter: ViewModifier {
    let status: ForwardStatus

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            content
            if case .failed(let message) = status {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 16)
            }
        }
    }
}

/// Claude Code가 띄운 프로세스 표시.
private struct ClaudeBadge: View {
    var body: some View {
        Text("Claude")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color(red: 0.85, green: 0.47, blue: 0.34).opacity(0.15)))
            .fixedSize()
            .help("Claude Code가 띄운 프로세스 (환경 변수 CLAUDECODE=1)")
            .accessibilityLabel("Claude Code가 띄운 프로세스")
    }
}

/// 직접 그리는 스위치. 시스템 스위치는 창이 비활성이면(브라우저가 앞에 있을 때 등) 켜진 상태도 회색으로 그려서,
/// 창 상태와 관계없이 켜짐은 초록, 꺼짐은 회색으로 그린다.
private struct StatusSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Capsule()
            .fill(configuration.isOn ? Color.green : Color.primary.opacity(0.15))
            .frame(width: 26, height: 15)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
                    .padding(1.5)
            }
            .animation(.easeOut(duration: 0.15), value: configuration.isOn)
            .contentShape(Capsule())
            .onTapGesture { configuration.isOn.toggle() }
            .accessibilityElement()
            .accessibilityLabel("포워딩 켜기")
            .accessibilityValue(configuration.isOn ? "켜짐" : "꺼짐")
            .accessibilityAddTraits(.isButton)
            .help(configuration.isOn ? "포워딩 끄기" : "포워딩 켜기")
    }
}

/// 아이콘만 있는 버튼. 클릭 영역을 22pt로 넓히고 접근성 라벨과 툴팁을 붙인다.
private struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .help(label)
    }
}

// MARK: - 서버 항목

private struct HostSection: View {
    @EnvironmentObject private var manager: ForwardManager
    let host: String
    @Binding var expanded: Bool
    @State private var showService = false
    @State private var showHidden = false
    @AppStorage("treeView") private var treeView = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)
                Text(host)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                // 진행 표시가 나타나고 사라질 때 줄 높이가 바뀌어 패널 크기가 흔들리지 않도록, 줄 높이 안에 드는 크기의 자리를 항상 둔다.
                ZStack {
                    if manager.isScanning(host) {
                        ProgressView()
                            .controlSize(.mini)
                            .help("포트를 조회하는 중")
                    }
                }
                .frame(width: 16, height: 16)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            // 애니메이션을 쓰면 패널 창 크기가 내용 높이를 한 박자 늦게 따라가 스크롤바가 깜박인다.
            .onTapGesture { expanded.toggle() }

            if expanded {
                content
                    .padding(.leading, 28)
                    .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch manager.scans[host] {
        case .none, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("열린 포트를 조회하는 중이다.").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        case .loaded(let scan) where scan.ports.isEmpty:
            Text("열린 포트가 없다.").font(.caption).foregroundStyle(.secondary)
        case .loaded(let scan):
            let web = scan.ports.filter { manager.category(host: host, port: $0) == .web }
            let service = scan.ports.filter { manager.category(host: host, port: $0) == .service }
            let hidden = scan.ports.filter { manager.category(host: host, port: $0) == .hidden }
            VStack(alignment: .leading, spacing: 0) {
                if web.isEmpty && !(treeView && (showService || showHidden)) {
                    Text("웹 페이지로 응답하는 포트가 없다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
                if treeView {
                    let visible = web + (showService ? service : []) + (showHidden ? hidden : [])
                    ForEach(scan.treeRows(for: visible)) { row in
                        ProcessTreeRow(host: host, row: row)
                    }
                    // PID를 알 수 없는 포트(다른 사용자의 프로세스)는 트리에 넣을 수 없어 따로 표시한다.
                    ForEach(visible.filter { $0.pid == nil }) { port in
                        PortRow(host: host, port: port)
                    }
                } else {
                    ForEach(web) { PortRow(host: host, port: $0) }
                    if showService { groupHeader("기타 서비스") }
                    if showService { ForEach(service) { PortRow(host: host, port: $0) } }
                    if showHidden { groupHeader("숨김") }
                    if showHidden { ForEach(hidden) { PortRow(host: host, port: $0) } }
                }
                HStack(spacing: 12) {
                    if !service.isEmpty {
                        Button(showService ? "기타 서비스 접기" : "기타 서비스 \(service.count)개") { showService.toggle() }
                            .help("내 프로세스이지만 HTML로 응답하지 않는 포트(API, 내부 통신)")
                    }
                    if !hidden.isEmpty {
                        Button(showHidden ? "숨김 접기" : "숨김 \(hidden.count)개") { showHidden.toggle() }
                            .help("다른 사용자의 프로세스, VS Code, Claude Code, ssh 터널, 시스템 포트, 직접 숨긴 포트")
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.top, 4)
            }
        }
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.top, 6)
    }
}

// MARK: - 포트 메뉴

/// 포트 행과 트리 행이 함께 쓰는 우클릭 메뉴.
private struct PortMenu: View {
    @EnvironmentObject private var manager: ForwardManager
    let host: String
    let ports: [RemotePort]
    let process: ProcessDetails?

    var body: some View {
        ForEach(ports) { port in
            let current = manager.override(host: host, port: port.port)
            let suffix = ports.count > 1 ? " (:\(port.port))" : ""
            if current != .pinned {
                Button("항상 표시" + suffix) { manager.setOverride(host: host, port: port.port, .pinned) }
            }
            if current != .hidden {
                Button("숨기기" + suffix) { manager.setOverride(host: host, port: port.port, .hidden) }
            }
            if current != nil {
                Button("자동 분류로 되돌리기" + suffix) { manager.setOverride(host: host, port: port.port, nil) }
            }
        }
        if let process {
            Divider()
            Button("프로세스 종료…") { manager.confirmTerminate(host: host, process: process) }
        }
    }
}

// MARK: - 포트 행

private struct PortRow: View {
    @EnvironmentObject private var manager: ForwardManager
    let host: String
    let port: RemotePort
    @State private var hovering = false

    var body: some View {
        let forwarded = manager.forwards.first {
            $0.host == host && $0.remotePort == port.port && $0.remoteTarget == port.target
        }
        let connected = forwarded.map { manager.status[$0.id] == .connected } ?? false
        let pinned = manager.override(host: host, port: port.port) == .pinned
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(port.port))
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .fixedSize()
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(port.displayName ?? "프로세스 정보 없음")
                        .font(.callout)
                        .foregroundStyle(port.displayName == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    if port.details?.launchedByClaude == true {
                        ClaudeBadge()
                    }
                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("항상 표시")
                    }
                    if port.target != "localhost" {
                        Text(port.bindAddress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if let d = port.details {
                    Text(d.shortCommand)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let dir = d.directory, dir != "/" {
                        Text(dir)
                            .font(.caption)
                            .foregroundStyle(d.directoryDeleted ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
            Spacer(minLength: 4)
            if let elapsed = port.details?.elapsedText {
                Text(elapsed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help("실행 시간")
            }
            if connected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("포워딩 중")
            }
            Image(systemName: "arrow.up.right.square")
                .foregroundStyle(hovering ? Color.accentColor : .secondary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            manager.connect(
                host: host, remotePort: port.port, remoteTarget: port.target,
                label: port.http?.title ?? port.details?.shortCommand ?? port.process, open: true
            )
        }
        .contextMenu { PortMenu(host: host, ports: [port], process: port.details) }
        .help(tooltip)
    }

    private var tooltip: String {
        guard port.process != nil else {
            return "다른 사용자의 프로세스는 root 권한 없이 조회할 수 없다. 클릭하면 포워딩하고 브라우저에서 연다."
        }
        var lines: [String] = []
        if let pid = port.pid { lines.append("PID \(pid)") }
        if let d = port.details {
            lines.append(d.command)
            if let dir = d.directory { lines.append("디렉터리: \(dir)") }
            if let e = d.elapsedText { lines.append("실행 시간: \(e)") }
        }
        if let http = port.http { lines.append("HTTP \(http.status)" + (http.isHTML ? ", HTML" : "")) }
        lines.append("클릭하면 포워딩하고 브라우저에서 연다. 우클릭하면 분류 지정과 프로세스 종료 메뉴가 나온다.")
        return lines.joined(separator: "\n")
    }
}

// MARK: - 프로세스 트리 행

private struct ProcessTreeRow: View {
    @EnvironmentObject private var manager: ForwardManager
    let host: String
    let row: TreeRow
    @State private var hovering = false

    private var process: ProcessDetails { row.process }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if row.depth > 0 {
                Text("└")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, CGFloat(min(row.depth, 8) - 1) * 12)
            }
            Text(row.ports.isEmpty ? row.summary : process.displayName)
                .font(.callout.weight(row.ports.isEmpty ? .regular : .medium))
                .foregroundStyle(row.ports.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.head)
                .layoutPriority(2)
            Text(String(process.pid))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize()
            if !row.ports.isEmpty && process.launchedByClaude {
                ClaudeBadge()
            }
            ForEach(row.ports) { port in
                portChip(port)
            }
            if let title = row.ports.compactMap({ $0.http?.title }).first {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if process.directoryDeleted {
                Image(systemName: "folder.badge.minus")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("작업 디렉터리가 삭제되었다.")
            }
            Spacer(minLength: 4)
            if let elapsed = process.elapsedText {
                Text(elapsed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            // 조상 프로세스(셸, sshd 등)는 종료 대상에서 뺀다.
            if !row.ports.isEmpty { PortMenu(host: host, ports: row.ports, process: process) }
        }
        .help(tooltip)
    }

    private func portChip(_ port: RemotePort) -> some View {
        let connected = manager.forwards.contains {
            $0.host == host && $0.remotePort == port.port && $0.remoteTarget == port.target
                && manager.status[$0.id] == .connected
        }
        return Button {
            manager.connect(
                host: host, remotePort: port.port, remoteTarget: port.target,
                label: port.http?.title ?? process.shortCommand, open: true
            )
        } label: {
            Text(":\(String(port.port))")
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(connected ? Color.green.opacity(0.25) : Color.accentColor.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("포트 \(port.port) 열기")
        .help(connected ? "포워딩 중. 클릭하면 브라우저에서 연다." : "포워딩하고 브라우저에서 열기")
    }

    private var tooltip: String {
        if row.ports.isEmpty {
            return "실행 경로 전체:\n" + row.chain.map { "\($0.displayName) (PID \($0.pid))" }.joined(separator: "\n")
        }
        var lines = ["PID \(process.pid), 부모 PID \(process.ppid)"]
        if !process.command.isEmpty { lines.append(process.command) }
        if let dir = process.directory { lines.append("디렉터리: \(dir)") }
        if let e = process.elapsedText { lines.append("실행 시간: \(e)") }
        if !row.ports.isEmpty { lines.append("우클릭하면 분류 지정과 프로세스 종료 메뉴가 나온다.") }
        return lines.joined(separator: "\n")
    }
}
