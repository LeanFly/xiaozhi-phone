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
    // The C module exposes these opaque handles as OpaquePointer.
    private var kws: OpaquePointer?
    private var kwsStream: OpaquePointer?
    private var asr: OpaquePointer?
    private let queueKey = DispatchSpecificKey<Void>()
    private let stateLock = NSLock()
    private var stopRequested = false
    private var running = false
    private var stopping = false
    private var tapInstalled = false
    private var collecting = false
    private var utterance: [Float] = []
    private var utteranceSamples = 0
    private var silenceSamples = 0
    private var voicedSamples = 0
    private var waitingForSpeech = false
    // All gate state is confined to workQueue. The deadline is measured in captured
    // samples and is deliberately not renewed by rejected/noisy utterances.
    private var waitBudgetSamples = 0
    private var framePending: [Float] = []
    private var candidate: [Float] = []
    private var candidateFrames = 0
    private var noiseRMS: Float = 0.004
    private var candidateMin: Float = .greatestFiniteMagnitude
    private var candidateMax: Float = 0
    private static let frameSamples = 320 // 20 ms at 16 kHz
    public var onWake: (() -> Void)?
    public var onFollowUpTimeout: (() -> Void)?
    private let beginWithFollowUp: Bool
    private var followUp = false
    private var speechWaitLimit = 5
    private var ignoreSamples = 16_000 / 4
    private var completion: Completion?
    private let keyword: String?
    private let maxUtteranceSeconds: Double

    private static let sampleRate = 16_000
    private static let featureDim = 80
    private static let tapBufferFrames: AVAudioFrameCount = 2_048

    /// `keyword` is optional when the kws model's keywords.txt already defines it.
    public init(keyword: String? = nil, maxUtteranceSeconds: Double = 8.0, beginWithFollowUp: Bool = false) {
        self.beginWithFollowUp = beginWithFollowUp
        self.keyword = keyword
        self.maxUtteranceSeconds = max(1.0, maxUtteranceSeconds)
        workQueue.setSpecific(key: queueKey, value: ())
    }

    /// Starts microphone capture without doing model/audio setup on the caller's queue.
    public func start(completion: @escaping Completion) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            workQueue.async { [self] in
                do {
                    try Task.checkCancellation()
                    self.stateLock.lock(); let wasStopped = self.stopRequested; self.stopRequested = false; self.stateLock.unlock()
                    guard !wasStopped else { throw CancellationError() }
                    guard !self.running else { continuation.resume(); return }
                    self.completion = completion
                    do {
                        try self.configureModels()
                        let input = self.audioEngine.inputNode
                        // outputFormat is the format actually produced by the input node.
                        let format = input.outputFormat(forBus: 0)
                        guard format.sampleRate > 0, format.channelCount > 0 else {
                            throw EngineError.microphoneUnavailable
                        }
                        self.inputFormat = format
                        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                   sampleRate: Double(Self.sampleRate), channels: 1,
                                                   interleaved: false)!
                        self.converter = AVAudioConverter(from: format, to: target)
                        guard self.converter != nil else { throw EngineError.converterUnavailable }
                        input.installTap(onBus: 0, bufferSize: Self.tapBufferFrames, format: format) { [weak self] buffer, _ in
                            // The tap's buffer storage may be reused after this callback; make an owned copy.
                            guard let copy = buffer.mutableCopy() as? AVAudioPCMBuffer else { return }
                            self?.convertAndEnqueue(copy)
                        }
                        self.tapInstalled = true
                        self.stateLock.lock(); let cancelled = self.stopRequested; self.stateLock.unlock()
                        guard !cancelled else { throw CancellationError() }
                        self.audioEngine.prepare()
                        try self.audioEngine.start()
                        self.running = true
                        self.stopping = false
                        if self.beginWithFollowUp { self.beginCollection(followUp: true) }
                        continuation.resume()
                    } catch {
                        self.stopLocked()
                        continuation.resume(throwing: error)
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Stops capture and releases all native sherpa-onnx handles.
    public func stop() {
        stateLock.lock(); stopRequested = true; stateLock.unlock()
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopLocked()
        } else {
            workQueue.sync { stopLocked() }
        }
    }

    deinit { stop() }

    private func stopLocked() {
        guard !stopping else { return }
        stopping = true
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled { audioEngine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        if let s = kwsStream { SherpaOnnxDestroyOnlineStream(s) }
        if let k = kws { SherpaOnnxDestroyKeywordSpotter(k) }
        if let a = asr { SherpaOnnxDestroyOfflineRecognizer(a) }
        kwsStream = nil; kws = nil; asr = nil
        converter = nil; inputFormat = nil; utterance.removeAll(keepingCapacity: false)
        utteranceSamples = 0; silenceSamples = 0; collecting = false; running = false
        framePending.removeAll(); candidate.removeAll(); waitBudgetSamples = 0
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

    private func beginCollection(followUp: Bool, preserveBudget: Bool = false) {
        collecting = true
        self.followUp = followUp
        speechWaitLimit = followUp ? 8 : 5
        if !preserveBudget { waitBudgetSamples = Self.sampleRate * speechWaitLimit }
        ignoreSamples = preserveBudget || followUp ? 0 : Self.sampleRate / 4
        utterance.removeAll(keepingCapacity: true)
        utteranceSamples = 0; silenceSamples = 0; voicedSamples = 0
        candidate.removeAll(keepingCapacity: true); candidateFrames = 0
        candidateMin = .greatestFiniteMagnitude; candidateMax = 0
        if !preserveBudget { framePending.removeAll(keepingCapacity: true); noiseRMS = 0.004 }
        waitingForSpeech = true
    }

    private func collectionTimedOut() {
        collecting = false
        utterance.removeAll(keepingCapacity: true); candidate.removeAll(keepingCapacity: true)
        if let kws, let stream = kwsStream { SherpaOnnxResetKeywordStream(kws, stream) }
        if followUp {
            followUp = false
            let callback = onFollowUpTimeout
            DispatchQueue.main.async { callback?() }
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
            let hit = result.pointee.keyword.map { String(cString: $0) } ?? ""
            SherpaOnnxDestroyKeywordResult(result)
            guard !hit.isEmpty else { return }
            beginCollection(followUp: false)
            let wakeCallback = onWake
            DispatchQueue.main.async { wakeCallback?() }
            SherpaOnnxResetKeywordStream(kws, stream)
            return // Do not submit the wake phrase itself as the user's question.
        }
        framePending.append(contentsOf: samples)
        var offset = 0
        while collecting && framePending.count - offset >= Self.frameSamples {
            let frame = Array(framePending[offset..<(offset + Self.frameSamples)])
            offset += Self.frameSamples
            processFrame(frame)
        }
        if offset > 0 { framePending.removeFirst(offset) }
    }

    private func processFrame(_ frame: [Float]) {
        let energy = sqrt(frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame.count))
        guard energy.isFinite else { collectionTimedOut(); return }
        waitBudgetSamples -= frame.count
        if waitingForSpeech {
            if waitBudgetSamples <= 0 { collectionTimedOut(); return }
            if ignoreSamples > 0 {
                ignoreSamples -= frame.count
                return
            }
            // A conservative adaptive floor, with hysteresis and consecutive frames,
            // avoids treating a single transient or steady fan noise as speech.
            let threshold = max(Float(0.012), noiseRMS * 2.5)
            if energy >= threshold {
                candidate.append(contentsOf: frame); candidateFrames += 1
                candidateMin = min(candidateMin, energy); candidateMax = max(candidateMax, energy)
                if candidateFrames >= 10 {
                    // Speech normally changes amplitude; stationary tones/noise should
                    // not open the gate merely by persisting above the floor.
                    if candidateMax >= candidateMin * 1.35 {
                        waitingForSpeech = false
                        utterance = candidate
                        utteranceSamples = candidate.count; voicedSamples = candidate.count; silenceSamples = 0
                        candidate.removeAll(keepingCapacity: true); candidateFrames = 0
                    } else {
                        // Learn sustained stationary noise, then require a new onset.
                        noiseRMS = min(0.08, max(noiseRMS, energy))
                        candidate.removeAll(keepingCapacity: true); candidateFrames = 0
                        candidateMin = .greatestFiniteMagnitude; candidateMax = 0
                    }
                }
            } else {
                candidate.removeAll(keepingCapacity: true); candidateFrames = 0
                candidateMin = .greatestFiniteMagnitude; candidateMax = 0
                noiseRMS = min(0.08, max(0.001, noiseRMS * 0.98 + energy * 0.02))
            }
            return
        }
        utterance.append(contentsOf: frame); utteranceSamples += frame.count
        if energy >= max(Float(0.009), noiseRMS * 1.6) {
            voicedSamples += frame.count; silenceSamples = 0
        } else { silenceSamples += frame.count }
        let reachedSilence = silenceSamples >= Self.sampleRate * 8 / 10
        let reachedMaximum = Double(utteranceSamples) / Double(Self.sampleRate) >= maxUtteranceSeconds
        if reachedSilence || reachedMaximum {
            // Do not decode an uninterrupted maximum-length signal: it is often
            // environmental noise, and decoding it can produce hallucinated text.
            if reachedSilence && voicedSamples >= Self.sampleRate / 3 { recognizeAndFinish() }
            else if waitBudgetSamples > 0 { beginCollection(followUp: followUp, preserveBudget: true) }
            else { collectionTimedOut() }
        }
    }

    private func recognizeAndFinish() {
        guard let asr, !utterance.isEmpty else { collecting = false; return }
        let audio = utterance
        collecting = false; utterance.removeAll(keepingCapacity: true); utteranceSamples = 0; silenceSamples = 0
        guard let stream = SherpaOnnxCreateOfflineStream(asr) else {
            if waitBudgetSamples > 0 { beginCollection(followUp: followUp, preserveBudget: true) }
            else { collectionTimedOut() }
            return
        }
        audio.withUnsafeBufferPointer {
            SherpaOnnxAcceptWaveformOffline(stream, Int32(Self.sampleRate), $0.baseAddress, Int32($0.count))
        }
        SherpaOnnxDecodeOfflineStream(asr, stream)
        var text = ""
        if let result = SherpaOnnxGetOfflineStreamResult(stream) {
            text = result.pointee.text.map { String(cString: $0) }?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
            SherpaOnnxDestroyOfflineRecognizerResult(result)
        }
        SherpaOnnxDestroyOfflineStream(stream)
        guard text.count >= 2, !text.contains("[音频"), !text.isEmpty else {
            if waitBudgetSamples > 0 { beginCollection(followUp: followUp, preserveBudget: true) }
            else { collectionTimedOut() }
            return
        }
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
        ac.decoding_method = strdup("greedy_search").map { UnsafePointer<CChar>($0) }
        ef.path.withCString { e in df.path.withCString { d in jf.path.withCString { j in kt.path.withCString { t in kw.path.withCString { w in
            kc.model_config.transducer.encoder = e; kc.model_config.transducer.decoder = d; kc.model_config.transducer.joiner = j
            kc.model_config.tokens = t; kc.keywords_file = w; kc.model_config.provider = strdup("cpu").map { UnsafePointer<CChar>($0) }; kc.model_config.num_threads = 2
            kws = SherpaOnnxCreateKeywordSpotter(&kc)
        }}}}}
        guard let kws else { throw EngineError.modelLoadFailed("kws") }
        kwsStream = keyword?.withCString { SherpaOnnxCreateKeywordStreamWithKeywords(kws, $0) } ?? SherpaOnnxCreateKeywordStream(kws)
        st.path.withCString { t in sm.path.withCString { m in
            ac.model_config.tokens = t; ac.model_config.provider = strdup("cpu").map { UnsafePointer<CChar>($0) }; ac.model_config.num_threads = 2
            ac.model_config.sense_voice.model = m; ac.model_config.sense_voice.language = "zh".withCString { strdup($0) }.map { UnsafePointer<CChar>($0) }; ac.model_config.sense_voice.use_itn = 1
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
