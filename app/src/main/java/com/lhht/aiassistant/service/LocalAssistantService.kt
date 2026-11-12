package com.lhht.aiassistant.service

import android.content.Context
import android.util.Log
import com.lhht.aiassistant.model.ModelApiConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * 本地优先语音助手链路：麦克风 -> 本地 sherpa-onnx ASR -> 文本问答 API。
 * ASR 不把音频上传；只有识别出的文本才会发送到配置好的大模型接口。
 */
class LocalAssistantService private constructor(
    private val context: Context,
    private val recognizer: LocalSpeechRecognizer,
    private val llm: ModelApiService
) {
    companion object {
        private const val TAG = "LocalAssistantService"
        private const val MODEL_DIR = "models/asr"

        suspend fun create(context: Context, config: ModelApiConfig): LocalAssistantService =
            withContext(Dispatchers.IO) {
                val appContext = context.applicationContext
                val modelDir = File(appContext.filesDir, MODEL_DIR)
                val recognizer = LocalSpeechRecognizer(appContext, modelDir)
                val llm = ModelApiService(config.endpoint, config.apiKey, config.model)
                LocalAssistantService(appContext, recognizer, llm)
            }
    }

    suspend fun listenAndAsk(): Pair<String, String> {
        val text = recognizer.transcribeOnce()
        if (text.isBlank()) return "" to "没有听清，请再说一次"
        Log.i(TAG, "ASR text ready; requesting LLM answer")
        val answer = llm.answer(text)
        return text to answer
    }

    fun release() = recognizer.release()

    fun modelDirectory(): File = File(context.filesDir, MODEL_DIR)
}
