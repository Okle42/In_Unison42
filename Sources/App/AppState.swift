// AppState.swift — 選單列 app 的狀態中樞（ObservableObject，主執行緒）
//
// 擁有：Engine、Reconnector、ModeManager、BluetoothOutManager、SystemSoundsRouter、DefaultOutputGuard。
// 面板（UI/Panel.swift）只讀這裡的 @Published 值、只呼叫這裡的「使用者動作」方法；不要直接碰 Engine。
//
// 已實作（架構階段）：啟動／停止 engine＋重接、單一實例檢查、每秒刷新狀態、狀態 log、state.json、設定讀寫與套用。
// TODO（各 owner）：見各方法上的 TODO 標記。
import AppKit
import Combine
import CoreAudio
import Foundation

/// 面板上的一台輸出
struct DeviceRow: Identifiable, Equatable {
    let uid: String
    let name: String
    let kind: DeviceKind
    /// true = 在聚合裝置裡；false = 藍牙只輸出路徑
    let inAggregate: Bool
    let isVolumeSource: Bool
    let enabled: Bool
    let trimDb: Double
    let measuredLatencyMs: Double?
    /// 目前模式下的計畫（nil = engine 還沒算到它，例如藍牙輸出還沒註冊）
    let plan: PlanEntry?
    /// 【永遠 0】即時峰值會讓 devices 每秒都「變」、整個面板每秒重畫 → 2026-09-29 起改放 `LiveMeters.outputPeaks[uid]`
    /// （只在面板開著時更新）。欄位保留只為了相容既有的建構呼叫（PanelSnapshot 假資料）
    var peak: Float = 0
    /// 藍牙：量過延遲後重新連線過，建議重新校正（Config.DeviceConfig.needsRecalibration）
    var needsRecalibration: Bool = false
    var id: String { uid }
}

/// 【第 C 輪】面板／ctl：一台藍牙的漂移補償狀態
struct DriftStatusRow: Equatable, Identifiable {
    let uid: String
    let name: String
    /// 這個串流內的量測點數
    let points: Int
    /// 漂移速度（ms／分鐘）；nil = 還沒估（點不夠／跨度太短）或不外推
    let rateMsPerMin: Double?
    /// 目前交給 engine 的修正（ms）
    let correctionMs: Double?
    /// 預估誤差（1σ，ms）
    let sigmaMs: Double?
    /// 模型健康（正常／矛盾／速度超出範圍）
    let health: String
    let healthy: Bool
    /// 下一次短校正（到期時間與原因）；nil = 不需要（沒有點：交給自動校正）
    let nextDue: Date?
    let nextReason: String?
    /// 到期了、在等什麼（「等節目音空檔」「倒數中」…）
    let waiting: String?
    /// 預估誤差太大、停止外推（修正停在那一刻）
    var held = false
    /// 【第 C 輪驗收後】最近一次預測失準（精確點和預測差 > 3 ms）；這個串流內失準幾次
    var lastMiss: String? = nil
    var misses = 0
    var id: String { uid }
}

/// 【第 C 輪】面板／log：最近一次「藍牙連上後預設輸出」的處理
struct OutputRestoreNote: Equatable {
    let at: Date
    let message: String
    /// true = 真的切回了；false = 尊重使用者（只提示）
    let restored: Bool
}

/// 面板頂端的警告
struct AppWarning: Identifiable, Equatable {
    enum Kind: String { case permission, defaultOutput, otherInstance, engine, bluetooth, config }
    let kind: Kind
    let message: String
    /// 有值 = 面板顯示一顆按鈕（例如「切回內建喇叭」）
    let actionTitle: String?
    var id: String { kind.rawValue + message }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: 給面板讀的狀態
    @Published private(set) var config: Config
    @Published private(set) var devices: [DeviceRow] = []
    /// 目前生效的模式（engine.mode）
    @Published private(set) var playMode: PlayMode
    /// 自動模式下，決定目前模式的理由（例如「前景 IINA」）；手動時為 nil
    @Published private(set) var modeReason: String?
    @Published private(set) var warnings: [AppWarning] = []
    @Published private(set) var running = false
    /// 最近 2 秒 IOProc 有前進
    @Published private(set) var ioAdvancing = false
    /// IOProc 沒前進、但沒有程式在播聲音：tap 的 IO 是 autostart，這是正常待命（不顯示「音訊沒有在跑」、不亮警告）
    @Published private(set) var engineIdle = false
    /// engine 狀態行（含每秒跳動的 t／io／峰值）：**不是 @Published**（每秒變 → 會讓選單列圖示與面板每秒重算）。
    /// ctl state 直接讀；面板要顯示請綁 `meters.statusLine`（只在面板開著時更新）
    private(set) var statusLine = ""
    @Published private(set) var calibrationMics: [CalibrationMic] = []
    /// 自動校正（新裝置接上／app 重開後的藍牙）：倒數、執行中、需要校正、暫停出聲的藍牙（見 AutoCalibration.swift）
    @Published private(set) var autoCalStatus = AutoCalibrationStatus()
    /// 背景監聽（播音樂時自動修正落拍）：面板顯示開關、聆聽中、最近一次結果
    @Published private(set) var monitorStatus = MonitorStatus()
    /// 【第 C 輪】藍牙漂移補償（每台藍牙：量測點、速度、目前修正、下一次短校正）
    @Published private(set) var driftStatus: [DriftStatusRow] = []
    /// 【第 C 輪】最近一次「藍牙連上後 macOS 搶預設輸出」的處理（自動切回／尊重）
    @Published private(set) var outputRestoreNote: OutputRestoreNote?

    /// 選單列圖示要加提示點：有裝置在等校正（需要校正／needsConsent／背景監聽標記／暫停出聲等校正的藍牙）
    var menuBarNeedsAttention: Bool {
        !autoCalStatus.pending.isEmpty || !autoCalStatus.heldNames.isEmpty || devices.contains { $0.needsRecalibration }
    }

    /// 面板頂部「需要校正」的原因（空 = 不顯示）
    var attentionReasons: [String] {
        var r = autoCalStatus.pending.map { "〈\($0.name)〉\($0.message)" }
        for n in autoCalStatus.heldNames where !autoCalStatus.pending.contains(where: { $0.name == n }) && !autoCalStatus.countdownNames.contains(n)
            && !autoCalStatus.runningNames.contains(n) {
            r.append("〈\(n)〉重新連線後延遲可能改變，校正完成前先不出聲")
        }
        for d in devices where d.needsRecalibration && !autoCalStatus.pending.contains(where: { $0.uid == d.uid }) {
            r.append("〈\(d.name)〉串流重開過，延遲可能改變")
        }
        return r
    }

    var menuBarSymbol: String {
        if !running { return "speaker.slash" }
        if !ioAdvancing && !engineIdle { return "exclamationmark.triangle" }
        switch playMode {
        case .music: return "hifispeaker.2"
        case .movie: return "film"
        case .game: return "gamecontroller"
        }
    }

    /// 高頻數值（峰值、狀態行）：獨立的 ObservableObject，只在面板開著時更新，不觸發 AppState 的 objectWillChange
    let meters = LiveMeters()
    /// 面板是否開著（PanelView onAppear／onDisappear＋每秒用 NSApp.windows 校正）
    private(set) var panelVisible = false

    // MARK: 元件
    let engine: Engine
    private var reconnector: Reconnector?
    let modeManager: ModeManager
    let bluetooth: BluetoothOutManager
    let systemSounds: SystemSoundsRouter
    let outputGuard: DefaultOutputGuard

    private var timer: Timer?
    /// AppState 對 engine 的所有呼叫都丟到這個序列 queue（engine 方法可能等 engine queue，不能卡主執行緒）
    private let control = DispatchQueue(label: "In_Unison42.app.control", qos: .userInitiated)
    private var lastIO: (cycles: Int64, at: Date) = (0, .distantPast)
    private var lastChangeKey = ""
    private var lastStatusPrint = Date.distantPast
    private var otherInstance = false
    /// engine.start() 還沒回來（可能在等授權對話框）：這段時間不能呼叫任何 engine 方法（會等 engine queue、卡住主執行緒）
    @Published private(set) var engineStarting = false
    /// 校正子行程執行中（app 自己的 engine 已暫停）：不顯示「音訊沒有在跑」
    @Published private(set) var calibrating = false
    /// 最近的峰值紀錄（每次 refresh 一筆，保留 120 筆）：ctl peaks 用（系統提示音驗證）
    private(set) var peakLog: [(at: Date, input: Float, outputs: [(name: String, peak: Float)])] = []
    private var lastEngineRate: Double = 0
    /// 上一次「完整」刷新（列舉藍牙裝置、DefaultOutputGuard.evaluate：Core Audio IPC 較多）的時間與結果。
    /// 面板關著時每秒只做輕量刷新（engine 狀態），完整刷新改成事件觸發（plan／藍牙／預設輸出變化、使用者動作）＋每 10 秒一次
    private var lastFullRefresh = Date.distantPast
    private var lastBluetoothList: [AudioDevice] = []
    private var lastGuardWarning: OutputWarning?
    /// 【2026-10-04】藍牙連線健康：每台最近 btUnstableWindow 秒的（時間, 誤差過大重對時累計）；已提示過的狀態（log 只在變化時印）
    private var btResyncSamples: [String: [(at: Date, big: Int64)]] = [:]
    private var btHealthState: [String: String] = [:]
    static let btUnstableWindow: TimeInterval = 30
    /// 視窗內誤差過大重對時達這個次數 = 連線不穩（正常一整天個位數）
    static let btUnstableResyncs: Int64 = 3
    /// 設定檔唯讀保護（config.json 損壞後）：完整刷新時重讀旗標檔（面板警告＋「重設設定」按鈕）
    private var configProtection: Config.WriteProtection? = Config.writeProtection()
    static let fullRefreshInterval: TimeInterval = 10
    /// state.json：狀態變化才寫＋心跳
    private var lastStateFileKey = ""
    private var lastStateFileWrite = Date.distantPast
    static let stateFileHeartbeat: TimeInterval = 10
    /// 自動校正狀態機（start() 時重建：startedAt = app 啟動時間，用來判斷「app 重開後的藍牙」）
    private(set) var autoCal = AutoCalibrator()
    private let notifier = AutoCalNotifier()
    /// 倒數中 0.25 秒一次的 tick（平常跟著每秒 timer）
    private var autoCalTimer: Timer?
    /// 下一次 CalibrationRunner.onStarted 是我們（自動校正）發起的
    private var autoCalStarting = false
    private var lastMicName = "麥克風"
    /// 背景監聽：排程狀態機（主執行緒）＋進行中的一輪（麥克風擷取在自己的 queue）
    private var monitor = MonitorScheduler(now: Date())
    private var monitorRound: MonitorRound?
    /// 正在 control queue 上量環境（避免每秒重複排）
    private var monitorEnvPending = false
    /// 最近一次 engine 狀態的音量倍率（節目音夠不夠大：峰值 × 音量）
    private var lastVolumeGain: Float = 1

