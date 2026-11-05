# ChekiLens 社群模型優化：端側去識別化上傳、全自動訓練與 OTA 熱更新架構藍圖 (Phase 8)

> **設計目標**：在不收集任何個人肖像、手寫簽名或 EXIF 定位隱私的前提下，透過用戶手動微調四角座標回饋，全自動完成模型增量訓練、黃金測試集防退步檢驗與 iOS 端免審核 OTA 熱更新。
> **商業與授權策略**：開啟共享可享半價買斷 `com.chekilens.pro.contributor`（`NT$60 / ¥300`）；一旦以半價方案完成購買，系統將永久鎖定共享開關為開啟狀態（支援跨裝置「回復購買」自動同步鎖定）。

---

## 🏗️ 端到端完整流程圖 (End-to-End Architecture Flowchart)

```mermaid
flowchart TD
    subgraph Client["📱 階段 1：iOS 裝置端（端側隱私去識別化與佇列回傳）"]
        UserAdjust["用戶於 ChekiDetailView / BatchPairingView 微調四角並儲存"] --> CheckOptIn{"是否開啟社群模型共享？"}
        CheckOptIn -->|"未開啟"| SkipTelemetry["僅儲存本機裁切，不建立回傳任務"]
        CheckOptIn -->|"已開啟（或半價 Pro 永久鎖定）"| GeoCheck{"QuadCornerGeometry 端側幾何檢驗"}
        GeoCheck -->|"非凸四邊形 / 面積佔比異常 / 越界"| RejectLocal["丟棄異常座標，不進入佇列"]
        GeoCheck -->|"通過順時針凸包檢驗"| PrivacyMask["ChekiPrivacyMaskService 端側去識別化"]
        PrivacyMask --> StepResize["1. 長邊等比例降採樣至 640px"]
        StepResize --> StepCenterMask["2. 遮蔽四邊形中央 76% 肖像與簽名區（僅留外圍 12% 相紙白邊與桌面背景）"]
        StepCenterMask --> StepFaceMask["3. VNDetectFaceRectanglesRequest 偵測背景殘留人臉並塗黑"]
        StepFaceMask --> StepStripEXIF["4. 重新編碼純淨 JPEG（抹除 GPS / TIFF / 拍攝時間與設備 EXIF）"]
        StepStripEXIF --> Enqueue["ChekiAlignmentTelemetryService 寫入本機 Application Support 佇列"]
        Enqueue --> UploadWorker["背景連線時批次上傳 payload.json + image.jpg，成功後移除本機佇列"]
    end

    subgraph CloudMLOps["☁️ 階段 2：GitHub Actions 自動化訓練與守門管線（Mode C / macos-14）"]
        UploadWorker --> Ingest["scripts/ingest_community_annotations.py 批次匯入"]
        Ingest --> ServerGate{"後端二次幾何與離群值檢驗 + sampleId 冪等去重"}
        ServerGate -->|"不合格或已存在"| DropSample["移入 rejected / 略過重複樣本"]
        ServerGate -->|"合格新樣本"| MergeJSONL["合併寫入 TestData/cheki_annotations.jsonl 與 TestData/images"]
        MergeJSONL --> CheckThreshold{"累積新增合格樣本 >= 門檻？"}
        CheckThreshold -->|"未達門檻"| WaitNextRun["保留樣本，等待下週排程"]
        CheckThreshold -->|"達標"| Augment["執行 scripts/data_augmentation.py 產生訓練與驗證集"]
        Augment --> TrainPose["執行 scripts/train_yolo_pose.py 微調 YOLO11n-Pose 並匯出 ChekiPoseNet.mlpackage"]
        TrainPose --> CompileCoreML["執行 xcrun coremlcompiler compile 預先編譯為 ChekiPoseNet.mlmodelc"]
        CompileCoreML --> GoldenGate{"黃金測試集守門（evaluate_golden_gate）"}
        GoldenGate -->|"平均角點誤差退步 或 <95% 樣本達標"| AbortRelease["中止發布並保留上一版模型"]
        GoldenGate -->|"精準度優於現有基準"| BuildManifest["壓縮 ChekiPoseNet.mlmodelc.zip 並計算 SHA256 產出 ota_manifest.json"]
        BuildManifest --> PublishRelease["自動發布至 GitHub Release（tag: model-latest）"]
    end

    subgraph OTADelivery["🔄 階段 3：iOS 端免更新 App 之 OTA 模型熱更新與推理"]
        PublishRelease --> AppCheckManifest["App 啟動或背景喚醒時讀取遠端 ota_manifest.json"]
        AppCheckManifest --> CompareVer{"遠端 version 是否與本機已安裝版本不同？"}
        CompareVer -->|"版本相同"| KeepCurrent["略過下載，直接使用現有模型"]
        CompareVer -->|"發現新版本"| DownloadZip["背景下載 ChekiPoseNet.mlmodelc.zip"]
        DownloadZip --> VerifySHA{"CryptoKit SHA256 雜湊比對是否一致？"}
        VerifySHA -->|"雜湊不符（損毀或遭竄改）"| DiscardZip["拋出 sha256Mismatch 並保留舊版模型"]
        VerifySHA -->|"雜湊驗證通過"| AtomicInstall["ChekiOTAModelStore 原子替換 Application Support/ChekiModels/ChekiPoseNet.mlmodelc"]
        AtomicInstall --> VisionLoad["VisionManager.resolvePoseModelURL 優先載入熱更新模型（失敗自動退回 Bundle 內建模型）"]
    end
```

