# 背景監聽演算法（第 B 輪）— 演算法作者的原始說明

> **已併入 `docs/API.md` §13（2026-09-29 整合）**，以那邊為準；這份保留演算法作者的原文與自測數據。
> 第 8 節的接線已完成（CLI 分派、test.sh 跑 `monitor-selftest --quick`、發行版閘門）。
> 差異：app 的排程用 `App/MonitorScheduler.swift`（不是本檔第 4 節的 `MonitorDecider`），規則見 API.md §13.1／§13.4。

> 檔案：`Sources/Monitor/DriftEstimator.swift`（估計器，產品碼）、`MonitorDecider.swift`（決策器＋探測排程，產品碼）、
> `MonitorSelfTest.swift`（離線模擬與自測，只在 `-D IU42_DIAG`）。
> **純運算**：不碰 CoreAudio、不開麥克風、不存檔、不出聲。錄音樣本由呼叫端在記憶體裡交進來，算完就丟。
> 狀態：**只有離線模擬驗證**（見文末）。實機（C270＋四台喇叭）完全沒有跑過。

## 1. 一輪監聽的流程（整合者要做的事）

```
每 5 分鐘（音樂播放中、面板開關＝開、不在校正中、C270 沒被別的 app 占用）：
 1. plan = MonitorProbePlan.bluetooth(btIndex)            // 建議：藍牙 +3 ms、+4 ms 各一段（10 秒窗）
    （有線裝置較低頻率：MonitorProbePlan.pair(bluetooth: bt, wired: w)，或 make(steps: [(w, 3), (w, 4)])）
 2. 開 C270 輸入 IOProc（絕不開 GLASS5+ :input），10 秒：
      - 樣本（單聲道平均）存進記憶體陣列 mic
      - 每個 input buffer 記一點 MonitorClockPoint(sample: 這個 buffer 第一個樣本在 mic 裡的 index,
                                                   hostSeconds: inputTime.mHostTime × BTRenderer.hostSecondsPerTick())
    同時在非即時執行緒每 ≤ 1 秒從 ProgramRing.read 搬節目音（L+R 平均）到 program，
    並記 ProgramRing.clock() → MonitorClockPoint(sample: sampleTime, hostSeconds: hostTime × secPerTick)
    節目音範圍：[麥克風開始 − 0.7 秒, 麥克風結束]（群集到達約 430 ms＋麥克風延遲；ProgramRing 只留 2.7 秒）
 3. 依 plan 的時間呼叫 Engine.setProbeOffset(uid:ms:) / setProbeOffset(uid:0)，記下當時的 engine sampleTime
    → MonitorProbe.fromOutputTimes(device:setAt:clearAt:offsetMs:rampSeconds: Engine.probeRampSeconds,
                                    engineRate:, baseDelayFrames: 該台 plan 延遲（藍牙再加 BluetoothOut safety）)
 4. 停麥克風 → 背景 queue：r = DriftEstimator.analyze(MonitorCapture(...))   // -O 約 0.03 秒、-Onone 約 0.4 秒
    （錄音陣列用完即丟）
 5. 每台：action = decider[uid].feed(r.devices[i], roundSkipped: r.skip != nil)
      .correct(byMs, rampSeconds) → Engine.adjustLatencyCorrection(uid:, byMs:)；rampSeconds 內不要開始下一輪
      .needsRecalibration(原因)   → 標「需要重新校正」（不自行修）
      .pending / .none            → 不動作
    修正已套用、重新校正、裝置重連後：decider.reset()
```

跳過本輪（呼叫端判斷，不進 analyze）：麥克風被其他 app 占用、使用者在校正中、沒有播音樂（ProgramRing 沒前進）。
analyze 自己會跳過（`r.skip`）：節目音太小、1–4 kHz 能量不足、麥克風削波、麥克風沒訊號、聽不到節目音、時間對不上。

## 2. 輸入

```swift
struct MonitorClockPoint { var sample: Double; var hostSeconds: Double }

struct MonitorProbe {                       // 以「節目音內容」（engine sampleTime）表示的一段探測
    var device: Int                         // 0..<deviceCount（呼叫端自己定的編號）
    var fullStart: Int64, fullEnd: Int64    // 偏移完全到位的內容範圍
    var offsetMs: Double                    // 正 = 更晚出聲（同 Engine.setProbeOffset）
    var rampMs: Double = 500                // 前後斜坡（內容上約等長）；斜坡與 guard 內的段不用
    static func fromOutputTimes(device:setAt:clearAt:offsetMs:rampSeconds:engineRate:baseDelayFrames:) -> MonitorProbe
}

struct MonitorCapture {
    var mic: [Float]; var micRate: Double
    var micClock: [MonitorClockPoint]       // 空 = 沒有時間戳（退回標稱比例，漂移用區塊相位估）
    var program: [Float]; var programRate: Double; var programStart: Int64
    var programClock: [MonitorClockPoint]   // ProgramRing.clock()：該 frame 在延遲 0 的輸出播出的 hostTime
    var deviceCount: Int
    var probes: [MonitorProbe]
    var referenceDevices: [Int] = []        // 「準時」的定義：建議填有線裝置；空 = 其他全部
}
```

