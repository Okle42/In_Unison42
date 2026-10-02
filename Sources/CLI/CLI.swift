// CLI.swift — In_Unison42 的命令列子指令（原 main.swift）。
// 進入點在 App/AppMain.swift：帶子指令 → runCLI；不帶參數 → 選單列 app。
// CLI 分派：run / calibrate / mics / install / uninstall / start / stop / status / devices / *-selftest / help
import Foundation

let usage = """
用法：In_Unison42 [指令]（\(BuildFlavor.name)，\(buildStamp)）
  （不帶參數）            選單列 app（In_Unison42.app 雙擊或 open 啟動）
  run [--force] [--mode music|movie|game]
                          前景執行引擎（CLI 沒有前景 app 偵測：設定是「自動」時用音樂模式）
  calibrate --pulse|--verify-program [--mic <uid>] [--mode music|movie|game] [--only <uid>] [--progress-lines]
                          用麥克風量測各喇叭延遲：--pulse 用脈衝＋GCC-PHAT 量尺量延遲並寫入 measuredLatencyMs；
                          --verify-program 走節目音路徑驗證對齊（不寫檔）
  pp-signal <訊號> <out.wav>   測試音寫成 WAV（試聽）；pp-reanalyze <dir>：離線重新分析 calibrate --dump <dir> 存的錄音
  mics                    列出可選的校正麥克風（含 Continuity，只用於校正）
  config [status | reset --yes]
                          設定檔狀態（損壞時的唯讀保護）／重設為預設值（壞檔 config.json.corrupt-* 保留）
  plan-selftest | autocal-selftest | drift-selftest | config-selftest | log-rotate-selftest | policy-selftest
                          plan()／設定檔損壞保護／log 輪替／發行版白名單 離線自測
  panel-snapshot <png> [--dark] | --fake <dir> | --selftest
                          面板離屏渲染成 PNG（不啟動引擎、不碰螢幕）；render-panel <dir> = --fake 的別名
  ctl <指令…>             控制執行中的選單列 app（mode／state／guard-restore／calibrate／peaks／bt／login-item／config），見 ctl help
  mode-selftest | bluetooth-selftest       模式規則／藍牙重取樣離線自測
  system-sounds | login-item | output-guard 系統提示音行程、登入項目（SMAppService）、預設輸出提示
  install                 （停用）登入自動啟動改用選單列 app 的「在登入時打開」（login-item on）
  uninstall | stop        移除／停止舊版 LaunchAgent
  start | status          重新載入舊 LaunchAgent／查看狀態（含選單列 app 的 state.json）
  reconnect-selftest [-v] 重接邏輯自測（虛擬時間，不出聲）
  service-selftest        行程辨識自測（會短暫開 sh/cat 兩個無害行程）
  engine-selftest         IOProc 渲染離線自測（輸入 buffer 排列、solo、onset、延遲淡入淡出、遮罩、節目音緩衝；不出聲）
  devices                 列出音訊裝置與分類
  version                 建置標記與種類（debug／release）
  help                    顯示這段說明
\(BuildFlavor.diagnostics ? diagnosticUsage : "（診斷指令只在除錯版：./build.sh 預設，或 ./build.sh --install-debug）")
設定檔：\(Config.fileURL.path)
"""

/// 除錯版才有的指令與參數
let diagnosticUsage = """
診斷（只在除錯版）：
  calibrate [--verify|--verify-program [--check-silent]|--volume-test] [--level] [--mic <uid|名稱|auto>]
            [--signal noise|xylo|xylo-strong|ab|ab-strong|ab-pink] [--dump <dir>] [--cal-gain-db dB|off] …
                          chirp 量尺（沒有 --pulse）、--level 響度匹配、木琴／A-B 比對、--dump 存錄音（pp-reanalyze 用）
  mic-probe [--mic q] [--seconds s] [--burst|--beep]
                          錄麥克風並在第 1 秒播測試脈衝（afplay）或系統提示音（osascript beep），回報比底噪高幾 dB
  bt-tone-test <raw|raw-tap|btout|gate> …   藍牙輸出路徑診斷
  output-guard set <uid|名稱> --yes          把預設輸出切到指定裝置（觸發警告用）
  snapshot-live-test      實機測 SystemAudioSnapshot 還原規則（只往下調、不覆蓋使用者操作；會短暫調低音量／切預設輸出）
  engine-live-test        實機測 Engine 執行中 API（會開 tap；要用 app 身分跑：open -W --stdout f build/In_Unison42.app --args engine-live-test）
  ctl snapshot <dir> | ctl bt detach-all|attach <id>|detach <uid>|simulate-reconnect <uid>
"""

