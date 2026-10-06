#Requires -Version 5.0
<#
.SYNOPSIS
    启动 MOSS-Transcribe-Diarize（本机直接运行；由 wanggang-run-oss 生成）。
.DESCRIPTION
    主路径：无参运行后交互选择要启动的服务（可单开或同开多个）。

    本仓没有 docker-compose，只支持直接运行（uv venv + 本地 HF 推理）。
    上游的 vLLM 后端在本机未启用（Windows 下 vLLM 支持不佳），见 RUN.md。
.PARAMETER Port
    仅当最终只启动一个需端口的服务时，作为该服务的端口搜索起点。
.PARAMETER Service
    内部/自动化用：跳过菜单，直接启动指定 Id。日常请无参走交互。
.PARAMETER MaxNewTokens
    解码生成长度上限。上游默认 2048，长音频会被截断（实测约 6 分钟音频即需 8192）；本机默认 8192。
#>
[CmdletBinding()]
param(
    [int]$Port = 0,

    [string]$Service = '',

    [int]$MaxNewTokens = 8192
)

$ErrorActionPreference = 'Stop'

# ---- 非 PS7 时转交给 pwsh（文件顶部必须能被 5.1 解析）----
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        throw '未找到 PowerShell 7 (pwsh)。请先全局安装：winget install --id Microsoft.PowerShell -e'
    }
    $argList = @('-NoProfile', '-File', $PSCommandPath)
    foreach ($key in $PSBoundParameters.Keys) {
        $argList += "-$key"
        $val = $PSBoundParameters[$key]
        if ($val -isnot [System.Management.Automation.SwitchParameter]) {
            $argList += [string]$val
        }
    }
    & $pwsh.Source @argList
    exit $LASTEXITCODE
}

Set-Location $PSScriptRoot

# ---- 合并全局 PATH（Trae/代理终端常被精简，缺 git/uv/ffmpeg）----
$MergePath = 'E:\Pro\blog\docs\AI\skills\script\merge-global-path.ps1'
if (Test-Path $MergePath) { & $MergePath }

# ---- ffmpeg：本机全局一份，不要再下一份 ----
$FfmpegBin = 'E:\Programs\ffmpeg-master-latest-win64-gpl\bin'
if (Test-Path $FfmpegBin) {
    $env:Path = "$FfmpegBin;$env:Path"
} else {
    Write-Warning "未找到本机 ffmpeg：$FfmpegBin（CLI 的 --render 烧字幕会不可用）"
}

# ---- 模型缓存与镜像 ----
# huggingface.co 本机直连不通，必须走 hf-mirror；权重放共享 HF 缓存，不散落在仓库里。
if (-not $env:HF_HOME) { $env:HF_HOME = 'E:\huggingface_cache' }
if (-not $env:HF_ENDPOINT) { $env:HF_ENDPOINT = 'https://hf-mirror.com' }
# hf-mirror 不代理 Xet 存储后端，不禁用会 401
if (-not $env:HF_HUB_DISABLE_XET) { $env:HF_HUB_DISABLE_XET = '1' }

$VenvPy = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
$BinDir = Join-Path $PSScriptRoot '.venv\Scripts'

function Show-GpuStatus {
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) {
        Write-Warning '未检测到 nvidia-smi，跳过 GPU 检查。'
        return
    }
    Write-Host '=== GPU 状态 ===' -ForegroundColor Cyan
    & nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,utilization.gpu --format=csv
}

function Assert-VenvReady {
    if (-not (Test-Path $VenvPy)) {
        throw @"
未找到虚拟环境：$VenvPy
请先在仓库根目录执行：
  uv venv --python 3.12 .venv
  uv pip install -e ".[torch-runtime]" --python .venv\Scripts\python.exe --torch-backend=auto
"@
    }
}

