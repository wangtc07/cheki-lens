import Foundation
import Photos
import UIKit
import OSLog

@Observable
final class PhotoLibraryManager {
    static let shared = PhotoLibraryManager()
    
    var authorizationStatus: PHAuthorizationStatus = .notDetermined
    private let logger = Logger(subsystem: "com.chekilens.app", category: "PhotoLibrary")
    
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
        
        // 2. 尋找現有相簿
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", albumName)
        
        let collections: PHFetchResult<PHAssetCollection>
        if let folder = targetFolder {
            // 從指定資料夾內尋找相簿
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
            // 從根目錄尋找
            collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
            if let album = collections.firstObject {
                return album
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
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", folderName)
        
        let folders = PHCollectionList.fetchCollectionLists(with: .folder, subtype: .any, options: fetchOptions)
        if let folder = folders.firstObject {
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
    
    /// 直接修改現有系統相簿原圖（不新增重複照片，保留原始圖片可復原）；若尚未存在於系統相簿則以原圖建立並套用非破壞性裁切編輯
    /// - Parameters:
    ///   - image: 裁切後的拍立得影像
    ///   - originalImageData: 原始未裁切圖片資料（首次寫入相簿時作為底層原圖保留，供日後復原）
    ///   - existingAssetIdentifier: 原生相簿既有的 `PHAsset.localIdentifier`（若提供則直接原地修改該張照片，絕不新建照片）
    ///   - creationDate: 拍攝時間（含手寫日期 OCR 時間軸）
    ///   - album: 目標相簿（可為 nil）
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
        
        // 1. 若已有現存 PHAsset，直接以 PHContentEditingOutput 非破壞性修改原圖（不新增照片，且保留原始底圖可復原）
        if let existingId = existingAssetIdentifier,
           !existingId.isEmpty,
           let existingAsset = PHAsset.fetchAssets(withLocalIdentifiers: [existingId], options: nil).firstObject {
            try await modifyAssetInPlace(
                asset: existingAsset,
                croppedImage: image,
                creationDate: creationDate,
                album: album
            )
            return existingAsset.localIdentifier
        }
        
        // 2. 若尚未存在於系統相簿：先以「原始未裁切圖片」建立 PHAsset，若 image 為已裁切圖則立即套用非破壞性編輯
        guard let croppedJPEG = image.jpegData(compressionQuality: 0.92) else {
            throw NSError(domain: "PhotoLibraryManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "影像編碼失敗"])
        }
        let baseData = originalImageData ?? croppedJPEG
        var placeholderId: String?
        
        try await PHPhotoLibrary.shared().performChanges {
            let creationRequest = PHAssetCreationRequest.forAsset()
            creationRequest.addResource(with: .photo, data: baseData, options: nil)
            creationRequest.creationDate = creationDate
            
            if let album = album, let placeholder = creationRequest.placeholderForCreatedAsset {
                let albumChangeRequest = PHAssetCollectionChangeRequest(for: album)
                albumChangeRequest?.addAssets([placeholder] as NSArray)
            }
            placeholderId = creationRequest.placeholderForCreatedAsset?.localIdentifier
        }
        
        guard let createdId = placeholderId else {
            throw NSError(domain: "PhotoLibraryManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "儲存照片失敗"])
        }
        
        // 若提供了原始未裁切底圖且與裁切後圖片不同，將裁切結果透過 PHContentEditingOutput 覆蓋於同一張 PHAsset 上（保留原圖可復原）
        if let origData = originalImageData,
           origData != croppedJPEG,
           let createdAsset = PHAsset.fetchAssets(withLocalIdentifiers: [createdId], options: nil).firstObject {
            try? await modifyAssetInPlace(
                asset: createdAsset,
                croppedImage: image,
                creationDate: creationDate,
                album: nil
            )
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

