package com.lhht.aiassistant.ui.config

import android.os.Bundle
import android.content.Intent
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.widget.ArrayAdapter
import android.widget.AdapterView
import android.view.View
import android.widget.Toast
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import com.lhht.aiassistant.service.ModelApiService
import com.lhht.aiassistant.R
import com.lhht.aiassistant.databinding.ActivityConfigEditBinding
import com.lhht.aiassistant.model.DifyConfig
import com.lhht.aiassistant.model.XiaozhiConfig
import com.lhht.aiassistant.viewmodel.ConfigViewModel
import com.lhht.aiassistant.utils.DeviceUtil
import java.util.*

/**
 * 配置编辑Activity
 */
class ConfigEditActivity : AppCompatActivity() {
    
    private lateinit var binding: ActivityConfigEditBinding
    private val configViewModel: ConfigViewModel by viewModels()
    
    private var configType: String? = null
    private var configId: String? = null
    private var isEditing = false
    private var previewTts: TextToSpeech? = null
    private var ttsGeneration = 0
    private var previewReady = false
    private var enginePackages: List<String> = emptyList()
    private var chosenEngine = ""
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityConfigEditBinding.inflate(layoutInflater)
        setContentView(binding.root)
        
        // 获取传递的参数
        configType = intent.getStringExtra("config_type")
        configId = intent.getStringExtra("config_id")
        isEditing = configId != null
        
        android.util.Log.d("ConfigEdit", "ConfigEditActivity初始化")
        android.util.Log.d("ConfigEdit", "configType: $configType")
        android.util.Log.d("ConfigEdit", "configId: $configId")
        android.util.Log.d("ConfigEdit", "isEditing: $isEditing")
        
        setupToolbar()
        setupViews()
        setupClickListeners()
        
