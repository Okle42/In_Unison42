# In_Unison42 內部 API（第一期：選單列 app）

> 下一階段四位實作者**只看這份＋自己的 stub 檔**。所有型別在同一個 module（`In_Unison42`），直接用，不用 import。
> 最後更新：2026-09-29 整合驗收（§10 校正交接、§11.8 實機 CPU、§12.5）；自動校正（§12）；藍牙納入校正（§5 末、§8.4、§10）；更早：2026-09-28 架構階段（app bundle、固定簽章、Config 第 2 版、plan()、Engine 執行中 API、stub）。
> 第 1 版（CLI＋LaunchAgent）的內容仍然有效的部分保留在 §4～§6；有改的地方標 **【v2】**。

## 0. 分工與硬規則

| 實作者 | 只能改 | 進入點／要實作的東西 | 自測指令（已接好） |
|---|---|---|---|
| UI | `Sources/UI/Panel.swift` | `PanelView`、`AppState.runCalibration()` 的內容（見 §8.1，唯一可以動 AppState 的地方） | `panel-snapshot <png>` |
| 模式 | `Sources/Mode/ModeManager.swift` | `ModeManager.start/stop/update/reevaluate`、`runModeSelfTest` | `mode-selftest` |
| 系統 | `Sources/System/SystemSounds.swift`、`LoginItem.swift`、`DefaultOutputGuard.swift` | `SystemSoundsRouter`、`LoginItem`、`DefaultOutputGuard`、三個 CLI | `system-sounds`、`login-item`、`output-guard` |
| 藍牙 | `Sources/Bluetooth/BluetoothOut.swift` | `BluetoothOutput`、`BluetoothOutManager`、`runBluetoothSelfTest` | `bluetooth-selftest` |

- 其他檔案（Engine／Config／Devices／Reconnect／Calibrate／ProgramPath／Service／CLI／App/*／build.sh／Info.plist／entitlements）**不要改**；需要新 API 就回報架構負責人。
  CLI 子指令已經幫各 owner 接好（上表），只要實作自己檔案裡的函式。
- 不可 git commit／push；不可安裝任何套件；只用系統框架（CoreAudio／AudioToolbox／Accelerate／Foundation／AppKit／SwiftUI／ServiceManagement）。
- 不可 `rm`；要移除就 `mv` 到 `~/.Trash/`（加時間戳避免撞名；`Service.swift` 有 `moveToTrash(_:dryRun:)`）。
- 動系統設定（預設輸出、系統輸出、音量、靜音）前先 `SystemAudioSnapshot.capture()`，結束時 `restore()`；**絕不調高系統音量、絕不合成音量鍵事件**。
  `SystemAudioSnapshot` 是 class（2026-09-29 起），還原規則：音量／靜音只套在**擷取當下那台**預設輸出上；音量只往下調
  （目前值仍是「我們自己最後設的值」才可以回到原值，使用者中途自己調低就不動）；靜音只解除我們自己設的；
  預設輸出／系統提示音輸出只在「目前值仍等於我們設的值」時還原。要改音量／靜音請用 `snap.setVolume(_:)`／`snap.setMuted(_:)`，
  自己切輸出後呼叫 `snap.noteSetDefaultOutput(_:)`／`noteSetSystemOutput(_:)`。實機測試：`In_Unison42 snapshot-live-test`。
- **絕不移動、縮放、關閉使用者的視窗；不可用 AX 自動化點畫面。** 面板截圖用 `panel-snapshot`（ImageRenderer 離屏渲染）。
- 即時執行緒（IOProc）內不可配置記憶體、上鎖、print、呼叫 Core Audio 屬性 API、retain class（closure 只捕捉值型別的指標 struct）。
- **同一時間只能有一個 tap 實例**（兩個會互相靜音）。由 `InstanceLock`（`System/InstanceLock.swift`，flock
  `~/Library/Application Support/In_Unison42/instance.lock`）保證：app、`run`、獨立跑的 `calibrate`／`engine-live-test` 開 tap 前
  `acquireTapInstance()`；app 呼叫的校正子行程不拿鎖，只確認持有者是 parent。舊版（沒有鎖的）只剩舊 LaunchAgent 的 `bin/In_Unison42`，
  用 `findLegacyRunInstances()` 另外看。app 拿不到鎖時不啟動引擎、面板顯示 otherInstance 警告，每秒重試，對方結束就自動接手。
- 回報誠實：沒實際跑過的標「未實測」，不可用推論代替量測。

## 1. 建置、簽章、執行

```sh
./build.sh                                  # 除錯版（-Onone -j10 -D DEBUG -D IU42_DIAG，約 4 秒）→ build/In_Unison42.app（＋ build/In_Unison42 symlink）
./build.sh --release                        # 正式版（-O -wmo，不含診斷，約 26 秒）；--install = 正式版＋安裝；--install-debug = 除錯版＋安裝
./test.sh                                   # 11 個離線自測＋15 份錄音回歸（testdata/expected.json）＋正式版閘門；非 0 = 回歸
open build/In_Unison42.app                  # 選單列 app（LSUIElement，不出現在 Dock）
./build/In_Unison42 devices                 # 帶子指令 = CLI（原本的行為）
open -W --stdout /tmp/x.log build/In_Unison42.app --args engine-live-test   # 需要 TCC 的 CLI 測試：用 app 身分跑
```

- `swiftc -O -swift-version 5 -module-name In_Unison42 -target arm64-apple-macos14.4 $(find Sources -name '*.swift')`，
  連結 CoreAudio／AudioToolbox／Accelerate／SwiftUI／AppKit／ServiceManagement。**新檔案放進 Sources/ 任何子目錄就會被編進去。**
- Bundle：`Contents/Info.plist`（來源：repo 根目錄 `Info.plist`）：`CFBundleIdentifier = com.kang.In-Unison42`、`LSUIElement = YES`、
  `LSMinimumSystemVersion = 14.4`、`NSAudioCaptureUsageDescription`、`NSMicrophoneUsageDescription`。
- 簽章：`codesign --force --options runtime --entitlements In_Unison42.entitlements --sign "$IDENTITY"`（預設 `-` ＝ ad-hoc；`IN_UNISON42_SIGN_IDENTITY="Apple Development: …"` 改用正式身分）。
  entitlements 只有 `com.apple.security.device.audio-input`（Hardened Runtime 下開麥克風必須）；不開 sandbox。
  designated requirement = `identifier "com.kang.In-Unison42" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: …"` →
  **重新編譯不會讓系統音訊錄製權限失效**（2026-09-28 實測：三個不同 CDHash 的版本重啟後 IO 都前進，tccd 沒有再跳授權）。
  上面的 designated requirement 與「權限不失效」只在設了 Apple Development 身分時成立；預設 ad-hoc 的權限每次重編都會失效。
- 進入點（`App/AppMain.swift`）：`argv[1]` 存在且不以 `-` 開頭 → `runCLI(argv)`；否則 → SwiftUI `In_Unison42App`（MenuBarExtra `.window`）。
- app 模式的 stdout/stderr 附加到 `~/Library/Logs/In_Unison42.log`（`AppLog.line(_:)` 加時間戳）；`~/Library/Application Support/In_Unison42/state.json`（`AppRuntimeState`）**狀態變化才寫＋每 10 秒心跳**（2026-09-29 起；以前每秒寫，`ioCycles`／`sampleTime` 現在最多舊 10 秒），`In_Unison42 status` 會顯示。
- **第一次啟動**：`engine.start()` 會卡在 `AudioDeviceCreateIOProcIDWithBlock` 等使用者回應「系統音訊錄製」授權對話框（實測 90 秒）。所以 AppState 在背景 queue 啟動 engine，主執行緒不會卡。
- SIGTERM／SIGINT → `NSApp.terminate` → `AppState.stop()` → `engine.stop()`（乾淨清掉 tap／聚合裝置）。實測結束後 coreaudiod 對 33 個行程記錄 `unmuted by In_Unison42-tap`、`Current muters: ()`。

## 2. 資料模型（Config.swift）【v2】

檔案：`~/Library/Application Support/In_Unison42/config.json`（`Config.fileURL`）。第 2 版範例：
```json
{
  "autoModeRules" : { "com.colliderli.iina" : "movie", "com.valvesoftware.steam" : "game", "…" : "…" },
  "calibratedAt" : "2026-09-28T09:18:54Z",
  "calibrationMicUID" : null,
  "devices" : {
    "BuiltInSpeakerDevice" : { "delayMs" : 34.46, "enabled" : true, "measuredLatencyMs" : 0, "trimDb" : 0 },
    "3669B030-0000-0000-1B21-010380341E78" : { "delayMs" : 33.2, "enabled" : true, "measuredLatencyMs" : 1.26, "trimDb" : 0 },
    "40C88240-0000-0000-151D-010380593278" : { "delayMs" : 0, "enabled" : true, "measuredLatencyMs" : 34.46, "trimDb" : 0 }
  },
  "levelMatch" : false,
  "manualLock" : false,
  "mode" : "auto",
  "modeCaps" : { "gameMs" : 20, "movieMs" : 80, "musicMs" : null },
  "version" : 2
}
```

```swift
enum AudioMode: String, Codable, CaseIterable { case auto, music, movie, game
    var fixed: PlayMode? { get }        // auto → nil
    var label: String { get }           // 自動／音樂／影片／遊戲
}
enum PlayMode: String, Codable, CaseIterable { case music, movie, game; var label: String }   // 生效的模式（沒有 auto）

struct ModeCaps: Codable, Equatable {   // 延遲上限（ms），nil = 不限；nil 會明確存成 null
    var musicMs: Double? = nil, movieMs: Double? = 80, gameMs: Double? = 20
    func cap(_ m: PlayMode) -> Double   // 不限回 .infinity
}

struct DeviceConfig: Codable, Equatable {
    var delayMs: Double = 0             // 【舊版欄位】只用來反推 measuredLatencyMs；calibrate 仍順手寫（舊執行檔讀得懂）
    var trimDb: Double = 0              // 音量微調（dB）；v2 一律生效（v1 只有 levelMatch 時生效）
    var measuredLatencyMs: Double? = nil  // 相對最快裝置的實測延遲（ms）；calibrate 寫入
    var enabled: Bool = true            // 使用者開關
    var needsRecalibration: Bool = false  // 【2026-09-29】藍牙量過延遲後重新連線 → true（面板提示）；校正寫入延遲時清掉
}

struct Config: Codable, Equatable {
    static let currentVersion = 2, maxDelayMs: Double = 1000 /* 2026-09-29 由 500 調大（藍牙）；48 kHz 延遲線仍 65536 frame */,
               trimDbRange: ClosedRange<Double> = -60...12
    static let silenceBluetoothAfterReconnect = false   // 重連後 needsRecalibration 的藍牙：false = 沿用舊值出聲＋提示；true = 先不出聲
    static let defaultAutoModeRules: [String: AudioMode]   // IINA、QuickTime、VLC、Infuse、Netflix、TV、mpv → movie；Steam → game
    var version: Int
    var devices: [String: DeviceConfig]     // key = 裝置 UID
    var levelMatch: Bool                    // 【舊版】v2 只表示「最近一次 calibrate --level 有寫 trim」
    var calibratedAt: String?
    var mode: AudioMode = .auto
    var manualLock: Bool = false            // 手動選模式 = true；按回「自動」= false
    var autoModeRules: [String: AudioMode]  // bundle id → 模式
    var calibrationMicUID: String?          // nil = 自動（Devices.microphone()）
    var modeCaps: ModeCaps
    static var directory: URL; static var fileURL: URL
    static func load(from: URL = fileURL) -> Config     // 不存在/壞檔 → 預設值；v1 自動遷移（只在記憶體，save 才寫回）
    func save(to: URL = fileURL) throws
    func device(_ uid: String) -> DeviceConfig
    func effectiveTrimDb(_ uid: String) -> Double        // 夾 -60…+12（v2 與 levelMatch 無關）
    func effectiveTrimGain(_ uid: String) -> Float
    func measuredLatencyMs(_ uid: String) -> Double?     // 非有限／負值 → nil
    func effectiveDelayMs(_ uid: String) -> Double       // 【舊版】v1 補償值；v2 的延遲請用 plan()／engine.plan
    var startupPlayMode: PlayMode                         // mode.fixed ?? .music
    static func migrateV1(_ c: inout Config)
}
```

**v1 → v2 遷移**（沒有 `version` 欄位的檔案）：
- 校正過（`calibratedAt` 有值或任一 `delayMs > 0`）→ `measuredLatencyMs = max(delayMs) − delayMs`（v1 的 delayMs 就是「最慢 − 自己」）。實際檔案：內建 0、MSI 1.26、電視 34.46。
- `levelMatch == false` → 所有 `trimDb` 歸 0（v1 時沒生效，避免升級後音量突然改變）。

### plan()（純函式）
```swift
struct PlanDevice: Equatable {
    let uid: String, name: String, latencyMs: Double?, enabled: Bool, isBuiltIn: Bool
    init(uid:name:latencyMs:enabled: = true, isBuiltIn: = false)
    init(uid: String, name: String, isBuiltIn: Bool, config: Config)   // 從設定取 latency／enabled
}
struct PlanEntry: Equatable, CustomStringConvertible { let active: Bool; let delayMs: Double; let reason: String }

