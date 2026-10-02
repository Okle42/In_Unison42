// Config.swift — 使用者設定（~/Library/Application Support/In_Unison42/config.json）＋ 模式與出聲計畫（純函式 plan）
//
// 第 2 版格式（version = 2，第一期選單列 app）：
//   * 每裝置：measuredLatencyMs（相對最快裝置的實測延遲，校正寫入）、enabled、trimDb（一律生效）
//     delayMs 只是舊版欄位（第 1 版的補償值）：讀入時用來反推 measuredLatencyMs；新版的補償由 plan() 算出
//   * 全域：mode（auto/music/movie/game）、manualLock、autoModeRules（bundle id → 模式）、calibrationMicUID、modeCaps
// 舊檔（沒有 version）無痛讀入：delayMs 反推 measuredLatencyMs；levelMatch=false 時舊 trimDb 本來就沒生效 → 歸 0。
import Foundation

// MARK: - 模式

/// 使用者選的模式（含「自動」）
enum AudioMode: String, Codable, CaseIterable, Equatable {
    case auto, music, movie, game

    /// 自動 → nil（要由 ModeManager 依前景 app 決定）
    var fixed: PlayMode? {
        switch self {
        case .auto: return nil
        case .music: return .music
        case .movie: return .movie
        case .game: return .game
        }
    }

    var label: String {
        switch self {
        case .auto: return "自動"
        case .music: return "音樂"
        case .movie: return "影片"
        case .game: return "遊戲"
        }
    }
}

/// 實際生效的模式（Engine 用；沒有 auto）
enum PlayMode: String, Codable, CaseIterable, Equatable {
    case music, movie, game

    var label: String { AudioMode(rawValue: rawValue)!.label }
}

/// 各模式的延遲上限（ms）：裝置「相對最快裝置的實測延遲」超過就不出聲。nil = 不限
struct ModeCaps: Codable, Equatable {
    var musicMs: Double? = nil
    var movieMs: Double? = 80
    var gameMs: Double? = 20

    private enum CodingKeys: String, CodingKey { case musicMs, movieMs, gameMs }

    init(musicMs: Double? = nil, movieMs: Double? = 80, gameMs: Double? = 20) {
        self.musicMs = musicMs; self.movieMs = movieMs; self.gameMs = gameMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        musicMs = try c.decodeIfPresent(Double.self, forKey: .musicMs)
        movieMs = c.contains(.movieMs) ? try c.decodeIfPresent(Double.self, forKey: .movieMs) : 80
        gameMs = c.contains(.gameMs) ? try c.decodeIfPresent(Double.self, forKey: .gameMs) : 20
    }

    /// nil 也明確寫成 null（否則讀回來會變成預設值 80／20）
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(musicMs, forKey: .musicMs)
        try c.encode(movieMs, forKey: .movieMs)
        try c.encode(gameMs, forKey: .gameMs)
    }

    /// 上限（ms）；不限回 .infinity
    func cap(_ m: PlayMode) -> Double {
        let v: Double?
        switch m {
        case .music: v = musicMs
        case .movie: v = movieMs
        case .game: v = gameMs
        }
        guard let v, v.isFinite, v >= 0 else { return .infinity }
        return v
    }
}

// MARK: - 裝置設定

/// 單一輸出裝置的設定（以裝置 UID 為 key 存在 Config.devices）
struct DeviceConfig: Codable, Equatable {
    /// 【舊版欄位】第 1 版的補償延遲（ms）。第 2 版不再用它決定延遲（改由 plan() 依 measuredLatencyMs 計算），
    /// 只在讀舊檔時反推 measuredLatencyMs；calibrate 仍會順手寫入（舊版執行檔讀得懂）。
    var delayMs: Double = 0
    /// 音量微調（dB），Config.trimDbRange 內；第 2 版一律生效（面板的每台音量微調、calibrate --level 都寫這裡）
    var trimDb: Double = 0
    /// 相對最快裝置的實測延遲（ms，≥ 0）；nil = 未量測。calibrate 寫入
    var measuredLatencyMs: Double? = nil
    /// false = 使用者關掉這台（不出聲）
    var enabled: Bool = true
    /// 藍牙：量過延遲之後斷線又重新連上（A2DP 延遲可能變了）→ true，面板提示「重新校正」；下次校正寫入延遲時清掉。
    /// 出聲政策見 Config.silenceBluetoothAfterReconnect
    var needsRecalibration: Bool = false

    init(delayMs: Double = 0, trimDb: Double = 0, measuredLatencyMs: Double? = nil, enabled: Bool = true, needsRecalibration: Bool = false) {
        self.delayMs = delayMs
        self.trimDb = trimDb
        self.measuredLatencyMs = measuredLatencyMs
        self.enabled = enabled
        self.needsRecalibration = needsRecalibration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        delayMs = try c.decodeIfPresent(Double.self, forKey: .delayMs) ?? 0
        trimDb = try c.decodeIfPresent(Double.self, forKey: .trimDb) ?? 0
        measuredLatencyMs = try c.decodeIfPresent(Double.self, forKey: .measuredLatencyMs)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        needsRecalibration = try c.decodeIfPresent(Bool.self, forKey: .needsRecalibration) ?? false
    }
}

// MARK: - Config

