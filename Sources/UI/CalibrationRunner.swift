// CalibrationRunner.swift — 從選單列 app 執行校正（owner：UI）
//
// 流程：pauseEngine（AppState 停掉自己的 engine＋重接，兩個 tap 會互相靜音）
//       → 子行程 `<app 執行檔> calibrate [--mic <uid>]`（同一個簽章身分 → 同一份 TCC 權限）
//       → 逐行讀 stdout 換成面板的進度／結果 → resumeEngine（AppState 重新讀設定並啟動 engine）。
// 子行程的環境變數 IN_UNISON42_CALIBRATE_PARENT=<app pid>：讓 cmdCalibrate 知道「擋路的 run 實例」是呼叫它的 app，
// 而且 app 的 engine 已經停了（需要架構負責人在 cmdCalibrate 認這個變數，見 open issue）。
//
// 接線（AppState 負責，UI owner 不改 AppState）：
//   CalibrationRunner.shared.pauseEngine = { done in /* reconnector.stop(); control.async { engine.stop(); main { done() } } */ }
//   CalibrationRunner.shared.resumeEngine = { /* reloadConfig(); 重新 start engine＋reconnector */ }
// 兩個都沒接之前，面板的「開始校正」按鈕會改呼叫 AppState.runCalibration()（目前是 TODO，只寫 log）。
import AppKit
import Foundation

@MainActor
final class CalibrationRunner: ObservableObject {
    static let shared = CalibrationRunner()

    enum Phase: Equatable {
        case idle
        /// step：給人看的步驟；fraction：0…1，nil = 不確定進度
        case running(step: String, fraction: Double?)
        case finished(ok: Bool, message: String, at: Date)
    }

    @Published private(set) var phase: Phase = .idle
    /// 子行程輸出的最後幾行（除錯用；面板不直接顯示）
    @Published private(set) var recentLines: [String] = []

    /// AppState 接：暫停本 app 的 engine＋重接，停好後呼叫 done（主執行緒）
    var pauseEngine: ((@escaping () -> Void) -> Void)?
    /// AppState 接：校正結束（成功或失敗）後重新讀設定並啟動 engine
    var resumeEngine: (() -> Void)?
    /// AppState 接（可選）：engine 已經提早恢復（交接模式的 `@@tap-released`）後，子行程結束時只重讀設定（applyConfig，不重建 tap）
    var reloadAfterCalibration: (() -> Void)?
    /// AppState 接（第 B 輪）：背景監聽目前套用的延遲修正（uid → ms）。`--verify-program`（不寫入）時交給子行程，
    /// 讓驗證量的是 app 實際在播的補償（修正只在 app 記憶體、不存檔；沒有這個，驗證會量到修正前的狀態）
    var runtimeCorrections: (() -> [String: Double])?
    nonisolated static let runtimeCorrectionsEnv = "IN_UNISON42_RUNTIME_CORRECTIONS"

    /// 一次性：這次校正結束時呼叫（ok, 訊息, 子行程全部輸出）。ctl 用
    var onFinishOnce: ((Bool, String, [String]) -> Void)?
    /// 【自動校正】每次校正開始（extraArgs）／結束（ok, 使用者停止, 訊息, 子行程全部輸出）都呼叫。AppState 接（AutoCalibrator）
    var onStarted: (([String]) -> Void)?
    var onFinished: ((Bool, Bool, String, [String]) -> Void)?
    /// 這次子行程的全部輸出（上限 4000 行）
    private(set) var allLines: [String] = []

    var isWired: Bool { pauseEngine != nil && resumeEngine != nil }
    var isRunning: Bool { if case .running = phase { return true } else { return false } }

    private var process: Process?
    private var buffer = Data()
    private var measureStart: Date?
    private var measureSeconds: Double?
    private var ticker: Timer?
    private var resultMessage: String?
    private var failureMessage: String?
    private var cancelled = false
    /// 交接模式（IN_UNISON42_HANDOFF=1，只用於脈衝量尺）：子行程先準備好麥克風／藍牙／WAV，印 `@@handoff-ready` 才暫停 app 的 engine，
    /// 暫停完寫 stdin「go」；子行程停掉自己的 tap 時印 `@@tap-released` → 立刻恢復 app 的 engine。縮短兩段「沒有 tap、原音外漏」的空窗。
    private var handoff = false
    private var enginePaused = false
    private var engineResumed = false
    private var stdinPipe: Pipe?
    /// 交接用時間點（log：量原音空窗）
    private var pauseRequestedAt: Date?

    init() {}