/// 中斷時的清理掛鉤：校正等流程在改動系統狀態前註冊還原動作（例如 SystemAudioSnapshot.restore）。
/// SIGINT／SIGTERM 時先依註冊的相反順序執行，再停 engine。正常結束的還原仍由呼叫端自己做。
enum Cleanup {
    private struct State { var handlers: [(id: Int, run: () -> Void)] = []; var nextID = 0 }
    private static let state = LockedValue(State())

    /// 回傳 id，可用 unregister 取消
    @discardableResult
    static func register(_ f: @escaping () -> Void) -> Int {
        state.withLock { st in
            st.nextID += 1
            st.handlers.append((st.nextID, f))
            return st.nextID
        }
    }

    static func unregister(_ id: Int) {
        state.withLock { $0.handlers.removeAll { $0.id == id } }
    }

    static func runAll() {
        let hs = state.withLock { st -> [() -> Void] in
            let hs = st.handlers.reversed().map(\.run)
            st.handlers.removeAll()
            return hs
        }
        for h in hs { h() }
    }
}

/// SIGINT／SIGTERM：跑 Cleanup、停 engine（清除 tap／聚合裝置）後結束
/// 已安裝的 signal source（要保留參考，否則會被釋放）
let signalSources = LockedValue<[DispatchSourceSignal]>([])
func installSignalHandlers(_ onSignal: @escaping (Int32) -> Void) {
    let q = DispatchQueue(label: "In_Unison42.signals")
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: sig, queue: q)
        s.setEventHandler { onSignal(sig) }
        s.resume()
        signalSources.withLock { $0.append(s) }
    }
}

/// 狀態行心跳間隔（秒）；環境變數 IN_UNISON42_STATUS_HEARTBEAT 可覆寫（測試用）
let statusHeartbeat: Double = {
    if let v = ProcessInfo.processInfo.environment["IN_UNISON42_STATUS_HEARTBEAT"], let d = Double(v), d > 0 { return d }
    return 600
}()

func cmdRun(_ args: [String]) -> Int32 {
    // 兩個 tap 同時存在會互相靜音：已有別的 run 在跑就不啟動（--force 例外）
    // 實例鎖（InstanceLock，flock）：選單列 app、其他 run 都拿同一把；舊版 LaunchAgent 另外比對
    if let why = acquireTapInstance() {
        print("⚠ \(why)")
        if !args.contains("--force") {
            print("  先執行 `In_Unison42 stop`，或加 --force。")
            // 由 launchd 啟動時回 0，避免 KeepAlive 每 5 秒重試
            return ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == ServicePaths.label ? 0 : 3
        }
    }
    let snapshot = SystemAudioSnapshot.capture()
    print("系統狀態：\(snapshot)")
    var mode: PlayMode? = nil
    if let i = args.firstIndex(of: "--mode") {
        guard i + 1 < args.count, let m = PlayMode(rawValue: args[i + 1]) else { print("--mode 要接 music／movie／game"); return 2 }
        mode = m
    }
    let engine = Engine(mode: mode)
    let cfg = engine.config
    print("設定：\(Config.fileURL.path)（\(cfg.devices.count) 個裝置設定，設定模式 \(cfg.mode.label) → 生效 \(engine.mode.label)）")
    installSignalHandlers { sig in
        print("收到 \(sig == SIGINT ? "SIGINT" : "SIGTERM")，清除中…")
        Cleanup.runAll()
        engine.stop()
        print("✓ 乾淨結束")
        exit(0)
    }
    do {
        try engine.start()
    } catch {
        print("✗ \(error)")
        return 1
    }
    writePidFile()
    let reconnector = Reconnector(engine: engine)
    reconnector.start()
    // 狀態行：每 5 秒取樣，只在狀態有變（gen、音量、靜音、輸出組成／增益／延遲、skip、輸入錯位）時才印，
    // 另外每 statusHeartbeat 秒印一次心跳；log 太大就輪替（一般約 20 MB）
    rotateStdoutLogIfNeeded()
    let last = LockedValue((key: "", printed: Date.distantPast))
    let statusTimer = Timer(timeInterval: 5, repeats: true) { _ in
        let st = engine.status()
        let now = Date()
        let due = last.withLock { l -> Bool in
            guard st.changeKey != l.key || now.timeIntervalSince(l.printed) >= statusHeartbeat else { return false }
            l = (st.changeKey, now)
            return true
        }
        if due { print(st.line) }
        rotateStdoutLogIfNeeded()
    }
    RunLoop.main.add(statusTimer, forMode: .common)
    // SIGUSR1：強制重建一次（診斷用，例如量重建耗時）
    signal(SIGUSR1, SIG_IGN)
    let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    usr1.setEventHandler { reconnector.requestRebuild("SIGUSR1 手動要求") }
    usr1.resume()
    signalSources.withLock { $0.append(usr1) }
    withExtendedLifetime((reconnector, statusTimer)) {
        RunLoop.main.run()
    }
    return 0
}

