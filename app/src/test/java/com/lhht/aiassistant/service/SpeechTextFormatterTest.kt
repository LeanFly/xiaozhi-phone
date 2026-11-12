package com.lhht.aiassistant.service

import org.junit.Assert.assertEquals
import org.junit.Test

class SpeechTextFormatterTest {
    @Test fun stripsFormattingAndKeepsMeaning() {
        val input = "# 天气\n**北京**今天 25°C。\n- 带伞\n- 查看[天气预报](https://example.com)"
        assertEquals("天气\n北京今天 25°C。\n带伞\n查看天气预报", SpeechTextFormatter.format(input))
    }

    @Test fun preservesNumbersAndIdentifiers() {
        assertEquals("版本 v1.2.3，模型 qwen_latest，价格 12.5 元。", SpeechTextFormatter.format("版本 v1.2.3，模型 qwen_latest，价格 12.5 元。"))
    }

    @Test fun hidesReasoningAndFences() {
        val input = "<think>秘密思考</think>\n```text\n答案是 42。\n```"
        assertEquals("答案是 42。", SpeechTextFormatter.format(input))
    }

    @Test fun retainsOrdinaryMultiplication() {
        assertEquals("3*5=15", SpeechTextFormatter.format("3*5=15"))
    }
}
