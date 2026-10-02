// ModeManager.swift — 依前景 app 自動切換模式（owner：模式）
//
// 行為規格（第一期，已與 Kang 定案）：
// * config.mode == .auto 且 !config.manualLock：前景 app 改變時 → ModeRules.resolve → onResolvedModeChange(mode, reason)
// * 手動選模式（AppState.selectMode(.music/.movie/.game)）= 鎖定：ModeManager 不送任何事件，直到使用者按回「自動」
//   （AppState.selectMode(.auto) 會呼叫 reevaluate()）
// * 對照表：config.autoModeRules（bundle id → 模式，可在面板設定）；預設見 Config.defaultAutoModeRules
//   另外 LSApplicationCategoryType 是 public.app-category.*games 的 app → 遊戲；Steam 遊戲庫（steamapps/common）裡的 app → 遊戲
// * 都不符合 → 音樂（不限延遲，所有喇叭都出聲）
//
// 實作：
// * 判斷邏輯全部在純值型別 ModeDecider（虛擬時間，mode-selftest 直接驅動）；ModeManager 只負責接 NSWorkspace 通知與計時器。
// * 去抖動 1 秒（trailing）：Cmd-Tab 掃過一串 app 時只看最後停下來的那個。啟動時與 reevaluate() 立即送、不等。
// * 自己（com.kang.In-Unison42，面板打開時會變前景）忽略：不改模式、也不取消已排定的切換。
// * 送出條件：(模式, 理由) 與上次送出的不同。同模式換 app 只更新理由（AppState.applyResolvedMode → engine.setMode 同模式是 no-op）。
// * 鎖定判斷 = 記憶體裡的設定（start/update 給的）或 config.json 任一個是鎖定。
//   原因：AppState.selectMode 只存檔、沒有呼叫 modeManager.update(config:)，所以記憶體那份可能是舊的；
//   config.json 是 AppState.updateConfig 每次都先寫的，拿來補。reevaluate()（只有按回「自動」時呼叫）會把記憶體那份改成自動。
import AppKit
import Foundation

/// 前景 app 的摘要（測試時可手造）
struct FrontApp: Equatable {
    let bundleID: String?
    let name: String
    /// Info.plist 的 LSApplicationCategoryType（例如 public.app-category.action-games）
    let categoryType: String?
    /// app bundle 路徑（Steam 遊戲庫判斷用）；nil = 不知道
    var bundlePath: String? = nil
}

enum ModeRules {
    static let ownBundleID = "com.kang.In-Unison42"

    /// Steam 遊戲庫：~/Library/Application Support/Steam/steamapps/common/<遊戲>/…（大小寫不拘）
    static func isSteamLibraryPath(_ p: String?) -> Bool {
        guard let p else { return false }
        return p.lowercased().contains("/steamapps/common/")
    }

    /// 對照表查詢：先精確、再不分大小寫（bundle id 在系統裡不分大小寫）。值是 .auto 的項目視為沒有列
    static func lookup(_ bundleID: String?, rules: [String: AudioMode]) -> PlayMode? {
        guard let b = bundleID, !b.isEmpty else { return nil }
        if let m = rules[b] { return m.fixed }
        let lb = b.lowercased()
        for (k, v) in rules where k.lowercased() == lb { return v.fixed }
        return nil
    }

    static func isGameCategory(_ c: String?) -> Bool {
        guard let c = c?.lowercased() else { return false }
        return c.hasPrefix("public.app-category.") && c.hasSuffix("games")
    }

    /// 純函式：前景 app → 模式與理由。對照表優先，其次遊戲類別／Steam 遊戲庫，否則音樂
    static func resolve(_ app: FrontApp?, rules: [String: AudioMode]) -> (mode: PlayMode, reason: String) {
        guard let app else { return (.music, "沒有前景 app") }
        if let m = lookup(app.bundleID, rules: rules) {
            return (m, "前景 \(app.name)（對照表：\(m.label)）")
        }
        if isGameCategory(app.categoryType), let c = app.categoryType {
            return (.game, "前景 \(app.name)（類別 \(c.lowercased())）")
        }
        if isSteamLibraryPath(app.bundlePath) {
            return (.game, "前景 \(app.name)（Steam 遊戲庫）")
        }
        return (.music, "前景 \(app.name)（未列入對照表）")
    }

    static func isOwn(_ app: FrontApp?) -> Bool {
        guard let b = app?.bundleID else { return false }
        return b.caseInsensitiveCompare(ownBundleID) == .orderedSame
    }
}

// MARK: - 純邏輯：去抖動＋鎖定＋去重（虛擬時間）

