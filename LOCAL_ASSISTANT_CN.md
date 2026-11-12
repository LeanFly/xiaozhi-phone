# 本地智能音箱

应用现在不使用 Dify，不使用小智 WebSocket 后端。设备链路为：

```text
麦克风 -> 本地 sherpa-onnx ASR -> 文本 -> 唯一模型接口 -> 回答
```

## 本地 ASR 模型

模型放在：

```text
/data/data/com.lhht.aiassistant/files/models/asr/
  encoder-epoch-99-avg-1.int8.onnx
  decoder-epoch-99-avg-1.int8.onnx
  joiner-epoch-99-avg-1.int8.onnx
  tokens.txt
```

当前设备 `f455901` 已经推送并验证了这四个文件。

## 唯一模型接口

在应用中进入“设置 → 模型接口配置”，填写：

- 接口地址：OpenAI 兼容服务根地址，例如 `https://api.example.com`；程序请求 `/v1/chat/completions`。
- API Key：可选，填写后以 Bearer 方式发送。
- 模型名：当前默认 `default`。

如果地址本身已经以 `/v1/chat/completions` 结尾，程序会直接使用该地址。

音频始终在手机本地识别，不上传；只有识别出的文字发送给模型接口。进入“本地智能音箱”后，点击“点击说话”开始一次本地识别和问答。
