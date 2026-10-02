// AppControl.swift — 控制執行中的選單列 app（驗收／除錯用；不碰使用者畫面）
//
//   In_Unison42 ctl <指令…>
//     state                         目前狀態（模式、理由、每台出聲計畫、警告、藍牙、排除清單、登入項目）
//     mode auto|music|movie|game    等同面板選模式（music/movie/game = 手動鎖定；auto = 解鎖）
//   發行版（沒有 -D IU42_DIAG）只接受白名單（ReleasePolicy.checkCtl）；標「診斷」的只在除錯版。
//     config status|reset           設定檔損壞唯讀保護狀態／重設為預設值（等同面板「重設設定」）
//     snapshot <dir>（診斷）        以「真的 AppState」離屏渲染面板：panel-live-{light,dark}.png（ImageRenderer）
//                                   ＋ panel-live-appkit-{light,dark}.png（NSHostingView.cacheDisplay；視窗從不顯示）
//     guard-restore                 等同面板「切回音量來源」按鈕
//     calibrate [calibrate 參數…]   等同面板「開始校正」（暫停引擎 → 子行程 calibrate → 恢復）；結束才回覆
//                                   發行版只准 --pulse／--verify-program／--mode／--only <uid>／--mic <可用麥克風 uid>
//     peaks <秒>                    最近 N 秒每秒的輸入／各輸出峰值（系統提示音驗證用）
//     bt status|resync|detach-all|attach <deviceID>|detach <uid>|simulate-reconnect <uid>
//                                   status 含每台藍牙的即時統計（填充量、重取樣修正 ppm、欠載、重對時）；
//                                   simulate-reconnect：停掉再 attach，走和真的斷線重連一樣的路徑
//                                   （第 B 輪起：量過延遲的藍牙先不出聲、倒數 3 秒、--only 重校；通知沒授權 → 面板打開才倒數）
//     autocal status|cancel|now     自動校正：狀態／等同面板「取消」／等同面板「需要校正」（立即校正延後的裝置）
//     monitor status|on|off         背景監聽（播音樂時自動修正落拍）：狀態／等同面板開關
//     monitor now（診斷）           下一秒就跑一輪（條件照樣檢查：音樂模式、節目音夠大、麥克風沒被占用…）
//                                   發行版要在 ReleasePolicy.checkCtl 加 "monitor"（CLI.swift，不是本檔 owner）才放行
//     login-item status|on|off
//     trim <uid> <dB>               等同面板每台音量微調（夾在 Config.trimDbRange；不動系統音量）
//     reload-config                 重新讀 config.json（外部改過設定檔之後；等同校正結束時的 reloadConfig）
//
// 通道：DistributedNotificationCenter（同一個登入工作階段），通知名 com.kang.In-Unison42.ctl，
// userInfo = { id, args }；app 把回覆寫到 ~/Library/Application Support/In_Unison42/ctl-reply.json（{ id, ok, lines }）。
// 所有指令都是面板本來就能做的事（不開放任意檔案讀寫；snapshot 只寫 PNG 到家目錄底下）。
import AppKit
import CoreAudio
import Foundation
import ServiceManagement

enum AppControlChannel {
    static let name = Notification.Name("com.kang.In-Unison42.ctl")
    static var replyURL: URL { Config.directory.appendingPathComponent("ctl-reply.json") }

    struct Reply: Codable { let id: String; let ok: Bool; let lines: [String] }

    static func writeReply(_ r: Reply) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        try? enc.encode(r).write(to: replyURL, options: .atomic)
    }

    static func readReply() -> Reply? {
        guard let d = try? Data(contentsOf: replyURL) else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: d)
    }
}

