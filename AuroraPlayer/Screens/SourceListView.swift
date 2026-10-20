import SwiftUI
import UniformTypeIdentifiers

struct SourceListView: View {

    @EnvironmentObject private var store: Store

    @State private var showAddURL = false
    @State private var showImporter = false
    @State private var busy = false
    @State private var showAlert = false
    @State private var alertText = ""

    var body: some View {
        NavigationView {
            List {
                ForEach(store.sources) { source in
                    NavigationLink(destination: ChannelListView(source: source)) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(source.name)
                                .font(.headline)
                            Text("\(source.kindText) · \(source.count) 频道")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .contextMenu {
                        if source.kind == .url {
                            Button("刷新") { refresh(source) }
                        }
                        Button("删除", role: .destructive) {
                            store.remove(source)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("极光播放器")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showAddURL = true
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            }
            .overlay(
                Group {
                    if store.sources.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "film.stack")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text("暂无播放列表")
                                .font(.headline)
                            Text("点右上角 ＋ 添加在线 m3u/txt\n或点 ⤓ 导入本地文件")
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                                .foregroundColor(.secondary)
                        }
                        .padding(30)
                    }
                }
            )
            .overlay(
                Group {
                    if busy {
                        ProgressView()
                            .scaleEffect(1.6)
                            .padding(24)
                            .background(Color.black.opacity(0.55))
                            .cornerRadius(12)
                    }
                }
            )
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showAddURL) {
            AddSourceView { name, url in
                addOnline(name: name, url: url)
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType.item],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert(isPresented: $showAlert) {
            Alert(title: Text("提示"), message: Text(alertText), dismissButton: .default(Text("好")))
        }
    }

    // MARK: - 在线添加

    private func addOnline(name: String, url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed), parsed.scheme != nil else {
            show("网址无效")
            return
        }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = Source(
            name: title.isEmpty ? PlaylistParser.deriveName(trimmed) : title,
            kind: .url,
            location: trimmed
        )
        store.add(source)
        refresh(source)
    }

    private func refresh(_ source: Source) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let text = try HTTPService.fetchSync(source.location)
                let channels = PlaylistParser.parse(text)
                DispatchQueue.main.async {
                    var updated = source
                    updated.count = channels.count
                    updated.updatedAt = Date()
                    store.save(channels: channels, for: updated)
                    store.update(updated)
                    busy = false
                    if channels.isEmpty {
                        show("未解析到频道，请检查列表格式")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    show("拉取失败：\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - 本地导入

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                let text = HTTPService.decode(data)
                let channels = PlaylistParser.parse(text)
                var source = Source(
                    name: url.deletingPathExtension().lastPathComponent,
                    kind: .file,
                    location: url.lastPathComponent
                )
                source.count = channels.count
                store.add(source)
                store.save(channels: channels, for: source)
                show("已导入 \(channels.count) 个频道")
            } catch {
                show("导入失败：\(error.localizedDescription)")
            }
        case .failure(let error):
            show("选择文件失败：\(error.localizedDescription)")
        }
    }

    private func show(_ text: String) {
        alertText = text
        showAlert = true
    }
}