struct Config: Codable, Equatable {
    static let currentVersion = 2
    /// 延遲線上限（ms）。2026-09-29 由 500 調到 1000：藍牙（A2DP）相對延遲可能 100–400 ms，讓其他喇叭等它時要補到這麼多。
    /// 記憶體：延遲線 = 2 的次方 ≥ 上限＋16384 frame，48 kHz 下 500 ms 與 1000 ms 都是 65536 frame（512 KB），不變；
    /// 96 kHz 為 131072 frame（1 MB）。節目音廣播緩衝（ProgramRing，2.7 s @48k）也容得下藍牙讀取點落後 1 s＋緩衝
    static let maxDelayMs: Double = 1000
    /// 藍牙重新連線後（needsRecalibration）的出聲政策：false = 沿用舊的實測值照常出聲、面板提示重新校正；
    /// true = 先不出聲直到重新校正。依 2026-09-29 實測決定（見 README「藍牙」）
    static let silenceBluetoothAfterReconnect = false
    /// 【第 B 輪 2026-09-29 Kang 定案】藍牙真的斷線重連 → 比照 app 重開：先不出聲、倒數 3 秒、`--only` 重校
    /// （V8：A2DP 串流每次重開延遲差 35–61 ms）。false = 退回舊政策（沿用舊值出聲）
    static let recalibrateBluetoothOnReconnect = true
    static let trimDbRange: ClosedRange<Double> = -60...12

    /// 預設的自動模式對照（bundle id → 模式）。遊戲另有規則：Info.plist 的 LSApplicationCategoryType 是
    /// public.app-category.*games → 遊戲（ModeRules.resolve 處理，不在這張表）
    static let defaultAutoModeRules: [String: AudioMode] = [
        "com.colliderli.iina": .movie,
        "com.apple.QuickTimePlayerX": .movie,
        "org.videolan.vlc": .movie,
        "com.firecore.infuse": .movie,
        "com.netflix.Netflix": .movie,
        "com.apple.TV": .movie,
        "io.mpv": .movie,
        "com.valvesoftware.steam": .game,
    ]

    var version: Int = Config.currentVersion
    /// key = 裝置 UID（kAudioDevicePropertyDeviceUID）
    var devices: [String: DeviceConfig] = [:]
    /// 【舊版欄位】第 1 版「trim 是否生效」。第 2 版 trim 一律生效；這個值只表示「最近一次 calibrate --level 有寫 trim」
    var levelMatch: Bool = false
    /// 最近一次校正時間（ISO 8601），未校正為 nil
    var calibratedAt: String? = nil
    /// 使用者選的模式（auto = 依前景 app）
    var mode: AudioMode = .auto
    /// true = 使用者手動選了模式，自動切換暫停，直到按回「自動」（按回自動時 mode = .auto、manualLock = false）
    var manualLock: Bool = false
    /// 自動模式對照：bundle id → 模式（值只該是 music/movie/game；auto 視為沒有規則）
    var autoModeRules: [String: AudioMode] = Config.defaultAutoModeRules
    /// 校正用麥克風 UID；nil = 自動（Devices.microphone()）。可以是 Continuity（iPhone）麥克風——只准用於校正
    var calibrationMicUID: String? = nil
    /// 各模式延遲上限
    var modeCaps: ModeCaps = ModeCaps()
    /// 【執行期，不存檔】自動校正（AppState／AutoCalibrator）暫停出聲的藍牙 uid：app 重開後、重新校正完成前不出聲
    /// （實測 app 重開後藍牙延遲可能差 35 ms）。只由 AppState 疊在交給 engine 的設定上；config.json 不會有這個欄位
    var calibrationHolds: Set<String> = []
    /// 【第 B 輪】背景監聽（播音樂時自動修正落拍）：面板一鍵開關，預設開。開著時每 monitorIntervalSec 用校正麥克風聽
    /// monitorCaptureSec 秒（錄音只在記憶體、不存檔；會亮橘色麥克風燈）
    var monitorEnabled: Bool = true
    var monitorIntervalSec: Double = 300
    var monitorCaptureSec: Double = 10
    /// 【第 C 輪】藍牙漂移預測補償（同串流內的多次量測估漂移速度 → 延遲修正緩慢斜率預先補償；量測點不夠時自己排短校正）。面板開關，預設開
    var bluetoothDriftCompensation: Bool = true
    /// 【第 C 輪】藍牙剛連上 10 秒內 macOS 把預設輸出搶到藍牙 → 自動切回音量來源（內建）。面板開關，預設開
    var restoreDefaultOutputOnBluetoothConnect: Bool = true

    /// 生效值（夾在合理範圍：間隔 60 秒–1 小時、每輪 5–20 秒）
    var effectiveMonitorIntervalSec: Double { monitorIntervalSec.isFinite ? min(max(monitorIntervalSec, 60), 3600) : 300 }
    var effectiveMonitorCaptureSec: Double { monitorCaptureSec.isFinite ? min(max(monitorCaptureSec, 5), 20) : 10 }

    /// 存檔欄位（calibrationHolds 是執行期狀態，不在這裡 → 不寫進 config.json）
    private enum CodingKeys: String, CodingKey {
        case version, devices, levelMatch, calibratedAt, mode, manualLock, autoModeRules, calibrationMicUID, modeCaps
        case monitorEnabled, monitorIntervalSec, monitorCaptureSec
        case bluetoothDriftCompensation, restoreDefaultOutputOnBluetoothConnect
    }

