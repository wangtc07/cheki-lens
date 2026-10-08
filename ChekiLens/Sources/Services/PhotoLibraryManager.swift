import Foundation
import Photos
import UIKit
import SwiftUI
import OSLog

@Observable
final class PhotoLibraryManager {
    static let shared = PhotoLibraryManager()
    
    var authorizationStatus: PHAuthorizationStatus = .notDetermined
    private let logger = Logger(subsystem: "com.chekilens.app", category: "PhotoLibrary")
    
    /// 是否已解鎖 ChekiLens Pro 終身買斷版
    static var isProLifetimeUnlocked: Bool {
        UserDefaults.standard.bool(forKey: "isProLifetimeUnlocked")
    }
    
    // MARK: - Authorization
    
    /// 檢查並更新目前的相簿權限狀態
    func checkAuthorizationStatus() {
        self.authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }
    
    /// 請求相簿權限
    func requestAuthorization() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await MainActor.run {
            self.authorizationStatus = status
        }
        return status == .authorized || status == .limited
    }
    
    // MARK: - Album Management
    
    /// 取得或建立指定的相簿 (Album)
    /// - Parameters:
    ///   - albumName: 相簿名稱 (例如：成員名稱)
    ///   - folderName: 父資料夾名稱 (例如：ChekiLens 或 團體名稱)。若為 nil 則建立在根目錄
    func getOrCreateAlbum(albumName: String, inFolder folderName: String? = nil) async throws -> PHAssetCollection {
        // 確保有權限
        guard await requestAuthorization() else {
            throw NSError(domain: "PhotoLibraryManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "無相簿權限"])
        }
        
        var targetFolder: PHCollectionList? = nil
        
        // 1. 若有指定資料夾，先取得或建立資料夾
        if let folderName = folderName {
            targetFolder = try await getOrCreateFolder(folderName: folderName)
        }
        
        // 2. 尋找現有相簿（使用安全的列舉比對 localizedTitle，避免部分 iOS 版本因 predicate key 拋出例外）
        if let folder = targetFolder {
            let query = PHCollectionList.fetchCollections(in: folder, options: nil)
            var foundAlbum: PHAssetCollection? = nil
            query.enumerateObjects { (collection, _, stop) in
                if let album = collection as? PHAssetCollection, album.localizedTitle == albumName {
                    foundAlbum = album
                    stop.pointee = true
                }
            }
            if let found = foundAlbum {
                return found
            }
        } else {
            let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            var foundAlbum: PHAssetCollection? = nil
            collections.enumerateObjects { (album, _, stop) in
                if album.localizedTitle == albumName {
                    foundAlbum = album
                    stop.pointee = true
                }
            }
            if let found = foundAlbum {
                return found
            }
        }
        
        // 3. 建立新相簿
        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let createRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
            placeholder = createRequest.placeholderForCreatedAssetCollection
            
            // 如果有父資料夾，將新相簿加入該資料夾
            if let folder = targetFolder, let placeholder = placeholder {
                guard let folderChangeRequest = PHCollectionListChangeRequest(for: folder) else { return }
                folderChangeRequest.addChildCollections([placeholder] as NSArray)
            }
        }
        
        guard let placeholder = placeholder,
              let createdAlbum = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [placeholder.localIdentifier], options: nil).firstObject else {
            throw NSError(domain: "PhotoLibraryManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "建立相簿失敗"])
        }
        
        return createdAlbum
    }
    
    /// 取得或建立資料夾 (Folder)
    private func getOrCreateFolder(folderName: String) async throws -> PHCollectionList {
        let folders = PHCollectionList.fetchCollectionLists(with: .folder, subtype: .any, options: nil)
        var existingFolder: PHCollectionList? = nil
        folders.enumerateObjects { (folder, _, stop) in
            if folder.localizedTitle == folderName {
                existingFolder = folder
                stop.pointee = true
            }
        }
        if let folder = existingFolder {
            return folder
        }
        
        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let createRequest = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: folderName)
            placeholder = createRequest.placeholderForCreatedCollectionList
        }
        
        guard let placeholder = placeholder,
              let createdFolder = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [placeholder.localIdentifier], options: nil).firstObject else {
            throw NSError(domain: "PhotoLibraryManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "建立資料夾失敗"])
        }
        
        return createdFolder
    }
    
    // MARK: - Save & Non-Destructive In-Place Edit Image
    
    /// 同步照片至 iOS 系統相簿（依免費版 / Pro 版區分裁切寫入行為）：
    /// - **免費版 (`isProLifetimeUnlocked == false`)**：原生相簿**不裁切**（保留未裁切原圖），但依然可同步歸檔至 `ChekiLens › 團體 › 成員` 相簿階層並寫入 OCR 拍攝時間軸；裁切後的照片僅在 App 內（加上浮水印）查看，分享或輸出時亦加上浮水印。
    /// - **Pro 終身買斷版 (`isProLifetimeUnlocked == true`)**：
    ///   - 若為系統相簿既有照片 (`existingAssetIdentifier != nil`)，以 `PHContentEditingOutput` 非破壞性原地修改為裁切後拍立得（不新增重複照片，且保留原始底圖供隨時復原）。
    ///   - 若為 App 內相機新拍攝的照片 (`existingAssetIdentifier == nil`)，直接將正位裁切／去反光後的成品存入系統相簿（避免觸發二次修改系統彈窗，同時在 App 內 SwiftData 完整保留 `originalFrontImageData` 供隨時復原）。
    /// - Returns: 該張照片在系統相簿中的 `PHAsset.localIdentifier`
    func updateOrSaveImage(
        _ image: UIImage,
        originalImageData: Data? = nil,
        existingAssetIdentifier: String? = nil,
        creationDate: Date,
        to album: PHAssetCollection? = nil
    ) async throws -> String {
        guard await requestAuthorization() else {
            throw NSError(domain: "PhotoLibraryManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "無相簿權限"])
        }
        
        let isPro = Self.isProLifetimeUnlocked
        
        // 1. 若已有現存 PHAsset
        if let existingId = existingAssetIdentifier,
           !existingId.isEmpty,
           let existingAsset = PHAsset.fetchAssets(withLocalIdentifiers: [existingId], options: nil).firstObject {
            if isPro {
                // Pro 版：直接以 PHContentEditingOutput 非破壞性修改原圖為裁切後拍立得（不新增照片，且保留原始底圖可復原）
                try await modifyAssetInPlace(
                    asset: existingAsset,
                    croppedImage: image,
                    creationDate: creationDate,
                    album: album
                )
            } else {
                // 免費版：原生相簿不裁切（維持未裁切原圖），但同步寫入拍攝時間軸與相簿分類
                try await PHPhotoLibrary.shared().performChanges {
                    let changeRequest = PHAssetChangeRequest(for: existingAsset)
                    changeRequest.creationDate = creationDate
                    if let album {
                        let albumChangeRequest = PHAssetCollectionChangeRequest(for: album)
                        albumChangeRequest?.addAssets([existingAsset] as NSArray)
                    }
                }
            }
            return existingAsset.localIdentifier
        }
        
        // 2. 若尚未存在於系統相簿（例如使用 App 內建相機拍攝）：
        // - Pro 版：直接將正位裁切／Mode B 去反光後的成品存入系統相簿（單次寫入、零彈窗、極速完成；原始未裁切底圖已保存在 SwiftData 供隨時復原）
        // - 免費版：依規則於原生相簿保留未裁切原圖（若無原圖則存 croppedJPEG）
        guard let croppedJPEG = image.jpegData(compressionQuality: 0.92) else {
            throw NSError(domain: "PhotoLibraryManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "影像編碼失敗"])
        }
        let dataToSave = isPro ? croppedJPEG : (originalImageData ?? croppedJPEG)
        var placeholderId: String?
        
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .photo, data: dataToSave, options: nil)
                creationRequest.creationDate = creationDate
                
                if let album = album, let placeholder = creationRequest.placeholderForCreatedAsset {
                    let albumChangeRequest = PHAssetCollectionChangeRequest(for: album)
                    albumChangeRequest?.addAssets([placeholder] as NSArray)
                }
                placeholderId = creationRequest.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            // 若因相簿權限（如 .limited 選取照片模式）導致加入相簿失敗，自動回退為直接寫入系統「最近項目 (Camera Roll)」
            try await PHPhotoLibrary.shared().performChanges {
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .photo, data: dataToSave, options: nil)
                creationRequest.creationDate = creationDate
                placeholderId = creationRequest.placeholderForCreatedAsset?.localIdentifier
            }
        }
        
        guard let createdId = placeholderId else {
            throw NSError(domain: "PhotoLibraryManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "儲存照片失敗"])
        }
        
        return createdId
    }
    
    /// 相容舊版呼叫介面：轉發至 `updateOrSaveImage`
    func saveImage(_ image: UIImage, creationDate: Date, to album: PHAssetCollection? = nil) async throws -> String {
        try await updateOrSaveImage(
            image,
            originalImageData: nil,
            existingAssetIdentifier: nil,
            creationDate: creationDate,
            to: album
        )
    }
    
    /// 使用 Apple Photos 原生 `PHContentEditingOutput` 直接修改既有 `PHAsset`（不新建照片，且保留原始未裁切圖片供隨時復原）
    func modifyAssetInPlace(
        asset: PHAsset,
        croppedImage: UIImage,
        creationDate: Date? = nil,
        album: PHAssetCollection? = nil
    ) async throws {
        guard let jpegData = croppedImage.jpegData(compressionQuality: 0.92) else {
            throw NSError(domain: "PhotoLibraryManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "無法編碼裁切後影像"])
        }
        
        let editingInput = try await requestContentEditingInput(for: asset)
        let output = PHContentEditingOutput(contentEditingInput: editingInput)
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: "wangtc07.ChekiLens.crop",
            formatVersion: "1.0",
            data: Data("cheki-perspective-crop-\(Date().timeIntervalSince1970)".utf8)
        )
        try jpegData.write(to: output.renderedContentURL, options: .atomic)
        
        try await PHPhotoLibrary.shared().performChanges {
            let changeRequest = PHAssetChangeRequest(for: asset)
            changeRequest.contentEditingOutput = output
            if let creationDate {
                changeRequest.creationDate = creationDate
            }
            if let album {
                let albumChangeRequest = PHAssetCollectionChangeRequest(for: album)
                albumChangeRequest?.addAssets([asset] as NSArray)
            }
        }
    }
    
    /// 將既有 `PHAsset` 加入指定相簿（不複製或新建照片）
    func addExistingAsset(identifier: String, creationDate: Date? = nil, to album: PHAssetCollection) async throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return }
        try await PHPhotoLibrary.shared().performChanges {
            if let creationDate {
                let changeRequest = PHAssetChangeRequest(for: asset)
                changeRequest.creationDate = creationDate
            }
            let albumChangeRequest = PHAssetCollectionChangeRequest(for: album)
            albumChangeRequest?.addAssets([asset] as NSArray)
        }
    }
    
    /// 將系統相簿中的 `PHAsset` 復原為未裁切的原始圖片 (`revertAssetContentToOriginal`)
    func revertAssetToOriginal(assetIdentifier: String) async throws {
        guard !assetIdentifier.isEmpty,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject else {
            return
        }
        try await PHPhotoLibrary.shared().performChanges {
            let changeRequest = PHAssetChangeRequest(for: asset)
            changeRequest.revertAssetContentToOriginal()
        }
    }
    
    private func requestContentEditingInput(for asset: PHAsset) async throws -> PHContentEditingInput {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            options.canHandleAdjustmentData = { _ in true }
            asset.requestContentEditingInput(with: options) { input, info in
                if let input {
                    continuation.resume(returning: input)
                } else {
                    let err = (info[PHContentEditingInputErrorKey] as? Error)
                        ?? NSError(domain: "PhotoLibraryManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "無法取得原圖編輯輸入"])
                    continuation.resume(throwing: err)
                }
            }
        }
    }
    
    // MARK: - Task 4.4 & 4.6 System Photo Library Seeder (10 張帶手寫日期拍立得寫入 iOS 原生相簿)
    
    private static let systemSeedFlagKey = "debug.didSeedSystemPhotoLibraryV3_Dated10"
    
    /// 將 10 張帶有封面手寫日期的實體拍立得測試相片寫入 iOS 原生相簿 (`Photos.app`)，
    /// 供使用者點擊「＋」(`PhotosPicker`) 實測導入並自動辨識封面手寫日期與原地裁切（不新增照片、保留原圖可復原）。
    /// - Parameter force: 若為 `true` 則無視已寫入標記，強制再次寫入一組測試相片至系統相簿。
    /// - Returns: 實際寫入系統相簿的相片張數（若先前已自動寫入且 `force == false` 則回傳 0）
    @MainActor
    func seedTestChekiPhotosToSystemLibrary(force: Bool = false) async throws -> Int {
        if !force && UserDefaults.standard.bool(forKey: Self.systemSeedFlagKey) {
            return 0
        }
        
        guard await requestAuthorization() else {
            throw NSError(domain: "PhotoLibraryManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "尚未取得 iOS 系統相簿存取權限，請於系統設定開啟相簿權限。"])
        }
        
        let testImages = Self.buildTask44SystemTestImages()
        guard !testImages.isEmpty else { return 0 }
        
        let album = try? await getOrCreateAlbum(albumName: "ChekiLens 帶日期拍立得測試 (10張)")
        let baseDate = Date()
        
        for (idx, item) in testImages.enumerated() {
            // 依序遞減 5 秒，確保在系統相簿與 PhotosPicker 中順序固定且清晰
            let photoDate = baseDate.addingTimeInterval(TimeInterval(-idx * 5))
            _ = try await saveImage(item.image, creationDate: photoDate, to: album)
        }
        
        UserDefaults.standard.set(true, forKey: Self.systemSeedFlagKey)
        logger.info("已成功寫入 \(testImages.count) 張帶日期拍立得相片至 iOS 系統相簿 (Photos.app)")
        return testImages.count
    }
    
    /// 建立供寫入系統相簿的 10 張帶封面手寫日期之真實拍立得測試相片：
    /// - 優先讀取專案 `TestData/images/` 下帶有真實手寫日期的 10 張拍立得 JPG（在模擬器環境可直接讀取 Mac 路徑）
    /// - 若檔案不存在（如實機執行），自動回退生成帶有清晰手寫日期與拍立得外框的高解析度擬真測試相片
    private static func buildTask44SystemTestImages() -> [(title: String, image: UIImage)] {
        let projectTestDir = "/Users/tcwang/Documents/ChekiLens/TestData/images"
        
        // 10 張帶有真實封面手寫日期的拍立得（均已經過 VisionManager.recognizeDate 100% 驗證）：
        let specs: [(seq: Int, fileName: String, title: String, isBackside: Bool, colors: [UIColor], dateText: String)] = [
            (1,  "DSCF0073.JPG",        "手寫日期 2025.11.3 (正面)",  false, [.systemPink, .systemIndigo],   "2025.11.3"),
            (2,  "DSCF0010.JPG",        "手寫日期 2025.07.31 (正面)", false, [.systemPurple, .systemPink],   "2025.07.31"),
            (3,  "193422_DSCF1405.JPG", "手寫日期 2026.06.26 (正面)", false, [.systemTeal, .systemBlue],     "2026.06.26"),
            (4,  "193424_DSCF1411.JPG", "手寫日期 2026.07.31 (正面)", false, [.systemOrange, .systemPink],   "2026.07.31"),
            (5,  "193425_DSCF1414.JPG", "手寫日期 2026.8-5 (正面)",   false, [.systemIndigo, .systemCyan],   "2026.8-5"),
            (6,  "193426_DSCF1417.JPG", "手寫日期 2026.8.11 (正面)",  false, [.systemBlue, .systemPurple],   "2026.8.11"),
            (7,  "193427_DSCF1421.JPG", "手寫日期 2026.08.23 (正面)", false, [.systemRed, .systemOrange],    "2026.08.23"),
            (8,  "193428_DSCF1424.JPG", "手寫日期 2026.8.22 (正面)",  false, [.systemMint, .systemTeal],     "2026.8.22"),
            (9,  "193430_DSCF1429.JPG", "手寫日期 2026.08.24 (正面)", false, [.systemPink, .systemPurple],   "2026.08.24"),
            (10, "193430_DSCF1430.JPG", "手寫日期 2026.8.28 (正面)",  false, [.systemIndigo, .systemBlue],   "2026.8.28")
        ]
        
        var results: [(title: String, image: UIImage)] = []
        for spec in specs {
            let fullPath = (projectTestDir as NSString).appendingPathComponent(spec.fileName)
            if FileManager.default.fileExists(atPath: fullPath),
               let diskImage = UIImage(contentsOfFile: fullPath) {
                results.append((spec.title, diskImage))
            } else {
                let fallbackImage = renderFallbackTestChekiImage(
                    sequence: spec.seq,
                    title: spec.title,
                    colors: spec.colors,
                    isBackside: spec.isBackside,
                    dateText: spec.dateText
                )
                results.append((spec.title, fallbackImage))
            }
        }
        return results
    }
    
    /// 當不在 Mac 模擬器路徑時，繪製帶有真實 Vision OCR 錨點 (`Don't put in mouth` / `FUJIFILM instax`) 的高解析度測試相片
    static func renderFallbackTestChekiImage(
        sequence: Int,
        title: String,
        colors: [UIColor],
        isBackside: Bool,
        dateText: String
    ) -> UIImage {
        let size = CGSize(width: 540, height: 860)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor(white: isBackside ? 0.92 : 0.98, alpha: 1.0).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            
            if isBackside {
                // 頂部黑膠帶警告文字（供 BacksideDetector Layer 0 100% 識別）
                let topWarnAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 20, weight: .bold),
                    .foregroundColor: UIColor(white: 0.20, alpha: 1.0)
                ]
                NSAttributedString(string: "Don't put in mouth.", attributes: topWarnAttrs)
                    .draw(at: CGPoint(x: 155, y: 18))
            }
            
            let innerRect = CGRect(x: 40, y: 52, width: 460, height: 616)
            cg.saveGState()
            cg.addRect(innerRect)
            cg.clip()
            
            let cgColors = colors.map {
                isBackside ? $0.withAlphaComponent(0.22).cgColor : $0.cgColor
            } as CFArray
            
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: cgColors,
                locations: [0.0, 1.0]
            ) {
                cg.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: innerRect.minX, y: innerRect.minY),
                    end: CGPoint(x: innerRect.maxX, y: innerRect.maxY),
                    options: []
                )
            }
            
            if !isBackside {
                cg.setFillColor(UIColor.white.withAlphaComponent(0.30).cgColor)
                cg.fillEllipse(in: CGRect(x: 195, y: 170, width: 150, height: 150))
                cg.fillEllipse(in: CGRect(x: 120, y: 340, width: 300, height: 280))
            } else {
                let backAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 26, weight: .semibold),
                    .foregroundColor: UIColor.darkGray
                ]
                NSAttributedString(string: "いつもありがとう！♡\nまた来週のライブでね", attributes: backAttrs)
                    .draw(in: CGRect(x: 80, y: 240, width: 380, height: 140))
            }
            cg.restoreGState()
            
            let dateAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 28, weight: .bold),
                .foregroundColor: UIColor(white: 0.22, alpha: 1.0)
            ]
            NSAttributedString(string: dateText, attributes: dateAttrs)
                .draw(at: CGPoint(x: 56, y: 710))
            
            let seqAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .medium),
                .foregroundColor: UIColor.secondaryLabel
            ]
            NSAttributedString(string: "#\(sequence) \(title)", attributes: seqAttrs)
                .draw(at: CGPoint(x: 56, y: 752))
            
            if isBackside {
                // 底部品牌標記（供 BacksideDetector 雙錨點定位）
                let instaxAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedSystemFont(ofSize: 24, weight: .bold),
                    .foregroundColor: UIColor(white: 0.25, alpha: 1.0)
                ]
                NSAttributedString(string: "FUJIFILM instax", attributes: instaxAttrs)
                    .draw(at: CGPoint(x: 150, y: 798))
            }
        }
    }
}

