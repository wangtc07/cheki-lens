# ChekiLens UI 修正代理人規範 (UI Fix Agent Guidelines)

> **何時呼叫本文件**：任何「新增、修改、檢查、重構 UI／UX／動畫／手勢」的工作，動手前必須先讀完本文件。
> 本文件是 `AGENTS.md` 的 UI 專章，優先級高於個別畫面現有寫法。現有程式與本文件衝突時，**以本文件為準**，並於同一任務內修正或登記到 §9。
> 觸發語：「修 UI」「調整按鈕」「統一風格」「檢查 UIUX」「縮放／手勢／動畫」。

---

## 0. 啟動流程 (Start-of-Turn)

1. 讀 `docs/PROGRESS.md` 與 `git status`、`git log -n 3`，告知使用者目前進度與本次 Task。
2. 讀本文件 §1～§8，並從 §9 找出本次任務涵蓋的偏差項目。
3. **一次只處理一個任務**（例如「只改取消／完成文字」或「只抽出縮放元件」）。禁止順手重構無關畫面。
4. 動手前先 grep 現況（見 §10），改完後再 grep 一次，證明違規數量下降。

---

## 1. 設計原則

1. **遵循 Apple HIG 與 iOS 26 Liquid Glass**：導覽列、工具列、選單、TabBar 優先使用系統元件（`NavigationStack` + `.toolbar`、`Menu`、`TabView`），系統會自動套用玻璃效果與正確的位置、尺寸。
2. **玻璃不是強制，是工具**：
   - 浮在內容（照片、相機預覽）上的操作鈕 → 液態玻璃。
   - 需要「一眼看出狀態」的控制（閃光燈、補光燈、已選取、已啟用）→ 依 §4 使用語意色，不可只靠玻璃或透明度表達。
   - 純文字表單、設定頁 → 系統 `Form` / Inset Grouped，不加玻璃。
3. **同一件事，同一種長相**：關閉、確認、更多、新增、返回，在所有畫面必須是同一個元件、同一個尺寸、同一個位置。
4. **畫面切換時按鈕不跳動**：左上／右上／底部的按鈕，跨畫面時要盡量落在同一個座標、同一個尺寸（§3）。
5. **相同操作，相同手勢，相同動畫**（§6）。
6. 不引入第三方 UI 套件。

---

## 2. 共用元件（單一來源）

所有 chrome（浮動按鈕、膠囊）**只能**透過 `ChekiLens/Sources/Views/Shared/` 內的共用元件產生。禁止在各畫面自行 `.frame(width:height:)` + `.background(Circle())`，也禁止再新增私有玻璃修飾器。

### 2.1 目標狀態（`ChromeMetrics` 與按鈕元件由 Task 6.6.1 建立、`ChekiMotion` 由 6.6.6、`GridPinchZoom` 由 6.6.7）

| 元件 | 用途 | 規格 |
| --- | --- | --- |
| `ChromeMetrics` | 全 App chrome 尺寸、邊距、圓角常數的唯一定義 | 見 §3 |
| `ChromeCircleButton` | 圓形圖示鈕（關閉、返回、旋轉、裁切、分享、刪除…） | 直徑 `ChromeMetrics.circle` |
| `ChromeCapsuleButton` | 膠囊鈕（日期、規格、確認等） | 高度 `ChromeMetrics.circle`，圓角＝高度／2 |
| `CloseToolbarButton` | 取消／關閉，永遠是 `xmark` 圖示 | 見 §5 |
| `ConfirmToolbarButton` | 完成／確認，永遠是 `checkmark` 圖示 | 見 §5 |
| `ChekiMotion` | 動畫常數 | 見 §6 |
| `GridPinchZoom` | 格狀縮放手勢＋即時跟手狀態 | 見 §7 |

### 2.2 現況：待合併的重複實作（登記於 §9）

目前同一種玻璃按鈕有 4 套各自實作，尺寸與前景色不一致：

