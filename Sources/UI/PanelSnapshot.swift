// PanelSnapshot.swift — 面板離屏截圖（owner：UI）
//
//   In_Unison42 panel-snapshot <out.png> [--dark]   真的 AppState 資料（不啟動引擎；engine 沒在跑時照裝置與 plan() 現算）
//   In_Unison42 panel-snapshot --fake <dir>          假資料，兩個情境 × 淺色／深色：
//       panel-light.png / panel-dark.png             自動→影片、預設輸出警告、校正待機（ImageRenderer）
//       panel-game-light.png / panel-game-dark.png   手動鎖定遊戲、電視被排除、校正進行中、登入項目待核准（ImageRenderer）
//       panel-appkit-light.png / panel-appkit-dark.png  同第一個情境，但用 NSHostingView.cacheDisplay 畫「真的」AppKit 控制項
//   In_Unison42 panel-snapshot --selftest            版面文字與 calibrate 輸出解析的單元測試（不出聲、不開麥克風）
//
// 全部離屏：不顯示任何視窗、不碰使用者的螢幕與視窗、不開麥克風、不出聲。
// ImageRenderer 畫不出 AppKit 背書的控制項，所以 ImageRenderer 版用替身（PanelControls.swift，environment panelOffscreen）；
// cacheDisplay 版用一個從未 order in 的 borderless 視窗承載 NSHostingView，控制項是真的，但視窗不是 key → 強調色顯示成非作用中的灰色。
import AppKit
import SwiftUI

@MainActor
enum PanelSnapshot {
    // MARK: 渲染