// MARK: - 免費版浮水印渲染器與視圖疊加元件 (Free Tier Watermark Overlay & Export Renderer)

/// 負責在「免費版 (`isProLifetimeUnlocked == false`)」且每日 1 張免費高畫質額度用罄後，
/// 將匯出/分享的裁切拍立得縮小為 SNS 夠用畫質（長邊上限 960px、JPEG 0.72 壓縮）並於右下角加上 `ChekiLens` 浮水印；
/// 若已解鎖 Pro 終身買斷版（或使用當日 1 張免費高畫質額度），則 100% 原圖 4K 無損直出、完全不加浮水印。
enum ChekiWatermarkRenderer {
    /// 免費版額度用完後的 SNS 輸出長邊像素上限（例如 Mini 約 603×960 px，勉強夠 SNS 分享）
    static let freeTierSNSMaxDimension: CGFloat = 960.0
    /// 免費版額度用完後的 JPEG 壓縮品質
    static let freeTierSNSJPEGQuality: CGFloat = 0.72

    static func applyWatermarkIfNeeded(to image: UIImage, downscaleForSNS: Bool = true) -> UIImage {
        guard !PhotoLibraryManager.isProLifetimeUnlocked else {
            return image
        }

        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth > 10, pixelHeight > 10 else { return image }

        // 1. 計算免費版 SNS 縮圖尺寸（長邊上限 960px，scale 固定為 1.0 確保實際輸出像素縮小）
        let targetSize: CGSize
        if downscaleForSNS {
            let maxSide = max(pixelWidth, pixelHeight)
            let ratio = maxSide > freeTierSNSMaxDimension ? (freeTierSNSMaxDimension / maxSide) : 1.0
            targetSize = CGSize(
                width: max(1, round(pixelWidth * ratio)),
                height: max(1, round(pixelHeight * ratio))
            )
        } else {
            targetSize = CGSize(width: pixelWidth, height: pixelHeight)
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)

        let watermarkedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
            let shortSide = min(targetSize.width, targetSize.height)

            // 右下角拍立得白邊品牌浮水印章 ("ChekiLens")
            let badgeFontSize = max(12, shortSide * 0.038)
            let badgeText = "ChekiLens"
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: badgeFontSize, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.92),
                .kern: 0.6
            ]
            let attributedBadge = NSAttributedString(string: badgeText, attributes: badgeAttrs)
            let textSize = attributedBadge.size()
            let padX = badgeFontSize * 0.65
            let padY = badgeFontSize * 0.34
            let margin = max(10, shortSide * 0.036)

            let pillRect = CGRect(
                x: targetSize.width - textSize.width - padX * 2 - margin,
                y: targetSize.height - textSize.height - padY * 2 - margin,
                width: textSize.width + padX * 2,
                height: textSize.height + padY * 2
            )

            let pillPath = UIBezierPath(roundedRect: pillRect, cornerRadius: pillRect.height / 2)
            UIColor.black.withAlphaComponent(0.42).setFill()
            pillPath.fill()

            UIColor.white.withAlphaComponent(0.28).setStroke()
            pillPath.lineWidth = max(1.0, shortSide * 0.0025)
            pillPath.stroke()

            attributedBadge.draw(
                at: CGPoint(
                    x: pillRect.minX + padX,
                    y: pillRect.minY + padY
                )
            )
        }

        // 2. 壓縮為 SNS 等級 JPEG，讓檔案大小與畫質僅勉強夠 SNS 分享使用
        if downscaleForSNS,
           let compressedData = watermarkedImage.jpegData(compressionQuality: freeTierSNSJPEGQuality),
           let compressedImage = UIImage(data: compressedData) {
            return compressedImage
        }
        return watermarkedImage
    }
}

