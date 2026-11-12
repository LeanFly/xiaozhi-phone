package com.lhht.aiassistant.service

/** Conservative Markdown cleanup for text displayed and read aloud. */
object SpeechTextFormatter {
    fun format(input: String): String {
        var text = input.replace("\r\n", "\n").replace('\r', '\n')
        // Do not read model reasoning blocks if a provider returns them.
        text = text.replace(Regex("(?is)<think>.*?</think>"), " ")
        text = text.replace(Regex("(?is)<think>.*$"), " ")
        // Preserve human-readable link text and code contents; discard link targets and fences.
        text = text.replace(Regex("!\\[([^]]*)]\\([^)]*\\)"), "$1")
        text = text.replace(Regex("\\[([^]]+)]\\([^)]*\\)"), "$1")
        text = text.replace(Regex("(?m)^\\s*```[^\\n]*$"), "")
        text = text.replace(Regex("(?m)^\\s{0,3}#{1,6}\\s+"), "")
        text = text.replace(Regex("(?m)^\\s*>+\\s?"), "")
        text = text.replace(Regex("(?m)^\\s*(?:[-*+]\\s+|\\d+[.)、]\\s*)"), "")
        text = text.replace(Regex("(?m)^\\s*\\|?\\s*:?-{3,}:?\\s*(?:\\|\\s*:?-{3,}:?\\s*)+\\|?\\s*$"), "")
        text = text.replace(Regex("(?<!\\*)\\*\\*(?=\\S)|(?<=\\S)\\*\\*(?!\\*)"), "")
        text = text.replace(Regex("(?<!_)__(?=\\S)|(?<=\\S)__(?!_)"), "")
        text = text.replace(Regex("(?<![\\w*])\\*(?=\\S)|(?<=\\S)\\*(?![\\w*])"), "")
        text = text.replace(Regex("(?<![\\w_])_(?=\\S)|(?<=\\S)_(?![\\w_])"), "")
        text = text.replace("~~", "").replace("`", "")
        text = text.replace(Regex("(?m)^\\s*[-*_]{3,}\\s*$"), "")
        text = text.replace(Regex("(?m)^\\s*\\|\\s*|\\s*\\|\\s*$"), "")
        text = text.replace(Regex("\\s*\\|\\s*"), "，")
        text = text.replace(Regex("[\\uD83C-\\uDBFF][\\uDC00-\\uDFFF]"), "")
        text = text.replace(Regex("[\\t ]+"), " ").replace(Regex(" *\\n *"), "\n")
        return text.replace(Regex("\\n{3,}"), "\n\n").trim()
    }
}