    init(devices: [String: DeviceConfig] = [:], levelMatch: Bool = false, calibratedAt: String? = nil,
         mode: AudioMode = .auto, manualLock: Bool = false,
         autoModeRules: [String: AudioMode] = Config.defaultAutoModeRules,
         calibrationMicUID: String? = nil, modeCaps: ModeCaps = ModeCaps()) {
        self.devices = devices
        self.levelMatch = levelMatch
        self.calibratedAt = calibratedAt
        self.mode = mode
        self.manualLock = manualLock
        self.autoModeRules = autoModeRules
        self.calibrationMicUID = calibrationMicUID
        self.modeCaps = modeCaps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let ver = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        devices = try c.decodeIfPresent([String: DeviceConfig].self, forKey: .devices) ?? [:]
        levelMatch = try c.decodeIfPresent(Bool.self, forKey: .levelMatch) ?? false
        calibratedAt = try c.decodeIfPresent(String.self, forKey: .calibratedAt)
        mode = (try? c.decodeIfPresent(AudioMode.self, forKey: .mode)) ?? .auto
        manualLock = try c.decodeIfPresent(Bool.self, forKey: .manualLock) ?? false
        if let raw = try? c.decodeIfPresent([String: String].self, forKey: .autoModeRules) {
            autoModeRules = raw.compactMapValues { AudioMode(rawValue: $0) }
        } else {
            autoModeRules = Config.defaultAutoModeRules
        }
        calibrationMicUID = try c.decodeIfPresent(String.self, forKey: .calibrationMicUID)
        modeCaps = (try? c.decodeIfPresent(ModeCaps.self, forKey: .modeCaps)) ?? ModeCaps()
        monitorEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .monitorEnabled)) ?? true
        monitorIntervalSec = (try? c.decodeIfPresent(Double.self, forKey: .monitorIntervalSec)) ?? 300
        monitorCaptureSec = (try? c.decodeIfPresent(Double.self, forKey: .monitorCaptureSec)) ?? 10
        bluetoothDriftCompensation = (try? c.decodeIfPresent(Bool.self, forKey: .bluetoothDriftCompensation)) ?? true
        restoreDefaultOutputOnBluetoothConnect = (try? c.decodeIfPresent(Bool.self, forKey: .restoreDefaultOutputOnBluetoothConnect)) ?? true
        version = Config.currentVersion
        if ver < 2 { Config.migrateV1(&self) }
    }

    /// 第 1 版 → 第 2 版：
    /// * measuredLatencyMs = max(delayMs) − delayMs（第 1 版 delayMs = 最慢延遲 − 自己延遲，所以這正是「相對最快」的延遲）
    ///   只有真的校正過（calibratedAt 有值、或任一 delayMs > 0）才反推；已有 measuredLatencyMs 的不覆寫
    /// * levelMatch = false 時第 1 版 trimDb 沒生效 → 歸 0（第 2 版 trim 一律生效，避免行為突然改變）
    static func migrateV1(_ c: inout Config) {
        let delays = c.devices.values.map(\.delayMs).filter { $0.isFinite }
        let calibrated = c.calibratedAt != nil || delays.contains { $0 > 0 }
        if calibrated, let maxD = delays.max() {
            for (uid, var d) in c.devices where d.measuredLatencyMs == nil && d.delayMs.isFinite {
                d.measuredLatencyMs = ((maxD - d.delayMs) * 1000).rounded() / 1000
                c.devices[uid] = d
            }
        }
        if !c.levelMatch {
            for (uid, var d) in c.devices where d.trimDb != 0 {
                d.trimDb = 0
                c.devices[uid] = d
            }
        }
    }

    // MARK: 路徑

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/In_Unison42", isDirectory: true)
    }
    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    // MARK: 讀寫

    /// 讀檔；檔案不存在時回傳預設值。舊版格式自動轉換（只在記憶體裡，save 才寫回）。
    /// 設定檔存在但讀不出來／解析失敗（損壞）→
    ///   1. 壞檔改名成 config.json.corrupt-<時間戳> 保留（不刪、不覆寫）
    ///   2. 寫入「唯讀保護旗標」（config.json.protect）：在使用者明確操作（校正成功或按重設）之前，save() 一律拒絕，
    ///      避免預設值自動蓋掉使用者的校正結果（壞檔還在，可以手動救回）
    ///   3. stderr／log 警告；面板用 Config.writeProtection(for:) 顯示
    /// 旗標存在、但設定檔又是好的（使用者自己修好或換回來）→ 解除保護。
    static func load(from url: URL = Config.fileURL) -> Config {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            if let p = writeProtection(for: url) {
                logWarning("⚠ 設定檔唯讀保護中（先前的設定檔損壞，已改名保留為 \(p.corruptBackup)）：使用預設值、不自動存檔，直到校正成功或按「重設設定」")
            }
            return Config()
        }
        do {
            let data = try Data(contentsOf: url)
            let c = try JSONDecoder().decode(Config.self, from: data)
            if writeProtection(for: url) != nil {
                clearWriteProtection(for: url)
                logWarning("設定檔已恢復可讀（\(url.path)）：解除唯讀保護")
            }
            return c
        } catch {
            let backup = quarantineCorrupt(url)
            let p = WriteProtection(corruptBackup: backup?.path ?? url.path, since: nowISO8601(), error: "\(error)")
            setWriteProtection(p, for: url)
            logWarning("⚠ 設定檔無法解析，改用預設值並進入唯讀保護：\(url.path)（\(error)）；"
                       + (backup.map { "壞檔已改名保留：\($0.path)" } ?? "壞檔無法改名，原地保留")
                       + "。校正成功或按「重設設定」之前不會自動覆寫")
            return Config()
        }
    }

    /// 原子寫入（先寫暫存檔再取代）。
    /// explicit：這次寫入是使用者明確操作的結果（校正成功、重設）；nil = 用行程層級的 Config.explicitWritesAllowed
    /// （calibrate 子行程會設 true：它只在量測成功時寫檔）。
    /// 唯讀保護中且不是明確操作 → 丟 ConfigWriteProtectedError、不寫檔；明確操作寫入成功 → 解除保護。
    func save(to url: URL = Config.fileURL, explicit: Bool? = nil) throws {
        let isExplicit = explicit ?? Config.explicitWritesAllowed
        if let p = Config.writeProtection(for: url), !isExplicit {
            throw ConfigWriteProtectedError(protection: p)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
        if Config.writeProtection(for: url) != nil {
            Config.clearWriteProtection(for: url)
            Config.logWarning("設定檔已由使用者操作重新寫入（\(url.path)）：解除唯讀保護")
        }
    }

    /// 使用者按「重設設定」：寫入預設值（明確操作）並解除唯讀保護；壞檔（config.json.corrupt-*）保留不動
    @discardableResult
    static func resetToDefaults(at url: URL = Config.fileURL) throws -> Config {
        let c = Config()
        try c.save(to: url, explicit: true)
        return c
    }

    // MARK: 損壞保護（唯讀保護旗標）

    struct WriteProtection: Codable, Equatable {
        /// 壞檔改名後的路徑
        var corruptBackup: String
        /// 進入保護的時間（ISO 8601）
        var since: String
        /// 解析錯誤
        var error: String
    }

    /// 行程層級：這個行程的 save() 視為使用者明確操作（calibrate 子行程設 true）
    static var explicitWritesAllowed: Bool {
        get { explicitWritesFlag.value }
        set { explicitWritesFlag.value = newValue }
    }
    private static let explicitWritesFlag = LockedValue(false)

    /// 旗標檔：config.json.protect（和設定檔同一個資料夾，跨行程、跨重開有效）
    static func protectionURL(for url: URL) -> URL { url.appendingPathExtension("protect") }

    /// 目前是否唯讀保護中（nil = 沒有）
    static func writeProtection(for url: URL = Config.fileURL) -> WriteProtection? {
        let f = protectionURL(for: url)
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        if let d = try? Data(contentsOf: f), let p = try? JSONDecoder().decode(WriteProtection.self, from: d) { return p }
        return WriteProtection(corruptBackup: "?", since: "?", error: "旗標檔無法解析")
    }

    private static func setWriteProtection(_ p: WriteProtection, for url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(p).write(to: protectionURL(for: url), options: .atomic)
    }

    /// 旗標檔是自己產生的小檔：直接刪（不丟垃圾桶）
    private static func clearWriteProtection(for url: URL) {
        try? FileManager.default.removeItem(at: protectionURL(for: url))
    }

    /// 壞檔改名成 <檔名>.corrupt-<yyyyMMdd-HHmmss>[-n]；失敗回 nil（原地保留）
    private static func quarantineCorrupt(_ url: URL) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = url.lastPathComponent + ".corrupt-" + f.string(from: Date())
        let dir = url.deletingLastPathComponent()
        var dest = dir.appendingPathComponent(base)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(base + "-\(n)"); n += 1
        }
        do { try FileManager.default.moveItem(at: url, to: dest); return dest } catch { return nil }
    }

    /// 警告：stderr（選單列 app 的 stderr 已導到 ~/Library/Logs/In_Unison42.log）
    static func logWarning(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }

    // MARK: 查詢（已夾在合法範圍內）

    func device(_ uid: String) -> DeviceConfig { devices[uid] ?? DeviceConfig() }

    /// 【舊版】第 1 版的補償延遲（ms），夾在 0...maxDelayMs。第 2 版的實際延遲請用 Engine.plan / plan()
    func effectiveDelayMs(_ uid: String) -> Double {
        let d = device(uid).delayMs
        return d.isFinite ? min(max(d, 0), Config.maxDelayMs) : 0
    }

    /// 生效 trim（dB），夾在 trimDbRange（第 2 版一律生效，與 levelMatch 無關）
    func effectiveTrimDb(_ uid: String) -> Double {
        let t = device(uid).trimDb
        return t.isFinite ? min(max(t, Config.trimDbRange.lowerBound), Config.trimDbRange.upperBound) : 0
    }

    /// 生效 trim 線性倍率
    func effectiveTrimGain(_ uid: String) -> Float {
        Float(pow(10, effectiveTrimDb(uid) / 20))
    }

    /// 實測延遲（ms），非有限值或負值視為未量測
    func measuredLatencyMs(_ uid: String) -> Double? {
        guard let v = device(uid).measuredLatencyMs, v.isFinite, v >= 0 else { return nil }
        return v
    }

    /// 啟動時的生效模式：手動模式直接用；auto 在還沒有前景 app 資訊時先用音樂（不限，不會少掉任何喇叭）
    var startupPlayMode: PlayMode { mode.fixed ?? .music }

    static func nowISO8601() -> String { ISO8601DateFormatter().string(from: Date()) }
}