    /// ImageRenderer（Apple 建議的離屏方式）；AppKit 控制項用替身
    static func renderSwiftUI<V: View>(_ content: V, dark: Bool, scale: CGFloat = 2) -> CGImage? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var out: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            // ImageRenderer 不會依 colorScheme 重新解析 NSColor → 背景色先在指定外觀下解析成固定值
            let bg = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .windowBackgroundColor
            let v = content
                .environment(\.panelOffscreen, true)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.locale, PanelText.locale)
                .background(Color(nsColor: bg))
            let r = ImageRenderer(content: v)
            r.scale = scale
            out = r.cgImage
        }
        return out
    }

    /// NSHostingView＋cacheDisplay（真的 AppKit 控制項；視窗從未顯示）
    static func renderAppKit<V: View>(_ content: V, dark: Bool, scale: CGFloat = 2) -> CGImage? {
        _ = NSApplication.shared
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let root = content
            .environment(\.locale, PanelText.locale)
            .background(Color(nsColor: .windowBackgroundColor))
        let hv = NSHostingView(rootView: root)
        hv.appearance = appearance
        let size = hv.fittingSize
        guard size.width > 0, size.height > 0 else { return nil }
        hv.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: hv.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        w.appearance = appearance
        w.isReleasedWhenClosed = false
        w.contentView = hv
        hv.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        hv.cacheDisplay(in: hv.bounds, to: rep)
        w.contentView = nil
        return rep.cgImage
    }

    static func writePNG(_ img: CGImage, to url: URL) -> Bool {
        let rep = NSBitmapImageRep(cgImage: img)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: url); return true } catch { return false }
    }

    // MARK: 真的資料

    static func renderLive(to url: URL, dark: Bool) -> Bool {
        let state = AppState.shared
        state.refreshNow()
        let view = PanelView().environmentObject(state)
        guard let img = renderSwiftUI(view, dark: dark) else { return false }
        return writePNG(img, to: url)
    }

    /// 執行中的 app：用目前的 @Published 狀態（不呼叫 refreshNow，不碰 engine）渲染 PanelView
    static func renderCurrent(to url: URL, dark: Bool, appKit: Bool) -> Bool {
        let view = PanelView().environmentObject(AppState.shared)
        let img = appKit ? renderAppKit(view, dark: dark) : renderSwiftUI(view, dark: dark)
        return img.map { writePNG($0, to: url) } ?? false
    }

    // MARK: 假資料（2026-09-28 實測延遲：內建 0、MSI +1.26、電視 +34.46）

    static let builtinUID = "BuiltInSpeakerDevice"
    static let msiUID = "3669B030-0000-0000-1B21-010380341E78"
    static let tvUID = "40C88240-0000-0000-151D-010380593278"
    static let glassUID = "00-00-00-00-00-00:output"

    static func fakeModel(scenario: String) -> PanelModel {
        if scenario == "autocal" {
            // 自動校正：app 重開後的藍牙倒數中（校正完成前不出聲）＋一台取消過的新裝置（需要校正）
            var m = fakeModel(scenario: "movie")
            m.warnings = []
            m.autoCal = AutoCalibrationStatus(countdownNames: ["GLASS5+"], secondsLeft: 2, waitingMessage: nil, runningNames: [],
                                              pending: [.init(uid: "usb", name: "USB 喇叭", message: "已取消自動校正")],
                                              heldNames: ["GLASS5+"])
            m.attention = ["〈USB 喇叭〉已取消自動校正"]
            return m
        }
        if scenario == "monitor" {
            // 第 B 輪：背景監聽剛修正過藍牙、電視被標記需要重新校正（面板頂部＋立即校正）；音樂模式四台出聲
            var m = fakeModel(scenario: "movie")
            m.warnings = []
            m.playMode = .music
            m.configMode = .auto
            m.modeReason = "前景 Music（未列入對照表）"
            m.autoCal = AutoCalibrationStatus(pending: [.init(uid: tvUID, name: "40PFH4082/96",
                                                             message: "背景監聽連續 2 次量到偏 +12.4 ms（超過 10 ms，不自動修）")])
            m.attention = ["〈40PFH4082/96〉背景監聽連續 2 次量到偏 +12.4 ms（超過 10 ms，不自動修）"]
            let at = ISO8601DateFormatter().date(from: "2026-09-29T07:05:00Z")!
            m.monitor = MonitorStatus(enabled: true, listening: false, nextDue: at.addingTimeInterval(300), waitingReason: nil,
                                      last: MonitorRoundSummary(at: at, round: 7, confirm: true, skipped: nil, message: "",
                                                                devices: [MonitorDeviceResult(uid: glassUID, name: "GLASS5+", errorMs: 1.42, confidence: 0.86,
                                                                                              correctedMs: 1.42, note: "連續 2 次一致，已修正（累計 +2.90 ms）")]),
                                      totals: [glassUID: 2.9])
            return m
        }
        if scenario == "drift" {
            // 第 C 輪：藍牙漂移補償（速度、目前修正、等空檔）＋藍牙連上後預設輸出自動切回的紀錄；音樂模式
            var m = fakeModel(scenario: "monitor")
            m.autoCal = AutoCalibrationStatus()
            m.attention = []
            let at = ISO8601DateFormatter().date(from: "2026-09-29T11:51:26Z")!
            m.drift = [DriftStatusRow(uid: glassUID, name: "GLASS5+", points: 3, rateMsPerMin: -0.716, correctionMs: -7.14, sigmaMs: 0.31,
                                      health: "正常", healthy: true, nextDue: at.addingTimeInterval(290), nextReason: "預估誤差 2σ 將超過 2 ms", waiting: nil,
                                      lastMiss: "晚上7:46 驗證預測失準 -3.7 ms（> 3 ms）", misses: 1)]
            m.outputRestoreNote = OutputRestoreNote(at: at.addingTimeInterval(-900),
                                                    message: "藍牙「GLASS5+」連上後 2.1 秒 macOS 把預設輸出切到它 → 已自動切回「Mac mini揚聲器」（只改預設輸出，不動音量）",
                                                    restored: true)
            return m
        }
        let game = scenario == "game"
        let mode: PlayMode = game ? .game : .movie
        let caps = ModeCaps()
        struct Dev { let uid, name: String; let kind: DeviceKind; let agg, src: Bool; let lat: Double?; let on: Bool; let trim: Double }
        let devs = [
            Dev(uid: builtinUID, name: "Mac mini揚聲器", kind: .builtIn, agg: true, src: true, lat: 0, on: true, trim: 0),
            Dev(uid: msiUID, name: "MSI MP242C", kind: .hdmi, agg: true, src: false, lat: 1.26, on: true, trim: -3),
            Dev(uid: tvUID, name: "40PFH4082/96", kind: .displayPort, agg: true, src: false, lat: 34.46, on: true, trim: 1.5),
            Dev(uid: glassUID, name: "GLASS5+", kind: .bluetooth, agg: false, src: false, lat: nil, on: game, trim: 0),
        ]
        let p = plan(devices: devs.map { PlanDevice(uid: $0.uid, name: $0.name, latencyMs: $0.lat, enabled: $0.on, isBuiltIn: $0.kind == .builtIn, requiresMeasurement: $0.kind.isBluetooth) },
                     mode: mode, caps: caps)
        let rows = devs.map { d in
            DeviceRow(uid: d.uid, name: d.name, kind: d.kind, inAggregate: d.agg, isVolumeSource: d.src, enabled: d.on,
                      trimDb: d.trim, measuredLatencyMs: d.lat, plan: p[d.uid], peak: 0)
        }
        let mics = [
            CalibrationMic(uid: "C270-UID", name: "C270 HD WEBCAM", kind: .usb, sampleRate: 48000, channels: 1,
                           isContinuity: false, isAutomaticChoice: true),
            CalibrationMic(uid: "IPHONE-UID", name: "Kang的iPhone麥克風", kind: .continuity, sampleRate: 48000, channels: 1,
                           isContinuity: true, isAutomaticChoice: false),
            CalibrationMic(uid: "00-00-00-00-00-00:input", name: "GLASS5+", kind: .bluetooth, sampleRate: 8000, channels: 1,
                           isContinuity: false, isAutomaticChoice: false),
        ]
        let warnings = game ? [] : [
            AppWarning(kind: .defaultOutput,
                       message: "預設輸出是「40PFH4082/96」，它沒有音量控制，音量鍵調不到任何喇叭。",
                       actionTitle: "切回「Mac mini揚聲器」"),
        ]
        return PanelModel(engine: .running, configMode: game ? .game : .auto, manualLock: game, playMode: mode,
                          modeReason: game ? nil : "前景 IINA（對照表：影片）", caps: caps, devices: rows, warnings: warnings,
                          mics: mics, micUID: game ? "IPHONE-UID" : nil, calibratedAt: "2026-09-28T09:18:54Z",
                          calibration: game ? .running(step: "播放測試音並錄音，請保持安靜⋯", fraction: 0.45) : .idle,
                          loginEnabled: game, loginNeedsApproval: game, loginError: nil)
    }

    /// 假資料的 PNG：回傳寫出的檔案
    static func renderFake(into dir: URL) -> [(URL, Bool)] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [(URL, Bool)] = []
        for (scenario, prefix) in [("movie", "panel"), ("game", "panel-game"), ("autocal", "panel-autocal"), ("monitor", "panel-monitor"), ("drift", "panel-drift")] {
            let content = PanelContent(model: fakeModel(scenario: scenario), actions: PanelActions())
            for dark in [false, true] {
                let url = dir.appendingPathComponent("\(prefix)-\(dark ? "dark" : "light").png")
                out.append((url, renderSwiftUI(content, dark: dark).map { writePNG($0, to: url) } ?? false))
            }
        }
        let content = PanelContent(model: fakeModel(scenario: "movie"), actions: PanelActions())
        for dark in [false, true] {
            let url = dir.appendingPathComponent("panel-appkit-\(dark ? "dark" : "light").png")
            out.append((url, renderAppKit(content, dark: dark).map { writePNG($0, to: url) } ?? false))
        }
        // 選單列圖示：一般／需要校正（提示點），淺色與深色選單列
        for badge in [false, true] {
            for dark in [false, true] {
                let url = dir.appendingPathComponent("menubar-\(badge ? "badge" : "plain")-\(dark ? "dark" : "light").png")
                out.append((url, MenuBarIcon.renderPNG(symbol: "hifispeaker.2", badge: badge, dark: dark, to: url)))
            }
        }
        return out
    }

    // MARK: 自測

    static func selfTest() -> Int32 {
        var fail = 0
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "（\(detail)）")")
            if !ok { fail += 1 }
        }
        print("── 模式理由改寫 ──")
        check(PanelText.autoReason("前景 IINA（對照表：影片）", mode: .movie) == "IINA在前景 → 影片", "IINA → 影片",
              PanelText.autoReason("前景 IINA（對照表：影片）", mode: .movie))
        check(PanelText.autoReason("前景 Hades（類別 public.app-category.action-games）", mode: .game) == "Hades在前景（遊戲類App） → 遊戲", "遊戲類別")
        check(PanelText.autoReason("前景 Safari（未列入對照表）", mode: .music) == "Safari在前景（不在對照表） → 音樂", "未列入")
        check(PanelText.autoReason(nil, mode: .music) == "自動：音樂", "沒有理由")
        check(PanelText.autoReason("沒有前景 app", mode: .music) == "沒有前景 app → 音樂", "未知格式原樣")
        print("── 數值格式 ──")
        check(PanelText.db(-3) == "\u{2212}3.0 dB", "−3.0 dB（U+2212）", PanelText.db(-3))
        check(PanelText.db(1.5) == "+1.5 dB", "+1.5 dB")
        check(PanelText.db(-0.01) == "+0.0 dB", "近 0 不顯示負號", PanelText.db(-0.01))
        check(PanelText.lastCalibrated(nil) == "尚未校正", "尚未校正")
        check(PanelText.lastCalibrated("2026-09-28T09:18:54Z").hasPrefix("上次校正："), "上次校正時間",
              PanelText.lastCalibrated("2026-09-28T09:18:54Z"))
        check(PanelText.capText(.infinity).hasPrefix("不限延遲"), "不限延遲")
        print("── 假資料的出聲計畫（plan()）──")
        let movie = fakeModel(scenario: "movie"), game = fakeModel(scenario: "game")
        func row(_ m: PanelModel, _ uid: String) -> DeviceRow? { m.devices.first { $0.uid == uid } }
        check(row(movie, tvUID)?.plan?.active == true, "影片：電視出聲")
        check(row(game, tvUID)?.plan?.active == false, "遊戲：電視不出聲", row(game, tvUID)?.plan?.reason ?? "")
        check(abs((row(game, builtinUID)?.plan?.delayMs ?? 0) - 1.26) < 1e-6, "遊戲：內建補償 1.26 ms")
        check(row(game, glassUID)?.plan?.active == false, "遊戲：未量測的藍牙不出聲", row(game, glassUID)?.plan?.reason ?? "")
        print("── SF Symbols 存在 ──")
        let symbols = PlayMode.allCases.map(PanelText.symbol)
            + [DeviceKind.builtIn, .hdmi, .bluetooth, .airPlay, .usb, .continuity].map(PanelText.deviceSymbol)
            + ["speaker.slash", "lock.fill", "exclamationmark.triangle.fill", "checkmark.circle.fill", "xmark.octagon.fill", "info.circle", "xmark",
               "timer", "waveform", "exclamationmark.circle", "exclamationmark.circle.fill", "pause.circle", "clock", "checkmark.circle", "circle"]
        for s in Set(symbols).sorted() {
            check(NSImage(systemSymbolName: s, accessibilityDescription: nil) != nil, s)
        }
        print("── 選單列提示點（第 B 輪）──")
        for sym in PlayMode.allCases.map(PanelText.symbol) + ["speaker.slash", "exclamationmark.triangle"] {
            check(MenuBarIcon.badgePixelsOK(symbol: sym), "\(sym)＋提示點：右上角點不透明、點旁挖縫透明")
            let plain = MenuBarIcon.make(symbol: sym, badge: false), badged = MenuBarIcon.make(symbol: sym, badge: true)
            check(plain.isTemplate && badged.isTemplate && badged.size.width > plain.size.width, "\(sym)：兩種都是 template（選單列自動套色）")
        }
        print("── 背景監聽文字（第 B 輪）──")
        let mon = fakeModel(scenario: "monitor").monitor
        let lines = PanelText.monitorLines(mon).map(\.text)
        check(lines.count == 2 && lines[0].hasPrefix("上次 ") && lines[0].hasSuffix("（確認）") && lines[1].contains("GLASS5+ +1.42 ms") && lines[1].contains("已修正"),
              "最近一次：時間＋每台誤差＋是否修正", lines.joined(separator: "／"))
        var waiting = MonitorStatus(); waiting.waitingReason = .micBusy
        check(PanelText.monitorLines(waiting).first?.text.contains("麥克風正被其他 App 使用") == true, "等待原因")
        var listening = MonitorStatus(); listening.listening = true
        check(PanelText.monitorLines(listening).map(\.text) == ["聆聽中⋯"], "聆聽中")
        check(PanelText.minutes(MonitorStatus()) == "5 分鐘", "間隔 300 秒 → 5 分鐘")
        print("── calibrate 輸出解析 ──")
        typealias S = CalibrationOutputParser.Step
        check(CalibrationOutputParser.parse("麥克風：C270 HD WEBCAM（48000 Hz，1ch，只錄第 1 聲道；不改系統預設輸入）") == S.mic, "麥克風")
        check(CalibrationOutputParser.parse("輸出 3 台、每輪 3 個 chirp × 4 輪、間隔 400 ms，約 6.4 秒。請保持安靜…") == S.measuring(seconds: 6.4), "量測秒數")
        check(CalibrationOutputParser.parse("錄到 7.10 秒，麥克風峰值 -12.0 dBFS，漏格 0 次") == S.analyzing, "分析")
        check(CalibrationOutputParser.parse("✓ 已寫入 /x/config.json 並套用") == S.success("校正完成，已套用新的延遲"), "成功")
        check(CalibrationOutputParser.parse("✗ 量測不合格，設定未修改") == S.failure("量測不合格，設定未修改"), "失敗")
        check(CalibrationOutputParser.parse("  [engine] xxx") == S.other, "其他")
        print(fail == 0 ? "✓ panel 自測全部通過" : "✗ panel 自測有 \(fail) 項失敗")
        return fail == 0 ? 0 : 1
    }
}

func cmdPanelSnapshot(_ args: [String]) -> Int32 {
    if args.first == "--selftest" {
        return MainActor.assumeIsolated { PanelSnapshot.selfTest() }
    }
    if args.first == "--fake" {
        guard args.count >= 2 else { print("用法：In_Unison42 panel-snapshot --fake <dir>"); return 2 }
        let dir = URL(fileURLWithPath: args[1])
        let results = MainActor.assumeIsolated { PanelSnapshot.renderFake(into: dir) }
        for (u, ok) in results { print(ok ? "✓ \(u.path)" : "✗ 渲染失敗：\(u.path)") }
        return results.allSatisfy(\.1) ? 0 : 1
    }
    guard let path = args.first, !path.hasPrefix("-") else {
        print("用法：In_Unison42 panel-snapshot <out.png> [--dark] | --fake <dir> | --selftest")
        return 2
    }
    let url = URL(fileURLWithPath: path)
    let dark = args.contains("--dark")
    let ok = MainActor.assumeIsolated { PanelSnapshot.renderLive(to: url, dark: dark) }
    print(ok ? "✓ \(url.path)" : "✗ 渲染失敗")
    return ok ? 0 : 1
}