struct ModeDecision: Equatable {
    let mode: PlayMode
    let reason: String
}

struct ModeDecider {
    /// 去抖動秒數（前景 app 停留這麼久才切換）
    var debounce: Double = 1.0
    private(set) var pending: (decision: ModeDecision, due: Double)?
    private(set) var lastSent: ModeDecision?
    /// 最近一個非自己的前景 app
    private(set) var lastApp: FrontApp?

    init(debounce: Double = 1.0) { self.debounce = debounce }

    static func isLocked(_ c: Config) -> Bool { c.manualLock || c.mode != .auto }

    /// 前景 app 改變。回傳 true = 已排定（或更新）一次切換
    @discardableResult
    mutating func activate(_ app: FrontApp?, now: Double, config: Config) -> Bool {
        if ModeRules.isOwn(app) { return false }          // 自己：完全忽略
        lastApp = app
        if Self.isLocked(config) { pending = nil; return false }
        let r = ModeRules.resolve(app, rules: config.autoModeRules)
        let d = ModeDecision(mode: r.mode, reason: r.reason)
        if d == lastSent { pending = nil; return false }  // 回到目前狀態：取消排定
        pending = (d, now + debounce)
        return true
    }

    /// 計時器到期時呼叫；到期且未鎖定 → 回傳要送出的決定
    mutating func fire(now: Double, config: Config) -> ModeDecision? {
        guard let p = pending, now >= p.due - 1e-9 else { return nil }
        pending = nil
        if Self.isLocked(config) { return nil }
        let d = ModeRules.resolve(lastApp, rules: config.autoModeRules)
        let dec = ModeDecision(mode: d.mode, reason: d.reason)   // 用最新對照表重算
        guard dec != lastSent else { return nil }
        lastSent = dec
        return dec
    }

    /// 立即判斷（啟動、按回「自動」、對照表改了）：不等去抖動。force = 即使和上次相同也送
    mutating func evaluateNow(_ app: FrontApp?, config: Config, force: Bool) -> ModeDecision? {
        if !ModeRules.isOwn(app) { lastApp = app }
        pending = nil
        if Self.isLocked(config) { return nil }
        let r = ModeRules.resolve(lastApp, rules: config.autoModeRules)
        let d = ModeDecision(mode: r.mode, reason: r.reason)
        if !force && d == lastSent { return nil }
        lastSent = d
        return d
    }

    /// 鎖定時呼叫：下次解鎖要重新送（engine 的模式已被手動改掉）
    mutating func forgetLastSent() { lastSent = nil; pending = nil }
}

// MARK: - 前景 app 讀取（NSWorkspace）

enum FrontAppReader {
    private static var categoryCache: [String: String?] = [:]

    static func frontApp(_ app: NSRunningApplication?) -> FrontApp? {
        guard let app else { return nil }
        let bid = app.bundleIdentifier
        let path = app.bundleURL?.path
        return FrontApp(bundleID: bid, name: app.localizedName ?? bid ?? "pid \(app.processIdentifier)",
                        categoryType: category(bundleID: bid, url: app.bundleURL), bundlePath: path)
    }

    /// Info.plist 的 LSApplicationCategoryType；快取 by bundle id（主執行緒用）
    static func category(bundleID: String?, url: URL?) -> String? {
        if let b = bundleID, let c = categoryCache[b] { return c }
        var c: String?
        if let url, let info = Bundle(url: url)?.infoDictionary {
            c = info["LSApplicationCategoryType"] as? String
        }
        if let b = bundleID { categoryCache[b] = c }
        return c
    }

    static func current() -> FrontApp? { frontApp(NSWorkspace.shared.frontmostApplication) }
}

// MARK: - ModeManager

@MainActor
final class ModeManager {
    /// 自動模式算出新模式時呼叫（主執行緒）；reason 給面板顯示
    var onResolvedModeChange: ((PlayMode, String) -> Void)?
    /// 讀 config.json（鎖定狀態的第二來源）；測試可換掉
    var readDiskConfig: () -> Config? = {
        FileManager.default.fileExists(atPath: Config.fileURL.path) ? Config.load() : nil
    }
    /// log（預設不印；AppState 可接 AppLog.line）
    var log: ((String) -> Void)?

    private(set) var config = Config()
    private(set) var frontApp: FrontApp?
    private(set) var decider = ModeDecider(debounce: 1.0)
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private let t0 = Date()

    init() {}

    var lastSent: PlayMode? { decider.lastSent?.mode }
    var lastReason: String? { decider.lastSent?.reason }

    private var now: Double { Date().timeIntervalSince(t0) }

