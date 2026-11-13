import SwiftUI

struct ContentView: View {
    @StateObject private var assistant = AssistantModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false
    @State private var speakingUntil = Date.distantPast
    @State private var holding = false
    @FocusState private var editing: Bool

    private var waiting: Bool { assistant.isBusy && (assistant.status.hasPrefix("正在请求回答") || assistant.status.hasPrefix("正在通过 HTTP")) }
    private var statusColor: Color {
        if assistant.isListening { return Color(red: 0.47, green: 0.94, blue: 0.78) }
        if assistant.isBusy { return Color(red: 1, green: 0.83, blue: 0.54) }
        if assistant.status.contains("失败") || assistant.status.contains("不可用") || assistant.status.contains("需要") { return Color(red: 1, green: 0.6, blue: 0.62) }
        return Color(red: 0.65, green: 0.76, blue: 0.84)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(red: 0.025, green: 0.055, blue: 0.11), Color(red: 0.035, green: 0.12, blue: 0.19), Color(red: 0.015, green: 0.035, blue: 0.075)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
                TimelineView(.animation(minimumInterval: 0.05, paused: scenePhase != .active)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    ZStack {
                        if waiting { Ripple(time: time).allowsHitTesting(false) }
                        Mascot(time: time, listening: assistant.isListening, speaking: assistant.isSpeaking)
                            .frame(width: min(geometry.size.width - 48, geometry.size.height * 0.65), height: min(geometry.size.width - 48, geometry.size.height * 0.65))
                            .contentShape(Rectangle())
                            .onLongPressGesture(minimumDuration: 5, maximumDistance: 20, pressing: { holding = $0 }, perform: {
                                speakingUntil = .distantPast
                                assistant.stopAll()
                                showingSettings = true
                            })
                            .accessibilityLabel("小智吉祥物")
                            .accessibilityHint("长按五秒打开设置")
                            .accessibilityAction(named: Text("打开设置")) { assistant.stopAll(); showingSettings = true }
                    }
                }
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: assistant.isListening ? "mic.fill" : "mic.slash.fill")
                        Text(assistant.status).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.black.opacity(0.55), in: Capsule())
                    Spacer(minLength: 0)
                    Text(holding ? "继续按住 5 秒进入设置" : "长按吉祥物 5 秒进入设置")
                        .font(.caption).foregroundStyle(.white.opacity(0.65))
                    if !assistant.messages.isEmpty {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 12) {
                                    ForEach(assistant.messages) { message in
                                        Text("\(message.role == "user" ? "你说" : "小智")：\(message.content)")
                                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).id(message.id)
                                    }
                                }.padding(14)
                            }
                            .frame(maxHeight: min(180, geometry.size.height * 0.23))
                            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 16))
                            .onChange(of: assistant.messages.count) { _, _ in
                                if let id = assistant.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                            }
                        }
                    }
                    if !assistant.messages.isEmpty {
                        Color.clear.frame(height: 1)
                    }
                }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear { assistant.startAutoListening() }
        .sheet(isPresented: $showingSettings) { SettingsView(assistant: assistant) }
        .onChange(of: assistant.messages.count) { _, _ in
            if let message = assistant.messages.last, message.role == "assistant" {
                // AssistantModel does not expose TTS callbacks; estimate the animation duration.
                speakingUntil = Date().addingTimeInterval(min(120, max(2, Double(message.content.count) / 4)))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { speakingUntil = .distantPast; assistant.stopAll() }
            else if !showingSettings { assistant.startAutoListening() }
        }
    }
}

private struct Ripple: View {
    let time: TimeInterval
    var body: some View {
        GeometryReader { geometry in
            let radius = min(geometry.size.width, geometry.size.height) * 0.55
            ZStack {
                ForEach(0..<3) { index in
                    let phase = CGFloat((time / 2.4 + Double(index) / 3).truncatingRemainder(dividingBy: 1))
                    Circle().stroke(Color(red: 0.36, green: 0.84, blue: 0.96).opacity(Double(1 - phase) * 0.43), lineWidth: 2)
                        .frame(width: radius * (0.25 + phase) * 2, height: radius * (0.25 + phase) * 2)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.clipped()
    }
}

private struct Mascot: View {
    let time: TimeInterval
    let listening: Bool
    let speaking: Bool
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 240
            context.scaleBy(x: scale, y: scale)
            func fill(_ path: Path, _ color: Color) { context.fill(path, with: .color(color)) }
            var antenna = Path(); antenna.move(to: CGPoint(x: 120, y: 32)); antenna.addLine(to: CGPoint(x: 120, y: 51))
            context.stroke(antenna, with: .color(Color(red: 0.44, green: 0.73, blue: 0.92)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            fill(Path(ellipseIn: CGRect(x: 111, y: 22, width: 18, height: 18)), Color(red: 1, green: 0.8, blue: 0.44))
            fill(Path(roundedRect: CGRect(x: 24, y: 99, width: 30, height: 58), cornerRadius: 15), Color(red: 0.53, green: 0.82, blue: 1))
            fill(Path(roundedRect: CGRect(x: 186, y: 99, width: 30, height: 58), cornerRadius: 15), Color(red: 0.53, green: 0.82, blue: 1))
            fill(Path(roundedRect: CGRect(x: 46, y: 49, width: 148, height: 146), cornerRadius: 48), Color(red: 0.35, green: 0.72, blue: 0.96))
            fill(Path(roundedRect: CGRect(x: 58, y: 64, width: 124, height: 107), cornerRadius: 38), .white)
            for x in [80.0, 144.0] { fill(Path(ellipseIn: CGRect(x: x, y: 105, width: 16, height: 22)), Color(red: 0.094, green: 0.235, blue: 0.392)) }
            for x in [60.0, 160.0] { fill(Path(ellipseIn: CGRect(x: x, y: 133, width: 20, height: 10)), Color(red: 1, green: 0.74, blue: 0.78)) }
            let mouth = Color(red: 0.196, green: 0.38, blue: 0.53)
            if speaking {
                let height = 2.5 + 4 * (sin(time / 0.13) + 1) / 2
                fill(Path(ellipseIn: CGRect(x: 111, y: 143 - height, width: 18, height: height * 2)), mouth)
            } else {
                var smile = Path(); smile.move(to: CGPoint(x: 108, y: 139)); smile.addQuadCurve(to: CGPoint(x: 132, y: 139), control: CGPoint(x: 120, y: 151))
                context.stroke(smile, with: .color(mouth), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            if listening {
                let pulse = (sin(time / 0.45) + 1) / 2
                for radius in [17.0, 24.0] {
                    var arc = Path(); arc.addArc(center: CGPoint(x: 120, y: 30), radius: radius, startAngle: .degrees(205), endAngle: .degrees(335), clockwise: false)
                    context.stroke(arc, with: .color(Color.cyan.opacity(0.35 + pulse * 0.5)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
            }
        }.aspectRatio(1, contentMode: .fit)
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
                    Text("密钥保存在设备 Keychain；问题会发送到所设置的服务。局域网 HTTP 不加密，请仅在可信网络使用。")
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
