# In_Unison42

[English](README.md)

讓 Mac 上所有喇叭**同時**發聲，而且選單列音量滑桿／鍵盤音量鍵能**一起**控制總音量。

macOS 內建的「多重輸出裝置」可以同時出聲，但沒有音量控制；HDMI／DisplayPort 螢幕本身也沒有軟體音量。
In_Unison42 不裝任何音訊驅動，只用系統框架（CoreAudio／AudioToolbox／Accelerate／Foundation）。

## 原理

1. 系統預設輸出維持內建喇叭（有硬體音量，滑桿與音量鍵照常有效）
2. Core Audio Process Tap（macOS 14.2+）攔截全系統聲音，攔截期間原聲靜音（排除自己，避免迴授）
3. 私有聚合裝置：tap 當輸入，內建喇叭當主時鐘，其他實體輸出（HDMI、DisplayPort…）開漂移校正
4. IOProc：內建喇叭送原音（硬體已套音量）；其他裝置乘上內建喇叭的 10^(dB/20)，靜音時為 0
5. 每台喇叭有各自的延遲線（最多 1000 ms，足夠容納藍牙喇叭），用麥克風校正後，讓快的喇叭等慢的喇叭，聲音對齊
6. 裝置熱插拔、預設輸出變更、取樣率變更、IOProc 停住時自動重建（去抖動 500 ms、每秒健康檢查、第一次停住 2 秒就重建、退避重試、60 秒內最多 6 次）
7. 同時有麥克風的輸出裝置（藍牙耳機、USB 耳麥、會議喇叭）**不會**放進聚合裝置：否則會打開它的麥克風，而且聚合裝置的輸入 buffer 會把麥克風排在 tap 前面。IOProc 只讀 tap 所在的 buffer，輸入 buffer 數與預期不符就靜音並計數

程式結束或當掉時 tap 隨之消失，聲音自動退回內建喇叭（已實測 `kill -9` 後系統聲音正常）。
使用者自建的多重輸出裝置、AirPlay 不使用；Continuity（iPhone）麥克風只在校正時、使用者選它才開。

## 安裝

```sh
./build.sh --install          # 編譯「正式版」、簽章，並複製到 ~/Applications/In_Unison42.app
open ~/Applications/In_Unison42.app
```

- 只用系統框架，不需要安裝任何套件。`./build.sh`（不加 `--install`）只產生 `build/In_Unison42.app`，另有 `build/In_Unison42` 指向 app 內執行檔（CLI 用）。
- **兩種建置**（2026-09-29 實測，Mac mini M4）：

  | 指令 | 種類 | 旗標 | 編譯時間 |
  |---|---|---|---|
  | `./build.sh` | 除錯版（預設） | `-Onone -j10 -D DEBUG -D IU42_DIAG`，含診斷指令 | 3.4–4.4 秒（`time` 總計 4.19 秒） |
  | `./build.sh --release` | 正式版 | `-O -wmo`，不含診斷 | 25.6–25.9 秒 |
  | `./build.sh --install` | 正式版＋安裝 | 同上；`--debug --install`、`--install --no-sign` 會被拒絕 | |
  | `./build.sh --install-debug` | 除錯版＋安裝 | 要在安裝版上跑診斷時才用 | |

  正式版沒有 `bt-tone-test`／`mic-probe`／`engine-live-test`／`snapshot-live-test`／`output-guard set`（符號整段不編進去），
  `calibrate` 只准 `--pulse`／`--verify-program`／`--mode`／`--only <uid>`／`--mic <uid>`（`--dump`、`--signal`、chirp 等都拒絕），
  `ctl` 只開放面板本來就能做的事（`snapshot`、`bt attach/detach/simulate-reconnect`、`autocal simulate-appear` 只在除錯版）。
  `In_Unison42 version` 顯示建置標記（`git describe --dirty`＋時間＋種類）。
- **測試**：`./test.sh`（`-O` 增量編譯到 `build/test`）平行跑 11 個離線自測、15 份實機錄音 `pp-reanalyze` 對 `testdata/expected.json`（±0.05 ms）、
  另編一份正式版旗標確認診斷指令與危險參數被擋（10 項）。非 0 = 有回歸；`--update-expected` 重產標準答案（刻意改量尺後才用）。
  2026-09-29 實測：增量 18.2 秒、冷編譯 31.8 秒。錄音在 `testdata/dump/`（不進版控），`testdata/expected.json` 要進版控。