@MainActor
final class AppControl {
    static let shared = AppControl()
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: AppControlChannel.name, object: nil, queue: .main) { n in
            let id = n.userInfo?["id"] as? String ?? ""
            let args = n.userInfo?["args"] as? [String] ?? []
            MainActor.assumeIsolated { AppControl.shared.handle(id: id, args: args) }
        }
        AppLog.line("ctl 通道就緒（\(AppControlChannel.name.rawValue)）")
    }

    func stop() {
        if let o = observer { DistributedNotificationCenter.default().removeObserver(o) }
        observer = nil
    }

    private func reply(_ id: String, _ ok: Bool, _ lines: [String]) {
        AppControlChannel.writeReply(.init(id: id, ok: ok, lines: lines))
    }

    private func handle(id: String, args: [String]) {
        let state = AppState.shared
        let cmd = args.first ?? "help"
        let rest = Array(args.dropFirst())
        AppLog.line("ctl：\(args.joined(separator: " "))")
        // 發行版：白名單（面板本來就能做的事＋唯讀查詢）；calibrate 另外檢查參數
        if !BuildFlavor.diagnostics {
            if let why = ReleasePolicy.checkCtl(args) { reply(id, false, ["✗ \(why)"]); return }
            if cmd == "calibrate",
               let why = ReleasePolicy.checkCalibrateArgs(rest, micUIDs: availableCalibrationMics().map(\.uid), allowCLIExtras: false) {
                reply(id, false, ["✗ \(why)"]); return
            }
        }
        switch cmd {
        case "state":
            reply(id, true, stateLines())
        case "mode":
            guard let m = rest.first.flatMap(AudioMode.init(rawValue:)) else { reply(id, false, ["用法：mode auto|music|movie|game"]); return }
            state.selectMode(m)
            // 等 engine 套用（control queue）與 refresh 回來再回覆
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { self.reply(id, true, self.stateLines()) } }
        #if IU42_DIAG
        case "snapshot":
            guard let dir = rest.first else { reply(id, false, ["用法：snapshot <dir>"]); return }
            let url = URL(fileURLWithPath: dir).standardizedFileURL
            guard url.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/") else {
                reply(id, false, ["只寫到家目錄底下"]); return
            }
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var lines: [String] = []
            var ok = true
            for dark in [false, true] {
                for appkit in [false, true] {
                    let name = "panel-live\(appkit ? "-appkit" : "")-\(dark ? "dark" : "light").png"
                    let f = url.appendingPathComponent(name)
                    let r = PanelSnapshot.renderCurrent(to: f, dark: dark, appKit: appkit)
                    ok = ok && r
                    lines.append("\(r ? "✓" : "✗") \(f.path)")
                }
            }
            // 選單列圖示（真實 AppState：目前的符號與提示點）
            for dark in [false, true] {
                let f = url.appendingPathComponent("menubar-live-\(dark ? "dark" : "light").png")
                let r = MenuBarIcon.renderPNG(symbol: state.menuBarSymbol, badge: state.menuBarNeedsAttention, dark: dark, to: f)
                ok = ok && r
                lines.append("\(r ? "✓" : "✗") \(f.path)（提示點：\(state.menuBarNeedsAttention ? "有" : "沒有")）")
            }
            reply(id, ok, lines + stateLines())
        #endif
        case "guard-restore":
            let before = DefaultOutputGuard.evaluate(engine: state.engine)?.message ?? "（沒有警告）"
            state.switchDefaultOutputToVolumeSource()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    self.reply(id, true, ["切換前警告：\(before)", "目前：\(SystemAudioSnapshot.capture())"] + self.stateLines())
                }
            }
        case "calibrate":
            let runner = CalibrationRunner.shared
            guard !runner.isRunning else { reply(id, false, ["已有校正在跑"]); return }
            runner.onFinishOnce = { ok, msg, lines in
                AppControl.shared.reply(id, ok, lines + ["== \(ok ? "成功" : "未成功")：\(msg)"])
            }
            state.runCalibration(extraArgs: rest)
        case "peaks":
            let secs = rest.first.flatMap(Double.init) ?? 5
            let since = Date().addingTimeInterval(-secs)
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
            let lines = state.peakLog.filter { $0.at >= since }.map { e in
                "\(f.string(from: e.at)) 輸入 \(String(format: "%.4f", e.input)) | "
                    + e.outputs.map { "\($0.name) \(String(format: "%.4f", $0.peak))" }.joined(separator: " | ")
            }
            reply(id, true, lines)
        case "bt":
            let bt = state.bluetooth
            let sub = rest.first ?? "status"
            var lines: [String] = []
            switch sub {
            case "resync": bt.resync(); lines.append("resync 已排入")
            #if IU42_DIAG
            case "detach-all": bt.detachAll(); lines.append("detachAll 完成")
            case "attach":
                let idv = rest.dropFirst().first.flatMap { UInt32($0) } ?? 0
                lines.append("attach(deviceID: \(idv)) → \(bt.attach(deviceID: AudioObjectID(idv)))")
            case "detach":
                if let u = rest.dropFirst().first { bt.detach(uid: u); lines.append("detach(uid: \(u)) 完成") }
            case "simulate-reconnect":
                if let u = rest.dropFirst().first { lines.append("simulateReconnect(uid: \(u)) → \(bt.simulateReconnect(uid: u))") }
            #endif
            default: break
            }
            lines.append("藍牙裝置（Devices.bluetoothOutputs）：\(Devices.bluetoothOutputs().map { "\($0.name) id=\($0.id)" })")
            lines.append("輸出：\(bt.outputs.keys.sorted())　錯誤：\(bt.errors)")
            for (uid, o) in bt.outputs.sorted(by: { $0.key < $1.key }) {
                let rate = CA.f64(o.device.id, kAudioDevicePropertyNominalSampleRate) ?? 0
                let pe = state.engine.planEntry(uid: uid)
                lines.append(String(format: "  %@ id=%u 槽 %@ 取樣率 %.0f Hz 固定緩衝 %.0f ms；%@；計畫：%@", o.device.name, o.device.id,
                                    o.slot.map(String.init) ?? "-", rate, o.safetyMs ?? 0, o.stats.description, pe?.description ?? "無"))
            }
            reply(id, true, lines)
        case "reload-config":
            state.reloadConfig()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { MainActor.assumeIsolated { self.reply(id, true, self.stateLines()) } }
        case "trim":
            guard rest.count == 2, let db = Double(rest[1]) else { reply(id, false, ["用法：trim <uid> <dB>"]); return }
            let before = state.config.device(rest[0]).trimDb
            state.setTrim(rest[0], db)
            reply(id, true, ["trim \(rest[0])：\(before) → \(state.config.device(rest[0]).trimDb) dB"])
        case "config":
            // config status：設定檔損壞的唯讀保護；config reset：等同面板「重設設定」（使用者明確操作 → 寫預設值、解除保護、重新載入）
            let sub = rest.first ?? "status"
            if sub == "reset" {
                do { try Config.resetToDefaults() } catch { reply(id, false, ["✗ 重設失敗：\(error)"]); return }
                AppLog.line("ctl：設定檔已重設為預設值（唯讀保護解除）")
                state.reloadConfig()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    MainActor.assumeIsolated { self.reply(id, true, ["✓ 已重設 \(Config.fileURL.path)"] + self.stateLines()) }
                }
            } else {
                reply(id, true, [Self.protectionLine()])
            }
        case "autocal":
            // 自動校正：status（倒數／執行中／需要校正／暫停出聲的藍牙）｜cancel（等同面板「取消」）｜now（等同面板「需要校正」）
            let sub = rest.first ?? "status"
            #if IU42_DIAG
            if sub == "simulate-appear", rest.count == 2 {
                // 除錯版：模擬 rest[1] 這台拔掉再接上（新裝置倒數的實機驗證用）
                guard state.simulateDeviceAppeared(rest[1]) else { reply(id, false, ["裝置清單裡沒有 \(rest[1])"]); return }
                reply(id, true, Self.autoCalLines(state)); return
            }
            if sub == "set-latency", rest.count == 3, let v = Double(rest[2]), v.isFinite, v >= 0, v <= Config.maxDelayMs {
                // 除錯版・實機驗收：節目音一直在播、脈衝校正量不到時，手動寫入延遲並當作這台已校正（解除暫停出聲）
                guard state.debugSetMeasuredLatency(rest[1], ms: v) else { reply(id, false, ["裝置清單裡沒有 \(rest[1])"]); return }
                reply(id, true, Self.autoCalLines(state)); return
            }
            #endif
            if sub == "cancel" { state.cancelAutoCalibration() }
            else if sub == "now" { state.calibratePendingNow() }
            else if sub != "status" { reply(id, false, ["用法：autocal status|cancel|now"]); return }
            reply(id, true, Self.autoCalLines(state))
        case "monitor":
            let sub = rest.first ?? "status"
            switch sub {
            case "on": state.setMonitorEnabled(true)
            case "off": state.setMonitorEnabled(false)
            #if IU42_DIAG
            case "now": state.monitorRunSoon()
            case "bias":
                // 實機驗收：monitor bias <uid|名稱> <ms>（正 = 讓它晚到）｜monitor bias clear
                if rest.count >= 2, rest[1] == "clear" { state.monitorClearCorrections(); break }
                guard rest.count >= 3, let v = Double(rest[2]), v.isFinite, abs(v) <= 20 else {
                    reply(id, false, ["用法：monitor bias <uid|名稱> <ms（±20）>｜monitor bias clear"]); return
                }
                guard let uid = state.monitorInjectError(rest[1], ms: v) else { reply(id, false, ["找不到裝置：\(rest[1])"]); return }
                reply(id, true, [String(format: "已讓 %@ 晚到 %+.2f ms（延遲修正 %+.2f ms，斜率 0.1 ms/秒）", uid, v, -v)] + Self.monitorLines(state)); return
            case "interval":
                guard rest.count >= 2, let v = Double(rest[1]) else { reply(id, false, ["用法：monitor interval <秒（60–3600）>"]); return }
                state.monitorSetInterval(v)
            #endif
            case "status": break
            default: reply(id, false, ["用法：monitor status|on|off" + (BuildFlavor.diagnostics ? "|now|bias <uid> <ms>|bias clear|interval <秒>" : "")]); return
            }
            reply(id, true, Self.monitorLines(state))
        case "drift":
            // 【第 C 輪】藍牙漂移補償：status｜on｜off（等同面板開關）｜verify-feed on|off（驗收用、執行期）
            let sub = rest.first ?? "status"
            switch sub {
            case "on": state.setDriftCompensationEnabled(true)
            case "off": state.setDriftCompensationEnabled(false)
            case "verify-feed" where rest.count >= 2 && ["on", "off"].contains(rest[1]): state.setDriftFeedsVerify(rest[1] == "on")
            case "status": break
            default: reply(id, false, ["用法：drift status|on|off|verify-feed on|off"]); return
            }
            reply(id, true, Self.driftLines(state))
        case "output-restore":
            // 【第 C 輪】藍牙連上後 macOS 搶預設輸出 → 自動切回：status｜on｜off（等同面板開關）
            let sub = rest.first ?? "status"
            switch sub {
            case "on": state.setOutputRestoreEnabled(true)
            case "off": state.setOutputRestoreEnabled(false)
            case "status": break
            default: reply(id, false, ["用法：output-restore status|on|off"]); return
            }
            reply(id, true, Self.outputRestoreLines(state))
        case "login-item":
            let sub = rest.first ?? "status"
            var lines: [String] = []
            var ok = true
            do {
                if sub == "on" { try LoginItem.setEnabled(true) }
                if sub == "off" { try LoginItem.setEnabled(false) }
            } catch {
                ok = false
                lines.append("✗ \(error)")
            }
            let s = LoginItem.status
            lines.append("SMAppService.mainApp.status = \(s.rawValue) \(LoginItem.describe(s))")
            lines.append("app：\(LoginItem.appBundleURL.path)")
            lines.append("舊 LaunchAgent：\(LoginItem.hasLegacyLaunchAgent ? "還在" : "沒有")")
            reply(id, ok, lines)
        default:
            reply(id, cmd == "help", ["指令（\(BuildFlavor.name)）：state | mode <m> | guard-restore | calibrate [參數…] | peaks <秒> | bt status|resync | trim <uid> <dB> | reload-config | config status|reset | autocal status|cancel|now | monitor status|on|off | drift status|on|off|verify-feed on|off | output-restore status|on|off | login-item status|on|off"
                                      + (BuildFlavor.diagnostics ? "；診斷：snapshot <dir> | bt detach-all|attach|detach|simulate-reconnect | autocal simulate-appear <uid> | monitor now|bias|interval" : "")])
        }
    }

    /// 自動校正狀態（ctl state／ctl autocal）
    static func autoCalLines(_ s: AppState) -> [String] {
        let a = s.autoCalStatus
        var l = ["自動校正：階段 \(s.autoCal.phase)（使用者看得到倒數：面板\(s.panelVisible ? "開著" : "關著")、通知\(s.canNotify ? "可以發" : "不能發")）"]
        if !a.countdownNames.isEmpty { l.append("  倒數：\(a.secondsLeft) 秒後校正 \(a.countdownNames.joined(separator: "、"))\(a.waitingMessage.map { "（\($0)）" } ?? "")") }
        if !a.runningNames.isEmpty { l.append("  執行中：\(a.runningNames.joined(separator: "、"))") }
        for p in a.pending { l.append("  需要校正：\(p.name)（\(p.message)）") }
        if !s.autoCal.holds.isEmpty { l.append("  校正完成前不出聲（app 重開／重新連線後的藍牙）：\(s.autoCal.holds.sorted().joined(separator: ", "))") }
        let eh = s.engine.reconnectHolds
        if !eh.isEmpty { l.append("  engine 暫時 hold（重連中）：\(eh.sorted().joined(separator: ", "))") }
        l.append("  選單列提示點：\(s.menuBarNeedsAttention ? "有" : "沒有")")
        return l
    }

    /// 背景監聽狀態（ctl state／ctl monitor）
    static func monitorLines(_ s: AppState) -> [String] {
        let m = s.monitorStatus
        var l = ["背景監聽：\(m.enabled ? "開" : "關")\(m.listening ? "（聆聽中）" : "")"
                 + (m.nextDue.map { "，下一輪 \(PanelText.time($0))（每 \(Int(m.intervalSeconds)) 秒）" } ?? "")
                 + (m.waitingReason.map { "，等待：\($0.text)" } ?? "")]
        if let last = m.last {
            l.append("  上次 \(PanelText.time(last.at)) 第 \(last.round) 輪\(last.confirm ? "（確認）" : "")："
                     + (last.skipped.map { "跳過／不可採信（\($0.text)：\(last.message)）" } ?? last.message))
            for d in last.devices {
                l.append("    \(d.name)：\(d.errorMs.map { String(format: "%+.2f ms", $0) } ?? "—") 信心 \(String(format: "%.2f", d.confidence))　\(d.note)")
            }
        }
        for (uid, v) in m.totals.sorted(by: { $0.key < $1.key }) { l.append(String(format: "  累計修正 %@：%+.2f ms", uid, v)) }
        let offs = s.engine.delayOffsets().filter { $0.value.probeTargetMs != 0 || $0.value.correctionTargetMs != 0 || !$0.value.settled }
        for (uid, o) in offs.sorted(by: { $0.key < $1.key }) {
            l.append(String(format: "  engine 額外延遲 %@：修正 %.3f → %.3f ms、探測 %.3f → %.3f ms", uid, o.correctionMs, o.correctionTargetMs, o.probeMs, o.probeTargetMs))
        }
        if let mic = resolveCalibrationMic(uid: s.config.calibrationMicUID) {
            // 佐證「關掉就不開麥克風」：Core Audio 的 DeviceIsRunningSomewhere（任何行程在用它都算）
            l.append("  校正麥克風「\(mic.name)」DeviceIsRunningSomewhere=\(MonitorMicCapture.isRunningSomewhere(mic.id) ? 1 : 0)")
        }
        if let bt = Devices.bluetoothOutputs().first, let inDev = Devices.all().first(where: { $0.uid == bt.uid.replacingOccurrences(of: ":output", with: ":input") }) {
            l.append("  藍牙「\(bt.name)」:input DeviceIsRunningSomewhere=\(MonitorMicCapture.isRunningSomewhere(inDev.id) ? 1 : 0)（必須 0）")
        }
        if !s.engine.latencyCorrections.isEmpty {
            l.append("  engine 延遲修正（依裝置）：" + s.engine.latencyCorrections.sorted { $0.key < $1.key }.map { String(format: "%@ %+.2f ms", $0.key, $0.value) }.joined(separator: "、"))
        }
        return l
    }

    /// 【第 C 輪】藍牙漂移補償狀態（ctl state／ctl drift）
    static func driftLines(_ s: AppState) -> [String] {
        var l = ["藍牙漂移補償：\(s.config.bluetoothDriftCompensation ? "開" : "關")（--verify-program 結果\(s.driftFeedsVerify ? "會" : "不會")當量測點）"]
        let now = Date()
        for (uid, m) in s.driftModels.sorted(by: { $0.key < $1.key }) {
            let pr = m.predict(at: now)
            l.append("  \(uid)：串流 \(m.streamKey ?? "?")（目前 \(s.lastStreamKeys[uid] ?? "?")）、\(m.points.count) 點、模型\(m.health.text)"
                     + (pr.map { String(format: "、預測 %.3f ± %.3f ms", $0.ms, $0.sigmaMs) } ?? "")
                     + (pr?.rateMsPerMin.map { String(format: "、速度 %+.4f ms／分鐘", $0) } ?? "、還沒估速度")
                     + (pr?.held == true ? "、預估誤差太大：停止外推" : ""))
            if let a = m.anchor { l.append(String(format: "    錨點（修正以它為準）：%@ %@ %.3f ms", PanelText.time(a.at), a.source.label, a.latencyMs)) }
            if let x = m.lastMiss {
                l.append(String(format: "    預測失準（> %.0f ms）：這個串流 %d 次、連續 %d 次；最近 %@ %@ %+.2f ms", m.params.missMs, m.missCount, m.consecutiveMisses,
                                PanelText.time(x.at), x.source.label, x.residualMs))
            }
            for p in m.points.suffix(8) {
                l.append(String(format: "    %@ %@ %.3f ms（σ %.1f）", PanelText.time(p.at), p.source.label, p.latencyMs, p.sigmaMs))
            }
            if let d = s.shortCal.dueAt(m) {
                l.append("    下次短校正：\(PanelText.time(d.at))（\(d.reason)）" + (s.shortCal.dueSince[uid].map { "；已到期（自 \(PanelText.time($0))）" } ?? "")
                         + ((s.shortCal.failures[uid] ?? 0) > 0 ? "；連續沒量到 \(s.shortCal.failures[uid]!) 次" : "")
                         + (s.shortCal.stopped(uid) ? "；已停止自動短校正（按「需要校正」恢復）" : ""))
            }
        }
        for r in s.driftResiduals.suffix(6) {
            l.append(String(format: "  藍牙殘差 %@ %@：%+.3f ms（%@）", PanelText.time(r.at), s.driftDeviceName(r.uid), r.ms, r.kind))
        }
        for r in s.driftStatus { l.append("  面板：\(r.name) 修正 \(r.correctionMs.map { String(format: "%+.2f ms", $0) } ?? "—")\(r.waiting.map { "；\($0)" } ?? "")") }
        if let ls = s.shortCal.lastStart { l.append("  最近一次短校正觸發：\(PanelText.time(ls.at)) \(ls.uid)（\(ls.gap ? "空檔" : "倒數")）") }
        if s.driftModels.isEmpty { l.append("  （還沒有藍牙量測點：藍牙校正後開始）") }
        return l
    }

    /// 【第 C 輪】藍牙連上後預設輸出自動切回（ctl state／ctl output-restore）
    static func outputRestoreLines(_ s: AppState) -> [String] {
        var l = ["藍牙連上時保持預設輸出：\(s.config.restoreDefaultOutputOnBluetoothConnect ? "開" : "關")（連上後 \(Int(BluetoothOutputRestorePolicy.window)) 秒內 macOS 搶預設輸出 → 切回音量來源）"]
        if let n = s.outputRestoreNote { l.append("  最近一次 \(PanelText.time(n.at))：\(n.message)") }
        l.append("  目前預設輸出：\(Devices.defaultOutput()?.name ?? "?")")
        return l
    }

    /// 設定檔唯讀保護狀態（一行）
    static func protectionLine() -> String {
        if let p = Config.writeProtection() {
            return "⚠ 設定檔唯讀保護中（自 \(p.since)）：先前的設定檔損壞，已保留為 \(p.corruptBackup)；不自動存檔，校正成功或 ctl config reset 後解除"
        }
        return "設定檔：正常（沒有唯讀保護）"
    }

    private func stateLines() -> [String] {
        let s = AppState.shared
        var l: [String] = []
        l.append("pid \(getpid()) 執行檔 \(Bundle.main.bundlePath)（\(BuildFlavor.name)，\(buildStamp)）")
        l.append(Self.protectionLine())
        l.append("running=\(s.running) ioAdvancing=\(s.ioAdvancing) engineStarting=\(s.engineStarting) calibrating=\(s.calibrating)")
        l.append("生效模式 \(s.playMode.rawValue)（設定 \(s.config.mode.rawValue)\(s.config.manualLock ? "，手動鎖定" : "")）理由：\(s.modeReason ?? "-")")
        for d in s.devices {
            let p = d.plan.map { "\($0.active ? "出聲" : "不出聲") delay \(String(format: "%.2f", $0.delayMs)) ms（\($0.reason)）" } ?? "無計畫"
            l.append("  · \(d.name)\(d.isVolumeSource ? "［音量來源］" : "")\(d.inAggregate ? "" : "［藍牙］")\(d.needsRecalibration ? "［需要重新校正］" : "") 延遲 \(d.measuredLatencyMs.map { String(format: "%.2f", $0) } ?? "未量") trim \(d.trimDb) 開關 \(d.enabled) → \(p)")
        }
        for w in s.warnings { l.append("  ⚠ [\(w.kind.rawValue)] \(w.message)\(w.actionTitle.map { "（按鈕：\($0)）" } ?? "")") }
        l.append("tap 額外排除 process object：\(s.engine.extraExcludedProcesses)")
        l.append("系統提示音行程：\(SystemSoundsRouter.systemSoundProcesses().map(\.description))")
        l.append("系統：\(SystemAudioSnapshot.capture())　系統提示音輸出：\(Devices.defaultSystemOutput()?.name ?? "?")")
        l.append("登入項目：\(LoginItem.describe(LoginItem.status))")
        l += Self.autoCalLines(s)
        l += Self.monitorLines(s)
        l += Self.driftLines(s)
        l += Self.outputRestoreLines(s)
        l.append("狀態行：\(s.statusLine)")
        return l
    }
}

/// `In_Unison42 ctl <指令…>`：送給執行中的選單列 app，等回覆
func cmdCtl(_ args: [String]) -> Int32 {
    guard !args.isEmpty else { print("用法：In_Unison42 ctl state | mode <m> | snapshot <dir> | guard-restore | calibrate [參數…] | peaks <秒> | bt … | login-item …"); return 2 }
    let id = UUID().uuidString
    let timeout: Double = args.first == "calibrate" ? 600 : 30
    DistributedNotificationCenter.default().postNotificationName(AppControlChannel.name, object: nil,
                                                                  userInfo: ["id": id, "args": args], deliverImmediately: true)
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if let r = AppControlChannel.readReply(), r.id == id {
            for l in r.lines { print(l) }
            return r.ok ? 0 : 1
        }
        usleep(100_000)
    }
    print("✗ \(Int(timeout)) 秒內沒有回覆（選單列 app 沒在跑？）")
    return 1
}
