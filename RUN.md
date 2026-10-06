# 运行命令

- 项目：MOSS-Transcribe-Diarize（OpenMOSS 0.9B，长音频多说话人转写 + 匿名说话人分离 + 时间戳）
- 生成时间：2026-10-06
- 运行方式：**直接运行**（本仓无 docker-compose；`uv venv` + 本地 HF 推理）
- 硬件评估：**满足**
  - 依据：模型 0.9B（Qwen3-0.6B 风格解码器 + Whisper-Medium 音频编码器），bf16 权重约 2GB；本机 RTX 4080 / 16GB，实测空闲 13GB。
  - 注意：长音频的 KV 缓存随 `max_new_tokens` 增长；上游警告 `eager` attention 显存随音频长度平方增长，本机走 `sdpa`（装了 flash-attn 会自动优先 `flash_attention_2`）。

## 环境准备

依赖（`--torch-backend=auto` 会按驱动能力自动选 CUDA 轮子；本机实测装出 torch 2.14.1+cu130 / transformers 5.18.0 / Python 3.12.13）：

```powershell
Set-Location E:\AI\local-voice\MOSS-Transcribe-Diarize
uv venv --python 3.12 .venv
uv pip install -e ".[torch-runtime]" --python .venv\Scripts\python.exe --torch-backend=auto
```

模型权重（本机 huggingface.co 直连不通，必须走 hf-mirror；**并且必须禁用 Xet**）：

```powershell
$env:HF_HOME = 'E:\huggingface_cache'
$env:HF_ENDPOINT = 'https://hf-mirror.com'
$env:HF_HUB_DISABLE_XET = '1'   # 关键：否则报 401 Unauthorized
hf download OpenMOSS-Team/MOSS-Transcribe-Diarize
```

`HF_HUB_DISABLE_XET=1` 不能省：hf-mirror 不代理 Xet 存储后端，不禁用会走到 `cas-server.xethub.hf.co` 并报
`RuntimeError: ... CAS Client Error: HTTP status client error (401 Unauthorized)`。禁用后回退到经典 HTTP 下载路径，正常。

## 启动

- 推荐：`pwsh -NoProfile -File .\start.ps1`
- 说明：启动后按提示选择服务，可单开或同开多个；默认第 1 项（字幕工作台）。不要默认全开。
- 等价手动命令（`<模型目录>` 见「模型目录解析」）：

字幕工作台 Web UI（端口 7860 起探测顺延）：

```powershell
.\.venv\Scripts\mtd-subtitle-web.exe --model <模型目录> --device cuda --dtype bf16 --port 7860 --max-new-tokens 8192
```

单文件转写 CLI（出 `raw_transcript.txt` / `segments.json` / `subtitle.srt` / `subtitle.ass`）：

```powershell
.\.venv\Scripts\mtd-subtitle.exe <输入文件> --model <模型目录> --device cuda --dtype bf16 --max-new-tokens 8192
# 追加 --render 可烧字幕到 MP4（需 ffmpeg）
```

## 验证

字幕工作台：

```powershell
curl.exe -s http://127.0.0.1:7860/api/runtime
```

预期返回 JSON，含 `ffmpeg.available`、`model.backend`（`hf`）、`model.device`（`cuda`）、`model.path`（本地模型目录）。页面打开 `http://127.0.0.1:7860` 上传一段多说话人音频，应产出带 `[S01]`/`[S02]` 说话人标签的带时间戳分段。

CLI：跑完会打印 JSON 摘要，`segments` 为分段数，`files` 列出四个产物路径；`--render` 时另有 `mp4`。

## 备注

**模型目录解析**（`start.ps1` 内 `Resolve-ModelDir`，按优先级）：

1. 环境变量 `MOSS_MODEL_DIR`（含 `config.json` 的目录）
2. 仓库内 `pretrained\moss-transcribe-diarize\`（上游 `cli.py` 的 `DEFAULT_MODEL` 约定，已被 `.gitignore` 忽略）
3. 共享 HF 缓存快照：`$env:HF_HOME\hub\models--OpenMOSS-Team--MOSS-Transcribe-Diarize\snapshots\<rev>\`

**为什么必须传本地目录、不能传 HF repo id**：`cli.py` / `web_cli.py` 会把 `--model` 过一遍 `Path(...).expanduser()`，Windows 上 `Path()` 会把 `OpenMOSS-Team/MOSS-Transcribe-Diarize` 规范化成 `OpenMOSS-Team\MOSS-Transcribe-Diarize`，`from_pretrained` 就当成不存在的本地目录了。上游有个 `fix/windows-hf-repo-id` 分支，但当前与 `main` 无差异，问题仍在。`start.ps1` 因此统一解析成绝对路径再传。

**`max_new_tokens` 默认改成 8192**：上游默认 2048，长音频会被截断（FunASR 侧实测约 6 分钟的音频用 5120 就会在 354.98 秒处截断并报错，需抬到 8192）。`start.ps1` 暴露 `-MaxNewTokens` 参数，默认 8192。

**模型缓存与 voice-studio 一致**：权重落在共享 HF 缓存 `E:\huggingface_cache`，不散落在仓库里；`start.ps1` 会把 `HF_HOME` 显式钉住（未设置时才设），并默认补 `HF_ENDPOINT=https://hf-mirror.com`。这样 voice-studio 的 sidecar 用同一个 `HF_HOME` 就能直接命中，不需要第二份。

**端口**：字幕工作台默认 7860 起探测顺延。注意**不要用 8000**——那是 voice-studio `funasr` 节点写死的 `base_url`。

**vLLM 后端未启用**：上游支持 `--backend vllm`（连外部 OpenAI 兼容服务，且需 vLLM 0.27.1 + `[audio]` extra）。Windows 下 vLLM 支持不佳，本机不装；如要用请另起 Linux 容器或 WSL。

**ffmpeg**：用全局一份 `E:\Programs\ffmpeg-master-latest-win64-gpl\bin`，`start.ps1` 会加进当前会话 PATH，不要再下一份。

**`trust_remote_code`**：模型走 HF 自定义代码加载，权重目录里自带 `modeling_*` / `processing_*` / `configuration_*`，不依赖仓库源码；`from_pretrained` 传本地目录时不会联网。

## 本机改动（local-custom 分支）

相对上游 `main` 仅新增本机运行材料，不改任何推理代码：

- `RUN.md`（本文件）
- `start.ps1`（多服务交互启动）