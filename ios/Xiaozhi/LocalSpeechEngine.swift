import Foundation
import AVFoundation
import SherpaOnnxC

/// Local, offline wake-word + SenseVoice speech engine.
/// Bundle resources are expected at `kws/` and `sense/` (directory resources).
/// KWS continuously listens; after a keyword trigger it collects one utterance,
/// decodes it with SenseVoice, and calls `completion` on the main queue.
public final class LocalSpeechEngine {
    public typealias Completion = (String) -> Void

    private let workQueue = DispatchQueue(label: "xiaozhi.local-speech-engine", qos: .userInitiated)
    private let audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var kws: UnsafePointer<SherpaOnnxKeywordSpotter>?
    private var kwsStream: UnsafePointer<SherpaOnnxOnlineStream>?
    private var asr: UnsafePointer<SherpaOnnxOfflineRecognizer>?
    private var running = false
    private var stopping = false
    private var collecting = false
    private var utterance: [Float] = []
    private var utteranceSamples = 0
    private var silenceSamples = 0
    private var completion: Completion?
    private let keyword: String?
    private let maxUtteranceSeconds: Double

    private static let sampleRate = 16_000
    private static let featureDim = 80
    private static let tapBufferFrames: AVAudioFrameCount = 2_048

    /// `keyword` is optional when the kws model's keywords.txt already defines it.
    public init(keyword: String? = nil, maxUtteranceSeconds: Double = 8.0) {
        self.keyword = keyword
        self.maxUtteranceSeconds = max(1.0, maxUtteranceSeconds)
    }

    /// Starts microphone capture. `completion` is invoked once per detected utterance.
    public func start(completion: @escaping Completion) throws {
        try workQueue.sync {
            guard !running else { return }
            self.completion = completion
            try configureModels()
            let input = audioEngine.inputNode
            guard let format = input.inputFormat(forBus: 0).copy() as? AVAudioFormat,
                  format.sampleRate > 0 else {
                throw EngineError.microphoneUnavailable
            }
            inputFormat = format
            converter = AVAudioConverter(from: format,
                                         to: AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                           sampleRate: Double(Self.sampleRate),
                                                           channels: 1,
                                                           interleaved: false)!)
            guard converter != nil else { throw EngineError.converterUnavailable }
            input.installTap(onBus: 0, bufferSize: Self.tapBufferFrames, format: format) { [weak self] buffer, _ in
                self?.convertAndEnqueue(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            running = true
        }
    }

    /// Stops capture and releases all native sherpa-onnx handles.
    public func stop() {
        workQueue.sync {
            stopLocked()
        }
    }

    deinit { stop() }

    private func stopLocked() {
        guard !stopping else { return }
        stopping = true
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        if let s = kwsStream { SherpaOnnxDestroyOnlineStream(s) }
        if let k = kws { SherpaOnnxDestroyKeywordSpotter(k) }
        if let a = asr { SherpaOnnxDestroyOfflineRecognizer(a) }
        kwsStream = nil; kws = nil; asr = nil
        converter = nil; inputFormat = nil; utterance.removeAll(keepingCapacity: false)
        utteranceSamples = 0; silenceSamples = 0; collecting = false; running = false
        completion = nil
        stopping = false
    }

    private func convertAndEnqueue(_ buffer: AVAudioPCMBuffer) {
        workQueue.async { [weak self] in
            guard let self, self.running || self.audioEngine.isRunning else { return }
            guard let converter = self.converter else { return }
            let ratio = Double(Self.sampleRate) / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 8
            guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }
            var error: NSError?
            var supplied = false
            converter.convert(to: out, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return buffer
            }
            guard error == nil, let samples = out.floatChannelData?[0], out.frameLength > 0 else { return }
            self.process(Array(UnsafeBufferPointer(start: samples, count: Int(out.frameLength))))
        }
    }