function Resolve-ModelDir {
    # 1) 显式指定优先
    if ($env:MOSS_MODEL_DIR -and (Test-Path (Join-Path $env:MOSS_MODEL_DIR 'config.json'))) {
        return (Resolve-Path $env:MOSS_MODEL_DIR).Path
    }
    # 2) 仓库内 pretrained/（上游 cli.py 的 DEFAULT_MODEL 约定）
    $local = Join-Path $PSScriptRoot 'pretrained\moss-transcribe-diarize'
    if (Test-Path (Join-Path $local 'config.json')) { return $local }
    # 3) 共享 HF 缓存快照（hub\ 与根目录两种布局都试）
    $snapshotRoots = @(
        (Join-Path $env:HF_HOME 'hub\models--OpenMOSS-Team--MOSS-Transcribe-Diarize\snapshots'),
        (Join-Path $env:HF_HOME 'models--OpenMOSS-Team--MOSS-Transcribe-Diarize\snapshots')
    )
    foreach ($root in $snapshotRoots) {
        if (-not (Test-Path $root)) { continue }
        $snap = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($snap -and (Test-Path (Join-Path $snap.FullName 'config.json'))) { return $snap.FullName }
    }
    throw @"
未找到模型权重（config.json）。请先下载：
  `$env:HF_HOME='$($env:HF_HOME)'
  `$env:HF_ENDPOINT='https://hf-mirror.com'
  hf download OpenMOSS-Team/MOSS-Transcribe-Diarize
或复用已有目录：`$env:MOSS_MODEL_DIR='<含 config.json 的目录>'
"@
}

function Test-PortBusy {
    param([int]$TargetPort)
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $TargetPort)
        $listener.Start()
        return $false
    } catch {
        return $true
    } finally {
        if ($null -ne $listener) { $listener.Stop() }
    }
}

function Get-FreePort {
    param(
        [int]$StartPort,
        [int]$MaxTries = 50
    )
    if ($StartPort -lt 1) { $StartPort = 1024 }
    $end = $StartPort + $MaxTries - 1
    if ($end -gt 65535) { $end = 65535 }
    $p = $StartPort
    while ($p -le $end) {
        if (-not (Test-PortBusy -TargetPort $p)) {
            if ($p -ne $StartPort) {
                Write-Host "端口 $StartPort 已占用，顺延到 $p" -ForegroundColor Yellow
            }
            return $p
        }
        $p++
    }
    throw "从 $StartPort 起连续探测均被占用，放弃。"
}

function Select-ServicesInteractive {
    param([object[]]$AllServices)

    if ($AllServices.Count -eq 0) {
        throw '未配置 $Services，请按项目改写模板。'
    }
    if ($AllServices.Count -eq 1) {
        Write-Host "仅一个服务，直接启动：$($AllServices[0].Label)" -ForegroundColor Cyan
        return @($AllServices[0])
    }

    Write-Host ''
    Write-Host '=== 启动哪些服务？===' -ForegroundColor Cyan
    for ($i = 0; $i -lt $AllServices.Count; $i++) {
        $svc = $AllServices[$i]
        $portHint = if ($svc.NeedsPort) { "端口起点 $($svc.PreferredPort)" } else { '无需端口' }
        Write-Host ("  [{0}] {1}  ({2})" -f ($i + 1), $svc.Label, $portHint)
    }
    Write-Host ("  [{0}] 全部开" -f ($AllServices.Count + 1))
    Write-Host '  [0] 取消'
    Write-Host ''

    $defaultChoice = '1'
    $raw = Read-Host "请选择（可多选，逗号分隔，如 1,2；默认 $defaultChoice）"
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $defaultChoice }

    if ($raw.Trim() -eq '0') {
        throw '已取消启动。'
    }

    $allIndex = $AllServices.Count + 1
    $parts = $raw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    $selected = [System.Collections.Generic.List[object]]::new()

    foreach ($part in $parts) {
        $n = 0
        if (-not [int]::TryParse($part, [ref]$n)) {
            throw "无效选项：$part"
        }
        if ($n -eq $allIndex) {
            return @($AllServices)
        }
        if ($n -lt 1 -or $n -gt $AllServices.Count) {
            throw "选项超出范围：$n"
        }
        $selected.Add($AllServices[$n - 1])
    }

    if ($selected.Count -eq 0) {
        throw '未选择任何服务。'
    }

    $byId = [ordered]@{}
    foreach ($s in $selected) { $byId[$s.Id] = $s }
    return @($byId.Values)
}

function Assert-GpuOkForSelection {
    param([object[]]$Selected)

    $gpuServices = @($Selected | Where-Object { $_.UsesGpu })
    if ($gpuServices.Count -le 1) { return }

    $labels = ($gpuServices | ForEach-Object { $_.Label }) -join ', '
    Write-Host ''
    Write-Host "已选多个占卡服务：$labels" -ForegroundColor Yellow
    Write-Host '16GB 显存下同时加载多份 0.9B 权重容易 OOM。请确认剩余显存足够，或改回只开一个。' -ForegroundColor Yellow
    $confirm = Read-Host '仍要继续？[y/N]'
    if ($confirm -notmatch '^[yY]') {
        throw '已取消：多服务占卡未确认。'
    }
}

# --- 服务清单 ---
$Services = @(
    [pscustomobject]@{
        Id            = 'web'
        Label         = '字幕工作台 Web UI（FastAPI + 静态前端，本地 HF 推理）'
        PreferredPort = 7860
        NeedsPort     = $true
        UsesGpu       = $true
    }
    [pscustomobject]@{
        Id            = 'cli'
        Label         = '单文件转写 CLI（一次性，出 SRT/ASS/JSON，可选烧字幕）'
        PreferredPort = 0
        NeedsPort     = $false
        UsesGpu       = $true
    }
)

function Start-ProjectService {
    param(
        [Parameter(Mandatory)]
        [object]$Service,

        [int]$ListenPort = 0
    )

    Assert-VenvReady
    $modelDir = Resolve-ModelDir
    Write-Host "模型目录：$modelDir" -ForegroundColor Cyan

    switch ($Service.Id) {
        'web' {
            $exe = Join-Path $BinDir 'mtd-subtitle-web.exe'
            if (-not (Test-Path $exe)) { throw "未找到 $exe，请确认依赖已安装。" }
            Write-Host "字幕工作台：http://127.0.0.1:$ListenPort" -ForegroundColor Green
            & $exe --model $modelDir --device cuda --dtype bf16 `
                --host 127.0.0.1 --port $ListenPort `
                --max-new-tokens $MaxNewTokens
        }
        'cli' {
            $exe = Join-Path $BinDir 'mtd-subtitle.exe'
            if (-not (Test-Path $exe)) { throw "未找到 $exe，请确认依赖已安装。" }
            $inputPath = Read-Host '输入音频/视频路径'
            if ([string]::IsNullOrWhiteSpace($inputPath)) { throw '未提供输入路径。' }
            $resolved = (Resolve-Path $inputPath -ErrorAction SilentlyContinue)
            if (-not $resolved) { throw "输入文件不存在：$inputPath" }
            $render = Read-Host '是否烧字幕到 MP4？需要 ffmpeg [y/N]'
            $extra = @()
            if ($render -match '^[yY]') { $extra += '--render' }
            & $exe $resolved.Path --model $modelDir --device cuda --dtype bf16 `
                --max-new-tokens $MaxNewTokens @extra
        }
        default {
            throw "未知服务 Id：$($Service.Id)"
        }
    }
}

