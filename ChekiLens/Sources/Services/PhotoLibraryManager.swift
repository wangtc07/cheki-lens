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
    
    // MARK: - Save Image
    
    /// 將影像存入指定相簿，並強制修改相機時間 (EXIF 建立時間)
    /// - Parameters:
    ///   - image: 要儲存的影像
    ///   - creationDate: 強制指定的拍攝時間 (這也是 Task 3.3 與 3.4 的核心)
    ///   - album: 目標相簿 (可為 nil，代表只存入相機膠卷)
    /// - Returns: 儲存後的 Asset Local Identifier
    func saveImage(_ image: UIImage, creationDate: Date, to album: PHAssetCollection? = nil) async throws -> String {
        guard await requestAuthorization() else {
            throw NSError(domain: "PhotoLibraryManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "無相簿權限"])
        }
        
        var placeholderId: String?
        
        try await PHPhotoLibrary.shared().performChanges {
            // 建立新增照片的 Request
            let creationRequest = PHAssetCreationRequest.forAsset()
            creationRequest.addResource(with: .photo, data: image.jpegData(compressionQuality: 0.9)!, options: nil)
            
            // 強制覆寫照片的拍攝時間 (EXIF)
            creationRequest.creationDate = creationDate
            
            // 如果有指定相簿，加進相簿裡
            if let album = album, let placeholder = creationRequest.placeholderForCreatedAsset {
                let albumChangeRequest = PHAssetCollectionChangeRequest(for: album)
                albumChangeRequest?.addAssets([placeholder] as NSArray)
            }
            
            placeholderId = creationRequest.placeholderForCreatedAsset?.localIdentifier
        }
        
        guard let id = placeholderId else {
            throw NSError(domain: "PhotoLibraryManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "儲存照片失敗"])
        }
        
        return id
    }
    
    // MARK: - Task 4.4 System Photo Library Seeder (測試相片寫入 iOS 系統相簿)
    
    private static let systemSeedFlagKey = "debug.didSeedSystemPhotoLibraryV2"
    
    /// 將 8 張實體拍立得測試相片（含正常正反面、雙正面防呆警示案例、正反順序顛倒案例）寫入 iOS 系統相簿 (`Photos.app`)，
    /// 供使用者點擊「＋」(`PhotosPicker`) 實測 Task 4.4 批次配對工作台。
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
        
        let album = try? await getOrCreateAlbum(albumName: "ChekiLens 測試相片 (Task 4.4)")
        let baseDate = Date()
        
        for (idx, item) in testImages.enumerated() {
            // 依序遞減 5 秒，確保在系統相簿與 PhotosPicker 中順序固定且清晰
            let photoDate = baseDate.addingTimeInterval(TimeInterval(-idx * 5))
            _ = try await saveImage(item.image, creationDate: photoDate, to: album)
        }
        
        UserDefaults.standard.set(true, forKey: Self.systemSeedFlagKey)
        logger.info("已成功寫入 \(testImages.count) 張測試拍立得相片至 iOS 系統相簿 (Photos.app)")
        return testImages.count
    }
    
    /// 建立供寫入系統相簿的 8 張測試相片：
    /// - 優先讀取專案 `TestData/images/` 下的真實拍攝拍立得正反面 JPG（在模擬器環境可直接讀取 Mac 路徑）
    /// - 若檔案不存在（如實機執行），自動回退生成帶有標準 `Don't put in mouth` 與 `FUJIFILM instax` 錨點的高解析度擬真測試相片
    private static func buildTask44SystemTestImages() -> [(title: String, image: UIImage)] {
        let projectTestDir = "/Users/tcwang/Documents/ChekiLens/TestData/images"
        
        // 精心編排的 8 張測試組合：
        // Pair 1 (#1 正面 + #2 背面)：正常正反配對
        // Pair 2 (#3 正面 + #4 正面)：⚠️ 疑似兩張皆為正面（觸發雙正面防呆警示）
        // Pair 3 (#5 背面 + #6 正面)：⚠️ 正反順序顛倒（觸發一鍵對調提示）
        // Pair 4 (#7 正面 + #8 背面)：正常正反配對
        let specs: [(seq: Int, fileName: String, title: String, isBackside: Bool, colors: [UIColor], dateText: String)] = [
            (1, "DSCF0023.JPG", "夏巡舞台服特寫 (正面)", false, [.systemIndigo, .systemPink], "2026.09.24"),
            (2, "DSCF0024.JPG", "夏巡手寫簽名 (背面)",   true,  [.darkGray, .black],          "2026.09.24"),
            (3, "DSCF0025.JPG", "浴衣造型特寫 (正面 A)", false, [.systemTeal, .systemBlue],   "2026.09.28"),
            (4, "DSCF0029.JPG", "生誕祭私服 (正面 B)",   false, [.systemOrange, .systemPink], "2026.09.29"),
            (5, "DSCF0032.JPG", "握手會留言 (背面先選)", true,  [.systemGray, .darkGray],     "2026.10.02"),
            (6, "DSCF0031.JPG", "握手會比愛心 (正面後選)", false, [.systemPurple, .systemIndigo], "2026.10.02"),
            (7, "DSCF0033.JPG", "五週年紀念服 (正面)",   false, [.systemPink, .systemRed],    "2026.10.05"),
            (8, "DSCF0034.JPG", "五週年感謝簽名 (背面)", true,  [.darkGray, .systemIndigo],   "2026.10.05")
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

