# ChekiLens 開發進度與斷點記錄 (Progress & Task Board)

> **使用說明**：本文件為 ChekiLens 專案之「單一進度事實來源（Single Source of Truth）」。
> AI 代理人或開發者在開始任何工作前，**必須先讀取本文件與 `git status`**，確認最新斷點；在完成任何任務後，**必須立即更新此文件之狀態並進行 git commit**。

---

## 📍 最新狀態摘要 (Current Checkpoint)

* **最後更新時間**：2026-09-30
* **當前所屬階段**：Phase 1 - 資料模型與核心架構
* **當前進行中任務**：Task 1.4 已完成
* **最新穩定 Git Commit**：feat(models): 完成 Task 1.1–1.4 SwiftData 資料層建置
* **下一動執行指示**：開始 Phase 2 影像核心演算法 (Task 2.1 VisionManager.swift)

---

## 🔄 斷點續傳協議 (Continuation Protocol)

當對話因**每日 AI 額度耗盡 (429 Quota Limit)** 或重啟而中斷時，請遵守以下規則：

1. **恢復開發時的第一句 Prompt**：
   > 「請先閱讀 `docs/PROGRESS.md`，並執行 `git status` 與 `git log -n 3` 檢查最新程式碼狀態。確認目前進度停在哪裡，然後接續執行下一個標記為 `[ ]` 或 `[/]` 的任務。」
2. **原子化原則**：
   * 每次提示只專注完成 **1 個任務**。
   * 完成一個任務後，AI 必須：
     1. 執行編譯/測試驗證。
     2. 更新本文件（將 `[ ]` 改為 `[x]`，並更新上方「最新狀態摘要」）。
     3. 進行 git commit（格式：`feat(模組): 完成 Task X.X 任務內容`）。

---

## 📋 原子微任務清單 (Atomic Tasks)

### 階段 0：環境與規範 (Phase 0: Project Setup)
- [x] **Task 0.1**: 專案目錄初始化、Git 倉庫建立與標準 `.gitignore` 設定
- [x] **Task 0.2**: 建立 AI 代理人開發指引規約 (`AGENTS.md`, `CLAUDE.md`, `.cursorrules`)
- [x] **Task 0.3**: 複製並歸檔需求設計規格 (`cheki_app_design.md`, `cheki_uiux_spec.md`, UI 展示檔)

---

### 階段 1：資料模型與核心架構 (Phase 1: Domain Models & SwiftData)
- [x] **Task 1.1**: 建立 Xcode iOS 專案結構（SwiftUI + SwiftData + iOS 17/18 Target）
- [x] **Task 1.2**: 定義 SwiftData 實體模型
  * `ChekiItem.swift`（正反面圖片資料、拍攝時間、手寫OCR時間、規格比例、邊界偏移率）
  * `IdolGroup.swift`（團體名稱、顏色識別、排序權重）
  * `IdolMember.swift`（成員藝名、本名、頭像圖、標籤、所屬團體關聯）
  * `ChekiMemo.swift`（特典會活動名稱、會話筆記文字、#標籤列表）
- [x] **Task 1.3**: 建立 ModelContainer 預設注入器與預覽假資料生成器（用於 SwiftUI Preview）
- [x] **Task 1.4**: 編寫資料層單元測試（CRUD、正反雙面綁定與級聯刪除）並驗證通過

---

### 階段 2：影像核心演算法 (Phase 2: Vision & Core Image Pipeline)
*參考來源：`src/image_process/cheki_crop.py`*
- [ ] **Task 2.1**: 建立 `VisionManager.swift` 核心類別與影像方向/色彩空間預處理
- [ ] **Task 2.2**: 實作第一層矩形辨識（`VNDetectRectanglesRequest` 自動錨點偵測）
- [ ] **Task 2.3**: 實作第二/三層 Fallback 機制（邊緣偵測與白色相紙外框輪廓求解）
- [ ] **Task 2.4**: 實作 `CIPerspectiveCorrection` 透視校正與比例鎖定（Mini: 86×54, Square: 86×72, Wide: 86×108）
- [ ] **Task 2.5**: 實作邊界微調偏移（Inset / Outset -3% ~ +3% 矩陣微調）
- [ ] **Task 2.6**: 實作底部手寫日期 OCR（`VNRecognizeTextRequest` 指定白邊區域掃描 + Regex 日期解析器）
- [ ] **Task 2.7**: 撰寫影像演算法單元測試（使用實體測試圖驗證透視拉直與日期提取）