    // 【第 C 輪】藍牙漂移補償（BluetoothDrift.swift）
    private(set) var driftModels: [String: BluetoothDriftModel] = [:]
    /// 每台藍牙最近 2 個背景監聽量測（時間、換算後的相對延遲）：連續 2 次一致時取平均當「背景監聽確認」點
    private var recentMonitorObs: [String: [(at: Date, ms: Double)]] = [:]
    private(set) var shortCal = ShortCalScheduler()
    /// 最近一次交給 engine 的漂移修正（uid → ms）；nil = 下一次一定送
    private var driftApplied: [String: Double] = [:]
    private var driftLastLog: [String: (at: Date, ms: Double)] = [:]
    private var lastDriftApply = Date.distantPast
    private var lastStreamKeyPoll = Date.distantPast
    private var streamKeyPollPending = false
    /// 最近一次看到的藍牙串流識別（BluetoothOutManager.streamKeys）
    private(set) var lastStreamKeys: [String: String] = [:]
    /// 驗收用（ctl drift verify-feed off）：`--verify-program` 的結果不餵進模型，只記 log（執行期、不存檔）
    private(set) var driftFeedsVerify = true
    /// 【第 C 輪驗收後】最近的藍牙殘差（ctl drift）：只量藍牙的驗證（實測 − app 當時用的）、精確量測點（實測 − 加入前的預測）
    private(set) var driftResiduals: [(at: Date, uid: String, ms: Double, kind: String)] = []
    /// 這次自動校正是漂移補償的短校正（結束時告訴排程量到沒）
    private var driftRunUIDs: Set<String> = []
    /// 這次自動校正已經因為短量測找不到而改跑過完整量測（避免無限重跑）
    private var autoCalFullRetryDone = false
    /// 背景監聽這一輪開始時的延遲修正（結果換算成漂移量測點）
    private var monitorRoundCorrections: [String: Double] = [:]
    /// 節目音（tap 輸入）靜止開始的時間（nil = 正在播）；最近一次「可用的空檔」（連續靜止 ≥ 5 秒）的時間
    private var programSilentSince: Date?
    private var lastProgramGapAt: Date?
    /// 【第 C 輪審查】節目音從什麼時候開始連續在播；這段靜止之前連續播了幾秒（空檔要「從播放轉成靜止」才算）
    private var programPlayingSince: Date?
    private var playedBeforeSilence: TimeInterval = 0

    init(config: Config = Config.load()) {
        self.config = config
        let e = Engine(config: config)
        engine = e
        playMode = e.mode
        modeManager = ModeManager()
        bluetooth = BluetoothOutManager(engine: e)
        systemSounds = SystemSoundsRouter(engine: e)
        outputGuard = DefaultOutputGuard(engine: e)
    }

    // MARK: 生命週期