    /// 開始校正。micUID nil = 自動（CLI 會用 config.calibrationMicUID 或 Devices.microphone()）
    /// extraArgs：附加給 calibrate 的參數（例如 --verify、--verify-program --mode game；ctl 用）
    func start(micUID: String?, extraArgs: [String] = []) {
        guard !isRunning else { return }
        guard let exe = Bundle.main.executableURL else {
            phase = .finished(ok: false, message: "找不到執行檔，無法校正", at: Date())
            return
        }
        resultMessage = nil; failureMessage = nil; cancelled = false
        measureStart = nil; measureSeconds = nil
        recentLines = []
        allLines = []
        enginePaused = false; engineResumed = false
        handoff = Self.handoffEnabled && pauseEngine != nil && Self.usesHandoff(extraArgs)
        phase = .running(step: handoff ? "準備中⋯" : "暫停同步播放⋯", fraction: nil)
        onStarted?(extraArgs)
        if handoff {
            // 先啟動子行程（app 的 engine 照常出聲），子行程準備好才暫停（handle 裡的 @@handoff-ready）
            launch(exe: exe, micUID: micUID, extraArgs: extraArgs)
            return
        }
        let launch: () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                self?.enginePaused = true
                self?.launch(exe: exe, micUID: micUID, extraArgs: extraArgs)
            }
        }
        if let pause = pauseEngine { pause(launch) } else { launch() }
    }

    /// 停止校正：送 SIGINT，calibrate 會清掉自己的 tap／聚合裝置並還原系統狀態
    func cancel() {
        guard isRunning else { return }
        cancelled = true
        if let p = process, p.isRunning {
            p.interrupt()
        } else {
            finish(status: 130)
        }
    }

    /// 延遲修正 ↔ 環境變數字串：「uid=ms」以換行分隔（uid 可能含冒號／逗號，不會含換行）
    nonisolated static func encodeCorrections(_ c: [String: Double]) -> String {
        c.sorted { $0.key < $1.key }.map { String(format: "%@=%.4f", $0.key, $0.value) }.joined(separator: "\n")
    }
    nonisolated static func decodeCorrections(_ s: String?) -> [String: Double] {
        guard let s else { return [:] }
        var out: [String: Double] = [:]
        for line in s.split(separator: "\n") {
            guard let eq = line.lastIndex(of: "=") else { continue }
            let uid = String(line[..<eq]), v = Double(line[line.index(after: eq)...]) ?? .nan
            if !uid.isEmpty, v.isFinite, abs(v) <= Engine.maxCorrectionMs { out[uid] = v }
        }
        return out
    }

    /// 交接模式總開關（出問題時改 false 退回「先暫停再啟動子行程」）
    static let handoffEnabled = true
    /// 只有脈衝量尺（ppRun：--pulse／--verify-program／--volume-test）支援交接；chirp／--selftest 走舊流程
    static func usesHandoff(_ args: [String]) -> Bool {
        !args.contains("--selftest") && (args.contains("--pulse") || args.contains("--verify-program") || args.contains("--volume-test"))
    }

    /// 結果看完後回到待機
    func dismissResult() {
        if case .finished = phase { phase = .idle }
    }

    // MARK: 內部

    private func launch(exe: URL, micUID: String?, extraArgs: [String]) {
        guard !cancelled else { finish(status: 130); return }
        let p = Process()
        p.executableURL = exe
        var args = ["calibrate"]
        if let micUID, !extraArgs.contains("--mic") { args += ["--mic", micUID] }
        args += extraArgs
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["IN_UNISON42_CALIBRATE_PARENT"] = String(getpid())
        env[Self.runtimeCorrectionsEnv] = nil
        if extraArgs.contains("--verify-program"), !extraArgs.contains("--pulse"), let corr = runtimeCorrections?(), !corr.isEmpty {
            env[Self.runtimeCorrectionsEnv] = Self.encodeCorrections(corr)
        }
        if handoff {
            env["IN_UNISON42_HANDOFF"] = "1"
            let inPipe = Pipe()
            // 子行程可能先結束（例如等 go 逾時）→ 之後寫 go 會碰到斷掉的管線：不要 SIGPIPE（會殺掉 app），讓 write 丟錯誤就好
            _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            p.standardInput = inPipe
            stdinPipe = inPipe
        } else {
            stdinPipe = nil
        }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(d) } }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                    self?.receive(rest)
                    self?.flushPartialLine()
                    self?.finish(status: status)
                }
            }
        }
        phase = .running(step: "準備中⋯", fraction: nil)
        do {
            try p.run()
            process = p
            AppLog.line("校正子行程 pid \(p.processIdentifier)：\(exe.lastPathComponent) \(args.joined(separator: " "))")
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            failureMessage = "無法啟動校正：\(error.localizedDescription)"
            finish(status: -1)
        }
    }

    private func receive(_ d: Data) {
        guard !d.isEmpty else { return }
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(String(decoding: lineData, as: UTF8.self))
        }
    }

    private func flushPartialLine() {
        guard !buffer.isEmpty else { return }
        handle(String(decoding: buffer, as: UTF8.self))
        buffer.removeAll()
    }

    /// 把 calibrate 的輸出換成面板進度（對應 Calibrate.swift 的 print 文字）
    private func handle(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        if line == "@@handoff-ready" { handoffReady(); return }
        if line == "@@tap-released" { tapReleased(); return }
        AppLog.line("[校正] \(line)")
        recentLines.append(line)
        if allLines.count < 4000 { allLines.append(line) }
        if recentLines.count > 40 { recentLines.removeFirst(recentLines.count - 40) }
        guard isRunning else { return }
        let step = CalibrationOutputParser.parse(line)
        switch step {
        case .mic:
            phase = .running(step: "開啟麥克風⋯", fraction: nil)
        case .measuring(let seconds):
            measureStart = Date()
            measureSeconds = seconds
            phase = .running(step: "播放測試音並錄音，請保持安靜⋯", fraction: 0)
            startTicker()
        case .analyzing:
            stopTicker()
            phase = .running(step: "分析中⋯", fraction: 0.95)
        case .success(let msg):
            resultMessage = msg
        case .failure(let msg):
            if failureMessage == nil { failureMessage = msg }
        case .other:
            break
        }
    }

    /// 子行程準備好（麥克風在錄、藍牙已開、WAV 已寫）→ 暫停 app 的 engine → stdin「go」
    private func handoffReady() {
        guard handoff, !enginePaused, let pause = pauseEngine else { return }
        enginePaused = true
        pauseRequestedAt = Date()
        AppLog.line("校正交接：子行程已準備好，暫停本 app 的 engine")
        phase = .running(step: "暫停同步播放⋯", fraction: nil)
        pause { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let ms = self.pauseRequestedAt.map { Date().timeIntervalSince($0) * 1000 } ?? 0
                if let h = self.stdinPipe?.fileHandleForWriting {
                    do { try h.write(contentsOf: Data("go\n".utf8)) } catch { AppLog.line("✗ 校正交接：寫 go 失敗：\(error)") }
                }
                AppLog.line(String(format: "校正交接：app 的 tap 已拆（%.0f ms），送出 go", ms))
            }
        }
    }

    /// 子行程已停掉自己的 tap（量測錄完、分析前）→ 立刻恢復 app 的 engine（用舊設定；子行程結束時再 reloadAfterCalibration）
    private func tapReleased() {
        guard handoff, enginePaused, !engineResumed, reloadAfterCalibration != nil else { return }
        engineResumed = true
        AppLog.line("校正交接：子行程已拆 tap，先恢復本 app 的 engine（結果寫入後再重讀設定）")
        resumeEngine?()
    }

    private func startTicker() {
        stopTicker()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    private func tick() {
        guard case .running(let step, _) = phase, let s = measureStart, let total = measureSeconds, total > 0 else { return }
        let f = min(Date().timeIntervalSince(s) / total, 1) * 0.9
        phase = .running(step: step, fraction: f)
    }

    private func finish(status: Int32) {
        stopTicker()
        process = nil
        // 結束代碼 0 且印了「✓ 已寫入」＝寫入成功（中途的 ✗ 行只是個別脈衝／個別裝置的說明）
        let ok = status == 0 && !cancelled && (failureMessage == nil || resultMessage != nil)
        let msg: String
        if cancelled {
            msg = "已停止校正，設定未修改"
        } else if ok {
            msg = resultMessage ?? "校正完成，已套用新的延遲"
        } else {
            msg = failureMessage ?? "校正失敗（結束代碼 \(status)），設定未修改"
        }
        phase = .finished(ok: ok, message: msg, at: Date())
        AppLog.line("校正結束：\(ok ? "成功" : "未成功")（\(status)）\(msg)")
        if let h = stdinPipe?.fileHandleForWriting { try? h.close() }
        stdinPipe = nil
        if engineResumed {
            reloadAfterCalibration?()          // engine 已提早恢復：只套用新寫入的延遲
        } else if enginePaused || !handoff {
            resumeEngine?()
        } else {
            reloadAfterCalibration?()          // 交接模式但子行程在準備階段就結束（沒暫停過 engine）
        }
        enginePaused = false; engineResumed = false
        if let f = onFinishOnce { onFinishOnce = nil; f(ok, msg, allLines) }
        onFinished?(ok, cancelled, msg, allLines)
    }
}