---

### 階段 3：iOS 系統相簿與權限管理 (Phase 3: Photos Framework Sync)
- [ ] **Task 3.1**: 封裝 `PhotoLibraryManager.swift`（PHPhotoLibrary 授權狀態處理）
- [ ] **Task 3.2**: 實作自動建立相簿階層結構（`ChekiLens` › `團體` › `成員` 資料夾）
- [ ] **Task 3.3**: 實作同秒寫入機制（正面與背面照片賦予同秒 `creationDate` 緊鄰存入相簿）
- [ ] **Task 3.4**: 實作 OCR 日期回寫相簿時間軸（使用手寫日期取代翻拍當日時間）

---

### 階段 4：UI 介面開發 (Phase 4: SwiftUI Views - iOS 18 HIG)
*參考來源：`docs/ui/` 內 7 個高保真畫面*
- [ ] **Task 4.1**: 實作「01. ようこそ 歡迎導引輪播」（Apple 條列功能展示與權限引導）
- [ ] **Task 4.2**: 實作「02. アルバム 典藏首頁」
  * 頂部導覽列與分段控制（全部 / 團體 / 成員）
  * 雙欄圓角大卡片網格與標籤
  * 底部 iOS 18 浮動導覽膠囊 (`[ライブラリ | コレクション]`) ＋ 圓形搜尋鈕
- [ ] **Task 4.3**: 實作「03. カメラ 即時相機掃描」
  * AVFoundation 相機預覽流
  * 3×3 九宮格 ＋ 綠色拍立得虛線追蹤框
  * 頂部曝光指示（`露出 -0.3`）與閃燈膠囊、底部快門與模式切換
- [ ] **Task 4.4**: 實作「04. ペアリング 批次配對工作台」
  * PhotosPicker 多選匯入（不設張數上限）
  * 三段模式切換（直接執行 / ⚡自動配對 / 手動配對）
  * Vision 雙正面防呆警示標記與解除配對手勢
- [ ] **Task 4.5**: 實作「05. 写真詳細 單張全螢幕檢視」
  * 頂部半透明日期時間藥丸 (`9月17日 16:26`)
  * 底部縮圖膠卷 (Filmstrip Scrubber) 滾動切換
  * 5 大標準工具列按鈕（分享、愛心、ℹ️、調整、垃圾桶）
  * 3D Y 軸翻轉動畫查看背面手寫
- [ ] **Task 4.6**: 實作「06. 情報・備忘 上滑資訊面板」
  * 圖片微縮至上方、展開 iOS 18 圓角群組資訊卡
  * `キャプションを追加` 特典會對話備忘文字框
  * 日期與「調整」按鈕、活動資訊與 #標籤 膠囊群組
- [ ] **Task 4.7**: 實作「07. 設定與 Pro 買斷」
  * iOS Inset Grouped 分組表格
  * 相簿雙向同步開關與偏好設定

---

### 階段 5：商業化與進階功能 (Phase 5: StoreKit 2 & Polish)
- [ ] **Task 5.1**: 封裝 `StoreKitManager.swift`（Non-Consumable NT$120 終身買斷商品）
- [ ] **Task 5.2**: 實作每日 1 張 4K 高畫質免費額度計數器（UserDefaults 儲存）
- [ ] **Task 5.3**: 實作免費版浮水印疊加與低解析度輸出限制
- [ ] **Task 5.4**: 實作 Mode B 雙角度去反光合成管線（Pro 專屬功能）

---

### 階段 6：端到端整合與發布準備 (Phase 6: QA & Release)
- [ ] **Task 6.1**: 實機測試與效能調校（記憶體佔用、批次處理速度優化）
- [ ] **Task 6.2**: 支援深色/淺色模式與動態字級 (Dynamic Type)
- [ ] **Task 6.3**: 建立 App 圖示、啟動畫面與 App Store 截圖產生流程