- **簽章**：預設 ad-hoc（`-`）＋Hardened Runtime，不需要任何憑證；代價是每次重新編譯後「系統音訊錄製」權限都要重新授權。
  有 Apple Development 憑證的話設 `IN_UNISON42_SIGN_IDENTITY="Apple Development: 你的名字 (TEAMID)" ./build.sh`（`security find-identity -v -p codesigning` 查）；也可以把身分寫在 `~/.config/in_unison42/sign_identity` 第一行，之後每次 build 自動套用：
  同一個身分簽的新版本，重新編譯、換位置（build/ → ~/Applications）後權限不會失效。
- 第一次啟動會跳「系統音訊錄製」授權；第一次校正會跳「麥克風」授權。
- **登入時打開**：面板底部勾選（或 `In_Unison42 ctl login-item on`）→ `SMAppService.mainApp` 註冊。app 必須在 `/Applications` 或 `~/Applications`。
  第一次開啟時會把舊版 LaunchAgent（plist 與 `bin/`）移到垃圾桶。舊的 `install`／`start` 指令已停用。

## 使用

選單列圖示（不出現在 Dock）：🔊 音樂、🎬 影片、🎮 遊戲、⚠ 音訊沒在跑、🔇 未啟動。點開是控制面板：

<picture><source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/panel-live-dark.png"><img src="docs/screenshots/panel-live-light.png" alt="In_Unison42 控制面板：自動模式（音樂）、3 台喇叭出聲、各自的延遲補償" width="420"></picture>

截圖分兩種（都是 ImageRenderer／AppKit 離屏渲染，不碰螢幕上的視窗）：

| 檔名 | 資料來源 | 內容 |
|---|---|---|
| `panel-live-{light,dark}.png`、`panel-live-appkit-*.png` | **真實狀態**（2026-09-29 01:18，執行中的 app `ctl snapshot`；登入項目已啟用） | 自動→音樂、3 台出聲、延遲為 `calibrate --pulse` 寫入的值 |
| `panel-live-game-{light,dark}.png` | **真實狀態**（`ctl mode game` 後） | 手動鎖定遊戲、電視顯示「不出聲：延遲 +34.71 ms 超過遊戲模式上限 20 ms」 |
| `panel-live-guard-{light,dark}.png` | **真實狀態**（`output-guard set MSI --yes` 後；之後 `ctl guard-restore` 切回內建） | 預設輸出守衛警告＋「切回『Mac mini的揚聲器』」按鈕 |
| `panel-live-config-protect-{light,dark}.png` | **真實狀態**（2026-09-29 15:00，V10：寫入壞 JSON 後重開，除錯版 `ctl snapshot`） | 設定檔損壞警告＋「重設設定」、全部未量測 |
| `panel-live-autocal-pending-{light,dark}.png` | **真實狀態**（2026-09-29 15:02，V9：`autocal simulate-appear` 後按取消） | 「〈GLASS5+〉已取消自動校正」＋「需要校正」按鈕、GLASS5+ 未校正不出聲（AppKit 渲染） |
| `panel-drift-{light,dark}.png` | **假資料**（`render-panel`） | 藍牙漂移補償（速度、修正、下次短校正）＋藍牙連上時保持預設輸出的紀錄 |
| `panel-{light,dark}.png`、`panel-game-*.png`、`panel-appkit-*.png` | **假資料**（`render-panel`） | iPhone 麥克風選項、藍牙列（未校正→不出聲）、登入項目待核准、校正進行中等手邊做不出來的畫面 |

### 模式：以延遲上限區分

| 模式 | 上限（相對最快的裝置） | 本機實測延遲下的結果 |
|---|---|---|
| 音樂 | 不限 | 內建、MSI、電視全部出聲；補償 34.46／33.20／0 ms |
| 影片 | 80 ms | 同上 |
| 遊戲 | 20 ms | 電視（+34.46 ms）不出聲；內建補償 1.26 ms、MSI 0 |

- 超過上限的裝置不出聲，補償只在出聲的裝置之間重算；切換時淡出、換延遲、再淡入，不重建聚合裝置。
- **自動**（預設）：依前景 app 切換，去抖動 1 秒。對照表在 `config.json` 的 `autoModeRules`（bundle id → movie/game/music）：
  預設 IINA、QuickTime、VLC、Infuse、Netflix、TV、mpv → 影片；Steam 與 `LSApplicationCategoryType` 為 `*games` 的 app、Steam 遊戲庫裡的程式 → 遊戲；其他 → 音樂。
- **手動**：選音樂／影片／遊戲＝鎖定，不再依前景 app 切換，直到選回「自動」。
- 瀏覽器裡看 YouTube／Netflix 仍算音樂（只看前景 app）。