func cmdCalibrate(_ args: [String]) -> Int32 {
    if !BuildFlavor.diagnostics,
       let why = ReleasePolicy.checkCalibrateArgs(args, micUIDs: availableCalibrationMics().map(\.uid), allowCLIExtras: true) {
        print("✗ \(why)")
        return 2
    }
    if args.contains("--selftest") { return runCalibrate(engine: Engine(), args: args) }
    // 校正子行程只在量測成功時寫設定檔 → 這個行程的寫入算「使用者明確操作」（可解除設定檔損壞的唯讀保護）
    Config.explicitWritesAllowed = true
    // 校正要自己建 tap；常駐服務或手動 run 在跑時兩個 tap 會互相靜音 → 先暫停服務、結束後恢復
    // 由選單列 app 呼叫（CalibrationRunner）：app 已先停掉自己的 engine，這個「實例」不算擋路
    let parent = ProcessInfo.processInfo.environment["IN_UNISON42_CALIBRATE_PARENT"].flatMap { pid_t($0) }
    if let parent { print("由選單列 app（pid \(parent)）呼叫；app 的引擎已暫停") }
    let manual = findLegacyRunInstances().filter { $0.pid != launchdState().pid && $0.pid != parent }
    if !manual.isEmpty {
        print("✗ 有舊版手動執行的 In_Unison42 run（pid \(manual.map { String($0.pid) }.joined(separator: ", "))），請先結束（In_Unison42 stop）再校正")
        return 1
    }
    // 實例鎖：由 app 呼叫時鎖在 app（parent）手上；獨立執行時自己拿（期間 app 若啟動會等到校正結束）
    if let h = InstanceLock.holderPID(), h != getpid(), h != parent {
        print("✗ 另一個 In_Unison42（pid \(h)）正在跑同步播放，兩個 tap 會互相靜音；請從選單列 app 的「延遲校正」或 `In_Unison42 ctl calibrate …` 校正")
        return 1
    }
    if parent == nil && !InstanceLock.tryAcquire() {
        print("✗ 拿不到實例鎖（\(InstanceLock.url.path)）：另一個 In_Unison42 剛啟動")
        return 1
    }
    var resumeService = false
    if launchdState().loaded {
        print("暫停常駐服務（校正完自動恢復）…")
        guard launchdBootout() else { print("✗ 無法暫停常駐服務"); return 1 }
        resumeService = true
    }
    func resume() {
        guard resumeService else { return }
        resumeService = false
        let r = launchdBootstrap()
        print(r.status == 0 ? "✓ 已恢復常駐服務（會讀到新設定）" : "✗ 恢復常駐服務失敗（\(r.status)）：\(r.err)；請執行 In_Unison42 start")
    }
    let engine = Engine()
    installSignalHandlers { _ in
        print("中斷，清除中…")
        Cleanup.runAll()
        engine.stop()
        resume()
        exit(130)
    }
    let rc = runCalibrate(engine: engine, args: args)
    engine.stop()
    resume()
    return rc
}