        if (isEditing || configType == "model_api") {
            observeConfigData()
        }
    }
    
    private fun setupToolbar() {
        setSupportActionBar(binding.toolbar)
        supportActionBar?.setDisplayHomeAsUpEnabled(true)
        supportActionBar?.title = if (isEditing) "编辑配置" else "添加配置"
    }
    
    private fun setupViews() {
        when (configType) {
            "model_api" -> {
                binding.apiUrlLayout.visibility = android.view.View.VISIBLE
                binding.apiKeyLayout.visibility = android.view.View.VISIBLE
                binding.modelNameLayout.visibility = android.view.View.VISIBLE
                binding.testModelButton.visibility = android.view.View.VISIBLE
                binding.testModelResult.visibility = android.view.View.VISIBLE
                binding.ttsHeading.visibility = View.VISIBLE
                binding.ttsEngineSpinner.visibility = View.VISIBLE
                binding.ttsStatus.visibility = View.VISIBLE
                binding.ttsTestButton.visibility = View.VISIBLE
                binding.ttsSystemButton.visibility = View.VISIBLE
                setupTtsControls()
                binding.websocketUrlLayout.visibility = android.view.View.GONE
                binding.macAddressLayout.visibility = android.view.View.GONE
                binding.tokenLayout.visibility = android.view.View.GONE
                binding.apiUrlEditText.hint = "模型接口地址（OpenAI兼容）"
                binding.apiKeyEditText.hint = "API Key（可选）"
            }
            "dify" -> {
                binding.apiUrlLayout.visibility = android.view.View.VISIBLE
                binding.apiKeyLayout.visibility = android.view.View.VISIBLE
                binding.websocketUrlLayout.visibility = android.view.View.GONE
                binding.macAddressLayout.visibility = android.view.View.GONE
                binding.tokenLayout.visibility = android.view.View.GONE
            }
            "xiaozhi" -> {
                binding.apiUrlLayout.visibility = android.view.View.GONE
                binding.apiKeyLayout.visibility = android.view.View.GONE
                binding.websocketUrlLayout.visibility = android.view.View.VISIBLE
                binding.macAddressLayout.visibility = android.view.View.VISIBLE
                binding.tokenLayout.visibility = android.view.View.VISIBLE
                
                // 如果不是编辑模式，自动获取并填充MAC地址
                if (!isEditing) {
                    val macAddress = DeviceUtil.getMacAddress(this)
                    binding.macAddressEditText.setText(macAddress)
                    android.util.Log.d("ConfigEdit", "自动获取MAC地址: $macAddress")
                }
            }
        }
    }
    
    private fun setupClickListeners() {
        binding.saveButton.setOnClickListener {
            android.util.Log.d("ConfigEdit", "保存按钮被点击")
            saveConfig()
        }
        
        binding.testModelButton.setOnClickListener { testModel() }

        binding.cancelButton.setOnClickListener {
            android.util.Log.d("ConfigEdit", "取消按钮被点击")
            finish()
        }
    }
    
    private fun observeConfigData() {
        when (configType) {
            "model_api" -> {
                val prefs = getSharedPreferences("model_api", MODE_PRIVATE)
                binding.nameEditText.setText(prefs.getString("name", "本地智能音箱"))
                binding.apiUrlEditText.setText(prefs.getString("endpoint", ""))
                binding.apiKeyEditText.setText(prefs.getString("api_key", ""))
                binding.modelNameEditText.setText(prefs.getString("model", ""))
            }
            "dify" -> {
                configViewModel.difyConfigs.observe(this) { configs ->
                    val config = configs.find { it.id == configId }
                    if (config != null) {
                        binding.nameEditText.setText(config.name)
                        binding.apiUrlEditText.setText(config.apiUrl)
                        binding.apiKeyEditText.setText(config.apiKey)
                    }
                }
            }
            "xiaozhi" -> {
                configViewModel.xiaozhiConfigs.observe(this) { configs ->
                    val config = configs.find { it.id == configId }
                    if (config != null) {
                        binding.nameEditText.setText(config.name)
                        binding.websocketUrlEditText.setText(config.websocketUrl)
                        binding.macAddressEditText.setText(config.macAddress)
                        binding.tokenEditText.setText(config.token)
                    }
                }
            }
        }
    }
    
    private fun setupTtsControls() {
        val intent = Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE)
        val services = packageManager.queryIntentServices(intent, 0)
            .distinctBy { it.serviceInfo.packageName }
            .sortedBy { it.loadLabel(packageManager).toString() }
        val saved = getSharedPreferences("model_api", MODE_PRIVATE).getString("tts_engine", "").orEmpty()
        enginePackages = listOf("") + services.map { it.serviceInfo.packageName } +
            if (saved.isNotEmpty() && services.none { it.serviceInfo.packageName == saved }) listOf(saved) else emptyList()
        val labels = listOf("跟随系统默认") + services.map { "${it.loadLabel(packageManager)} (${it.serviceInfo.packageName})" } +
            if (saved.isNotEmpty() && services.none { it.serviceInfo.packageName == saved }) listOf("未安装：$saved") else emptyList()
        chosenEngine = saved
        binding.ttsEngineSpinner.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, labels)
        binding.ttsEngineSpinner.setSelection(enginePackages.indexOf(saved).coerceAtLeast(0))
        binding.ttsEngineSpinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onNothingSelected(parent: AdapterView<*>?) {}
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                chosenEngine = enginePackages[position]
                initializePreview(chosenEngine)
            }
        }
        binding.ttsTestButton.setOnClickListener {
            if (!previewReady || previewTts == null) {
                binding.ttsStatus.text = "语音引擎未就绪，请选择支持中文的引擎并安装语音数据。"
            } else {
                val result = previewTts?.speak("你好，我是小智同学，语音播报测试成功。", TextToSpeech.QUEUE_FLUSH, null, "preview")
                binding.ttsStatus.text = if (result == TextToSpeech.SUCCESS) "试听已提交，请确认是否听到声音。" else "试听启动失败，请检查引擎及音量。"
            }
        }
        binding.ttsSystemButton.setOnClickListener {
            try { startActivity(Intent("com.android.settings.TTS_SETTINGS")) }
            catch (_: Exception) { binding.ttsStatus.text = "无法打开系统语音设置，请手动前往系统设置中的文字转语音。" }
        }
    }

    private fun initializePreview(engine: String) {
        val generation = ++ttsGeneration
        previewReady = false
        previewTts?.shutdown()
        previewTts = null
        binding.ttsTestButton.isEnabled = false
        binding.ttsStatus.text = "正在检测语音引擎…"
        val callback = TextToSpeech.OnInitListener { result ->
            // Post so even a synchronous callback cannot run before previewTts is assigned.
            binding.root.post {
                if (generation != ttsGeneration || isFinishing || isDestroyed) return@post
                if (result != TextToSpeech.SUCCESS) {
                    binding.ttsStatus.text = "引擎初始化失败，请更换引擎或检查系统设置。"
                } else {
                    val language = previewTts?.setLanguage(Locale.CHINESE) ?: TextToSpeech.ERROR
                    previewReady = language != TextToSpeech.ERROR && language != TextToSpeech.LANG_MISSING_DATA && language != TextToSpeech.LANG_NOT_SUPPORTED
                    binding.ttsStatus.text = if (previewReady) "引擎已连接，支持中文；点击试听确认播放。" else "引擎未提供中文语音，请安装语音数据或更换引擎。"
                    binding.ttsTestButton.isEnabled = previewReady
                }
            }
        }
        previewTts = if (engine.isBlank()) TextToSpeech(this, callback) else TextToSpeech(this, callback, engine)
        previewTts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {}
            override fun onDone(utteranceId: String?) { runOnUiThread { if (generation == ttsGeneration && !isFinishing) binding.ttsStatus.text = "试听播放完成，请确认是否听到声音。" } }
            @Deprecated("Android callback") override fun onError(utteranceId: String?) { runOnUiThread { if (generation == ttsGeneration && !isFinishing) binding.ttsStatus.text = "试听播放失败，请检查语音引擎和音量。" } }
        })
    }

    override fun onDestroy() {
        ttsGeneration++
        previewTts?.stop()
        previewTts?.shutdown()
        previewTts = null
        super.onDestroy()
    }

    private fun testModel() {
        val endpoint = binding.apiUrlEditText.text.toString().trim()
        val key = binding.apiKeyEditText.text.toString().trim()
        val model = binding.modelNameEditText.text.toString().trim()
        if (endpoint.isBlank() || model.isBlank()) {
            binding.testModelResult.text = "请先填写接口地址和模型名称。"
            return
        }
        binding.testModelButton.isEnabled = false
        binding.testModelResult.text = "正在发送测试请求，可能产生少量模型调用费用…"
        lifecycleScope.launch {
            try {
                val answer = ModelApiService(endpoint, key, model).answer("请只回复：连接成功。")
                binding.testModelResult.text = if (answer.isNotBlank()) "检测成功：模型已返回回答。" else "接口返回成功，但回答为空。"
            } catch (e: Exception) {
                binding.testModelResult.text = "检测失败：${e.message?.take(200) ?: "未知错误"}"
            } finally {
                binding.testModelButton.isEnabled = true
            }
        }
    }

    private fun saveConfig() {
        android.util.Log.d("ConfigEdit", "开始保存配置，类型: $configType")
        val name = binding.nameEditText.text.toString().trim()
        if (name.isEmpty()) {
            android.util.Log.w("ConfigEdit", "配置名称为空")
            Toast.makeText(this, "请输入配置名称", Toast.LENGTH_SHORT).show()
            return
        }
        
        android.util.Log.d("ConfigEdit", "配置名称: $name")
        when (configType) {
            "model_api" -> {
                val endpoint = binding.apiUrlEditText.text.toString().trim()
                val apiKey = binding.apiKeyEditText.text.toString().trim()
                val model = binding.modelNameEditText.text.toString().trim()
                if (endpoint.isEmpty() || model.isEmpty()) {
                    Toast.makeText(this, "请填写模型接口地址和模型名称", Toast.LENGTH_SHORT).show()
                    return
                }
                getSharedPreferences("model_api", MODE_PRIVATE).edit()
                    .putString("name", name)
                    .putString("endpoint", endpoint)
                    .putString("api_key", apiKey)
                    .putString("model", model)
                    .putString("tts_engine", chosenEngine)
                    .apply()
            }
            "dify" -> {
                val apiUrl = binding.apiUrlEditText.text.toString().trim()
                val apiKey = binding.apiKeyEditText.text.toString().trim()
                
                if (apiUrl.isEmpty() || apiKey.isEmpty()) {
                    Toast.makeText(this, "请填写完整的Dify配置信息", Toast.LENGTH_SHORT).show()
                    return
                }
                
                val config = DifyConfig(
                    id = configId ?: UUID.randomUUID().toString(),
                    name = name,
                    apiUrl = apiUrl,
                    apiKey = apiKey
                )
                
                if (isEditing) {
                    configViewModel.updateDifyConfig(config)
                } else {
                    configViewModel.addDifyConfig(config)
                }
            }
            "xiaozhi" -> {
                android.util.Log.d("ConfigEdit", "处理小智配置")
                val websocketUrl = binding.websocketUrlEditText.text.toString().trim()
                val macAddress = binding.macAddressEditText.text.toString().trim()
                val token = binding.tokenEditText.text.toString().trim()
                
                android.util.Log.d("ConfigEdit", "WebSocket URL: $websocketUrl")
                android.util.Log.d("ConfigEdit", "MAC地址: $macAddress")
                
                if (websocketUrl.isEmpty() || macAddress.isEmpty() || token.isEmpty()) {
                    android.util.Log.w("ConfigEdit", "小智配置信息不完整")
                    Toast.makeText(this, "请填写完整的小智配置信息", Toast.LENGTH_SHORT).show()
                    return
                }
                
                val newConfigId = configId ?: UUID.randomUUID().toString()
                android.util.Log.d("ConfigEdit", "生成的配置ID: $newConfigId")
                android.util.Log.d("ConfigEdit", "原始configId: $configId")
                
                val config = XiaozhiConfig(
                    id = newConfigId,
                    name = name,
                    websocketUrl = websocketUrl,
                    macAddress = macAddress,
                    token = token
                )
                
                android.util.Log.d("ConfigEdit", "创建小智配置")
                android.util.Log.d("ConfigEdit", "isEditing: $isEditing")
                if (isEditing) {
                    android.util.Log.d("ConfigEdit", "更新小智配置")
                    configViewModel.updateXiaozhiConfig(config)
                } else {
                    android.util.Log.d("ConfigEdit", "添加小智配置")
                    configViewModel.addXiaozhiConfig(config)
                }
            }
        }
        
        Toast.makeText(this, "配置保存成功", Toast.LENGTH_SHORT).show()
        finish()
    }
    
    override fun onSupportNavigateUp(): Boolean {
        finish()
        return true
    }
}
