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

    /// 裁切済みチェキ画像の底部 20% 領域から手書き日付を認識
    ///
    /// - Parameter croppedImage: Task 2.4 で透視校正済みの CGImage
    /// - Returns: 認識した日付（nil = 認識失敗）
    func recognizeDate(from croppedImage: CGImage) async -> OCRDateResult? {
        // ① 底部 20% を切り出し（白い余白に手書きがある）
        let imgW = croppedImage.width
        let imgH = croppedImage.height
        let bottomY = Int(Double(imgH) * 0.78)   // 上端から 78% の位置
        guard let bottomROI = croppedImage.cropping(to: CGRect(
            x: 0, y: bottomY,
            width: imgW, height: imgH - bottomY
        )) else { return nil }

        // ② VNRecognizeTextRequest 実行
        let request = VNRecognizeTextRequest()
        request.recognitionLevel     = .accurate
        request.recognitionLanguages = ["ja", "en"]
        request.usesLanguageCorrection = false   // 手書き日付は言語補正不要
        request.minimumTextHeight    = 0.05      // 小さい文字も拾う

        let handler = VNImageRequestHandler(cgImage: bottomROI, options: [:])
        try? handler.perform([request])

        guard let observations = request.results else { return nil }

        // ③ 全テキスト候補を収集してパース
        let candidates = observations
            .flatMap { obs -> [(String, Float)] in
                let topN = obs.topCandidates(5)
                return topN.map { ($0.string, $0.confidence) }
            }
            .sorted { $0.1 > $1.1 }   // 信頼度降順

        for (text, confidence) in candidates {
            if let result = parseDateString(text, confidence: confidence) {
                return result
            }
        }
        return nil
    }

    // MARK: - Date Parsing

    /// 手書き日付テキストをパース
    private func parseDateString(_ text: String, confidence: Float) -> OCRDateResult? {
        // 前処理：全角数字 → 半角、余分なスペース除去
        let normalized = normalizeText(text)

        // 試行する正規表現パターン（優先度順）
        let patterns: [(pattern: String, format: String)] = [
            // 西暦 4 桁
            (#"(\d{4})[./\-](\d{1,2})[./\-](\d{1,2})"#, "yyyy-M-d"),
            // 西暦 2 桁
            (#"(\d{2})[./\-](\d{1,2})[./\-](\d{1,2})"#, "yy-M-d"),
            // 元号（R=令和, H=平成, S=昭和）
            (#"[RrＲ](\d{1,2})[./\-](\d{1,2})[./\-](\d{1,2})"#, "reiwa"),
            (#"[HhＨ](\d{1,2})[./\-](\d{1,2})[./\-](\d{1,2})"#, "heisei"),
            // 月/日のみ
            (#"(\d{1,2})[./](\d{1,2})"#, "M-d"),
        ]

        for (pattern, formatHint) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(normalized.startIndex..., in: normalized)
            guard let match = regex.firstMatch(in: normalized, range: range) else { continue }

            if let date = extractDate(from: match, in: normalized, formatHint: formatHint) {
                return OCRDateResult(
                    date: date,
                    rawText: text,
                    confidence: confidence,
                    formatMatched: formatHint
                )
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

        switch formatHint {
        case "yyyy-M-d":
            guard let y = group(1).flatMap(Int.init),
                  let m = group(2).flatMap(Int.init),
                  let d = group(3).flatMap(Int.init) else { return nil }
            return makeDate(year: y, month: m, day: d)

        case "yy-M-d":
            guard let yy = group(1).flatMap(Int.init),
                  let m  = group(2).flatMap(Int.init),
                  let d  = group(3).flatMap(Int.init) else { return nil }
            // 2000年代か 1900年代か判定（50以上は1900年代）
            let y = yy >= 50 ? 1900 + yy : 2000 + yy
            return makeDate(year: y, month: m, day: d)

        case "reiwa":
            guard let ry = group(1).flatMap(Int.init),
                  let m  = group(2).flatMap(Int.init),
                  let d  = group(3).flatMap(Int.init) else { return nil }
            return makeDate(year: 2018 + ry, month: m, day: d)

        case "heisei":
            guard let hy = group(1).flatMap(Int.init),
                  let m  = group(2).flatMap(Int.init),
                  let d  = group(3).flatMap(Int.init) else { return nil }
            return makeDate(year: 1988 + hy, month: m, day: d)

        case "M-d":
            guard let m = group(1).flatMap(Int.init),
                  let d = group(2).flatMap(Int.init) else { return nil }
            // 年は当年から推定（将来日付なら昨年）
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
        guard (1900...2100).contains(year),
              (1...12).contains(month),
              (1...31).contains(day) else { return nil }
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = 12    // 正午に固定（時刻不明なため）
        return Calendar.current.date(from: comps)
    }

    // MARK: - Text Normalization

    private func normalizeText(_ input: String) -> String {
        // 全角数字 → 半角
        var s = input
        let fullWidthDigits = "０１２３４５６７８９"
        let halfWidthDigits = "0123456789"
        for (fw, hw) in zip(fullWidthDigits, halfWidthDigits) {
            s = s.replacingOccurrences(of: String(fw), with: String(hw))
        }
        // 全角スラッシュ・ドット
        s = s.replacingOccurrences(of: "．", with: ".")
        s = s.replacingOccurrences(of: "／", with: "/")
        // 余白除去
        s = s.trimmingCharacters(in: .whitespaces)
        return s
    }
}