    func start() {
        guard !running, timer == nil else { return }
        AppLog.line("選單列 app 啟動（\(buildStamp)）pid \(getpid())，執行檔 \(currentExecutable()?.path ?? "?")")
        AppLog.line("系統狀態：\(SystemAudioSnapshot.capture())")
        autoCal = AutoCalibrator(startedAt: Date())
        monitor = MonitorScheduler(now: Date(), params: Self.monitorParams(config))
        notifier.onCancel = { [weak self] in MainActor.assumeIsolated { self?.cancelAutoCalibration() } }
        notifier.start()
        // 登入項目已啟用、舊 LaunchAgent 還在（登入時兩邊同時啟動）→ 直接遷移（bootout＋移到垃圾桶），不必等使用者按
        if LoginItem.isEnabled, LoginItem.hasLegacyLaunchAgent, let m = LoginItem.migrateFromLaunchAgent() {
            AppLog.line("啟動時自動遷移（登入項目已啟用）：\(m)")
        }
        NotificationCenter.default.addObserver(forName: LoginItem.legacyMigratedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryInstance(reason: "舊 LaunchAgent 已遷移") }
        }
        // 每秒：刷新狀態；等待另一個實例時順便重試（對方消失就正常啟動）
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.otherInstance { self.retryInstance(reason: nil) }
                self.syncPanelVisibilityFromWindows()
                self.autoCalTick()
                self.monitorTick()
                self.driftTick()
                // 面板開著：每秒完整刷新；關著：輕量刷新（完整刷新靠事件＋每 10 秒一次）
                self.refresh(full: self.panelVisible || Date().timeIntervalSince(self.lastFullRefresh) >= Self.fullRefreshInterval)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        retryInstance(reason: "啟動")
        refresh()
    }

    /// 同一時間只能有一個 tap 實例（兩個會互相靜音）：拿 InstanceLock（flock）＋確認沒有舊版 LaunchAgent 在跑。
    /// 拿不到 → otherInstance = true、每秒重試；拿到 → 正常啟動引擎
    private func retryInstance(reason: String?) {
        guard !running else { return }
        if let why = acquireTapInstance() {
            if !otherInstance || reason != nil {
                AppLog.line("⚠ \(why)；不啟動引擎，每秒重試\(reason.map { "（\($0)）" } ?? "")")
            }
            otherInstance = true
            return
        }
        if otherInstance { AppLog.line("另一個實例已結束（\(reason ?? "重試")）：啟動引擎") }
        otherInstance = false
        startEngineStack()
    }

    /// 拿到實例鎖之後：啟動引擎，引擎回來後再啟動其他元件（engineStartReturned）
    private func startEngineStack() {
        engine.log = { AppLog.line($0) }
        engine.onPlanChange = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.planChanged() } }
        }
        // 系統提示音：第一個 tap 建立時就排除（不等 SystemSoundsRouter.start，避免啟動那一瞬間把它靜音）
        engine.setExtraExcludedBundleIDs(SystemSoundsRouter.bundleIDs)
        engine.setExtraExcludedProcesses(SystemSoundsRouter.systemSoundProcessObjects())
        writePidFile()
        AppControl.shared.start()
        // 自動校正：已校正的藍牙在 app 重開後延遲可能改變（實測 35 ms）→ engine 開始前就先暫停出聲，第一次觀察時倒數重校
        let launchBT = Devices.bluetoothOutputs().filter { config.measuredLatencyMs($0.uid) != nil && config.device($0.uid).enabled }
        if !launchBT.isEmpty {
            autoCal.primeLaunchHolds(launchBT.map(\.uid))
            AppLog.line("自動校正：app 啟動，已校正的藍牙 \(launchBT.map(\.name).joined(separator: "、")) 先不出聲，等重新校正")
            engine.applyConfig(engineConfig(config))   // engine 還沒 start：立即生效、不會卡
        }
        running = true
        lastIO = (engine.ioCycles, Date())
        refresh()
        // engine.start() 可能卡很久（第一次要等使用者回應「系統音訊錄製」授權對話框，coreaudiod 最多等約 30 秒），
        // 所以不在主執行緒做，面板照常可以開
        let engine = self.engine
        engineStarting = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try engine.start()
            } catch {
                AppLog.line("✗ 引擎啟動失敗：\(error)（重接元件會退避重試）")
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.engineStartReturned() } }
        }
    }

    /// engine 的 plan 改變（模式、設定、rebuild、外接註冊）。rebuild 成不同取樣率時藍牙輸出要重建（sinc 表依 engine 取樣率預建）
    private func planChanged() {
        let engine = self.engine, bt = bluetooth
        control.async {
            let rate = engine.sampleRate
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if rate > 0, self.lastEngineRate > 0, rate != self.lastEngineRate {
                        if bt.allSupportEngineRate(rate) {
                            // renderer 已預建這個取樣率的 sinc 表：藍牙串流不必重開（重開 = A2DP 重新協商、延遲可能變）
                            AppLog.line("engine 取樣率 \(Int(self.lastEngineRate)) → \(Int(rate)) Hz：藍牙輸出已支援，不重開")
                        } else {
                            AppLog.line("engine 取樣率 \(Int(self.lastEngineRate)) → \(Int(rate)) Hz：藍牙輸出重建（延遲可能改變）")
                            let uids = Array(bt.outputs.keys)
                            for u in uids { self.markBluetoothNeedsRecalibration(u, reason: "engine 取樣率改變、藍牙串流重開") }
                            DispatchQueue.global(qos: .utility).async { bt.detachAll(); bt.resync() }
                        }
                    }
                    if rate > 0 { self.lastEngineRate = rate }
                    self.refresh()
                }
            }
        }
    }

    /// engine.start() 回來之後（成功或失敗）才啟動重接與其他元件
    private func engineStartReturned() {
        engineStarting = false
        guard running, reconnector == nil else { return }
        let r = Reconnector(engine: engine)
        r.start()
        reconnector = r
        wireCalibration()
        wireAutoCalibration()

        modeManager.onResolvedModeChange = { [weak self] m, reason in
            self?.applyResolvedMode(m, reason: reason)
        }
        modeManager.start(config: config)
        bluetooth.onChange = { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        bluetooth.onReconnect = { [weak self] uid in MainActor.assumeIsolated { self?.bluetoothReconnected(uid) } }
        bluetooth.onFirstConnect = { [weak self] uid in MainActor.assumeIsolated { self?.bluetoothFirstConnected(uid) } }
        bluetooth.onLatencyMayChange = { [weak self] uid, why in
            MainActor.assumeIsolated { self?.markBluetoothNeedsRecalibration(uid, reason: why) }
        }
        // 第 B 輪：藍牙真的斷線重連 → 重新 start 之前就先不出聲（之後由 bluetoothReconnected 交給自動校正）
        bluetooth.holdOnReconnect = Config.recalibrateBluetoothOnReconnect
        bluetooth.start()
        systemSounds.start()
        outputGuard.onChange = { [weak self] _ in self?.refresh() }
        outputGuard.autoRestoreEnabled.value = config.restoreDefaultOutputOnBluetoothConnect
        outputGuard.onAutoRestore = { [weak self] msg, restored in
            MainActor.assumeIsolated {
                self?.outputRestoreNote = OutputRestoreNote(at: Date(), message: msg, restored: restored)
                self?.refresh()
            }
        }
        outputGuard.start()
        let mics = availableCalibrationMics()
        if mics != calibrationMics { calibrationMics = mics }
        lastIO = (engine.ioCycles, Date())
        refresh()
    }

    /// 結束前呼叫（applicationWillTerminate）：停掉所有元件，engine.stop() 清掉 tap／聚合裝置
    func stop() {
        timer?.invalidate(); timer = nil
        AppControl.shared.stop()
        if CalibrationRunner.shared.isRunning { CalibrationRunner.shared.cancel() }
        autoCalTimer?.invalidate(); autoCalTimer = nil
        notifier.withdrawCountdown()
        monitorRound?.abort("app 結束"); monitorRound = nil
        outputGuard.stop()
        bluetooth.stop()
        modeManager.stop()
        reconnector?.stop(); reconnector = nil
        engine.stop()
        // engine 停了才清提示音排除（先清的話 tap 在結束前那一瞬間會把 systemsoundserverd 靜音）
        systemSounds.stop()
        let wasRunning = running
        running = false
        if wasRunning { AppRuntimeState.markStopped() }
        InstanceLock.release()
        AppLog.line("選單列 app 結束（tap／聚合裝置已清除）")
    }

    // MARK: 使用者動作（面板呼叫）

    /// 選模式：.auto = 回到自動（解除鎖定）；其他 = 手動鎖定該模式
    func selectMode(_ m: AudioMode) {
        updateConfig { c in
            c.mode = m
            c.manualLock = m != .auto
        }
        modeManager.update(config: config)
        if let fixed = m.fixed {
            AppLog.line("手動鎖定模式：\(fixed.label)")
            applyResolvedMode(fixed, reason: nil)
        } else {
            AppLog.line("回到自動模式")
            modeManager.reevaluate()   // 回到自動：立刻依前景 app 重算
        }
    }

    func setDeviceEnabled(_ uid: String, _ on: Bool) {
        updateConfig { c in
            var d = c.device(uid); d.enabled = on; c.devices[uid] = d
        }
    }

    /// 每台音量微調（dB，夾在 Config.trimDbRange）
    func setTrim(_ uid: String, _ db: Double) {
        let v = min(max(db, Config.trimDbRange.lowerBound), Config.trimDbRange.upperBound)
        updateConfig { c in
            var d = c.device(uid); d.trimDb = (v * 10).rounded() / 10; c.devices[uid] = d
        }
    }

    /// nil = 自動
    func setCalibrationMic(_ uid: String?) {
        if let uid, let d = Devices.device(uid: uid), d.kind.isBluetooth { return }   // 藍牙麥克風不准存成校正麥克風
        updateConfig { $0.calibrationMicUID = uid }
    }

    func setAutoModeRule(bundleID: String, mode: AudioMode?) {
        updateConfig { c in c.autoModeRules[bundleID] = mode }
        modeManager.update(config: config)
    }

    /// 一鍵把預設輸出切回音量來源（DefaultOutputGuard 實作）
    func switchDefaultOutputToVolumeSource() {
        _ = outputGuard.switchBackToVolumeSource()
        refresh()
    }

    /// 從 app 內跑校正：CalibrationRunner 暫停本 app 的 engine → 子行程 `<app 執行檔> calibrate [--mic uid]`
    /// （同一個簽章身分，TCC 權限相同）→ 結束後 reloadConfig() 並重新啟動 engine。
    /// 面板「開始校正」附加的 calibrate 參數（脈衝量尺寫入）
    static let panelCalibrationArgs = ["--pulse"]

    func runCalibration(extraArgs: [String] = []) {
        CalibrationRunner.shared.start(micUID: config.calibrationMicUID, extraArgs: extraArgs)
    }

    // MARK: 自動校正（AutoCalibrator 驅動；見 AutoCalibration.swift 開頭的規則）

    /// 交給 engine 的設定：疊上「校正完成前不出聲」的藍牙（Config.calibrationHolds，不存檔）
    func engineConfig(_ c: Config) -> Config {
        var e = c
        e.calibrationHolds = autoCal.holds
        return e
    }

    /// 面板／通知的「取消」：倒數中 → 延後（面板留「需要校正」）；自動校正執行中 → 停止子行程
    func cancelAutoCalibration() {
        if autoCal.phase == .running, CalibrationRunner.shared.isRunning {
            CalibrationRunner.shared.cancel()
            return
        }
        handleAutoCal(autoCal.cancel())
    }

    /// 面板「需要校正」：延後的裝置立刻校正（不倒數；仍會先看麥克風有沒有被占用）
    func calibratePendingNow() {
        handleAutoCal(autoCal.requestNow(now: Date()))
        autoCalTick()
    }

    /// 面板頂部「立即校正」：需要校正的全部（自動校正延後的、背景監聽標記的、串流重開過而標 needsRecalibration 的）一次 --only
    func calibrateAttentionNow() {
        for d in devices where d.needsRecalibration && config.device(d.uid).enabled {
            _ = autoCal.flagNeedsCalibration(uid: d.uid, name: d.name, reason: "串流重開過，延遲可能改變")   // 不發通知：使用者正在按
        }
        AppLog.line("面板：立即校正（需要校正的裝置）")
        calibratePendingNow()
    }

    #if IU42_DIAG
    /// 【除錯版】模擬「uid 這台裝置剛接上」：先給狀態機一次沒有它的觀察，再給一次有它的（走和真的熱插拔同一條 observe 路徑）。
    /// 用來實機驗證新裝置倒數／取消／需要校正（手邊沒辦法真的拔插時）。回傳 false = 目前裝置清單裡沒有這台
    func simulateDeviceAppeared(_ uid: String) -> Bool {
        guard devices.contains(where: { $0.uid == uid }) else { return false }
        let devs = devices.map { r in
            AutoCalDevice(uid: r.uid, name: r.name, isBluetooth: !r.inAggregate, hasLatency: config.measuredLatencyMs(r.uid) != nil,
                          enabled: r.enabled, isReference: r.isVolumeSource || r.kind == .builtIn)
        }
        AppLog.line("自動校正（模擬，除錯版）：「\(devices.first { $0.uid == uid }!.name)」拔掉再接上")
        handleAutoCal(autoCal.observe(devs.filter { $0.uid != uid }, now: Date()))
        handleAutoCal(autoCal.observe(devs, now: Date()))
        autoCalTick()
        return true
    }
    #endif

    /// 需要時才量環境（麥克風占用要讀 Core Audio 屬性；不會開麥克風）
    private func autoCalTick() {
        guard running, autoCal.needsEnvironment else { return }
        handleAutoCal(autoCal.tick(now: Date(), env: autoCalEnvironment()))
    }

    private func autoCalEnvironment() -> AutoCalEnvironment {
        var env = AutoCalEnvironment()
        let runner = CalibrationRunner.shared
        env.canRun = running && !engineStarting && !otherInstance && reconnector != nil && runner.isWired && !runner.isRunning && !calibrating
        // 使用者看得到倒數才自動倒數：面板開著，或能發通知（通知沒授權時面板平常是關著的，會變成無預警播測試音、開麥克風）
        notifier.refreshAuthorization()
        env.userCanSee = panelVisible || notifier.canNotify
        if let mic = resolveCalibrationMic(uid: config.calibrationMicUID) {
            env.micName = mic.name
            lastMicName = mic.name
            // DeviceIsRunningSomewhere：有任何行程在用它。我們平常不開麥克風（只有校正子行程會開，那時不會走到這裡）
            // 背景監聽自己開著麥克風時不算「被占用」（校正要開始時 monitorTick 會中止那一輪）
            env.micBusy = monitorRound == nil && MonitorMicCapture.isRunningSomewhere(mic.id)
        } else {
            env.micAvailable = false
        }
        return env
    }

    private func handleAutoCal(_ acts: [AutoCalAction]) {
        for a in acts {
            switch a {
            case .log(let m):
                AppLog.line(m)
            case .countdownStarted(let names, let secs):
                AppLog.line("自動校正：\(secs) 秒後校正 \(names.joined(separator: "、"))")
                notifier.countdown(names: names, seconds: secs)
            case .deferred(let names, let reason):
                AppLog.line("自動校正：延後 \(names.joined(separator: "、"))（\(reason.text)）")
                notifier.deferred(names: names, reason: reason, micName: lastMicName)
            case .startCalibration(let uids):
                let runner = CalibrationRunner.shared
                // 子行程在「只有一台已校正的藍牙」時自動走短量測；短量測在預期的窗內找不到 → onFinished 接著改跑 --full（只一次）
                let full: [String] = []
                driftRunUIDs = autoCal.batchIsDriftOnly ? Set(uids) : []
                autoCalFullRetryDone = false
                AppLog.line("自動校正：開始 calibrate --pulse \(full.isEmpty ? "" : "--full ")--only \(uids.joined(separator: ","))\(driftRunUIDs.isEmpty ? "" : "（漂移補償短校正）")")
                notifier.withdrawCountdown()
                autoCalStarting = true
                runner.start(micUID: config.calibrationMicUID, extraArgs: AppState.panelCalibrationArgs + full + ["--only", uids.joined(separator: ",")])
                autoCalStarting = false
                if !runner.isRunning, case .finished = runner.phase {
                    handleAutoCal(autoCal.startFailed("無法啟動校正"))
                }
            case .holdsChanged(let h):
                AppLog.line("自動校正：暫停出聲的藍牙 = [\(h.sorted().joined(separator: ", "))]")
                let c = engineConfig(config), engine = self.engine
                control.async { engine.applyConfig(c) }
                refresh()
            case .finished(let ok, let failed, let cancelled):
                notifier.finished(ok: ok, failed: failed, cancelled: cancelled)
            }
        }
        updateAutoCalStatus()
    }

    private func updateAutoCalStatus() {
        let st = autoCal.status(now: Date())
        if st != autoCalStatus { autoCalStatus = st }
        // 倒數中：0.25 秒 tick（倒數精準到 0.25 秒、面板秒數跟得上）；其他時候靠每秒 timer
        let counting: Bool
        if case .countdown = autoCal.phase { counting = true } else { counting = autoCal.phase == .waiting }
        if counting, autoCalTimer == nil {
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.autoCalTick()
                    self.updateAutoCalStatus()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            autoCalTimer = t
        } else if !counting, let t = autoCalTimer {
            t.invalidate(); autoCalTimer = nil
        }
    }

    /// CalibrationRunner 的開始／結束 → 自動校正狀態機（engineStartReturned 裡接一次）
    private func wireAutoCalibration() {
        let runner = CalibrationRunner.shared
        runner.onStarted = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 任何校正開始：背景監聽這一輪立刻停（拿掉探測偏移、關麥克風）
                if let r = self.monitorRound { r.abort("校正開始"); }
                // 我們發起的：startIfPossible 已經進 running；別人（面板「開始校正」、ctl）發起的：倒數先擱著
                if !self.autoCalStarting { self.autoCal.externalRunStarted(); self.updateAutoCalStatus() }
            }
        }
        runner.onFinished = { [weak self] ok, cancelled, msg, lines in
            MainActor.assumeIsolated {
                guard let self else { return }
                let measured = parseMeasuredUIDs(lines)
                // 【第 C 輪】短量測在預期的窗內找不到藍牙（例如重連後延遲跳太多）→ 同一次自動校正接著改跑完整量測（使用者已經同意過這次校正）
                let miss = parseShortMissUIDs(lines).subtracting(measured)
                if !cancelled, self.autoCal.phase == .running, !miss.isEmpty, !self.autoCalFullRetryDone, self.driftRunUIDs.isEmpty {
                    self.autoCalFullRetryDone = true
                    AppLog.line("自動校正：短量測沒有找到 \(miss.sorted().joined(separator: ","))，接著改用完整量測（--full）")
                    self.autoCalStarting = true
                    CalibrationRunner.shared.start(micUID: self.config.calibrationMicUID,
                                                   extraArgs: AppState.panelCalibrationArgs + ["--full", "--only", miss.sorted().joined(separator: ",")])
                    self.autoCalStarting = false
                    if CalibrationRunner.shared.isRunning { return }
                }
                self.driftHandleCalibrationOutput(lines, measured: measured, cancelled: cancelled)
                self.handleAutoCal(self.autoCal.finished(measured: measured, cancelled: cancelled, message: ok ? "" : msg, now: Date()))
                // 重新校正過的裝置：背景監聽的等確認／累計修正／標記歸零，engine 的延遲修正清掉（新量到的值已包含）
                if !measured.isEmpty {
                    self.monitor.resetDevices(measured)
                    let engine = self.engine
                    self.control.async { engine.clearLatencyCorrections(measured) }
                    self.updateMonitorStatus()
                    // 漂移補償：清掉後立刻依模型重送（control queue 依序：先清、再設）
                    for u in measured { self.driftApplied[u] = nil }
                    self.applyDriftCorrections(Date(), force: true)
                }
            }
        }
    }

    /// 完整刷新時（engine 有輸出、不在校正中）把目前的輸出交給自動校正觀察：新接上／重新接上／app 重開後的藍牙
    private func observeForAutoCalibration(_ rows: [DeviceRow]) {
        let devs = rows.map { r in
            AutoCalDevice(uid: r.uid, name: r.name, isBluetooth: !r.inAggregate, hasLatency: config.measuredLatencyMs(r.uid) != nil,
                          enabled: r.enabled, isReference: r.isVolumeSource || r.kind == .builtIn)
        }
        handleAutoCal(autoCal.observe(devs, now: Date()))
        autoCalTick()
    }

    /// CalibrationRunner 的暫停／恢復（engineStartReturned 裡接一次）
    private func wireCalibration() {
        let runner = CalibrationRunner.shared
        guard !runner.isWired else { return }
        wireCalibrationReload()
        let eng = self.engine
        runner.runtimeCorrections = { eng.latencyCorrections }
        runner.pauseEngine = { [weak self] done in
            MainActor.assumeIsolated {
                guard let self else { done(); return }
                self.calibrating = true
                if let r = self.monitorRound { r.abort("校正暫停引擎") }
                AppLog.line("校正：暫停本 app 的引擎與重接")
                self.reconnector?.stop(); self.reconnector = nil
                let engine = self.engine
                self.control.async {
                    engine.stop()
                    DispatchQueue.main.async { done() }
                }
            }
        }
        runner.resumeEngine = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                self.reloadConfig()
                let engine = self.engine
                AppLog.line("校正結束：重新啟動引擎")
                self.control.async {
                    do { try engine.start() } catch { AppLog.line("✗ 校正後引擎啟動失敗：\(error)（重接元件會退避重試）") }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.calibrating = false
                            if self.running, self.reconnector == nil {
                                let r = Reconnector(engine: engine)
                                r.start()
                                self.reconnector = r
                            }
                            self.lastIO = (engine.ioCycles, Date())
                            self.refresh()
                        }
                    }
                }
            }
        }
    }

    /// 交接模式：engine 已在 `@@tap-released` 時恢復，子行程結束後只重讀設定（新延遲以 applyConfig 套用，不重建 tap）
    private func wireCalibrationReload() {
        CalibrationRunner.shared.reloadAfterCalibration = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                AppLog.line("校正結束：重讀設定（engine 已在交接時恢復）")
                self.reloadConfig()
            }
        }
    }

    func quit() { NSApp.terminate(nil) }

    // MARK: 面板可見性（高頻數值只在面板開著時更新）

    /// PanelView 的 onAppear／onDisappear 呼叫。開啟時立刻完整刷新一次（不等下一個 1 秒 tick）
    func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        AppLog.line("面板\(visible ? "打開" : "關上")")
        if visible { refresh(full: true) } else { meters.reset() }
        autoCalTick()   // 面板打開：因「看不到倒數」延後的自動校正現在可以倒數了（面板關上：倒數中且沒通知權限 → 延後）
    }

    /// 每秒校正一次 panelVisible（MenuBarExtra 的 onAppear／onDisappear 在某些 macOS 版本不是每次開關都會呼叫）：
    /// 有沒有「不是狀態列按鈕」的可見視窗（本 app 是 LSUIElement，唯一的一般視窗就是面板）。只讀 NSApp.windows，不碰 Core Audio
    private func syncPanelVisibilityFromWindows() {
        let shown = NSApp?.windows.first { w in
            w.isVisible && w.occlusionState.contains(.visible) && !String(describing: type(of: w)).contains("StatusBar")
        }
        let visible = shown != nil
        if visible != panelVisible {
            if let w = shown { AppLog.line("面板可見性（依視窗）：\(type(of: w)) frame=\(NSStringFromRect(w.frame))") }
            setPanelVisible(visible)
        }
    }

    /// 通知權限（ctl state 顯示用）
    var canNotify: Bool { notifier.canNotify }

    /// 藍牙斷線重連（BluetoothOutManager.onReconnect；ctl bt simulate-reconnect 走同一條）。
    /// （舊政策：已有延遲紀錄的裝置重新接上 → 沿用舊值出聲，只寫 log；有線裝置仍是這樣）
    /// 【第 B 輪 2026-09-29 Kang 定案】真的斷線重連（非 app 重開）也比照 app 重開：先不出聲（BluetoothOutManager 在重新 start 前
    /// 已經 Engine.holdUntilCalibrated）→ 倒數 3 秒 → `--only` 重校；通知沒授權、面板關著 → needsConsent（面板打開才倒數）。
    /// Config.recalibrateBluetoothOnReconnect = false 時退回「沿用舊值出聲」
    func bluetoothReconnected(_ uid: String) {
        let has = config.measuredLatencyMs(uid) != nil
        let dc = config.device(uid)
        let name = devices.first { $0.uid == uid }?.name ?? Devices.bluetoothOutputs().first { $0.uid == uid }?.name ?? uid
        guard Config.recalibrateBluetoothOnReconnect else {
            AppLog.line("藍牙重新連線：\(uid) \(has ? "沿用舊的延遲值出聲" : "沒量過延遲（維持不出聲，等校正）")")
            return
        }
        AppLog.line("藍牙重新連線：\(name)（\(uid)）\(has && dc.enabled ? "→ 先不出聲、倒數重新校正" : (has ? "（已關閉）" : "沒量過延遲（維持不出聲，等校正）"))")
        // 背景監聽對它的等確認／累計修正作廢（串流重開了，舊的修正不適用）
        monitor.resetDevices([uid])
        driftStreamReset(uid, reason: "藍牙重新連線")
        let engine = self.engine
        control.async { engine.clearLatencyCorrections([uid]) }
        handleAutoCal(autoCal.bluetoothReconnected(uid: uid, name: name, hasLatency: has, enabled: dc.enabled, now: Date()))
        // engine 那邊的暫時 hold（重新 start 前加的）交給 autoCal.holds：先套用含 holds 的設定再拿掉暫時 hold（control queue 依序）
        let ec = engineConfig(config)
        control.async { engine.applyConfig(ec); engine.releaseReconnectHolds([uid]) }
        autoCalTick()
    }

    /// 【2026-09-29 審查】這個 app 行程第一次連上某台藍牙（BluetoothOutManager 已先 hold engine）：
    /// 啟動 30 秒內 = app 重開（primeLaunchHolds 通常已經 hold 了）；之後才第一次連上 = 串流重開，比照重連——先不出聲、倒數重校。
    /// 不管要不要重校，最後都把 engine 的暫時 hold 交給 autoCal.holds（沒量過／關掉的 → 直接放掉，本來就不出聲）
    func bluetoothFirstConnected(_ uid: String) {
        let has = config.measuredLatencyMs(uid) != nil
        let dc = config.device(uid)
        let name = devices.first { $0.uid == uid }?.name ?? Devices.bluetoothOutputs().first { $0.uid == uid }?.name ?? uid
        let acts = autoCal.bluetoothFirstConnected(uid: uid, name: name, hasLatency: has, enabled: dc.enabled, now: Date())
        AppLog.line("藍牙第一次連上（這個 app 行程）：\(name)（\(uid)）"
                    + (autoCal.holds.contains(uid) ? "→ 校正完成前不出聲" : (has ? "→ 沿用舊的延遲值" : "沒量過延遲（維持不出聲，等校正）")))
        if autoCal.holds.contains(uid) {
            monitor.resetDevices([uid])
            let engine = self.engine
            control.async { engine.clearLatencyCorrections([uid]) }
        }
        driftStreamReset(uid, reason: "藍牙串流第一次啟動")
        handleAutoCal(acts)
        let ec = engineConfig(config), engine = self.engine
        control.async { engine.applyConfig(ec); engine.releaseReconnectHolds([uid]) }
        autoCalTick()
    }

    /// 藍牙延遲可能改變（重新連線、取樣率改變重開、HFP 暫停／恢復、engine 換取樣率而重開藍牙串流）：量過延遲的標記需要重新校正
    func markBluetoothNeedsRecalibration(_ uid: String, reason: String) {
        driftStreamReset(uid, reason: reason)
        guard config.measuredLatencyMs(uid) != nil else {
            AppLog.line("藍牙（\(reason)）：\(uid) 本來就沒量過延遲（維持不出聲，等校正）")
            return
        }
        guard config.devices[uid]?.needsRecalibration != true else { return }
        AppLog.line("藍牙（\(reason)）：\(uid) 標記需要重新校正（\(Config.silenceBluetoothAfterReconnect ? "先不出聲" : "沿用舊值出聲")）")
        updateConfig { c in var d = c.device(uid); d.needsRecalibration = true; c.devices[uid] = d }
    }

    // MARK: 背景監聽（第 B 輪；MonitorScheduler.swift）

    static func monitorParams(_ c: Config) -> MonitorScheduler.Params {
        var p = MonitorScheduler.Params()
        p.intervalSeconds = c.effectiveMonitorIntervalSec
        p.captureSeconds = c.effectiveMonitorCaptureSec
        return p
    }

    /// 面板開關（預設開）
    func setMonitorEnabled(_ on: Bool) {
        updateConfig { $0.monitorEnabled = on }
        AppLog.line("背景監聽：\(on ? "開啟" : "關閉")")
        if on { monitor.reschedule(now: Date()) } else if let r = monitorRound { r.abort("使用者關閉背景監聽") }
        updateMonitorStatus()
    }

    #if IU42_DIAG
    /// 【除錯版】下一秒就跑一輪（不等 5 分鐘；條件照樣檢查）。ctl monitor now
    func monitorRunSoon() {
        monitor.params.intervalSeconds = 0
        monitor.reschedule(now: Date())
        monitor.params = Self.monitorParams(config)
        updateMonitorStatus()
    }

    /// 【除錯版・實機驗收 M2】人為製造誤差：讓這台晚到 ms（= 延遲修正 −ms，同一條斜率 ≤ 0.1 ms/秒）。背景監聽應該量到 +ms 並修回 0。
    /// 背景監聽的累計／等確認歸零（這不是它做的修正）。回傳實際 uid
    func monitorInjectError(_ query: String, ms: Double) -> String? {
        guard let d = devices.first(where: { $0.uid == query }) ?? devices.first(where: { $0.name.lowercased().contains(query.lowercased()) }) else { return nil }
        AppLog.line(String(format: "【測試】背景監聽驗收：人為讓「%@」晚到 %+.2f ms（延遲修正 %+.2f ms）", d.name, ms, -ms))
        monitor.resetDevices([d.uid])
        let engine = self.engine, uid = d.uid
        control.async { _ = engine.adjustLatencyCorrection(uid: uid, byMs: -ms) }
        updateMonitorStatus()
        return uid
    }

    /// 【除錯版・實機驗收】手動寫入 measuredLatencyMs 並當作這台剛校正完成（解除暫停出聲、清修正、監聽狀態歸零）。
    /// 只給「一直有節目音、脈衝校正 SNR 不夠」時暫代；log 會標「手動」
    func debugSetMeasuredLatency(_ uid: String, ms: Double) -> Bool {
        guard devices.contains(where: { $0.uid == uid }) || Devices.bluetoothOutputs().contains(where: { $0.uid == uid }) else { return false }
        AppLog.line(String(format: "【測試】手動寫入「%@」延遲 %.3f ms（不是量測寫入），當作已校正", uid, ms))
        updateConfig { c in var d = c.device(uid); d.measuredLatencyMs = ms; d.needsRecalibration = false; c.devices[uid] = d }
        monitor.resetDevices([uid])
        let engine = self.engine
        control.async { engine.clearLatencyCorrections([uid]) }
        handleAutoCal(autoCal.finished(measured: [uid], cancelled: false, message: "", now: Date()))
        updateMonitorStatus()
        return true
    }

    /// 【除錯版】清掉全部延遲修正（測試後還原）
    func monitorClearCorrections() {
        AppLog.line("【測試】清除全部延遲修正與背景監聽累計")
        monitor.resetDevices(Set(devices.map(\.uid)))
        let engine = self.engine
        control.async { engine.clearLatencyCorrections() }
        updateMonitorStatus()
    }

    /// 【除錯版】改監聽間隔（存進 config；測完要改回 300）
    func monitorSetInterval(_ sec: Double) {
        updateConfig { $0.monitorIntervalSec = sec }
        monitor.params = Self.monitorParams(config)
        monitor.reschedule(now: Date())
        AppLog.line("背景監聽：間隔改為 \(Int(config.effectiveMonitorIntervalSec)) 秒")
        updateMonitorStatus()
    }
    #endif

    /// 背景監聽開麥克風前，節目音要連續在播多久（每秒峰值 ≥ −60 dBFS 不中斷）；擋掉通知音、截圖快門這類短促聲音
    static let monitorMinPlayingSeconds: TimeInterval = 20

    /// 節目音夠不夠大：連續在播 ≥ 20 秒，最近 3 秒 tap 輸入峰值 ≥ −30 dBFS，而且乘上音量倍率 ≥ −50 dBFS（音量很小時麥克風聽不清楚）
    private func programLoudEnough(now: Date) -> Bool {
        guard let since = programPlayingSince, now.timeIntervalSince(since) >= Self.monitorMinPlayingSeconds else { return false }
        let recent = peakLog.filter { now.timeIntervalSince($0.at) <= 3 }.map(\.input)
        guard let pk = recent.max() else { return false }
        return pk >= 0.0316 && pk * lastVolumeGain >= 0.00316
    }

    private func updateMonitorStatus() {
        let st = monitor.status(enabled: config.monitorEnabled, listening: monitorRound?.listening ?? false)
        if st != monitorStatus { monitorStatus = st }
    }

    /// 每秒：中止條件（校正開始、engine 停了、功能關掉）＋到期時量環境並交給排程
    private func monitorTick() {
        if monitor.params.intervalSeconds != config.effectiveMonitorIntervalSec || monitor.params.captureSeconds != config.effectiveMonitorCaptureSec {
            monitor.params = Self.monitorParams(config)
        }
        defer { updateMonitorStatus() }
        let calibratingNow = calibrating || CalibrationRunner.shared.isRunning || autoCal.phase != .idle
        if let r = monitorRound {
            if calibratingNow || !running || !config.monitorEnabled { r.abort(calibratingNow ? "校正中" : "背景監聽停止") }
            return
        }
        guard running, !engineStarting, config.monitorEnabled, Date() >= monitor.nextDue, !monitorEnvPending else { return }
        // 到期：環境要讀 Core Audio（麥克風占用）與 engine（斜坡中？）→ 在 control queue 量，回主執行緒交給排程
        var env = MonitorEnvironment()
        env.enabled = config.monitorEnabled
        env.engineRunning = running && ioAdvancing && !engineStarting && !otherInstance && reconnector != nil
        env.musicMode = playMode == .music
        env.calibrating = calibratingNow
        env.programLoud = programLoudEnough(now: Date())
        env.targets = devices.map { d in
            MonitorTarget(uid: d.uid, name: d.name, isBluetooth: !d.inAggregate, active: d.plan?.active == true,
                          isReference: d.isVolumeSource || d.kind == .builtIn,
                          driftManaged: !d.inAggregate && config.bluetoothDriftCompensation && driftModels[d.uid]?.points.isEmpty == false)
        }
        let micUID = config.calibrationMicUID
        let engine = self.engine
        monitorEnvPending = true
        control.async {
            let mic = resolveCalibrationMic(uid: micUID)
            env.micAvailable = mic != nil
            env.micBusy = mic.map { MonitorMicCapture.isRunningSomewhere($0.id) } ?? false
            env.slewing = engine.isSlewing
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.monitorEnvPending = false
                    self.handleMonitor(self.monitor.tick(now: Date(), env: env), mic: mic)
                }
            }
        }
    }

    private func handleMonitor(_ acts: [MonitorAction], mic: AudioDevice?) {
        for a in acts {
            switch a {
            case .log(let m):
                AppLog.line(m)
            case .skipped(let r):
                AppLog.line("背景監聽：到期但先跳過（\(r.text)），條件恢復就開始")
            case .start(let plan):
                guard let mic, monitorRound == nil else {
                    handleMonitor(monitor.roundSkipped(plan, reason: .noMic, message: "", now: Date()), mic: nil); continue
                }
                startMonitorRound(plan, mic: mic)
            case .correct(let uid, let name, let delta, let total):
                if config.bluetoothDriftCompensation, driftModels[uid]?.points.isEmpty == false {
                    // 這台藍牙由漂移模型管：不另外疊修正，改把這兩輪的平均當「背景監聽確認」點餵給模型
                    //（模型判矛盾後只認精確點；以前這裡只記 log，跳動要等下次校正才修得到）
                    let obs = (recentMonitorObs[uid] ?? []).filter { Date().timeIntervalSince($0.at) < 600 }.suffix(2)
                    guard !obs.isEmpty else { continue }
                    let mean = obs.map(\.ms).reduce(0, +) / Double(obs.count)
                    AppLog.line(String(format: "背景監聽：「%@」連續 2 次一致 %+.2f ms → 兩輪平均 %.3f ms 當漂移模型的新基準點", name, delta, mean))
                    recentMonitorObs[uid] = nil
                    addDriftObservation(uid: uid, latencyMs: mean, source: .monitorConfirmed)
                    continue
                }
                AppLog.line(String(format: "背景監聽：修正「%@」%+.2f ms（累計 %+.2f ms，斜率 ≤ %.1f ms/秒）", name, delta, total, Engine.correctionSlewMsPerSecond))
                let engine = self.engine
                control.async { engine.adjustLatencyCorrection(uid: uid, byMs: delta) }
            case .flagCalibration(let uid, let name, let reason):
                AppLog.line("背景監聽：「\(name)」需要重新校正（\(reason)）")
                handleAutoCal(autoCal.flagNeedsCalibration(uid: uid, name: name, reason: reason))
            }
        }
        updateMonitorStatus()
    }

    private func startMonitorRound(_ plan: MonitorRoundPlan, mic: AudioDevice) {
        let engine = self.engine, cfg = config, bt = bluetooth
        let steps = plan.slots.map { String(format: "%@ +%.1f ms", $0.target.name, $0.offsetMs) }.joined(separator: " → ")
        AppLog.line("背景監聽第 \(plan.round) 輪\(plan.confirm ? "（確認）" : "")：用「\(mic.name)」聽 \(Int(plan.captureSeconds)) 秒，探測 \(steps)")
        // 給演算法的裝置資訊（plan 延遲、目前修正）在 control queue 取
        control.async {
            let p = engine.plan
            let corr = engine.latencyCorrections
            let offs = engine.delayOffsets()
            let devs: [DriftDevice] = engine.outputDetails.map { o in
                DriftDevice(uid: o.uid, name: o.name, isBluetooth: false, isReference: o.isVolumeSource || o.kind == .builtIn,
                            planDelayMs: p[o.uid]?.delayMs ?? 0, correctionMs: corr[o.uid] ?? 0, measuredLatencyMs: cfg.measuredLatencyMs(o.uid),
                            appliedExtraDelayMs: offs[o.uid]?.correctionMs ?? 0)
            } + engine.externalOutputs.map { e in
                DriftDevice(uid: e.uid, name: e.name, isBluetooth: true, isReference: false,
                            planDelayMs: p[e.uid]?.delayMs ?? 0, correctionMs: corr[e.uid] ?? 0, measuredLatencyMs: cfg.measuredLatencyMs(e.uid),
                            pathDelayMs: bt.outputs[e.uid]?.safetyMs ?? 0, appliedExtraDelayMs: offs[e.uid]?.correctionMs ?? 0)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.running, self.config.monitorEnabled, self.monitorRound == nil else {
                        self.handleMonitor(self.monitor.roundSkipped(plan, reason: .aborted, message: "開始前條件改變", now: Date()), mic: nil)
                        return
                    }
                    self.monitorRoundCorrections = corr
                    let round = MonitorRound(plan: plan, engine: engine, mic: mic, devices: devs.filter { p[$0.uid]?.active == true },
                                             estimator: makeDriftEstimator())
                    round.onFinish = { outcome in   // AppState.shared 永遠存在（和其他 control.async 回呼一樣直接用 self）
                        MainActor.assumeIsolated {
                            self.monitorRound = nil
                            switch outcome {
                            case .completed(let est):
                                self.driftObserveMonitor(est, plan: plan)
                                self.handleMonitor(self.monitor.roundFinished(plan, estimate: est, now: Date()), mic: nil)
                            case .skipped(let r, let m):
                                self.handleMonitor(self.monitor.roundSkipped(plan, reason: r, message: m, now: Date()), mic: nil)
                            }
                        }
                    }
                    self.monitorRound = round
                    round.start()
                    self.updateMonitorStatus()
                }
            }
        }
    }

    // MARK: 藍牙漂移補償（第 C 輪；BluetoothDrift.swift）

    /// 面板開關：漂移預測補償＋短校正排程
    func setDriftCompensationEnabled(_ on: Bool) {
        updateConfig { $0.bluetoothDriftCompensation = on }
        AppLog.line("藍牙漂移補償：\(on ? "開啟" : "關閉")")
        if !on {
            // 關掉：漂移模型送的修正清掉（走斜率回去）；模型與量測點保留（再打開時直接用）
            let uids = Set(driftApplied.keys)
            driftApplied = [:]
            let engine = self.engine
            if !uids.isEmpty { control.async { engine.clearLatencyCorrections(uids) } }
        } else {
            applyDriftCorrections(Date(), force: true)
        }
        updateDriftStatus(Date())
    }

    /// 面板開關：藍牙連上後 macOS 搶預設輸出 → 自動切回
    func setOutputRestoreEnabled(_ on: Bool) {
        updateConfig { $0.restoreDefaultOutputOnBluetoothConnect = on }
        outputGuard.autoRestoreEnabled.value = on
        AppLog.line("藍牙連上後預設輸出自動切回：\(on ? "開啟" : "關閉")")
    }

    /// ctl drift verify-feed on|off（驗收用、執行期）
    func setDriftFeedsVerify(_ on: Bool) {
        driftFeedsVerify = on
        AppLog.line("漂移補償：--verify-program 的結果\(on ? "會" : "不會")當成量測點（ctl drift verify-feed，執行期）")
    }

    /// 參考喇叭（校正的主時鐘＝內建）
    private var driftReferenceUID: String {
        devices.first { $0.kind == .builtIn }?.uid ?? devices.first { $0.isVolumeSource }?.uid ?? "BuiltInSpeakerDevice"
    }

    private func isBluetoothUID(_ uid: String) -> Bool {
        if let d = devices.first(where: { $0.uid == uid }) { return !d.inAggregate }
        return lastBluetoothList.contains { $0.uid == uid }
    }

    func driftDeviceName(_ uid: String) -> String { deviceName(uid) }

    private func deviceName(_ uid: String) -> String {
        devices.first { $0.uid == uid }?.name ?? lastBluetoothList.first { $0.uid == uid }?.name ?? uid
    }

    /// 串流重開（重連、第一次啟動、取樣率改變重開、HFP…）：這台的漂移模型歸零
    private func driftStreamReset(_ uid: String, reason: String) {
        if let m = driftModels[uid], !m.points.isEmpty {
            AppLog.line("漂移補償：「\(deviceName(uid))」\(reason) → 串流重開，漂移模型歸零（原有 \(m.points.count) 個量測點）")
        }
        driftModels[uid] = nil
        shortCal.reset(uid: uid)
        // 【第 C 輪審查】舊串流的漂移修正不能帶到新串流（串流識別改變／取樣率改變重開這兩條路以前不清，模型刪了之後也沒人再碰它）
        //  （一律送：clearLatencyCorrections 沒有這台的修正時什麼都不做；不在主執行緒讀 engine 狀態）
        driftApplied[uid] = nil
        monitor.resetDevices([uid])
        let engine = self.engine
        control.async { engine.clearLatencyCorrections([uid]) }
        driftLastLog[uid] = nil
        lastStreamKeys[uid] = nil
    }

    /// 一個量測點（校正、驗證、背景監聽）
    private func addDriftObservation(uid: String, latencyMs: Double, source: DriftSource, at: Date = Date()) {
        guard isBluetoothUID(uid), latencyMs.isFinite else { return }
        let name = deviceName(uid)
        let m: BluetoothDriftModel
        if let e = driftModels[uid] { m = e } else {
            m = BluetoothDriftModel(uid: uid)
            m.reset(streamKey: lastStreamKeys[uid], at: at)
            driftModels[uid] = m
        }
        let before = m.predict(at: at)
        if let b = before, source != .monitor { recordDriftResidual(uid: uid, ms: latencyMs - b.ms, kind: "\(source.label)點 − 加入前的預測") }
        let r = m.add(DriftPoint(at: at, latencyMs: latencyMs, source: source))
        let pr = m.predict(at: at)
        var line = String(format: "漂移補償：「%@」%@量測點 %.3f ms", name, source.label, latencyMs)
        if let b = before { line += String(format: "（加入前預測 %.3f ms，差 %+.3f）", b.ms, latencyMs - b.ms) }
        line += String(format: "；%d 點", m.points.count)
        if let rate = pr?.rateMsPerMin { line += String(format: "、速度 %+.3f ms／分鐘", rate) }
        switch r {
        case .accepted: break
        case .missed(let d): line += String(format: "；⚠ 預測失準 %+.2f ms（> %.0f ms，第 %d 次連續）→ 速度重估（只留上一個量測點起的點）", d, m.params.missMs, m.consecutiveMisses)
        case .erratic(let why): line += "；⚠ \(why) → 不外推、需要重新校正"
        case .restarted(let why): line += "；以這個\(source.label)點重新開始（\(why)）"
        case .contradiction(let why): line += "；⚠ 矛盾（\(why)）→ 不外推、需要重新校正"
        case .rateOutOfRange(let v): line += String(format: "；⚠ 速度 %+.2f ms／分鐘超出合理範圍 → 不外推、需要重新校正", v)
        }
        AppLog.line(line)
        switch r {
        case .contradiction(let why):
            handleAutoCal(autoCal.flagNeedsCalibration(uid: uid, name: name, reason: "藍牙漂移補償：量測彼此矛盾（\(why)）"))
        case .rateOutOfRange(let v):
            handleAutoCal(autoCal.flagNeedsCalibration(uid: uid, name: name, reason: String(format: "藍牙漂移補償：漂移速度 %+.2f ms／分鐘超出合理範圍", v)))
        case .erratic(let why):
            handleAutoCal(autoCal.flagNeedsCalibration(uid: uid, name: name, reason: "藍牙漂移補償：漂移不規則（\(why)）"))
        default: break
        }
        if source != .monitor { handleShortCal(shortCal.attemptFinished(uid: uid, name: name, measured: true, now: at)) }
        driftApplied[uid] = nil
        applyDriftCorrections(at, force: true)
        updateDriftStatus(at)
    }

    /// 校正／驗證子行程結束：`@@latency-obs` → 量測點；漂移補償的短校正沒量到 → 告訴排程
    private func driftHandleCalibrationOutput(_ lines: [String], measured: Set<String>, cancelled: Bool) {
        for o in parseLatencyObservations(lines) {
            if o.source == .verify && !driftFeedsVerify {
                AppLog.line(String(format: "漂移補償：驗證量到「%@」%.3f ms（ctl drift verify-feed off：不當成量測點）", deviceName(o.uid), o.latencyMs))
                continue
            }
            addDriftObservation(uid: o.uid, latencyMs: o.latencyMs, source: o.source)
        }
        for (uid, r) in parseBluetoothResiduals(lines) {
            recordDriftResidual(uid: uid, ms: r, kind: "只量藍牙的驗證：實測 − app 當時用的")
            AppLog.line(String(format: "漂移補償：只量藍牙的驗證「%@」殘差 %+.3f ms（app 當時的修正 %+.3f ms）", deviceName(uid), r, driftApplied[uid] ?? engineCorrectionGuess(uid)))
        }
        if !driftRunUIDs.isEmpty {
            for u in driftRunUIDs where !measured.contains(u) && !cancelled {
                handleShortCal(shortCal.attemptFinished(uid: u, name: deviceName(u), measured: false, now: Date()))
            }
            driftRunUIDs = []
        }
    }

    private func recordDriftResidual(uid: String, ms: Double, kind: String) {
        driftResiduals.append((Date(), uid, ms, kind))
        if driftResiduals.count > 20 { driftResiduals.removeFirst(driftResiduals.count - 20) }
    }

    private func engineCorrectionGuess(_ uid: String) -> Double { monitorRoundCorrections[uid] ?? 0 }

    /// 背景監聽一輪完成：可採信的藍牙結果 → 量測點（L = 校正值 + 當時修正 + 誤差 − 參考）
    private func driftObserveMonitor(_ est: DriftEstimate, plan: MonitorRoundPlan) {
        guard est.usable else { return }
        let ref = driftReferenceUID
        let mRef = config.measuredLatencyMs(ref) ?? 0
        for d in est.devices {
            guard let e = d.errorMs, e.isFinite, d.confidence >= monitor.params.minConfidence, isBluetoothUID(d.uid),
                  let m = config.measuredLatencyMs(d.uid), !autoCal.holds.contains(d.uid) else { continue }
            let l = m + (monitorRoundCorrections[d.uid] ?? 0) + e - (mRef + (monitorRoundCorrections[ref] ?? 0))
            addDriftObservation(uid: d.uid, latencyMs: l, source: .monitor)
            recentMonitorObs[d.uid, default: []].append((Date(), l))
            recentMonitorObs[d.uid] = Array(recentMonitorObs[d.uid]!.suffix(2))
        }
    }

    /// 每秒（start() 的 timer）：串流識別（每 5 秒）、修正（每 10 秒）、短校正排程、面板狀態
    private func driftTick() {
        guard running, !engineStarting, !otherInstance else { return }
        let now = Date()
        if now.timeIntervalSince(lastStreamKeyPoll) >= 5, !streamKeyPollPending {
            lastStreamKeyPoll = now
            streamKeyPollPending = true
            let bt = bluetooth
            control.async {
                let keys = bt.streamKeys
                DispatchQueue.main.async { MainActor.assumeIsolated { self.streamKeyPollPending = false; self.streamKeysPolled(keys) } }
            }
        }
        if now.timeIntervalSince(lastDriftApply) >= 10 { applyDriftCorrections(now) }
        shortCalTick(now)
        updateDriftStatus(now)
    }

    private func streamKeysPolled(_ keys: [String: String]) {
        for (uid, key) in keys {
            if let m = driftModels[uid] {
                if m.streamKey == nil { m.adopt(streamKey: key) }
                else if m.streamKey != key { driftStreamReset(uid, reason: "串流識別改變") }
            }
            lastStreamKeys[uid] = key
        }
    }

    /// 修正 = 預測的相對延遲 − (校正值 − 參考校正值)，交給 Engine（≤ 0.1 ms/秒 斜率）。暫停出聲等校正、背景監聽一輪進行中、校正中不動
    private func applyDriftCorrections(_ now: Date, force: Bool = false) {
        lastDriftApply = now
        guard config.bluetoothDriftCompensation, running, !calibrating, monitorRound == nil else { return }
        let mRef = config.measuredLatencyMs(driftReferenceUID) ?? 0
        var send: [String: Double] = [:]
        for (uid, m) in driftModels {
            guard let mBT = config.measuredLatencyMs(uid), let pr = m.predict(at: now), !autoCal.holds.contains(uid) else { continue }
            let c = min(max(pr.ms - (mBT - mRef), -Engine.maxCorrectionMs), Engine.maxCorrectionMs)
            if !force, let prev = driftApplied[uid], abs(prev - c) < 0.02 { continue }
            send[uid] = c
            driftApplied[uid] = c
            let last = driftLastLog[uid]
            if force || last == nil || abs(last!.ms - c) >= 0.5 || now.timeIntervalSince(last!.at) >= 300 {
                driftLastLog[uid] = (now, c)
                AppLog.line(String(format: "漂移補償：「%@」延遲修正 %+.2f ms（預測 %.2f ± %.2f ms%@、%d 點；斜率 ≤ %.1f ms/秒）", deviceName(uid), c, pr.ms, pr.sigmaMs,
                                   (pr.rateMsPerMin.map { String(format: "、速度 %+.3f ms／分鐘", $0) } ?? (m.health.extrapolates ? "、還沒估速度" : "、不外推"))
                                    + (pr.held ? String(format: "、預估誤差 2σ > %.0f ms：停止外推，等量測", m.params.holdAtTwoSigmaMs) : ""),
                                   m.points.count, Engine.correctionSlewMsPerSecond))
            }
        }
        guard !send.isEmpty else { return }
        let engine = self.engine
        control.async { for (u, c) in send { engine.setLatencyCorrection(uid: u, ms: c, quiet: true) } }
    }

    /// 節目音（tap 輸入）連續靜止了幾秒（每秒峰值都 < −60 dBFS）
    private func programSilentSeconds(_ now: Date) -> TimeInterval {
        programSilentSince.map { now.timeIntervalSince($0) } ?? 0
    }

    private func shortCalTick(_ now: Date) {
        var env = ShortCalEnvironment()
        env.enabled = config.bluetoothDriftCompensation
        let runner = CalibrationRunner.shared
        env.canStart = running && ioAdvancing && !engineStarting && !otherInstance && reconnector != nil && runner.isWired && !runner.isRunning
            && !calibrating && autoCal.phase == .idle && monitorRound == nil
        env.programSilentSeconds = programSilentSeconds(now)
        env.secondsSinceLastGap = lastProgramGapAt.map { now.timeIntervalSince($0) } ?? .infinity
        env.playedBeforeSilence = playedBeforeSilence
        env.volumeGain = lastVolumeGain
        env.countdownBlocked = Set(autoCal.deferred.keys)
        env.targets = devices.filter { !$0.inAggregate }.map {
            ShortCalTarget(uid: $0.uid, name: $0.name, active: $0.enabled && $0.plan?.active == true && !autoCal.holds.contains($0.uid))
        }
        handleShortCal(shortCal.tick(now: now, env: env, models: driftModels))
    }

    private func handleShortCal(_ acts: [ShortCalAction]) {
        for a in acts {
            switch a {
            case .log(let m):
                AppLog.line(m)
            case .start(let uid, let name, let gap, let reason):
                AppLog.line("漂移補償：「\(name)」該量下一點（\(reason)）→ \(gap ? "空檔直接短校正" : "倒數 3 秒短校正")")
                handleAutoCal(autoCal.requestDriftCalibration(uid: uid, name: name, countdown: !gap, now: Date()))
                autoCalTick()
            case .flag(let uid, let name, let reason):
                AppLog.line("漂移補償：「\(name)」需要重新校正（\(reason)）")
                handleAutoCal(autoCal.flagNeedsCalibration(uid: uid, name: name, reason: reason))
            }
        }
    }

    private func updateDriftStatus(_ now: Date) {
        var rows: [DriftStatusRow] = []
        for d in devices where !d.inAggregate {
            guard let m = driftModels[d.uid] else { continue }
            let pr = m.predict(at: now)
            let due = shortCal.dueAt(m)
            var waiting: String?
            if let due, now >= due.at {
                if case .countdown = autoCal.phase, autoCal.batch.contains(where: { $0.uid == d.uid }) { waiting = "倒數中" }
                else if autoCal.phase == .running, autoCal.batch.contains(where: { $0.uid == d.uid }) { waiting = "短校正中" }
                else if shortCal.stopped(d.uid) { waiting = "連續 \(shortCal.params.maxFailures) 次沒量到：停止自動短校正，請按「需要校正」" }
                else if lastVolumeGain < shortCal.params.minVolumeGain { waiting = "系統靜音／音量很小：不放測試音" }
                else if autoCal.deferred[d.uid]?.reason == .needsConsent { waiting = "等你打開面板（通知沒開）或按「需要校正」；空檔時照樣短校正" }
                else if autoCal.deferred[d.uid] != nil { waiting = "面板有「需要校正」：空檔時照樣短校正（不倒數）" }
                else if programSilentSeconds(now) > shortCal.params.maxGapSilence { waiting = "節目音靜止超過 10 分鐘（不聽了）：等音樂再開始" }
                else if let since = shortCal.dueSince[d.uid] {
                    let playing = min(now.timeIntervalSince(since), lastProgramGapAt.map { now.timeIntervalSince($0) } ?? .infinity)
                    let left = max(0, shortCal.params.maxWaitForGap - playing)
                    waiting = String(format: "等節目音空檔（%.0f 分鐘後沒有空檔就倒數）", (left / 60).rounded(.up))
                }
            }
            rows.append(DriftStatusRow(uid: d.uid, name: d.name, points: m.points.count, rateMsPerMin: pr?.rateMsPerMin.map { ($0 * 1000).rounded() / 1000 },
                                       correctionMs: driftApplied[d.uid].map { ($0 * 100).rounded() / 100 },
                                       sigmaMs: pr.map { ($0.sigmaMs * 100).rounded() / 100 }, health: m.health.text, healthy: m.health.extrapolates,
                                       nextDue: due?.at, nextReason: due?.reason, waiting: waiting, held: pr?.held ?? false,
                                       lastMiss: m.lastMiss.map { String(format: "%@ %@預測失準 %+.1f ms（> %.0f ms）", PanelText.time($0.at), $0.source.label, $0.residualMs, m.params.missMs) },
                                       misses: m.missCount))
        }
        if rows != driftStatus { driftStatus = rows }
    }

    // MARK: 內部

    /// 改設定：存檔並套用到 engine（plan 會重算，不重建聚合裝置）
    func updateConfig(_ mutate: (inout Config) -> Void) {
        var c = config
        mutate(&c)
        guard c != config else { return }
        config = c
        do { try c.save() } catch { AppLog.line("✗ 寫設定檔失敗：\(error)") }
        let engine = self.engine, ec = engineConfig(c)
        control.async { engine.applyConfig(ec) }
        refresh()
    }

    /// 外部改了 config.json（例如 CLI calibrate）後重新讀入
    /// 面板「重設設定」（設定檔唯讀保護中才出現）：寫入預設值（明確操作）→ 解除保護 → 重新載入。壞檔（config.json.corrupt-*）保留不動
    func resetConfigToDefaults() {
        do {
            try Config.resetToDefaults()
            AppLog.line("面板：設定檔已重設為預設值（唯讀保護解除）")
        } catch {
            AppLog.line("✗ 重設設定失敗：\(error)")
        }
        configProtection = Config.writeProtection()
        reloadConfig()
    }

    func reloadConfig() {
        let c = Config.load()
        if c != config { config = c }
        let engine = self.engine, ec = engineConfig(c)
        control.async { engine.applyConfig(ec) }
        modeManager.update(config: c)
        refresh()
    }

    private func applyResolvedMode(_ m: PlayMode, reason: String?) {
        if modeReason != reason { modeReason = reason }
        // 手動鎖定時 ModeManager 不該再送事件；這裡再擋一次
        if config.manualLock, let fixed = config.mode.fixed, m != fixed { return }
        let engine = self.engine
        control.async { engine.setMode(m) }
        refresh()
    }

    /// 從 engine 取快照（在 control queue 上，不在主執行緒：engine 重建時可能卡住等授權）
    private struct Snapshot {
        let status: EngineStatus
        let plan: [String: PlanEntry]
        let details: [EngineOutput]
        let bluetooth: [AudioDevice]
        let guardWarning: OutputWarning?
        var bluetoothErrors: [String: String] = [:]
        var bluetoothStats: [String: BluetoothOutput.Stats] = [:]
        var full = true
    }
    private var refreshInFlight = false

    /// 上一次刷新還在跑時又要求完整刷新：等它回來後補一次
    private var pendingFull = false

    /// 非同步刷新：engine 快照在 control queue 取，回主執行緒更新 @Published（值有變才賦值）。上一次還沒回來就略過。
    /// full = true（預設；事件觸發、使用者動作）：重新列舉藍牙輸出、重算預設輸出警告；false（面板關著時的每秒 tick）：沿用上次的結果
    func refresh(full: Bool = true) {
        if engineStarting {
            statusLine = "引擎啟動中…"
            if panelVisible { meters.update(statusLine: statusLine) }
            let w = [AppWarning(kind: .permission, message: "引擎啟動中；第一次執行請在「系統音訊錄製」授權對話框按允許", actionTitle: nil)]
            if w != warnings { warnings = w }
            return
        }
        guard !refreshInFlight else { if full { pendingFull = true }; return }
        refreshInFlight = true
        let engine = self.engine, bt = bluetooth
        let full = full || pendingFull || lastFullRefresh == .distantPast
        pendingFull = false
        if full { lastFullRefresh = Date() }
        let prevBT = lastBluetoothList, prevGuard = lastGuardWarning
        control.async {
            let snap = Snapshot(status: engine.status(resetPeaks: true), plan: engine.plan, details: engine.outputDetails,
                                bluetooth: full ? Devices.bluetoothOutputs() : prevBT,
                                guardWarning: full ? DefaultOutputGuard.evaluate(engine: engine) : prevGuard,
                                bluetoothErrors: bt.errors, bluetoothStats: bt.outputs.mapValues { $0.stats }, full: full)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.refreshInFlight = false
                    self.apply(snap)
                    if self.pendingFull { self.refresh(full: true) }
                }
            }
        }
    }

    /// 【2026-10-04】藍牙連線健康警告（每秒刷新時呼叫）：
    ///   · 連線降速（BTRenderer 判定、已自動靜音）：macOS 實際送資料的速度偏離名目 > 1%（GLASS5+ 重連後只跑 91%）
    ///   · 連線不穩：最近 30 秒誤差過大重對時 ≥ 3 次（每次都會淡出淡入一下，聽起來斷斷續續）
    /// 文字不放會跳動的計數（警告 id 含文字，每秒變會讓面板一直重排）；細節在 log 與 ctl bt status
    private func bluetoothHealthWarnings(_ stats: [String: BluetoothOutput.Stats], now: Date) -> [AppWarning] {
        var w: [AppWarning] = []
        for uid in btResyncSamples.keys where stats[uid] == nil { btResyncSamples[uid] = nil; btHealthState[uid] = nil }
        for (uid, st) in stats.sorted(by: { $0.key < $1.key }) {
            let name = devices.first { $0.uid == uid }?.name ?? uid
            var hist = btResyncSamples[uid, default: []]
            if let last = hist.last, st.bigErrResyncs < last.big { hist.removeAll() }   // 重開 IOProc：計數歸零
            hist.append((now, st.bigErrResyncs))
            hist.removeAll { now.timeIntervalSince($0.at) > Self.btUnstableWindow }
            btResyncSamples[uid] = hist
            let recent = (hist.last?.big ?? 0) - (hist.first?.big ?? 0)
            let state: String
            if st.rateFault {
                let pct = st.linkSpeed.map { String(format: "%.0f%%", $0 * 100) } ?? "不到正常"
                state = "降速 \(pct)"
                w.append(AppWarning(kind: .bluetooth,
                                    message: "藍牙「\(name)」連線降速：macOS 只用 \(pct) 的速度送資料給它，已先把這台靜音免得斷斷續續。把喇叭關機再開（重新連線）通常就會恢復",
                                    actionTitle: nil))
            } else if recent >= Self.btUnstableResyncs {
                state = "不穩"
                w.append(AppWarning(kind: .bluetooth,
                                    message: "藍牙「\(name)」連線不穩：一直重新對時，聽起來會斷斷續續。試著把喇叭移近 Mac、或關機再開",
                                    actionTitle: nil))
            } else {
                state = "正常"
            }
            let prev = btHealthState[uid] ?? "正常"
            if state != prev {
                AppLog.line("藍牙「\(name)」連線狀態：\(prev) → \(state)（最近 \(Int(Self.btUnstableWindow)) 秒誤差過大重對時 \(recent) 次；\(st.description)）")
            }
            btHealthState[uid] = state
        }
        return w
    }

    /// 同步刷新（離屏截圖用；engine 沒在跑，不會卡）
    func refreshNow() {
        apply(Snapshot(status: engine.status(resetPeaks: false), plan: engine.plan, details: engine.outputDetails,
                       bluetooth: Devices.bluetoothOutputs(), guardWarning: nil))
    }

    private func apply(_ snap: Snapshot) {
        let st = snap.status
        if snap.full {
            lastBluetoothList = snap.bluetooth
            lastGuardWarning = snap.guardWarning
        }
        if playMode != st.mode { playMode = st.mode }
        if st.running { lastVolumeGain = st.muted ? 0 : st.volumeGain }
        let now = Date()
        if st.ioCycles != lastIO.cycles { lastIO = (st.ioCycles, now) }
        if running && st.running {
            peakLog.append((now, st.inputPeak, st.outputs.map { ($0.name, $0.peak) }))
            if peakLog.count > 120 { peakLog.removeFirst(peakLog.count - 120) }
            // 漂移補償的短校正排程：節目音靜止多久、上一次可用空檔（每秒峰值 < −60 dBFS）
            if st.inputPeak < 0.001 {
                if programSilentSince == nil {
                    programSilentSince = now
                    playedBeforeSilence = programPlayingSince.map { now.timeIntervalSince($0) } ?? 0
                    programPlayingSince = nil
                }
                if now.timeIntervalSince(programSilentSince!) >= shortCal.params.silenceSeconds { lastProgramGapAt = now }
            } else {
                programSilentSince = nil
                if programPlayingSince == nil { programPlayingSince = now }
            }
        }
        let adv = running && st.running && now.timeIntervalSince(lastIO.at) < 2
        if adv != ioAdvancing { ioAdvancing = adv }
        let idle = !adv && running && st.running && !SystemSoundsRouter.otherProgramPlaying()
        if idle != engineIdle { engineIdle = idle }
        statusLine = st.line
        if panelVisible {
            var pk: [String: Float] = [:]
            for o in st.outputs { pk[o.uid] = o.peak }
            meters.update(statusLine: st.line, inputPeak: st.inputPeak, outputPeaks: pk)
        }

        // 裝置列：聚合裝置輸出（engine 順序）＋藍牙輸出
        let plan = snap.plan
        var rows: [DeviceRow] = []
        let details = snap.details
        for o in details {
            let dc = config.device(o.uid)
            rows.append(DeviceRow(uid: o.uid, name: o.name, kind: o.kind, inAggregate: true, isVolumeSource: o.isVolumeSource,
                                  enabled: dc.enabled, trimDb: dc.trimDb, measuredLatencyMs: config.measuredLatencyMs(o.uid),
                                  plan: plan[o.uid]))
        }
        if details.isEmpty {
            // engine 沒在跑（啟動失敗、另一個實例在跑、離屏截圖）：照目前裝置與設定列出，計畫用 plan() 現算
            let phys = Devices.physicalOutputs()
            let src = Devices.defaultOutput().flatMap { d in phys.first { $0.uid == d.uid && Devices.hasVolumeDecibels($0.id) } }
                ?? phys.first { $0.kind == .builtIn } ?? phys.first
            let cands = phys + snap.bluetooth
            let ec = engineConfig(config)
            let p = In_Unison42.plan(devices: cands.map { PlanDevice(uid: $0.uid, name: $0.name, isBuiltIn: $0.kind == .builtIn, requiresMeasurement: $0.kind.isBluetooth, config: ec) },
                                     mode: st.mode, caps: config.modeCaps)
            for d in cands {
                let dc = config.device(d.uid)
                rows.append(DeviceRow(uid: d.uid, name: d.name, kind: d.kind, inAggregate: !d.kind.isBluetooth,
                                      isVolumeSource: d.uid == src?.uid, enabled: dc.enabled, trimDb: dc.trimDb,
                                      measuredLatencyMs: config.measuredLatencyMs(d.uid), plan: p[d.uid]))
            }
        }
        for d in snap.bluetooth where !rows.contains(where: { $0.uid == d.uid }) {
            let dc = config.device(d.uid)
            rows.append(DeviceRow(uid: d.uid, name: d.name, kind: d.kind, inAggregate: false, isVolumeSource: false,
                                  enabled: dc.enabled, trimDb: dc.trimDb, measuredLatencyMs: config.measuredLatencyMs(d.uid),
                                  plan: plan[d.uid]))
        }
        for i in rows.indices where !rows[i].inAggregate {
            rows[i].needsRecalibration = config.device(rows[i].uid).needsRecalibration && config.measuredLatencyMs(rows[i].uid) != nil
        }
        if rows != devices { devices = rows }
        // 自動校正：只看「engine 在跑、有輸出」時的完整刷新（engine 重建中／校正中輸出清單是空的，不能當成裝置拔掉）
        if snap.full, running, !calibrating, !details.isEmpty { observeForAutoCalibration(rows) }

        // 警告
        var w: [AppWarning] = []
        if otherInstance {
            w.append(AppWarning(kind: .otherInstance, message: "已有另一個 In_Unison42 在執行（兩個會互相靜音）：本 app 先不啟動引擎，對方結束後 1 秒內自動接手", actionTitle: nil))
        }
        if calibrating {
            w.append(AppWarning(kind: .engine, message: "校正中：同步播放已暫停，校正結束後自動恢復", actionTitle: nil))
        } else if running && !st.running && reconnector != nil && now.timeIntervalSince(lastIO.at) >= 5 {
            w.append(AppWarning(kind: .engine, message: "引擎沒有在跑（重接中）；詳情見 ~/Library/Logs/In_Unison42.log", actionTitle: nil))
        }
        if !calibrating && running && st.running && !ioAdvancing && !engineIdle && now.timeIntervalSince(lastIO.at) >= 2 {
            // 這個行程之前跑過 → 不是權限（10-02 03:06 校正後卡 20 秒，面板卻寫「多半是權限」）
            let ranBefore = engine.ioCycles > 0
            w.append(AppWarning(kind: ranBefore ? .engine : .permission,
                                message: ranBefore
                                    ? "音訊暫時沒有在跑：系統音訊服務沒回應（不是權限問題），已先讓原本的聲音照常出、自動重試中"
                                    : "音訊沒有在跑：多半是「系統音訊錄製」權限未授與（系統設定 → 隱私權與安全性 → 螢幕與系統錄音 → 僅系統錄音）",
                                actionTitle: nil))
        }
        if let g = snap.guardWarning {
            w.append(AppWarning(kind: .defaultOutput, message: g.message, actionTitle: "切回「\(g.volumeSourceName)」"))
        }
        if snap.full { configProtection = Config.writeProtection() }
        if let p = configProtection {
            w.append(AppWarning(kind: .config,
                                message: "設定檔損壞，已改用預設值並停止自動存檔（壞檔保留為 \((p.corruptBackup as NSString).lastPathComponent)）。校正成功或按「重設設定」後恢復",
                                actionTitle: "重設設定"))
        }
        for (uid, err) in snap.bluetoothErrors.sorted(by: { $0.key < $1.key }) {
            let name = devices.first { $0.uid == uid }?.name ?? uid
            w.append(AppWarning(kind: .bluetooth, message: "藍牙「\(name)」無法出聲：\(err)", actionTitle: nil))
        }
        w += bluetoothHealthWarnings(snap.bluetoothStats, now: now)
        if w != warnings { warnings = w }

        // log：狀態有變才印（另 600 秒心跳）
        if running, st.changeKey != lastChangeKey || now.timeIntervalSince(lastStatusPrint) >= 600 {
            AppLog.line(st.line)
            lastChangeKey = st.changeKey
            lastStatusPrint = now
            rotateStdoutLogIfNeeded()
        }
        // state.json：狀態變化（changeKey＋IO 前進與否＋設定模式）才寫，另 10 秒心跳（io／sampleTime 最多舊 10 秒）
        if running {
            let key = "\(st.changeKey)|\(ioAdvancing)|\(config.mode.rawValue)|\(config.manualLock)"
            if key != lastStateFileKey || now.timeIntervalSince(lastStateFileWrite) >= Self.stateFileHeartbeat {
                lastStateFileKey = key
                lastStateFileWrite = now
                AppRuntimeState(pid: getpid(), updatedAt: Config.nowISO8601(), running: st.running, generation: st.generation,
                                ioCycles: st.ioCycles, sampleTime: st.sampleTime, mode: st.mode.rawValue,
                                configMode: config.mode.rawValue, manualLock: config.manualLock, line: st.line).save()
            }
        }
    }
}

