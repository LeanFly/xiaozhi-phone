# 唯一模型接口配置

应用现在不使用 Dify，不使用小智 WebSocket 后端。设备链路为：

```text
麦克风 -> 本地 sherpa-onnx ASR -> 文本 -> 唯一模型接口 -> 回答
```

在应用的“设置 → 模型接口配置”中填写：

- 接口地址：OpenAI 兼容服务的根地址，例如 `https://api.example.com`；程序请求 `/v1/chat/completions`。
- API Key：可选；填写后以 Bearer 方式发送。
- 模型名：当前默认 `default`，如需指定模型可在后续配置中扩展。

如果地址本身已经以 `/v1/chat/completions` 结尾，程序会直接使用该地址。

音频始终在设备本地识别，不上传；只有识别出的文字发送给模型接口。