/// 重新載入已安裝的 LaunchAgent（stop 之後要馬上再開用）
func cmdStart() -> Int32 {
    guard FileManager.default.fileExists(atPath: ServicePaths.plist.path) else {
        print("✗ 尚未安裝（In_Unison42 install）"); return 1
    }
    let st = launchdState()
    if st.loaded, st.pid != nil { print("已在執行：pid \(st.pid!)"); return 0 }
    let manual = findRunInstances()
    if !manual.isEmpty {
        print("✗ 有手動執行的 run（pid \(manual.map { String($0.pid) }.joined(separator: ", "))），請先 stop"); return 1
    }
    let r = st.loaded ? shell("/bin/launchctl", ["kickstart", ServicePaths.serviceTarget]) : launchdBootstrap()
    guard r.status == 0 else { print("✗ 啟動失敗（\(r.status)）：\(r.err)"); return 1 }
    Thread.sleep(forTimeInterval: 1)
    let s2 = launchdState()
    print("✓ 已啟動：state=\(s2.state ?? "?") pid=\(s2.pid.map(String.init) ?? "無")")
    return 0
}

func cmdDevices() -> Int32 {
    let dOut = Devices.defaultOutput()?.uid
    let dIn = Devices.defaultInput()?.uid
    for d in Devices.all() {
        var tags: [String] = []
        if d.uid == dOut { tags.append("預設輸出") }
        if d.uid == dIn { tags.append("預設輸入") }
        if Devices.isExcluded(d) { tags.append("排除") }
        if d.hasOutput, Devices.hasVolumeDecibels(d.id) {
            tags.append(String(format: "%.1fdB", Devices.volumeDecibels(d.id) ?? 0))
        }
        print("\(d)\(tags.isEmpty ? "" : "  <" + tags.joined(separator: ",") + ">")")
    }
    print("聚合裝置輸出：\(Devices.physicalOutputs().map(\.name))　藍牙（只輸出路徑）：\(Devices.bluetoothOutputs().map(\.name))")
    print("內建：\(Devices.builtInOutput()?.name ?? "無")　麥克風：\(Devices.microphone()?.name ?? "無")")
    print("系統狀態：\(SystemAudioSnapshot.capture())")
    return 0
}

