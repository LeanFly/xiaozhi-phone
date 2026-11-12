package com.lhht.aiassistant

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.ViewConfiguration
import kotlin.math.abs
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.view.View
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.lhht.aiassistant.databinding.ActivityMainBinding
import com.lhht.aiassistant.service.ModelApiService
import com.lhht.aiassistant.service.SpeakerListener
import com.lhht.aiassistant.service.SpeechTextFormatter
import com.lhht.aiassistant.ui.config.ConfigEditActivity
import kotlinx.coroutines.*
import java.util.Locale

class MainActivity : AppCompatActivity() {
    private lateinit var binding: ActivityMainBinding
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var listener: SpeakerListener? = null
    private var listenerJob: Job? = null
    private var tts: TextToSpeech? = null
    @Volatile private var ttsReady = false
    private var ttsEngine: String? = null
    private var ttsGeneration = 0
    @Volatile private var visible = false
    private val holdHandler = Handler(Looper.getMainLooper())
    private var holdAction: Runnable? = null
    private var downX = 0f
    private var downY = 0f

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        enableImmersiveMode()
        binding.mascot.setOnTouchListener { view, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.x
                    downY = event.y
                    binding.holdHint.text = "继续按住 5 秒进入设置"
                    val action = Runnable {
                        holdAction = null
                        binding.holdHint.text = "正在打开设置…"
                        view.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
                        startActivity(Intent(this, ConfigEditActivity::class.java).putExtra("config_type", "model_api"))
                    }
                    holdAction = action
                    holdHandler.postDelayed(action, 5000L)
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val slop = ViewConfiguration.get(this).scaledTouchSlop
                    if (abs(event.x - downX) > slop || abs(event.y - downY) > slop) cancelHold()
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> { cancelHold(); true }
                else -> true
            }
        }
        binding.retryButton.setOnClickListener { startListening() }
    }

    private fun initializeTts(engine: String) {
        val generation = ++ttsGeneration
        ttsEngine = engine
        ttsReady = false
        tts?.stop()
        tts?.shutdown()
        val callback = TextToSpeech.OnInitListener { status ->
            binding.root.post {
                if (generation == ttsGeneration && !isFinishing && !isDestroyed) {
                    val result = if (status == TextToSpeech.SUCCESS) tts?.setLanguage(Locale.CHINESE) ?: TextToSpeech.ERROR else TextToSpeech.ERROR
                    ttsReady = result != TextToSpeech.ERROR && result != TextToSpeech.LANG_MISSING_DATA && result != TextToSpeech.LANG_NOT_SUPPORTED
                }
            }
        }
        tts = if (engine.isBlank()) TextToSpeech(this, callback) else TextToSpeech(this, callback, engine)
        tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) { runOnUiThread { if (visible) binding.mascot.setMode(MascotView.Mode.SPEAKING) } }
            override fun onDone(utteranceId: String?) { runOnUiThread { binding.mascot.setMode(MascotView.Mode.IDLE) } }
            @Deprecated("Android callback")
            override fun onError(utteranceId: String?) { runOnUiThread { binding.mascot.setMode(MascotView.Mode.IDLE) } }
        })
    }

    @Suppress("DEPRECATION")
    private fun enableImmersiveMode() {
        window.statusBarColor = android.graphics.Color.TRANSPARENT
        window.navigationBarColor = android.graphics.Color.TRANSPARENT
        if (android.os.Build.VERSION.SDK_INT >= 28) {
            val params = window.attributes
            params.layoutInDisplayCutoutMode = android.view.WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            window.attributes = params
        }
        window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            or View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) enableImmersiveMode()
    }

    override fun onResume() {
        super.onResume()
        visible = true
        val selectedEngine = getSharedPreferences("model_api", MODE_PRIVATE).getString("tts_engine", "").orEmpty()
        if (ttsEngine != selectedEngine || tts == null) initializeTts(selectedEngine)
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            startListening()
        } else {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), 101)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 101 && grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) startListening()
        else if (requestCode == 101) showStatus("麦克风权限未授予", android.graphics.Color.rgb(255, 154, 159))
    }

    private fun showStatus(text: String, color: Int) {
        binding.status.text = text
        binding.ripple.setActive(text.startsWith("正在请求回答"))
        binding.mascot.setMode(if (text == "正在监听") MascotView.Mode.LISTENING else MascotView.Mode.IDLE)
        binding.micStatusIcon.setColorFilter(color)
        binding.status.setTextColor(color)
        binding.micStatusIcon.contentDescription = "麦克风状态：$text"
    }

    private fun startListening() {
        if (!visible || listenerJob?.isActive == true) return
        val worker = SpeakerListener(applicationContext)
        listener = worker
        showStatus("正在加载语音模型", android.graphics.Color.rgb(255, 212, 137))
        listenerJob = scope.launch(Dispatchers.IO) {
            try {
                worker.run(
                    onStatus = { text -> runOnUiThread {
                        if (visible) {
                            when {
                                text.startsWith("正在监听") -> showStatus("正在监听", android.graphics.Color.rgb(120, 240, 199))
                                text.startsWith("已唤醒") -> showStatus("正在听你说", android.graphics.Color.rgb(138, 216, 255))
                                text.startsWith("没有听清") -> { binding.resultScroll.visibility = View.VISIBLE; binding.result.text = text }
                                else -> showStatus("正在识别", android.graphics.Color.rgb(138, 216, 255))
                            }
                        }
                    } },
                    onQuestion = { text ->
                        runOnUiThread { binding.resultScroll.visibility = View.VISIBLE; binding.result.text = "你说：$text"; if (visible) showStatus("正在请求回答（麦克风暂停）", android.graphics.Color.rgb(255, 212, 137)) }
                        val prefs = getSharedPreferences("model_api", MODE_PRIVATE)
                        try {
                            val service = ModelApiService(prefs.getString("endpoint", "").orEmpty(), prefs.getString("api_key", "").orEmpty(), prefs.getString("model", "default").orEmpty())
                            val rawAnswer = runBlocking { service.answer(text) }
                            val answer = SpeechTextFormatter.format(rawAnswer).ifBlank { "抱歉，我暂时没有得到可播报的回答。" }
                            runOnUiThread { binding.result.text = "你说：$text\n\n小智：$answer" }
                            // Stop TTS from being recognized as a new wake phrase.
                            if (ttsReady && visible) {
                                val queued = tts?.speak(answer, TextToSpeech.QUEUE_FLUSH, null, "xiaozhi-answer")
                                if (queued != TextToSpeech.SUCCESS) {
                                    runOnUiThread { binding.result.append("\n语音播放失败，请检查系统语音引擎。") }
                                } else {
                                    Thread.sleep(500)
                                    while (visible && tts?.isSpeaking == true) Thread.sleep(100)
                                }
                            } else if (visible) {
                                runOnUiThread { binding.result.append("\n语音引擎未就绪，请检查系统文字转语音设置。") }
                            }
                        } catch (e: Exception) {
                            runOnUiThread { binding.result.text = "你说：$text\n\n${e.message}" }
                        }
                    }
                )
            } catch (e: LinkageError) {
                runOnUiThread { if (visible) showStatus("语音库不兼容", android.graphics.Color.rgb(255, 154, 159)) }
            } catch (e: Exception) {
                runOnUiThread { if (visible) showStatus("监听失败：${e.message}", android.graphics.Color.rgb(255, 154, 159)) }
            } finally {
                withContext(NonCancellable + Dispatchers.Main) {
                    if (listener === worker) listener = null
                    listenerJob = null
                    if (visible && !isFinishing && worker.wasStopped()) startListening()
                }
            }
        }
    }


    private fun cancelHold() {
        holdAction?.let { holdHandler.removeCallbacks(it) }
        holdAction = null
        binding.holdHint.text = "长按吉祥物 5 秒进入设置"
    }

    override fun onPause() {
        cancelHold()
        visible = false
        binding.mascot.setMode(MascotView.Mode.IDLE)
        binding.ripple.setActive(false)
        listener?.stop()
        tts?.stop()
        super.onPause()
    }

    override fun onDestroy() {
        listener?.stop()
        scope.cancel()
        ttsGeneration++
        tts?.shutdown()
        super.onDestroy()
    }
}