/// 唯讀保護中，拒絕自動存檔
struct ConfigWriteProtectedError: Error, CustomStringConvertible {
    let protection: Config.WriteProtection
    var description: String {
        "設定檔唯讀保護中（先前的設定檔損壞，已保留為 \(protection.corruptBackup)）：不自動存檔，校正成功或按「重設設定」後恢復"
    }
}

/// 有鎖的小盒子（跨執行緒讀寫的全域狀態；Swift 6 並行檢查可接受）。不可在 IOProc 裡用（會上鎖）
final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
    /// 在鎖內改值並回傳結果
    func withLock<R>(_ f: (inout T) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try f(&v)
    }
}

// MARK: - 出聲計畫（純函式）

/// plan() 的輸入：一台候選輸出
struct PlanDevice: Equatable {
    let uid: String
    let name: String
    /// 相對最快裝置的實測延遲（ms）；nil = 未量測
    let latencyMs: Double?
    let enabled: Bool
    /// 內建喇叭：未量測時視為 0（它本來就是最快的）
    let isBuiltIn: Bool
    /// 未量測就不出聲（任何模式）：藍牙只輸出路徑。A2DP 本身延遲約 100–200 ms，不補償直接出聲會比其他喇叭慢一百多毫秒（回音）
    let requiresMeasurement: Bool
    /// 量過之後重新連線過（藍牙）：延遲值可能過時。silenceAfterReconnect = false 時照舊出聲（理由註明），true 時不出聲
    let needsRecalibration: Bool
    /// 【2026-09-29 自動校正】app 重開後等待重新校正（Config.calibrationHolds，只對 requiresMeasurement）：不出聲
    let awaitingCalibration: Bool

    init(uid: String, name: String, latencyMs: Double?, enabled: Bool = true, isBuiltIn: Bool = false, requiresMeasurement: Bool = false,
         needsRecalibration: Bool = false, awaitingCalibration: Bool = false) {
        self.uid = uid; self.name = name; self.latencyMs = latencyMs; self.enabled = enabled; self.isBuiltIn = isBuiltIn
        self.requiresMeasurement = requiresMeasurement
        self.needsRecalibration = needsRecalibration
        self.awaitingCalibration = awaitingCalibration
    }

