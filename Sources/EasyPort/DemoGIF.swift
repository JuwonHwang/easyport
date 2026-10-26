import AppKit
import SwiftUI

/// `EasyPort --gif <디렉터리>`: 가상 데이터로 사용 흐름을 장면별로 렌더링해 README용 GIF를 만든다.
/// 한국어 설명(demo-ko.gif)과 영어 설명(demo-en.gif) 두 개를 만든다. GIF 변환에 ffmpeg가 필요하다.
@MainActor
enum DemoGIF {
    private struct Scene {
        let ko: String
        let en: String
        let seconds: Double
        var expanded: Set<String> = ["gpu-box"]
        var tree = false
        var browser = false
        var setup: (ForwardManager) -> Void = { _ in }
    }

    private static let monitor = Forward(
        host: "gpu-box", remotePort: 8790, localPort: 8790, label: "Experiment Monitor", enabled: true
    )

    private static var scenes: [Scene] {
        [
            Scene(
                ko: "메뉴바에서 SSH 서버 목록을 열어요", en: "Open your SSH servers from the menu bar",
                seconds: 1.8, expanded: [],
                setup: { m in m.clearPreviewForwards(); m.setPreviewScan("gpu-box", .loading) }
            ),
            Scene(
                ko: "서버를 펼치면 열린 포트를 조회해요", en: "Expand a server to scan its open ports",
                seconds: 1.0
            ),
            Scene(
                ko: "웹 페이지는 제목으로, Claude가 띄운 건 배지로 보여요",
                en: "Web pages show titles, Claude's servers get a badge",
                seconds: 2.8, setup: { m in m.setPreviewScan("gpu-box", .loaded(DemoData.gpuBox)) }
            ),
            Scene(
                ko: "포트를 누르면 SSH로 포워딩하고", en: "Click a port to forward it over SSH",
                seconds: 1.2, setup: { m in m.addPreviewForward(monitor); m.setPreviewStatus(monitor.id, .connecting) }
            ),
            Scene(
                ko: "포트를 누르면 SSH로 포워딩하고", en: "Click a port to forward it over SSH",
                seconds: 1.0, setup: { m in m.setPreviewStatus(monitor.id, .connected) }
            ),
            Scene(
                ko: "브라우저에서 바로 열어요", en: "and it opens in your browser",
                seconds: 2.2, browser: true
            ),
            Scene(
                ko: "트리 보기로 어떤 경로로 띄웠는지 확인해요", en: "The tree view shows how each port was launched",
                seconds: 3.0, tree: true
            ),
        ]
    }

    static func run(outputDir: String) {
        let manager = ForwardManager.shared
        manager.setPreviewHosts(["gpu-box", "dev-server", "staging"], scans: [:])
        let appearance = NSAppearance.Name.aqua

        // 장면마다 높이가 달라 GIF 크기가 흔들리지 않도록, 먼저 전체 장면의 최대 높이를 잰다.
        var maxHeight: CGFloat = 0
        for scene in scenes {
            scene.setup(manager)
            UserDefaults.standard.set(scene.tree, forKey: "treeView")
            maxHeight = max(maxHeight, measure(content(scene, manager), appearance: appearance).height)
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("easyport-gif-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for lang in ["ko", "en"] {
            var list = ""
            var last = ""
            for (i, scene) in scenes.enumerated() {
                scene.setup(manager)
                UserDefaults.standard.set(scene.tree, forKey: "treeView")
                let frame = tmp.appendingPathComponent("\(lang)-\(i).png").path
                let view = VStack(spacing: 16) {
                    content(scene, manager)
                        .frame(height: maxHeight, alignment: .top)
                    Text(lang == "ko" ? scene.ko : scene.en)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(white: 0.2))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: 440, height: 24)
                }
                .padding(28)
                .background(Color(white: 0.94))
                Snapshot.renderView(view, appearance: appearance, to: frame)
                list += "file '\(frame)'\nduration \(scene.seconds)\n"
                last = frame
            }
            // concat demuxer는 마지막 파일의 duration을 무시하므로 마지막 장면을 한 번 더 넣는다.
            list += "file '\(last)'\n"
            let listPath = tmp.appendingPathComponent("\(lang).txt").path
            try? list.write(toFile: listPath, atomically: true, encoding: .utf8)
            let out = "\(outputDir)/demo-\(lang).gif"
            ffmpeg([
                "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", listPath,
                "-vf", "fps=10,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=none",
                "-loop", "0", out,
            ])
            print("저장: \(out)")
        }
        try? FileManager.default.removeItem(at: tmp)
        NSApp.terminate(nil)
    }

    @ViewBuilder
    private static func content(_ scene: Scene, _ manager: ForwardManager) -> some View {
        if scene.browser {
            BrowserMock()
        } else {
            PanelView(initialExpanded: scene.expanded)
                .environmentObject(manager)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.12)))
        }
    }

    private static func measure(_ view: some View, appearance: NSAppearance.Name) -> CGSize {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        return hosting.fittingSize
    }

    private static func ffmpeg(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["ffmpeg"] + args
        p.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        try? p.run()
        p.waitUntilExit()
    }
}

/// 포트를 연 뒤 브라우저에 페이지가 열린 장면. 실제 브라우저가 아니라 그림이다.
private struct BrowserMock: View {
    private let points: [CGFloat] = [0.92, 0.78, 0.7, 0.58, 0.55, 0.47, 0.41, 0.4, 0.34, 0.31, 0.3, 0.27, 0.26, 0.24]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color.red, .yellow, .green], id: \.self) { c in
                    Circle().fill(c.opacity(0.8)).frame(width: 11, height: 11)
                }
                Spacer().frame(width: 12)
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    Text("localhost:8790").font(.callout)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
                Spacer().frame(width: 40)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(white: 0.97))
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text("Experiment Monitor").font(.title2.weight(.semibold))
                Text("run-042 · step 18,400 / 30,000").font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    metric("train loss", "0.241")
                    metric("eval acc", "87.3%")
                    metric("GPU", "8 × H200")
                }
                GeometryReader { geo in
                    Path { path in
                        for (i, v) in points.enumerated() {
                            let x = geo.size.width * CGFloat(i) / CGFloat(points.count - 1)
                            let y = geo.size.height * v
                            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                }
                .frame(height: 150)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
        }
        .frame(width: 440)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.15)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.top, 40)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}
