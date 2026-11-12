package com.lhht.aiassistant.service

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import com.k2fsa.sherpa.onnx.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Offline speech-to-text using sherpa-onnx streaming Zipformer.
 * The model is deliberately kept outside the APK because a usable ASR model is
 * hundreds of MB. Put the model files in filesDir/models/asr and pass that path.
 */
class LocalSpeechRecognizer(private val context: Context, private val modelDir: File) {
    companion object {
        private const val TAG = "LocalSpeechRecognizer"
        private const val SAMPLE_RATE = 16000
        private const val FRAME_MS = 100
    }

    private var recognizer: OnlineRecognizer? = null

    private fun modelConfig(): OnlineRecognizerConfig {
        val encoder = File(modelDir, "encoder-epoch-99-avg-1.int8.onnx").path
        val decoder = File(modelDir, "decoder-epoch-99-avg-1.int8.onnx").path
        val joiner = File(modelDir, "joiner-epoch-99-avg-1.int8.onnx").path
        val tokens = File(modelDir, "tokens.txt").path
        require(listOf(encoder, decoder, joiner, tokens).all { File(it).exists() }) {
            "离线语音模型不完整，需要 encoder/decoder/joiner/tokens.txt"
        }
        return OnlineRecognizerConfig(
            featConfig = FeatureConfig(SAMPLE_RATE, 80),
            modelConfig = OnlineModelConfig(
                transducer = OnlineTransducerModelConfig(encoder, decoder, joiner),
                tokens = tokens,
                modelType = "zipformer",
                numThreads = 2,
                provider = "cpu"
            ),
            enableEndpoint = true,
            endpointConfig = EndpointConfig(
                rule1 = EndpointRule(false, 2.0f, 0.0f),
                rule2 = EndpointRule(true, 0.8f, 0.0f),
                rule3 = EndpointRule(false, 0.0f, 20.0f)
            )
        )
    }

    suspend fun transcribeOnce(maxDurationMs: Long = 12000): String = withContext(Dispatchers.IO) {
        if (recognizer == null) recognizer = OnlineRecognizer(config = modelConfig())
        val audioBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        ).coerceAtLeast(SAMPLE_RATE / 5)
        val record = AudioRecord(
            MediaRecorder.AudioSource.MIC, SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, audioBuffer * 2
        )
        check(record.state == AudioRecord.STATE_INITIALIZED) { "无法初始化麦克风" }
        val stream = recognizer!!.createStream()
        val pcm = ShortArray(SAMPLE_RATE * FRAME_MS / 1000)
        val started = System.currentTimeMillis()
        try {
            record.startRecording()
            while (System.currentTimeMillis() - started < maxDurationMs) {
                val n = record.read(pcm, 0, pcm.size)
                if (n <= 0) continue
                stream.acceptWaveform(FloatArray(n) { pcm[it] / 32768.0f }, SAMPLE_RATE)
                while (recognizer!!.isReady(stream)) recognizer!!.decode(stream)
                if (recognizer!!.isEndpoint(stream)) break
            }
            stream.inputFinished()
            while (recognizer!!.isReady(stream)) recognizer!!.decode(stream)
            val result = recognizer!!.getResult(stream).text.trim()
            Log.i(TAG, "offline transcription: $result")
            result
        } finally {
            runCatching { record.stop() }
            record.release()
            stream.release()
        }
    }

    fun release() {
        recognizer?.release()
        recognizer = null
    }
}