/// CLI 分派；argv 不含執行檔路徑。回傳 exit code（run 正常情況不會回來：收到 SIGINT/SIGTERM 時直接 exit）
func runCLI(_ argv: [String]) -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)
    let cmd = argv.first ?? "run"
    let rest = Array(argv.dropFirst())
    // test.sh 發行版閘門：只問政策、不執行（閘門回歸時不會真的去播測試音／開麥克風／建 tap）
    if ProcessInfo.processInfo.environment["IU42_POLICY_DRYRUN"] == "1" { return ReleasePolicy.dryRun(cmd, rest) }
    if !BuildFlavor.diagnostics, let why = ReleasePolicy.checkCLICommand(cmd, rest) {
        print("✗ \(why)")
        return 2
    }
    let rc: Int32
    switch cmd {
    case "run": rc = cmdRun(rest)
    case "start": rc = cmdStart()
    case "reconnect-selftest": rc = runReconnectSelfTest(verbose: rest.contains("-v"))
    case "service-selftest": rc = runServiceSelfTest()
    case "engine-selftest": rc = runEngineSelfTest()
    case "config-selftest": rc = runConfigSelfTest()
    case "log-rotate-selftest": rc = runLogRotateSelfTest()
    case "policy-selftest": rc = runReleasePolicySelfTest()
    case "config": rc = cmdConfig(rest)
    case "version", "--version": print("In_Unison42 \(buildStamp)（\(BuildFlavor.name)）"); rc = 0
    case "calibrate": rc = cmdCalibrate(rest)
    case "mics": rc = cmdListMics()
    case "pp-reanalyze": rc = runPPReanalyze(rest)   // 調參用：離線重新分析 calibrate --dump 存的錄音
    case "pp-signal": rc = runPPSignal(rest)          // 測試音寫成 WAV（試聽／離線分析）
    case "plan-selftest": rc = runPlanSelfTest()
    case "autocal-selftest": rc = runAutoCalibrationSelfTest()   // 自動校正狀態機（純邏輯，不出聲）
    case "drift-selftest": rc = runDriftSelfTest()               // 【第 C 輪】藍牙漂移模型／短校正排程／預設輸出自動切回（純邏輯）
    case "panel-snapshot": rc = cmdPanelSnapshot(rest)
    case "render-panel": rc = cmdPanelSnapshot(["--fake"] + rest)
    case "ctl": rc = cmdCtl(rest)
    #if IU42_DIAG
    case "bt-tone-test": rc = cmdBTToneTest(rest)      // 診斷：藍牙輸出路徑到底有沒有出聲
    case "mic-probe": rc = cmdMicProbe(rest)
    case "engine-live-test": rc = runEngineLiveTest()
    case "snapshot-live-test": rc = runSnapshotLiveTest()
    case "monitor-selftest": rc = runMonitorSelfTest(rest)   // 背景監聽演算法離線自測（--quick 約 7 秒；純運算、不開麥克風）
    case "monitor-sim": rc = cmdMonitorSim(rest)             // 背景監聽：單次模擬、印完整結果（調參用）
    #endif
    // 以下由各 owner 實作（函式在各自的檔案裡）
    case "mode-selftest": rc = runModeSelfTest()
    case "system-sounds": rc = cmdSystemSounds(rest)
    case "login-item": rc = cmdLoginItem(rest)
    case "output-guard": rc = cmdOutputGuard(rest)
    case "bluetooth-selftest": rc = runBluetoothSelfTest()
    case "install", "uninstall", "stop", "status": rc = runService(cmd, args: rest)
    case "devices": rc = cmdDevices()
    case "help", "-h", "--help": print(usage); rc = 0
    default: print("未知指令：\(cmd)\n\n\(usage)"); rc = 2
    }
    return rc
}

/// `config status|reset`：設定檔狀態（含損壞唯讀保護）／重設為預設值（使用者明確操作，解除保護；壞檔保留）
/// 選單列 app 在跑時請用 `ctl config reset`（app 會同時重新載入）
func cmdConfig(_ args: [String]) -> Int32 {
    switch args.first ?? "status" {
    case "status":
        print("設定檔：\(Config.fileURL.path)（\(FileManager.default.fileExists(atPath: Config.fileURL.path) ? "存在" : "不存在")）")
        if let p = Config.writeProtection() {
            print("⚠ 唯讀保護中（自 \(p.since)）：先前的設定檔損壞，已保留為 \(p.corruptBackup)；校正成功或 `config reset` 後解除")
            print("  解析錯誤：\(p.error)")
            return 1
        }
        print("✓ 沒有唯讀保護")
        return 0
    case "reset":
        guard args.contains("--yes") else {
            print("會把設定檔重設為預設值（所有實測延遲、trim、模式都會清掉；壞檔 config.json.corrupt-* 保留）。加 --yes 才執行")
            return 0
        }
        do { try Config.resetToDefaults() } catch { print("✗ 重設失敗：\(error)"); return 1 }
        print("✓ 已重設 \(Config.fileURL.path)，唯讀保護已解除")
        return 0
    default:
        print("用法：In_Unison42 config [status | reset --yes]")
        return 2
    }
}

// MARK: - 發行版／除錯版

/// 建置種類：build.sh 預設（debug）加 -D IU42_DIAG；--release 不加 → 危險診斷整段不編進去
enum BuildFlavor {
    #if IU42_DIAG
    static let diagnostics = true
    #else
    static let diagnostics = false
    #endif
    #if DEBUG
    static let name = diagnostics ? "debug＋診斷" : "debug"
    #else
    static let name = diagnostics ? "release＋診斷" : "release"
    #endif
}

