# ChekiLens (拍立得智慧掃描與推活典藏 App) - UI/UX 規格與操作流程指南

> **版本**：v1.0  
> **設計規範基準**：Apple Human Interface Guidelines (iOS 17/18 Native HIG)  
> **視覺哲學**：極簡現代主義、乾淨冷調、去擬真化（Skeuomorphism-free）、聚焦於拍立得卡片本身

---

## 1. 視覺設計系統 (Visual Design System)

### 1.1 色彩調性 (Color Palette)
* **背景色 (Surfaces)**：
  * Light Mode: `Color(uiColor: .systemGroupedBackground)` (純淨淺灰 #F2F2F7) / `systemBackground` (純白 #FFFFFF)
  * Dark Mode: `Color(uiColor: .systemBackground)` (沉浸純黑 #000000) / `secondarySystemBackground` (#1C1C1E)
* **主題點綴色 (Accent Color)**：
  * **Cheki Indigo** (`#4F46E5` / 深邃藍紫) 或 **Fujifilm Green / Sunset Orange** 微光點綴，僅用於按鈕、進度條與選取狀態。
* **卡片實體投影 (Native Shadow)**：
  * 不使用誇張的紙張陰影，使用細膩的原生光影：`color: .black.opacity(0.12), radius: 8, x: 0, y: 4`，烘托相紙立體感。

### 1.2 排版與字體 (Typography)
* **大標題/導覽列**：SF Pro Display, Bold
* **相片手寫辨識日期**：SF Mono, Regular (呈現數位校正的嚴謹與機械美感)
* **備忘錄內文**：SF Pro Text, Regular
* **Hashtag (# 標記)**：SF Pro Text, Semibold (`.secondary` 柔和灰色)

---

## 2. 核心架構與頁面導覽 (Information Architecture)

```
Root View (TabView or NavigationSplitView)
├── 📚 典藏首頁 (Collection Gallery)
│    ├── 頂部：團體切換分段選擇器 (Group Picker: 全部 / 乃木坂 / 私立惠比壽 / ...)
│    ├── 次級：成員水平頭像膠囊列 (Member Scroll: 全部 / 〇〇 / △△ ...)
│    └── 主體：雙欄/三欄拍立得網格 (Cheki Grid)
│         ├── 點選 ➔ 單張全螢幕檢視 (Detail View)
│         │    ├── 點擊/雙擊 ➔ 3D 翻轉查看背面 (Flip to Back)
│         │    └── 向上滑動 ➔ 呼出原生 Info Sheet (備忘錄 & #標籤)
├── ➕ 翻拍/匯入入口 (Floating Action Button or Top Right Bar)
│    ├── 開啟相機 (Live Camera - 邊框辨識與反光警示)
│    └── 選擇相簿 (PhotosPicker - 支援 1~50 張批次)
│         └── ➔ 配對確認工作台 (Pairing Workbench)
└── ⚙️ 設定 (Settings - 買斷狀態、相簿同步開關、相紙預設偏移)
```

---

## 3. 初次使用新手引導 (Onboarding & First-Time Guidance)

針對「不知道怎麼用、不知道可以上滑記筆記、不知道可以自動配對正反面」的痛點，設計**情境式漸進引導 (Contextual Progressive Disclosure)**：

### 3.1 首次開啟 App 歡迎頁 (Welcome Carousel)
* **頁 1【自動拉直】**：動態展示一張拍歪的實體拍立得，被綠色框線鎖定並瞬間拉正為 86×54mm 標準比例。
* **頁 2【手寫日期自動辨識】**：展示相紙下方的筆跡 `2024.9.24` 自動提取並同步至 iPhone 相簿時間軸。
* **頁 3【正反雙面與特典會備忘】**：展示拍立得翻面動畫與上滑記錄對話的卡片面板。
* **CTA 按鈕**：`[ 開始使用 ]`

### 3.2 首次操作亮點提示 (Spotlight Coach Marks)
1. **初次進入單張檢視時**：
   * 畫面下方浮現輕柔的微動態向上箭頭與提示框：
     > 「💡 **向上滑動**：隨時記錄特典會對話與 #標籤」
     > 「💡 **輕點卡片**：可翻轉至背面查看手寫留言」
   * 用戶觸發一次後，該提示永久消失。
2. **初次批次匯入時**：
   * 在確認工作台浮出標註提示：
     > 「💡 依序拍了正反面？點擊『自動配對』立即成對綁定」

---

## 4. 關鍵使用者流程 (Key User Flows)

### Flow 1: 批次相簿匯入與配對流程 (Batch Import Flow)
1. 點擊頂部 `[+]` ➔ 選擇「從相簿匯入」。
2. iOS 原生 `PhotosPicker` 多選拍立得照片（例如選 10 張）。
3. 進入**【配對確認工作台】**：
   * 頂部三顆切換按鈕：`[ 全部單面 ]`、`[ 自動配對 ⚡ ]`、`[ 手動配對 👆 ]`。
   * 若點選「自動配對」：系統以 Vision 快速檢查相紙特徵，若連續兩張都是正面，彈出警告標記，避免錯配。
   * 若點選「手動配對」：提示「請依序點擊：[正面] ➔ [反面]」，點擊卡片會有高亮邊框依序配對。
4. 點擊 `[ 開始處理 (10張) ]` ➔ 顯示圓形進度條，完成後震動反饋並自動歸入選定的成員資料夾。

### Flow 2: 單張檢視與備忘錄上滑流程 (Detail & Memo Flow)
1. 在網格中點擊任意拍立得 ➔ 英雄動畫過渡展開至全螢幕。
2. **正反面翻轉**：
   * 點擊右下角 `[ 🔄 翻面 ]` 按鈕，卡片以 3D 沿 Y 軸 180 度翻轉至背面。
3. **呼出備忘錄**：
   * 手指向上滑動（Swipe Up）或點擊右上角 `[ ℹ️ 資訊 ]`。
   * 照片等比縮小（縮至螢幕上方 40% 區域），下方滑出原生毛玻璃 Info Sheet。
   * **未有備忘**：顯示文字框「紀錄今天的心情或偶像說的話...」與標籤列「新增 #標籤（如 #生誕祭 #浴衣）」，喚起系統鍵盤直接輸入。
   * **已有備忘**：清晰顯示 OCR 識別日期、已打上的 #標籤標籤膠囊、對話全文，點擊右上角「編輯」即可修改。