/// App 內檢視裁切後拍立得時的非破壞性浮水印疊加層：
/// - 免費版 (`isProLifetimeUnlocked == false`)：在 App 內查看裁切後的拍立得照片時於右下角顯示浮水印。
/// - Pro 終身買斷版 (`isProLifetimeUnlocked == true`)：自動完全隱藏浮水印。
struct ChekiWatermarkOverlayView: View {
    @AppStorage("isProLifetimeUnlocked") private var isProLifetimeUnlocked: Bool = false

    /// 是否為網格縮圖緊湊模式
    var compact: Bool = false

    var body: some View {
        let fontSize: CGFloat = compact ? 8.5 : 11.5
        let hPad: CGFloat = compact ? 5.5 : 8.5
        let vPad: CGFloat = compact ? 2.0 : 3.5
        let outerPad: CGFloat = compact ? 5.0 : 10.0

        ZStack {
            if !isProLifetimeUnlocked {
                // 右下角品牌浮水印標記
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("ChekiLens")
                            .font(.system(size: fontSize, weight: .bold, design: .rounded))
                            .tracking(0.4)
                            .foregroundStyle(Color.white.opacity(0.90))
                            .padding(.horizontal, hPad)
                            .padding(.vertical, vPad)
                            .background(Color.black.opacity(0.42), in: Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.5)
                            )
                            .padding(outerPad)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}


