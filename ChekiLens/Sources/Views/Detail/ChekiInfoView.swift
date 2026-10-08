import SwiftUI
import SwiftData
import UIKit

// MARK: - ChekiInfoView (Task 4.6: 06. 情報・備忘 上滑資訊面板)

/// 拍立得資訊與備忘面板
/// - 不顯示重複縮圖（背後主檢視器已呈現拍立得）
/// - 內部資訊（日期、時間、規格、成員、備忘）點擊後可直接修正並即時寫入 SwiftData，無須右上角「完成」按鈕
/// - 日期格式固定為 `yyyy年M月d日 EEEE`（例如 `2025年11月3日 星期一`）
/// - 規格自動歸入三種具體規格之一（`Instax Mini` / `Instax Square` / `Instax Wide`，預設 `Instax Mini`）
/// - 備忘輸入時預設為空白，不自動帶入系統匯入文字
struct ChekiInfoView: View {
    let item: ChekiItem

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \IdolMember.sortOrder, order: .forward) private var idolMembers: [IdolMember]

    @State private var showingQuickCreateMember: Bool = false
    @State private var isEditingDate: Bool = false
    @State private var isEditingTime: Bool = false
    @State private var memoText: String = ""
    @State private var isRecognizingCoverDate: Bool = false
    @FocusState private var isMemoFocused: Bool

    var body: some View {
        List {
            // MARK: 1. 拍攝資訊（點擊各列可直接修正）
            Section("拍攝資訊") {
                // 日期（點擊展開/收合內嵌月曆直接修正，格式：yyyy年M月d日 {星期}）
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.snappy(duration: 0.22)) {
                        isEditingDate.toggle()
                        if isEditingDate {
                            isEditingTime = false
                            isMemoFocused = false
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("日期")
                            .foregroundStyle(.primary)

                        Spacer()

                        if isRecognizingCoverDate {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Text(ChekiItem.formatFullDateWithWeekday(item.displayDate))
                            .foregroundStyle(isEditingDate ? Color.accentColor : .secondary)
                            .fontWeight(isEditingDate ? .semibold : .regular)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isEditingDate {
                    DatePicker(
                        "選擇拍攝日期",
                        selection: dateSelectionBinding,
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.graphical)
                    .environment(\.locale, L10n.formattingLocale)
                    .padding(.vertical, 4)
                }

                // 時間（點擊展開/收合時間滾輪直接修正）
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.snappy(duration: 0.22)) {
                        isEditingTime.toggle()
                        if isEditingTime {
                            isEditingDate = false
                            isMemoFocused = false
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("時間")
                            .foregroundStyle(.primary)

                        Spacer()

                        Text(ChekiDetailView.datePillTimeString(from: item.displayDate))
                            .foregroundStyle(isEditingTime ? Color.accentColor : .secondary)
                            .fontWeight(isEditingTime ? .semibold : .regular)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isEditingTime {
                    DatePicker(
                        "選擇拍攝時間",
                        selection: timeSelectionBinding,
                        displayedComponents: [.hourAndMinute]
                    )
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .frame(height: 148)
                    .clipped()
                }

                // 規格（自動辨識後填入三種其中一種，點擊可直接切換 Instax Mini / Square / Wide）
                HStack {
                    Text("規格")
                        .foregroundStyle(.primary)

                    Spacer()

                    Menu {
                        ForEach(FilmFormat.concreteFormats, id: \.self) { format in
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                item.filmFormat = format
                                item.detectedAspectRatio = format.aspectRatio
                                try? modelContext.save()
                            } label: {
                                HStack {
                                    Text(format.detailDisplayName)
                                    if item.filmFormat.concreteFormat == format {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(item.filmFormat.concreteDisplayName)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                }

                // 成員（點擊可直接切換歸檔成員）
                if true {
                    HStack {
                        Text("成員")
                            .foregroundStyle(.primary)

                        Spacer()

                        Menu {
                            MemberAssignmentMenuContent(item: item) { showingQuickCreateMember = true }
                        } label: {
                            HStack(spacing: 4) {
                                if let memberTitle = item.idolMember?.albumTitle {
                                    Text(memberTitle)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("未分類")
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                    }
                }
            }

            // MARK: 2. 備忘（預設空白，點擊直接輸入並即時儲存）
            Section("備忘") {
                TextField("點擊輸入備忘…", text: $memoText, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($isMemoFocused)
                    .onChange(of: memoText) { _, newValue in
                        saveMemoTextImmediately(newValue)
                    }
            }
        }
        .listStyle(.insetGrouped)
        .sheet(isPresented: $showingQuickCreateMember) {
            QuickCreateIdolSheet()
        }
        .navigationTitle("資訊")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            normalizeLegacyFieldsIfNeeded()
            memoText = sanitizedMemoText(from: item.memo?.noteText)
        }
        .task(id: item.id) {
            await autoRecognizeCoverDateIfNeeded()
        }
        .applyAppAppearanceAndLocale()
    }

    // MARK: - Bindings & Persistence Helpers

    /// 日期選擇器 Binding：修改年、月、日，保留原有的時、分、秒，並同步寫入 SwiftData
    private var dateSelectionBinding: Binding<Date> {
        Binding(
            get: { item.displayDate },
            set: { newDate in
                let merged = ChekiItem.mergeRecognizedDate(newDate, into: item.displayDate)
                item.capturedAt = merged
                if item.ocrDate != nil {
                    item.ocrDate = merged
                }
                try? modelContext.save()
            }
        )
    }

    /// 時間選擇器 Binding：修改時、分，保留原有的年、月、日，並同步寫入 SwiftData
    private var timeSelectionBinding: Binding<Date> {
        Binding(
            get: { item.displayDate },
            set: { newTime in
                let cal = Calendar.current
                let dateComps = cal.dateComponents([.year, .month, .day], from: item.displayDate)
                let timeComps = cal.dateComponents([.hour, .minute, .second], from: newTime)
                var mergedComps = DateComponents()
                mergedComps.year = dateComps.year
                mergedComps.month = dateComps.month
                mergedComps.day = dateComps.day
                mergedComps.hour = timeComps.hour
                mergedComps.minute = timeComps.minute
                mergedComps.second = timeComps.second ?? 0
                if let updated = cal.date(from: mergedComps) {
                    item.capturedAt = updated
                    if item.ocrDate != nil {
                        item.ocrDate = updated
                    }
                    try? modelContext.save()
                }
            }
        )
    }

    /// 清除舊版自動塞入的系統匯入文字（「透過批次配對工作台…」），並確保規格落入三種具體規格之一
    private func normalizeLegacyFieldsIfNeeded() {
        var didMutate = false

        // 1. 若舊資料為 `.auto`（自動識別），自動正規化為具體規格（預設 Instax Mini）
        if item.filmFormat == .auto {
            var imgSize: CGSize? = nil
            if let data = item.frontImageData, let img = UIImage(data: data) {
                imgSize = img.size
            }
            let concrete = FilmFormat.resolvedConcreteFormat(
                preferred: .auto,
                specName: nil,
                outputSize: imgSize
            )
            item.filmFormat = concrete
            item.detectedAspectRatio = concrete.aspectRatio
            didMutate = true
        }

        // 2. 若舊資料帶有系統自動產生的匯入說明文字，自動清空讓備忘保持空白
        if let memo = item.memo {
            if let rawNote = memo.noteText, Self.isSystemGeneratedNote(rawNote) {
                memo.noteText = nil
                didMutate = true
            }
            if memo.eventName == "批次配對匯入" {
                memo.eventName = nil
                didMutate = true
            }
            memo.hashtags.removeAll {
                $0 == "#雙面配對" || $0 == "#批次匯入" || $0 == "#單面匯入"
            }
        }

        if didMutate {
            try? modelContext.save()
        }
    }

    private func sanitizedMemoText(from note: String?) -> String {
        guard let note, !Self.isSystemGeneratedNote(note) else { return "" }
        return note
    }

    private static func isSystemGeneratedNote(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("透過批次配對工作台") || trimmed.hasPrefix("透過批次工作台")
    }

    private func saveMemoTextImmediately(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let memo = item.memo {
            memo.noteText = trimmed.isEmpty ? nil : text
            memo.updatedAt = Date()
        } else if !trimmed.isEmpty {
            let newMemo = ChekiMemo(
                eventName: nil,
                noteText: text,
                hashtags: [],
                chekiItem: item
            )
            item.memo = newMemo
            modelContext.insert(newMemo)
        }
        try? modelContext.save()
    }

    /// 若該拍立得尚未有手寫日期紀錄，自動從拍立得封面辨識手寫日期並填入拍攝日期
    @MainActor
    private func autoRecognizeCoverDateIfNeeded() async {
        guard item.ocrDate == nil else { return }
        guard let data = item.frontImageData ?? item.originalFrontImageData,
              let uiImage = UIImage(data: data)?.normalizedImage,
              let cgImage = uiImage.cgImage else { return }

        isRecognizingCoverDate = true
        defer { isRecognizingCoverDate = false }

        let visionManager = VisionManager()
        if let ocrResult = await visionManager.recognizeDate(from: cgImage) {
            let mergedDate = ChekiItem.mergeRecognizedDate(ocrResult.date, into: item.capturedAt)
            item.ocrDate = mergedDate
            item.capturedAt = mergedDate
            try? modelContext.save()
        } else if let origData = item.originalFrontImageData,
                  origData != data,
                  let origUI = UIImage(data: origData)?.normalizedImage,
                  let origCG = origUI.cgImage,
                  let fallbackResult = await visionManager.recognizeDate(from: origCG) {
            let mergedDate = ChekiItem.mergeRecognizedDate(fallbackResult.date, into: item.capturedAt)
            item.ocrDate = mergedDate
            item.capturedAt = mergedDate
            try? modelContext.save()
        }
    }
}

