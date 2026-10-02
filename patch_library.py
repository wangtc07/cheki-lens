import re

with open('ChekiLens/Sources/Views/Library/LibraryView.swift', 'r') as f:
    content = f.read()

toolbar_old = """            .navigationTitle("典藏")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    // PhotosPicker (系統原生選圖介面，無需自刻)
                    PhotosPicker(
                        selection: $selectedPhotos,
                        maxSelectionCount: 50,
                        matching: .images,
                        preferredItemEncoding: .automatic
                    ) {
                        Label("匯入", systemImage: "plus")
                    }
                    .onChange(of: selectedPhotos) { _, newItems in
                        guard !newItems.isEmpty else { return }
                        processingItems = newItems
                        selectedPhotos = []
                        Task { await processImportedPhotos(processingItems) }
                    }
                }
            }
            .overlay {"""

toolbar_new = """            .navigationTitle(isSelectionMode ? "已選取 \(selectedItemIDs.count) 張" : "典藏")
            .navigationBarTitleDisplayMode(isSelectionMode ? .inline : .large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if isSelectionMode {
                        Button(selectedItemIDs.count == chekiItems.count ? "取消全選" : "全選") {
                            if selectedItemIDs.count == chekiItems.count {
                                selectedItemIDs.removeAll()
                            } else {
                                selectedItemIDs = Set(chekiItems.map { $0.id })
                            }
                        }
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        if !chekiItems.isEmpty {
                            Button(isSelectionMode ? "取消" : "選取") {
                                withAnimation {
                                    isSelectionMode.toggle()
                                    if !isSelectionMode {
                                        selectedItemIDs.removeAll()
                                    }
                                }
                            }
                        }
                        
                        if !isSelectionMode {
                            PhotosPicker(
                                selection: $selectedPhotos,
                                maxSelectionCount: 50,
                                matching: .images,
                                preferredItemEncoding: .automatic
                            ) {
                                Image(systemName: "plus")
                                    .font(.title3)
                            }
                            .onChange(of: selectedPhotos) { _, newItems in
                                guard !newItems.isEmpty else { return }
                                processingItems = newItems
                                selectedPhotos = []
                                Task { await processImportedPhotos(processingItems) }
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelectionMode {
                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(selectedItemIDs.isEmpty)
                    }
                    .padding()
                    .background(.bar)
                }
            }
            .confirmationDialog("確定要刪除選取的 \(selectedItemIDs.count) 張照片嗎？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("刪除", role: .destructive) {
                    deleteSelectedItems()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此操作無法復原。")
            }
            .overlay {"""

content = content.replace(toolbar_old, toolbar_new)

grid_old = """    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 2) {
                ForEach(chekiItems) { item in
                    NavigationLink(value: item) {
                        ChekiThumbnailView(item: item)
                    }
                }
            }
        }
        .navigationDestination(for: ChekiItem.self) { item in
            ChekiDetailView(item: item)
        }
    }"""

grid_new = """    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 2) {
                ForEach(chekiItems) { item in
                    if isSelectionMode {
                        ChekiThumbnailView(item: item)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: selectedItemIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .foregroundStyle(selectedItemIDs.contains(item.id) ? .blue : .white.opacity(0.8))
                                    .padding(8)
                            }
                            .onTapGesture {
                                if selectedItemIDs.contains(item.id) {
                                    selectedItemIDs.remove(item.id)
                                } else {
                                    selectedItemIDs.insert(item.id)
                                }
                            }
                    } else {
                        NavigationLink(value: item) {
                            ChekiThumbnailView(item: item)
                        }
                    }
                }
            }
        }
        .navigationDestination(for: ChekiItem.self) { item in
            ChekiDetailView(item: item)
        }
    }
    
    private func deleteSelectedItems() {
        for item in chekiItems where selectedItemIDs.contains(item.id) {
            modelContext.delete(item)
        }
        try? modelContext.save()
        withAnimation {
            isSelectionMode = false
            selectedItemIDs.removeAll()
        }
    }"""

content = content.replace(grid_old, grid_new)

with open('ChekiLens/Sources/Views/Library/LibraryView.swift', 'w') as f:
    f.write(content)