### 每台裝置

開關（關掉＝不出聲）、音量微調 −12…+6 dB（放開才存；右鍵回 0 dB）、實測延遲與目前補償；不出聲時顯示原因。

### 延遲校正

面板「延遲校正」：選麥克風 → 開始校正。校正期間同步播放暫停、其他 App 的聲音被靜音，每台喇叭依序播粉紅雜訊脈衝（1–4 kHz），約 15–40 秒（有藍牙時脈衝間隔 2 秒）；
面板用的是**脈衝＋GCC-PHAT 量尺**（`calibrate --pulse`）：每台取「最大一致群」（寬 0.3 ms 的窗裡脈衝最多的一群；兩群一樣多時取較早的一群並在輸出註明），
一致的脈衝要 ≥ 3 個且 ≥ 一半才寫入它；**某台不合格只略過那台**（保留舊值），其他照寫；只有參考喇叭（內建）不合格才整次不寫。
（chirp 掃頻量尺 `calibrate` 仍保留給 CLI；在這個房間它常抓到內建喇叭的反射，見 [docs/TESTLOG.zh-TW.md](docs/TESTLOG.zh-TW.md)。）

**測試音與「延遲」的定義**：
- 測試音是**粉紅雜訊、只含 1–4 kHz**、80 ms、RMS −22 dBFS（舊版白雜訊 300 Hz–7 kHz、−20 dBFS；比較柔和）；參考喇叭以外每台 4 個（舊版 6 個）。
- **延遲 = 1–4 kHz 的群延遲**：GCC-PHAT 只用 1–4 kHz，取**包絡**（解析訊號絕對值）的峰值，不取載波峰。這幾台喇叭在不同頻帶的到達時間差 0.6–1.4 ms（色散），
  舊量尺用全頻帶的載波峰，會在「低頻主導／高頻主導」兩個峰之間跳；包絡峰不受相位影響，不會跳。
- **測試音不受系統音量影響**：校正子行程裡，HDMI／DP／藍牙改用固定增益 −8 dB（不乘系統音量；`--cal-gain-db <dB>` 可改、上限 0 dB、`off` = 舊行為）。
  內建喇叭照系統音量（硬體音量，本程式不動）。量測期間其他 App 的聲音被 tap 靜音，所以不會有突然變大聲的節目音。
- 舊白雜訊 `--signal noise`、木琴 `--signal xylo`（實機沒過，見 [docs/TESTLOG.zh-TW.md](docs/TESTLOG.zh-TW.md)「木琴測試音評估」）仍可選；試聽檔在 `docs/tone-samples/`（G5 版已淘汰）。

- 麥克風清單：自動（C270）、其他實體麥克風、iPhone（Continuity，只用於校正、平常不開）。**藍牙麥克風一律不列、不自動選、指定也拒絕**
  （開了會把藍牙喇叭切到 HFP 通話音質，量到的也不是 A2DP 的延遲）。
- 指定的麥克風不在時拒絕執行（不會默默改用別支）。

### 自動校正

實機驗收見 [docs/TESTLOG.zh-TW.md](docs/TESTLOG.zh-TW.md)「整合驗收」V8／V9。

- **新的輸出裝置接上**（從未校正過）：跳通知＋面板「3 秒後校正〈裝置名〉」倒數，可按「取消」（取消後面板留「需要校正」按鈕）；
  倒數完自動跑 `calibrate --pulse --only <uid>`（只量參考喇叭＋這台，其他沿用；有線約 20 秒，全部量約 47 秒）。
  **已校正過的藍牙**（重連、app 重開、漂移補償）自動走**短量測**：約 10–11 秒（原本 31 秒），見下方「藍牙漂移補償」。
- **校正過的有線裝置重新接上**：直接用舊值出聲，不播測試音。
- **校正過的藍牙真的斷線再連上**：比照 app 重開——串流一開始就不出聲、倒數 3 秒、`--only` 重校；
  通知沒授權、面板關著 → 面板打開才倒數（needsConsent）。理由：V8 實測 A2DP 串流每次重開延遲差 35–61 ms。
- **app 重開／登入啟動後的藍牙**（已校正過）：實測 app 重開後 GLASS5+ 延遲每次都不同（413.6／474.8／426.3／443.5／430.5 ms，系統回報的 kAudioDevicePropertyLatency 一直是 111.6 ms、沒有反映）
  → 校正完成前**先不出聲**，一樣倒數 3 秒自動重校（只量藍牙）。