- `AlbumChrome.swift`：`darkSystemCircleChrome` / `darkSystemCapsuleChrome` / `pairingLiquidGlassCircle` / `pairingLiquidGlassCapsule`（前景色用 `.primary`）
- `ChekiDetailView.swift` 私有 `detailLiquidGlassCircle` / `detailLiquidGlassCapsule`（前景色用 `.white`）
- `CameraScannerView.swift` 內的 `cameraLiquidGlassCapsule` 等
- `BatchPairingView.swift` 預覽頁以 `Color.black.opacity(0.50)` / `Color.white.opacity(0.18)` 手刻非玻璃按鈕

**修改任何一套之前，先改成呼叫共用元件，不要在舊實作上再疊加參數。**

---

## 3. 尺寸與位置規範 (Chrome Geometry)

下列數值為初始 token，**只能定義在 `ChromeMetrics`**，需要調整時只改這一處。

| Token | 值 | 說明 |
| --- | --- | --- |
| `circle` | 44 pt | 所有圓形圖示鈕直徑（也是 HIG 最小點擊區） |
| `capsuleHeight` | 44 pt | 所有膠囊鈕高度，與 `circle` 相同，圓角半徑因此一致（22 pt） |
| `icon` | 17 pt, `.semibold` | 圖示字級（SF Symbol） |
| `capsuleHPadding` | 16 pt | 膠囊內左右留白 |
| `edgeHorizontal` | 16 pt | 距左右安全區邊界 |
| `edgeTop` | 與系統導覽列按鈕同一條基準線 | 見下方規則 |
| `edgeBottom` | 底部安全區上方 12 pt | 底部浮動按鈕列 |
| `groupSpacing` | 12 pt | 相鄰按鈕間距 |

### 3.1 位置規則

1. **左上＝離開／返回；右上＝動作（新增、確認、更多 `⋯`）；底部＝針對目前內容的操作。** 跨畫面不得更換角色。
2. **頂部按鈕優先使用真正的系統 `.toolbar`**。全螢幕畫面（`fullScreenCover`、相機、單張編輯）也應包在 `NavigationStack` 內用 `ToolbarItem(.topBarLeading / .topBarTrailing)`，系統會保證和批次工作台、相冊頁的按鈕在同一座標與尺寸。只有在系統 toolbar 做不到（例如相機要隱藏導覽列）時，才使用 `ChromeMetrics` 手刻，並且座標必須與系統 toolbar 對齊。
3. **同一邊的按鈕組合順序固定**：右上由左至右 ＝ `[主要動作 (+ / 確認)]` `[更多 ⋯]`；單一關閉鈕永遠在最外側角落。
4. **底部按鈕列**：同一頁面內所有按鈕（圓、膠囊）高度皆為 44 pt，垂直置中對齊；圓角半徑必須一致，不得出現 44 圓配 42 膠囊的「微妙差別」。
5. 橫向（landscape）使用相同尺寸，不另設 30 pt 縮小版。空間不足時改用 Menu 收納，而不是縮小按鈕。
6. 點擊區域一律 ≥ 44×44 pt（`.contentShape`）。

### 3.2 範例對照（這次要消除的差異）

- 批次工作台右上 `+`／`⋯` 為系統 toolbar；單張預覽頁右上 `xmark` 為手刻 34 pt 深色圓、裁切頁 `xmark` 為 36 pt 玻璃圓 → 三個畫面三種尺寸、風格。**應統一為系統 toolbar 按鈕或 `CloseToolbarButton`。**
- 單張預覽底部：`crop`／`rotate.left` 為 44 pt 半透白圓、「規格與日期」膠囊高度由 padding 推算（約 42 pt）→ 圓角半徑不同。**應全部為 `ChromeCircleButton` / `ChromeCapsuleButton`，高度 44 pt。**

---

## 4. 色彩與狀態語意

1. **狀態必須能「一眼看出」**。禁止用「白 vs 半透明白／灰」作為唯一的開關狀態差異。
2. 語意色：

