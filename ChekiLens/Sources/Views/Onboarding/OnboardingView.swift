import SwiftUI

// MARK: - Onboarding Feature Model
private struct OnboardingFeature {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
}

// MARK: - OnboardingView
/// Task 4.1: 使用 iOS 官方 Welcome Screen 模式的導引頁面
/// 採用 SwiftUI 原生 TabView + PageTabViewStyle 實作輪播
struct OnboardingView: View {

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var currentPage = 0

    private let features: [OnboardingFeature] = [
        OnboardingFeature(
            icon: "viewfinder.rectangular",
            iconColor: .blue,
            title: "AI 自動偵測邊框",
            description: "拍下拍立得照片，AI 會自動找出四個角落，精準裁切出完美比例。"
        ),
        OnboardingFeature(
            icon: "photo.stack",
            iconColor: .purple,
            title: "正反面自動配對",
            description: "一次匯入多張照片，系統會自動將正面與背面兩兩配對，省去繁瑣手動操作。"
        ),
        OnboardingFeature(
            icon: "text.viewfinder",
            iconColor: .orange,
            title: "手寫日期 OCR 辨識",
            description: "自動讀取拍立得背面的手寫日期，並同步更新到相簿的時間軸，讓回憶按時間排列。"
        ),
        OnboardingFeature(
            icon: "person.2.crop.square.stack",
            iconColor: .green,
            title: "按偶像分類典藏",
            description: "建立您的成員名冊，讓每張拍立得都歸屬於對應的成員相簿。"
        )
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 60))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.blue)

                    Text("歡迎使用 ChekiLens")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("您的拍立得數位典藏工具")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 60)
                .padding(.bottom, 40)

                // Feature List (Apple 歡迎畫面標準樣式)
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(features, id: \.title) { feature in
                        HStack(alignment: .center, spacing: 18) {
                            Image(systemName: feature.icon)
                                .font(.system(size: 28))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(feature.iconColor)
                                .frame(width: 44, height: 44)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.title)
                                    .font(.body)
                                    .fontWeight(.semibold)

                                Text(feature.description)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)

                Spacer()

                // Continue Button
                Button {
                    hasCompletedOnboarding = true
                } label: {
                    Text("開始使用")
                        .font(.body)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
    }
}

#Preview {
    OnboardingView()
}