---

## 🔐 購買半價 Pro 與共享開關鎖定狀態機 (Contribution & Paywall Sequence)

```mermaid
sequenceDiagram
    participant User as 用戶 (SettingsView / Paywall)
    participant Policy as CommunityContributionStore
    participant StoreKit as StoreKitManager (StoreKit 2)
    participant Privacy as ChekiPrivacyMaskService
    participant Telemetry as ChekiAlignmentTelemetryService

    User->>Policy: 檢視「端側去識別化即時預覽 Sheet」並開啟共享開關
    Policy-->>User: isSharingEnabled = true（解鎖 NT$60 / ¥300 半價購買資格）
    User->>StoreKit: 選購 com.chekilens.pro.contributor（社群貢獻半價版）
    StoreKit->>Policy: 驗證 JWS 交易簽章成功，呼叫 lockForContributorPurchase()
    Policy-->>User: isLockedByContributorPurchase = true（共享開關永久鎖定為開啟）
    Note over User,Policy: 跨裝置執行「回復購買」時，StoreKit 掃描 currentEntitlements 亦會自動恢復永久鎖定狀態

    User->>Privacy: 手動微調拍立得四角並點擊儲存
    Privacy->>Privacy: 640px 降採樣 + 遮蔽中央 76% 畫面 + Vision 人臉塗黑 + 抹除 EXIF
    Privacy->>Telemetry: 封裝正規化四角座標與去識別化邊框圖寫入離線佇列
```

---

## 🗂️ 對應程式碼與腳本索引 (Codebase Mapping)

| 階段 | 模組職責 | 檔案路徑 |
| :--- | :--- | :--- |
| **階段 1：端側隱私與佇列** | 四角凸包幾何檢驗、640px 降採樣、中央 76% 遮蔽、Vision 人臉遮罩、EXIF 抹除 | [`ChekiPrivacyMaskService.swift`](file:///Users/tcwang/Documents/ChekiLens/ChekiLens/Sources/Services/ChekiPrivacyMaskService.swift) |
| **階段 1：端側隱私與佇列** | 離線持久化上傳佇列、Manifest SHA256 驗證與 OTA `.mlmodelc` 儲存管理 | [`ChekiAlignmentTelemetryService.swift`](file:///Users/tcwang/Documents/ChekiLens/ChekiLens/Sources/Services/ChekiAlignmentTelemetryService.swift) |
| **階段 1：半價 Pro 鎖定** | 共享開關狀態機、半價 Pro 購買資格檢查與永久鎖定規則 | [`CommunityContributionPolicy.swift`](file:///Users/tcwang/Documents/ChekiLens/ChekiLens/Sources/Services/CommunityContributionPolicy.swift) |
| **階段 1：StoreKit 2** | 標準價 (`com.chekilens.pro.lifetime`) 與半價貢獻版 (`com.chekilens.pro.contributor`) 雙 SKU 管理 | [`StoreKitManager.swift`](file:///Users/tcwang/Documents/ChekiLens/ChekiLens/Sources/Services/StoreKitManager.swift) |
| **階段 1：UI 整合** | 設定頁開關、去識別化即時預覽 Sheet、單張與批次裁切儲存掛載 | [`SettingsView.swift`](file:///Users/tcwang/Documents/ChekiLens/ChekiLens/Sources/Views/Settings/SettingsView.swift)、[`ChekiDetailView.swift`](file:///Users/tcwang/Documents/ChekiLens/ChekiLens/Sources/Views/Detail/ChekiDetailView.swift)、[`BatchPairingView.swift`](file:///Users/tcwang/Documents/ChekiLens/ChekiLens/Sources/Views/Pairing/BatchPairingView.swift) |
| **階段 2：自動化訓練管線** | 後端樣本清洗、冪等合併、訓練觸發、黃金測試集守門與 OTA 清單打包 | [`ingest_community_annotations.py`](file:///Users/tcwang/Documents/ChekiLens/scripts/ingest_community_annotations.py) |
| **階段 2：CI/CD 排程** | 每週於 `macos-14` 自動重訓、編譯 `.mlmodelc` 並發布至 GitHub Release | [`community_model_retrain.yml`](file:///Users/tcwang/Documents/ChekiLens/.github/workflows/community_model_retrain.yml) |
| **階段 3：推理引擎熱載入** | 優先載入 `Application Support/ChekiModels/ChekiPoseNet.mlmodelc`，失敗時自動退回 Bundle 模型 | [`VisionManager+Fallback.swift`](file:///Users/tcwang/Documents/ChekiLens/ChekiLens/Sources/Services/VisionManager+Fallback.swift) |
