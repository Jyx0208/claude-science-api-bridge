# Windows 使用说明

本目录下的 `scripts/windows/` 提供完整的 Windows 原生适配脚本（PowerShell 5.1+，无需管理员权限），让你在 Windows 10/11 上把 Claude Science 桌面版接到任意第三方 API。

## 原理

```
Claude Science (Windows) → 本地代理 127.0.0.1:9876 → 你的第三方 API（智谱/DeepSeek/Kimi/OpenAI/...）
        ↑                        ↑
   补丁后的 exe 认为           Anthropic ↔ OpenAI 格式转换（或 Anthropic 原生直通）
   在连官方，假 OAuth 令牌
```

与 macOS/Linux 版完全同机制：等长二进制补丁 + 假登录令牌 + 本地翻译代理。区别仅在于 Windows 版直接补丁安装目录的 `claude-science.exe`（Windows 没有 `~/.claude-science/bin` daemon 副本）。

## 前提条件

- Windows 10/11，PowerShell 5.1 以上（系统自带）
- Python 3.9+（[python.org](https://www.python.org/downloads/) 安装时勾选 "Add to PATH"，或已有 conda）
- 已安装 Claude Science 桌面版（`%LOCALAPPDATA%\Programs\ClaudeScience\claude-science.exe`，官方 CDN 提供 windows-x64 二进制）
- 一家第三方 API 的密钥

## 安装

### 方式 A：环境变量文件（推荐）

把配置写进项目根目录的 `.env.tmp`（bash 风格，支持引号和行尾 `\` 续行）：

```bash
CUSTOM_API_KEY="你的密钥" \
CUSTOM_BASE_URL="https://open.bigmodel.cn/api/anthropic" \
CUSTOM_UPSTREAM_MODE="anthropic" \
DEFAULT_BACKEND="custom" \
FORCE_MODEL="glm-5.3" \
MODEL_LIST_MODE="aliases" \
MODEL_MENU_STRATEGY="claude_compatible" \
MODEL_ALIASES='[{"id":"claude-sonnet-4-5","display_name":"GLM-5.3","backend":"custom","model":"glm-5.3"}]' \
INLINE_IMAGE_POLICY="auto" \
PROXY_PORT="9876"
```

然后以智谱 BigModel 的 **Anthropic 原生端点**为例运行安装：

```powershell
cd C:\Users\<你>\claude-science-api-bridge
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\install-safe.ps1
```

也可以直接双击 `scripts\windows\install-safe.bat`。

安装脚本会自动完成：

1. 在项目根目录创建 `.venv` 虚拟环境并安装依赖（失败自动改用清华 pip 镜像；系统 Python 不被污染）
2. 从 `config.example.json` 创建 `config.json` 并应用上述环境变量
3. 生成假 OAuth 登录令牌（`~/.claude-science/.oauth-tokens/`，有效期到 2099 年）
4. 关闭正在运行的 Claude Science，对 `claude-science.exe` 做**免登录补丁**和**模型菜单补丁**（均先备份）
5. 注册开机自启快捷方式（`-NoStartup` 跳过）
6. 后台启动代理并做健康检查

### 方式 B：装完后在 Dashboard 配置

先不带任何环境变量安装（或 `-NoStartup`），然后打开 `http://127.0.0.1:9876/dashboard`，在 Providers 里填 API key、base URL，拉取模型列表，一键测试。

### 常用参数

| 参数 | 作用 |
| --- | --- |
| `-NoStartup` | 不注册开机自启 |
| `-NoAuthPatch` | 跳过免登录补丁 |
| `-NoModelPatch` | 跳过模型菜单补丁 |
| `-Python <路径>` | 指定引导用的 python.exe |
| `-EnvFile <路径>` | 指定环境变量文件（默认依次找 `.env.tmp`、`.env`） |

## 常见 provider 配置

| 供应商 | CUSTOM_BASE_URL | CUSTOM_UPSTREAM_MODE | FORCE_MODEL 示例 |
| --- | --- | --- | --- |
| 智谱 BigModel | `https://open.bigmodel.cn/api/anthropic` | `anthropic` | `glm-5.3` |
| DeepSeek | `https://api.deepseek.com` | `openai` | `deepseek-chat` |
| 硅基流动 Kimi | `https://api.siliconflow.cn` | `openai` | `Pro/moonshotai/Kimi-K2.6` |
| OpenAI | `https://api.openai.com` | `openai` | `gpt-4o` |
| 任意 OneAPI/NewAPI 中转 | 你的中转地址 | `openai` | 任意 |

有 Anthropic 原生端点的优先用 `anthropic` 模式（直通不翻译，tool calls / 流式完整保留），没有就用 `openai` 模式。

## 启动 Claude Science

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\start-claude-science.ps1
```

该脚本每次启动都会：确保代理在跑 → 刷新令牌 → 检查并（在需要时）重放补丁 → 以 `ANTHROPIC_BASE_URL=http://127.0.0.1:9876` 启动应用。**Claude Science 自动更新替换 exe 后补丁会失效，用这个脚本启动即可自动重打**，无需手动处理。

## 验证

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\verify-proxy.ps1
```

依次验证 health → models → messages → recent-requests；配置了视觉模型可加 `-VerifyImage` 做真实读图验证。日常诊断用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\doctor.ps1
```

## 日常使用

| 操作 | 命令 |
| --- | --- |
| 启动代理（后台、无窗口） | `scripts\windows\start-proxy.ps1` |
| 停止代理 | `scripts\windows\stop-proxy.ps1` |
| 启动 Claude Science（自动走代理） | `scripts\windows\start-claude-science.ps1` |
| 诊断 | `scripts\windows\doctor.ps1` |
| 端到端验证 | `scripts\windows\verify-proxy.ps1` |
| Dashboard | `http://127.0.0.1:9876/dashboard` |

代理日志在 `~/.claude-science/logs/proxy.log` 和 `proxy-error.log`，PID 文件在 `~/.claude-science/proxy.pid`。

## 安全说明

- 默认不修改系统代理、DNS、hosts、证书、防火墙，不占用 443 端口
- 二进制补丁只改用户目录安装的 exe，改前自动备份（`.byok-auth-original` / `.byok-model-original`），可随时还原
- 补丁会使 exe 的官方数字签名失效。Windows 运行本地未签名 exe 没有问题，但**杀毒软件可能告警**，如遇误报请将 Claude Science 安装目录加入信任
- `config.json` 含 API 密钥，不要截图或提交；脚本输出和日志均对密钥脱敏

## 端口要求

代理端口必须保持 **4 位数字**（默认 9876）——免登录补丁是等长字节替换，5 位端口会导致补丁失败。

## 卸载

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\uninstall.ps1
```

停止代理、删除自启快捷方式、从备份还原原始 exe。加 `-PurgeConfig` 同时删除 `config.json` 和补丁状态文件；OAuth 令牌和日志会保留。

## 故障排查

| 现象 | 处理 |
| --- | --- |
| `File is locked` / 补丁失败 | Claude Science 正在运行占用了 exe；先关闭它（脚本一般会自动关闭，也可手动结束 claude-science.exe 进程）再重试 |
| 代理起不来 | 看 `~/.claude-science/logs/proxy-error.log`；端口被占用时换一个 4 位端口（改 `config.json` 的 `proxy_port` 和 `.env.tmp` 后重装） |
| pip 安装失败 | 脚本会自动重试清华镜像；仍失败请检查网络后重跑 `install-safe.ps1` |
| Claude Science 显示未登录 | 确认 `.oauth-tokens/` 下有 `.enc` 令牌文件；重新运行 `start-claude-science.ps1`（会刷新令牌并重放补丁） |
| 更新 Claude Science 后又要求登录 | 正常现象（更新还原了 exe）；用 `start-claude-science.ps1` 启动会自动重打补丁 |
| 模型回复为空/只有思考 | 带 thinking 的模型请把 `max_tokens` 调大（512 以上） |
| 杀软报警 | 补丁导致签名失效的正常现象，将安装目录加白名单 |

更多通用排错见 [troubleshooting.md](troubleshooting.md)。
