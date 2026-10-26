import AppKit
import SwiftUI

@main
struct EasyPortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var manager = ForwardManager.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(manager)
        } label: {
            let count = manager.connectedCount
            Image(systemName: count > 0 ? "network" : "network.slash")
            if count > 0 { Text("\(count)") }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SIGTERM(pkill, 로그아웃)과 SIGINT에서는 applicationWillTerminate가 호출되지 않으므로 직접 ssh를 정리한다.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                ForwardManager.shared.shutdown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.run(outputDir: args[i + 1], demo: args.contains("--demo"))
            return
        }
        ForwardManager.shared.bootstrap()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ForwardManager.shared.shutdown()
    }
}
