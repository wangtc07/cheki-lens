## Goal Description

為了落實 `AGENTS.md` 中規定的「斷點續傳與原子切片」開發守則，本計畫將開發任務拆解為極度細化的**原子任務（Atomic Tasks）**，並加上 Checkbox 以利後續開發時逐項確認與打勾。
同時，針對每個任務標註了建議使用的**代理人/快捷指令 (`/{command}`)**，協助您在發動任務時選擇最適合的 AI 執行模式。

_註解：_

- `(一般對話)`：直接輸入指令即可，不需特別加上 Slash Command。
- `/boost`：適合需要深度思考、撰寫複雜演算法或架構設計的任務。
- `/goal`：適合需要反覆試錯、長期執行或全面掃描的任務（例如寫測試或 QA 階段）。
- `/browser`：適合需要查閱最新官方文件（如 iOS 18 新 API）的任務。

## User Review Required

> [!IMPORTANT]
> 這是已轉換為 Checkbox 版本的原子任務清單，後續開發時我們將直接在對話中更新此份文件的打勾狀態。請確認清單格式與推薦指令是否符合您的工作流。

## Proposed Changes

### Phase 1：資料模型與核心架構 (SwiftData & Core)

- [ ] **Task 1.1**: 建立 Xcode iOS 專案結構（SwiftUI + SwiftData + iOS 18 Target），設置基本目錄架構。 `(一般對話)`
- [ ] **Task 1.2**: 定義 SwiftData `ChekiItem` 實體模型（圖片路徑、時間、規格比例、偏移率）。 `/boost`
- [ ] **Task 1.3**: 定義 SwiftData `IdolGroup` 與 `IdolMember` 實體模型，並建立關聯。 `/boost`
- [ ] **Task 1.4**: 定義 SwiftData `ChekiMemo` 實體模型（特典會筆記、Hashtag 標籤）。 `/boost`
- [ ] **Task 1.5**: 建立 `ModelContainer` 預設注入器，並撰寫 Preview 用的假資料生成器（Mock Data）。 `(一般對話)`
- [ ] **Task 1.6**: 編寫資料層單元測試，驗證 CRUD 操作、關聯綁定與級聯刪除邏輯。 `/goal`

---

### Phase 2：影像核心演算法 (Vision & Core Image)

- [ ] **Task 2.1**: 建立 `VisionManager` 單例核心類別，處理基本的影像方向與色彩預處理。 `/boost`
- [ ] **Task 2.2**: 實作 `VNDetectRectanglesRequest` 第一層自動錨點偵測（尋找相紙邊框）。 `/boost`
- [ ] **Task 2.3**: 實作第二/三層 Fallback 機制（邊緣偵測與白色相紙外框輪廓求解）。 `/boost`
- [ ] **Task 2.4**: 實作 `CIPerspectiveCorrection` 透視校正，鎖定 86×54 / 86×72 / 86×108 比例。 `/boost`
- [ ] **Task 2.5**: 實作邊界微調演算法（支援 Inset / Outset -3% ~ +3% 矩陣微調）。 `/boost`
- [ ] **Task 2.6**: 實作 `VNRecognizeTextRequest` 指定白邊區域掃描（提取手寫日期）。 `/boost`
- [ ] **Task 2.7**: 實作 Regex 日期解析器，將 OCR 字串轉換為 `Date` 物件。 `(一般對話)`
- [ ] **Task 2.8**: 撰寫影像演算法單元測試（透視拉直與日期提取）。 `/goal`

---

### Phase 3：iOS 系統相簿與權限管理 (Photos Framework)

- [ ] **Task 3.1**: 封裝 `PhotoLibraryManager`，處理 `PHPhotoLibrary` 授權狀態。 `(一般對話)`
- [ ] **Task 3.2**: 實作自動建立相簿階層結構邏輯（`ChekiLens` › `團體` › `成員`）。 `/boost`
- [ ] **Task 3.3**: 實作同秒寫入機制，確保正反面照片賦予同秒 `creationDate`。 `/boost`
- [ ] **Task 3.4**: 實作 OCR 日期回寫相簿功能，修改寫入時的 EXIF 時間軸。 `/boost`
- [ ] **Task 3.5**: 實作相簿雙向同步監聽（同步系統相簿刪除事件）。 `/goal`

---

### Phase 4：UI 介面開發 (SwiftUI Views - iOS 18 HIG)

#### Screen 01: 歡迎導引 (Onboarding)

- [ ] **Task 4.1.1**: 建立 `OnboardingView` 輪播架構 (`TabView`)。 `(一般對話)`
- [ ] **Task 4.1.2**: 實作頁面 1 自動拉直動畫展示。 `/boost`
- [ ] **Task 4.1.3**: 實作頁面 2 手寫 OCR 提取動畫展示。 `/boost`
- [ ] **Task 4.1.4**: 實作頁面 3 正反翻轉與備忘錄展示。 `/boost`
- [ ] **Task 4.1.5**: 實作 `@AppStorage` 狀態管理與開始按鈕。 `(一般對話)`

#### Screen 02: 典藏首頁 (Gallery)