/// 發行版的指令白名單（純函式；除錯版不套用）
enum ReleasePolicy {
    /// 發行版能用的 calibrate 參數。--only 由校正實作者實作，這裡只放行參數
    static let calibrateFlags: Set<String> = ["--pulse", "--verify-program"]
    static let calibrateValueFlags: Set<String> = ["--mode", "--only", "--mic"]
    /// 不改變量測種類的修飾旗標（【第 C 輪】--full：--only 藍牙也用完整量測，app 在短量測找不到藍牙時自動改用）
    static let calibrateModifierFlags: Set<String> = ["--full"]
    /// CLI 直接跑 calibrate 另外允許（無害）：離線自測、進度行格式
    static let calibrateCLIExtras: Set<String> = ["--selftest", "--progress-lines"]
    /// 只在除錯版提供的 CLI 指令
    static let diagnosticCommands: Set<String> = ["bt-tone-test", "mic-probe", "engine-live-test", "snapshot-live-test",
                                                   "monitor-selftest", "monitor-sim"]

    /// calibrate 參數是否允許；nil = 允許，否則回傳拒絕理由。
    /// --mic 只能是 micUIDs（availableCalibrationMics() 的 uid）裡的值（不接受名稱、auto、藍牙）
    static func checkCalibrateArgs(_ args: [String], micUIDs: [String], allowCLIExtras: Bool) -> String? {
        var i = 0
        var hasAction = false
        while i < args.count {
            let a = args[i]; i += 1
            if calibrateFlags.contains(a) { hasAction = true; continue }
            if calibrateModifierFlags.contains(a) { continue }
            if allowCLIExtras && calibrateCLIExtras.contains(a) { if a == "--selftest" { hasAction = true }; continue }
            if calibrateValueFlags.contains(a) {
                guard i < args.count, !args[i].hasPrefix("--") else { return "\(a) 後面要接值" }
                let v = args[i]; i += 1
                switch a {
                case "--mode": if PlayMode(rawValue: v) == nil { return "--mode 只能是 music／movie／game" }
                case "--mic": if !micUIDs.contains(v) { return "發行版的 --mic 只接受可用校正麥克風的 UID（`In_Unison42 mics` 列出）：\(v)" }
                default: if v.isEmpty { return "\(a) 後面要接值" }
                }
                continue
            }
            return "發行版的 calibrate 不提供「\(a)」（只准 --pulse／--verify-program／--mode／--only <uid>／--mic <uid>／--full）；診斷請用除錯版（./build.sh）"
        }
        return hasAction ? nil : "發行版的 calibrate 要指定 --pulse 或 --verify-program（chirp／木琴／A-B 比對只在除錯版）"
    }

    /// IU42_POLICY_DRYRUN=1：只跑這個建置會套用的政策檢查（CLI 指令＋calibrate 參數），印結果就回傳，**絕不執行指令**。
    /// 0 = 會放行、2 = 會拒絕。除錯版不套用政策 → 一律 0。只讀裝置清單（calibrate --mic 要比對可用麥克風），不開任何裝置
    static func dryRun(_ cmd: String, _ rest: [String]) -> Int32 {
        var why: String? = nil
        if !BuildFlavor.diagnostics {
            why = checkCLICommand(cmd, rest)
            if why == nil, cmd == "calibrate" {
                why = checkCalibrateArgs(rest, micUIDs: availableCalibrationMics().map(\.uid), allowCLIExtras: true)
            }
        }
        print(why.map { "policy-dryrun: deny（\($0)）" } ?? "policy-dryrun: allow（\(BuildFlavor.name)；未執行）")
        return why == nil ? 0 : 2
    }

    /// CLI 指令是否允許；nil = 允許
    static func checkCLICommand(_ cmd: String, _ rest: [String]) -> String? {
        if diagnosticCommands.contains(cmd) { return "「\(cmd)」是診斷指令，只在除錯版提供（./build.sh 預設、或 --install-debug）" }
        if cmd == "output-guard" && rest.first == "set" { return "「output-guard set」是測試用診斷指令，只在除錯版提供" }
        return nil
    }

