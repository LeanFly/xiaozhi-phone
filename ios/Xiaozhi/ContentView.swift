import SwiftUI

struct ContentView: View {
    @StateObject private var assistant = AssistantModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(assistant.messages) { message in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(message.role == "user" ? "你" : "小智").font(.caption).foregroundStyle(.secondary)
                                    Text(message.content).textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(message.role == "user" ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .id(message.id)
                            }
                        }.padding(.vertical, 4)
                    }
                    .onChange(of: assistant.messages.count) { _, _ in
                        if let id = assistant.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                    }
                }
                Text(assistant.status).font(.footnote).foregroundStyle(.secondary)
                TextField("识别结果或输入问题", text: $assistant.transcript, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.roundedBorder)
                    .disabled(assistant.isListening || assistant.isBusy)
                HStack {
                    Button(assistant.isListening ? "停止识别" : "开始说话") {
                        if assistant.isListening { assistant.stopListening() } else { assistant.startListening() }
                    }.disabled(assistant.isBusy)
                    Spacer()
                    Button("发送") { assistant.send() }
                        .buttonStyle(.borderedProminent)
                        .disabled(assistant.isListening || assistant.isBusy)
                    Button("停止") { assistant.stopAll() }
                }
            }
            .padding()
            .navigationTitle("小智")
            .toolbar { Button("设置") { showingSettings = true } }
            .sheet(isPresented: $showingSettings) { SettingsView(assistant: assistant) }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { assistant.stopAll() }
            }
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var assistant: AssistantModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var model = ""
    @State private var key = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("OpenAI 兼容接口") {
                    TextField("HTTPS 基础地址，例如 https://api.openai.com/v1", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("模型", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API 密钥", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Text("密钥保存在设备 Keychain；问题与对话历史会发送到所设置的服务。仅支持 HTTPS。")
                        .font(.footnote)
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        assistant.baseURL = address; assistant.model = model; assistant.apiKey = key
                        assistant.saveSettings(); dismiss()
                    }
                }
            }
            .onAppear { address = assistant.baseURL; model = assistant.model; key = assistant.apiKey }
        }
    }
}
