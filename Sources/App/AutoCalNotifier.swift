// AutoCalNotifier.swift — 自動校正的使用者通知（UNUserNotificationCenter；只在 app 模式、有 bundle id 時用）
//
// 倒數通知附「取消」動作（按了 = 面板的取消）。通知權限在 app 啟動時要一次（只要 alert，不要聲音）。
// 沒有授權（拒絕、或授權對話框還沒回答）時通知送不出去，選單列面板平常又是關著的 → 使用者看不到倒數：
// AppState 用 canNotify＋面板是否開著決定 AutoCalEnvironment.userCanSee，看不到就不自動倒數（延後成 needsConsent，面板打開時才倒數）。
import Foundation
import UserNotifications

final class AutoCalNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let categoryCountdown = "autocal.countdown"
    static let actionCancel = "autocal.cancel"
    static let idCountdown = "autocal.countdown"
    static let idResult = "autocal.result"

    /// 通知上按了「取消」（主執行緒呼叫）
    var onCancel: (() -> Void)?
    private var center: UNUserNotificationCenter?
    /// 通知權限是「允許」或「暫時允許」（主執行緒讀寫；還沒查到 = false）
    private(set) var canNotify = false
    private var lastAuthCheck = Date.distantPast

    /// app 模式才有 bundle id；CLI／自測沒有 bundle 時 UNUserNotificationCenter.current() 會當掉 → 不啟用
    func start() {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else {
            AppLog.line("通知：不是 app bundle，不發使用者通知")
            return
        }
        let c = UNUserNotificationCenter.current()
        center = c
        c.delegate = self
        let cancel = UNNotificationAction(identifier: Self.actionCancel, title: "取消", options: [])
        c.setNotificationCategories([UNNotificationCategory(identifier: Self.categoryCountdown, actions: [cancel],
                                                            intentIdentifiers: [], options: [])])
        c.requestAuthorization(options: [.alert]) { [weak self] granted, error in
            AppLog.line("通知權限：\(granted ? "允許" : "未允許")\(error.map { "（\($0.localizedDescription)）" } ?? "")")
            DispatchQueue.main.async { self?.refreshAuthorization(force: true) }
        }
        refreshAuthorization(force: true)
    }

    /// 重新讀通知權限（非同步；結果在下一次讀 canNotify 時生效）。使用者可能在系統設定裡改過 → 自動校正需要環境時每 5 秒讀一次
    func refreshAuthorization(force: Bool = false) {
        guard let c = center else { return }
        guard force || Date().timeIntervalSince(lastAuthCheck) >= 5 else { return }
        lastAuthCheck = Date()
        c.getNotificationSettings { [weak self] st in
            let ok = st.authorizationStatus == .authorized || st.authorizationStatus == .provisional
            let alerts = st.alertSetting != .disabled
            DispatchQueue.main.async {
                guard let self else { return }
                let v = ok && alerts
                if v != self.canNotify { AppLog.line("通知權限狀態：\(v ? "可以發通知" : "不能發通知（自動校正改成面板打開時才倒數）")") }
                self.canNotify = v
            }
        }
    }

    func countdown(names: [String], seconds: Int) {
        post(id: Self.idCountdown, title: "\(seconds) 秒後校正\(Self.list(names))",
             body: "會暫停同步播放，從這台和內建喇叭播放幾下柔和的測試音（約十幾秒）。現在不方便請按「取消」，之後可在選單列面板按「需要校正」。",
             category: Self.categoryCountdown)
    }

    func deferred(names: [String], reason: AutoCalDeferral, micName: String) {
        withdrawCountdown()
        switch reason {
        case .micBusy:
            post(id: Self.idResult, title: "延後校正\(Self.list(names))",
                 body: "麥克風「\(micName)」正被其他 App 使用。空下來後會自動再倒數校正。")
        case .noMic:
            post(id: Self.idResult, title: "延後校正\(Self.list(names))",
                 body: "找不到校正麥克風。接上後會自動再倒數校正，也可以在選單列面板改選麥克風。")
        case .driftDetected(let why):
            post(id: Self.idResult, title: "建議重新校正\(Self.list(names))",
                 body: "\(why)。沒有自動修正；打開選單列面板按「立即校正」。")
        case .cancelled, .failed, .notCalibratedAtLaunch, .heldAwaitingCalibration, .needsConsent:
            break   // 使用者自己取消的不再通知
        }
    }

    func finished(ok: [String], failed: [String], cancelled: Bool) {
        withdrawCountdown()
        guard !cancelled else { return }
        if failed.isEmpty {
            post(id: Self.idResult, title: "\(Self.list(ok))校正完成", body: "已套用新的延遲。")
        } else {
            post(id: Self.idResult, title: "\(Self.list(failed))沒有校正成功",
                 body: "麥克風可能聽不到它（放近一點或調大它本身的音量）。選單列面板可以按「需要校正」再試一次。")
        }
    }

    func withdrawCountdown() {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.idCountdown])
        center?.removePendingNotificationRequests(withIdentifiers: [Self.idCountdown])
    }

    private func post(id: String, title: String, body: String, category: String? = nil) {
        guard let c = center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        c.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { err in
            if let err { AppLog.line("通知發送失敗：\(err.localizedDescription)") }
        }
    }

    static func list(_ names: [String]) -> String { names.map { "〈\($0)〉" }.joined(separator: "") }

    // MARK: UNUserNotificationCenterDelegate

    /// app 是 LSUIElement（沒有前景視窗），通知一律照常顯示橫幅
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == Self.actionCancel {
            DispatchQueue.main.async { [weak self] in self?.onCancel?() }
        }
        completionHandler()
    }
}