    private func process(_ samples: [Float]) {
        guard let kws, let stream = kwsStream else { return }
        samples.withUnsafeBufferPointer {
            SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(Self.sampleRate), $0.baseAddress, Int32($0.count))
        }
        while SherpaOnnxIsKeywordStreamReady(kws, stream) != 0 {
            SherpaOnnxDecodeKeywordStream(kws, stream)
        }
        if !collecting {
            guard let result = SherpaOnnxGetKeywordResult(kws, stream) else { return }
            let hit = result.pointee.keyword.map(String.init(cString:)) ?? ""
            SherpaOnnxDestroyKeywordResult(result)
            guard !hit.isEmpty else { return }
            collecting = true
            utterance.removeAll(keepingCapacity: true)
            utteranceSamples = 0
            silenceSamples = 0
            SherpaOnnxResetKeywordStream(kws, stream)
        }
        if collecting {
            utterance.append(contentsOf: samples)
            utteranceSamples += samples.count
            let energy = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count)))
            silenceSamples = energy < 0.012 ? silenceSamples + samples.count : 0
            let reachedSilence = utteranceSamples > Self.sampleRate / 2 && silenceSamples >= Self.sampleRate * 8 / 10
            if reachedSilence || Double(utteranceSamples) / Double(Self.sampleRate) >= maxUtteranceSeconds {
                recognizeAndFinish()
            }
        }
    }

    private func recognizeAndFinish() {
        guard let asr, !utterance.isEmpty else { collecting = false; return }
        let audio = utterance
        collecting = false; utterance.removeAll(keepingCapacity: true); utteranceSamples = 0; silenceSamples = 0
        guard let stream = SherpaOnnxCreateOfflineStream(asr) else { return }
        audio.withUnsafeBufferPointer {
            SherpaOnnxAcceptWaveformOffline(stream, Int32(Self.sampleRate), $0.baseAddress, Int32($0.count))
        }
        SherpaOnnxDecodeOfflineStream(asr, stream)
        var text = ""
        if let result = SherpaOnnxGetOfflineStreamResult(stream) {
            text = result.pointee.text.map(String.init(cString:))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            SherpaOnnxDestroyOfflineRecognizerResult(result)
        }
        SherpaOnnxDestroyOfflineStream(stream)
        guard !text.isEmpty else { return }
        let callback = completion
        DispatchQueue.main.async { callback?(text) }
    }

    private func configureModels() throws {
        guard let kwsDir = Bundle.main.url(forResource: "kws", withExtension: nil),
              let senseDir = Bundle.main.url(forResource: "sense", withExtension: nil) else {
            throw EngineError.missingModelDirectory
        }
        let ef = try Self.modelFile(in: kwsDir, names: ["encoder-epoch-12-avg-2-chunk-16-left-64.onnx", "encoder.onnx", "encoder.int8.onnx"])
        let df = try Self.modelFile(in: kwsDir, names: ["decoder-epoch-12-avg-2-chunk-16-left-64.onnx", "decoder.onnx", "decoder.int8.onnx"])
        let jf = try Self.modelFile(in: kwsDir, names: ["joiner-epoch-12-avg-2-chunk-16-left-64.onnx", "joiner.onnx", "joiner.int8.onnx"])
        let kt = try Self.modelFile(in: kwsDir, names: ["tokens.txt"])
        let kw = try Self.modelFile(in: kwsDir, names: ["keywords.txt"])
        let sm = try Self.modelFile(in: senseDir, names: ["model.int8.onnx", "model.onnx"])
        let st = try Self.modelFile(in: senseDir, names: ["tokens.txt"])

        var kc = SherpaOnnxKeywordSpotterConfig()
        kc.feat_config.sample_rate = Int32(Self.sampleRate); kc.feat_config.feature_dim = Int32(Self.featureDim)
        kc.max_active_paths = 4; kc.num_trailing_blanks = 1; kc.keywords_score = 3; kc.keywords_threshold = 0.1
        var ac = SherpaOnnxOfflineRecognizerConfig()
        ac.feat_config.sample_rate = Int32(Self.sampleRate); ac.feat_config.feature_dim = Int32(Self.featureDim)
        ac.decoding_method = strdup("greedy_search")
        ef.path.withCString { e in df.path.withCString { d in jf.path.withCString { j in kt.path.withCString { t in kw.path.withCString { w in
            kc.model_config.transducer.encoder = e; kc.model_config.transducer.decoder = d; kc.model_config.transducer.joiner = j
            kc.model_config.tokens = t; kc.keywords_file = w; kc.model_config.provider = strdup("cpu"); kc.model_config.num_threads = 2
            kws = SherpaOnnxCreateKeywordSpotter(&kc)
        }}}}}
        guard let kws else { throw EngineError.modelLoadFailed("kws") }
        kwsStream = keyword?.withCString { SherpaOnnxCreateKeywordStreamWithKeywords(kws, $0) } ?? SherpaOnnxCreateKeywordStream(kws)
        st.path.withCString { t in sm.path.withCString { m in
            ac.model_config.tokens = t; ac.model_config.provider = strdup("cpu"); ac.model_config.num_threads = 2
            ac.model_config.sense_voice.model = m; ac.model_config.sense_voice.language = strdup("auto"); ac.model_config.sense_voice.use_itn = 1
            asr = SherpaOnnxCreateOfflineRecognizer(&ac)
        }}
        guard asr != nil, kwsStream != nil else { throw EngineError.modelLoadFailed("sense") }
    }

    private static func modelFile(in directory: URL, names: [String]) throws -> URL {
        let fm = FileManager.default
        for name in names {
            let direct = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: direct.path) { return direct }
        }
        if let e = fm.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let url as URL in e where names.contains(url.lastPathComponent) { return url }
        }
        throw EngineError.missingModelFile(names.first ?? "")
    }

    public enum EngineError: Error { case microphoneUnavailable, converterUnavailable, missingModelDirectory, missingModelFile(String), modelLoadFailed(String) }
}