    /// 從設定組出來（name/isBuiltIn/requiresMeasurement 由呼叫端給）
    init(uid: String, name: String, isBuiltIn: Bool, requiresMeasurement: Bool = false, config: Config) {
        self.init(uid: uid, name: name, latencyMs: config.measuredLatencyMs(uid),
                  enabled: config.device(uid).enabled, isBuiltIn: isBuiltIn, requiresMeasurement: requiresMeasurement,
                  needsRecalibration: requiresMeasurement && config.device(uid).needsRecalibration,
                  awaitingCalibration: requiresMeasurement && config.calibrationHolds.contains(uid))
    }
}

/// plan() 的輸出：一台輸出要不要出聲、延遲多少、為什麼
struct PlanEntry: Equatable, CustomStringConvertible {
    let active: Bool
    /// 補償延遲（ms，0...Config.maxDelayMs）：讓快的等慢的。不出聲的裝置為 0
    let delayMs: Double
    let reason: String

    /// 自動校正暫停出聲（app 重開後的藍牙）的理由
    static let awaitingCalibrationReason = "等待重新校正：藍牙重新連線（或 app 重新啟動）後延遲可能改變，校正完成前先不出聲"

    var description: String {
        active ? String(format: "出聲 延遲 %.2f ms（%@）", delayMs, reason) : "不出聲（\(reason)）"
    }
}

/// 依模式決定每台輸出是否出聲與補償延遲。規則：
/// 1. enabled=false → 不出聲（已關閉）
/// 2. 延遲 = measuredLatencyMs；未量測時內建喇叭視為 0，其他裝置在有上限的模式（影片/遊戲）不出聲、音樂模式出聲但不補償；
///    requiresMeasurement（藍牙）未量測 → 任何模式都不出聲（理由含「未校正」）
/// 3. 基準 = 啟用且有延遲值的裝置裡最快的；相對延遲 = 延遲 − 基準
/// 4. 相對延遲 > 模式上限 → 不出聲；> Config.maxDelayMs（延遲線補不到）→ 不出聲
/// 5. 補償只在出聲的裝置間重算：delayMs = 出聲裝置最大相對延遲 − 自己的相對延遲
/// 6. 保底：有啟用的裝置但算完一台都不出聲（全部未量測）→ 啟用的全部出聲、延遲 0
/// 8. awaitingCalibration（自動校正：app 重開後的藍牙，Config.calibrationHolds）→ 不出聲、不算進基準（保底規則照舊）
/// 7. needsRecalibration（藍牙重連後）：silenceAfterReconnect = true → 不出聲（理由「重新連線後需要重新校正」）；
///    false → 照舊值參與，出聲時理由加註「重新連線後未重新校正」
func plan(devices: [PlanDevice], mode: PlayMode, caps: ModeCaps = ModeCaps(),
          maxDelayMs: Double = Config.maxDelayMs,
          silenceAfterReconnect: Bool = Config.silenceBluetoothAfterReconnect) -> [String: PlanEntry] {
    let cap = caps.cap(mode)
    let capText = cap.isFinite ? String(format: "%@模式上限 %.0f ms", mode.label, cap) : "\(mode.label)模式不限延遲"
    func lat(_ d: PlanDevice) -> Double? {
        if let v = d.latencyMs, v.isFinite, v >= 0 { return v }
        return d.isBuiltIn ? 0 : nil
    }
    let enabled = devices.filter(\.enabled)
    let base = enabled.compactMap(lat).min() ?? 0

    var result: [String: PlanEntry] = [:]
    var activeRel: [String: Double] = [:]      // 出聲且有延遲值的裝置 → 相對延遲
    var activeUnknown: [String] = []           // 出聲但未量測（只在不限延遲的模式）
    for d in devices {
        guard d.enabled else { result[d.uid] = PlanEntry(active: false, delayMs: 0, reason: "已關閉"); continue }
        if d.awaitingCalibration && d.requiresMeasurement {
            result[d.uid] = PlanEntry(active: false, delayMs: 0, reason: PlanEntry.awaitingCalibrationReason)
            continue
        }
        if d.needsRecalibration && silenceAfterReconnect && d.requiresMeasurement {
            result[d.uid] = PlanEntry(active: false, delayMs: 0, reason: "未校正：重新連線後延遲可能改變，需要重新校正")
            continue
        }
        guard let l = lat(d) else {
            if d.requiresMeasurement {
                result[d.uid] = PlanEntry(active: false, delayMs: 0,
                                          reason: "未校正：藍牙延遲未量測（不補償直接出聲會比其他喇叭慢上百毫秒）")
            } else if cap.isFinite {
                result[d.uid] = PlanEntry(active: false, delayMs: 0, reason: "未量測延遲，\(capText)")
            } else {
                activeUnknown.append(d.uid)
            }
            continue
        }
        let rel = l - base
        if rel > cap + 1e-9 {
            result[d.uid] = PlanEntry(active: false, delayMs: 0,
                                      reason: String(format: "相對延遲 +%.2f ms 超過%@", rel, capText))
        } else if rel > maxDelayMs + 1e-9 {
            result[d.uid] = PlanEntry(active: false, delayMs: 0,
                                      reason: String(format: "相對延遲 +%.2f ms 超過延遲線上限 %.0f ms", rel, maxDelayMs))
        } else {
            activeRel[d.uid] = rel
        }
    }
    let maxRel = activeRel.values.max() ?? 0
    let stale = Set(devices.filter(\.needsRecalibration).map(\.uid))
    for (uid, rel) in activeRel {
        var why = rel <= 1e-9 ? "最快（基準）" : String(format: "相對延遲 +%.2f ms，%@", rel, capText)
        if stale.contains(uid) { why += "；重新連線後未重新校正，沿用舊值" }
        result[uid] = PlanEntry(active: true, delayMs: min(max(maxRel - rel, 0), maxDelayMs), reason: why)
    }
    for uid in activeUnknown {
        result[uid] = PlanEntry(active: true, delayMs: 0, reason: "未量測延遲，不補償")
    }
    // 保底：一台都沒出聲，但有啟用的裝置（例如全部未量測、又在遊戲模式）。只有單獨一台時藍牙也可以（沒有別台就沒有回音）
    let fallback = enabled.count == 1 ? enabled : enabled.filter { !$0.requiresMeasurement }
    if !fallback.isEmpty, !result.values.contains(where: \.active) {
        for d in fallback { result[d.uid] = PlanEntry(active: true, delayMs: 0, reason: "未量測延遲（保底：沒有其他裝置可出聲）") }
    }
    return result
}