- 校正麥克風被其他 App 占用（例如視訊通話）→ 延後並通知，麥克風空下來後自動再倒數；多台同時出現 → 合併成一次；同一時間最多一個校正。
- app 啟動時就在、但從未校正的裝置**不會**自動播測試音（只顯示「需要校正」）；自動校正失敗或被停止的裝置也不自動重試。
- `ctl autocal status|cancel|now`；規則與接線見 `docs/API.md` §12。
- **原音空窗**：校正時 app 和校正子行程「交接」tap（子行程先把麥克風、藍牙、afplay 準備好才讓 app 拆 tap；子行程一拆 tap 就讓 app 重建，不等分析與寫檔）。
  實測 coreaudiod：開始 85 ms、結束 99 ms 沒有任何 tap（以前開始約 1 秒）。

### 背景監聽：播音樂時自動修正落拍

規則與 API 見 [docs/API.md](docs/API.md) §13。

- 面板「播音樂時自動修正落拍」開關（**預設開**）。音樂模式、有節目音時，每 5 分鐘用校正麥克風（C270）聽 10 秒，
  以正在播的音樂為參考（1–4 kHz GCC-PHAT），輪流對藍牙（每輪）與一台有線（每 3 輪）加 +3／+4 ms 的探測偏移（0.5 秒斜坡），
  量它相對有線裝置的誤差；連續 2 次一致（30 秒後確認）才以 ≤ 0.1 ms/秒的斜率修正。> 10 ms、累計 > 50 ms、量到過之後連續 3 次量不到 → 不自己修，標「需要校正」。
  （「量不到 → 需要重新校正」＝**校正後至少可採信地量到過一次，之後連續 3 次量不到**才標。）
  藍牙已有漂移模型時，監聽的可採信結果改成漂移模型的一個量測點（不另外疊修正），見下一節。
- 麥克風被其他 App 占用、節目音太小或 1–4 kHz 能量不足、校正中 → 跳過這一輪。
- **隱私**：
  - 錄音**只在 app 記憶體裡計算，算完就丟，不存檔、不上傳**；log 只有統計量（dBFS、SNR、誤差 ms），沒有錄音內容。
  - 聆聽的 10 秒 macOS 會亮**橘色麥克風指示燈**（每 5 分鐘一次）。
  - **可以關**：面板開關或 `ctl monitor off`；關掉後不再開麥克風。絕不開藍牙喇叭的麥克風。
- 選單列圖示：有裝置在等校正（需要校正、等你打開面板才倒數、背景監聽標記、暫停出聲等校正的藍牙）時，右上角加一個提示點；點開面板頂端有「需要校正」橫幅與「立即校正」。
- ⚠ **實機結果：在這個房間（系統音量 38、C270 在 GLASS5+ 旁、有線喇叭離麥克風遠）演算法每一輪都判「不可採信」**，所以沒有修正過任何東西
  （安全面成立、功能面沒有在實機上證明）。見 [docs/TESTLOG.zh-TW.md](docs/TESTLOG.zh-TW.md)「第 B 輪整合驗收」。

### 藍牙漂移補償

規則與 API 見 [docs/API.md](docs/API.md) §14。

藍牙喇叭（GLASS5+）在同一個串流內延遲會慢慢漂（實測約 −0.78 ms／分鐘，是喇叭自己的 DAC 時鐘／A2DP 緩衝，程式端的重取樣吸收不到）。
- **預測補償**：同一個串流內的每次量測（只量藍牙的校正、`--verify-program`、背景監聽可採信的結果）→ 加權線性回歸估漂移速度，
  修正 = **最新一次實測值** + 速度 × 經過時間（剛量完就等於實測值；背景監聽的點誤差 2–4 ms，只幫忙估速度、不單獨決定修正），
  每 10 秒交給延遲修正（≤ 0.1 ms/秒 的緩慢斜率，聽不出來）。串流重開（重連、app 重開…）就重新開始，舊串流的修正一併清掉。
  速度超過 ±3 ms／分鐘或量測彼此矛盾 → 不外推、標「需要校正」。
- **預測失準**：新的量測和當時的預測差 > 3 ms（藍牙門檻）＝補償已經超出門檻，面板顯示「最近一次 … 預測失準」；
  **連續 2 次 → 「漂移不規則」**：不外推（修正停在最新實測）、標「需要校正」。
