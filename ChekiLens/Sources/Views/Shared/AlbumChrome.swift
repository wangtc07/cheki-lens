import SwiftUI
import UIKit

// MARK: - 共用圖示：攝影追加（Apple 原生 SF Symbol `camera`）

enum AppIcons {
    static let cameraAddSymbolName = "camera"

    static var cameraAddImage: Image {
        Image(systemName: cameraAddSymbolName)
    }
}

// MARK: - 共用標籤

/// 攝影追加（所有「拍照追加」入口共用）
struct CameraAddLabel: View {
    var body: some View {
        Label(L10n.tr("拍照", "カメラ"), systemImage: AppIcons.cameraAddSymbolName)
    }
}

/// 從相冊讀入（所有「相簿匯入」入口共用）
struct AlbumImportLabel: View {
    var body: some View {
        Label(L10n.tr("相簿", "アルバム"), systemImage: "photo.badge.plus")
    }
}

// MARK: - 共用選單項目

/// 「攝影追加」與「從相冊讀入」兩個按鈕（長按選單、漢堡選單共用）
struct AlbumAddMenuItems: View {
    let onCamera: () -> Void
    let onImport: () -> Void

    var body: some View {
        Button(action: onCamera) { CameraAddLabel() }
        Button(action: onImport) { AlbumImportLabel() }
    }
}

/// 「排序」與「顯示」兩個子選單（團體／成員層級共用）
struct AlbumSortDisplayMenus: View {
    @Binding var sortMethodRaw: String
    @Binding var displayModeRaw: String

    private var sortMethod: AlbumSortMethod { AlbumSortMethod(rawValue: sortMethodRaw) ?? .custom }
    private var displayMode: AlbumDisplayMode { AlbumDisplayMode(rawValue: displayModeRaw) ?? .grid }

    var body: some View {
        Menu {
            ForEach(AlbumSortMethod.allCases) { method in
                Button {
                    withAnimation(.snappy(duration: 0.22)) { sortMethodRaw = method.rawValue }
                } label: {
                    if sortMethod == method {
                        Label(method.displayName, systemImage: "checkmark")
                    } else {
                        Text(method.displayName)
                    }
                }
            }
        } label: {
            Label(L10n.tr("排序", "並び順"), systemImage: "arrow.up.arrow.down")
        }

        Menu {
            ForEach(AlbumDisplayMode.allCases) { mode in
                Button {
                    withAnimation(.snappy(duration: 0.22)) { displayModeRaw = mode.rawValue }
                } label: {
                    Label(mode.displayName, systemImage: displayMode == mode ? "checkmark" : mode.iconName)
                }
            }
        } label: {
            Label(L10n.tr("顯示", "表示"), systemImage: displayMode.iconName)
        }
    }
}

/// 設定按鈕
struct SettingsMenuButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("設定", systemImage: "gearshape")
        }
    }
}

// MARK: - 共用導覽列右上按鈕（`+` | `⋯`，相冊／團體頁共用）

struct AlbumNavTrailingToolbar<MenuContent: View>: ToolbarContent {
    let onCreate: () -> Void
    @ViewBuilder let menuContent: () -> MenuContent

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(action: onCreate) {
                Image(systemName: "plus")
            }
            .accessibilityLabel("團體 / 成員")

            Menu {
                menuContent()
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("更多")
        }
    }
}

// MARK: - 全 App 共用液態玻璃 (Liquid Glass) 按鈕與膠囊修飾器

struct OptionalLiquidGlassCapsuleModifier: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.liquidGlassCapsule()
        } else {
            content
        }
    }
}