    /// ctl 白名單（發行版）：面板本來就能做的事＋唯讀查詢
    static func checkCtl(_ args: [String]) -> String? {
        let cmd = args.first ?? "help"
        let rest = Array(args.dropFirst())
        switch cmd {
        case "state", "mode", "guard-restore", "peaks", "trim", "reload-config", "login-item", "config", "help", "calibrate", "autocal":
            return nil
        case "bt":
            let sub = rest.first ?? "status"
            return ["status", "resync"].contains(sub) ? nil : "發行版的 ctl bt 只提供 status／resync（attach／detach／simulate-reconnect 只在除錯版）"
        case "monitor":
            // 背景監聽：面板本來就有開關；now／bias 是測試入口（只在除錯版）
            let sub = rest.first ?? "status"
            return ["status", "on", "off"].contains(sub) ? nil : "發行版的 ctl monitor 只提供 status／on／off（now／bias 只在除錯版）"
        case "drift":
            // 【第 C 輪】藍牙漂移補償：狀態／面板開關；verify-feed on|off（驗收用：--verify-program 結果要不要餵進模型，執行期、不存檔）
            let sub = rest.first ?? "status"
            if ["status", "on", "off"].contains(sub) { return nil }
            if sub == "verify-feed", rest.count >= 2, ["on", "off"].contains(rest[1]) { return nil }
            return "發行版的 ctl drift 只提供 status／on／off／verify-feed on|off"
        case "output-restore":
            // 【第 C 輪】藍牙連上後 macOS 搶預設輸出 → 自動切回：狀態／面板開關
            let sub = rest.first ?? "status"
            return ["status", "on", "off"].contains(sub) ? nil : "發行版的 ctl output-restore 只提供 status／on／off"
        default:
            return "發行版的 ctl 不提供「\(cmd)」（snapshot 等診斷只在除錯版）"
        }
    }
}

