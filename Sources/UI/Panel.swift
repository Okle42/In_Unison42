// Panel.swift — 選單列面板（MenuBarExtra .window 樣式）（owner：UI）
//
// 結構：
//   PanelView     —— 真的面板：讀 AppState／CalibrationRunner／LoginItem，組成 PanelModel＋PanelActions
//   PanelContent  —— 純版面：只吃 PanelModel（值）與 PanelActions（closure），離屏截圖用假資料餵同一份版面
// 版面（寬 340 pt，apple-design：macOS 13pt 內文、語意色、SF Symbols、繁中照 Apple 用語）：
//   標頭（名稱＋運轉狀態）→ 警告列（預設輸出警告附「切回」）→ 模式（分段控制＋目前判定與理由／鎖定說明）
//   → 喇叭（類型圖示、名稱、標籤、延遲／補償或不出聲理由、開關、音量微調）→ 校正（麥克風選單、開始／停止、上次時間、進度／結果）
//   → 底部（在登入時打開、結束）
// 截圖：`In_Unison42 panel-snapshot --fake <dir>`（見 PanelSnapshot.swift），不碰使用者螢幕。
import AppKit
import ServiceManagement
import SwiftUI

// MARK: - 模型

/// 面板要顯示的一切（值型別；真的面板從 AppState 組，截圖用假資料）
struct PanelModel {
    enum EngineState: Equatable { case running, idle, notAdvancing, starting, stopped }

    var engine: EngineState
    /// 設定裡的模式（.auto 或手動鎖定的模式）
    var configMode: AudioMode
    var manualLock: Bool
    /// 目前生效的模式
    var playMode: PlayMode
    /// 自動模式的理由（ModeManager 給，例如「前景 IINA（對照表：影片）」）
    var modeReason: String?
    var caps: ModeCaps
    var devices: [DeviceRow]
    var warnings: [AppWarning]
    var mics: [CalibrationMic]
    /// nil = 自動
    var micUID: String?
    var calibratedAt: String?
    var calibration: CalibrationRunner.Phase
    var loginEnabled: Bool
    var loginNeedsApproval: Bool
    var loginError: String?
    /// 自動校正（倒數、需要校正、暫停出聲的藍牙）；預設空（假資料截圖不必給）
    var autoCal = AutoCalibrationStatus()
    /// 【第 B 輪】面板頂部「需要校正」的原因（空 = 不顯示）
    var attention: [String] = []
    /// 【第 B 輪】背景監聽
    var monitor = MonitorStatus()
    /// 【第 C 輪】藍牙漂移補償（開關＋每台狀態）
    var driftEnabled = true
    var drift: [DriftStatusRow] = []
    /// 【第 C 輪】藍牙連上後 macOS 搶預設輸出 → 自動切回（開關＋最近一次）
    var outputRestoreEnabled = true
    var outputRestoreNote: OutputRestoreNote?
}

/// 面板上的使用者動作
struct PanelActions {
    var selectMode: (AudioMode) -> Void = { _ in }
    var setDeviceEnabled: (String, Bool) -> Void = { _, _ in }
    var setTrim: (String, Double) -> Void = { _, _ in }
    var switchDefaultOutput: () -> Void = {}
    /// 設定檔唯讀保護中的「重設設定」
    var resetConfig: () -> Void = {}
    var setMic: (String?) -> Void = { _ in }
    var startCalibration: () -> Void = {}
    var cancelCalibration: () -> Void = {}
    var dismissCalibrationResult: () -> Void = {}
    /// 自動校正：倒數中取消（延後）／「需要校正」立即校正
    var cancelAutoCalibration: () -> Void = {}
    var calibratePendingNow: () -> Void = {}
    /// 面板頂部「立即校正」（需要校正的裝置全部，--only）
    var calibrateAttentionNow: () -> Void = {}
    /// 背景監聽開關
    var setMonitorEnabled: (Bool) -> Void = { _ in }
    /// 【第 C 輪】藍牙漂移補償開關、預設輸出自動切回開關
    var setDriftEnabled: (Bool) -> Void = { _ in }
    var setOutputRestoreEnabled: (Bool) -> Void = { _ in }
    var setLoginEnabled: (Bool) -> Void = { _ in }
    var openLoginItemsSettings: () -> Void = {}
    var quit: () -> Void = {}
}

