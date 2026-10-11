import SwiftUI
import UIKit

/// 格狀頁面的雙指縮放：手指移動時只跟手縮放，放開才切換欄數。
enum GridPinchZoom {
    static let columnCounts = [1, 2, 3, 5]
    /// 相冊封面磚。預設 2 欄，放大可到 1 欄，縮小可到 3 欄。
    static let albumColumnCounts = [1, 2, 3]

    static func dampedScale(magnification: CGFloat) -> CGFloat {
        if magnification >= 1 {
            return 1 + min(magnification - 1, 1.2) * 0.32
        }
        return 1 - min(1 - magnification, 0.55) * 0.32
    }

    /// 放大減少欄數，縮小增加欄數。未過門檻時維持基準欄數。
    static func columnCount(after magnification: CGFloat, from baseline: Int, counts: [Int] = columnCounts) -> Int {
        guard !counts.isEmpty else { return baseline }
        let baseIndex = counts.firstIndex(of: baseline) ?? (counts.count - 1)
        let targetIndex: Int
        if magnification > 1.58 {
            targetIndex = max(0, baseIndex - 2)
        } else if magnification > 1.15 {
            targetIndex = max(0, baseIndex - 1)
        } else if magnification < 0.62 {
            targetIndex = min(counts.count - 1, baseIndex + 2)
        } else if magnification < 0.86 {
            targetIndex = min(counts.count - 1, baseIndex + 1)
        } else {
            targetIndex = baseIndex
        }
        return counts[targetIndex]
    }

    static func gesture(
        columnCount: Binding<Int>,
        liveScale: Binding<CGFloat>,
        baseline: Binding<Int?>,
        counts: [Int] = columnCounts
    ) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if baseline.wrappedValue == nil {
                    baseline.wrappedValue = columnCount.wrappedValue
                }
                let scale = dampedScale(magnification: value.magnification)
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    liveScale.wrappedValue = scale
                }
            }
            .onEnded { value in
                let base = baseline.wrappedValue ?? columnCount.wrappedValue
                let next = Self.columnCount(after: value.magnification, from: base, counts: counts)
                if next != columnCount.wrappedValue {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                withAnimation(ChekiMotion.layoutCommit) {
                    columnCount.wrappedValue = next
                    liveScale.wrappedValue = 1
                }
                baseline.wrappedValue = nil
            }
    }
}

extension View {
    @ViewBuilder
    func gridPinchGesture<G: Gesture>(enabled: Bool, _ gesture: G) -> some View {
        if enabled {
            highPriorityGesture(gesture)
        } else {
            self
        }
    }
}
