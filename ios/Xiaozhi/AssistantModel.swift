import Foundation
import SwiftUI
import Speech
import AVFoundation
import Security

struct ChatMessage: Identifiable, Encodable {
    let id: UUID
    let role: String
    let content: String
    init(role: String, content: String) {
        self.id = UUID(); self.role = role; self.content = content
    }
    enum CodingKeys: String, CodingKey { case role, content }
}

private enum KeyStore {
    private static let account = "openai-api-key"
    static func load() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Xiaozhi", kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Xiaozhi", kSecAttrAccount as String: account]
        let data = Data(value.utf8)
        let status: OSStatus
        if value.isEmpty {
            status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }
    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "密钥保存失败（Keychain 状态 \(status)）。" }
    }
}

@MainActor
final class AssistantModel: ObservableObject {
    @Published var baseURL = UserDefaults.standard.string(forKey: "baseURL") ?? "https://api.openai.com/v1"
    @Published var model = UserDefaults.standard.string(forKey: "model") ?? "gpt-4o-mini"
    @Published var apiKey = KeyStore.load()
    @Published var messages: [ChatMessage] = []
    @Published var transcript = ""
    @Published var status = "点击开始说话，结束后点击发送语音。"
    @Published var isListening = false
    @Published var isBusy = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let engine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var networkTask: Task<Void, Never>?
    private var generation = UUID()
    private var tapInstalled = false

    func saveSettings() {
        do {
            try KeyStore.save(apiKey)
            UserDefaults.standard.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "baseURL")
            UserDefaults.standard.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "model")
            status = "设置已保存。"
        } catch { status = error.localizedDescription }
    }

    func startListening() {
        guard !isListening && !isBusy else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let token = UUID(); generation = token
        isBusy = true
        status = "正在请求权限…"
        Task {
            let speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            let microphone = await AVAudioApplication.requestRecordPermission()
            guard generation == token else { return }
            isBusy = false
            guard speech == .authorized, microphone else {
                status = "需要语音识别和麦克风权限，请在系统设置中允许。"; return
            }
            guard let recognizer, recognizer.isAvailable else {
                status = "中文语音识别当前不可用，请检查设备与系统设置。"; return
            }
            guard recognizer.supportsOnDeviceRecognition else {
                status = "此设备当前不支持中文本地语音识别，不会使用云端识别。"; return
            }
            do {
                transcript = ""
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true)
                let audioRequest = SFSpeechAudioBufferRecognitionRequest()
                audioRequest.requiresOnDeviceRecognition = true
                audioRequest.shouldReportPartialResults = true
                request = audioRequest
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0 && format.channelCount > 0 else {
                    throw AssistantError.message("麦克风音频格式不可用。")
                }
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                    audioRequest.append(buffer)
                }
                tapInstalled = true
                recognitionTask = recognizer.recognitionTask(with: audioRequest) { [weak self] result, error in
                    let text = result?.bestTranscription.formattedString
                    let final = result?.isFinal ?? false
                    let errorText = error?.localizedDescription
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token else { return }
                        if let text { self.transcript = text }
                        if let errorText {
                            self.stopCapture(cancel: true)
                            self.status = "本地识别失败：\(errorText)"
                        } else if final {
                            self.stopCapture(cancel: true)
                            self.status = "识别结束，请检查文本并发送。"
                        }
                    }
                }
                engine.prepare()
                try engine.start()
                isListening = true
                status = "正在本机识别；点击停止后可检查并发送。"
            } catch {
                stopCapture(cancel: true)
                status = "无法启动本地识别：\(error.localizedDescription)"
            }
        }
    }

    func stopListening() {
        guard isListening else { return }
        // Keep the current partial transcription; cancel prevents late callbacks overwriting edits.
        generation = UUID()
        stopCapture(cancel: true)
        status = "识别已停止，请检查文本并发送。"
    }

    private func stopCapture(cancel: Bool) {
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio()
        if cancel { recognitionTask?.cancel() }
        recognitionTask = nil; request = nil; isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func send() {
        guard !isBusy, !isListening else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { status = "请输入或识别问题。"; return }
        guard let url = endpoint(), !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "请在设置中填写有效的 HTTPS 接口地址和模型。"; return
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { status = "请先在设置中填写 API 密钥。"; return }
        let userMessage = ChatMessage(role: "user", content: text)
        let outgoing = messages + [userMessage]
        messages.append(userMessage); transcript = ""; isBusy = true
        status = "正在请求回答…"
        let token = UUID(); generation = token
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        networkTask = Task {
            do {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.timeoutInterval = 60
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                req.httpBody = try JSONEncoder().encode(ChatRequest(model: selectedModel, messages: outgoing))
                let (data, response) = try await URLSession.shared.data(for: req)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw AssistantError.message("接口返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)。")
                }
                let result = try JSONDecoder().decode(ChatResponse.self, from: data)
                guard let answer = result.choices.first?.message.content, !answer.isEmpty else {
                    throw AssistantError.message("接口未返回文本回答。")
                }
                guard generation == token else { return }
                messages.append(ChatMessage(role: "assistant", content: answer))
                isBusy = false; status = "回答完成。"
                let utterance = AVSpeechUtterance(string: answer)
                utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
                synthesizer.speak(utterance)
            } catch {
                guard generation == token else { return }
                isBusy = false
                // Remove failed turn so retrying does not duplicate it in the history.
                if messages.last?.id == userMessage.id { messages.removeLast() }
                transcript = text
                status = "请求失败：\(error.localizedDescription)"
            }
        }
    }

    func stopAll() {
        generation = UUID()
        networkTask?.cancel(); networkTask = nil
        if isBusy, let last = messages.last, last.role == "user" {
            transcript = last.content
            messages.removeLast()
        }
        stopCapture(cancel: true)
        synthesizer.stopSpeaking(at: .immediate)
        isBusy = false
        status = "已停止。"
    }

    private func endpoint() -> URL? {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value), components.scheme?.lowercased() == "https",
              components.host != nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
        components.path = path
        return components.url
    }

    private struct ChatRequest: Encodable { let model: String; let messages: [ChatMessage] }
    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }
    private enum AssistantError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}