// MARK: - 真的面板

struct PanelView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var calibration = CalibrationRunner.shared
    @State private var loginStatus: SMAppService.Status = LoginItem.status
    @State private var loginError: String?
    /// 面板打開時重新列一次麥克風（AppState 只在 engine 啟動時列一次；列出不會開任何麥克風）
    @State private var mics: [CalibrationMic]?

    var body: some View {
        PanelContent(model: model, actions: actions)
            .onAppear {
                // 高頻數值（LiveMeters：峰值、狀態行）只在面板開著時更新；AppState 另外每秒用 NSApp.windows 校正一次
                state.setPanelVisible(true)
                loginStatus = LoginItem.status
                DispatchQueue.global(qos: .userInitiated).async {
                    let m = availableCalibrationMics()
                    DispatchQueue.main.async { if m != mics { mics = m } }
                }
            }
            .onDisappear { state.setPanelVisible(false) }
    }

    private var model: PanelModel {
        let engine: PanelModel.EngineState
        if state.engineStarting { engine = .starting }
        else if !state.running { engine = .stopped }
        else if !state.ioAdvancing { engine = state.engineIdle ? .idle : .notAdvancing }
        else { engine = .running }
        return PanelModel(engine: engine, configMode: state.config.mode, manualLock: state.config.manualLock,
                          playMode: state.playMode, modeReason: state.modeReason, caps: state.config.modeCaps,
                          devices: state.devices, warnings: state.warnings,
                          mics: mics ?? state.calibrationMics, micUID: state.config.calibrationMicUID,
                          calibratedAt: state.config.calibratedAt, calibration: calibration.phase,
                          loginEnabled: loginStatus == .enabled || loginStatus == .requiresApproval,
                          loginNeedsApproval: loginStatus == .requiresApproval, loginError: loginError,
                          autoCal: state.autoCalStatus, attention: state.attentionReasons, monitor: state.monitorStatus,
                          driftEnabled: state.config.bluetoothDriftCompensation, drift: state.driftStatus,
                          outputRestoreEnabled: state.config.restoreDefaultOutputOnBluetoothConnect, outputRestoreNote: state.outputRestoreNote)
    }

    private var actions: PanelActions {
        let state = self.state
        let runner = calibration
        return PanelActions(
            selectMode: { state.selectMode($0) },
            setDeviceEnabled: { state.setDeviceEnabled($0, $1) },
            setTrim: { state.setTrim($0, $1) },
            switchDefaultOutput: { state.switchDefaultOutputToVolumeSource() },
            resetConfig: { state.resetConfigToDefaults() },
            setMic: { state.setCalibrationMic($0) },
            startCalibration: {
                // AppState 接好 pause／resume 之前，退回 AppState.runCalibration()（見 CalibrationRunner.swift 開頭）
                // 面板用脈衝＋GCC-PHAT 量尺（calibrate --pulse）寫入：chirp 量尺在這個房間會抓到內建喇叭的反射、
                // 三輪離散常超過 1 ms（2026-09-29 實測），脈衝量尺有離群剔除、同一把尺也是 --verify-program 的驗收尺
                if runner.isWired { runner.start(micUID: state.config.calibrationMicUID, extraArgs: AppState.panelCalibrationArgs) }
                else { state.runCalibration(extraArgs: AppState.panelCalibrationArgs) }
            },
            cancelCalibration: { runner.cancel() },
            dismissCalibrationResult: { runner.dismissResult() },
            cancelAutoCalibration: { state.cancelAutoCalibration() },
            calibratePendingNow: { state.calibratePendingNow() },
            calibrateAttentionNow: { state.calibrateAttentionNow() },
            setMonitorEnabled: { state.setMonitorEnabled($0) },
            setDriftEnabled: { state.setDriftCompensationEnabled($0) },
            setOutputRestoreEnabled: { state.setOutputRestoreEnabled($0) },
            setLoginEnabled: { on in
                do {
                    try LoginItem.setEnabled(on)
                    loginError = nil
                } catch {
                    loginError = "無法\(on ? "開啟" : "關閉")「在登入時打開」：\(error.localizedDescription)"
                }
                loginStatus = LoginItem.status
            },
            openLoginItemsSettings: { SMAppService.openSystemSettingsLoginItems() },
            quit: { state.quit() })
    }
}