- **短校正**（約 10–11 秒，原本 31 秒）：只量藍牙時（`--pulse --only <藍牙>`）自動用短量測：參考×2、藍牙×4、參考×2，間隔 0.9 秒，
  搜尋窗以上次延遲為中心 ±150 ms，pilot（150 Hz、−40 dBFS）和準備時間重疊。找不到（例如重連後延遲跳太多）→ 自動改跑完整量測。
- **排程**：串流開始後約 3 分鐘量第 2 點（估速度），之後預估誤差可能超過 2 ms 就再量——GLASS5+ 的漂移速度會變，**照目前參數實際約每 5 分鐘一次**
  （「每 30 分鐘」的上限只有速度很穩的喇叭才用得到）。**優先挑音樂停下來的空檔**（節目音連續靜止 5 秒～10 分鐘、靜止前連續播了 ≥ 20 秒、
  系統沒靜音且音量 > −40 dB）直接跑、不中斷音樂；連續播放 30 分鐘都沒空檔才倒數 3 秒（通知沒授權 → 打開面板才倒數）。
  **校正後追蹤量測（2026-10-04）**：串流剛開始時藍牙延遲會一直長大（實測校正後 5 分鐘 GLASS5+ 晚 73 ms），所以這個串流的前 2 個追蹤點
  （約 3 分鐘、再約 4 分鐘後）**不等空檔、不倒數**，到期就直接短校正（約 10 秒，期間同步播放暫停）；之後才恢復上面的空檔優先規則。
  太久沒量到（預估誤差 2σ > 4 ms，約 7 分鐘）→ 修正先停住、不再沿舊速度外推。連續 3 次沒量到 → 標「需要校正」並**停止自動短校正**（按了量到才恢復）。
- ⚠ **目前的限制（誠實）**：這個補償只有在「約每 5 分鐘有一次量測」時成立（D2：殘差 < 2 ms）。**音樂整首接整首、沒有 5 秒以上的空檔時，
  照「30 分鐘才倒數」規則，量完一點約 7 分鐘後修正就凍結，之後 20 多分鐘誤差會隨 GLASS5+ 的漂移長到十幾～二十幾 ms**；
  實機驗收（量測間隔 10–18 分鐘）3 次殘差 +4.1／−9.2／−12.5 ms 全部超過 3 ms。另外 GLASS5+ 在驗收後段出現**約 17 ms 的階梯跳動**
  （同一次 4 秒的量測裡前兩個脈衝 436.7、後兩個 419.4／421.6 ms），這種跳動任何預測都補不了。要不要改規則見 [docs/ROADMAP.md](docs/ROADMAP.md)「第 C 輪留給 Kang 決定」。
- 面板「藍牙漂移補償」開關（預設開）＋每台：漂移速度、目前修正、預測失準、下次短校正。`ctl drift status`（含最近 6 筆藍牙殘差）。

### 其他

- **系統提示音只從內建喇叭出**：啟動時把「系統提示音輸出」設成內建，並把 `systemsoundserverd` 排除在 tap 外（不被靜音、不送到其他喇叭）：
  macOS 26+ 用 `CATapDescription.bundleIDs`＋`processRestoreEnabled`（它閒置被收掉、重啟換 pid 也自動排除），另外照舊排除目前的 process object；
  第一個 tap 建立前就設好。
- **設定檔損壞保護**：`config.json` 讀不出來時，壞檔改名保留為 `config.json.corrupt-<時間>`、寫入旗標 `config.json.protect`，app 用預設值執行但**不自動存檔**
  （不會拿預設值蓋掉使用者的校正結果）；面板頂端警告＋「重設設定」按鈕（`docs/screenshots/panel-live-config-protect-*.png`，真實狀態）。
  校正成功、按「重設設定」、`ctl config reset` 或把好的設定檔放回去（`ctl reload-config`）才解除。`In_Unison42 config status`／`ctl config status` 查狀態。