// MARK: - 高頻數值（面板開著時才更新）

/// 峰值、狀態行等每秒都會變的數值。和 AppState 分開：它變的時候只有訂閱它的 view 重算，
/// 選單列圖示（In_Unison42App 觀察 AppState）與面板其他部分不會跟著每秒重算。面板關著時不更新（AppState.panelVisible）
@MainActor
final class LiveMeters: ObservableObject {
    /// engine 狀態行（同 AppState.statusLine）
    @Published private(set) var statusLine = ""
    /// 最近一秒的 tap 輸入峰值（0…1）
    @Published private(set) var inputPeak: Float = 0
    /// 最近一秒的聚合裝置輸出峰值（key = 裝置 UID；藍牙輸出目前沒有）
    @Published private(set) var outputPeaks: [String: Float] = [:]

    func update(statusLine line: String, inputPeak ip: Float? = nil, outputPeaks op: [String: Float]? = nil) {
        if line != statusLine { statusLine = line }
        if let ip, ip != inputPeak { inputPeak = ip }
        if let op, op != outputPeaks { outputPeaks = op }
    }

    func reset() {
        if inputPeak != 0 { inputPeak = 0 }
        if !outputPeaks.isEmpty { outputPeaks = [:] }
    }
}

// MARK: - log

extension AppLog {
    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// 帶時間戳的一行 log（stdout；app 模式已導到 ~/Library/Logs/In_Unison42.log）
    static func line(_ s: String) {
        print("[\(tsFormatter.string(from: Date()))] \(s)")
    }
}

