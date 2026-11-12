package com.lhht.aiassistant.service

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import com.k2fsa.sherpa.onnx.*
import java.io.File

/** One microphone and one worker: wake detection and recognition never compete. */
class SpeakerListener(private val context: Context) {
    @Volatile private var running = true
    @Volatile private var recorder: AudioRecord? = null

    fun wasStopped(): Boolean = !running

    fun stop() {
        running = false
        try { recorder?.stop() } catch (_: IllegalStateException) { }
    }

    fun run(onStatus: (String) -> Unit, onQuestion: (String) -> Unit) {
        var kws: KeywordSpotter? = null
        var asr: OnlineRecognizer? = null
        var wake: OnlineStream? = null
        var speech: OnlineStream? = null
        var mic: AudioRecord? = null
        var sense: OfflineRecognizer? = null
        try {
            val dir = File(context.filesDir, "models/asr")
            val names = listOf("encoder-epoch-99-avg-1.int8.onnx", "decoder-epoch-99-avg-1.int8.onnx", "joiner-epoch-99-avg-1.int8.onnx", "tokens.txt")
            require(names.all { File(dir, it).isFile }) { "本地语音模型文件不完整" }
            kws = KeywordSpotter(context.assets, KeywordSpotterConfig(
                modelConfig = getKwsModelConfig(0) ?: error("唤醒模型配置不存在"),
                keywordsFile = getKeywordsFile(0)
            ))
            wake = kws.createStream()
            check(wake.ptr != 0L) { "唤醒模型初始化失败" }
            asr = OnlineRecognizer(config = OnlineRecognizerConfig(
                modelConfig = OnlineModelConfig(
                    transducer = OnlineTransducerModelConfig(File(dir, names[0]).path, File(dir, names[1]).path, File(dir, names[2]).path),
                    tokens = File(dir, names[3]).path, modelType = "zipformer", numThreads = 2
                ),
                // Keep multiple transcription candidates instead of committing to
                // the most likely token at every frame (greedy decoding).
                decodingMethod = "modified_beam_search",
                maxActivePaths = 8,
                endpointConfig = EndpointConfig(
                    rule1 = EndpointRule(false, 4.0f, 0.0f),
                    rule2 = EndpointRule(true, 1.8f, 0.0f),
                    rule3 = EndpointRule(false, 0.0f, 20.0f)
                ),
                enableEndpoint = true
            ))
            val senseDir = File(context.filesDir, "models/sensevoice")
            if (File(senseDir, "model.int8.onnx").isFile && File(senseDir, "tokens.txt").isFile) {
                sense = OfflineRecognizer(config = OfflineRecognizerConfig(
                    modelConfig = OfflineModelConfig(
                        senseVoice = OfflineSenseVoiceModelConfig(model = File(senseDir, "model.int8.onnx").path, language = "zh"),
                        tokens = File(senseDir, "tokens.txt").path, numThreads = 2
                    )
                ))
            }
            val size = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            check(size > 0) { "设备不支持录音格式" }
            mic = AudioRecord(MediaRecorder.AudioSource.MIC, 16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, size * 2)
            check(mic.state == AudioRecord.STATE_INITIALIZED) { "麦克风初始化失败" }
            recorder = mic
            mic.startRecording()
            check(mic.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "麦克风启动失败" }
            onStatus("正在监听唤醒词：小智同学")
            val data = ShortArray(1600)
            var startedAt = 0L
            val utterance = java.io.ByteArrayOutputStream()
            while (running) {
                val n = mic.read(data, 0, data.size)
                if (n < 0) { if (running) error("录音读取失败：$n"); break }
                if (n == 0) continue
                val samples = FloatArray(n) { data[it] / 32768.0f }
                val current = speech
                if (current == null) {
                    wake.acceptWaveform(samples, 16000)
                    while (running && kws.isReady(wake)) {
                        kws.decode(wake)
                        val keyword = kws.getResult(wake).keyword
                        if (keyword.isNotBlank()) {
                            kws.reset(wake)
                            speech = asr.createStream()
                            utterance.reset()
                            startedAt = System.currentTimeMillis()
                            onStatus("已唤醒，请说出问题")
                            break
                        }
                    }
                } else {
                    for (i in 0 until n) {
                        utterance.write(data[i].toInt() and 0xff)
                        utterance.write((data[i].toInt() shr 8) and 0xff)
                    }
                    current.acceptWaveform(samples, 16000)
                    while (asr.isReady(current)) asr.decode(current)
                    if (asr.isEndpoint(current) || System.currentTimeMillis() - startedAt > 15000) {
                        current.inputFinished()
                        while (asr.isReady(current)) asr.decode(current)
                        val fallbackText = asr.getResult(current).text.trim()
                        val text = if (sense != null) {
                            val bytes = utterance.toByteArray()
                            val floats = FloatArray(bytes.size / 2) { i ->
                                ((bytes[i * 2].toInt() and 0xff) or (bytes[i * 2 + 1].toInt() shl 8)).toShort() / 32768.0f
                            }
                            val offlineStream = sense.createStream()
                            try {
                                offlineStream.acceptWaveform(floats, 16000)
                                sense.decode(offlineStream)
                                sense.getResult(offlineStream).text.trim().ifBlank { fallbackText }
                            } finally { offlineStream.release() }
                        } else fallbackText
                        current.release()
                        speech = null
                        if (text.isBlank() && running) onStatus("没有听清，请再次唤醒")
                        if (text.isNotBlank() && running) {
                            onStatus("识别：$text")
                            // Pauses microphone before network and spoken reply.
                            mic.stop()
                            onQuestion(text)
                            if (running) mic.startRecording()
                        }
                        if (running) onStatus("正在监听唤醒词：小智同学")
                    }
                }
            }
        } finally {
            recorder = null
            try { mic?.stop() } catch (_: Exception) { }
            mic?.release()
            speech?.release()
            wake?.release()
            asr?.release()
            sense?.release()
            kws?.release()
        }
    }
}