/// `In_Unison42 policy-selftest`：白名單規則（純函式，除錯版／發行版都跑得到）＋這個建置的診斷指令是否存在
func runReleasePolicySelfTest() -> Int32 {
    var fail = 0
    func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "（\(detail)）")")
        if !ok { fail += 1 }
    }
    let mics = ["C270-uid", "iPhone-uid"]
    func cal(_ a: [String], cli: Bool = false) -> String? { ReleasePolicy.checkCalibrateArgs(a, micUIDs: mics, allowCLIExtras: cli) }
    print("── 1. ctl calibrate 白名單 ──")
    check(cal(["--pulse"]) == nil, "--pulse")
    check(cal(["--mic", "C270-uid", "--pulse"]) == nil, "--mic <可用 uid> --pulse（面板送的格式）")
    check(cal(["--verify-program", "--mode", "game"]) == nil, "--verify-program --mode game")
    check(cal(["--pulse", "--only", "AA-BB-CC-DD-EE-01:output"]) == nil, "--pulse --only <uid>")
    check(cal(["--mic", "C270-uid", "--pulse", "--only", "usb,AA-BB-CC-DD-EE-01:output"]) == nil, "自動校正送的格式：--mic <uid> --pulse --only a,b")
    check(cal(["--pulse", "--full", "--only", "AA-BB-CC-DD-EE-01:output"]) == nil && cal(["--verify-program", "--only", "bt"]) == nil,
          "【第 C 輪】--full（短量測找不到時的完整量測）、--verify-program --only（只量藍牙的驗證）")
    check(cal(["--full"]) != nil, "只有 --full（沒有 --pulse／--verify-program）拒絕")
    check(cal(["--pulse", "--dump", "/tmp/x"]) != nil, "拒絕 --dump")
    check(cal(["--pulse", "--mic", "auto"]) != nil, "拒絕 --mic auto（不是 uid）")
    check(cal(["--pulse", "--mic", "AA-BB-CC-DD-EE-01:input"]) != nil, "拒絕 --mic 不在清單的 uid（藍牙輸入）")
    check(cal(["--pulse", "--mic"]) != nil, "拒絕 --mic 沒有值")
    check(cal(["--pulse", "--mode", "loud"]) != nil, "拒絕 --mode 亂值")
    check(cal([]) != nil && cal(["--verify"]) != nil && cal(["--level"]) != nil, "拒絕 chirp（沒有 --pulse／--verify-program、--verify、--level）")
    check(cal(["--pulse", "--signal", "xylo"]) != nil && cal(["--verify-program", "--signal", "ab"]) != nil, "拒絕木琴／A-B 比對")
    check(cal(["--volume-test"]) != nil && cal(["--pulse", "--bt-uncalibrated"]) != nil && cal(["--pulse", "--cal-gain-db", "0"]) != nil,
          "拒絕 --volume-test／--bt-uncalibrated／--cal-gain-db")
    check(cal(["--selftest"]) != nil && cal(["--selftest"], cli: true) == nil, "--selftest 只在 CLI 放行（ctl 不行）")
    print("── 2. CLI／ctl 指令 ──")
    for c in ["bt-tone-test", "mic-probe", "engine-live-test", "snapshot-live-test"] {
        check(ReleasePolicy.checkCLICommand(c, []) != nil, "發行版拒絕 \(c)")
    }
    check(ReleasePolicy.checkCLICommand("output-guard", ["set", "x", "--yes"]) != nil && ReleasePolicy.checkCLICommand("output-guard", ["check"]) == nil,
          "output-guard set 拒絕、check 放行")
    check(ReleasePolicy.checkCLICommand("calibrate", ["--pulse"]) == nil && ReleasePolicy.checkCLICommand("pp-reanalyze", ["d"]) == nil, "一般指令放行")
    check(ReleasePolicy.checkCtl(["snapshot", "/tmp"]) != nil && ReleasePolicy.checkCtl(["bt", "detach-all"]) != nil
          && ReleasePolicy.checkCtl(["bt", "simulate-reconnect", "u"]) != nil, "ctl snapshot／bt detach-all／simulate-reconnect 拒絕")
    check(ReleasePolicy.checkCtl(["state"]) == nil && ReleasePolicy.checkCtl(["bt"]) == nil && ReleasePolicy.checkCtl(["calibrate", "--pulse"]) == nil
          && ReleasePolicy.checkCtl(["config", "reset"]) == nil, "ctl state／bt status／calibrate／config 放行")
    check(ReleasePolicy.checkCtl(["autocal", "status"]) == nil && ReleasePolicy.checkCtl(["autocal", "cancel"]) == nil, "ctl autocal 放行（面板本來就能做）")
    check(ReleasePolicy.checkCtl(["monitor"]) == nil && ReleasePolicy.checkCtl(["monitor", "on"]) == nil && ReleasePolicy.checkCtl(["monitor", "off"]) == nil,
          "ctl monitor status／on／off 放行（面板開關）")
    check(ReleasePolicy.checkCtl(["monitor", "now"]) != nil && ReleasePolicy.checkCtl(["monitor", "bias", "u", "2"]) != nil, "ctl monitor now／bias 拒絕（測試入口）")
    check(ReleasePolicy.checkCLICommand("monitor-selftest", []) != nil && ReleasePolicy.checkCLICommand("monitor-sim", []) != nil, "發行版拒絕 monitor-selftest／monitor-sim")
    let corr = ["AA-BB-CC-DD-EE-01:output": 1.25, "AppleUSBAudioEngine:x,y:1": -0.5]
    let rt = CalibrationRunner.decodeCorrections(CalibrationRunner.encodeCorrections(corr))
    check(rt == corr && CalibrationRunner.decodeCorrections("bad\nu=nan\nv=999") .isEmpty,
          "驗證子行程的延遲修正環境變數：uid（含冒號／逗號）來回一致、壞值丟掉", "\(rt)")
    print("── 3. 這個建置：\(BuildFlavor.name)（buildStamp \(buildStamp)）──")
    #if IU42_DIAG
    check(BuildFlavor.diagnostics, "除錯版：診斷指令有編進來")
    #else
    check(!BuildFlavor.diagnostics, "發行版：診斷指令沒有編進來")
    #endif
    print(fail == 0 ? "✓ policy 自測全部通過" : "✗ \(fail) 項失敗")
    return fail == 0 ? 0 : 1
}