// MARK: - 版面

struct PanelContent: View {
    let model: PanelModel
    let actions: PanelActions

    static let width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !model.attention.isEmpty {
                AttentionBanner(reasons: model.attention, busy: calibrationBusy, actions: actions)
            }
            if !model.warnings.isEmpty {
                VStack(spacing: 6) {
                    ForEach(model.warnings) { w in
                        WarningRow(warning: w, action: w.kind == .config ? actions.resetConfig : actions.switchDefaultOutput)
                    }
                }
            }
            modeSection
            Divider()
            devicesSection
            Divider()
            CalibrationSection(model: model, actions: actions)
            Divider()
            MonitorSection(status: model.monitor, micName: monitorMicName, actions: actions)
            if hasBluetooth {
                Divider()
                DriftSection(enabled: model.driftEnabled, rows: model.drift, actions: actions)
            }
            Divider()
            OutputRestoreSection(enabled: model.outputRestoreEnabled, note: model.outputRestoreNote, actions: actions)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
    }

    /// 有藍牙喇叭（漂移補償只對藍牙）
    private var hasBluetooth: Bool { model.devices.contains { !$0.inAggregate } || !model.drift.isEmpty }

    /// 有校正在跑／倒數中（「立即校正」停用）
    private var calibrationBusy: Bool {
        if case .running = model.calibration { return true }
        return !model.autoCal.countdownNames.isEmpty || !model.autoCal.runningNames.isEmpty
    }

    private var monitorMicName: String {
        if let uid = model.micUID, let m = model.mics.first(where: { $0.uid == uid }) { return m.name }
        return model.mics.first(where: \.isAutomaticChoice)?.name ?? "校正麥克風"
    }

    // 標頭：名稱＋運轉狀態（顏色＋文字，不只靠顏色）
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("In_Unison42").font(.headline)
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var statusText: String {
        switch model.engine {
        case .running: return "同步播放中"
        case .idle: return "待命中（有聲音時自動開始）"
        case .notAdvancing: return "音訊沒有在跑"
        case .starting: return "啟動中⋯"
        case .stopped: return "未啟動"
        }
    }

    private var statusColor: Color {
        switch model.engine {
        case .running: return .green
        case .idle: return .green
        case .notAdvancing: return .orange
        case .starting: return .yellow
        case .stopped: return .secondary
        }
    }

    // 模式
    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ModeSegmentedControl(selection: Binding(get: { model.configMode }, set: { actions.selectMode($0) }))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: model.manualLock ? "lock.fill" : PanelText.symbol(model.playMode))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(modeHeadline)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(modeDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .help(model.modeReason ?? "")
        }
    }

    private var modeHeadline: String {
        if model.manualLock { return "已鎖定為\(model.playMode.label)模式" }
        return PanelText.autoReason(model.modeReason, mode: model.playMode)
    }

    private var modeDetail: String {
        let cap = PanelText.capText(model.caps.cap(model.playMode))
        return model.manualLock ? "\(cap)\n選「自動」即可恢復依前景App切換" : cap
    }

    // 喇叭
    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                PanelSectionTitle("喇叭")
                Spacer()
                if !model.devices.isEmpty {
                    Text("\(model.devices.filter { $0.plan?.active == true }.count)台出聲，共\(model.devices.count)台")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if model.devices.isEmpty {
                Text("找不到可用的輸出裝置")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.devices) { d in
                DeviceRowView(device: d, actions: actions)
            }
        }
    }

    // 底部
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("在登入時打開", isOn: Binding(get: { model.loginEnabled }, set: { actions.setLoginEnabled($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("結束In_Unison42") { actions.quit() }
                    .keyboardShortcut("q")
            }
            if model.loginNeedsApproval {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("需要在「登入項目」中允許")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("打開登入項目設定⋯") { actions.openLoginItemsSettings() }
                        .controlSize(.small)
                }
            }
            if let e = model.loginError {
                Text(e)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 區段標題
struct PanelSectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - 警告列

struct WarningRow: View {
    let warning: AppWarning
    let action: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("警告")
                Text(warning.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let title = warning.actionTitle, warning.kind == .defaultOutput || warning.kind == .config {
                Button(title, action: action)
                    .controlSize(.small)
                    .fixedSize()
                    .help(warning.kind == .config ? "寫入預設設定並恢復自動存檔（壞檔保留不動；之後需要重新校正）"
                                                  : "把系統預設輸出切回音量來源（不會改音量）")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.14)))
    }
}

// MARK: - 裝置列

struct DeviceRowView: View {
    let device: DeviceRow
    let actions: PanelActions

    private var active: Bool { device.plan?.active ?? device.enabled }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: active ? PanelText.deviceSymbol(device.kind) : "speaker.slash")
                .font(.body)
                .imageScale(.large)
                .foregroundStyle(active ? Color.primary : Color.secondary)
                .frame(width: 22, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(active ? Color.primary : Color.secondary)
                    if device.isVolumeSource { PanelBadge("音量來源") }
                    if !device.inAggregate { PanelBadge("藍牙") }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                if device.enabled {
                    TrimSlider(name: device.name, trimDb: device.trimDb) { actions.setTrim(device.uid, $0) }
                        .opacity(active ? 1 : 0.6)
                }
            }
            Spacer(minLength: 4)
            DeviceSwitch(isOn: Binding(get: { device.enabled }, set: { actions.setDeviceEnabled(device.uid, $0) }),
                         accessibilityName: device.name)
                .padding(.top, 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var subtitle: String {
        let lat = device.measuredLatencyMs.map { "延遲" + PanelText.ms($0, signed: true) } ?? "未量測延遲"
        guard device.enabled else { return "已關閉" }
        let again = device.needsRecalibration ? "\n重新連線後延遲可能改變，請重新校正" : ""
        guard let p = device.plan else { return lat + again }
        if p.active { return "\(lat)・補償" + PanelText.ms(p.delayMs, signed: false) + again }
        if device.needsRecalibration && p.reason.contains("重新校正") { return "不出聲：重新連線後需要重新校正" }
        return "不出聲：\(PanelText.tidyReason(p.reason))" + again
    }
}

/// 名稱旁的小標籤
struct PanelBadge: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

/// 音量微調滑桿：拖曳時只改本地值，放開才存檔（setTrim 每次都會寫 config.json）
struct TrimSlider: View {
    let name: String
    let trimDb: Double
    let commit: (Double) -> Void
    @State private var dragging: Double?

    /// 建議範圍 −12…+6 dB；設定值超出時放寬到包住它（Config 允許 −60…+12）
    private var range: ClosedRange<Double> { min(-12, trimDb)...max(6, trimDb) }

    var body: some View {
        let shown = dragging ?? trimDb
        HStack(spacing: 8) {
            Text("微調")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { shown }, set: { dragging = ($0 * 2).rounded() / 2 }), in: range) { editing in
                if !editing, let v = dragging {
                    commit(v)
                    dragging = nil
                }
            }
            .controlSize(.mini)
            .accessibilityLabel("\(name)音量微調")
            .accessibilityValue(PanelText.db(shown))
            Text(PanelText.db(shown))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .contextMenu {
            Button("回復成0 dB") { commit(0) }
        }
        .help("音量微調（dB）；放開滑桿才儲存")
    }
}