// MARK: - plan() 單元測試（`In_Unison42 plan-selftest`）

func runPlanSelfTest() -> Int32 {
    var fail = 0
    func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "（\(detail)）")")
        if !ok { fail += 1 }
    }
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }
    let builtin = "BuiltInSpeakerDevice", msi = "3669B030-0000-0000-1B21-010380341E78", tv = "40C88240-0000-0000-151D-010380593278"
    // 2026-09-28 實測：內建 0、MSI +1.26、電視 +34.46
    let devs = [PlanDevice(uid: builtin, name: "內建", latencyMs: 0, isBuiltIn: true),
                PlanDevice(uid: msi, name: "MSI", latencyMs: 1.26),
                PlanDevice(uid: tv, name: "電視", latencyMs: 34.46)]
    func show(_ p: [String: PlanEntry]) -> String {
        [builtin, msi, tv].compactMap { u in p[u].map { "\(u.prefix(4)):\($0.active ? "on" : "off")/\(String(format: "%.2f", $0.delayMs))" } }
            .joined(separator: " ")
    }

    print("── 1. 音樂（不限）：三台都出聲，補償 34.46／33.20／0 ──")
    var p = plan(devices: devs, mode: .music)
    check(p[builtin]!.active && p[msi]!.active && p[tv]!.active, "三台出聲", show(p))
    check(near(p[builtin]!.delayMs, 34.46) && near(p[msi]!.delayMs, 33.2) && near(p[tv]!.delayMs, 0), "延遲 = 最慢 − 自己", show(p))

    print("── 2. 影片（80 ms）：電視 +34.46 ≤ 80 → 三台都出聲，同音樂 ──")
    p = plan(devices: devs, mode: .movie)
    check(p.values.allSatisfy(\.active), "三台出聲", show(p))
    check(near(p[builtin]!.delayMs, 34.46) && near(p[msi]!.delayMs, 33.2) && near(p[tv]!.delayMs, 0), "延遲 34.46／33.20／0", show(p))

    print("── 3. 遊戲（20 ms）：電視 +34.46 > 20 → 不出聲；補償只在內建＋MSI 間重算 ──")
    p = plan(devices: devs, mode: .game)
    check(p[builtin]!.active && p[msi]!.active && !p[tv]!.active, "內建、MSI 出聲；電視不出聲", show(p))
    check(near(p[builtin]!.delayMs, 1.26) && near(p[msi]!.delayMs, 0) && p[tv]!.delayMs == 0, "延遲 1.26／0／0", show(p))
    check(p[tv]!.reason.contains("超過"), "電視理由含「超過」", p[tv]!.reason)

    print("── 4. 關掉內建：遊戲模式基準改成 MSI，電視 +33.20 仍超過 → 只剩 MSI、延遲 0 ──")
    var d2 = devs; d2[0] = PlanDevice(uid: builtin, name: "內建", latencyMs: 0, enabled: false, isBuiltIn: true)
    p = plan(devices: d2, mode: .game)
    check(!p[builtin]!.active && p[msi]!.active && !p[tv]!.active && near(p[msi]!.delayMs, 0), "只剩 MSI", show(p))
    p = plan(devices: d2, mode: .movie)
    check(!p[builtin]!.active && near(p[msi]!.delayMs, 33.2) && near(p[tv]!.delayMs, 0), "影片：MSI 等電視 33.20", show(p))

    print("── 5. 未量測：內建視為 0；其他裝置影片/遊戲不出聲、音樂出聲不補償 ──")
    let d3 = [PlanDevice(uid: builtin, name: "內建", latencyMs: nil, isBuiltIn: true),
              PlanDevice(uid: msi, name: "MSI", latencyMs: nil)]
    p = plan(devices: d3, mode: .game)
    check(p[builtin]!.active && !p[msi]!.active && p[builtin]!.delayMs == 0, "遊戲：只有內建", show(p))
    p = plan(devices: d3, mode: .music)
    check(p[builtin]!.active && p[msi]!.active && p[msi]!.delayMs == 0, "音樂：兩台都出聲、不補償", show(p))
    p = plan(devices: [PlanDevice(uid: msi, name: "MSI", latencyMs: nil)], mode: .game)
    check(p[msi]!.active, "保底：唯一裝置未量測也出聲", show(p))

    print("── 5b. 藍牙（requiresMeasurement）未量測：任何模式都不出聲、理由含「未校正」；量過就照常參與 ──")
    let bt = PlanDevice(uid: "bt", name: "GLASS5+", latencyMs: nil, requiresMeasurement: true)
    for m in PlayMode.allCases {
        p = plan(devices: devs + [bt], mode: m)
        check(!p["bt"]!.active && p["bt"]!.reason.contains("未校正"), "\(m.label)：藍牙不出聲", p["bt"]!.reason)
        check(p[builtin]!.active && p[builtin]!.delayMs == plan(devices: devs, mode: m)[builtin]!.delayMs, "\(m.label)：其他裝置補償不受影響", show(p))
    }
    p = plan(devices: devs + [PlanDevice(uid: "bt", name: "GLASS5+", latencyMs: 150, requiresMeasurement: true)], mode: .music)
    check(p["bt"]!.active && near(p[builtin]!.delayMs, 150) && near(p["bt"]!.delayMs, 0), "音樂：量過 150 ms → 出聲，內建等它 150 ms", show(p))
    p = plan(devices: [PlanDevice(uid: builtin, name: "內建", latencyMs: 0, enabled: false, isBuiltIn: true), bt], mode: .music)
    check(p["bt"]!.active, "只剩藍牙一台：保底出聲（沒有別台，不會有回音）")

    print("── 5c. 藍牙重新連線後（needsRecalibration）：沿用舊值出聲＋理由註明；政策改成靜音時不出聲 ──")
    let btStale = PlanDevice(uid: "bt", name: "GLASS5+", latencyMs: 200, requiresMeasurement: true, needsRecalibration: true)
    p = plan(devices: devs + [btStale], mode: .music, silenceAfterReconnect: false)
    check(p["bt"]!.active && p["bt"]!.reason.contains("重新連線") && near(p[builtin]!.delayMs, 200), "沿用舊值：出聲、理由含「重新連線」、內建等 200 ms", p["bt"]!.description)
    p = plan(devices: devs + [btStale], mode: .music, silenceAfterReconnect: true)
    check(!p["bt"]!.active && p["bt"]!.reason.contains("重新校正") && near(p[builtin]!.delayMs, 34.46), "靜音政策：不出聲、其他照三台補償", p["bt"]!.description)
    p = plan(devices: devs + [btStale], mode: .movie, silenceAfterReconnect: false)
    check(!p["bt"]!.active && p["bt"]!.reason.contains("超過"), "影片：藍牙 +200 ms 超過 80 ms 上限 → 不出聲", p["bt"]!.reason)
    var cfgStale = Config(); cfgStale.devices["bt"] = DeviceConfig(measuredLatencyMs: 200, needsRecalibration: true)
    check(PlanDevice(uid: "bt", name: "b", isBuiltIn: false, requiresMeasurement: true, config: cfgStale).needsRecalibration
          && !PlanDevice(uid: "bt", name: "b", isBuiltIn: false, requiresMeasurement: false, config: cfgStale).needsRecalibration,
          "PlanDevice 由設定帶出 needsRecalibration（只對藍牙）")
    let cfgRT = try! JSONDecoder().decode(Config.self, from: try! JSONEncoder().encode(cfgStale))
    check(cfgRT.device("bt").needsRecalibration, "needsRecalibration 存檔讀回")
    let (cfgCal, _) = applyCalibrationResult(to: cfgStale, measuredRel: ["bt": 180], trims: nil, mode: .music,
                                             devices: [(uid: "bt", name: "b", isBuiltIn: false)])
    check(!cfgCal.device("bt").needsRecalibration && cfgCal.measuredLatencyMs("bt") == 180, "校正寫入新值 → 清掉「需要重新校正」")

    print("── 5d. 自動校正暫停出聲（calibrationHolds，app 重開後的藍牙）：不出聲、其他照三台補償；不存檔 ──")
    let btHeld = PlanDevice(uid: "bt", name: "GLASS5+", latencyMs: 413.6, requiresMeasurement: true, awaitingCalibration: true)
    p = plan(devices: devs + [btHeld], mode: .music)
    check(!p["bt"]!.active && p["bt"]!.reason == PlanEntry.awaitingCalibrationReason && near(p[builtin]!.delayMs, 34.46),
          "藍牙不出聲、內建不必等藍牙（補償 34.46）", p["bt"]!.description)
    var cfgHold = Config(); cfgHold.devices["bt"] = DeviceConfig(measuredLatencyMs: 413.6); cfgHold.calibrationHolds = ["bt", builtin]
    check(PlanDevice(uid: "bt", name: "b", isBuiltIn: false, requiresMeasurement: true, config: cfgHold).awaitingCalibration
          && !PlanDevice(uid: builtin, name: "內建", isBuiltIn: true, config: cfgHold).awaitingCalibration,
          "PlanDevice 由設定帶出 awaitingCalibration（只對藍牙）")
    let holdJSON = String(decoding: try! JSONEncoder().encode(cfgHold), as: UTF8.self)
    let cfgHoldRT = try! JSONDecoder().decode(Config.self, from: holdJSON.data(using: .utf8)!)
    check(!holdJSON.contains("calibrationHolds") && cfgHoldRT.calibrationHolds.isEmpty && cfgHoldRT.measuredLatencyMs("bt") == 413.6,
          "calibrationHolds 不寫進 config.json")

    print("── 6. 延遲線上限：音樂模式相對 1200 ms（AirPlay 類）→ 不出聲 ──")
    p = plan(devices: [devs[0], PlanDevice(uid: "air", name: "AirPlay", latencyMs: 1200)], mode: .music)
    check(p[builtin]!.active && !p["air"]!.active && p[builtin]!.delayMs == 0, "AirPlay 不出聲、內建不必等", "\(p["air"]!)")

    print("── 7. 舊設定反推 measuredLatencyMs（delayMs 34.46／33.2／0）──")
    let old = """
    {"calibratedAt":"2026-09-28T09:18:54Z","devices":{"\(msi)":{"delayMs":33.2,"trimDb":-3},"\(tv)":{"delayMs":0,"trimDb":0},"\(builtin)":{"delayMs":34.46,"trimDb":0}},"levelMatch":false}
    """
    let c = try! JSONDecoder().decode(Config.self, from: old.data(using: .utf8)!)
    check(near(c.measuredLatencyMs(builtin) ?? -1, 0) && near(c.measuredLatencyMs(msi) ?? -1, 1.26) && near(c.measuredLatencyMs(tv) ?? -1, 34.46),
          "反推 0／1.26／34.46", "\(c.measuredLatencyMs(builtin) ?? -1)/\(c.measuredLatencyMs(msi) ?? -1)/\(c.measuredLatencyMs(tv) ?? -1)")
    check(c.device(msi).trimDb == 0, "levelMatch=false 的舊 trim 歸 0（本來就沒生效）")
    check(c.mode == .auto && !c.manualLock && c.autoModeRules["com.colliderli.iina"] == .movie && c.modeCaps.cap(.game) == 20 && c.modeCaps.cap(.music) == .infinity,
          "新欄位預設值")
    check(c.devices.values.allSatisfy(\.enabled), "enabled 預設 true")
    let enc = try! JSONEncoder().encode(c)
    let c2 = try! JSONDecoder().decode(Config.self, from: enc)
    check(c2 == c, "第 2 版存檔再讀回相同（不會再次遷移）")
    let fresh = try! JSONDecoder().decode(Config.self, from: "{}".data(using: .utf8)!)
    check(fresh.devices.isEmpty && fresh.version == 2, "空檔 → 預設值")
    check(fresh.monitorEnabled && fresh.monitorIntervalSec == 300 && fresh.monitorCaptureSec == 10, "背景監聽預設：開、300 秒、10 秒")
    var mon = Config(); mon.monitorEnabled = false; mon.monitorIntervalSec = 5; mon.monitorCaptureSec = 99
    let monRT = try! JSONDecoder().decode(Config.self, from: try! JSONEncoder().encode(mon))
    check(!monRT.monitorEnabled && monRT.effectiveMonitorIntervalSec == 60 && monRT.effectiveMonitorCaptureSec == 20,
          "背景監聽設定存檔讀回＋生效值夾在範圍內（間隔 ≥ 60 秒、每輪 ≤ 20 秒）")

    print(fail == 0 ? "✓ plan 自測全部通過" : "✗ \(fail) 項失敗")
    return fail == 0 ? 0 : 1
}