- [ ] **Task 4.2.1**: 建立 `GalleryView` 主視圖與 `NavigationStack`。 `(一般對話)`
- [ ] **Task 4.2.2**: 實作頂部團體切換組件。 `(一般對話)`
- [ ] **Task 4.2.3**: 實作成員水平頭像膠囊列。 `(一般對話)`
- [ ] **Task 4.2.4**: 實作相片網格主體 (`LazyVGrid`)，支援雙/三欄切換。 `/boost`
- [ ] **Task 4.2.5**: 實作單張拍立得縮圖卡片元件。 `(一般對話)`
- [ ] **Task 4.2.6**: 實作底部 iOS 18 浮動導覽膠囊與相機 FAB 按鈕。 `/browser` (查閱最新 HIG)

#### Screen 03: 即時相機掃描 (Live Camera)

- [ ] **Task 4.3.1**: 封裝 `CameraPreviewView` (`AVCaptureVideoPreviewLayer`)。 `/boost`
- [ ] **Task 4.3.2**: 實作 3×3 九宮格與遮罩疊加。 `(一般對話)`
- [ ] **Task 4.3.3**: 實作即時 Vision 邊框追蹤疊加層（綠色虛線動態框）。 `/boost`
- [ ] **Task 4.3.4**: 實作頂部狀態列（曝光、閃光燈）。 `(一般對話)`
- [ ] **Task 4.3.5**: 實作底部快門與模式切換區。 `(一般對話)`

#### Screen 04: 批次配對工作台 (Pairing Workbench)

- [ ] **Task 4.4.1**: 整合 `PhotosPicker` 實現無上限多選照片匯入。 `(一般對話)`
- [ ] **Task 4.4.2**: 建立配對工作台排版網格。 `(一般對話)`
- [ ] **Task 4.4.3**: 實作三段模式切換（直接/自動/手動）。 `(一般對話)`
- [ ] **Task 4.4.4**: 實作「自動配對」邏輯與 Vision 防呆警示。 `/boost`
- [ ] **Task 4.4.5**: 實作「手動配對」點擊互動邏輯。 `/boost`
- [ ] **Task 4.4.6**: 實作處理進度條與完成回饋動畫。 `(一般對話)`

#### Screen 05: 單張全螢幕檢視 (Detail View)

- [ ] **Task 4.5.1**: 實作 Gallery 到 Detail 的英雄動畫 (`matchedGeometryEffect`)。 `/boost`
- [ ] **Task 4.5.2**: 實作全螢幕檢視器與縮放平移。 `/boost`
- [ ] **Task 4.5.3**: 實作頂部半透明日期時間藥丸 UI。 `(一般對話)`
- [ ] **Task 4.5.4**: 實作底部縮圖膠卷 (Filmstrip Scrubber)。 `/boost`
- [ ] **Task 4.5.5**: 實作底部標準工具列按鈕。 `(一般對話)`
- [ ] **Task 4.5.6**: 實作正反面 3D Y 軸翻轉動畫。 `/boost`

#### Screen 06: 情報・備忘面板 (Memo / Info Sheet)

- [ ] **Task 4.6.1**: 實作上滑手勢呼出面板互動。 `(一般對話)`
- [ ] **Task 4.6.2**: 實作主相片連動微縮動畫。 `/boost`
- [ ] **Task 4.6.3**: 實作 iOS 18 圓角群組資訊卡 (`presentationDetents`)。 `/browser`
- [ ] **Task 4.6.4**: 實作「特典會對話」文字編輯器。 `(一般對話)`
- [ ] **Task 4.6.5**: 實作 Hashtag 膠囊群組輸入介面。 `(一般對話)`
- [ ] **Task 4.6.6**: 實作日期與狀態編輯。 `(一般對話)`

#### Screen 07: 設定與 Pro 買斷 (Settings)

- [ ] **Task 4.7.1**: 建立設定頁面 `Form` (Inset Grouped)。 `(一般對話)`
- [ ] **Task 4.7.2**: 實作相簿同步開關與偏好綁定。 `(一般對話)`
- [ ] **Task 4.7.3**: 實作預設邊界偏移率設定介面。 `(一般對話)`
- [ ] **Task 4.7.4**: 實作 Pro 狀態顯示與購買入口。 `(一般對話)`

---

### Phase 5：商業化與進階功能 (StoreKit 2)

- [ ] **Task 5.1**: 封裝 `StoreKitManager`，處理終身買斷商品流程。 `/boost`
- [ ] **Task 5.2**: 實作 Paywall（付費牆）UI。 `(一般對話)`
- [ ] **Task 5.3**: 實作免費版每日額度計數器 (`UserDefaults`)。 `(一般對話)`
- [ ] **Task 5.4**: 實作免費版浮水印疊加與低解析度限制。 `/boost`
- [ ] **Task 5.5**: 實作 Pro 專屬「Mode B 雙角度去反光合成管線」。 `/boost`

---

### Phase 6：端到端整合與發布準備 (QA & Release)

- [ ] **Task 6.1**: 執行記憶體 Profiling，優化大量圖片批次處理速度。 `/goal`
- [ ] **Task 6.2**: 全 App Dark/Light Mode 色彩稽核。 `/goal`
- [ ] **Task 6.3**: 支援動態字級 (Dynamic Type) 測試。 `/goal`
- [ ] **Task 6.4**: 匯入 App Icon 與 Launch Screen。 `(一般對話)`

## Verification Plan

依照 `AGENTS.md` 規範，每完成上述一個被勾選 `[x]` 的原子任務後，都會自動進行：

1. 編譯檢查或 Unit Test。
2. 更新本文件（或對應的 `PROGRESS.md`）的狀態。
3. 執行單獨的 git commit（如：`feat(Data): 完成 Task 1.1`）。