// MARK: - 執行狀態檔（~/Library/Application Support/In_Unison42/state.json，狀態變化時＋每 10 秒心跳更新；`status` 會讀）

struct AppRuntimeState: Codable {
    let pid: Int32
    let updatedAt: String
    let running: Bool
    let generation: Int
    let ioCycles: Int64
    let sampleTime: Int64
    let mode: String
    let configMode: String
    let manualLock: Bool
    let line: String

    static var fileURL: URL { Config.directory.appendingPathComponent("state.json") }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        try? enc.encode(self).write(to: Self.fileURL, options: .atomic)
    }

    static func load() -> AppRuntimeState? {
        guard let d = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(AppRuntimeState.self, from: d)
    }

    /// app 結束時把 running 標成 false（保留最後的計數）
    static func markStopped() {
        guard let s = load() else { return }
        AppRuntimeState(pid: s.pid, updatedAt: Config.nowISO8601(), running: false, generation: s.generation,
                        ioCycles: s.ioCycles, sampleTime: s.sampleTime, mode: s.mode, configMode: s.configMode,
                        manualLock: s.manualLock, line: s.line).save()
    }

    var summary: String {
        let alive = isAlive(pid)
        return "pid \(pid)\(alive ? "（執行中）" : "（已結束）") 更新 \(updatedAt) running=\(running) gen=\(generation) io=\(ioCycles) "
            + "模式 \(mode)（設定 \(configMode)\(manualLock ? "，手動鎖定" : "")）\n\(line)"
    }
}

/// BluetoothOutManager 的公開方法全部在自己的序列 queue 上執行（見 BluetoothOut.swift），可跨執行緒呼叫
extension BluetoothOutManager: @unchecked Sendable {}
