# ChekiLens 開發進度與斷點記錄 (Progress & Task Board)

> **使用說明**：本文件為 ChekiLens 專案之「單一進度事實來源（Single Source of Truth）」。
> AI 代理人或開發者在開始任何工作前，**必須先讀取本文件與 `git status`**，確認最新斷點；在完成任何任務後，**必須立即更新此文件之狀態並進行 git commit**。

---

## 📍 最新狀態摘要 (Current Checkpoint)

* **最後更新時間**：2026-10-08
* **當前所屬階段**：Phase 6 — 端到端整合與發布準備 (QA & Release)
* **當前分支**：`fix/camera-snap-and-antiglare-alignment`
* **當前進行中任務**：已完成 **Task 6.1** 實機問題專項修復與 **Google フォトスキャン 4 角點閃光去反光升級**：
  1. **拍照後與手動裁切「自動吸附」四角精準鎖定**：將相機拍後正位與手動裁切左下角「自動吸附」改為與取景器一致的純淨 `VNDetectRectanglesRequest` + 自然手持透視保護（內角 `68°~112°` 且對角和 `180°±14°` 時跳過會造成平行四邊形斜拉至木桌面的 `refineQuadrilateral` 與 `CIDetector` 面積覆蓋），並於按下快門瞬間鎖定取景器綠框 `trackedQuadPoints` 作為先驗錨點。
  2. **比照 Google フォトスキャン (PhotoScan) 4 角點開啟閃光燈對位與多角度 100% 去反光合成**：
     - **相機互動 (`CameraScannerView.swift`)**：切換至「防反光」模式時自動開啟相機 LED 持續補光燈 (`setTorchModeOn`) 將鏡面反光聚攏，先拍攝基準中心照，接著在拍立得四角浮現 `左上 ①`、`右上 ②`、`右下 ③`、`左下 ④` 4 個引導圓圈與中央準心環；將準心移至圓圈對準約 0.35 秒即自動吸附連拍（亦支援手動點擊或隨時按「立即合成」）。同時解除未解鎖 Pro 時誤落入單張拍照之門檻。
     - **全卡 `0% ~ 100%` 測地線光暈 100% 乾淨像素替換 (`VisionManager+AntiGlare.swift`)**：解除舊版頂部 `11.5%` 與底部 `22.5%` 邊框排除限制（解決頂部兔耳/氣球與底部手寫字反光無法消除問題），改用 `4×6` 截斷 L1 (`min(d, 85)`) 局部網格微平移對位 + 鏡面高光峰值種子 (`L >= 0.84`) + 4 輪測地線光暈膨脹，對反光核心與藍白光暈執行 `weight = 1.0`（100% 無反光像素替換），非反光區嚴格保持 `weight = 0.0` 零重影。
  3. **手動四頂點裁切編輯器支援移出相片邊界外 (`ChekiDetailView.swift`, `VisionManager+PerspectiveCorrect.swift`, `ChekiItem.swift`)**：放寬頂點拖曳與儲存範圍至 `-0.45 ~ 1.45`、加寬畫布預設邊距 (`padding: 44`) 並支援雙指縮小至 `0.65x`，且於透視校正超出相片邊界時透過 `clampedToExtent()` 自動延續相紙白邊色澤，避免傾斜超出畫面的拍立得邊角產生黑邊缺角。
  4. **單張全螢幕檢視單擊全畫面平滑漸進漸出與放大防跳動 (`ChekiDetailView.swift`)**：固定卡片基準 Layout Frame 並移除會觸發系統 Safe Area 重排的 `.statusBarHidden` 與 `if !isChromeHidden` 視圖銷毀重建，改以 GPU `scaleEffect` + `offset` 搭配翻頁同款漸進漸出曲線 (`pageAndZoomAnimation`) 驅動全畫面放大；當圖片處於放大狀態 (`isImageZoomed`) 時自動隱藏 icon，且單擊畫面僅切換 icon 顯示而不改變圖片倍率與座標，徹底消除畫面跳動與抖動。
  5. **相簿與相冊多選模式支援 Apple 原生拖選多選與底部左圓分享／右圓刪除操作列 (`LibraryView.swift`)**：於「全部」與「相冊詳情」進入選取模式時自動隱藏底部主 `TabView` 導覽列，並對齊 iOS 原生相簿 (`Photos.app`) 改為左下圓形毛玻璃「分享 (`square.and.arrow.up`)」、中央「已選取 N 張照片」、右下圓形毛玻璃「刪除 (`trash`)」操作列（右上角為「全選」與圓形「✕」完成按鈕）；同時加入 `ApplePhotosDragSelectOverlay`，支援手指橫向滑動跨格連續範圍拖選／取消勾選（啟動後可繼續跨多列上下滑動批次選取，純垂直滑動則維持 `ScrollView` 原生順暢捲動）。
  6. **從相簿追加後即時更新目前所在相簿，並於開啟「相簿同步」或變更成員時自動同步至 iOS 系統相簿 (`BatchPairingView.swift`, `LibraryView.swift`, `SettingsView.swift`, `PhotoLibraryManager.swift`, `ChekiDetailView.swift`, `ChekiInfoView.swift`)**：
     - 修復 `BatchPairingView` 初始化與 `appendPickerItems` / `collectAllPhotosInOrder` 會遺失 `defaultMember`（目前所在相簿）或漏掉工作台二次追加照片的問題，確保在某個成員相冊內追加匯入照片時自動套用該成員相冊。
     - 將 `AlbumHeroDetailView` 改為以 `@Query` 動態計算 `liveItems`，使從相簿追加照片或變更成員後立即更新目前所在的相簿畫面與張數。
     - 新增 `PhotoLibraryManager.syncItemsToSystemPhotoLibrary` 批次同步機制：當使用者先從相簿追加匯入照片、事後再打開「同步至 iOS 系統相簿 (`autoSyncToPhotosLibrary`)」，或於相冊／詳情頁變更所屬成員時，立即更新目前所在的相簿並同步寫入 iOS 原生相簿 (`ChekiLens › 團體 › 成員`)。
  7. **單張檢視背面體驗強化：移除測試手寫背面、空背面支援雙擊翻回正面、新增「從 App 內選取背面照片」(`ChekiDetailView.swift`)**：
     - 自「尚未綁定背面照片」引導卡與右上角「正反雙面管理」選單移除「產生測試手寫簽名背面」功能。
     - 為空背面引導卡綁定 `applyCardTapGestures`，使背面沒有照片時雙擊卡片同樣能平滑 3D 翻轉回正面。
     - 新增 [`InAppBacksidePickerSheet`](file:///Users/tcwang/Documents/ChekiLens/ChekiLens/Sources/Views/Detail/ChekiDetailView.swift#L2846-L3040) 與 [`attachBacksideFromInAppItem`](file:///Users/tcwang/Documents/ChekiLens/ChekiLens/Sources/Views/Detail/ChekiDetailView.swift#L1420-L1462)，支援在空背面卡片與右上選單直接從 App 內現有拍立得項目（可依全部／同相冊／僅單面篩選，並支援自動合併移除原獨立單張項目）選取作為背面。
  8. **成員相冊名稱格式統一為「人名 (團體)」與新增成員與團體欄位簡化 (`IdolMember.swift`, `LibraryView.swift`, `ChekiDetailView.swift`, `ChekiInfoView.swift`, `PhotoLibraryManager.swift`, `BatchPairingView.swift`, `CameraScannerView.swift`)**：於 `IdolMember` 新增 `albumTitle`（有團體時顯示 `"\(stageName) (\(groupName))"`，無團體時顯示 `stageName`），將「相冊 › 成員相冊」、團體內成員相冊、相冊詳情頁 Hero 標題、搜尋頁成員相冊、成員指派選單及系統相簿同步名稱統一改為「人名 (團體)」，並將 `QuickCreateIdolSheet`（「新增成員與團體」）輸入框提示精簡為 `姓名`、`團體`、`標籤`。
  9. **四角防反光改為「首張固定四邊 + 陀螺儀移動追蹤 + 四角分別手動按快門 + 極速非中斷合成」(`CameraScannerView.swift`, `VisionManager+AntiGlare.swift`, `VisionManager+PerspectiveCorrect.swift`)**：
     - **首張固定四邊 + 陀螺儀平滑位移 (`CMMotionManager`)**：拍下第 1 張照片瞬間立即呼叫 `lockQuadAndStartGyro()` 固定四邊位置並停止即時 `VNDetectRectanglesRequest` 矩形偵測 (`isQuadDetectionLocked = true`)，改由 `CMMotionManager` 60fps 姿態傾角 (`CMAttitude.multiply(byInverseOf:)`) 搭配阻尼加速度平移驅動四邊與 4 個角點圓圈平滑移動，徹底解決移動時四邊跳動問題。
     - **四角分別手動按快門（取消到點自動觸發）**：移除自動倒數觸發快門計時器 (`photoScanDwellTimer`)，改為由使用者移動至四個角點後分別手動按下快門（`1/4` → `2/4` → `3/4` → `4/4`）或直接點選角點圓圈拍攝；同時防護 `AVCapturePhotoOutput` 的 `photoContinuation` 重入與取消釋放。
     - **極速合成（`< 0.35s`）與跳出不中斷存檔**：消除 Debug `-Onone` 下 7.2 億次 `Array` 雙層迴圈 (`maxFilterFloatFast`) 與重型 CoreML Fallback 造成的數分鐘卡死，改以 $O(1)$ 滑動視窗 Box Filter 搭配 `1280px` 快速正位與共用 Metal `CIContext`，並將合成與相簿同步置於獨立非取消 `Task` 中執行，確保瞬間完成且跳出畫面也不會中斷。
* **最新穩定 Git Commit**：feat(Camera): 四角防反光改為首張固定四邊搭配陀螺儀移動並支援四角手動快門與極速合成
* **下一動執行指示**：執行 **Task 6.2**（支援深色/淺色模式與動態字級 Dynamic Type）

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
- [x] **Task 2.1**: 建立 `VisionManager.swift` 核心類別與影像方向/色彩空間預處理
- [x] **Task 2.2**: 實作第一層矩形辨識（`VNDetectRectanglesRequest` 自動錨點偵測）
- [x] **Task 2.3**: 實作第二/三層 Fallback 機制（邊緣偵測與白色相紙外框輪廓求解）
- [x] **Task 2.4**: 實作 `CIPerspectiveCorrection` 透視校正與比例鎖定（Mini: 86×54, Square: 86×72, Wide: 86×108）
- [x] **Task 2.5**: 實作邊界微調偏移（Inset / Outset -3% ~ +3% 矩陣微調）
- [x] **Task 2.6**: 實作底部手寫日期 OCR（`VNRecognizeTextRequest` 指定白邊區域掃描 + Regex 日期解析器）
- [x] **Task 2.7**: 撰寫影像演算法單元測試（72 張實體圖 Benchmark，100% 偵測成功，Xcode 17 項單元測試全數通過）


---

### 階段 2.5：專屬 AI 模型訓練與整合 (Phase 2.5: CoreML Keypoint Model)
*採用方案 B：使用手動標註資料訓練四角關鍵點模型，徹底解決極端環境誤判*
- [x] **Task 2.5.1**: 收集更多樣化的實體照片（如：手持、極端反光、黑色背景、複雜桌面）並放入 `TestData/images`，使用 WebUI 產生 `cheki_annotations.jsonl`
- [x] **Task 2.5.2**: 撰寫 Python 資料擴充腳本 (Data Augmentation)，將數十張原始圖片自動旋轉/扭曲/變色擴充為 1000+ 張訓練集
- [x] **Task 2.5.3**: 撰寫並執行 PyTorch 模型訓練腳本，將訓練完成的模型匯出為 iOS 專屬格式 (`ChekiCornerNet.mlpackage`)
- [x] **Task 2.5.4**: 將 CoreML 模型匯入 Xcode 專案，實作 `VisionManager+CoreML.swift`，直接輸出斜四角座標

---

### 階段 2.8：終極混合式高精度影像辨識引擎 (Phase 2.8: Hybrid Precision Pipeline v2)
*融合 Apple 原生直線精度 (15px 貼齊)、白邊幾何感知、內框外彈策略、背面水平膠帶錨點與 YOLO11-Pose 兜底*

#### 🏗️ 整體架構流程圖 (Overarching Architecture Pipeline)
```
輸入原始照片 (EXIF 物理轉正)
      │
      ▼
[Layer 0: 背面 OCR 快速掃描 (10ms)]
  ├─ 找到 instax / mouth 關鍵字 ──► 【進入背面分支】
  │                                      │
  │                                      ├─ 1. OCR 檢測文字上下方位 ──► 決定 180° 翻正方向
  │                                      ├─ 2. CIDetector / Hough 水平線 ──► 鎖定上下黑膠帶 Y 邊界
  │                                      └─ 3. YOLO11-Pose Bounding Box ──► 鎖定左右 X 邊界
  │                                      └─► 合成高精度背面四角透視校正
  │
  └─ 未找到背面文字 ──► 【進入正面/彩繪分支】
                            │
                            ▼
      [Layer 1: Apple 原生 VNDetectRectanglesRequest (5ms)]
                            │
                            ▼
              [驗證 A: 白邊比例與長寬比感知 (Ratio Sensing)]
                ├─ 【合格 (存在正常白邊)】
                │     │
                │     ▼
                │   [驗證 B: 四邊垂直平行角度檢查 (Orthogonality)]
                │     ├─ 四角夾角接近 90° (±5°) ──► 驗證通過
                │     └─ 某頂點偏斜 ──► [精密二次修正] 局部 ROI 視窗二次 Vision 修正
                │
                └─ 【不合格 (無白邊 / 比例異常)】
                      │
                      ├─ 情況 1: 面積比例過小且接近 4:3 ──► 【誤抓內部相片】
                      │     │
                      │     └─► [內框反推外框策略] 依 Mini/Square/Wide 物理幾何外彈
                      │           └─► 重新送回 [驗證 A] 檢查
                      │
                      └─ 情況 2: 滿版彩繪 / 極暗底漏抓 / 上白邊消失
                            │
                            └─► 【重新判斷: 全圖 YOLO11-Pose Fallback】
                                  └─► 輸出 4 個任意透視關鍵點兜底 (保證 0 嚴重翻車)
                            │
                            ▼
      [終端格式化: 規格感知與防拉伸變形 (Aspect Formatter)]
        ├─ 對角線與有效長寬比比對 ──► 自動判定 Instax Mini (直/橫) / Square / Wide (直/橫)
        ├─ 自動還原真實物理比例輸出 (如 Mini: 540x860 或 860x540)
        └─ 徹底消除橫向或 Wide 被強拉壓扁之問題
```

#### 📋 Phase 2.8 開發任務清單 (Development Checklist)
- [x] **Task 2.8.1**: 實作底片規格感知與防拉伸輸出模組 (`AspectRatioClassifier.swift`)
  * 以四邊形對角線長度比與面積比，精準分類 Instax Mini (直/橫)、Instax Square、Instax Wide (直/橫)
  * 動態指定 `CIPerspectiveCorrection` 的標準輸出解析度，防止橫向與 Wide 被強制拉伸變形（DSCF2190、IMG_1886 驗證通過）
- [x] **Task 2.8.2**: 實作白邊分佈感知與內框反推外框模組 (`FrameExtrapolator.swift`)
  * 分析長短邊比例是否符合內部照片特徵（長寬比接近 1.348）
  * 若檢測到誤抓內部深色畫面，依據富士工業規格（左右4mm、上5mm、下巴19mm）精確外彈還原外框，驗證錯誤率降低 70%~87%（DSCF3716、IMG_7280 驗證通過）
- [x] **Task 2.8.3**: 實作四邊垂直平行驗證與局部 ROI 二次精密修正 (`VisionManager+Refinement.swift`)
  * 計算四邊斜率向量與相鄰邊夾角，自適應偵測偏角大於 4° 的單點異常漂移
  * 針對偏移頂點（如 287136 右上角漂移 69px）利用其餘正交頂點形成的幾何向量精確修正，驗證誤差降低 60%（287136 驗證通過）
- [x] **Task 2.8.4**: 實作背面專用雙重錨點定型模組 (`BacksideDetector.swift`)
  * OCR 檢測頂部 "Don't put in mouth" 與底部 "instax/FUJIFILM" 關鍵字分類背面與 180° 方向判斷
  * 結合橫向跨距錨點與工業標準尺寸幾何定型，實測 6 大實體背面 100% 成功偵測（DSCF0024、0026、0032、0034、0042、IMG_6529 全數通過）
- [x] **Task 2.8.5**: 整合 YOLO11-Pose 作為全圖重判 Fallback 兜底機制 (`VisionManager+Fallback.swift`)
  * 將 YOLO11-Pose 匯出為 iOS 專屬 CoreML 模型 (`ChekiPoseNet.mlpackage`)，以物件語義全圖感知作為 Layer 1.8 兜底防線
  * 針對滿版彩繪（如 DSCF0025.JPG）、極端反光或 Native Vision 漏抓案例精準重判，並經 AspectRatioClassifier 幾何鎖定（DSCF0025 驗證通過）
- [x] **Task 2.8.6**: 驗證與基準回歸測試 (`run_hybrid_benchmark.swift` 全量評測)
  * 在 66 張極端驗證集（含 6 大暗底背面、滿版彩繪、橫向 Wide、傾斜透視）全面執行盲測
  * 達成 66/66 (100.0%) 偵測率、0 重大翻車 (Catastrophic Failures = 0)、背面 6/6 100% 成功命中
  * 輸出全量 4K 裁切成果至 `TestData/benchmark_output_hybrid/`

---

### 階段 2.9：混合辨識引擎精度重構與 11 大瑕疵清零 (Phase 2.9: Precision Engine v2.1 Refactor)
*專項分支：`feat/vision-precision-refinement`*
*目標：徹底修復用戶抽檢發現之 11 大邊界、回退、誤外彈與關鍵點丟失案例，並將該 11 個案例單獨輸出至獨立資料夾供人工驗收*
*防跑偏守門協議 (Anti-Drift Guard)：每一微任務完成後，必須無條件執行 `scripts/verify_no_regression.swift`，確保 49 張既有正常樣本通過率恆為 100.0%、6 張背面恆為 100.0%，任何非預期飄移即刻觸發回退防護。*

#### 📋 Phase 2.9 開發任務清單 (Development Checklist)
- [x] **Task 2.9.1 (方案 3)**: 實作 Layer 1 雙階段視窗過濾與防回退面積保護 (`VisionManager+Layer1Vision.swift`)
  * 第一階段啟用拍立得黃金比例窗（`0.45 ~ 0.95` 直向與 `1.05 ~ 1.85` 橫向），限制 `maximumObservations = 5`，徹底根除 `IMG_7882` 被 20 個碎雜訊塞滿名額問題
  * 引入面積下限保護（<35% 且長寬比異常時列為可疑），防止 `IMG_3491` 局域截半回退
  * 單元測試 4/4 100% 通過（`IMG_7882` 46.9% 面積 100% 捕獲、`IMG_3491` 由 29% 局域截半成功還原至 61.2% 全卡）
- [x] **Task 2.9.2 (方案 1)**: 實作內外雙輪廓幾何互鎖與外彈反差防護 (`FrameExtrapolator.swift`)
  * 外緣環狀色彩反差檢查（Outer Ring Contrast Gate）：外緣為黑色時嚴禁外彈，徹底根除 `287136` 外框被二次外彈包入黑底問題
  * 邊界溢出剛體投影：當底邊切出螢幕時，以完整之內部相片 4 角幾何推導外框，根治 `DSCF0984` 底邊無實體線問題
  * 修正橫豎下巴方位判定，解決 `DSCF0041 2` 與 `DSCF3696` 邊框分配錯誤
  * 防跑偏審計 100% 通過（49/49 既有樣本 0 飄移，6/6 背面 100% 保持）
- [x] **Task 2.9.3 (方案 2)**: 實作動態正交向量修正與 1D Sobel 梯度邊緣吸附 (`VisionManager+Refinement.swift`)
  * 降低歪斜觸發門檻至 2.0°，以長寬比適配度 (Format Error) 與對角直角偏差取代單純角度比值，徹底消滅 `IMG_1979` 的 TR/BR 互毀誤修 bug
  * 實作沿法向量之 1D Sobel 梯度邊緣吸附，自動鎖定黑白交界階躍線，校正 `287137`、`DSCF0008`、`IMG_7364` 浮起與偏斜頂點
  * 防跑偏審計 100% 通過（66/66 全量通過，49/49 基準樣本 0 飄移，6/6 背面 100% 保持，IMG_1979 異常徹底消除）
- [x] **Task 2.9.4 (方案 4)**: 實作 4 邊直線擬合相交求交點、多輪迭代收斂迴圈與 YOLO 全卡錨點比例修正 (`VisionManager+Refinement.swift`, `VisionManager+Fallback.swift`, `FrameExtrapolator.swift`)
  * 實作 1D Sobel 多點梯度直線擬合與相鄰直線幾何求交點（Line-Fitting Consensus Intersection），引入對邊平行約束保護，徹底消除 `287136` 頂邊斜角、`DSCF0008` 右側 167px 歪斜、`IMG_3491` 左側傾斜與 `IMG_7882` 右上角凹陷
  * 放寬直向 Mini 內框長寬比窗口至 1.20~1.385，精準救回 `DSCF0041 2` 內框誤抓並補全 4 邊完整相紙白框（面積由 7.5M 提升至 12.3M px）
  * 升級 YOLO CoreML 錨點評選演算法（面積與規格契合度加權評分），徹底解決 `IMG_6530` 滿版彩繪左側 500px 截半問題，輸出 6.15M px 標準 Mini 直式卡片
  * 防跑偏審計 100% 通過（66/66 全數命中，49/49 基準樣本 0 飄移，6/6 背面 100% 保持）
- [x] **Task 2.9.4.1 (專項微調)**: 專項邊界反差探測與自然透視保護 (`VisionManager.swift`, `VisionManager+Refinement.swift`, `VisionManager+Fallback.swift`)
  * `DSCF0041 2`: 於 `FrameExtrapolator` 外彈後串接 `refineQuadrilateral`，自動貼合實體外框邊緣，將右上角頂點向上拉昇 416px 消除歪斜
  * `IMG_3491`: 調整 `skewThresholdDegrees` 至 2.3°，將 2.03° 自然透視收斂識別為正常透視，杜絕破壞性平行四邊形重投射，完整保留左下角真實位置 (401.8px)
  * `IMG_6530`: 於 YOLO Fallback 中引入橫向實體邊界探測（Edge Contrast Snapping），自動探測右側與左側明暗階躍邊界，將右上角向左微調 124px，左邊界向左延伸 75px，完美重現滿版彩繪
  * 防跑偏審計 100% 通過（66/66 全數命中，49/49 基準樣本 0 飄移，6/6 背面 100% 保持）
- [x] **Task 2.9.4.2 (專項微調 II)**: 淺色桌面階躍差自適應、橫向大下巴限制與 Wide 自然透視保護 (`VisionManager+Refinement.swift`)
  * `IMG_1908`, `IMG_1921`, `IMG_2142`, `IMG_2279`, `IMG_3902` (淺色木紋桌): 實作越界安全 Luminance 取樣，杜絕 $Y < 0$ 偽造黑底階躍，並將 Sobel 梯度採樣升級為階躍差自適應 ($\Delta I \ge 25.0$)，徹底消除頂邊被誤吸附至 $Y = 0.0$ 的 230px 桌面留白問題
  * `DSCF2190`: 限制深搜僅在直向且比例異常時啟用 (`isPortrait && currentRatio < 1.50`)，橫向 Mini 嚴格使用 25px 邊緣微調，消除 187px 頂部歪斜，完美還原水平直角卡片
  * `IMG_1886`: 放寬橫向 Wide 規格自然透視門檻至 3.5° (`!isPortrait && ratio <= 1.35`)，杜絕破壞性平行四邊形重投射，右下角 (BR) 完整保留真實位置 (3671.3px)
  * `DSCF0984`: 左右兩側邊界擬合微調，右側白邊寬度還原為 174px，左側 196px，對稱平衡
  * 防跑偏審計 100% 通過（66/66 全數命中，49/49 基準樣本 0 飄移，6/6 背面 100% 保持）
- [x] **Task 2.9.5 (驗收)**: 專項瑕疵驗收、全量基準測試與新舊版本對照導出 (`scripts/run_hybrid_benchmark.swift`, `scripts/export_comparison.swift`)
  * 建立專屬輸出資料夾 `TestData/benchmark_output_problematic_cases/`，同步導出全量 65 張修復圖供人工驗收
  * 全量 66 張驗證集盲測，確認指標與視覺皆優於 `main` 分支（全量命中 100%，基準 49/49 零漂移，背面 6/6 保持）
  * 建立新舊版本雙向對照導出工具 (`scripts/export_comparison.swift`)，將當前 Commit 與 `ff7d866` 全量成對導出至 `TestData/benchmark_comparison/`（以 `_current.jpg` 與 `_ff7d866.jpg` 後綴區分）方便使用者逐圖比對
- [x] **Task 2.9.6 (滿版塗鴉跨邊專項優化)**: 實作外框 25 射線 RANSAC 直線擬合與背景盒文字誤判防護 (`VisionManager+Refinement.swift`, `VisionManager.swift`, `BacksideDetector.swift`, `scripts/benchmark_60_painted_and_pairs.swift`)
  * 切出專項分支 `feat/vision-painted-border-refinement`
  * 針對 `DSCF0029.JPG`（綠紅 `#` 格紋跨邊彩繪 + 貼紙遮擋內框）、`DSCF0073.JPG`（粗黑麥克筆跨邊）、`DSCF0012.JPG`（粉紅字跨邊）因跨邊筆觸切斷矩形輪廓導致 `VNDetectRectanglesRequest` 僅抓到局部碎片（`14.0%` / `4.1%` 面積）或嚴重梯形歪斜（`26.2°`）之問題，實作 `detectOuterPerimeterQuad`：由畫面四邊向內發射 25 道掃描射線，支援「深色背景階躍」與「陰影溝槽至白邊階躍」雙重邊緣步階檢測，並透過 RANSAC + OLS 直線擬合精準求解相紙四角交點（`DSCF0029.JPG` 由 `14.0%` 碎片還原至 `87.6%` 完整相紙、比例 `1.572`）
  * 於 `BacksideDetector.swift` 加入面積佔比（`>= 18%`）與拍立得長寬比守門，防止桌角背景之 `instax` 底片盒局部文字（如 `DSCF0050.JPG`、`DSCF0059.JPG`）誤觸發背面分支
  * 完成 `/Users/tcwang/Documents/ChekiLens/TestData/images` 60 張綜合基準測試（12 張滿版塗鴉正面 + 6 張拍立得反面 + 42 張拍立得正面 = 60/60 100.0% 通過）與既有 66 張防跑偏回歸測試（66/66 100.0% 零回退）

---

### 階段 3：iOS 系統相簿與權限管理 (Phase 3: Photos Framework Sync)
- [x] **Task 3.1**: 封裝 `PhotoLibraryManager.swift`（PHPhotoLibrary 授權狀態處理）
- [x] **Task 3.2**: 實作自動建立相簿階層結構（`ChekiLens` › `團體` › `成員` 資料夾）
- [x] **Task 3.3**: 實作同秒寫入機制（正面與背面照片賦予同秒 `creationDate` 緊鄰存入相簿）
- [x] **Task 3.4**: 實作 OCR 日期回寫相簿時間軸（使用手寫日期取代翻拍當日時間）

---

### 階段 4：UI 介面開發 (Phase 4: SwiftUI Views - iOS 18 HIG)
*參考來源：`docs/ui/` 僅作功能架構參考，實作嚴格遵循 Apple HIG 原生 SwiftUI 與 Apple 相簿設計規範*
- [x] **Task 4.1**: 實作「01. 歡迎導引輪播 (`OnboardingView.swift`)」（Apple 標準功能展示、3D 翻轉與 86×54 正位互動展示、相簿與相機權限引導）
- [x] **Task 4.2**: 實作「02. 典藏與相冊首頁 (`LibraryView.swift` / `ContentView.swift`)」
  * 底部導覽列比照 Apple 原生相簿：左側膠囊切換「全部 / 相冊」，右側獨立圓形「搜尋 (`Tab(role: .search)`)」按鈕，「設定」收納至右上角 `⋯` 選單
  * 「相冊」採用 Apple 相簿 1:1 圓角滿版封面磚（左下角白字疊加標題），頂部保留「團體 | 成員」分段控制（移除下方個人數字膠囊列）
  * 基本相簿構造為 `團體 > 成員`，切換頂部「成員」可無視團體階層直接展開全部成員；點開相冊後呈現全幅 Hero 封面 + 緊密縮圖網格
  * 擴充 `PreviewData` 測試資料集（3 個團體、6 位成員、13 張含正反雙面與未分類之拍立得、備忘錄與 `#標籤`）
- [x] **Task 4.3**: 實作「03. 即時相機掃描 (`CameraScannerView.swift`)」（採用 Apple 原生相機介面規範）
  * AVFoundation 相機預覽流（含模擬器擬真取景器 Fallback）
  * 3×3 九宮格 ＋ 綠色拍立得虛線追蹤框 ＋ 點擊對焦黃框 ＋ `.5 / 1× / 2` 倍率切換圈
  * 頂部曝光指示（`-0.3`）與閃燈控制、底部黃字模式轉盤（防反光 / 拍照 / 正反雙面）與雙環白色快門鈕
- [x] **Task 4.4**: 實作「04. ペアリング 批次配對工作台 (`BatchPairingView.swift`)」（嚴格遵循 Apple iOS 18 原生 HIG 規範）
  * `PhotosPicker` 多選匯入（`maxSelectionCount: nil` 不設張數上限）與工作台內追加照片
  * 原生 Segmented Control 三段模式切換（`直接執行` / `自動配對` / `手動配對`）與成員、相紙規格選單
  * Apple Vision 雙正面防呆警示、正反順序顛倒提示、一鍵自動修正、左滑（`swipeActions`）解除配對與對調手勢
  * 內建 8 張工作台測試照片組（含雙正面與正反顛倒警示案例），並將 `PreviewData` 擴充至 4 個團體、9 位成員、20 張拍立得
- [x] **Task 4.5**: 實作「05. 写真詳細 單張全螢幕檢視 (`ChekiDetailView.swift`)」（嚴格遵循 Apple iOS 18 原生相簿單張檢視規範）
  * 頂部半透明毛玻璃日期時間藥丸（`9月17日 · 16:26 · 成員名稱`）＋ 左上圓形返回鈕 ＋ 右上 `⋯` 選單
  * 底部縮圖膠卷 (Filmstrip Scrubber) 橫向滾動切換、左右滑動翻頁、點擊全螢幕沉浸模式
  * Apple Photos 標準 5 大工具列按鈕（分享、愛心 `#最愛`、ℹ️ 資訊面板、邊界與比例調整、垃圾桶刪除）
  * 3D Y 軸 180° 翻轉動畫（雙擊或點選右上角翻轉膠囊查看背面手寫簽名；單面拍立得支援直接補上背面或一鍵生成測試手寫背面）
  * 擴充 `PreviewData` 拍立得正反面渲染器（加入擬真背面手寫感謝留言、`FUJIFILM instax` 標記與正面下巴手寫日期簽名）
- [x] **Task 4.6**: 實作「06. 情報・備忘 上滑資訊面板 (`ChekiInfoView.swift`)」
  * 移除卡片上方重複縮圖與右上角「完成」按鈕，所有欄位（日期、時間、規格、成員、備忘）點擊後可直接於面板內修正並即時寫入 SwiftData
  * 拍攝日期統一使用 `yyyy年M月d日 EEEE`（`yyyy年y月m日 {星期}`）格式呈現，支援展開內嵌月曆與時間滾輪直接調整
  * 升級 `VisionManager+OCR.swift`（全圖 + 上/下 ROI + 高反差雙語辨識 + 手寫數字與符號容錯），於匯入/拍攝及檢視時自動辨識拍立得封面手寫日期並填入拍攝日期
  * 相紙規格自動辨識後歸入三種具體規格之一（`Instax Mini` / `Instax Square` / `Instax Wide`，預設 `Instax Mini`），支援點擊直接切換
  * 備忘輸入預設保持空白（不自動塞入系統匯入文字）
  * 匯入 10 張真實手寫日期拍立得（`DSCF0073.JPG`, `DSCF0010.JPG`, `193422_DSCF1405.JPG` 等）至 iOS 原生系統相簿供匯入日期辨識測試
  * 裁切照片全面改為**原地修改原圖（In-place Edit，絕不新增重複照片）**，透過 `originalFrontImageData` / `originalBackImageData` 與 Apple Photos `PHContentEditingInput` + `PHContentEditingOutput` 完整保留原始未裁切底圖，並提供「復原為原始圖片（取消裁切）」一鍵還原功能
- [x] **Task 4.7**: 實作「07. 設定與 Pro 買斷 (`SettingsView.swift`)」
  * **Apple 原生系統設定風格（iOS 26+ HIG，5 大圓角卡片群組）**：比照 iOS「設定」App 之經典 Inset Grouped 規格，包含圓角卡片區塊、左側彩色背景 SF Symbol 圖示與右側原生控制項（開關、滑桿、選單）
  * **Pro 終身買斷卡片（頂部購買入口）**：漸層深藍紫尊爵橫幅（NT$120 / ¥600 終身買斷、4K 無限制、Mode B 雙角度去反光、去浮水印等權益說明與解鎖按鈕，為 Phase 5 商業化預留進入點與購買狀態回饋）
  * **第 1 組：相簿雙向同步與時間軸策略 (Photos Sync & Timeline)**：
    * 相簿雙向同步總開關（`autoSyncToPhotos`）
    * 正反面時間軸排序策略（「正面與背面相同時間（同一秒）」緊密相鄰 vs 「背面自動延後 1 秒」確保正面永遠在左側）
    * 同步刪除偏好（在 App 內刪除拍立得時，是否詢問一併自 iOS 原生照片圖庫中刪除）
    * 手寫日期覆寫 EXIF 拍攝時間開關（`overwriteExifDateWithOCR`）
  * **第 2 組：匯入與 OCR 手寫日期辨識偏好 (Import & Recognition)**：
    * 匯入時自動辨識日期開關（Toggle：開啟時批次匯入/拍照後背景自動執行 OCR 填入，關閉時節省電力與處理資源）
    * 手寫日期預設年份補全規則（若拍立得僅寫 `9/17` 或 `'24.9.17`，當年份缺失時預設以「相片匯入當年度」或拍攝年度補全）
  * **第 3 組：照片儲存格式偏好 (Storage & Export Format)**：
    * 儲存模式：保留原圖格式（固定原圖不轉換） vs 新建副檔（可自由選擇指定格式）
    * 支援格式切換：`原圖格式 (不轉換)` vs `HEIC (節省空間)` vs `JPEG (最佳相容性)` vs `無失真 PNG (典藏專用)`
  * **第 4 組：相機與影像處理偏好 (Scan & Image Processing)**：
    * 預設相紙規格（`Auto 智慧偵測` / `Instax Mini` / `Instax Square` / `Instax Wide`）
    * 自動邊界微調 (Inset / Outset) 滑桿與快速預設（`-2% 去陰影` / `0% 標準外框` / `+2% 完整留白`）
    * 反光對策模式（`Mode A 單張智慧抑制` / `Mode B 雙角度合成 (Pro 專屬)`）
  * **第 5 組：一般與關於 (General & About)**：
    * 外觀模式（跟隨系統 / 深色 / 淺色）
    * 重新顯示新手導引教學按鈕
    * 版本資訊與「恢復購買項目 (Restore Purchases)」按鈕

---

### 階段 5：商業化與進階功能 (Phase 5: StoreKit 2 & Polish)
- [x] **Task 5.1**: 封裝 `StoreKitManager.swift`（Non-Consumable NT$120 / ¥600 終身買斷商品、JWS 本機簽章驗證、`Transaction.currentEntitlements` 與 `Transaction.updates` 交易監聽、`AppStore.sync()` 恢復購買）
- [x] **Task 5.2**: 實作每日 1 張 4K 高畫質免費額度計數器（`UserDefaults` 儲存、跨日自動重置、`0/1 → 1/1` 已使用進度顯示、於系統分享面板實際點擊 `Save Images` / 完成分享時才消耗額度，且額度用完後自動將匯出圖片降為長邊 960px + JPEG 0.72 之 SNS 夠用畫質並加上右下角浮水印）
- [x] **Task 5.3**: 實作免費版與 Pro 版分級機制（免費版：原生相簿不裁切但可同步相簿分類與時間軸、只能在 App 內加上 `ChekiWatermarkOverlayView` 浮水印查看裁切後照片、分享或輸出時透過 `ChekiWatermarkRenderer` 加上浮水印；Pro 版：原生相簿非破壞性原地裁切、原畫質無損輸出、完全移除浮水印）
- [x] **Task 5.4**: 實作 Mode B 雙角度去反光合成管線（Pro 專屬功能：`VisionManager+AntiGlare.swift` 實作 Mode A 單張高光抑制與 Mode B 雙角度各自透視校正、`VNTranslationalImageRegistrationRequest` 亞像素平移對位、內部相片鏡面反光差異權重遮罩、高斯盒式羽化平滑與白邊/手寫簽名保護融合；整合至 `CameraScannerView` 兩段式防反光連拍與 `ChekiDetailView` 右上選單匯入第二角度照片去反光合成）

---

### 階段 6：端到端整合與發布準備 (Phase 6: QA & Release)
- [x] **Task 6.1**: 實機測試與效能調校（實機部署至 iPhone 12 mini `ジェ`；補齊 `CameraScannerView` 所有拍攝模式自動同步寫入 iOS 原生相簿 `Photos.app`；將 Mode B 雙角度去反光升級為「第 1 張拍完立即背景預處理 + 1440px 快速正面四角偵測 + 540px 配準代理 + 270×430 O(1) 滑動視窗權重遮罩 + Core Image GPU `CIBlendWithMask` 單次 4K 渲染 + 取景器追蹤每 6 幀節流」，消除 4K CPU 迴圈瓶頸）
- [ ] **Task 6.2**: 支援深色/淺色模式與動態字級 (Dynamic Type)
- [ ] **Task 6.3**: 建立 App 圖示、啟動畫面與 App Store 截圖產生流程