Show-GpuStatus

if ($Service) {
    $match = @($Services | Where-Object { $_.Id -eq $Service })
    if ($match.Count -eq 0) {
        throw "未知服务 Id：$Service。可选：$($Services.Id -join ', ')"
    }
    $chosen = $match
} else {
    $chosen = Select-ServicesInteractive -AllServices $Services
    Assert-GpuOkForSelection -Selected $chosen
}

$multi = $chosen.Count -gt 1

if ($multi) {
    $started = @()
    foreach ($svc in $chosen) {
        $listen = 0
        if ($svc.NeedsPort) {
            $listen = Get-FreePort -StartPort $svc.PreferredPort
            Write-Host "$($svc.Label) 使用端口 $listen" -ForegroundColor Cyan
        }

        $argList = [System.Collections.Generic.List[string]]::new()
        $argList.AddRange([string[]]@('-NoProfile', '-File', $PSCommandPath, '-Service', $svc.Id, '-MaxNewTokens', "$MaxNewTokens"))
        if ($listen -gt 0) {
            $argList.Add('-Port')
            $argList.Add("$listen")
        }

        $p = Start-Process -FilePath 'pwsh' -ArgumentList $argList -PassThru -WorkingDirectory $PSScriptRoot
        $started += [pscustomobject]@{ Id = $svc.Id; Label = $svc.Label; Port = $listen; Pid = $p.Id }
        Write-Host "已后台启动 $($svc.Label) PID=$($p.Id)" -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '=== 已启动 ===' -ForegroundColor Cyan
    foreach ($s in $started) {
        $portInfo = if ($s.Port -gt 0) { " port=$($s.Port)" } else { '' }
        Write-Host ("- {0}{1} pid={2}" -f $s.Label, $portInfo, $s.Pid)
    }
    Write-Host '各服务在独立进程中运行；结束请自行停对应 PID。' -ForegroundColor Yellow
    return
}

$svc = $chosen[0]
$listen = 0
if ($svc.NeedsPort) {
    $startPort = $svc.PreferredPort
    if ($Port -gt 0) { $startPort = $Port }
    $listen = Get-FreePort -StartPort $startPort
    Write-Host "$($svc.Label) 使用端口 $listen" -ForegroundColor Cyan
}

Start-ProjectService -Service $svc -ListenPort $listen