- **預設輸出守衛**：預設輸出被切到沒有音量的裝置（HDMI／DP）時，面板頂端提示並附「切回『Mac mini的揚聲器』」按鈕；只改預設輸出，不動音量。
- **藍牙喇叭**：不放進聚合裝置，另開只輸出的 IOProc，從節目音環形緩衝讀取並自適應重取樣吸收時鐘漂移；**絕不開它的輸入**（避免被切到 HFP 通話音質）。
  - 讀取點以「固定目標延遲」鎖定：每個週期用時間戳重算（藍牙輸出時間 − 補償 − 固定緩衝 30 ms），PI／前饋只吸收時鐘比例，延遲不會隨時間漂。
  - 校正：`calibrate --pulse`（面板「開始校正」）在子行程自己開藍牙輸出一起量；未量測的藍牙在量測時照「不補償」出聲、solo 脈衝間隔放大到 2 秒，
    每台藍牙的到達時間先用 6 個脈衝的寬窗（900 ms）同相累加找。**麥克風聽不到藍牙時只略過藍牙**（維持未校正＝不出聲），其他喇叭照常寫入。
  - 出聲規則：藍牙量過延遲 → 音樂模式出聲（其他喇叭等它）；影片 80 ms／遊戲 20 ms 上限照舊（A2DP 多半 > 80 ms → 自動不出聲）。
  - 重新連線：量過延遲的藍牙斷線再連上（或除錯版 `ctl bt simulate-reconnect`）→ **比照 app 重開**：重新 start 前 engine 先 hold（串流一開始就靜音）、
    倒數 3 秒、`--only` 重校（通知沒授權 → 面板打開才倒數）。舊政策（沿用舊值出聲）被 V8 推翻：A2DP 串流每次重開延遲差 35–61 ms。
    2026-09-29 17:55 **真的斷線重連實測過**（IOBluetooth `closeConnection`／`openConnection`，見 [docs/TESTLOG.zh-TW.md](docs/TESTLOG.zh-TW.md)「第 B 輪審查修正」）。
    **第一次**連上（這個 app 行程從沒啟動過它，例如 app 啟動 30 秒後才連上）也在 start 之前先 hold（避免約 1 秒用舊值出聲的空窗）；
    30 秒內＝當作 app 重開、之後＝當作重連，都倒數重校。
    注意：macOS 在藍牙重新連上時會把**系統預設輸出切到藍牙**（實測兩次都這樣）。所以藍牙連上後 **10 秒內**發生的這種切換會**自動切回**音量來源（內建），
    log 與面板「藍牙連上時保持預設輸出」記一筆（開關預設開）；之後你自己把預設輸出選成藍牙 → 尊重，照舊只警告＋「切回」按鈕。只改預設輸出，不動音量。
    只對**本程式在出聲的藍牙喇叭**這樣做：排除清單裡／被關掉的藍牙（例如排除的 AirPods）一律尊重，早就連著的藍牙被手動選成預設輸出也不會被當成「剛連上」。

## CLI（app 內執行檔帶子指令）

```sh
B=~/Applications/In_Unison42.app/Contents/MacOS/In_Unison42    # 或 ./build/In_Unison42
$B devices | mics | status | help
$B ctl state                          # 控制執行中的 app：state / mode auto|music|movie|game / snapshot <dir> /
$B ctl mode game                      #   guard-restore / calibrate [參數] / peaks <秒> / bt … / login-item …
$B ctl calibrate --verify-program --mode game --check-silent
$B ctl bt status                      # 藍牙：取樣率、固定緩衝、欠載、重對時、重取樣修正 ppm、填充量、出聲計畫
$B ctl bt simulate-reconnect <uid>    # 模擬藍牙斷線重連（除錯版；先不出聲、倒數、--only 重校）
$B ctl monitor status|on|off          # 背景監聽：狀態（最近一輪、每台誤差、累計修正、麥克風 DeviceIsRunningSomewhere）／面板開關
                                      #   除錯版：monitor now（下一秒就跑一輪）｜bias <uid> <ms>｜bias clear｜interval <秒>；autocal set-latency <uid> <ms>
$B ctl autocal status|cancel|now      # 自動校正：狀態／取消倒數／「需要校正」立即校正
$B ctl drift status|on|off            # 藍牙漂移補償：模型（量測點、速度、預測 ± σ）、下次短校正、最近一次觸發（空檔／倒數）；面板開關
$B ctl drift verify-feed on|off       #   驗收用：--verify-program 的結果要不要當量測點（執行期）
$B ctl output-restore status|on|off   # 藍牙連上 10 秒內 macOS 搶預設輸出 → 自動切回：狀態／面板開關
$B ctl config status|reset            # 設定檔唯讀保護狀態／重設為預設值（等同面板「重設設定」）
$B version                            # 建置標記（git describe＋時間＋debug/release）
$B ctl trim <uid> <dB>                # 等同面板音量微調；ctl reload-config：外部改過 config.json 後重讀
$B render-panel docs/screenshots      # 假資料面板截圖（離屏）
```

- 需要音訊權限的指令（`calibrate`、`mic-probe`、`engine-live-test`）要用 app 身分跑：在 app 執行中用 `ctl calibrate …`，
  或 app 沒在跑時 `open -W -n --stdout /tmp/x.log ~/Applications/In_Unison42.app --args <指令>`。從終端機直接跑，權限算在終端機頭上。