// PlanDevice 另有 needsRecalibration（由 init(config:) 帶出，只對 requiresMeasurement 的裝置）
func plan(devices: [PlanDevice], mode: PlayMode, caps: ModeCaps = ModeCaps(),
          maxDelayMs: Double = Config.maxDelayMs,
          silenceAfterReconnect: Bool = Config.silenceBluetoothAfterReconnect) -> [String: PlanEntry]   // key = uid
```
規則：
1. `enabled == false` → 不出聲（「已關閉」）。
2. 延遲 = `latencyMs`；未量測時內建喇叭視為 0，其他裝置在有上限的模式不出聲、音樂模式出聲但不補償（delay 0）；
   `requiresMeasurement`（藍牙只輸出路徑）未量測 → **任何模式都不出聲**（理由「未校正：…」；A2DP 本身延遲上百 ms，不補償會變回音）。
3. 基準 = 啟用且有延遲值的裝置裡最快的；相對延遲 = 延遲 − 基準。
4. 相對延遲 > 模式上限 → 不出聲；> `maxDelayMs`（延遲線補不到）→ 不出聲。
5. 補償只在出聲的裝置間重算：`delayMs = 出聲裝置最大相對延遲 − 自己的相對延遲`。
6. 保底：有啟用的裝置但一台都沒出聲 → 啟用的全部出聲、延遲 0（`requiresMeasurement` 的裝置只有在它是唯一啟用的裝置時才算進保底）。
7. 【2026-09-29】`needsRecalibration`（藍牙重連後）：`silenceAfterReconnect` → 不出聲（「未校正：重新連線後…需要重新校正」）；
   否則照舊值參與，出聲時理由加「重新連線後未重新校正，沿用舊值」。

實測延遲下的結果（`plan-selftest` 全部通過）：

| 模式 | 內建（0） | MSI（+1.26） | 電視（+34.46） |
|---|---|---|---|
| 音樂（不限） | 出聲 34.46 ms | 出聲 33.20 ms | 出聲 0 |
| 影片（80 ms） | 出聲 34.46 ms | 出聲 33.20 ms | 出聲 0 |
| 遊戲（20 ms） | 出聲 1.26 ms | 出聲 0 | **不出聲** |

## 3. Engine【v2 新增】

原有 API 見 §4。以下是 v2 新增／改變的部分。所有方法可從任何**非即時**執行緒呼叫（內部序列化到 engine queue）；
**但可能等很久**（rebuild 中、第一次等授權對話框）→ **主執行緒不要直接呼叫**，AppState 已經把所有 engine 呼叫丟到自己的 `control` queue。

### 模式與出聲計畫
```swift
init(config: Config = Config.load(), mode: PlayMode? = nil)   // mode nil → config.startupPlayMode
var mode: PlayMode { get }
func setMode(_ m: PlayMode)           // 依 plan() 重算；不重建聚合裝置；出聲↔不出聲與延遲改變都淡入淡出
var plan: [String: PlanEntry] { get } // 聚合裝置輸出＋已註冊的外接輸出
func planEntry(uid: String) -> PlanEntry?
var onPlanChange: (([String: PlanEntry]) -> Void)?   // engine queue 上呼叫；模式、設定、rebuild、外接註冊都會觸發
func applyConfig(_ c: Config)         // 【v2】延遲不再讀 delayMs，而是 plan(measuredLatencyMs, enabled, modeCaps) 重算
```
- **不爆音**：RT 每個輸出有 `active`（0/1）遮罩乘進增益 ramp（約一個 IO 週期，512 frame ≈ 10.7 ms）；
  延遲改變時先用舊延遲淡出到 0、下一週期換新延遲再淡入（`engine-selftest` §4、§5 驗過波形；**聽感未實測**）。
- `status().outputs[i].active`、`status().mode` 可讀；狀態行不出聲的輸出前面有 `✕`。
- 2026-09-28 實機（`engine-live-test`）：遊戲→影片→音樂切換，遮罩與延遲都等於 plan()、generation 不變、IO 持續前進。

### tap 排除清單（系統提示音用）
```swift
@discardableResult func setExtraExcludedProcesses(_ objs: [AudioObjectID]) -> Bool
var extraExcludedProcesses: [AudioObjectID] { get }
@discardableResult func setExtraExcludedBundleIDs(_ ids: [String]) -> Bool   // macOS 26+：CATapDescription.bundleIDs＋processRestoreEnabled
var extraExcludedBundleIDs: [String] { get }
static var bundleIDTapSupported: Bool { get }
```
- bundle id 排除：行程結束後重啟（pid／process object 都換）也自動套用。app 在 `engine.start()` **之前**就設好
  （`SystemSoundsRouter.bundleIDs` ＋目前的 process object），所以第一個 tap 建立時 systemsoundserverd 就不會被靜音；
  結束時先 `engine.stop()` 再 `systemSounds.stop()`（反過來的話結束前那一瞬間會靜音它）。
- 正常模式的全域 tap 額外排除這些 Core Audio process object（自己一定排除）。被排除的行程**不被 tap 靜音、不進節目音**，照它自己的輸出裝置出聲。
- 運轉中先直接改 tap 的 `kAudioTapPropertyDescription`（保留原 UUID），失敗才 rebuild。實機：設定一個 process object → 直接更新成功、未重建、IO 仍前進。
  **「被排除的行程真的不被靜音」這件事還沒有用聲音驗證**（系統 owner 要驗）。
- 未運轉時設定：下次 start 生效。

### 外接輸出＋節目音共享環形緩衝（藍牙只輸出路徑用）
```swift
var program: ProgramRing { get }      // engine init 配置、deinit 釋放；跨 rebuild 存在（指標永遠有效）
func registerExternalOutput(uid: String, name: String, isBuiltIn: Bool = false) -> Int?   // 槽位 0..<4；uid 重複或槽滿 → nil
func unregisterExternalOutput(slot: Int)   // 先停 IOProc 再呼叫
var externalOutputs: [(slot: Int, uid: String, name: String)] { get }   // 【2026-09-29】已註冊的外接輸出
static func soloValue(externalSlot: Int) -> Int                        // = ProgramRing.externalSoloBase + 槽位，給 setSolo
var allowUncalibratedExternal: Bool   // 【只給校正子行程】未量測的外接輸出照「未量測、不補償」出聲（音樂模式）；預設 false、不存檔
```
```swift
struct ProgramRing {            // 值型別、全是預先配置的指標，IOProc closure 可以直接捕捉
    static let frames = 1 << 17 (≈2.7 s @48k), channels = 2, maxExternal = 4
    let capacity: Int, mask: Int
    let data: UnsafeMutablePointer<Float>          // 交錯立體聲，frame t 在 index (t & mask)*2
    let writeEnd: UnsafeMutablePointer<Int64>      // 已寫入最後 frame + 1（engine sampleTime）；< 0 = 從未寫入
    let sampleRate: UnsafeMutablePointer<Double>   // engine 取樣率；0 = 未運轉
    let generation: UnsafeMutablePointer<Int>      // 每次 start/rebuild +1 → 讀取端重新對時
    let muteProgram: UnsafeMutablePointer<Int>     // 1 = 校正中節目靜音（讀取端自己乘上）
    let solo: UnsafeMutablePointer<Int>            // 【2026-09-29】與 engine 共用的診斷 solo：-1 全部；0..<nOut 聚合輸出；
                                                   //   externalSoloBase(1000) + 槽位 = 只有該外接輸出（聚合輸出全部 0）
    let extUsed, extActive: UnsafeMutablePointer<Int>        // [maxExternal]
    let extGain: UnsafeMutablePointer<Float>                 // [maxExternal] 音量倍率 × trim × active（未含 muteProgram）
    let extDelayFrames: UnsafeMutablePointer<Int>            // [maxExternal] plan 補償（engine 取樣率的 frame）
    func read(from t: Int64, frames n: Int, into dst: UnsafeMutablePointer<Float>) -> Bool   // RT-safe；失敗填 0
    func clock() -> (sampleTime: Int64, hostTime: UInt64)?   // RT-safe；最近 IO 週期起點
    func write(...)   // 只有 engine IOProc 用
}
```
- 寫入端：engine 聚合 IOProc 每週期把**原始 tap 輸入（未延遲、未乘增益）**寫在 frame `[t0, t0+n)`，發佈 `writeEnd`，
  再用 seqlock 發佈 `(t0, 聚合裝置輸出 mHostTime)`：延遲 0 的聚合輸出在 mHostTime 播出 frame t0。
- 讀取端可以有多個，各自記讀取位置；`read` 在拷貝前後各讀一次 `writeEnd`，區間未寫入或已被覆寫 → false（輸出靜音、計數、重新對時）。
- HAL 跳號（`t0 > writeEnd`）：`write` 先把空洞 `[writeEnd, t0)` 補 0（≥ capacity 就整個 ring 清零）再發佈新的 writeEnd，
  讀取端掃過空洞讀到的是靜音，不是 capacity 之前的舊節目音（`engine-selftest` §6）。
- 外接輸出永遠不是音量來源（音量來源一定在聚合裝置裡），增益 = 音量來源倍率 × trim × active。
- 實機：writeEnd 前進、讀最近 512 frame 成功、未來區間失敗、hostTime 有值、取樣率一致；外接槽在音樂模式出聲、遊戲模式（未量測）不出聲。

### 狀態型別變更
- `EngineStatus.Output` 新增 `uid`、`active`；`EngineStatus` 新增 `mode`；`line`／`changeKey` 含模式與遮罩。
- `extension Engine: @unchecked Sendable`（內部已序列化）。

## 4. Devices.swift【v2 變更】

原 API 不變，另外：
```swift
extension DeviceKind { var isBluetooth: Bool }                  // .bluetooth / .bluetoothLE
static func physicalOutputs() -> [AudioDevice]   // 【v2】再排除藍牙（藍牙改走只輸出路徑）
static func bluetoothOutputs() -> [AudioDevice]  // 有輸出、alive、未排除的藍牙裝置（含同時有麥克風的）；依 id 排序
static func outputsWithInput() -> [AudioDevice]  // 【v2】不含藍牙
```
- 音量來源仍是「預設輸出（在 physicalOutputs 裡、有 VolumeDecibels）否則內建」（`ReconnectRules.desired`）。
  **預設輸出是藍牙喇叭時**，音量來源退回內建，DefaultOutputGuard 會提示（音量鍵只調到藍牙那台）。
- 實測裝置：GLASS5+ 以兩台裝置出現（`…:output` 2ch 44.1 kHz、`…:input` 1ch 8 kHz），transport 都是 bluetooth。
  其餘見 README（內建 `BuiltInSpeakerDevice`、MSI HDMI、電視 DP、C270、iPhone Continuity 麥克風、「全部喇叭」排除）。

## 5. 校正（Calibrate.swift）【v2 變更】

- `runCalibrate` 開頭 `engine.setMode(.music)`（所有輸出出聲、補償照實測）。`--verify` 用 `engine.planEntry(uid:).delayMs` 當現有補償。
- 寫入：`measuredLatencyMs = lat − min(lat)`（相對聚合裝置裡最快的輸出），`delayMs` 舊欄位照寫；`--level` 量測時把 trim 全歸 0。
- 麥克風選擇：
```swift
struct CalibrationMic: Identifiable, Equatable {
    let uid, name: String; let kind: DeviceKind; let sampleRate: Double; let channels: Int
    let isContinuity: Bool          // iPhone 麥克風：只准用於校正
    let isAutomaticChoice: Bool     // = Devices.microphone()
}
func availableCalibrationMics() -> [CalibrationMic]   // 實體輸入＋Continuity；排除自己的聚合／「全部喇叭」／虛擬；列出不會開任何麥克風
func resolveCalibrationMic(uid: String?) -> AudioDevice?   // nil → 自動（不含 Continuity）；指定 → 必須在清單裡，否則 nil（不要默默換別支）
```
  CLI：`In_Unison42 mics`、`calibrate --mic <uid>`；未給 `--mic` 時用 `config.calibrationMicUID`。
  藍牙輸入（例如 GLASS5+ `:input`）會列出但標「會切到 HFP」，面板要警告。**Continuity 麥克風校正尚未實測。**
- 【2026-09-29】`calibrate --pulse`／`--verify-program`／`--volume-test` 也量藍牙（ProgramPath.swift）：子行程 `ppAttachBluetooth` 開自己的
  `BluetoothOutManager(watchDeviceList: false)` attach 每台藍牙輸出（絕不開輸入）；量測對象 `PPTarget`（聚合輸出＋外接，各帶 solo 值）；
  有外接參與時脈衝間隔 ≥ 2 秒、solo 餘裕加 60 ms、錄音尾巴加 1 秒；外接的到達時間用該台所有脈衝的寬窗（0.45 × 間隔、上限 900 ms）
  GCC-PHAT 曲線同相累加找，再平移搜尋窗；每台另印匹配濾波「solo 脈衝 vs 安靜段」dB。`--pulse` 時打開 `allowUncalibratedExternal`；
  只有外接的脈衝不合格 → 略過它（印 ⚠、不寫它、面板不算失敗），其他照寫；聚合輸出不合格 → 整個不寫。
  CLI 旗標：`--no-bluetooth`、`--bt-uncalibrated`（驗證時讓未校正藍牙照不補償出聲，實機測試用，預設關）。
  `--check-silent` 對不出聲的外接輸出：依實測延遲往後找（窗 460 ms），沒量過就找 0.4 × 間隔（≤ 800 ms）。
- 【2026-09-29】測試音可選（ProgramPath.swift）：
```swift
struct PPSignal: Hashable {            // .noise（預設）、.xylophone（木琴 C5）、.xylophoneStrongClick（喀 5 ms ×0.7）
    var kind: Kind; var clickSeconds: Double; var clickPeakRatio: Double
    static func parse(_ s: String) -> PPSignal?   // noise｜xylo｜xylo-strong
    var soundSeconds: Double           // 播放長度：雜訊 0.08 s、木琴 0.6 s（脈衝間隔 ppPeriod 依它加大）
    func playback(rate:) -> [Float]    // 一下的波形
    func template(rate:) -> [Float]    // GCC 模板：雜訊＝整個脈衝、木琴＝前 300 ms
}
enum XyloParams                        // f0 523.25、分音 (1,1,0.45)(3.93,0.35,0.12)(9.2,0.12,0.04)、起音 0.8 ms、峰值 −12 dBFS、播放 0.6 s（0.45 s 起淡出）
func ppXylophone(rate:clickSeconds:clickPeakRatio:) -> [Float]   // 固定種子
final class PPGcc {
    func setNoise(psd: [Double], m: Int)          // 啟用 SNR 加權（木琴）：安靜段功率譜（PPGcc.noiseSpectrum）換算到這個 FFT 長度、±16 bin 平滑
    func weights(for seg: [Float]) -> [Float]     // PHAT：頻帶內 1；SNR 加權：SNR/(1+SNR)，SNR_f = g²|T_f|²/N_f
    func curve(_ seg: [Float], weights: [Float]? = nil) -> [Float]   // 安靜段比較要傳脈衝窗的權重（同一個濾波器）
}
struct PPCluster { kept, total, mean, spread, tiedOtherMean, ok, summary }
func ppLargestCluster(_ values: [Double], width: Double) -> PPCluster   // 寬度 < width 的窗裡成員最多的一群；平手取較早；ok = ≥ 3 且 ≥ 一半
func runProgramPathSelfTest() -> Int32   // calibrate --selftest 會一起跑
func runPPReanalyze(_ args: [String]) -> Int32   // pp-reanalyze <dir>：離線重新分析 --dump 的錄音
func runPPSignal(_ args: [String]) -> Int32      // pp-signal <訊號> <out.wav>
```
  `runVerifyProgramPath(…, signal: .noise, signalFor: [uid|名稱: PPSignal], dumpDir:, abSignals:)`；CLI `--signal noise|xylo|xylo-strong|ab|ab-strong`、
  `--signal-for <uid|名稱>=<訊號>`（只有那台換測試音）、`--dump <dir>`。`ab`：同一段錄音兩種測試音交錯（參考每組 [A,B]、其他每組 [A,B,A,B]），
  各自用參考喇叭同種脈衝擬合，印每台兩種的差（門檻 0.3 ms；只驗證、不寫）。
  **木琴實機驗收未通過**（[TESTLOG.zh-TW.md](TESTLOG.zh-TW.md)「木琴測試音評估」）。
- 【2026-09-29 第二版】預設測試音 `PPSignal.pink`：`ppPinkBurst(rate:lo:hi:)`（頻域 1/√f、隨機相位、1–4 kHz、邊緣 200 Hz 升餘弦、80 ms、RMS −22 dBFS、固定種子）。
  `PPSignal.gccBand`／`gccEnvelope`：pink = (1000, 4000)、包絡；其他 = (300, 7000)、載波。`PPGcc(template:searchLength:rate:band:envelope:)`：
  envelope = true 時曲線是解析訊號的絕對值（只留正頻率做複數反 FFT，`vDSP_fft_zip`），峰值＝該頻帶的群延遲，不會在載波週期間跳。
  `PPParams.pulsesPerOutputPerRound = 2`（每台 4 個）、`PPParams.calibrationGainDb = −8`。
  `runVerifyProgramPath(…, signal: .pink, calibrationGainDb: −8)`；CLI `--signal pink|ab-pink`、`--cal-gain-db <dB|off>`。
- 【2026-09-29 13:30】`Engine.calibrationFixedGainExternal: Float?`（外接輸出另用的固定增益；`PPParams.calibrationGainExternalDb = −24`；2026-10-04 改 −12，削波時 app 自動用 −24 重量一次：`PPParams.calibrationGainExternalFallbackDb`、環境變數 `IN_UNISON42_BT_CAL_GAIN_DB`、子行程印 `@@mic-clip`）、
  `Engine.calibrationPilotDb: Double?` → `ProgramRing.extPilot`（外接輸出持續加 150 Hz pilot；`BTRenderer.render` = `renderProgram` 之後加 pilot，任何狀態都加；
  `PPParams.bluetoothPilotDb = −40`）。只有校正子行程會設。原因：藍牙耳機靜音一陣子會關輸出、吃掉短脈衝。
- 診斷：`bt-tone-test raw|raw-tap|btout [--amp a]`、`bt-tone-test gate [--pilot dB]`（CLI/BTToneTest.swift；選單列 app 要先結束，用 app 身分跑）。
- 【2026-09-29】`Engine.calibrationFixedGain: Float?`（只給校正子行程）：非 nil 時音量來源以外的輸出（聚合裝置 index ≥ 1、外接藍牙）
  目標增益 = 固定增益 × trim（× active），**不乘系統音量倍率**；音量來源（index 0）照舊 = trim（硬體音量）。夾在 0…1；靜音時仍 0。

## 6. 仍有效的第 1 版內容（摘要）

- `CA`（屬性薄包裝）、`AudioDevice`、`SystemAudioSnapshot.capture()/restore()`、`Cleanup.register/unregister/runAll`、
  `Reconnector(engine:).start()/stop()/requestRebuild(_:)`、`ReconnectRules.desired/volumeKeyWarning`、`findRunInstances()`
  （【v2】app 模式——沒有參數或 `-psn…`——也算實例）、`writePidFile()`、`rotateStdoutLogIfNeeded()`、`moveToTrash(_:dryRun:)`：用法同前。
- Engine 原有：`start/stop/rebuild`、`sampleTime/ioCycles/ioSkips/generation/sampleRate`、`outputs/outputDetails`（index 0 = 音量來源）、
  `setMonitorMode`、`playTestSignal/isTestSignalActive/cancelTestSignals`（測試訊號**不受** active 遮罩影響）、`status()`、`onFormatChange`、
  診斷 `programProcesses/setSolo/armOnset/onsetSampleTime`。輸入 buffer 排列規則不變（tap 在子裝置輸入之後）。
- CLI：`run [--force] [--mode music|movie|game]`（設定是 auto 時 CLI 用音樂）、`calibrate …`、`devices`、`status`（v2 顯示實測延遲、三種模式的計畫、app 的 state.json）、
  `stop`／`uninstall`（舊 LaunchAgent）、`*-selftest`、`engine-live-test`、`panel-snapshot`。
- 【v2】`install`（LaunchAgent）停用：app bundle 的執行檔單獨複製出去會失去 Info.plist 與固定身分。

## 7. App 層（App/*.swift）

### `AppState`（`@MainActor final class: ObservableObject`，`AppState.shared`）
```swift
// 給面板讀
@Published private(set) var config: Config
@Published private(set) var devices: [DeviceRow]      // 聚合裝置輸出（engine 順序）＋藍牙；engine 沒在跑時照裝置與 plan() 現算
                                                       // DeviceRow.needsRecalibration（藍牙重連後）→ 面板該列加「請重新校正」