- 時間戳：兩邊的 hostTime 必須用同一種換算成秒。沒有 micClock 時仍可用（自測：+45 ppm 無時間戳 → 估到 −44.6 ppm、誤差 +1.509 ms）。
- 麥克風取樣率可以跟引擎不同（窗化 sinc 重取樣；自測 16 kHz ✓）。
- `referenceDevices`：只探測藍牙的輪次沒差（參考＝全部有線）；同一輪也探測有線時，有線的參考不含藍牙。

## 3. 輸出

```swift
let r = DriftEstimator.analyze(capture, params: MonitorParams())   // 同步、純運算；請在背景 queue 呼叫
r.skip: MonitorSkip?          // 非 nil = 整輪跳過（原因字串是 rawValue）
r.cluster: MonitorCluster?    // lagMs（群集到達，ms，相對延遲 0 輸出）、snrDb、peaks（±15 ms 內 ≥ 0.4 的局部峰）、
                              // single（主峰前 15 ms 到後 2.5 ms 沒有 ≥ 0.5 的第二峰；反射通常 > 2.5 ms 不算）
r.devices[i]: MonitorDeviceEstimate
    .probed, .probeSeconds, .probeOffsetsMs
    .errorMs      // 這台 − 參考（ms）；正 = 這台晚到 → adjustLatencyCorrection(byMs: +errorMs)
    .arrivalMs, .referenceMs, .snrDb, .referenceSnrDb, .psrDb, .halfDiffMs
    .trusted      // = issues 為空
    .issues: [MonitorDeviceIssue]   // 不可採信的原因（rawValue 是中文說明）
    .looksMissing // 「量不到」類（偏移可能 > 15 ms）：決策器連續 3 輪 → 需要重新校正
r.programDbFS / programBandDbFS / programBandwidthHz / micDbFS / micClipFraction
r.usedClock / ratioPpm / residualDriftPpm（頻域拉回的群集漂移） / segmentsUsed / segmentsExcluded / computeSeconds
r.summary     // 多行中文摘要（log 用）
```

`MonitorDeviceIssue`：notProbed、probeTooShort（兩種偏移 < 0.7 秒；單一偏移 < 1.5 秒）、lowSnr、referenceLowSnr、
ambiguous（有更早的峰）、weakerThanLater（後面的峰高很多）、referenceAmbiguous、inconsistent（奇偶兩半差 > 0.25 ms）、
atSearchEdge、clockUnknown（沒時間戳又估不出漂移）、nearProbeImage（單一偏移時誤差剛好在 ±p／±2p：可能是假峰）。

## 4. 決策器與排程

```swift
MonitorProbePlan.bluetooth(_ device: Int, windowSeconds: 10, offsetsMs: [3, 4]) -> [MonitorProbeStep]  // 建議的藍牙輪
MonitorProbePlan.pair(bluetooth:wired:windowSeconds:)      // 藍牙 +3、有線 +3、藍牙 +4、有線 +4（各 2 秒）
MonitorProbePlan.make(steps: [(device, offsetMs)], windowSeconds:, rampSeconds:)
MonitorProbePlan.make(devices:windowSeconds:offsetsMs:rampSeconds:round:)  // 每台一次（單一偏移；10 秒窗最多兩台才會採信）
struct MonitorProbeStep { device; startSeconds; clearSeconds; offsetMs }   // 輸出時刻（秒，相對監聽開始）

var d = MonitorDecider()        // 每台一個；Settings：minCorrectMs 0.5、confirmToleranceMs 0.35、bigOffsetMs 10、
                                //   slewMsPerSecond 0.1（同 Engine.correctionSlewMsPerSecond）、missingLimit 3
d.feed(estimate, roundSkipped:) -> .none(原因) | .pending(ms) | .correct(byMs:, rampSeconds:) | .needsRecalibration(原因)
d.reset()
```

規則：可採信且 |誤差| ≥ 0.5 ms，連續 2 輪差 ≤ 0.35 ms → 修正（兩次平均）；|誤差| > 10 ms 連續 2 次 → 需要重新校正；
群集正常但這台連續 3 輪量不到 → 需要重新校正；中間夾一次不可採信就重來（只有 nearProbeImage 是中性的）；
整輪跳過不影響。修正用 Engine 的斜率（≤ 0.1 ms/秒，1.5 ms 約 15 秒）。

## 5. 方法重點（為什麼這樣做）