/// calibrate 輸出的一行 → 面板步驟（純函式，可單元測試）
enum CalibrationOutputParser {
    enum Step: Equatable {
        case mic, measuring(seconds: Double?), analyzing, success(String), failure(String), other
    }

    static func parse(_ line: String) -> Step {
        if line.hasPrefix("麥克風：") { return .mic }
        if line.contains("請保持安靜") {
            // 「輸出 3 台、每輪 … 約 6.4 秒。請保持安靜…」
            var secs: Double?
            if let r = line.range(of: "約 "), let end = line.range(of: " 秒", range: r.upperBound..<line.endIndex) {
                secs = Double(line[r.upperBound..<end.lowerBound])
            }
            return .measuring(seconds: secs)
        }
        if line.hasPrefix("錄到 ") { return .analyzing }
        if line.hasPrefix("✓ 已寫入") { return .success("校正完成，已套用新的延遲") }
        if line.hasPrefix("✓ 驗證通過") { return .success(String(line.dropFirst(2))) }
        if line.hasPrefix("✓"), line.contains("驗證通過") { return .success(String(line.dropFirst(2))) }
        if line.hasPrefix("只有") && line.contains("不需要校正") { return .success(line) }
        if line.hasPrefix("✗") { return .failure(String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces)) }
        return .other
    }
}
