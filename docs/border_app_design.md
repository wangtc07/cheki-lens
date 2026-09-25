# FrameCraft (相機美學白邊與專業 EXIF 浮水印 App) - 設計定義文件

> **版本**：v0.1 (Draft)  
> **狀態**：設計探索階段 (Grilling in progress)  
> **核心代碼來源**：`src/watermark/wbg.py`, `src/image_process/combine_photos.py`, `src/image_process/remove_white_borders.py`  
> **平台**：iOS 原生 (100% On-Device, Swift / SwiftUI)

---

## 1. 專案願景與定位

* **定位**：專為單眼/無反相機玩家打造的極簡美學相框與 EXIF 浮水印批次排版工具。
* **核心標語**：讓每一張相機作品，都自帶藝廊裝裱感與專屬拍攝參數。
* **商業模式**：小額買斷制 (預估 NT$ 90 ~ 150 / US$ 2.99 ~ 4.99)，終身無訂閱負擔。

---

## 2. 目標用戶群與核心痛點

1. **Sony / Fuji / Canon / Nikon / Leica 相機玩家**：
   * 痛點：相機拍完傳到手機發 IG / Threads，需要排版白邊加相機參數，但競品（如 Liit、Polarr）全改成高額訂閱制。
2. **老鏡 / 手動鏡 / 轉接環愛好者 (Vintage Lens Shooters)**：
   * 痛點：現有相框軟體讀取不到電子接點鏡頭資訊，光圈常顯示 `f/--` 或空白；沒有自訂鏡頭預設庫。
3. **高效率批次出圖者**：
   * 痛點：主流修圖 App 偏重單張精修，要一次處理 20 張相片加白邊常需手動一張張點，極度耗時。

---

## 3. 功能規格（源自 `wbg.py` 等腳本之原生轉化）

### 3.1 核心排版與邊框引擎 (Border & Layout Engine)
* **畫布與邊框控制**：
  * 支援 Auto（依原圖比例）、Square (1:1)、4:3、16:9、3:2 等畫布比例。
  * 精確白邊比例控制（支援等寬白邊、等比白邊）。
  * 支援暗黑模式（黑邊框）與自訂純色邊框（如典雅灰、奶白、膠片黑）。
* **無損色彩與畫質保真**：
  * 支援 Display P3 與 sRGB 色彩空間精準轉換。
  * 支援 ProRAW、DNG、高解析度 JPEG/HEIF 原生渲染，保留完整原始相機 Metadata。

### 3.2 專業 EXIF 解析與「手動鏡頭記憶庫」
* **智慧 EXIF 提取**：
  * 利用原生 `ImageIO` 讀取相機廠牌、機身型號、鏡頭型號、焦距、光圈、快門速度、ISO 等。
* **自訂鏡頭庫 (Custom Lens Profiles)**：
  * 解決老鏡痛點：使用者可建立常用手動鏡清單（如 HELIOS 44M-5 58mm f/2、7Artisans 7.5mm f/2.8、Voigtländer 等）。
  * 當偵測到 EXIF 缺失鏡頭資訊時，一鍵批次指定鏡頭設定，並可手動微調光圈文字。
* **字型與排版排版**：
  * 預設精選襯線體與等寬字體（如 SF Mono Italic、Didot、Georgia、New York）。
  * 底部置中、右下角簡約排列、雙行藝廊標籤風格。

### 3.3 附加生產力工具 (Productivity Extensions)
* **多圖自動拼圖 (`combine_photos.py`)**：一鍵將 2~4 張照片以等距白邊拼貼為一張大圖。
* **反向白邊消除 (`remove_white_borders.py`)**：自動還原已加白邊的圖片，智慧避開底部文字浮水印。
* **iOS 系統分享整合 (Share Sheet Extension)**：
  * 在 iOS 原生「照片 App」選取多張照片，點擊「分享 -> FrameCraft」，直接快速套用預設排版並儲存。

---

## 4. 系統架構與技術棧

* **UI**：SwiftUI + PhotosPicker
* **元數據讀取**：ImageIO (`CGImageSourceCopyPropertiesAtIndex`)
* **排版繪圖**：Core Graphics (`CGContext`) / SwiftUI Canvas
* **擴充套件**：Action Extension (Share Sheet)
* **本機儲存**：SwiftData / UserDefaults（儲存自訂鏡頭庫與排版預設值）

---

## 5. 待決策分支 (Design Tree)

- [ ] 是否需要相機品牌 Logo 向量圖標（如 Leica 可樂標、Sony、Fujifilm 標誌）或僅維持文字排版？
- [ ] 批次處理時，不同橫豎比例的照片是否允許混合處理？
- [ ] 模板風格庫要提供幾種預設樣式？
