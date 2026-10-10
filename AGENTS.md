# ChekiLens AI 開發代理人工作規範 (AI Developer Guidelines)

> 本文件為所有 AI 代理人（Antigravity、Cursor、Claude Code 等）在開發本專案時必須嚴格遵守的最高指導方針。

---

## 🛑 核心開發守則：斷點續傳與原子切片

為了在每日有限的 AI 額度內持續穩健推進專案，**所有 AI 代理人在被喚醒時，必須無條件遵循以下流程**：

### 1. 喚醒啟動檢查（Start-of-Turn Routine）
任何任務開始前，**先執行且必須執行**以下動作：
1. 讀取 `docs/PROGRESS.md`，獲取當前所屬階段與最新斷點狀態。
2. 執行 `git status` 與 `git log -n 3`，比對本機程式碼是否與進度文件一致。
3. 明確告知使用者：「*目前進度為 Task X.X，本次將執行 Task Y.Y*」，然後才開始動作。

### 2. 嚴禁龐大生成，堅持原子循環（Atomic Task Execution）
* **一問一事**：一次 Prompt 僅允許實作 **1 個原子任務**（例如僅實作 `ChekiItem.swift` 模型，或僅實作 Vision 偵測核心）。
* **嚴禁批量寫爛代碼**：嚴禁在單次回應中一口氣創建 5~10 個未經編譯驗證的檔案。
* 任務規模控制在 15~30 分鐘的開發切片，保證在額度消耗前能安全著陸。

### 3. 完成後的收尾協議（End-of-Task Routine）
當一個微任務的代碼撰寫完畢，**必須依序執行以下 3 項動作**：
1. **驗證**：若為代碼，執行單元測試或語法檢查，確保代碼無編譯錯誤。
2. **更新看板**：修改 `docs/PROGRESS.md`，將已完成的任務標記為 `[x]`，並更新「最新狀態摘要」與「下一動執行指示」。
3. **Git 提交**：執行 `git add` 與 `git commit`，格式規範如下：
   ```bash
   git commit -m "feat(模組): 完成 Task X.X 任務內容說明"
   ```

### 4. 遇到額度中斷時的處理（Quota Safety Landing）
* 若偵測到 Token 耗盡或 API 429 錯誤：
  1. 優先保留當前檔案修改，確保無語法截斷的死代碼。
  2. 若檔案殘缺不全，執行 `git checkout .` 回退到上一個穩定 commit，避免污染工作區。

---

## 🛠️ 技術架構規範 (Tech Stack & Architecture)

* **目標平台**：iOS 17.0+ / iOS 18+ 原生支援（iPhone）
* **介面框架**：SwiftUI（100% 遵照 Apple Human Interface Guidelines）
  * 必須參考 `docs/ui/` 中的 7 個已定案 iOS 18 原生介面（含浮動導覽膠囊、九宮格相機、日期時間藥丸、毛玻璃資訊面板）。
* **資料持久化**：SwiftData（`@Model` 實體，零第三方依賴）
* **影像處理**：
  * Apple Vision Framework (`VNDetectRectanglesRequest`, `VNRecognizeTextRequest`)
  * Core Image (`CIPerspectiveCorrection`, Lanczos 重採樣)
  * 原 Python 演算法對照：參閱 `py-gif/src/image_process/cheki_crop.py`
* **相簿同步**：Photos Framework (`PHPhotoLibrary`, `PHAssetCreationRequest`)
  * 正反面雙圖同一秒 `creationDate` 存入相簿。
  * 手寫日期 OCR 覆寫 EXIF 時間軸。
* **商業化**：StoreKit 2（`Product.purchase()` Non-Consumable 買斷制，NT$120 / ¥600）
* **並行性與安全**：Swift 6 Concurrency (`async/await`, `@MainActor`, `Sendable`)，絕不阻塞主執行緒。

---

## Cloud Agent（Linux）環境

Cloud Agent 使用 Ubuntu 24.04。這台機器沒有 Xcode，無法執行 `xcodebuild`、iOS 模擬器或 XCTest。SwiftUI、SwiftData、Vision、Core Image、UIKit 只能在 macOS 上連結。iOS 建置與測試仍使用：

```bash
xcodebuild -scheme ChekiLens test
```

Linux 上已準備的工具：

* Swift 6.3.3：`swift` 與 `swiftc` 在 `/usr/local/bin`（工具鏈本體在 `/opt/swift`）。
* Python 在 `/opt/chekilens/venv`。`python3` 與 `pip` 指向這個 venv，內含 `scripts/requirements.txt`（torch、torchvision、coremltools、ultralytics 等），以及裁切腳本需要但 requirements 未列出的 `opencv-python-headless` 與 `pillow`。

可在 Linux 上做的檢查：

* 語法：逐檔執行 `swiftc -parse <file.swift>`。不要把多個 `main.swift` 一起丟給同一次 `swiftc`。
* 透視裁切：在 `TestData/images` 與 `TestData/cheki_annotations.jsonl` 備妥圖片與四角標註後，執行 `python3 BenchmarkTool/crop_annotated.py`。直向 Mini 會輸出 810×1290。
* 訓練集擴充：同一份標註可執行 `python3 scripts/data_augmentation.py`，產物在 `TestData/ml_dataset/`（gitignored）。