| 情境 | 色彩 |
| --- | --- |
| 相機閃光燈／補光燈：開、自動 | **黃色** `.yellow`（與 Apple 相機一致）；關閉為白色 |
| 相機中其他「已啟用」開關（九宮格、曝光已調整、進階控制已展開） | 啟用＝黃色；停用＝白色（不得用降低透明度） |
| 選取、已勾選 | 系統 `tint`（藍）或 `checkmark.circle.fill` |
| 破壞性（刪除） | `role: .destructive`（紅） |
| 一般玻璃圖示鈕 | 浮在照片／相機／深色沉浸畫面上：`.white`；浮在系統背景上：`.primary` |

3. 前景色規則二選一，**不要在同一畫面混用**：沉浸式畫面（相機、單張檢視、裁切）統一 `.white` 並套 `.environment(\.colorScheme, .dark)`；一般畫面（相冊、設定、工作台）用系統預設。
4. 狀態以「色相 + 圖示變體」雙重表達（例如 `bolt.fill` 黃 ↔ `bolt.slash.fill` 白）。
5. 禁用狀態使用系統 `.disabled(true)`，不要手刻 `opacity(0.42)`。

---

## 5. 文字、在地化與取消／確認

1. **工具列與 chrome 內的「取消」一律用 `xmark` 圖示，「完成／確認」一律用 `checkmark` 圖示**，並加 `accessibilityLabel`（中日雙語）。原因：日文「キャンセル」「完了」過長，會擠壓標題而讓中間文字不置中。
2. iOS 26 可用 `Button(role: .cancel)` / `Button(role: .confirm)` 讓系統自動渲染為 `xmark` / `checkmark`；因為最低支援 iOS 17，必須提供 `Image(systemName:)` 後備，統一由 `CloseToolbarButton`、`ConfirmToolbarButton` 包裝。
3. **例外**：`alert`、`confirmationDialog` 內的 `Button("取消", role: .cancel)` 由系統排版，保留文字，不改。
4. 圓形 chrome 內不得放文字。膠囊內有文字時必須：`.lineLimit(1)`、`.minimumScaleFactor(0.8)`，且在 `ja` 下確認不截斷、不推擠相鄰元素。
5. 導覽標題要保持視覺置中：左右兩側按鈕寬度應相等（單一圓鈕對單一圓鈕），不要一側放長文字。
6. 所有固定文字走 `L10n.tr("繁中", "日本語")`；避免括號與硬編碼 `\n`（見 Task 6.5.12）。

---

## 6. 動畫與互動一致性 (`ChekiMotion`)

| Token | 值 | 用途 |
| --- | --- | --- |
| `toggle` | `.snappy(duration: 0.22)` | 選單切換、勾選、模式切換 |
| `small` | `.spring(response: 0.30, dampingFraction: 0.82)` | 小元件展開／收合、重設縮放 |
| `layoutCommit` | `.spring(response: 0.50, dampingFraction: 0.86, blendDuration: 0.15)` | 格狀欄數切換、版面重排（縮放放開後） |
| `dismiss` | 跟手拖曳 + 放開彈簧回位 | 下拉關閉、縮回格位 |

規則：

1. 禁止在畫面內散寫 `spring(response:...)` 數字，一律引用 `ChekiMotion`。
2. **跟手優先**：任何由手勢驅動的視覺變化，手指未離開前必須持續跟隨（以 `Transaction.disablesAnimations = true` 更新即時狀態），放開才以彈簧動畫定位。
3. 觸覺回饋：欄數／模式／選取「確定改變」時一次 `UIImpactFeedbackGenerator(.light)`；不得在手勢進行中連續觸發。
4. 尊重「減少動態效果」（`accessibilityReduceMotion`）：開啟時以 `.easeInOut(0.15)` 取代彈簧。

---

## 7. 縮放手勢標準：「跟手縮放，放開才定位」

**基準實作**：`AlbumHeroDetailView.pinchZoomGesture`（`LibraryView.swift`，成員頁）。所有可縮放的格狀頁面一律採同一邏輯，並收斂進 `GridPinchZoom`：

1. `MagnifyGesture.onChanged`：
   - 第一次呼叫時記下 `pinchBaselineColumnCount`。
   - 將 `value.magnification` 以阻尼換算成即時縮放：放大 `1 + min(m-1, 1.2) × 0.32`；縮小 `1 - min(1-m, 0.55) × 0.32`。
   - 以 `disablesAnimations` 的 transaction 寫入 `livePinchScale`，內容用 `.scaleEffect(livePinchScale, anchor: .top)` 即時跟手。**不改變欄數、不播放動畫。**