@Published private(set) var playMode: PlayMode        // 生效模式
@Published private(set) var modeReason: String?       // 自動模式的理由（ModeManager 給）
@Published private(set) var warnings: [AppWarning]    // kind: permission / defaultOutput / otherInstance / engine / bluetooth
@Published private(set) var running: Bool, ioAdvancing: Bool, engineStarting: Bool
private(set) var statusLine: String                   // 【2026-09-29】不再 @Published（每秒變）；面板要顯示請綁 meters.statusLine
@Published private(set) var calibrationMics: [CalibrationMic]
let meters: LiveMeters                                // 【2026-09-29】高頻數值，見 §11
private(set) var panelVisible: Bool; func setPanelVisible(_ visible: Bool)   // PanelView onAppear／onDisappear 呼叫
var menuBarSymbol: String                             // speaker.slash / exclamationmark.triangle / hifispeaker.2 / film / gamecontroller
// 元件
let engine: Engine; let modeManager: ModeManager; let bluetooth: BluetoothOutManager
let systemSounds: SystemSoundsRouter; let outputGuard: DefaultOutputGuard
// 生命週期（AppDelegate 呼叫）
func start(); func stop()
// 使用者動作（面板呼叫；全部會存檔並套用，不重建聚合裝置）
func selectMode(_ m: AudioMode)            // .auto → 解除鎖定並 modeManager.reevaluate()；其他 → 手動鎖定
func setDeviceEnabled(_ uid: String, _ on: Bool)
func setTrim(_ uid: String, _ db: Double)  // 夾 -60…+12，存到 0.1 dB
func setCalibrationMic(_ uid: String?)
func setAutoModeRule(bundleID: String, mode: AudioMode?)
func switchDefaultOutputToVolumeSource()   // → outputGuard.switchBackToVolumeSource()
func runCalibration()                      // TODO(UI)
func quit()
func updateConfig(_ mutate: (inout Config) -> Void)
func reloadConfig()                        // 外部（CLI calibrate）改了 config.json 後
func refresh(full: Bool = true)            // engine 快照在背景 queue 取；值有變才賦值。full=false（面板關著時的每秒 tick）沿用上次的藍牙清單／預設輸出警告
func refreshNow()                          // 同步（離屏截圖用）
```
```swift
struct DeviceRow: Identifiable, Equatable { uid, name, kind, inAggregate, isVolumeSource, enabled, trimDb, measuredLatencyMs, plan: PlanEntry?, peak: Float = 0 /* 【2026-09-29】永遠 0，峰值改讀 LiveMeters.outputPeaks */ }
struct AppWarning: Identifiable, Equatable { kind, message, actionTitle: String? }
struct AppRuntimeState: Codable { pid, updatedAt, running, generation, ioCycles, sampleTime, mode, configMode, manualLock, line }   // state.json
enum AppLog { static func line(_:); static var fileURL: URL }
```
啟動順序：（登入項目已啟用且舊 LaunchAgent 還在 → 自動遷移）→ 每秒 timer → `acquireTapInstance()`（拿不到：otherInstance、每秒重試；
`LoginItem.legacyMigratedNotification` 也會觸發重試）→ 設提示音排除 → `writePidFile` → **背景** `engine.start()` → 回主執行緒後 `Reconnector.start` →
`modeManager.start(config:)` → `bluetooth.start()` → `systemSounds.start()` → `outputGuard.start()`。
結束：outputGuard → bluetooth → modeManager → reconnector → `engine.stop()` → `systemSounds.stop()` → `InstanceLock.release()`。元件的 `start/stop` 都在主執行緒呼叫。

## 8. 各 owner 的介面與注意事項（stub 已在檔案裡，含詳細 TODO）

### 8.1 UI（`UI/Panel.swift`）
- `struct PanelView: View`（`@EnvironmentObject var state: AppState`），寬約 320 pt。現在是最小可用版：模式 segmented、裝置開關、警告、結束。
- 要做：依 HIG 重做、每台 trim slider（`setTrim`）、峰值、不出聲時顯示 `plan.reason`、手動鎖定提示與「回到自動」、校正區（麥克風下拉＋按鈕）、
  自動模式對照表編輯、登入時啟動開關（`LoginItem`）。
- `runCalibration()`：唯一允許改 AppState 的地方。建議：停 engine＋reconnector → 子行程 `Bundle.main.executableURL calibrate [--mic uid]`（同身分、同 TCC）→ 讀 stdout 顯示進度 → `reloadConfig()` → 重新 start。
  注意 `cmdCalibrate` 會拒絕「有別的 run 實例在跑」：子行程啟動前 app 自己的 engine 必須已停，但 app 行程本身也會被 `findRunInstances()` 算進去 →
  **需要架構負責人加一個「由 app 呼叫」的旗標**（回報後再加，不要自己改 CLI.swift）。
- 截圖：`In_Unison42 panel-snapshot out.png`。**已知限制**：ImageRenderer 畫不出 AppKit 背書的控制項（segmented Picker、switch Toggle 會變成黃底禁止符號）；
  驗收版面時要換成可離屏渲染的樣式或接受佔位。

### 8.2 模式（`Mode/ModeManager.swift`）
```swift
struct FrontApp: Equatable { let bundleID: String?; let name: String; let categoryType: String? }
enum ModeRules { static let ownBundleID; static func resolve(_ app: FrontApp?, rules: [String: AudioMode]) -> (mode: PlayMode, reason: String) }  // 已實作
@MainActor final class ModeManager {
    var onResolvedModeChange: ((PlayMode, String) -> Void)?   // 主執行緒
    func start(config: Config); func stop(); func update(config: Config); func reevaluate()
}
func runModeSelfTest() -> Int32
```
- 規則：對照表 → `LSApplicationCategoryType` 以 `public.app-category.` 開頭、`games` 結尾 → 遊戲 → 否則音樂。
- 手動鎖定時不送事件；自己（面板打開時會變前景）要忽略；Cmd-Tab 掃過要去抖動。

### 8.3 系統（`System/*.swift`）
- `SystemSoundsRouter(engine:)`：`start()` 把系統提示音輸出設成內建（記原值）、`engine.setExtraExcludedBundleIDs(["systemsoundserverd"])`＋找系統提示音行程 → `engine.setExtraExcludedProcesses`；監聽 `kAudioHardwarePropertyProcessObjectList`；`stop()` 還原。`cmdSystemSounds`。
- `LoginItem`：`status`、`isEnabled`、`setEnabled(_:)`（`SMAppService.mainApp`）、`migrateFromLaunchAgent()`（bootout＋plist／bin 移垃圾桶）。
  目前 `SMAppService.mainApp.status` = 3（notFound，app 在 build/ 底下）；要先決定安裝位置（~/Applications？）。`cmdLoginItem`。
- `DefaultOutputGuard(engine:)`：`evaluate()`／`static evaluate(engine:)` 已實作（沿用 `ReconnectRules.volumeKeyWarning`）；
  要做 `start/stop` 監聽預設輸出、`switchBackToVolumeSource()`（`Devices.setDefaultOutput(id, alsoSystemOutput: false)`，不動音量）。`cmdOutputGuard`。

### 8.4 藍牙（`Bluetooth/BluetoothOut.swift`）
- `BluetoothOutput(engine:device:)`：`start() throws`、`stop()`、`slot`、`stats`；`BluetoothOutManager(engine:)`：`start()`、`stop()`、`outputs`。
- **絕不開輸入**：建立 IOProc 後、Start 前用 `kAudioDevicePropertyIOProcStreamUsage` 關掉所有輸入 stream；失敗就不要 start。
- 對時：`program.clock()` 的 (sampleTime, hostTime) ＋ `program.sampleRate` → 把藍牙 IOProc 的輸出 hostTime 換成 engine 時間 T；
  讀 `T − extDelayFrames[slot] − safety`。safety（固定 10–30 ms）是這條路徑自己的延遲，會被量進 measuredLatencyMs，所以要固定。
- 自適應重取樣：GLASS5+ 是 44.1 kHz、engine 48 kHz；比例 × 漂移修正（前饋＋PI，夾在 ±`BTParams.maxPPM` = **±500 ppm**）；預先配置 scratch。
  前饋在 engine 換世代後重新下錨，跨度 ≥ `ffReanchorSpan`（5 s）才採用（已有前饋值時不拿短跨度的雜訊估計覆蓋）。
- 換世代：`Engine.startLocked` 在新 IOProc 開始寫之前呼叫 `ProgramRing.beginGeneration(sampleRate:)`——清掉舊時間軸的 `writeEnd`、時鐘（`clock()` 回 nil）與資料，
  再設取樣率、`generation +1`。藍牙在新 engine 第一次寫入前只算「閒置」（不欠載、不重對時），也不會把舊時間軸的錨點帶進前饋速率量測。
  （2026-09-29 修正：原本只 `generation +1`，藍牙拿舊時鐘外插 → 每次校正暫停／恢復欠載＋重對時各 22–25 次；前饋錨點落在舊時間軸 →
  修正偏 −250 ppm、誤差擴大到 −354 frame、約 4.5 分鐘才收斂。`bluetooth-selftest` 5b 重現舊行為並驗證修正。）
- 停止：`AudioDeviceStop`／`DestroyIOProcID` 任一失敗或裝置已死（斷線）→ renderer 延遲 `deferredFreeSeconds`（5 s）才釋放（IOProc 可能還在跑最後一個週期）。
- HFP：藍牙取樣率 < `BTParams.minA2DPRate`（32 kHz）→ 停 IO、保留屬性監聽、**不出聲**（`isHFPPaused`，面板警告）；回到 A2DP 自動重開。
  取樣率改變重開／HFP 暫停與恢復 → `onRestart(out, err, latencyMayChange: true)` → `BluetoothOutManager.onLatencyMayChange(uid, 原因)` →
  AppState `markBluetoothNeedsRecalibration`（和重連同一個標記）。engine 換取樣率時，藍牙 renderer 已有該取樣率的 sinc 表就不重開串流
  （`allSupportEngineRate`），要重開才標記。
- 增益：`extGain[slot] × (muteProgram == 0)`，每週期 ramp；`extActive == 0` 淡出。
- 校正：【2026-09-29 已做】見 §5 末；量到的 measuredLatencyMs 與聚合裝置同一基準（參考＝主時鐘喇叭），含固定緩衝與 A2DP 延遲。
- solo：`ring.solo >= 0 && != externalSoloBase + slot` → 目標增益 0。
- 重連：`BluetoothOutManager.onReconnect: ((uid) -> Void)?`（主執行緒）——同 uid 消失再出現、或 AudioObjectID 換了，重新 start 成功時呼叫；
  `simulateReconnect(uid:) -> Bool`（detach＋當作消失過＋attach，ctl／測試用）。~~AppState 收到 → 量過延遲的裝置 `needsRecalibration = true`。~~
  【2026-09-29 Kang 定案，§12】重新接上 → 沿用舊值出聲，只寫 log；app 重開後的藍牙才暫停出聲＋自動重校。取樣率改變重開／HFP 仍標 `needsRecalibration`。
- 讀取點＝固定目標延遲鎖定：每週期由時間戳重算 `P = T − 延遲 − safety`，PI／前饋只修比例與相位 → 延遲不隨時間漂。

## 9. 已知問題（2026-09-28）

- 第一次啟動時授權對話框會讓 `AudioDeviceCreateIOProcIDWithBlock` 卡住（實測 90 秒，使用者按允許後才回來）；之後 Reconnector 會因「IOProc 從未前進」重建一次，然後正常。
- 從終端機（Ghostty）直接跑 CLI 的 TCC 責任行程是 Ghostty，不是 app（`kTCCServiceAudioCapture` 另外授權）；需要 IO 的 CLI 測試請用 `open -W --stdout … --args <指令>`。
- `calibrate` 從終端機直接跑、而 app 執行中時會拒絕（兩個 tap 互相靜音）；改用面板或 `ctl calibrate …`（app 先暫停自己的引擎）。
- 模式切換的淡入淡出只有離線波形測試，沒有聽感／錄音驗證。

## 10. 整合階段（2026-09-29）

### AppState 接線
- `CalibrationRunner.shared.pauseEngine／resumeEngine` 在 `engineStartReturned()` 接好（`wireCalibration()`）：暫停＝停 Reconnector、`control` queue 上 `engine.stop()`、`calibrating = true`；
  恢復＝`reloadConfig()` → `engine.start()` → 新 Reconnector。校正中警告改成「校正中：同步播放已暫停」，不顯示「音訊沒有在跑」。
- `runCalibration(extraArgs:)` → `CalibrationRunner.start(micUID: config.calibrationMicUID, extraArgs:)`。
- `selectMode` 之後呼叫 `modeManager.update(config:)`（ModeManager 記憶體裡的鎖定狀態同步）。
- `bluetooth.onChange` → `refresh()`；`BluetoothOutManager.errors` 轉成 `AppWarning(kind: .bluetooth)`。
- `engine.onPlanChange` → `planChanged()`：engine 取樣率變了就 `bluetooth.detachAll(); bluetooth.resync()`（重建 sinc 表）。
- `peakLog`：每次 refresh 記一筆輸入／各輸出峰值（保留 120 筆），給 `ctl peaks`。
- `extension BluetoothOutManager: @unchecked Sendable`（公開方法都在自己的序列 queue 上）。

### CLI／工具
- `cmdCalibrate` 認 `IN_UNISON42_CALIBRATE_PARENT=<app pid>`：這個 pid 不算「擋路的 run 實例」（app 已先停掉自己的 engine）。
- `ctl <指令…>`（`App/AppControl.swift`）：DistributedNotificationCenter `com.kang.In-Unison42.ctl`（userInfo `{id, args}`，`deliverImmediately`），
  app 把回覆寫到 `~/Library/Application Support/In_Unison42/ctl-reply.json`。指令：`state`、`mode <m>`、`snapshot <dir>`（真實 AppState 離屏渲染 4 張 PNG，只寫家目錄底下）、
  `guard-restore`、`calibrate [參數…]`（等同面板開始校正，結束才回覆，含子行程全部輸出）、`peaks <秒>`、`bt status|resync|detach-all|attach <id>|detach <uid>|simulate-reconnect <uid>`
  （status 另列每台藍牙：取樣率、固定緩衝、`BluetoothOutput.Stats`、出聲計畫）、`trim <uid> <dB>`、`reload-config`、`login-item status|on|off`。
  只開放面板本來就能做的事。
- `calibrate --pulse`：用 `--verify-program` 同一把尺（afplay 脈衝＋GCC-PHAT）量延遲並寫入 measuredLatencyMs（預設音樂模式）：
  相對延遲 = 到達差 − 量測時的補償差；【2026-09-29】每台取**最大一致群**（`ppLargestCluster`：寬 < 0.3 ms 的窗裡脈衝最多的一群，
  平手取較早的一群並印「兩群一樣多」），要 ≥ 3 個且 ≥ 一半才寫。取代舊的「中位數 ±0.2 ms、≥ 4 個」（6 個脈衝 3／3 分兩群時中位數落在中間、0 個被採用 → 整次不寫）。
  SNR 不合格的脈衝不採用（印 ⚠）；**非參考喇叭不合格只略過那台**（保留舊值），其他照寫；參考喇叭有不合格脈衝或一致群不足 → 整次不寫。
  藍牙（外接輸出）窗寬 1.0 ms；聽不到（0 個合格脈衝）或不穩只略過它（保留舊值與 needsRecalibration）。面板「開始校正」用這個。
- 校正麥克風：**藍牙輸入一律不可用**（`Devices.isUsableMicrophone` 排除、`availableCalibrationMics` 不列、`--mic`／設定值指到藍牙輸入直接失敗、
  `MicRecorder.start()` 對藍牙裝置回 `kAudioHardwareIllegalOperationError`）——開了會把藍牙喇叭切到 HFP，量到的也不是 A2DP 的延遲。
- chirp `calibrate`／`--verify`：到達位置取「最早到達」（最大峰前 15 ms 內、不低於最大峰 6 dB、高於雜訊平均 12 dB、至少早 2 ms 的局部峰），
  不取包絡最大值（內建喇叭的反射可能比直達聲強；合成自測 K／K2／K3）。
- `snapshot-live-test`：實機驗證 `SystemAudioSnapshot` 還原規則（短暫調低音量、切一次靜音與預設輸出，結束回原值）。
- `calibrate --verify-program --check-silent`：另外 solo 目前模式不出聲的輸出，在參考直線預測的到達處做匹配濾波，和安靜段比（差 < 3 dB 才算沒聲音；參考喇叭要比安靜段高 ≥ 10 dB 才判得出來）。
- `mic-probe [--mic q] [--seconds s] [--burst|--beep|--none]`：錄麥克風、第 1 秒觸發，回報 RMS 與（burst）匹配濾波比底噪高幾 dB。
- `output-guard set <uid|名稱> --yes`：測試用，只改預設輸出（不動系統提示音輸出與音量）。
- `render-panel <dir>` = `panel-snapshot --fake <dir>`。
- `./build.sh --install`：複製到 `~/Applications/In_Unison42.app`（舊版移到垃圾桶）。
- `CalibrationRunner.start(micUID:extraArgs:)`、`onFinishOnce: ((ok, msg, lines) -> Void)?`、`allLines`；解析器認「✓ … 驗證通過」為成功。
- **校正交接（2026-09-29 整合）**：`CalibrationRunner.usesHandoff(args)`（`--pulse`／`--verify-program`／`--volume-test`，非 `--selftest`）時：
  1. 先啟動子行程（env `IN_UNISON42_HANDOFF=1`、stdin 是 pipe），app 的 engine 照常出聲；
  2. 子行程開好麥克風、藍牙、寫好 WAV、**啟動 afplay 並找到它的 process object** 後印 `@@handoff-ready`；
  3. app `pauseEngine` → 拆完 tap 寫 stdin `go`；子行程只剩 `engine.start()`。子行程等 go 的**上限就是 afplay 啟動後 `leadSeconds − 0.4` 秒**
     （`ppWaitHandoff(deadline:)`，2026-09-29 審查修正：以前固定等 15 秒、回來才判「太慢」，這段時間第一個脈衝已從 app 還在跑的 tap 播到所有喇叭）；
     逾時立刻 `terminate` afplay（脈衝還沒播）並失敗。stdin 寫端設 `F_SETNOSIGPIPE`：子行程先結束時 app 寫 go 只會丟錯誤、不會被 SIGPIPE 殺掉；
  4. 子行程 `ppRun` 裡 `engine.stop()` 後印 `@@tap-released` → app 立刻 `resumeEngine`（用舊設定重建 tap）；
  5. 子行程結束 → `reloadAfterCalibration`（只 `reloadConfig()`＝applyConfig，不重建）。子行程在準備階段就結束（沒暫停過）→ 也只重讀設定。
  `@@handoff-ready`／`@@tap-released` 不寫進 allLines（`@@measured` 照寫，自動校正要用）。總開關 `CalibrationRunner.handoffEnabled`。實測 coreaudiod：沒有 tap 的空窗開始 85 ms、結束 99 ms（以前開始約 1 秒）。
- 成功判定：結束代碼 0 且（沒有行首 ✗ 或印了「✓ 已寫入」）。寫入模式的藍牙到達差那行不再標 ✓／✗（補償歸 0 時本來就不會 < 3 ms）。
- 設定檔唯讀保護：`AppWarning.Kind.config`（完整刷新時讀 `Config.writeProtection()`），面板按鈕「重設設定」→ `AppState.resetConfigToDefaults()`。
- 除錯版 `ctl autocal simulate-appear <uid>` → `AppState.simulateDeviceAppeared(_:)`：給 AutoCalibrator 一次沒有它、一次有它的觀察（實機驗證新裝置倒數用）。
- `PanelSnapshot.renderCurrent(to:dark:appKit:)`：執行中的 app 用目前的 @Published 狀態渲染（不呼叫 refreshNow、不碰 engine）。

## 11. 效能（2026-09-29，owner：效能；檔案 App/AppState.swift、Engine.swift 效能段、UI/Panel.swift 資料綁定）

目標：app 平常 CPU 從約 6% 降到 ≤ 2%（**尚未實機量**，量測指令見文末）。

### 11.1 主執行緒刷新（AppState）
- `refresh(full:)`：所有 @Published **值有變才賦值**（playMode、ioAdvancing、modeReason、config、calibrationMics、devices、warnings）。
  `statusLine` 不再是 @Published；`DeviceRow.peak` 永遠 0 → `devices` 不再每秒「變」，選單列圖示與面板不再每秒重算。
- 面板**關著**：每秒只做輕量刷新（`engine.status()`：IO 前進、模式、log、state.json、peakLog），
  **完整刷新**（`Devices.bluetoothOutputs()` 列舉所有裝置、`DefaultOutputGuard.evaluate`）改成事件觸發（plan／藍牙／預設輸出變化、使用者動作，
  這些路徑呼叫 `refresh()` 預設 full）＋每 `AppState.fullRefreshInterval` = 10 秒一次。面板**開著**：每秒完整刷新。
- 面板可見性：`PanelView.onAppear/onDisappear` → `setPanelVisible`；另外每秒用 `NSApp.windows`（非 StatusBar 類別、isVisible、occlusion visible）校正一次。
- `peakLog`（`ctl peaks`）照舊每秒一筆。

### 11.2 `LiveMeters`（`@MainActor final class: ObservableObject`，`AppState.shared.meters`）
```swift
@Published private(set) var statusLine: String
@Published private(set) var inputPeak: Float              // 最近一秒 tap 輸入峰值
@Published private(set) var outputPeaks: [String: Float]  // key = 裝置 UID（聚合裝置輸出；藍牙目前沒有）
```
只在面板開著時更新（關面板時 reset 峰值）。要顯示峰值／狀態行的 view 自己 `@ObservedObject var meters = AppState.shared.meters`，
**不要**把它塞回 AppState 的 @Published（會讓選單列圖示每秒重算）。

### 11.3 state.json
狀態變化（`EngineStatus.changeKey`＋ioAdvancing＋設定模式／鎖定）才寫，另 `AppState.stateFileHeartbeat` = 10 秒心跳。

### 11.4 Engine：音量改屬性監聽
- `AudioObjectAddPropertyListenerBlock`：音量來源的 `VolumeDecibels`／`VolumeScalar`／`Mute`（output scope，main／1／2 中存在的 element）、
  聚合裝置的 `NominalSampleRate`。通知送到專用 `listenerQueue`（只 `or` 進一個 `DispatchSourceUserDataOr`，不等任何東西），
  在 engine queue 上合併成一次 `pollVolumeLocked()`。`stopLocked()` 一律移除。
- `Engine.volumePollInterval` 50 ms → **1 秒備援輪詢**（監聽失敗或漏通知時最慢 1 秒補上；IO 看門狗、取樣率改變偵測也跟著它跑）。
- 診斷：`engine.volumeUpdateStats -> (listeners, listenerEvents, polls)`。

### 11.5 Engine：同 clock domain 關漂移校正
建聚合裝置時讀每個子裝置的 `kAudioDevicePropertyClockDomain`：主時鐘 0；與主時鐘同 domain 且非 0 → `DriftCompensation = 0`；
不同或 0（驅動沒回報）→ 1。純函式 `Engine.needsDriftCompensation(isClock:domain:clockDomain:)`（`engine-selftest` §8）、
`Engine.clockDomain(_ id:)`；`EngineOutput` 新增 `clockDomain: UInt32`、`driftCompensated: Bool`（description 會印）。
log 一行「clock domain：…」。本機三台（內建、MSI HDMI、電視 DP）都是 1835100526 → 全部不開漂移校正（2026-09-29 實機 log 確認）。
**關掉漂移校正會改變相對延遲**：MSI 早到 1.2 ms、電視早到 0.65 ms（漂移校正的重取樣本身有延遲）→ 這個改動之後必須重新校正（已重寫：MSI 0.850、電視 34.320 ms）。

### 11.6 Engine：測試訊號緩衝延後配置
- `RTShared.testBuf` → `testBufRef: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>`：平常 pointee = nil（以前每次 start 配 nOut × 10 秒 ≈ 5.5 MB）。
- `playTestSignal` 第一次呼叫時在 engine queue（非即時）`allocateTestBuffer()`，內容清零、barrier 後才發佈指標；IOProc 讀到 nil 就當沒有測試訊號
  （testState 自己歸 0）。`stop()`／`rebuild()` 一律釋放。
- IOProc 每個輸出每週期**只讀一次** `testState`（`st`），收尾用 `RTShared.shouldEndTest(readState: st, hadBuffer:, finished:)`：
  只有開頭讀到 1 才可能清 0（2026-09-29 審查修正：以前收尾重讀一次，開頭讀到 0、控制端中途 `playTestSignal` 寫 1 → 被清掉、測試音永遠不播）。
  `engine-selftest` 第 7 節涵蓋。
- `engine.releaseTestSignalBuffer() -> Int`（bytes）：校正／測試結束後可主動收回：testState 全 0 → 指標設 nil → 等 IOProc 再跑兩個週期才 free
  （等不到就放棄，留給 stop 釋放）。`engine.testSignalBufferBytes`：目前占用（app 平常應為 0）。
- `engine.prepareTestSignalBuffer() -> Bool`：可選，量測開始前先配置（第一次 playTestSignal 自己配置約幾 ms，排程很緊時開頭可能被截）。
- 呼叫端（Calibrate／LiveTest）**不用改**；建議在 start 之後、第一次排程之前呼叫一次 `prepareTestSignalBuffer()`。

### 11.7 離線量到的（不是 app 實機 CPU）
- `RTShared.render` 3 輸出 × 512 frame：即時負載 0.04% CPU（-O）。
- 一次音量輪詢（本行程側）32 µs → 50 ms 輪詢 0.06%、1 秒 0.003%；列舉 7 個裝置一次 293 µs（本行程側；coreaudiod 側另計、沒量）。
- ⇒ 約 6% 的大宗**不在** IOProc 或音量輪詢本身；嫌疑是每秒 @Published 觸發的 SwiftUI 重算（已修）、coreaudiod IPC 往返、藍牙 renderer、
  Reconnector 每秒健康檢查。要用下面的指令實機確認。

### 11.8 實機量測（整合者做；本輪實作者不能啟動 app）
```sh
PID=$(pgrep -x In_Unison42 | head -1)
top -l 13 -s 5 -pid $PID -stats pid,cpu,mem,threads | awk '/^[0-9]/ {print}' | tail -12   # 1 分鐘，丟掉第一筆；面板關著
# 平均：上一行 | awk '{s+=$2} END {print s/NR "%"}'
sample $PID 10 -file /tmp/iu42-sample.txt   # 看剩下的 CPU 花在哪（main thread vs IOProc vs 藍牙）
```
驗收：面板關著、音樂播放中，1 分鐘平均 ≤ 2%；另記面板開著時的值。舊版（HEAD daa1b31）同條件對照。

**2026-09-29 實測（面板關、音樂播放中，13 筆 × 5 秒）**：舊版 app 5.79%（5.4–6.1）→ 新版 **1.73%**（1.7–1.8）✓；coreaudiod 10.19% → 8.21%。面板開著時的值沒量（不能點開面板）。


## 12. 自動校正（2026-09-29，Kang 定案；檔案 App/AutoCalibration.swift、App/AutoCalNotifier.swift、AppState 自動校正段、UI/Panel.swift `AutoCalibrationBlock`）

### 12.1 規則
| 情況 | 行為 |
|---|---|
| 新的輸出裝置接上（從未校正、沒有 `measuredLatencyMs`） | 使用者通知（附「取消」）＋面板「N 秒後校正〈名〉」倒數 3 秒 → `calibrate --pulse --only <uid>` |
| 已有延遲紀錄的**有線**裝置重新接上 | 直接用舊值出聲，不播測試音 |
| 已有延遲紀錄的**藍牙**真的斷線再連上（第 B 輪 2026-09-29 Kang 定案，`Config.recalibrateBluetoothOnReconnect = true`） | **比照 app 重開**：重新 start 前 engine 先 hold（串流一開始就靜音）→ 交給 `autoCal.holds` → 倒數 3 秒 → `--only <藍牙 uid>`；通知沒授權、面板關著 → `needsConsent`（面板打開才倒數）。見 §13.6 |
| app 重開／登入啟動後，已校正的藍牙（啟動後 `AutoCalibrator.launchGrace` = 30 秒內第一次出現） | **先不出聲**（`Config.calibrationHolds`）＋倒數 3 秒 → `--only <藍牙 uid>`；量到才解除 |
| 倒數中按取消（面板或通知） | 延後；面板留「需要校正」按鈕（按了立刻校正，不倒數） |
| 使用者看不到倒數（面板關著、而且通知權限不是「允許」／「暫時允許」，包括授權對話框還沒回答） | **不自動倒數**：延後成 `needsConsent`，面板留「需要校正」；面板打開或通知允許後自動再倒數（2026-09-29 審查修正） |
| 暫停出聲中的藍牙被使用者關掉再打開 | 放回「需要校正」（`heldAwaitingCalibration`，不自動播測試音）；關著時接上、從未校正的裝置打開 → 「尚未校正」（2026-09-29 審查修正） |
| 校正麥克風被其他 app 占用（`kAudioDevicePropertyDeviceIsRunningSomewhere`，我們平常不開麥克風）／找不到麥克風 | 延後＋通知；麥克風空下來／接上後**自動**再倒數 |
| 多台同時出現／倒數中又來一台 | 合併成一次 `--only a,b`（重新倒數 3 秒） |
| 校正執行中又來一台 | 排隊；這次結束後再倒數一次（同一時間最多一個校正） |
| 使用者自己按「開始校正」／`ctl calibrate` | 倒數中的先擱著（不算取消）；那次量到的就不再自動校正 |

判斷細節：
- 「接上」＝上一次**完整刷新**不在、這一次在（`AppState.apply` 在 `snap.full && running && !calibrating && engine 有輸出` 時呼叫 `observe`；
  engine 重建中／校正中輸出清單是空的，不當成拔掉）。
- **app 啟動時就在、從未校正的裝置不自動校正**，只列「需要校正」（避免每次登入都對麥克風聽不到的裝置播測試音）。
- 自動校正**失敗或被停止**的裝置不自動重試；斷線再接上才會再自動一次，或按「需要校正」。暫停出聲的藍牙量不到 → 仍不出聲（見 12.5 待決）。
- 參考喇叭（音量來源／內建）與使用者關掉的裝置不自動校正。倒數中拔掉 → 從這批拿掉，全拿掉就取消倒數。

### 12.2 型別（純邏輯，`autocal-selftest`）
```swift
struct AutoCalDevice { uid, name, isBluetooth, hasLatency, enabled, isReference }
struct AutoCalEnvironment { micAvailable, micBusy, micName, canRun, userCanSee }   // AppState 每次 tick 量（需要時才讀 Core Audio）；
                                                                                   // userCanSee = panelVisible || AutoCalNotifier.canNotify
enum AutoCalDeferral { cancelled, micBusy, noMic, failed(String), notCalibratedAtLaunch, heldAwaitingCalibration, needsConsent
                       var retriesAutomatically: Bool }   // micBusy／noMic／needsConsent 條件解除後自動再倒數
enum AutoCalAction { countdownStarted(names:seconds:), deferred(names:reason:), startCalibration(uids:), holdsChanged(Set<String>), finished(ok:failed:cancelled:), log(String) }
struct AutoCalibrationStatus { countdownNames, secondsLeft, waitingMessage, runningNames, pending: [Pending], heldNames }   // 面板
final class AutoCalibrator {
    static let countdownSeconds = 3.0, launchGrace = 30.0
    init(startedAt:)
    var phase: Phase   // idle / countdown(deadline) / waiting / running / external
    var holds: Set<String>                                  // 校正完成前不出聲的藍牙
    func primeLaunchHolds(_ uids: [String])                 // engine start 前：已校正的藍牙先暫停出聲
    func observe(_ devices: [AutoCalDevice], now:) -> [AutoCalAction]
    func tick(now:, env:) -> [AutoCalAction]
    func cancel() -> [AutoCalAction]
    func requestNow(uids: [String]? = nil, now:) -> [AutoCalAction]
    func externalRunStarted()
    func finished(measured: Set<String>, cancelled: Bool, message: String, now:) -> [AutoCalAction]
    func status(now:) -> AutoCalibrationStatus
}
func parseMeasuredUIDs(_ lines: [String]) -> Set<String>   // 子行程的 `@@measured uid,uid,…`
```

### 12.3 接線
- `Config.calibrationHolds: Set<String>`：**執行期、不存檔**（`Config.CodingKeys` 不含它）。`AppState.engineConfig(c)` 把 `autoCal.holds` 疊上去再交給
  `engine.applyConfig`（`updateConfig`／`reloadConfig`／holds 改變時）。`PlanDevice.awaitingCalibration`（只對 `requiresMeasurement`）→
  `plan()` 規則 8：不出聲、理由 `PlanEntry.awaitingCalibrationReason`、不算進基準（保底規則照舊：只剩它一台時仍出聲）。
- `startEngineStack`：`engine.start()` **之前** `primeLaunchHolds`（`Devices.bluetoothOutputs()` 裡有延遲值且啟用的）＋同步 `applyConfig`
  → 藍牙 attach 時就已經不出聲，不會用舊值響一下。30 秒內才連上的藍牙在第一次觀察時才 hold（attach 到觀察之間最多約 1 秒可能用舊值出聲）。
- 開始：`CalibrationRunner.start(micUID: config.calibrationMicUID, extraArgs: ["--pulse", "--only", "a,b"])`（發行版白名單已放行）。
- `CalibrationRunner.onStarted(extraArgs)`／`onFinished(ok, cancelled, message, lines)`（新增，常駐回呼；`onFinishOnce` 照舊給 ctl）。
  自己發起的用 `autoCalStarting` 旗標區分；結束時 `parseMeasuredUIDs(lines)` → `autoCal.finished`。
- `ppWriteLatencies` 成功寫入時印 `@@measured <uid,…>`（這次真的量到並寫入的＋參考喇叭），在「✓ 已寫入」之前。
- 計時：倒數／等待中 0.25 秒 timer（`autoCalTick`＋更新 `autoCalStatus`）；其他時候跟著每秒 timer，且只有 `needsEnvironment` 時才讀麥克風狀態。
- `canRun` = running && !engineStarting && !otherInstance && Reconnector 在 && CalibrationRunner 已接線且沒在跑 && !calibrating。

### 12.4 使用者介面
- `AppState`：`@Published autoCalStatus`、`autoCal`、`cancelAutoCalibration()`（倒數中 → 延後；自動校正執行中 → 停止子行程）、`calibratePendingNow()`。
- 面板校正區 `AutoCalibrationBlock`：倒數列（計時器圖示＋「N 秒後校正〈名〉」＋「取消」）、自動校正中、需要校正清單＋「需要校正」按鈕、暫停出聲的藍牙。
  假資料截圖：`render-panel <dir>` 多一組 `panel-autocal-{light,dark}.png`。
- 通知（`AutoCalNotifier`，UNUserNotificationCenter；只在 `.app` bundle 內啟用，CLI／自測不碰）：啟動時要一次權限（只要 alert，不要聲音）；
  倒數通知附「取消」動作；麥克風占用／找不到 → 延後通知；結束 → 完成或「沒有校正成功」通知（使用者自己停止的不通知）。
  `canNotify`（`getNotificationSettings`：authorized／provisional 且 alert 沒關；啟動時與需要環境時每 5 秒重讀）。
  **沒有權限、面板又關著 → 不自動倒數**（倒數只在 `.countdown` 階段檢查；使用者按「需要校正」／`ctl autocal now` 不需要權限）。
  `setPanelVisible` 會立刻 `autoCalTick()`：面板一打開，`needsConsent` 的就開始倒數。
- `ctl autocal status|cancel|now`（發行版放行）；`ctl state` 末尾多幾行自動校正狀態。

### 12.5 未實測／待決
- **2026-09-29 實機**：app 重開 3 次都照 12.1 走完（藍牙先不出聲 → 倒數 → `--only` → 恢復出聲）；`simulate-reconnect` 沿用舊值；
  除錯版 `ctl autocal simulate-appear` 驗證新裝置倒數 → 取消 → 需要校正 → 立即校正。**未實測**：真的插拔、通知橫幅與「取消」動作、麥克風被占用的延後。
  `autocal-selftest` 79 項（2026-09-29 審查後新增第 9 節「暫停出聲中關掉再打開」、第 10 節「看不到倒數不自動播」）。
  **通知權限沒授與時的行為（needsConsent）只有自測，沒有實機**（要動通知權限，會改使用者的系統設定）。
- 暫停出聲的藍牙若自動校正量不到（例如 C270 聽不到 GLASS5+）→ 整個 session 不出聲，只能按「需要校正」再試。要不要加「沿用舊值出聲」按鈕由 Kang 決定。
- 「app 重開」以啟動後 30 秒為界：登入後藍牙超過 30 秒才連上會被當成「重新接上」→ 用舊值（V8 實測 app 重開後差 35–61 ms）。
- ~~重連政策待 Kang 重新拍板~~ → 第 B 輪定案：藍牙真的斷線重連比照 app 重開（§13.6）。`Config.silenceBluetoothAfterReconnect` 預設 false 沒改
  （它只作用在 `needsRecalibration`：取樣率改變重開、HFP 暫停／恢復）。
- app ↔ 子行程的 tap 交接：2026-09-29 已接（§10「校正交接」），自動校正、面板、`ctl calibrate` 都走它。

## 13. 背景監聽：播音樂時自動修正落拍（第 B 輪，2026-09-29 Kang 定案）

檔案：`Sources/Monitor/`（演算法，純運算：`DriftEstimator.swift`、`MonitorDecider.swift`、`MonitorSelfTest.swift`〔只在 `-D IU42_DIAG`〕）、
`App/MonitorScheduler.swift`（排程狀態機＋一輪的 IO 流程）、`App/MonitorCapture.swift`（app 行程內的 C270 擷取）、
`App/MonitorEstimatorAdapter.swift`（演算法 ↔ 排程介面轉換）、`Engine.swift`（探測偏移／延遲修正／節目音錄製）、AppState 背景監聽段、
`UI/Panel.swift`（開關＋最近結果）、`UI/MenuBarIcon.swift`（提示點）。

### 13.1 規則
- 音樂模式、同步播放在跑、面板開關開著（`Config.monitorEnabled`，預設開）時，每 `monitorIntervalSec`（300 秒，夾在 60–3600）一輪：
  用校正麥克風（C270；**藍牙麥克風一律不開**）聽 `monitorCaptureSec`（10 秒，夾在 5–20）。
- **隱私**：錄音只在 app 記憶體裡計算，算完就丟、**不存檔、不上傳**；log 只寫統計量（dBFS、SNR、誤差 ms），沒有錄音內容。
  聆聽的 10 秒 macOS 會亮**橘色麥克風指示燈**。面板一鍵關閉；關閉後不再開麥克風（`ctl monitor status` 的 `DeviceIsRunningSomewhere` 佐證）。
- 參考＝節目音（ProgramRing，L+R 平均）。一輪裡對被檢查的裝置加小的**探測偏移**（每台 +3 ms、+4 ms 各一段，0.5 秒斜坡、變速不淡出），
  讓它的峰從群集分離出來 → 量它相對**有線裝置**的誤差（正＝晚到）。一輪最多 2 台：藍牙每輪；每 3 輪加 1 台有線（MSI、電視輪替）。
  10 秒窗的排法：只有藍牙 → 基準 1.7 s｜藍牙 +3（3.3 s）｜藍牙 +4（3.3 s）｜基準 1.7 s；藍牙＋有線 → 藍牙 +3、有線 +3、藍牙 +4、有線 +4 各 2 秒。
- 確認才修：同一台可採信、0.5 ms ≤ |誤差| ≤ 10 ms，30 秒後的確認輪再量一次一致（差 ≤ max(1 ms, 25%)、同號）→ 以**最新一次**的值修正，
  斜率 ≤ 0.1 ms/秒（`Engine.correctionSlewMsPerSecond`；1.5 ms 約 15 秒）。修正還在走斜坡時不開始下一輪。
- 確認輪的上限（2026-09-29 審查）：確認輪**整輪不可採信** → 等確認作廢（「連續 2 次」重來）、回到 300 秒；確認輪被跳過（1–4 kHz 能量不足、
  麥克風被占用、中止…）或結果不一致 → 最多 `maxConfirmRounds`（2）個確認輪，之後放棄這次等確認、回到 300 秒。聽不清楚的環境不會每 30 秒開 10 秒麥克風。
- 擷取後的錄音檢查另加：麥克風輸入 `sampleTime` 跳號（`MicCaptureResult.gaps > 0`：HAL 丟輸入週期）→ 整輪「錄音不完整」跳過
  （估計器用一條直線對時，跳號後半段整段挪一個週期約 10 ms，會被攤平成數 ms 的偏差；校正路徑一樣判不可信）。
- 不自己修、標「需要重新校正」（面板橫幅＋選單列提示點＋通知）：可採信地連續 2 次 > 10 ms；累計修正 > `Engine.maxCorrectionMs`（50 ms，
  engine 能套用的上限；原本 20 ms，照 V7 的藍牙漂移速度約 20–25 分鐘就會被標記、之後整台不再監聽——2026-09-29 審查改。漂移是否線性不收斂實機還沒量到）；
  **量到過之後**連續 3 輪量不到（2026-09-29 整合實測加的條件，**Kang 已確認維持**：校正後從來沒量到過的裝置＝麥克風本來就聽不清楚它，不累計，否則在聽不清楚的環境會每 15 分鐘誤標一次）。
- 跳過本輪（條件恢復就跑）：功能關閉、不是音樂模式、同步播放沒在跑、校正中（含自動校正倒數／執行）、找不到校正麥克風、
  **麥克風被其他 App 占用**（`DeviceIsRunningSomewhere`，我們自己的擷取不算）、節目音太小（最近 3 秒 tap 峰值 < −30 dBFS 或乘上音量倍率 < −50 dBFS）、
  修正還在走斜坡。擷取後跳過：節目音 1–4 kHz < −50 dBFS、錄音不完整、同步播放重建過、演算法判整輪不可採信（節目音太小、1–4 kHz 能量不足、麥克風削波／沒訊號、找不到群集）。
- 中止（探測偏移 0.2 秒斜坡拿掉、關麥克風）：校正開始、engine 停止／重建、使用者關閉功能、app 結束。
- 修正只在執行期、不存檔；重新校正（該台 `measuredLatencyMs` 改變）、藍牙重連、app 重開都清掉。

### 13.2 Engine（探測偏移／延遲修正／節目音錄製）
```swift
static let probeRampSeconds = 0.5, maxProbeMs = 20.0, correctionSlewMsPerSecond = 0.1, maxCorrectionMs = 50.0
func setProbeOffset(uid:ms:rampSeconds:) -> Bool      // 這台的補償上額外 +ms（正＝更晚出聲）；0 = 移除。斜坡內變速走完
func clearProbeOffsets(rampSeconds:)
func setLatencyCorrection(uid:ms:)                     // 絕對值；正＝它實際比 measuredLatencyMs 慢。以修正後延遲重算 plan，差額斜率套到各台
func adjustLatencyCorrection(uid:byMs:) -> Double      // 累加，回傳新值
func clearLatencyCorrections(_ uids: Set<String>?)
var latencyCorrections: [String: Double]
func delayOffsets() -> [String: DelayOffset]            // 每台輸出目前／目標的探測與修正額外延遲（ms）
var isSlewing: Bool
func programClock() -> (clock, sampleRate, generation, writeEnd)?   // 節目音時鐘（sampleTime ↔ 延遲 0 輸出的 hostTime）
func programSnapshot(from:frames:) -> [Float]?
final class ProgramRecorder { init(ring:maxSeconds:); func start(lookbackSeconds:) -> Bool; func stop() -> ProgramRecording? }  // 每 0.2 s 從 ProgramRing 拷一次
func holdUntilCalibrated(uid:firstConnect:) -> Bool; func releaseReconnectHolds(_:); var reconnectHolds   // 藍牙重連：重新 start 前先靜音
```
- 聚合裝置輸出走延遲線讀取點、藍牙走 BluetoothOut 讀取點；位置有小數時 4 點 Hermite 插值，走完停在整數 frame（沒有斜坡時走原本的快速路徑）。
  engine 重建後第一個週期修正直接到位（沒有聲音連續性要保）。藍牙讀取點的移動算進對時，不觸發重新對時。
- 修正換算（`Engine.correctionOffsets`，純函式）：藍牙修正 +c ms → 修正後延遲重算 plan → 通常是三台有線各多等 c ms（藍牙是最慢的）。

### 13.3 擷取與排程（App/）
```swift
final class MonitorMicCapture { init(device:seconds:); func start() -> OSStatus; func stop(); func result() -> MicCaptureResult
                                static func isRunningSomewhere(_ id:) -> Bool }   // 輸入 IOProc，預配置緩衝，每週期記 (frame, hostTime)；藍牙裝置一律拒絕
protocol DriftEstimating { func estimate(_ input: DriftCaptureInput) -> DriftEstimate }
func makeDriftEstimator() -> DriftEstimating          // = ProgramDriftEstimator()（UntrustedDriftEstimator 保留給自測）
final class MonitorScheduler { tick(now:env:) -> [MonitorAction]; roundFinished(_:estimate:now:); roundSkipped(_:reason:message:now:)
                               resetDevices(_:); reschedule(now:); var maxProbesPerRound (= 2); func slots(for:round:) }
enum MonitorAction { start(MonitorRoundPlan), skipped(MonitorSkipReason), correct(uid:name:deltaMs:totalMs:), flagCalibration(uid:name:reason:), log(String) }
final class MonitorRound   // 一輪 IO：開麥克風＋ProgramRecorder＋依 plan 呼叫 setProbeOffset → 背景 queue 呼叫 estimator → 主執行緒回呼
```
- `ProgramDriftEstimator`（`MonitorEstimatorAdapter.swift`）：MicAnchor → `MonitorClockPoint`；探測 host 時間 → `MonitorProbe.fromOutputTimes`
  （這台補償 = plan 延遲 + 已套用的修正額外延遲 + 路徑固定延遲〔藍牙 safety〕）；`referenceDevices` = 有線裝置；
  結果 trusted → errorMs（信心 1），不可採信 → nil（`looksMissing` 才算「量不到」）。每輪把 `DriftEstimator` 的摘要（只有統計量）寫 log；
  除錯版另寫「M3 突波檢查」（斜坡時段 vs 其他時段的麥克風一階差分峰值）。
- 分析在 round 的背景 queue（除錯版 -Onone 約 0.3–0.4 秒、-O 約 0.03 秒），不在主執行緒或 IOProc。

### 13.4 演算法（Sources/Monitor/DriftEstimator.swift，純運算）
```swift
struct MonitorClockPoint { var sample: Double; var hostSeconds: Double }
struct MonitorProbe { var device: Int; var fullStart, fullEnd: Int64; var offsetMs: Double; var rampMs = 500
                      static func fromOutputTimes(device:setAt:clearAt:offsetMs:rampSeconds:engineRate:baseDelayFrames:) -> MonitorProbe }
struct MonitorCapture { mic, micRate, micClock, program, programRate, programStart, programClock, deviceCount, probes, referenceDevices }
let r = DriftEstimator.analyze(capture, params: MonitorParams())
r.skip: MonitorSkip?            // tooShort／programTooQuiet／bandEnergyTooLow／micSilent／micClipping／noOverlap／clusterNotFound
r.cluster: MonitorCluster?      // lagMs、snrDb、peaks、single
r.devices[i]: MonitorDeviceEstimate   // errorMs（這台 − 參考，正＝晚到）、trusted（= issues 為空）、issues、looksMissing、snrDb、psrDb、halfDiffMs…
r.summary                       // 多行中文摘要（log 用）
```
方法：
- 時鐘：麥克風與 ProgramRing 的 (sample, hostTime) 擬合直線對時，節目音用窗化 sinc 重取樣到麥克風時間軸（16 kHz 麥克風也可以）。
- 群集：1–4 kHz GCC-PHAT 包絡找全部喇叭合起來的到達時間；再用 Welch 等長窗（170 ms、50% 重疊）算互功率譜，每段依節目音內容落在哪個探測狀態分組
  （斜坡與前後 50 ms 不用）。
- 分離各台：每個頻率 bin 解一個小的加權最小平方（附每 bin SNR 與模型失配項），差分後群集與固定反射抵消，只剩被探測那台。
  同一輪兩種偏移（+3、+4）避免單一偏移在 ±p 的梳狀假峰；+4 與 4.1 ms 反射重疊時由 +3 補。
- 群集漂移：頭尾未探測區塊互比相位估剩餘漂移，頻域逐段拉回（沒拉回時自測抓到 +1.5 ms 被估成 −0.06 ms 還標可採信）。
- 可採信條件：探測資料夠（兩種偏移 ≥ 0.7 秒；單一偏移 ≥ 1.5 秒）、兩條曲線峰值比純雜訊區高 ≥ 10 dB、沒有更早的峰或後面更高的峰、
  奇偶兩半差 ≤ 0.25 ms、不在 ±15 ms 搜尋窗邊緣、單一偏移時不剛好在 ±p／±2p。任一條不成立 → 不可採信（附中文原因），不給數值。
- `MonitorDecider`／`MonitorProbePlan`（MonitorDecider.swift）：演算法作者的決策器與排程建議。**app 用的是 `MonitorScheduler`**
  （確認輪在 30 秒後、容許差 max(1 ms, 25%)、取最新值：藍牙同串流內約 0.47 ms／30 秒的單向漂移會讓 0.35 ms 的門檻常判成不一致）；
  `MonitorProbePlan.bluetooth`／`pair` 的時間表與 `MonitorScheduler.slots` 相同（autocal-selftest 第 11 節交叉檢查）。

### 13.5 離線自測
- `monitor-selftest [--quick]`（除錯版；test.sh 跑 `--quick`）：鼓點／人聲、藍牙 +1.5 ms、只探藍牙 22/22 可採信且 ±0.3 ms；+3／+4 分離 8/8；
  長音 32 次錯值 0；誤報 0/200（樣本外 0/400 ×2）；時鐘（無時間戳 +45 ppm、16 kHz、−50 ppm）；跳過條件；大偏移；決策器 11 項。
- `monitor-sim`（除錯版）：單次模擬、印完整結果（調參用）。
- `autocal-selftest` 第 11–13 節：排程狀態機（跳過條件、確認才修、標記、兩段偏移排程、有線輪替、量到過才累計量不到、
  確認輪上限〔不可採信作廢／跳過或不一致最多 2 個〕、預設累計上限 50 ms）、重連政策（含第一次連上 `bluetoothFirstConnected`、不重複排）、提示點。
- `engine-selftest` §9–11、`bluetooth-selftest` §6b：探測／修正斜坡逐樣本連續、斜率 ≤ 0.1 ms/秒、藍牙讀取點不重新對時。
- 發行版閘門：`monitor-selftest` 被拒、`runMonitorSelfTest`／`cmdMonitorSim` 不在符號表。
- **限制（只有模擬）**：模擬的喇叭 EQ 是零相位；實際喇叭「音樂加權」與「粉紅雜訊加權」1–4 kHz 群延遲不同會有固定偏差（沒量過）；
  參考只用單聲道；風琴式純線譜長音一律不可採信。實機結果見 [TESTLOG.zh-TW.md](TESTLOG.zh-TW.md)「第 B 輪整合驗收」。

### 13.6 藍牙真實斷線重連（第 B 輪定案）
- `BluetoothOutManager.holdOnReconnect`：斷線再連上（`goneUIDs` 裡有它），重新 start **之前**同步呼叫 `engine.holdUntilCalibrated(uid:)`
  → 串流一開始就是靜音。之後 `AppState.bluetoothReconnected`：清掉背景監聽對它的狀態與延遲修正 → `autoCal.bluetoothReconnected` 放進 `holds`
  → 先套用含 holds 的設定再 `releaseReconnectHolds`（control queue 依序，中間不會響）→ 倒數 3 秒 → `--only <uid>`；
  通知沒授權、面板關著 → `needsConsent`，面板打開才倒數。裝置清單看到的重連與 `onReconnect` 通知合併，不重複排；校正執行中又重連 → 排隊。
- 第一次連上（2026-09-29 審查補上原本的空窗）：這個 manager 從沒啟動成功過的 uid（`attachedEver` 沒有它）也在 start **之前** hold，
  成功後送 `onFirstConnect` → `AppState.bluetoothFirstConnected` → `autoCal.bluetoothFirstConnected`：啟動 30 秒內＝app 重開（`appRelaunch`）、
  之後＝同重連（`reconnect`）；沒量過延遲／使用者關掉的不排。最後一律「套用含 holds 的設定 → `releaseReconnectHolds`」。
  原本藍牙在 app 啟動 30 秒後才第一次連上時，engine 不會預先 hold，可能用舊值出聲最多約 1 秒（等下一次裝置清單觀察）。
- `Config.recalibrateBluetoothOnReconnect = false` 可退回舊政策（沿用舊值出聲）。

### 13.7 介面與 ctl
- 選單列：`AppState.menuBarNeedsAttention`（需要校正／needsConsent／背景監聽標記／暫停出聲等校正的藍牙）→ `MenuBarIcon.image(symbol:badge:)`
  在圖示右上角加提示點（template image，淺色／深色選單列自動套色）；accessibilityLabel「In_Unison42：有裝置需要校正」。
- 面板：頂部「需要校正」橫幅（原因＋「立即校正」）；「播音樂時自動修正落拍」開關＋最近一次結果（時間、每台誤差、有沒有修正）。
- `ctl monitor status|on|off`（發行版放行）；除錯版另有 `monitor now`（下一秒就跑一輪，條件照樣檢查）、
  `monitor bias <uid|名稱> <ms>`（實機驗收：讓它晚到 ms；`bias clear` 清全部修正）、`monitor interval <秒>`（存進 config，測完改回 300）、
  `autocal set-latency <uid> <ms>`（節目音一直在播、脈衝校正量不到時手動寫入延遲並當作已校正；log 標「手動」）。
  `ctl monitor status` 另列校正麥克風與藍牙 `:input` 的 `DeviceIsRunningSomewhere`。`ctl snapshot <dir>` 另存 `menubar-live-{light,dark}.png`
  （⚠ 離屏渲染面板會被當成「面板打開」約 0.1 秒，needsConsent 的倒數會開始又延後）。
- `calibrate --verify-program`（面板驗證、ctl）：app 經環境變數 `IN_UNISON42_RUNTIME_CORRECTIONS` 把目前的延遲修正交給子行程，
  子行程把 `measuredLatencyMs += 修正` 再驗 → 驗的是 app 實際在播的補償（`--pulse` 不帶，量的是裝置本身的延遲）。

## 14. 藍牙漂移預測補償、短校正、藍牙連上後預設輸出自動切回（第 C 輪，2026-09-29 Kang 同意）

檔案：`App/BluetoothDrift.swift`（純邏輯：`BluetoothDriftModel`、`ShortCalScheduler`、`BluetoothOutputRestorePolicy`、子行程輸出解析、`drift-selftest`）、
AppState「藍牙漂移補償」段、`AutoCalibration.swift`（`.drift` 項目）、`ProgramPath.swift`（短量測、`@@latency-obs`）、
`System/DefaultOutputGuard.swift`（自動切回）、`Bluetooth/BluetoothOut.swift`（`streamKeys`）、`UI/Panel.swift`（`DriftSection`、`OutputRestoreSection`）。

背景：GLASS5+ 在同一個 A2DP 串流內延遲單向漂（第 B 輪 17:57–18:17：約 −0.78 ms／分鐘 ≈ 13 ppm；BluetoothOut 重取樣只看到 −3.6 ppm
→ 是喇叭自己的 DAC 時鐘／A2DP 緩衝，程式端的時鐘吸收不到）；串流重開另跳 35–61 ms（已有重開／重連自動重校）；背景監聽在這個房間幾乎量不到。

### 14.1 漂移模型（每台藍牙一個 `BluetoothDriftModel`）
- 量測點 L（ms）＝這台「相對參考喇叭（內建）的真實延遲」，config 單位（`measuredLatencyMs(藍牙) − measuredLatencyMs(參考)`）：

  | 來源 | 怎麼來 | σ |
  |---|---|---|
  | 校正（只量藍牙的短校正、完整校正、面板／ctl／自動校正） | 子行程寫入後印 `@@latency-obs <uid> <L> <離散> <採用數> calibration` | 0.3 ms |
  | `--verify-program`（完整）、`--verify-program --only <藍牙>`（只量藍牙的驗證） | `@@latency-obs … verify`（完整驗證：到達差 − (補償藍牙 − 補償參考)，只在參考喇叭脈衝都合格、藍牙最大一致群 ≥ 3 時印） | 0.3 ms |
  | 背景監聽可採信的結果 | AppState：L = 校正值 + 這輪開始時的修正 + 誤差 − 參考 | 2 ms |

- 速度：加權最小平方直線（權重 1/σ² × exp(−距最新一點／15 分鐘)〔近期加權：D2 實測速度會變〕；點的散布比標稱大時按 χ² 放大不確定度）。
  **精確點（校正／驗證）≥ 2 個、精確點的跨度 ≥ 2 分鐘**才估速度（背景監聽點只參與回歸，不能單獨撐出速度）。
- 【第 C 輪驗收後】**預測 = 錨點 + 速度 ×（t − 錨點）**，錨點＝最新一個精確點（`BluetoothDriftModel.anchor`；只有背景監聽點時＝它們的加權平均）。
  剛量完修正就等於實測值（舊版用回歸直線，剛量完就差 1.2–1.55 ms）；背景監聽點（σ 2 ms）不能單獨決定修正。
- 預估誤差（外推時）：σ(t)² = σ錨點² + (t − 錨點)²·Var(r) + (½·a·Δ²)²，a = 0.08 ms／分鐘²（`rateWanderMsPerMin2`：速度本身會變），Δ = 距錨點的分鐘數；
  沒有速度時 σ² = σ錨點² + (0.8 ms／分鐘 × Δ)²（`priorRateMsPerMin`）。⚠ wander 項只跟「距錨點多久」有關、點再多也不會變小 →
  **2σ > 2 ms 約在錨點後 5 分鐘**（這就是排程實際的量測頻率），**2σ > 4 ms（`holdAtTwoSigmaMs`，約 7 分鐘）→ 停止外推**：
  預測停在 2σ 剛超過 4 ms 的那一刻（`DriftPrediction.held`；錨點當下就超過 → 停在錨點實測值）。
- 【第 C 輪驗收後】**預測失準**：精確點和「加入前的預測」差 > 3 ms（`missMs`＝藍牙門檻，固定值，**不跟著 σ 放大**；舊版容許量 3σ 在稀疏資料時變成 12 ms，
  偏 9–12 ms 的點照收、面板一直顯示「模型正常」）→ `AddResult.missed`、`lastMiss`／`missCount`（面板「最近一次 … 預測失準」、ctl）；
  有速度時代表速度變了 → 丟掉上一個錨點之前的點（最近兩個精確點重估速度）。**連續 2 次失準（`erraticMisses`）→ `.erratic`「漂移不規則」**：
  不外推（修正停在最新實測）、`flagNeedsCalibration`；之後一個沒失準的精確點 → 恢復。
- 合理範圍與矛盾：|速度| ≤ 3 ms／分鐘；還沒有速度時新點和錨點差 > 3 ms／分 × 間隔 + max(2.5, 3σ)、或背景監聽點偏離預測 > max(2.5 ms, 3·√(σ預測² + σ點²))＝矛盾。
  矛盾、速度超出範圍 → **不外推**（修正停在最新精確點）＋`autoCal.flagNeedsCalibration`（面板「需要校正」＋選單列提示點；已經在「需要校正」→ 只更新原因、不再通知），
  排程立刻到期（空檔優先）；之後來一個**校正點** → 以它重新開始。
- 串流重開即重置：`BluetoothOutManager.streamKeys`（uid → 「建立流水號#IOProc 成功啟動次數」，每 5 秒在 control queue 讀）變了，
  或 `bluetoothReconnected`／`bluetoothFirstConnected`／`markBluetoothNeedsRecalibration`（取樣率改變重開、HFP…）→ 模型、排程狀態清掉，
  **engine 裡這台的延遲修正也清掉**（`driftStreamReset` → `engine.clearLatencyCorrections([uid])`＋背景監聽這台的累計歸零；第 C 輪審查：串流識別改變／取樣率重開以前不清，
  舊串流的修正會帶進新串流）。
- 套用：每 10 秒（量測點進來時立刻）修正 = clamp(L̂(now) − (校正值 − 參考校正值), ±50 ms) → `Engine.setLatencyCorrection(uid:ms:quiet: true)`
  （Engine 以 ≤ 0.1 ms/秒 的斜率走過去；同一條延遲修正路徑，藍牙最慢 → 實際是三台有線各多／少等）。暫停出聲等校正、背景監聽一輪進行中、校正中不動；
  log 節流（變 ≥ 0.5 ms 或每 5 分鐘一行「漂移補償：…延遲修正 …（預測 … ± …、速度 …）」）。
- 背景監聽連續 2 次一致的 `.correct`：這台已有漂移模型時**不另外疊修正**（它的結果已經是量測點），只寫 log。
- 面板開關「藍牙漂移補償」（`Config.bluetoothDriftCompensation`，預設開）；關掉 → 漂移模型送的修正清掉（斜率回去），模型保留。

### 14.2 短校正（`calibrate --pulse --only <藍牙>`／`--verify-program --only <藍牙>`）
- 條件：`--only` 只有一台藍牙、它有上次的延遲值、沒有 `--full` → 自動走短量測（`PPShortPlan`）：
  參考×2 → 藍牙×4（**不丟暖機脈衝**）→ 參考×2；間隔 `ppShortPeriod` = max(0.85, 上次延遲 + 0.46 s，取 0.05 s 倍數)（GLASS5+ 0.9 s）；
  前導 1.5 s（原 2 s）；pilot 在藍牙輸出啟動時就開（暖機和交接、afplay 前導重疊；原本暖機 3 秒＋丟 1 個脈衝），短量測的 pilot **−40 dBFS**
  （`PPParams.shortPilotDb`；完整量測仍 −50、只在藍牙脈衝前後送）；尾巴 0.3 s；
  WAV 尾巴只剩靜音 → 不等 afplay 播完（全部量測都適用）。
- 定位：藍牙寬窗改成以上次延遲為中心 ±150 ms（窗尾補 0，PHAT 白化不受下一個脈衝影響）；藍牙的安靜段取脈衝**之前**半個週期
  （之後半個週期會碰到下一個參考脈衝）。峰值貼窗邊 10 ms 內或累加 SNR < 6 dB → 印 `@@short-miss <uid>`、這台不採用。
- 寫入照舊（最大一致群、窗寬 1.5 ms、≥ 3 且 ≥ 一半）。只量藍牙的驗證（`--verify-program --only`）：補償一樣歸 0，量到的相對延遲和 app 目前用的
  （校正值＋`IN_UNISON42_RUNTIME_CORRECTIONS` 的修正）比 → `✓／✗ … 殘差 …`（門檻 3 ms，正＝藍牙晚到）、`@@bt-residual <uid> <ms>`、`@@latency-obs … verify`；不寫入。
- `--full`：`--only` 藍牙也用完整量測（發行版白名單放行）。自動校正（重連、app 重開）的短量測 `@@short-miss` → 同一次自動校正接著改跑 `--full --only`
  （使用者已經同意這次校正；只重跑一次）。使用者按「需要校正」一樣先走短量測（找不到才 `--full`；2026-09-29 實機：重連後完整量測也一樣會被房間噪音蓋掉，
  強制 `--full` 沒有好處、只是多 20 秒測試音）。

### 14.3 短校正排程（`ShortCalScheduler`，AppState 每秒 tick）
- 到期：第 1 點之後 5 分鐘（取得速度）；有速度後 2σ 預估誤差 > 2 ms 的時間點（照目前參數約錨點後 5 分鐘），或距錨點 30 分鐘（`maxInterval`；
  只有速度很穩、`rateWanderMsPerMin2` 很小的喇叭才會用到），擇早；模型不外推（矛盾／不規則／速度超出）→ 立刻。
  沒有量測點 → 不排（交給自動校正：app 重開、重連本來就會校正）。
- 系統靜音或音量增益 < 0.01（−40 dB，`minVolumeGain`）→ 空檔、倒數都不跑（第 C 輪審查：暫停音樂、靜音去接電話時不放測試音）。
- 到期後：**節目音靜止**（tap 輸入每秒峰值 < −60 dBFS 連續 ≥ 5 秒、而且 ≤ 10 分鐘〔`maxGapSilence`：靜止更久＝不聽了、半夜，不在安靜的房間放測試音〕，
  而且靜止之前節目音連續播了 ≥ 20 秒〔`minPlayingBeforeGap`：剛開 app、長段靜音開頭不算〕）
  → 空檔直接跑（`autoCal.requestDriftCalibration(countdown: false)`：不倒數、不發通知）；
  到期後、而且上一次空檔之後**連續播放** 30 分鐘都沒空檔 → 倒數 3 秒（`countdown: true`：照一般規則，看不到倒數 → `needsConsent`，面板打開才倒數）；
  `needsConsent`／取消的延後項目還在 → 不重複倒數（空檔照樣可以跑）。
- 只在：功能開、藍牙出聲中（音樂模式、沒有暫停出聲等校正）、engine 在跑、沒有校正／自動校正／背景監聽在跑 時開始。
- 沒量到 → 5 分鐘後再試（`retrySeconds`）；連續 3 次沒量到 → `flagNeedsCalibration`＋**停止自動短校正**（`ShortCalScheduler.stopped`；
  按「需要校正」量到、或串流重開才恢復——不會每 5 分鐘在空檔一直放測試音、「需要校正」也不會被下一次短校正抹掉）。
- `AutoCalWhy.drift` 的項目：沒量到不留「需要校正」、不發完成通知；麥克風被占用／找不到 → 直接放掉（不變成「麥克風空下來就自動倒數」）。
  【第 C 輪審查】`requestDriftCalibration` 只拿掉 `.drift` 自己的延後項目；其他原因的「需要校正」（背景監聽連續量不到、漂移不規則、校正失敗、取消）保留，
  短校正量到（`finished(measured:)`）才解除。

### 14.4 藍牙連上後預設輸出自動切回（`BluetoothOutputRestorePolicy`＋`DefaultOutputGuard`）
- 唯一的自動切換例外：**本程式在出聲的**藍牙輸出（不在排除清單、設定沒關掉）**出現在裝置清單後 10 秒內**，系統預設輸出被切到它 → `DefaultOutputGuard.restore`（預設輸出 → 音量來源、
  系統提示音輸出 → 內建；**不動音量、靜音**），log＋`AppState.outputRestoreNote`（面板「藍牙連上時保持預設輸出」下方）。
- 「出現」以 Core Audio **全部**活著的藍牙輸出（含排除清單，`DefaultOutputGuard.allBluetoothOutputUIDs`）判斷（第 C 輪審查：以前只記本程式管理的，
  早就連著、但被排除的 AirPods 被手動選成預設輸出時會被當成剛連上而切回）。
- 預設輸出的通知比裝置清單先到（清單還沒有這台）→ 當作現在連上。app 啟動時就連著的不算。同一次連上最多自動切回 3 次（不跟 macOS 打架）。
- 排除清單裡／被關掉的藍牙（不是本程式出聲的）→ 一律尊重。
- 超過 10 秒（使用者自己選藍牙）、開關關掉 → 尊重，照舊只警告＋「切回」按鈕（log／面板記一筆「不自動切回（原因）」）。
- 開關 `Config.restoreDefaultOutputOnBluetoothConnect`（預設開）；`DefaultOutputGuard.autoRestoreEnabled`（LockedValue，AppState 同步）。

### 14.5 ctl／自測
- `ctl drift status|on|off|verify-feed on|off`（發行版放行）：模型（串流識別、點、速度、預測 ± σ、錨點、預測失準次數）、下次短校正（含「已停止自動短校正」）、
  最近 6 筆藍牙殘差（只量藍牙的驗證：實測 − app 當時用的；精確點：實測 − 加入前的預測）、最近一次觸發（空檔／倒數）；
  `verify-feed off` = 驗收用，`--verify-program` 的結果只記 log、不當量測點（執行期、不存檔）。`ctl output-restore status|on|off`。`ctl state` 末尾多這兩段。
- `drift-selftest`（test.sh）：模型（回歸、權重、雜訊、重置、合理範圍、矛盾、校正點重新開始）、排程（第 2 點 5 分鐘、2σ／30 分鐘擇早、空檔優先、
  30 分鐘沒空檔才倒數、needsConsent 不重複倒數、忙碌不動、失敗重試與 3 次標記、關閉／不出聲不排、靜止 > 10 分鐘不跑、音樂恢復重新累計）、
  停止外推、60 分鐘 −0.78 ms／分模擬（第 2 點後殘差 < 3 ms）、**D2 實機資料重播**（5b：有量測時事前誤差 < 3 ms；量測停 20 分鐘後停止外推比一直外推好，但仍 > 3 ms）、
  **第 C 輪驗收資料重播**（5c：+4.1／−9.2 ms 連續失準 → 不規則、修正停在最新實測 435.955）、預測失準／錨點／背景監聽不能單獨決定修正、
  失敗 3 次停止自動短校正、靜音／靜止前沒在播不跑、
  子行程輸出解析、預設輸出自動切回（10 秒窗、啟動時已連著、通知先於清單、關閉、最多 3 次、非藍牙、重連重新計時、排除清單裡早就連著的、不是本程式出聲的）。
- `autocal-selftest` 第 14 節（`.drift`：空檔不倒數、倒數 → needsConsent、失敗不留按鈕、不發通知、麥克風占用放掉、「需要校正」→ manual、不插隊、
  別的原因的「需要校正」不被短校正抹掉、已在「需要校正」只更新原因不再通知、量到才解除）；
  `calibrate --selftest` 2d（短量測序列／間隔、上次延遲差 0／±61／±135 ms 都找到且誤差 < 0.1 ms、差 200 ms 判找不到、錄音 ≤ 10 秒）；
  `policy-selftest`（`--full`、`--verify-program --only`）。