// MARK: - 設定檔損壞保護自測（`In_Unison42 config-selftest`；只動暫存資料夾，不碰真的設定檔）

func runConfigSelfTest() -> Int32 {
    var fail = 0
    func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "（\(detail)）")")
        if !ok { fail += 1 }
    }
    let fm = FileManager.default
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("In_Unison42-config-selftest-\(getpid())", isDirectory: true)
    // 自己產生的暫存資料夾：測完直接刪（FileManager.removeItem）
    defer { try? fm.removeItem(at: dir) }
    try? fm.removeItem(at: dir)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("config.json")
    func corrupts() -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("config.json.corrupt-") }.sorted()
    }

    print("── 1. 沒有設定檔：預設值、沒有保護、可以存 ──")
    var c = Config.load(from: url)
    check(c == Config() && Config.writeProtection(for: url) == nil, "預設值、無保護")
    c.mode = .game
    check((try? c.save(to: url)) != nil && Config.load(from: url).mode == .game, "一般存檔讀回")

    print("── 2. 設定檔損壞：改名保留＋唯讀保護 ──")
    let garbage = Data("{\"devices\": {\"x\": {\"measuredLatencyMs\": 12.5,".utf8)
    try? garbage.write(to: url)
    c = Config.load(from: url)
    check(c == Config(), "改用預設值")
    check(!fm.fileExists(atPath: url.path), "原檔名已移開（config.json 不存在）")
    let cs = corrupts()
    check(cs.count == 1 && (try? Data(contentsOf: dir.appendingPathComponent(cs.first ?? "-"))) == garbage,
          "壞檔改名為 config.json.corrupt-<時間戳>、內容不變", cs.joined(separator: ","))
    let p = Config.writeProtection(for: url)
    check(p != nil && p!.corruptBackup.hasSuffix(cs.first ?? "?"), "唯讀保護旗標（config.json.protect）", p?.corruptBackup ?? "nil")

    print("── 3. 保護中：自動存檔被拒絕、重開（再 load）仍保護 ──")
    var auto = Config(); auto.mode = .movie
    var threw = false
    do { try auto.save(to: url) } catch is ConfigWriteProtectedError { threw = true } catch {}
    check(threw && !fm.fileExists(atPath: url.path), "save() 丟 ConfigWriteProtectedError、沒寫檔")
    check(Config.load(from: url) == Config() && Config.writeProtection(for: url) != nil, "再讀一次：仍是預設值、仍保護")
    check(corrupts().count == 1, "壞檔沒有被動到（仍 1 份）")

    print("── 4. 行程層級明確操作（calibrate 子行程）：可寫、解除保護 ──")
    let prev = Config.explicitWritesAllowed
    Config.explicitWritesAllowed = true
    var cal = Config(); cal.devices["bt"] = DeviceConfig(measuredLatencyMs: 413.6)
    check((try? cal.save(to: url)) != nil, "校正成功寫入")
    Config.explicitWritesAllowed = prev
    check(Config.writeProtection(for: url) == nil && Config.load(from: url).measuredLatencyMs("bt") == 413.6, "保護解除、值讀回")

    print("── 5. 再壞一次 → 按「重設設定」（resetToDefaults）解除 ──")
    try? garbage.write(to: url)
    _ = Config.load(from: url)
    check(Config.writeProtection(for: url) != nil && corrupts().count == 2, "第二次損壞：再保留一份壞檔", corrupts().joined(separator: ","))
    check((try? Config.resetToDefaults(at: url)) != nil && Config.writeProtection(for: url) == nil, "重設 → 解除保護")
    check(Config.load(from: url) == Config() && fm.fileExists(atPath: url.path), "重設後是預設值設定檔")
    var after = Config(); after.mode = .music
    check((try? after.save(to: url)) != nil, "解除後一般存檔恢復")

    print("── 6. 保護中但使用者自己把好的設定檔放回來 → 讀到就解除 ──")
    try? garbage.write(to: url)
    _ = Config.load(from: url)
    var good = Config(); good.mode = .movie
    let enc = JSONEncoder()
    try? enc.encode(good).write(to: url)
    check(Config.load(from: url).mode == .movie && Config.writeProtection(for: url) == nil, "好的設定檔 → 讀入、解除保護")

    print(fail == 0 ? "✓ config 自測全部通過" : "✗ \(fail) 項失敗")
    return fail == 0 ? 0 : 1
}