詳細在 `DriftEstimator.swift` 檔頭。重點：
- **探測差分＋每 bin 最小平方**：群集（其他裝置、所有反射）在各探測狀態都一樣，差分後只剩被探測那台；
  e^{−jωp} − 1 的零點（p = 3 ms 每 333 Hz）由共變異自動降權。
- **同一輪用兩種偏移（+3、+4）**：單一偏移時零點是等間隔的梳子 → 曲線在 ±p 有群集的鏡像假峰（自測實際抓到過 −4.0 ms「可採信」的錯值）。
  兩種偏移時假峰散開；+4 ms 與 4.1 ms 反射重疊時 +3 補上。
- **Welch 等長窗**：一開始用「參考段補零 × 較長麥克風窗」，鄰近節目音依內容偏差、各狀態不同 → 差分抵消不掉 → 假峰。
- **群集漂移拉回**：差分要求群集在頭尾（基準）與中間（探測）完全一樣；4 kHz 時 0.05 ms 就差 0.07 週期。
  沒拉回時自測抓到「+1.5 ms 被估成 −0.06 ms 還標可採信」。
- **參考曲線用「和」的權重、只接受「和」也有峰的位置**；兩台直達相消時反射可以比直達高 → 另外標 referenceAmbiguous。

## 6. 離線自測結果（2026-09-29，-O、10 核；只有模擬）

`monitor-selftest`（全套 17 秒；`--quick` 7 秒）：
| 項目 | 結果 |
|---|---|
| 鼓點／人聲，藍牙 +1.5 ms，只探藍牙（+3、+4、+3+4） | 22/22 可採信、全部在 ±0.3 ms（最大偏差 0.061 ms） |
| 探測 +3 ms／+4 ms 分離 | 8/8、8/8 |
| 藍牙＋有線、四台輪流 | 不給錯值；藍牙可採信 5/12；有線（真實 0）可採信 5 次、全部 ≤ 0.3 ms |
| 長音：弦樂（有顫音）／風琴（無顫音） | 32 次：可採信 11（弦樂 11/16、風琴 0/16），錯值 0 |
| 誤報率（真實誤差全 0，200 次隨機） | 0/200（最大 \|誤差\| 0.275 ms）；另跑兩組樣本外 400 次：0/400、0/400 |
| 無時間戳＋45 ppm、16 kHz 麥克風、−50 ppm | ✓（+1.509／+1.502／+1.521 ms） |
| 跳過條件（太小聲、只有低頻、麥克風只有雜訊、削波） | ✓ |
| 藍牙 +12 ms → 量得到（決策器標需要重新校正）；+25 ms → 不可採信、歸類「量不到」 | ✓ |
| 決策器 11 項 | ✓ |

另外手動壓力測試（`monitor-sim`，沒有寫進自測）：頻帶內白噪 0 dB、藍牙比有線大 10 dB（GLASS5+ 在 C270 旁）、藍牙提早 0.6／1.5／3.5 ms
都估得到；藍牙大 15 dB 時有線太小聲，參考常失敗 → 標 referenceLowSnr（不算量不到、不給值）。

## 7. 限制與未實測（誠實）

- **全部只有模擬**：沒有用真的 C270 錄音跑過。模擬的喇叭 EQ 是零相位（群延遲 = 純延遲），電視色散在 1–4 kHz 平均為 0；
  實際喇叭若相位響應讓「音樂加權」與「粉紅雜訊加權」的 1–4 kHz 群延遲不同，會有固定偏差（沒量過，可能 0.1–0.3 ms 等級）。
- 參考只用單聲道（L+R 平均）；立體聲大幅左右分離的歌、各台左右聲道位置不同 → 相干性變差（沒模擬）。
- 風琴式純線譜長音一律「不可採信」（安全，但這類歌量不到）。
- 四台單一偏移輪流（每台 2 秒）資料太少，一律 probeTooShort；有線裝置請用 `pair` 或單台兩偏移的輪次。
- 探測內容換算（`fromOutputTimes`）假設 Engine 在呼叫後一個 IO 週期內開始斜坡；guard 50 ms。
- 分析在 -Onone 約 0.4 秒（除錯版 app），要放背景 queue。

## 8. 整合者要接的線（我沒有改這些檔）

- `Sources/CLI/CLI.swift` 的 `#if IU42_DIAG` 區塊加：
  ```swift
  case "monitor-selftest": rc = runMonitorSelfTest(rest)   // 背景監聽演算法離線自測（--quick 約 7 秒）
  case "monitor-sim": rc = cmdMonitorSim(rest)             // 單次模擬、印完整結果（調參用）
  ```
- `test.sh` 離線自測清單加 `"monitor-selftest --quick"`；發行版閘門可加「沒有 runMonitorSelfTest」。