    /// 記憶體設定＋config.json：任一個鎖定就算鎖定；對照表用記憶體那份
    private func effectiveConfig() -> Config {
        var c = config
        if let d = readDiskConfig(), ModeDecider.isLocked(d) {
            c.mode = d.mode
            c.manualLock = d.manualLock
        }
        return c
    }

    /// 訂閱前景 app 變更並做第一次判斷（立即送）
    func start(config: Config) {
        self.config = config
        if observer == nil {
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.handleActivation(FrontAppReader.frontApp(app)) }
            }
        }
        let fa = FrontAppReader.current()
        if !ModeRules.isOwn(fa) { frontApp = fa }
        send(decider.evaluateNow(fa, config: effectiveConfig(), force: true))
    }

    /// 取消訂閱
    func stop() {
        if let o = observer { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observer = nil
        timer?.invalidate(); timer = nil
    }

    /// 設定改了（對照表、mode、manualLock）
    func update(config: Config) {
        let old = self.config
        self.config = config
        let c = effectiveConfig()
        if ModeDecider.isLocked(c) {
            decider.forgetLastSent()
            timer?.invalidate(); timer = nil
            return
        }
        // 從鎖定變成自動，或對照表改了：立即依目前前景 app 重算（相同就不送）
        let wasLocked = ModeDecider.isLocked(old)
        if wasLocked || old.autoModeRules != config.autoModeRules {
            send(decider.evaluateNow(frontApp, config: c, force: wasLocked))
        }
    }

    /// 立刻依目前前景 app 重算並送出（按回「自動」時呼叫）。自己在前景（面板開著）時用上一個前景 app
    func reevaluate() {
        // 只有按回「自動」會呼叫：AppState.selectMode 沒有先 update(config:)，這裡把記憶體那份改成自動
        config.mode = .auto
        config.manualLock = false
        let fa = FrontAppReader.current()
        if !ModeRules.isOwn(fa) { frontApp = fa }
        timer?.invalidate(); timer = nil
        send(decider.evaluateNow(frontApp, config: effectiveConfig(), force: true))
    }

    // MARK: 內部

    func handleActivation(_ app: FrontApp?) {
        if ModeRules.isOwn(app) { return }
        frontApp = app
        let c = effectiveConfig()
        if ModeDecider.isLocked(c) { decider.forgetLastSent(); return }
        guard decider.activate(app, now: now, config: c), let due = decider.pending?.due else {
            if decider.pending == nil { timer?.invalidate(); timer = nil }
            return
        }
        timer?.invalidate()
        let t = Timer(timeInterval: max(0, due - now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func timerFired() {
        timer = nil
        send(decider.fire(now: now + 1e-6, config: effectiveConfig()))
    }

    private func send(_ d: ModeDecision?) {
        guard let d else { return }
        log?("自動模式 → \(d.mode.label)：\(d.reason)")
        onResolvedModeChange?(d.mode, d.reason)
    }
}

// MARK: - 自測

/// `In_Unison42 mode-selftest`：ModeRules／ModeDecider 單元測試（虛擬時間；不出聲、不碰前景 app）
func runModeSelfTest() -> Int32 {
    var pass = 0, fail = 0
    func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        if ok { pass += 1; print("  ✓ \(name)") } else { fail += 1; print("  ✗ \(name) \(detail)") }
    }
    let rules = Config.defaultAutoModeRules
    func app(_ b: String?, _ n: String, cat: String? = nil, path: String? = nil) -> FrontApp {
        FrontApp(bundleID: b, name: n, categoryType: cat, bundlePath: path)
    }
    let iina = app("com.colliderli.iina", "IINA")
    let qt = app("com.apple.QuickTimePlayerX", "QuickTime Player")
    let steam = app("com.valvesoftware.steam", "Steam")
    let safari = app("com.apple.Safari", "Safari")
    let finder = app("com.apple.finder", "Finder")
    let chess = app("com.apple.Chess", "Chess", cat: "public.app-category.board-games")
    let games = app("com.example.game", "SomeGame", cat: "public.app-category.games")
    let action = app("com.example.act", "Act", cat: "Public.App-Category.Action-Games")
    let steamGame = app("com.example.portal", "Portal 2",
                        path: "/Users/x/Library/Application Support/Steam/steamapps/common/Portal 2/portal2.app")
    let me = app(ModeRules.ownBundleID, "In_Unison42")

    print("ModeRules.resolve")
    check(ModeRules.resolve(iina, rules: rules).mode == .movie, "IINA → 影片")
    check(ModeRules.resolve(qt, rules: rules).mode == .movie, "QuickTime → 影片")
    for b in ["org.videolan.vlc", "com.firecore.infuse", "com.netflix.Netflix", "com.apple.TV", "io.mpv"] {
        check(ModeRules.resolve(app(b, b), rules: rules).mode == .movie, "\(b) → 影片")
    }
    check(ModeRules.resolve(steam, rules: rules).mode == .game, "Steam → 遊戲")
    check(ModeRules.resolve(games, rules: rules).mode == .game, "public.app-category.games → 遊戲")
    check(ModeRules.resolve(chess, rules: rules).mode == .game, "board-games 子類別 → 遊戲")
    check(ModeRules.resolve(action, rules: rules).mode == .game, "類別大小寫不拘 → 遊戲")
    check(ModeRules.resolve(steamGame, rules: rules).mode == .game, "Steam 遊戲庫路徑 → 遊戲")
    check(ModeRules.resolve(safari, rules: rules).mode == .music, "Safari → 音樂")
    check(ModeRules.resolve(app(nil, "無 bundle id"), rules: rules).mode == .music, "沒有 bundle id → 音樂")
    check(ModeRules.resolve(nil, rules: rules).mode == .music, "沒有前景 app → 音樂")
    check(ModeRules.resolve(app("com.colliderli.IINA", "IINA"), rules: rules).mode == .movie, "bundle id 大小寫不拘")
    check(ModeRules.resolve(app("com.apple.businessgames", "x", cat: "public.app-category.business"), rules: rules).mode == .music,
          "非 games 類別 → 音樂")
    check(ModeRules.resolve(app("com.x", "x", cat: "games"), rules: rules).mode == .music, "沒有 public.app-category. 前綴 → 音樂")
    var custom = rules
    custom["com.apple.Chess"] = .music
    custom["com.apple.Safari"] = .movie
    custom["com.colliderli.iina"] = .auto
    check(ModeRules.resolve(chess, rules: custom).mode == .music, "對照表優先於遊戲類別（Chess → 音樂）")
    check(ModeRules.resolve(safari, rules: custom).mode == .movie, "自訂 Safari → 影片")
    check(ModeRules.resolve(iina, rules: custom).mode == .music, "對照表值 .auto = 視為未列入")
    check(ModeRules.isOwn(me) && !ModeRules.isOwn(safari) && !ModeRules.isOwn(nil), "isOwn 辨識自己")
    check(ModeRules.resolve(iina, rules: rules).reason.contains("IINA"), "理由含 app 名稱")

    print("ModeDecider（虛擬時間，去抖動 1 秒）")
    let auto = Config()
    var locked = Config(); locked.mode = .game; locked.manualLock = true
    var lockedFlagOnly = Config(); lockedFlagOnly.manualLock = true
    do {
        var d = ModeDecider(debounce: 1.0)
        let first = d.evaluateNow(safari, config: auto, force: true)
        check(first?.mode == .music, "啟動立即送（Safari → 音樂）")
        check(d.evaluateNow(safari, config: auto, force: false) == nil, "相同結果不重送")
        check(d.activate(iina, now: 10.0, config: auto), "切到 IINA → 排定")
        check(d.fire(now: 10.5, config: auto) == nil, "0.5 秒時還不送")
        let s = d.fire(now: 11.0, config: auto)
        check(s?.mode == .movie, "1 秒後送影片", "\(String(describing: s))")
        check(d.fire(now: 12.0, config: auto) == nil, "已送過不再送")

        // Cmd-Tab 掃過：IINA → Steam → Safari → Finder（各 0.2 秒），最後停在 Finder
        d.activate(steam, now: 20.0, config: auto)
        d.activate(safari, now: 20.2, config: auto)
        d.activate(finder, now: 20.4, config: auto)
        check(d.fire(now: 21.0, config: auto) == nil, "掃過中途（上次切換後未滿 1 秒）不送")
        let s2 = d.fire(now: 21.4, config: auto)
        check(s2?.mode == .music && s2?.reason.contains("Finder") == true, "掃過結束送最後停下的 Finder → 音樂", "\(String(describing: s2))")

        // 掃過又回到原本的 app → 不送
        d.activate(iina, now: 30.0, config: auto)
        d.activate(finder, now: 30.3, config: auto)
        check(d.pending == nil, "掃回原狀態 → 取消排定")
        check(d.fire(now: 32.0, config: auto) == nil, "掃回原狀態 → 不送")

        // 自己變前景（面板打開）：忽略，不取消已排定的切換
        d.activate(iina, now: 40.0, config: auto)
        check(!d.activate(me, now: 40.3, config: auto), "自己 → 忽略")
        check(d.pending != nil, "自己不取消排定")
        check(d.fire(now: 41.0, config: auto)?.mode == .movie, "排定照常送出（影片）")
        check(d.lastApp == iina, "lastApp 不會變成自己")
        check(d.evaluateNow(me, config: auto, force: true)?.mode == .movie, "立即判斷時自己在前景 → 用上一個 app（IINA）")
    }
    do {
        var d = ModeDecider(debounce: 1.0)
        _ = d.evaluateNow(safari, config: auto, force: true)
        check(!d.activate(iina, now: 1, config: locked), "手動鎖定 → 不排定")
        check(d.fire(now: 5, config: locked) == nil, "手動鎖定 → 不送")
        check(!d.activate(steam, now: 6, config: lockedFlagOnly), "manualLock=true（mode 仍 auto）也算鎖定")
        check(d.evaluateNow(iina, config: locked, force: true) == nil, "鎖定時立即判斷也不送")
        // 排定後才鎖定 → 到期不送
        _ = d.evaluateNow(safari, config: auto, force: true)
        d.activate(iina, now: 10, config: auto)
        check(d.fire(now: 11, config: locked) == nil, "排定後被鎖定 → 到期不送")
        // 解鎖（按回自動）：force 立即送，即使和上次相同
        d.forgetLastSent()
        let u = d.evaluateNow(iina, config: auto, force: true)
        check(u?.mode == .movie, "按回自動 → 立即依前景（IINA）送影片")
        // 對照表在排定期間改了 → 到期用新表
        var r2 = auto; r2.autoModeRules["com.apple.Safari"] = .game
        d.activate(safari, now: 20, config: auto)
        check(d.fire(now: 21, config: r2)?.mode == .game, "到期時用最新對照表重算（Safari → 遊戲）")
    }
    do {
        // 同模式換 app：理由更新也送（面板理由不會停在舊 app）
        var d = ModeDecider(debounce: 1.0)
        _ = d.evaluateNow(iina, config: auto, force: true)
        d.activate(qt, now: 1, config: auto)
        let s = d.fire(now: 2, config: auto)
        check(s?.mode == .movie && s?.reason.contains("QuickTime") == true, "同模式換 app → 送出新理由")
    }

    print("ModeManager（主執行緒；不訂閱通知，直接餵事件）")
    let mmResult: (Bool, Bool, Bool) = MainActor.assumeIsolated {
        let mm = ModeManager()
        var got: [(PlayMode, String)] = []
        mm.onResolvedModeChange = { got.append(($0, $1)) }
        var disk = Config()
        mm.readDiskConfig = { disk }
        mm.update(config: Config())
        mm.handleActivation(iina)
        // 等 1.2 秒讓計時器觸發
        let end = Date().addingTimeInterval(1.3)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let a = got.last?.0 == .movie
        // 模擬 AppState.selectMode(.game)：只寫檔，沒有 update(config:)
        disk.mode = .game; disk.manualLock = true
        let n = got.count
        mm.handleActivation(safari)
        let end2 = Date().addingTimeInterval(1.3)
        while Date() < end2 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let b = got.count == n
        // 按回自動：selectMode 寫檔後呼叫 reevaluate
        disk.mode = .auto; disk.manualLock = false
        mm.reevaluate()
        let c = got.count == n + 1
        mm.stop()
        return (a, b, c)
    }
    check(mmResult.0, "handleActivation(IINA) 1 秒後送影片（真計時器）")
    check(mmResult.1, "只寫 config.json 的手動鎖定也擋得住（AppState 沒呼叫 update）")
    check(mmResult.2, "reevaluate（按回自動）立即送出")

    print("前景 app 讀取（唯讀）")
    let cur: FrontApp? = MainActor.assumeIsolated { FrontAppReader.current() }
    print("  目前前景：\(cur.map { "\($0.name) [\($0.bundleID ?? "-")] 類別=\($0.categoryType ?? "-")" } ?? "無")"
          + " → \(ModeRules.resolve(cur, rules: rules).reason)")
    let chessCat = FrontAppReader.category(bundleID: "com.apple.Chess", url: URL(fileURLWithPath: "/System/Applications/Chess.app"))
    check(chessCat.map(ModeRules.isGameCategory) ?? false, "讀 /System/Applications/Chess.app 的 LSApplicationCategoryType 是遊戲類別",
          "得到 \(chessCat ?? "nil")")

    print(fail == 0 ? "✓ mode-selftest 全部通過（\(pass) 項）" : "✗ mode-selftest 失敗 \(fail) 項（通過 \(pass) 項）")
    return fail == 0 ? 0 : 1
}