2. `onEnded`：依 `value.magnification` 與門檻決定目標欄數：
   - 放大：`> 1.58` 少 2 欄；`> 1.15` 少 1 欄。
   - 縮小：`< 0.62` 多 2 欄；`< 0.86` 多 1 欄。
   - 以 `ChekiMotion.layoutCommit` 同時更新 `columnCount` 並把 `livePinchScale` 歸 1；欄數有變才觸發一次觸覺回饋。
3. 欄數集合預設 `[1, 2, 3, 5]`；偏好以 `@AppStorage` 保存，漢堡選單內「N 欄」選項需與手勢同步（選單切換使用 `ChekiMotion.layoutCommit`）。
4. 手勢以 `.simultaneousGesture` 掛在捲動內容上，不得干擾捲動與 `NavigationLink` 點擊。
5. 縮放期間不得出現黑屏或縮圖閃爍（縮圖快取需預先涵蓋相鄰欄數尺寸）。

**適用頁面（全部都必須是這套）**：

| 頁面 | 現況 | 目標 |
| --- | --- | --- |
| 成員相冊 `AlbumHeroDetailView` | 即時跟手、放開定位（基準） | 保持，並改由 `GridPinchZoom` 驅動 |
| 全部 `LibraryView` | 門檻一過就即時切欄動畫（不跟手） | 改為基準邏輯 |
| 相冊 `AlbumsRootView`（團體／成員封面磚） | **無縮放** | 新增，欄數預設 2，集合另定（見 Task 6.6.8） |

---

## 8. 畫面清單與檢視重點

| 畫面 | 檔案 | 檢視重點 |
| --- | --- | --- |
| 導引 | `OnboardingView.swift` | 按鈕尺寸、玻璃使用 |
| 全部／相冊／搜尋 | `LibraryView.swift` | 右上 `+ ⋯`、選取模式底部列（48 pt → 44 pt）、縮放 |
| 批次工作台 | `BatchPairingView.swift` | 系統 toolbar 的取消改 `xmark`、`+`/`⋯` 位置為右上基準 |
| 單張預覽放大／裁切編輯 | `BatchPairingView.swift` | 右上關閉鈕與工作台一致；底部圓／膠囊高度 44；裁切頁底部功能列 |
| 相機 | `CameraScannerView.swift` | 閃光燈黃色狀態、頂部圖示 44 pt、關閉鈕位置 |
| 單張檢視 | `ChekiDetailView.swift` | 返回鈕 36/30 → 44；底部工具列；取消／完成 |
| 資訊面板 | `ChekiInfoView.swift` | 完成鈕改 `checkmark` |
| 設定 | `SettingsView.swift` | 完成鈕改 `checkmark` |

---

## 9. 基線稽核：已知偏差 (Audit 2026-10-11)

> 每完成一項，在該列加上 `✅ Task 6.6.x`。新發現的偏差也登記在此。