// MARK: - 校正區

struct CalibrationSection: View {
    let model: PanelModel
    let actions: PanelActions

    private var selectedMic: CalibrationMic? {
        if let uid = model.micUID { return model.mics.first { $0.uid == uid } }
        return model.mics.first(where: \.isAutomaticChoice)
    }

    private var running: Bool { if case .running = model.calibration { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSectionTitle("延遲校正")
            Picker("麥克風", selection: Binding(get: { model.micUID }, set: { actions.setMic($0) })) {
                Text(autoTitle).tag(String?.none)
                if !model.mics.isEmpty { Divider() }
                ForEach(model.mics) { m in
                    Text(PanelText.micTitle(m)).tag(String?.some(m.uid))
                }
                if let uid = model.micUID, !model.mics.contains(where: { $0.uid == uid }) {
                    Text("找不到已選的麥克風").tag(String?.some(uid))
                }
            }
            .pickerStyle(.menu)
            .disabled(running)

            if let m = selectedMic, model.micUID != nil, let note = PanelText.micNote(m) {
                Label(note.text, systemImage: note.warning ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(note.warning ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let uid = model.micUID, !model.mics.contains(where: { $0.uid == uid }) {
                Label("已選的麥克風目前沒有連接；校正會失敗，請改選其他麥克風", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.autoCal.countdownNames.isEmpty || !model.autoCal.runningNames.isEmpty {
                // 「需要校正」清單與暫停出聲的藍牙改在面板頂部（AttentionBanner）；這裡只剩倒數／執行中
                AutoCalibrationBlock(status: model.autoCal, calibrating: running, actions: actions, showPending: false)
            }

            progressOrResult

            HStack(alignment: .firstTextBaseline) {
                Text(PanelText.lastCalibrated(model.calibratedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if running {
                    Button("停止") { actions.cancelCalibration() }
                } else {
                    Button("開始校正") { actions.startCalibration() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.mics.isEmpty && model.micUID == nil)
                        .help("暫停同步播放，從每台喇叭播放測試音並用麥克風量到達時間")
                }
            }
        }
    }

    private var autoTitle: String {
        if let a = model.mics.first(where: \.isAutomaticChoice) { return "自動（\(a.name)）" }
        return "自動"
    }

    @ViewBuilder private var progressOrResult: some View {
        switch model.calibration {
        case .idle:
            Text("校正時會暫停同步播放，每台喇叭依序播放測試音，約需十幾秒。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .running(let step, let fraction):
            VStack(alignment: .leading, spacing: 5) {
                PanelProgressBar(fraction: fraction)
                Text(step)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .finished(let ok, let message, _):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(ok ? Color.green : Color.red)
                    .accessibilityLabel(ok ? "成功" : "失敗")
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    actions.dismissCalibrationResult()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .accessibilityLabel("關閉校正結果")
                .help("關閉校正結果")
            }
        }
    }
}

// MARK: - 自動校正（新裝置接上／app 重開後的藍牙）

struct AutoCalibrationBlock: View {
    let status: AutoCalibrationStatus
    /// 有校正在跑（按鈕停用）
    let calibrating: Bool
    let actions: PanelActions
    /// false：需要校正清單與暫停出聲的藍牙由面板頂部 AttentionBanner 顯示
    var showPending = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !status.countdownNames.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "timer")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text(status.waitingMessage.map { "即將校正\(AutoCalNotifier.list(status.countdownNames))：\($0)" }
                         ?? "\(status.secondsLeft) 秒後校正\(AutoCalNotifier.list(status.countdownNames))")
                        .font(.callout)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("取消") { actions.cancelAutoCalibration() }
                        .controlSize(.small)
                        .help("先不要校正；之後可按「需要校正」")
                }
            }
            if !status.runningNames.isEmpty {
                Label("自動校正\(AutoCalNotifier.list(status.runningNames))", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if showPending && !status.pending.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(status.pending) { p in
                            Label("\(AutoCalNotifier.list([p.name]))\(p.message)", systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("需要校正") { actions.calibratePendingNow() }
                        .controlSize(.small)
                        .disabled(calibrating || !status.countdownNames.isEmpty)
                        .help("只校正這幾台（其他喇叭沿用目前的延遲）")
                }
            }
            if showPending && !status.heldNames.isEmpty {
                Label("\(AutoCalNotifier.list(status.heldNames))校正完成前先不出聲（重新連線或 app 重新啟動後藍牙延遲可能改變）",
                      systemImage: "speaker.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 面板頂部：需要校正（第 B 輪）

struct AttentionBanner: View {
    let reasons: [String]
    /// 有校正在跑或倒數中（按鈕停用）
    let busy: Bool
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("需要校正")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("立即校正") { actions.calibrateAttentionNow() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                    .help("只校正這幾台（暫停同步播放約十幾秒；其他喇叭沿用目前的延遲）")
            }
            ForEach(Array(reasons.enumerated()), id: \.offset) { _, r in
                Text(r)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.14)))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 背景監聽（第 B 輪）

struct MonitorSection: View {
    let status: MonitorStatus
    let micName: String
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("播音樂時自動修正落拍")
                    Text("每 \(PanelText.minutes(status))用「\(micName)」聽幾秒（麥克風指示燈會亮；錄音只在記憶體計算，不存檔）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                DeviceSwitch(isOn: Binding(get: { status.enabled }, set: { actions.setMonitorEnabled($0) }), accessibilityName: "播音樂時自動修正落拍")
            }
            if status.enabled {
                ForEach(Array(PanelText.monitorLines(status).enumerated()), id: \.offset) { _, line in
                    Label(line.text, systemImage: line.symbol)
                        .font(.caption)
                        .foregroundStyle(line.warning ? Color.orange : Color.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - 藍牙漂移補償（第 C 輪）

struct DriftSection: View {
    let enabled: Bool
    let rows: [DriftStatusRow]
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("藍牙漂移補償")
                    Text("藍牙喇叭的延遲會慢慢漂；依量測估漂移速度、預先修正。量測點不夠時，趁音樂停下的空檔自動短校正（約 10 秒）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                DeviceSwitch(isOn: Binding(get: { enabled }, set: { actions.setDriftEnabled($0) }), accessibilityName: "藍牙漂移補償")
            }
            if enabled {
                ForEach(Array(PanelText.driftLines(rows).enumerated()), id: \.offset) { _, line in
                    Label(line.text, systemImage: line.symbol)
                        .font(.caption)
                        .foregroundStyle(line.warning ? Color.orange : Color.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - 藍牙連上後預設輸出自動切回（第 C 輪）

struct OutputRestoreSection: View {
    let enabled: Bool
    let note: OutputRestoreNote?
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("藍牙連上時保持預設輸出")
                    Text("藍牙喇叭連上後 10 秒內 macOS 把預設輸出切過去時，自動切回音量來源；之後你自己選藍牙就照你的")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                DeviceSwitch(isOn: Binding(get: { enabled }, set: { actions.setOutputRestoreEnabled($0) }), accessibilityName: "藍牙連上時保持預設輸出")
            }
            if let n = note {
                Label("\(PanelText.time(n.at))：\(n.message)", systemImage: n.restored ? "arrow.uturn.backward.circle" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 文字與圖示

enum PanelText {
    static let locale = Locale(identifier: "zh_Hant_TW")

    /// 模式的 SF Symbol（與 AppState.menuBarSymbol 一致）
    static func symbol(_ m: PlayMode) -> String {
        switch m {
        case .music: return "hifispeaker.2"
        case .movie: return "film"
        case .game: return "gamecontroller"
        }
    }

    static func deviceSymbol(_ k: DeviceKind) -> String {
        switch k {
        case .builtIn: return "speaker.wave.2"
        case .hdmi, .displayPort, .thunderbolt: return "tv"
        case .bluetooth, .bluetoothLE: return "hifispeaker"
        case .airPlay: return "airplay.audio"
        case .usb: return "cable.connector"
        case .continuity: return "iphone"
        default: return "speaker.wave.2"
        }
    }

    /// 「前景 IINA（對照表：影片）」→「IINA在前景 → 影片」；格式不認得就原樣加上結果
    static func autoReason(_ reason: String?, mode: PlayMode) -> String {
        guard let r = reason, !r.isEmpty else { return "自動：\(mode.label)" }
        if r.hasPrefix("前景 ") {
            var name = String(r.dropFirst(3))
            if let i = name.firstIndex(of: "（") { name = String(name[..<i]) }
            var why = ""
            if r.contains("類別") { why = "（遊戲類App）" }
            else if r.contains("未列入對照表") { why = "（不在對照表）" }
            return "\(name)在前景\(why) → \(mode.label)"
        }
        return "\(r) → \(mode.label)"
    }

    static func capText(_ cap: Double) -> String {
        cap.isFinite ? String(format: "延遲上限 %.0f ms：比最快的喇叭慢超過就不出聲", cap) : "不限延遲：所有喇叭都出聲"
    }

    static func ms(_ v: Double, signed: Bool) -> String {
        signed ? String(format: " +%.2f ms", v) : String(format: " %.2f ms", v)
    }

    /// 帶正負號的 dB，負號用 U+2212
    static func db(_ v: Double) -> String {
        let s = String(format: "%+.1f dB", abs(v) < 0.05 ? 0 : v)
        return s.replacingOccurrences(of: "-", with: "\u{2212}")
    }

    /// plan() 的理由（「相對延遲 +34.46 ms 超過遊戲模式上限 20 ms」）稍微精簡
    static func tidyReason(_ r: String) -> String {
        r.replacingOccurrences(of: "相對延遲 ", with: "延遲")
    }

    static func micTitle(_ m: CalibrationMic) -> String {
        if m.isContinuity { return "\(m.name)（只用於校正）" }
        if m.kind.isBluetooth { return "\(m.name)（藍牙）" }
        return m.name
    }

    static func micNote(_ m: CalibrationMic) -> (text: String, warning: Bool)? {
        if m.isContinuity { return ("iPhone麥克風只在校正期間開啟，平常不會使用", false) }
        if m.kind.isBluetooth { return ("藍牙麥克風會讓這台裝置切到通話音質（HFP），校正期間音質會變差；建議改用其他麥克風", true) }
        return nil
    }

    /// 監聽間隔（「5 分鐘」）
    static func minutes(_ st: MonitorStatus) -> String {
        let m = st.intervalSeconds / 60
        return m == m.rounded() ? "\(Int(m)) 分鐘" : String(format: "%.1f 分鐘", m)
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f.string(from: d)
    }

    /// 背景監聽狀態的幾行字（聆聽中／等待原因／最近一次結果／累計修正）
    static func monitorLines(_ st: MonitorStatus) -> [(text: String, symbol: String, warning: Bool)] {
        var out: [(String, String, Bool)] = []
        if st.listening {
            out.append(("聆聽中⋯", "waveform", false))
        } else if let w = st.waitingReason, w != .noTargets {
            out.append(("到時間了，等條件符合：\(w.text)", "pause.circle", false))
        }
        if let last = st.last {
            var head = "上次 \(time(last.at))"
            if let sk = last.skipped {
                head += sk == .estimator ? "：\(last.message)" : "：跳過（\(last.message)）"
                out.append((head, "clock", false))
            } else {
                out.append((head + (last.confirm ? "（確認）" : ""), "clock", false))
                for d in last.devices {
                    let e = d.errorMs.map { String(format: "%+.2f ms", $0) } ?? "—"
                    let warn = d.note.contains("需要重新校正")
                    out.append(("\(d.name) \(e)：\(d.note)", d.correctedMs != nil ? "checkmark.circle" : (warn ? "exclamationmark.circle" : "circle"), warn))
                }
            }
        } else if !st.listening {
            out.append(("還沒有監聽紀錄", "clock", false))
        }
        return out
    }

    /// 漂移補償每台一兩行：速度、目前修正、下一次短校正
    static func driftLines(_ rows: [DriftStatusRow]) -> [(text: String, symbol: String, warning: Bool)] {
        guard !rows.isEmpty else { return [("還沒有量測點（藍牙校正後開始）", "clock", false)] }
        var out: [(String, String, Bool)] = []
        for r in rows {
            var head = "\(r.name)："
            if let rate = r.rateMsPerMin { head += String(format: "漂 %+.2f ms／分", rate) } else { head += r.healthy ? "還沒估速度" : "不外推" }
            if let c = r.correctionMs { head += String(format: "、修正 %+.1f ms", c) }
            if let sg = r.sigmaMs { head += String(format: "（±%.1f）", sg) }
            head += "、\(r.points) 點"
            out.append((head, r.healthy ? "waveform.path.ecg" : "exclamationmark.circle", !r.healthy))
            if r.held { out.append(("太久沒量到、預估誤差變大：修正先停住，等下一次短校正", "pause.circle", true)) }
            if !r.healthy { out.append((r.health, "exclamationmark.triangle", true)) }
            else if let m = r.lastMiss { out.append(("最近一次 \(m)（這個串流 \(r.misses) 次）", "exclamationmark.circle", true)) }
            if let w = r.waiting {
                out.append(("該短校正了：\(w)", "hourglass", false))
            } else if let d = r.nextDue {
                out.append(("下次短校正 \(time(d))（\(r.nextReason ?? "")；有空檔才跑）", "clock", false))
            }
        }
        return out
    }

    static func lastCalibrated(_ iso: String?) -> String {
        guard let iso, let d = ISO8601DateFormatter().date(from: iso) else { return "尚未校正" }
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return "上次校正：\(f.string(from: d))"
    }
}
