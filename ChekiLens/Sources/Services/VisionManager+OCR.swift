import Foundation
import CoreImage
import CoreGraphics
import Vision

// MARK: - VisionManager + OCR Date Recognition (Task 2.6)
//
// VNRecognizeTextRequest で拍立得底部白い余白の手書き日付を認識
// 対応フォーマット：
//   24.9.24 / 2024.9.24
//   24/9/24 / 2024/9/24
//   24-9-24 / 2024-9-24
//   R6.9.24（元号：R=令和, H=平成, S=昭和）
//   9/24（月/日のみ：年は撮影年から推定）

extension VisionManager {

    // MARK: - OCR Result

    struct OCRDateResult {
        var date: Date
        var rawText: String        // 認識した生テキスト
        var confidence: Float
        var formatMatched: String  // どの正規表現にマッチしたか
    }

    // MARK: - Main OCR Entry

    /// 裁切済みチェキ画像全体（および上部・下部 ROI）から手書き日付を認識
    ///
    /// - Parameter croppedImage: 透視校正済みのチェキ CGImage（または元画像）
    /// - Returns: 認識した日付（nil = 認識失敗）
    func recognizeDate(from croppedImage: CGImage) async -> OCRDateResult? {
        let imgW = croppedImage.width
        let imgH = croppedImage.height
        guard imgW > 32, imgH > 32 else { return nil }

        // チェキの手書き日付は下部余白だけでなく、上部余白・写真内上部・中央・下部にも書かれるため
        // ① 全体画像、② 上部 35% ROI、③ 下部 35% ROI、④ コントラスト強調画像の順で候補を収集
        var rois: [CGImage] = [croppedImage]

        // 上部 35% ROI（例：DSCF0073 のような上部手書き日付）
        if let topROI = croppedImage.cropping(to: CGRect(
            x: 0,
            y: 0,
            width: imgW,
            height: Int(Double(imgH) * 0.36)
        )) {
            rois.append(topROI)
        }

        // 下部 35% ROI（定番の下部白枠および写真下部手書き日付）
        let bottomY = Int(Double(imgH) * 0.64)
        if let bottomROI = croppedImage.cropping(to: CGRect(
            x: 0,
            y: bottomY,
            width: imgW,
            height: imgH - bottomY
        )) {
            rois.append(bottomROI)
        }

        var allCandidates: [(String, Float)] = []
        for roi in rois {
            let extracted = extractTextCandidates(from: roi)
            allCandidates.append(contentsOf: extracted)
        }

        // まずは優先度の高い西暦4桁・元号・西暦2桁パターンで全候補を走査
        if let best = findBestDateMatch(in: allCandidates, allowMonthDayOnly: false) {
            return best
        }

        // まだ見つからない場合、ポスカ（蛍光ペン・パステル色）対策としてコントラスト強調パスを実行
        if let enhancedCG = makeContrastEnhancedImage(from: croppedImage) {
            var enhancedROIs: [CGImage] = [enhancedCG]
            if let topEnhanced = enhancedCG.cropping(to: CGRect(
                x: 0,
                y: 0,
                width: enhancedCG.width,
                height: Int(Double(enhancedCG.height) * 0.36)
            )) {
                enhancedROIs.append(topEnhanced)
            }
            if let bottomEnhanced = enhancedCG.cropping(to: CGRect(
                x: 0,
                y: Int(Double(enhancedCG.height) * 0.64),
                width: enhancedCG.width,
                height: enhancedCG.height - Int(Double(enhancedCG.height) * 0.64)
            )) {
                enhancedROIs.append(bottomEnhanced)
            }

            for roi in enhancedROIs {
                allCandidates.append(contentsOf: extractTextCandidates(from: roi))
            }

            if let best = findBestDateMatch(in: allCandidates, allowMonthDayOnly: false) {
                return best
            }
        }

        // 最終フォールバック：月/日のみ（例: 11/3, 9月24日）を許容して検索
        return findBestDateMatch(in: allCandidates, allowMonthDayOnly: true)
    }

    // MARK: - Vision Text Recognition Helpers