- `run`（前景 CLI 引擎）仍可用；同一時間只能有一個 tap 實例（app 或 run），兩個會互相靜音。

### 校正指令

```sh
$B calibrate [--mic <uid|名稱|auto>] [--mode music|movie|game]   # 量延遲並寫入 measuredLatencyMs
$B calibrate --pulse [--mic …]          # 脈衝＋GCC-PHAT 量尺量延遲並寫入（面板用這個；預設音樂模式＝所有啟用的都量）
$B calibrate --verify                   # 只驗證（目前模式下出聲的裝置），殘差 < 1 ms 回 0
$B calibrate --pulse --only <藍牙>     # 只量藍牙（已校正過 → 短量測約 10–11 秒；--full 改回完整量測）
$B calibrate --verify-program --only <藍牙>   # 只量藍牙的驗證（短量測、不寫入）：量到的延遲 vs app 目前用的（校正值＋修正）→ 殘差，門檻 3 ms
$B calibrate --verify-program [--check-silent]   # 獨立量尺：afplay → tap → 延遲線 → 各喇叭，GCC-PHAT；門檻：有線之間 1 ms、藍牙 3 ms
                                        #   （toleranceExternalMs：藍牙對任一台的到達差與自己的脈衝離散；有線 toleranceMs 維持 1 ms）
                                        #   --check-silent 另外 solo 不出聲的裝置，用匹配濾波證明它真的沒聲音
$B calibrate --volume-test              # 音量／靜音是否同時控制所有出聲的喇叭（只調低，結束還原）
$B snapshot-live-test                   # 實機驗證「還原只往下調、不覆蓋使用者中途的操作」（短暫調低音量／切預設輸出，結束回原值）
$B calibrate --selftest                 # 合成訊號自測，不出聲（含節目音路徑量尺：木琴／雜訊、藍牙 A2DP 模擬、最大一致群）
$B monitor-selftest [--quick]           # 背景監聽演算法離線自測（除錯版；純運算、不開麥克風）；monitor-sim：單次模擬
                                        # 註：app 經 ctl 跑 --verify-program 時會把背景監聽的延遲修正交給子行程（驗的是實際在播的補償）
$B calibrate --verify-program --signal ab-pink   # 同一段錄音裡粉紅（新）與白雜訊（舊）交錯比對（ab = 木琴 vs 白雜訊；只驗證、不寫）
$B pp-signal pink|noise|xylo|xylo-strong out.wav # 測試音寫成 WAV（試聽）
#   --pulse／--verify-program／--volume-test 預設連藍牙一起量；--no-bluetooth 不開藍牙；
#   --bt-uncalibrated（實機測試用，預設關）：驗證時讓未校正的藍牙照「不補償」出聲
#   --signal pink|noise|xylo|xylo-strong|ab|ab-strong|ab-pink：測試音（預設 pink）；--cal-gain-db <dB|off>：HDMI／DP／藍牙測試音固定增益（預設 −8）；--signal-for <uid|名稱>=<訊號>：只有那台換測試音
#   --dump <dir>：把錄音與中繼資料存下來，之後 `pp-reanalyze <dir>` 離線重新分析（調參用）
```

`--verify-program` 和 `calibrate`／`--verify` 刻意用不同的量尺：測試聲由另一個行程（`afplay`）播放，走和平常節目音同一條路徑；
訊號是粉紅雜訊脈衝 1–4 kHz（不是掃頻）；到達時間用 1–4 kHz GCC-PHAT 的包絡峰；時間軸只用麥克風自己的時間；每次只讓一台出聲，量測期間其他 App 的聲音被另一個 tap 靜音。

- log：`~/Library/Logs/In_Unison42.log`；狀態：`~/Library/Application Support/In_Unison42/state.json`；設定：同目錄 `config.json`（第 2 版）。
- 同一時間只能有一個 tap 實例：`~/Library/Application Support/In_Unison42/instance.lock`（flock）。第二個 app 會等（面板提示），前一個結束後 1 秒內自動接手；
  從終端機直接跑 `calibrate`／`run` 時若 app 在跑會被擋下（請用 `ctl calibrate …`）。
- 自測：`plan-selftest`、`mode-selftest`、`engine-selftest`、`reconnect-selftest`、`service-selftest`、`bluetooth-selftest`、`panel-snapshot --selftest`、`calibrate --selftest`。

## 限制

