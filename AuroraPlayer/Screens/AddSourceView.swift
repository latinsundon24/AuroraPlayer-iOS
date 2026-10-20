import SwiftUI

struct AddSourceView: View {

    @Environment(\.dismiss) private var dismiss

    var onAdd: (String, String) -> Void

    @State private var name: String = ""
    @State private var url: String = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("http://example.com/list.m3u", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                } header: {
                    Text("播放列表网址")
                } footer: {
                    Text("支持 m3u / m3u8 / txt，会自动识别 UTF-8 与 GBK 编码。")
                }

                Section {
                    TextField("名称（可留空）", text: $name)
                } header: {
                    Text("显示名称")
                }
            }
            .navigationTitle("添加在线列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        onAdd(name, url)
                        dismiss()
                    }
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