    private func extractTextCandidates(from cgImage: CGImage) -> [(String, Float)] {
        var results: [(String, Float)] = []

        // 1. 英語・数字特化パス（数字やドット・スラッシュが仮名に誤認識されるのを防ぐ）
        let enRequest = VNRecognizeTextRequest()
        enRequest.recognitionLevel = .accurate
        enRequest.recognitionLanguages = ["en-US"]
        enRequest.usesLanguageCorrection = false
        enRequest.minimumTextHeight = 0.012
        enRequest.customWords = ["2023.", "2024.", "2025.", "2026.", "2027."]

        // 2. 日本語＋英語マルチリンガルパス（「年・月・日」や縦書き・丸文字数字に強い）
        let jaRequest = VNRecognizeTextRequest()
        jaRequest.recognitionLevel = .accurate
        jaRequest.recognitionLanguages = ["ja-JP", "en-US", "zh-Hant"]
        jaRequest.usesLanguageCorrection = false
        jaRequest.minimumTextHeight = 0.012
        jaRequest.customWords = ["2023.", "2024.", "2025.", "2026.", "2027."]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([enRequest, jaRequest])

        for req in [enRequest, jaRequest] {
            if let observations = req.results {
                for obs in observations {
                    for cand in obs.topCandidates(5) {
                        results.append((cand.string, cand.confidence))
                    }
                }
            }
        }
        return results
    }

    private func makeContrastEnhancedImage(from cgImage: CGImage) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(1.45, forKey: kCIInputContrastKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(output, from: output.extent)
    }

    private func findBestDateMatch(
        in candidates: [(String, Float)],
        allowMonthDayOnly: Bool
    ) -> OCRDateResult? {
        let sorted = candidates.sorted { $0.1 > $1.1 }

        // Tier 1A: 西暦 4 桁・標準区切り（日が1〜2桁のクリーンな一致を最優先）
        if let match = pickBestYearMatch(from: sorted, tier: .fourDigitYearClean) {
            return match
        }

        // Tier 1B: 西暦 4 桁・末尾ハート誤認識やスラッシュ誤認識などの補正パターン
        if let match = pickBestYearMatch(from: sorted, tier: .fourDigitYearFallback) {
            return match
        }

        // Tier 2: 元号 (R6.9.24) & 西暦 2 桁 (25.11.3)
        for (text, confidence) in sorted {
            if let result = parseDateString(text, confidence: confidence, allowedTiers: [.eraYear, .twoDigitYear]) {
                return result
            }
        }

        // Tier 3: 月/日のみ (allowMonthDayOnly == true の場合のみ)
        if allowMonthDayOnly {
            for (text, confidence) in sorted where confidence >= 0.45 {
                if let result = parseDateString(text, confidence: confidence, allowedTiers: [.monthDayOnly]) {
                    return result
                }
            }
        }

        return nil
    }

    private func pickBestYearMatch(
        from sortedCandidates: [(String, Float)],
        tier: DatePatternTier
    ) -> OCRDateResult? {
        var matches: [OCRDateResult] = []
        for (text, confidence) in sortedCandidates {
            if let result = parseDateString(text, confidence: confidence, allowedTiers: [tier]) {
                matches.append(result)
            }
        }
        guard !matches.isEmpty else { return nil }
        let cal = Calendar(identifier: .gregorian)
        if let recentMatch = matches.first(where: {
            let y = cal.component(.year, from: $0.date)
            return (2022...2028).contains(y)
        }) {
            return recentMatch
        }
        return matches.first
    }

    // MARK: - Date Parsing

    private enum DatePatternTier: Equatable {
        case fourDigitYearClean
        case fourDigitYearFallback
        case eraYear
        case twoDigitYear
        case monthDayOnly
    }

