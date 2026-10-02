// AppMain.swift — 程式進入點：帶子指令 → CLI（原本的行為）；不帶參數 → 選單列 app（MenuBarExtra，.window 樣式）
//
// 判斷規則：argv[1] 存在且不是以 "-" 開頭 → CLI（run／calibrate／status／devices…）。
// 沒有參數、或只有 LaunchServices 塞的 -psn_…／-NS… 參數 → 選單列 app。
// Info.plist 有 LSUIElement = YES：不出現在 Dock、沒有主選單列。
import AppKit
import SwiftUI

/// 建置標記：build.sh 產生 build/gen/BuildStamp.swift（git describe --always --dirty＋建置時間＋debug/release）
/// 並加 -D IU42_BUILDSTAMP 一起編；直接 swiftc 編 Sources/ 的（例如開發中的編譯檢查）沒有這個檔 → "dev-unstamped"
#if IU42_BUILDSTAMP
let buildStamp = iu42GeneratedBuildStamp
#else
let buildStamp = "dev-unstamped"
#endif

@main
enum In_Unison42Main {
    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())
        if let first = argv.first, !first.hasPrefix("-") {
            exit(runCLI(argv))
        }
        AppLog.redirectIfNeeded()
        In_Unison42App.main()
    }
}

struct In_Unison42App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(state)
        } label: {
            // 第 B 輪：有裝置在等校正（需要校正／needsConsent／背景監聽標記／暫停出聲的藍牙）→ 右上角加提示點
            Image(nsImage: MenuBarIcon.image(symbol: state.menuBarSymbol, badge: state.menuBarNeedsAttention))
                .accessibilityLabel(state.menuBarNeedsAttention ? "In_Unison42：有裝置需要校正" : "In_Unison42")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SIGTERM／SIGINT（launchd、kill、Ctrl+C）→ 走正常的 terminate，讓 engine 乾淨清掉 tap／聚合裝置
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { NSApp.terminate(nil) }
            s.resume()
            signalSources.append(s)
        }
        MainActor.assumeIsolated { AppState.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.stop() }
    }
}

/// 選單列 app 的 log：stdout 不是終端機時（open／登入項目啟動），stdout/stderr 附加到 ~/Library/Logs/In_Unison42.log
enum AppLog {
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/In_Unison42.log")
    }

    static func redirectIfNeeded() {
        guard isatty(STDOUT_FILENO) == 0 else { setvbuf(stdout, nil, _IOLBF, 0); return }
        let path = fileURL.path
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        freopen(path, "a", stdout)
        freopen(path, "a", stderr)
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
    }
}