- 需要 macOS 14.2 以上（Process Tap）。
- 螢幕休眠（`pmset displaysleepnow` 8 秒、60 秒）時，HDMI／DP 音訊裝置**沒有**消失，所以不會觸發重建。**實體拔插螢幕線、整機睡眠（`pmset sleepnow`）都還沒有實測**；重建與喚醒路徑只在虛擬時間模擬中驗證（喚醒偵測 ≤ 1 秒、喚醒後 1 秒 IO 沒前進就強制重建、IO 停住 2 秒就重建）。
- 預設輸出切到沒有音量的裝置（HDMI／DP、「全部喇叭」）時，音量來源仍是內建喇叭；此時音量鍵／選單列滑桿調不到任何喇叭（macOS 對 HDMI 就沒有音量）。面板會提示並提供一鍵切回；不會自動切。
- 預設輸出切到「另一台有硬體音量的輸出」時，音量來源應跟著換：這條路徑**只有 selftest**，沒有實機測過（手邊沒有 USB DAC／USB 耳機這類有音量又沒有麥克風的裝置）。
- 同時有麥克風的**有線**輸出裝置（USB 耳麥）不會一起出聲（見原理 7）；藍牙喇叭走只輸出路徑：實機確認不觸發 HFP、重取樣 3 分鐘欠載 0（增益 0 時）。
  **GLASS5+ 已校正、音樂模式四台出聲**（app 重開會自動 `--only` 重校，因為 app 重開後延遲差 35–61 ms）。
  藍牙驗證門檻是 **3 ms**（有線之間 1 ms）：V7 連續 3 次都過（藍牙差 0.81／1.53／2.17 ms），但**藍牙延遲在同一個串流內會單向漂**（V7：1.5 分鐘漂 1.4 ms），
  照這個速度幾分鐘後就超過 3 ms——**「藍牙 3 ms」只在剛校正完的短時間內成立**，目前沒有定期重量、PI 迴路也不參考量到的延遲（尚未決定）。
  （舊紀錄：13:32–13:41 用 1 ms 門檻時 6 次過 4 次。）藍牙「出聲中」的長時間重取樣、**真的斷線重連**前後延遲差都還沒量。
- 登入項目（SMAppService）已註冊，但**沒有**做登出再登入或重開機的實測。**app 當掉後不會自動重啟**（`SMAppService.mainApp` 沒有 KeepAlive；舊 LaunchAgent 有）：
  當掉時 tap 隨行程消失、聲音退回內建喇叭，要手動再打開 app。需要自動恢復要另外設計（例如 `SMAppService.agent` 看門狗），目前沒做。
- 木琴 C5 在這個房間量不準（見 [docs/TESTLOG.zh-TW.md](docs/TESTLOG.zh-TW.md)「木琴測試音評估」），測試音用粉紅雜訊。
- 喇叭的到達時間隨頻帶差 0.6–1.4 ms（MSI、電視）：「延遲」定義成 1–4 kHz 的群延遲，低音與高音部分實際上會差這麼多（喇叭本身的特性，補償只能對一個頻帶）。
- chirp 校正（`calibrate`）在這個房間不穩：內建喇叭 +4 ms 的反射幾乎和直達聲一樣強、電視 SNR 約 6 dB，4 次寫入都不合格；面板改用脈衝量尺（`--pulse`）。
- 從舊版（沒有實例鎖）的 app 直接換成新版時，舊版不會讓出：先結束舊版再開新版（`build.sh --install` 不會停掉執行中的 app）。
- 模式切換的淡入淡出只有離線波形測試，沒有錄音或聽感驗證。
- 系統提示音若由 `systemsoundserverd` 以外的行程播放（例如未來版本改由 audiomxd），不會被排除。
- 延遲補償是整台裝置一個值；房間回音、喇叭的群延遲只能靠 `--verify` 檢查。
- 啟動後第一秒偶爾會有一次 HAL 丟 IO 週期（log 的 `skip=1`），已把跳過的 frame 補進時間軸，不影響校正。
- 權限未授與時 IOProc 不會跑，自動重建會以 2、4、8…秒（上限 300 秒）退避；授權後最久約 5 分鐘自動恢復，或直接 `stop` 再 `start`。

程式結構與內部 API：[docs/API.md](docs/API.md)。開發期間的實機驗收紀錄：[docs/TESTLOG.zh-TW.md](docs/TESTLOG.zh-TW.md)。

## 後續規劃

見 [docs/ROADMAP.md](docs/ROADMAP.md)。AirPlay 輸出徵求有裝置的人接手。

## 授權

[MIT](LICENSE) © 2026 Okle42