    /// 手書き日付テキストをパース
    private func parseDateString(
        _ text: String,
        confidence: Float,
        allowedTiers: [DatePatternTier]
    ) -> OCRDateResult? {
        let normalized = normalizeText(text)

        let patterns: [(pattern: String, format: String, tier: DatePatternTier)] = [
            // 西暦 4 桁・クリーン一致（2025.11.3 / 2026,07,31 / 2025年11月3日）
            (#"(?:^|[^\d])(20[1-3]\d)\s*[./\-,:;·•・年\s]\s*(1[0-2]|0?[1-9])\s*[./\-,:;·•・月\s]\s*([12]\d|3[01]|0?[1-9])\s*日?(?:$|[^\d])"#, "yyyy-M-d", .fourDigitYearClean),
            // 西暦 4 桁・末尾のハート♡や曜日記号が3桁目の数字（例: .310, .060, .223）として誤認識されたケース
            (#"(?:^|[^\d])(20[1-3]\d)\s*[./\-,:;·•・年\s]\s*(1[0-2]|0?[1-9])\s*[./\-,:;·•・月\s]\s*(\d{3})\s*日?(?:$|[^\d])"#, "yyyy-M-d", .fourDigitYearFallback),
            // 西暦 4 桁・スラッシュが 1 に誤認識されたケース（例 "2026.7131" -> 2026.7/31）
            (#"(?:^|[^\d])(20[1-3]\d)\s*[./\-,:;·•・]\s*(0?[1-9]|1[0-2])1([0-2]\d|3[01])(?:$|[^\d])"#, "yyyy-M-d", .fourDigitYearFallback),
            // 西暦 4 桁・2番目のドットが掠れて消えたケース（例 "2025.113" や "2026.626"）
            (#"(?:^|[^\d])(20[1-3]\d)\s*[./\-,:;·•・]\s*(1[0-2]|0?[1-9])([0-3]\d|[1-9])(?:$|[^\d])"#, "yyyy-M-d", .fourDigitYearFallback),
            // 元号（R=令和, H=平成）
            (#"[RrＲ]\s*(\d{1,2})\s*[./\-,:;·•・年]\s*(\d{1,2})\s*[./\-,:;·•・月]\s*(\d{1,3})"#, "reiwa", .eraYear),
            (#"[HhＨ]\s*(\d{1,2})\s*[./\-,:;·•・年]\s*(\d{1,2})\s*[./\-,:;·•・月]\s*(\d{1,3})"#, "heisei", .eraYear),
            // 西暦 2 桁（24.9.24 / '25.11.3 / 25/10/08）
            (#"(?:^|[^\d])'?([1-3]\d)\s*[./\-,:;·•・年]\s*(\d{1,2})\s*[./\-,:;·•・月]\s*(\d{1,3})\s*日?(?:$|[^\d])"#, "yy-M-d", .twoDigitYear),
            // 月/日のみ（スラッシュまたは「月/日」表記）
            (#"(?:^|[^\d.])(1[0-2]|0?[1-9])\s*[/／月]\s*([12]\d|3[01]|0?[1-9])\s*日?(?:$|[^\d.])"#, "M-d", .monthDayOnly),
        ]

        for (pattern, formatHint, tier) in patterns where allowedTiers.contains(tier) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(normalized.startIndex..., in: normalized)
            let matches = regex.matches(in: normalized, range: range)
            for match in matches {
                if let date = extractDate(from: match, in: normalized, formatHint: formatHint) {
                    return OCRDateResult(
                        date: date,
                        rawText: text,
                        confidence: confidence,
                        formatMatched: formatHint
                    )
                }
            }
        }
        return nil
    }

    private func extractDate(
        from match: NSTextCheckingResult,
        in text: String,
        formatHint: String
    ) -> Date? {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())

        func group(_ i: Int) -> String? {
            guard i < match.numberOfRanges,
                  let r = Range(match.range(at: i), in: text) else { return nil }
            return String(text[r])
        }

        func sanitizeDay(_ rawDayStr: String?) -> Int? {
            guard let raw = rawDayStr else { return nil }
            if let val = Int(raw), (1...31).contains(val) {
                return val
            }
            // 末尾の♡や丸記号が3桁目の数字（例: "310" -> 31, "060" -> 06, "223" -> 22）になった場合
            if raw.count == 3 {
                let prefix2 = String(raw.prefix(2))
                if let val2 = Int(prefix2), (1...31).contains(val2) {
                    return val2
                }
            }
            return nil
        }

        switch formatHint {
        case "yyyy-M-d":
            guard var y = group(1).flatMap(Int.init),
                  let m = group(2).flatMap(Int.init),
                  let d = sanitizeDay(group(3)) else { return nil }
            // 手書きの「2025」が「2015」に、「2026」が「2036」に誤認識された場合の補正
            if y == 2015 { y = 2025 }
            if y == 2036 { y = 2026 }
            return makeDate(year: y, month: m, day: d)

        case "yy-M-d":
            guard let yy = group(1).flatMap(Int.init),
                  let m  = group(2).flatMap(Int.init),
                  let d  = sanitizeDay(group(3)) else { return nil }
            let y = yy >= 50 ? 1900 + yy : 2000 + yy
            return makeDate(year: y, month: m, day: d)

        case "reiwa":
            guard let ry = group(1).flatMap(Int.init),
                  let m  = group(2).flatMap(Int.init),
                  let d  = sanitizeDay(group(3)) else { return nil }
            return makeDate(year: 2018 + ry, month: m, day: d)

        case "heisei":
            guard let hy = group(1).flatMap(Int.init),
                  let m  = group(2).flatMap(Int.init),
                  let d  = sanitizeDay(group(3)) else { return nil }
            return makeDate(year: 1988 + hy, month: m, day: d)

        case "M-d":
            guard let m = group(1).flatMap(Int.init),
                  let d = sanitizeDay(group(2)) else { return nil }
            var year = currentYear
            if let candidate = makeDate(year: year, month: m, day: d),
               candidate > Date() {
                year -= 1
            }
            return makeDate(year: year, month: m, day: d)

        default:
            return nil
        }
    }

    private func makeDate(year: Int, month: Int, day: Int) -> Date? {
        guard (1995...2035).contains(year),
              (1...12).contains(month),
              (1...31).contains(day) else { return nil }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12    // 正午に固定（時刻マージ時は年月日のみ利用）
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        guard let date = cal.date(from: comps),
              cal.component(.month, from: date) == month,
              cal.component(.day, from: date) == day else { return nil }
        return date
    }

    // MARK: - Text Normalization

    private func normalizeText(_ input: String) -> String {
        var s = input
        // 全角数字 → 半角
        let fullWidthDigits = "０１２３４５６７８９"
        let halfWidthDigits = "0123456789"
        for (fw, hw) in zip(fullWidthDigits, halfWidthDigits) {
            s = s.replacingOccurrences(of: String(fw), with: String(hw))
        }
        // 全角スラッシュ・ドット・ハイフン統一
        s = s.replacingOccurrences(of: "．", with: ".")
        s = s.replacingOccurrences(of: "。", with: ".")
        s = s.replacingOccurrences(of: "／", with: "/")
        s = s.replacingOccurrences(of: "－", with: "-")
        s = s.replacingOccurrences(of: "ー", with: "-")
        s = s.replacingOccurrences(of: "—", with: "-")

        // 手書き西暦・数字の頻出誤認識補正
        // 例: DSCF0073 "20）55.11.3" / "20155.11.2" -> "2025.11.3"
        if let regex2025 = try? NSRegularExpression(pattern: #"20[)）I1l|]55?"#) {
            s = regex2025.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "2025")
        }
        if let regex2026 = try? NSRegularExpression(pattern: #"2[09]9?2[6hHbG]|2076"#) {
            s = regex2026.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "2026")
        }
        s = s.replacingOccurrences(of: "2O2", with: "202")
        s = s.replacingOccurrences(of: "2o2", with: "202")
        s = s.replacingOccurrences(of: "2Q2", with: "202")
        s = s.replacingOccurrences(of: "C025", with: "2025")
        s = s.replacingOccurrences(of: "1025.", with: "2025.")
        s = s.replacingOccurrences(of: "425.0", with: "2025.0")
        s = s.replacingOccurrences(of: ".ll.", with: ".11.")
        s = s.replacingOccurrences(of: ".l1.", with: ".11.")
        s = s.replacingOccurrences(of: ".1l.", with: ".11.")
        s = s.replacingOccurrences(of: ".II.", with: ".11.")
        s = s.replacingOccurrences(of: ".I1.", with: ".11.")
        s = s.replacingOccurrences(of: ".1I.", with: ".11.")
        s = s.replacingOccurrences(of: "/ll/", with: "/11/")
        s = s.replacingOccurrences(of: "/I1/", with: "/11/")

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