| # | 偏差 | 位置 | 對應任務 |
| --- | --- | --- | --- |
| A1 | 玻璃按鈕有 4 套重複實作、前景色與尺寸不一 | `AlbumChrome.swift`、`ChekiDetailView.swift`（私有擴充）、`CameraScannerView.swift`、`BatchPairingView.swift` | 6.6.1 |
| A2 | 工具列「取消／完成」使用文字，日文過長導致標題不置中 | `BatchPairingView.swift` ~437、~3447、~3626；`LibraryView.swift` ~3493；`ChekiDetailView.swift` ~3673、~3678；`SettingsView.swift` ~519 | 6.6.2 |
| A3 | 批次工作台 `+ ⋯`（系統 toolbar）與單張預覽 `xmark`（34 pt 黑圓）、裁切頁 `xmark`（36 pt 玻璃）尺寸、位置、風格皆不同 | `BatchPairingView.swift` ~437–485、~1620–1632、~3590–3600 | 6.6.3 |
| A4 | 單張預覽底部：44 pt 半透白圓與約 42 pt 膠囊圓角不同；非玻璃手刻 | `BatchPairingView.swift` ~1690–1735 | 6.6.3 |
| A5 | 裁切編輯頁底部功能列為深色不透明底（`Color(white: 0.08)`）＋ 文字圖示，與其他頁 chrome 風格不同 | `BatchPairingView.swift` ~3940–4010 | 6.6.3 |
| A6 | 相機：閃光燈關／開僅以 `white.opacity(0.55)` vs `white` 區分，看不出已開啟；九宮格同樣只改透明度；頂部圖示 34 pt、非玻璃 | `CameraScannerView.swift` ~857–925 | 6.6.4 |
| A7 | 單張檢視返回鈕 36/30 pt（橫向縮小）、與工作台／相冊不同 | `ChekiDetailView.swift` ~408–420 | 6.6.5 |
| A8 | 選取模式底部列圓鈕 48 pt，與其他 chrome 44 pt 不同 | `LibraryView.swift` ~3633、~3659 | 6.6.5 |
| A9 | 全部頁縮放：門檻觸發即時切欄，非跟手 | `LibraryView.swift` ~541–573 | 6.6.7 |
| A10 | 相冊頁（團體／成員封面磚）不支援縮放 | `LibraryView.swift` `AlbumsRootView` ~837 起 | 6.6.8 |
| A11 | 動畫參數散寫（`0.3/0.82`、`0.32/0.82`、`0.50/0.86`、`0.22` 等） | 全部 Views | 6.6.6 |

---

## 10. 稽核指令（改前、改後各跑一次）

```bash
cd ChekiLens/Sources/Views

# 手刻 chrome 尺寸（應只出現在 Shared/ChromeMetrics 相關檔案）
rg -n "\.frame\(width: (3[0-9]|4[0-9]|5[0-9]), height: (3[0-9]|4[0-9]|5[0-9])\)"

# 文字型取消／完成（toolbar 與 chrome 內應為 0；alert / confirmationDialog 除外）
rg -n 'Button\("(取消|完成)"|L10n\.tr\("(取消|完成)"'

# 以透明度表達狀態（相機等處應為 0）
rg -n "foregroundStyle\(.*\? \.white : \.white\.opacity"

# 散寫動畫參數（應只出現在 ChekiMotion）
rg -n "\.spring\(response:|\.snappy\(duration:"

# 重複的玻璃修飾器（應只剩共用元件）
rg -n "glassEffect\(|ultraThinMaterial"
```

---

## 11. 驗證清單 (Definition of Done)

一個 UI 任務完成前，逐項確認：

- [ ] `xcodebuild -scheme ChekiLens build` 通過（並跑既有單元測試，不得退步）。
- [ ] §10 對應稽核指令的違規數量下降，且 §9 該列已標示完成。
- [ ] **繁中與日文**兩種語言各看一次；日文不截斷、標題置中。
- [ ] **淺色與深色**模式各看一次。
- [ ] **小螢幕（iPhone 12 mini）與大螢幕**各看一次；必要時含橫向。
- [ ] 跨畫面來回切換（例如：批次工作台 → 單張預覽 → 裁切 → 返回），左上／右上／底部按鈕的位置與尺寸肉眼無跳動。
- [ ] 手勢：縮放、下拉關閉、左右滑動在新舊畫面行為一致，無黑屏、無閃爍。
- [ ] VoiceOver 標籤齊全（圖示鈕皆有 `accessibilityLabel`）。
- [ ] 未新增私有玻璃修飾器、未新增魔術數字。

---

## 12. 收尾協議

1. 更新 `docs/PROGRESS.md`：勾選任務、更新「最新狀態摘要」與「下一動執行指示」。
2. 更新本文件 §9 的偏差表。
3. 以單一 commit 提交：

```bash
git commit -m "feat(UI): 完成 Task 6.6.x 任務內容說明"
```

4. 在回覆中列出：改了哪些畫面、尺寸／位置前後對照、還剩哪些 §9 項目。
