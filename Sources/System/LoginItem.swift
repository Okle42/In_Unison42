// LoginItem.swift — 登入自動啟動（SMAppService.mainApp），取代舊的 LaunchAgent（owner：系統）
//
// 規格：
//   * 面板上一個「登入時啟動」開關 → LoginItem.setEnabled
//   * 第一次啟用時遷移：舊 LaunchAgent（~/Library/LaunchAgents/com.kang.In-Unison42.plist，Label com.kang.In-Unison42）
//     要 launchctl bootout，plist 與 ~/Library/Application Support/In_Unison42/bin/ 移到 ~/.Trash（加時間戳；不可 rm）。
//   * app 必須在 /Applications 或 ~/Applications 才註冊（從 build/ 註冊的話，路徑換了就失效）：
//     不在這兩處時 setEnabled(true) 丟 LoginItemError.notInstalled（面板顯示「先把 app 放到『應用程式』」）。
//     安裝位置建議 ~/Applications/In_Unison42.app（不需要管理員權限）；由架構負責人在 build.sh 加 --install。
//   * status == .requiresApproval 時面板提示去「系統設定 → 一般 → 登入項目」核准（LoginItem.openSystemSettings()）。
import Foundation
import ServiceManagement

enum LoginItemError: Error, CustomStringConvertible {
    case notInstalled(String)
    case notAppBundle(String)
    case service(Error)

    var description: String {
        switch self {
        case .notInstalled(let p):
            return "app 在 \(p)，不在「應用程式」資料夾（/Applications 或 ~/Applications）；搬過去再開「登入時啟動」，否則路徑一換就失效"
        case .notAppBundle(let p):
            return "目前執行檔不是從 .app 啟動（\(p)），無法註冊登入項目"
        case .service(let e):
            return "SMAppService 失敗：\(e.localizedDescription)"
        }
    }
}

enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// 需要使用者到系統設定核准
    static var requiresApproval: Bool { status == .requiresApproval }

    static func describe(_ s: SMAppService.Status) -> String {
        switch s {
        case .notRegistered: return "未註冊"
        case .enabled: return "已啟用"
        case .requiresApproval: return "需要到系統設定核准"
        case .notFound: return "找不到（app 不在可註冊的位置，或還沒註冊過）"
        @unknown default: return "未知(\(s.rawValue))"
        }
    }

    /// 目前 app bundle 路徑（CLI 從 app 內執行檔跑也是同一個 bundle）
    static var appBundleURL: URL { Bundle.main.bundleURL }

    /// 是否在適合註冊的位置（/Applications 或 ~/Applications 底下）
    static func isInstalledLocation(_ url: URL = appBundleURL) -> Bool {
        let p = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard p.hasSuffix(".app") else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix("/Applications/") || p.hasPrefix(home + "/Applications/")
    }

    /// register()／unregister()；啟用時順便 migrateFromLaunchAgent()。force = 不在「應用程式」資料夾也註冊（測試用）
    static func setEnabled(_ on: Bool, force: Bool = false) throws {
        let service = SMAppService.mainApp
        if on {
            let url = appBundleURL
            guard url.pathExtension == "app" else { throw LoginItemError.notAppBundle(url.path) }
            if !force && !isInstalledLocation(url) { throw LoginItemError.notInstalled(url.path) }
            if service.status != .enabled {
                do { try service.register() } catch { throw LoginItemError.service(error) }
            }
            if let m = migrateFromLaunchAgent() { AppLog.line(m) }
        } else {
            guard service.status == .enabled || service.status == .requiresApproval else { return }
            do { try service.unregister() } catch { throw LoginItemError.service(error) }
        }
    }

    /// 打開「系統設定 → 一般 → 登入項目」
    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// migrateFromLaunchAgent 真的做了事之後發出（AppState 收到就立刻重試拿實例鎖、啟動引擎）
    static let legacyMigratedNotification = Notification.Name("In_Unison42.legacyLaunchAgentMigrated")

    /// 舊 LaunchAgent 還在不在（plist 存在或已載入）
    static var hasLegacyLaunchAgent: Bool {
        FileManager.default.fileExists(atPath: ServicePaths.plist.path) || launchdState().loaded
            || FileManager.default.fileExists(atPath: ServicePaths.binDir.path)
    }

    /// 停掉並移除舊 LaunchAgent（plist、bin 移到垃圾桶，不 rm）。回傳做了什麼（給 log／面板），沒有舊服務回 nil。
    /// dryRun = 只回傳會做什麼
    @discardableResult
    static func migrateFromLaunchAgent(dryRun: Bool = false) -> String? {
        let fm = FileManager.default
        var did: [String] = []
        if launchdState().loaded {
            if dryRun { did.append("launchctl bootout \(ServicePaths.serviceTarget)") }
            else { did.append(launchdBootout() ? "已停止舊 LaunchAgent（bootout）" : "⚠ 舊 LaunchAgent bootout 未確認成功") }
        }
        for url in [ServicePaths.plist, ServicePaths.binDir] where fm.fileExists(atPath: url.path) {
            if dryRun {
                did.append("mv \(url.path) → ~/.Trash/（加時間戳）")
            } else if let dest = moveToTrash(url, dryRun: false) {
                did.append("\(url.lastPathComponent) → \(dest.path)")
            } else {
                did.append("⚠ \(url.path) 移到垃圾桶失敗")
            }
        }
        guard !did.isEmpty else { return nil }
        if !dryRun { NotificationCenter.default.post(name: legacyMigratedNotification, object: nil) }
        return (dryRun ? "舊 LaunchAgent 遷移（dry-run）：" : "舊 LaunchAgent 遷移：") + did.joined(separator: "；")
    }
}

/// `In_Unison42 login-item [status | on [--force] | off | migrate [--dry-run]]`
func cmdLoginItem(_ args: [String]) -> Int32 {
    let sub = args.first ?? "status"
    let rest = Array(args.dropFirst())
    func printStatus() {
        let s = LoginItem.status
        print("登入項目（SMAppService.mainApp）：\(s.rawValue) \(LoginItem.describe(s))")
        print("app 位置：\(LoginItem.appBundleURL.path)（\(LoginItem.isInstalledLocation() ? "在「應用程式」資料夾" : "不在「應用程式」資料夾，不建議註冊")）")
        print("舊 LaunchAgent：\(LoginItem.hasLegacyLaunchAgent ? "還在" : "沒有")（plist \(FileManager.default.fileExists(atPath: ServicePaths.plist.path) ? "存在" : "不存在")、"
              + "\(launchdState().loaded ? "已載入" : "未載入")）")
    }
    switch sub {
    case "status":
        printStatus()
        return 0
    case "on":
        do {
            try LoginItem.setEnabled(true, force: rest.contains("--force"))
        } catch {
            print("✗ \(error)")
            return 1
        }
        printStatus()
        if LoginItem.requiresApproval {
            print("→ 請到 系統設定 → 一般 → 登入項目 核准 In_Unison42")
        }
        return LoginItem.isEnabled || LoginItem.requiresApproval ? 0 : 1
    case "off":
        do { try LoginItem.setEnabled(false) } catch { print("✗ \(error)"); return 1 }
        printStatus()
        return 0
    case "migrate":
        let dry = !rest.contains("--yes")
        print(LoginItem.migrateFromLaunchAgent(dryRun: dry) ?? "沒有舊 LaunchAgent")
        if dry { print("（dry-run；加 --yes 才真的執行）") }
        return 0
    default:
        print("用法：In_Unison42 login-item [status | on [--force] | off | migrate [--yes]]")
        return 2
    }
}
