package com.lhht.aiassistant.service

import com.google.gson.Gson
import com.google.gson.JsonObject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

/** OpenAI-compatible text generation endpoint. Audio never leaves the device. */
class ModelApiService(
    private val endpoint: String,
    private val apiKey: String,
    private val model: String
) {
    private val client = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(90, TimeUnit.SECONDS)
        .writeTimeout(20, TimeUnit.SECONDS)
        .build()
    private val gson = Gson()

    suspend fun answer(prompt: String): String = withContext(Dispatchers.IO) {
        require(endpoint.isNotBlank()) { "请先在设置中配置模型接口地址" }
        val url = endpoint.trim().trimEnd('/').let {
            when {
                it.endsWith("/chat/completions") -> it
                it.endsWith("/v1") -> "$it/chat/completions"
                else -> "$it/v1/chat/completions"
            }
        }
        val body = JsonObject().apply {
            addProperty("model", model.ifBlank { "default" })
            addProperty("stream", false)
            add("messages", gson.toJsonTree(listOf(
                mapOf("role" to "system", "content" to "你是智能音箱语音助手。回答将直接朗读给用户听，请使用自然、简洁的中文口语和纯文本，优先用一到三句话回答。不要使用 Markdown、标题、列表符号、表格、代码围栏、表情符号或网址；需要列举时用自然语言连接。不要读出格式说明，不要输出思考过程。对于必须保留的关键数字、单位和专有名词，确保准确。"),
                mapOf("role" to "user", "content" to prompt)
            )))
        }
        val request = Request.Builder().url(url)
            .post(body.toString().toRequestBody("application/json".toMediaType()))
            .apply { if (apiKey.isNotBlank()) addHeader("Authorization", "Bearer $apiKey") }
            .build()
        client.newCall(request).execute().use { response ->
            val raw = response.body?.string().orEmpty()
            if (!response.isSuccessful) throw IOException("模型接口返回 HTTP ${response.code}，请检查地址、密钥和模型名称")
            val json = gson.fromJson(raw, JsonObject::class.java)
            val content = json.getAsJsonArray("choices")?.firstOrNull()?.asJsonObject
                ?.getAsJsonObject("message")?.get("content")
            val answer = if (content != null && !content.isJsonNull && content.isJsonPrimitive) content.asString else null
            answer?.takeIf { it.isNotBlank() }
                ?: json.get("output")?.takeIf { !it.isJsonNull && it.isJsonPrimitive }?.asString?.takeIf { it.isNotBlank() }
                ?: throw IOException("模型接口返回空回答，请检查模型配置或稍后重试")
        }
    }
}
