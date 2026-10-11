import SwiftUI
import UIKit

/// 全 App 動畫的唯一數字來源。減少動態效果時改為短淡入淡出。
enum ChekiMotion {
    /// 選單切換、勾選、模式切換。
    static var toggle: Animation { resolved(.snappy(duration: 0.22)) }

    /// 小元件展開／收合、重設縮放、放開後回位。
    static var small: Animation { resolved(.spring(response: 0.30, dampingFraction: 0.82)) }

    /// 格狀欄數切換與版面重排。
    static var layoutCommit: Animation {
        resolved(.spring(response: 0.50, dampingFraction: 0.86, blendDuration: 0.15))
    }

    private static func resolved(_ animation: Animation) -> Animation {
        UIAccessibility.isReduceMotionEnabled ? .easeInOut(duration: 0.15) : animation
    }
}
