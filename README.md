# Claude Science API Bridge

让 Claude Science 安全接入 DeepSeek、OpenAI、硅基流动 Kimi 与任意 OpenAI 兼容第三方 API 的本地代理和 agent 配置手册。

最新 macOS 一键安装包：[`Claude Science API Bridge.dmg`](https://github.com/Jyx0208/claude-science-api-bridge/releases/latest)

这个项目不只是一个代理程序，也是一份给 AI agent 读取的操作说明书。把仓库交给 Codex、Claude Code 或其他本地 agent 后，它可以先读 `AGENTS.md` 和 `docs/agent-runbook.md`，再按步骤完成诊断、安装、配置和验证。

## 功能

- 提供 macOS `.app + .dmg` 一键安装包，首次打开即可选择 provider 并写入本地配置
- 在本机启动 Anthropic 兼容接口：`http://127.0.0.1:9876`
- 将 Claude Science 的 Anthropic Messages API 请求转换为 OpenAI Chat Completions 请求
- 将 DeepSeek、OpenAI 或其他 OpenAI 兼容接口的响应转换回 Anthropic 格式
- 支持流式、非流式、工具调用、工具结果、真实图片输入和基础 token 计数
- 对支持视觉的 OpenAI 兼容模型保留图片输入；对文本模型可自动省略图片，避免后端报错
- 自动生成 Claude Science 可接受的本地 fake OAuth token
- 支持第三方模型别名，让 Claude Science 模型选择里显示 Kimi、Qwen、GPT 等真实后端模型名
- 可安全补丁本地 daemon 复制件，把硬编码的 Opus/Sonnet 菜单替换成 BYOK 模型菜单
- 支持 Provider 预设、OpenAI 兼容翻译与 Anthropic 原生透传两种上游模式
- 支持可选 path-secret 本地鉴权，避免本机其他进程随便调用你的第三方 key
- 支持按模型配置 `max_tokens` 上限，减少第三方 provider 因输出上限报 400
- 提供 Web 管理面板：`http://127.0.0.1:9876/dashboard`
- 支持 macOS LaunchAgent 后台运行和开机自启
- 提供 agent runbook，方便 AI agent 在用户电脑上安全接管配置

## 默认安全策略

默认安装只走安全模式，不会修改：

- Clash、VPN、TUN、DNS 或系统代理配置
- `/etc/hosts`
- macOS 系统证书信任
- `443` 端口

如果 Claude Science 的某些硬编码 HTTPS 请求必须拦截，可以使用高级模式，但需要先阅读 `docs/network-interception.md`，并由用户明确同意。

本项目也吸收了 [CSswitch](https://github.com/SuperJJ007/CSswitch) 的几个安全设计：入站 Claude OAuth/API key 不转发给第三方、Provider 预设、path-secret 本地鉴权、优先使用 provider 的 Anthropic 原生端点。我们的默认模式仍保持兼容：不强制 secret，不默认切换用户已经跑通的 provider。

## 用户怎么使用

最简单的方式是下载 macOS 发布包：

1. 下载 `Claude Science API Bridge.dmg`
2. 双击打开 `Claude Science API Bridge.app`
3. 按弹窗选择 provider，输入自己的 API key
4. App 会自动安装本地代理、打开 Dashboard，并启动 Claude Science

如果首次打开被 macOS 拦截，请在 Finder 里右键 App，选择“打开”。

Agent 安装方式也仍然支持。推荐做法是：把下面这段 prompt 复制给你的本地 agent，让 agent 阅读仓库、诊断环境、安装、配置并验证。

你只需要准备：

- 一台 macOS 电脑
- 已安装 Claude Science
- 一个 DeepSeek、OpenAI 或其他 OpenAI 兼容 API key

## 直接复制给 Agent 的 Prompt

把下面整段发给 Codex、Claude Code 或其他能操作本机终端的 agent：

```text
请你帮我在这台 macOS 上配置 Claude Science API Bridge，让 Claude Science 使用第三方 OpenAI 兼容 API。

仓库地址：
https://github.com/Jyx0208/claude-science-api-bridge

目标：
1. 使用安全模式完成安装和配置。
2. 让 Claude Science 的 Anthropic API 请求走本地代理 127.0.0.1:9876。
3. 后端使用我提供的第三方 API。
4. 如果我要求读图，请使用支持视觉输入的模型，不要把图片替换成文本占位。
5. 让 Claude Science 的模型选择里显示第三方模型别名，而不是只显示 Opus / Sonnet / Haiku。
6. 完成端到端验证，确认 /v1/models 和 /v1/messages 都成功；如果启用读图，还要完成图片请求验证。

我的后端配置：
- provider: DeepSeek / OpenAI / Custom（三选一；硅基流动 Kimi 请选择 Custom；如果我没写，请先问我）
- api_key: 我会单独给你；不要把 key 打印到日志或最终回复里
- base_url: 如果是 DeepSeek 用 https://api.deepseek.com；如果是 OpenAI 用 https://api.openai.com；如果是硅基流动用 https://api.siliconflow.cn；如果是其他 Custom 请先问我
- model: 第三方服务实际支持的模型名；如果我没写，请先问我
- image_support: 如果我需要读图，请确认模型支持视觉输入，并设置 inline_image_policy=preserve 或 auto

安全要求：
1. 先完整阅读仓库结构，以及 README.md、AGENTS.md、docs/agent-runbook.md、docs/troubleshooting.md、scripts/doctor.sh、scripts/install-safe.sh、scripts/verify-proxy.sh。
2. 默认只使用安全模式，不要修改 Clash、VPN、TUN、DNS、系统代理、/etc/hosts、系统证书信任或 443 端口。
3. 不要 reload Clash，不要改任何网络代理配置。
4. 不要输出、提交、总结或截图我的 API key、OAuth token、证书私钥。
5. 如果你认为必须使用高级 HTTPS 拦截，必须先停下来解释原因并单独征求我的明确同意。

执行要求：
1. 如果本机还没有仓库，请 clone 到 ~/.claude-science/proxy；如果已有仓库，请进入该目录并拉取最新 main。
2. 先运行 ./scripts/doctor.sh 做只读诊断。
3. 按 AGENTS.md 和 docs/agent-runbook.md 执行安全安装。
4. 将 API key 和模型配置写入本地 config.json，确保 config.json 不会提交到 Git。
5. 配置 model_aliases 和 model_list_mode=aliases，让 /v1/models 只返回第三方模型别名。
6. 运行 ./scripts/self-test.sh。
7. 启动或重启代理服务。
8. 运行 ./scripts/verify-proxy.sh 做 health、models、messages 和 recent-requests 验证。
9. 如果模型支持读图，运行 VERIFY_IMAGE=1 ./scripts/verify-proxy.sh 做真实图片输入验证。
10. 运行 ./scripts/start-claude-science.sh，让脚本自动刷新 token、补丁本地 daemon 复制件并重启 Claude Science。
11. 再检查 http://127.0.0.1:9876/api/recent-requests，确认 Claude Science 命中了本地代理。

如果遇到问题：
1. 先运行 ./scripts/doctor.sh。
2. 阅读 docs/troubleshooting.md。
3. 优先修安全模式路径。
4. 不要通过修改 Clash 或系统网络配置来“试一试”。

最终回复请只告诉我：
1. 是否安装成功。
2. 使用的 provider、base_url 和模型名，但不要显示 API key。
3. 验证结果摘要。
4. Dashboard 地址。
5. 如果失败，明确卡在哪一步以及下一步需要我提供什么。
```

## 给 Agent 的入口

如果你是 AI agent，请不要让用户手动安装。你应该按顺序读取：

1. `AGENTS.md`
2. `docs/agent-runbook.md`
3. `docs/troubleshooting.md`
4. `docs/network-interception.md`，仅在用户明确允许高级拦截时读取和执行
5. `docs/github-publishing.md`，仅在需要发布到 GitHub 时读取

推荐执行流程：

```bash
./scripts/doctor.sh
./scripts/install-safe.sh
./scripts/self-test.sh
./scripts/verify-proxy.sh
```

`doctor.sh` 是只读诊断脚本；agent 应先运行它，不要直接猜测用户机器状态。

## Provider 配置示例

### DeepSeek

```json
{
  "deepseek_api_key": "REDACTED",
  "deepseek_base_url": "https://api.deepseek.com",
  "default_backend": "deepseek",
  "force_model": "deepseek-chat",
  "inline_image_policy": "auto"
}
```

### OpenAI

```json
{
  "openai_api_key": "REDACTED",
  "openai_base_url": "https://api.openai.com",
  "default_backend": "openai",
  "force_model": "gpt-4o",
  "inline_image_policy": "preserve"
}
```

### 任意 OpenAI 兼容 API

```json
{
  "custom_api_key": "REDACTED",
  "custom_base_url": "https://provider.example.com",
  "custom_upstream_mode": "openai",
  "default_backend": "custom",
  "force_model": "provider-model-name",
  "model_aliases": [
    {
      "id": "byok-model-0001",
      "display_name": "Provider Model",
      "backend": "custom",
      "model": "provider-model-name"
    }
  ],
  "model_list_mode": "aliases",
  "model_token_caps": {
    "provider-model-name": 8192
  },
  "default_max_tokens_cap": 0,
  "inline_image_policy": "auto"
}
```

`custom_base_url` 可以写成 `https://provider.example.com`，也可以写成 `https://provider.example.com/v1`，代理会自动规范化。

### 硅基流动 Kimi 示例

```json
{
  "custom_api_key": "REDACTED",
  "custom_base_url": "https://api.siliconflow.cn",
  "custom_upstream_mode": "openai",
  "default_backend": "custom",
  "force_model": "Pro/moonshotai/Kimi-K2.6",
  "model_aliases": [
    {
      "id": "byok-model-0001",
      "display_name": "Kimi K2.6 Pro++",
      "backend": "custom",
      "model": "Pro/moonshotai/Kimi-K2.6"
    }
  ],
  "model_list_mode": "aliases",
  "inline_image_policy": "preserve",
  "reasoning_content_policy": "never"
}
```

`reasoning_content_policy` 默认应保持 `never`。部分后端会把内部思考、会话恢复记录或执行计划放在 `reasoning_content` 或普通 `content` 前缀里；代理会尽量过滤这些工作记录，避免它们作为普通对话显示。

## 上游协议模式

每个后端都有一个 `*_upstream_mode`：

- `openai`：Claude Science 的 Anthropic 请求先由本代理翻译成 OpenAI Chat Completions，再发给第三方。适合硅基流动 Kimi、DashScope Qwen、OpenAI 兼容聚合器等。
- `anthropic`：第三方 provider 本身支持 Anthropic Messages API，本代理只替换模型名和鉴权头后透传。工具调用、thinking、流式事件更保真。适合 DeepSeek Anthropic、Moonshot Anthropic、部分 provider 的原生 Claude 兼容端点。

DeepSeek 原生 Anthropic 示例：

```json
{
  "deepseek_api_key": "REDACTED",
  "deepseek_base_url": "https://api.deepseek.com/anthropic",
  "deepseek_upstream_mode": "anthropic",
  "default_backend": "deepseek",
  "force_model": "deepseek-chat"
}
```

Dashboard 的「Provider 预设」可以快速套用常见 provider 的 base URL、协议模式、默认模型和模型别名。套用预设不会写入 API key；key 仍需本地配置。

## 本地 Path-Secret

默认 `proxy_auth_mode=optional`，保持旧用法：

```text
ANTHROPIC_BASE_URL=http://127.0.0.1:9876
```

如果需要更严格的本机访问控制，可以配置：

```json
{
  "proxy_auth_token": "生成一段随机长字符串",
  "proxy_auth_mode": "required"
}
```

之后启动脚本会自动使用：

```text
ANTHROPIC_BASE_URL=http://127.0.0.1:9876/<secret>
```

日志和 Dashboard 会对 secret 脱敏；没有 secret 的 `/v1/messages`、`/v1/models` 请求会返回 403。

## 模型选择显示第三方模型

Claude Science 的模型选择界面有一部分来自本地 daemon 的硬编码模型列表，因此只改 `/v1/models` 不一定能让界面立刻显示第三方模型名。

安全安装和启动脚本会自动运行：

```bash
./scripts/patch-daemon-models.sh
```

这个脚本只修改 `~/.claude-science/bin/claude-science` 这一份用户目录里的 daemon 复制件，不修改 `/Applications/Claude Science.app`，也不修改 Clash、DNS、系统代理、证书或 443 端口。脚本会：

- 备份本地 daemon 复制件
- 把 Claude-facing 模型 ID 改成固定别名：`byok-model-0001`、`byok-model-0002`、`byok-model-000003`
- 把显示名改成 `model_aliases` 里的第三方模型名
- 同步写回 `config.json`，确保这些菜单 ID 能路由到真实后端模型
- 重新 ad-hoc 签名并执行 daemon 可运行检查

常用配置：

```json
{
  "model_aliases": [
    {
      "id": "byok-model-0001",
      "display_name": "Kimi K2.6 Pro++",
      "backend": "custom",
      "model": "Pro/moonshotai/Kimi-K2.6"
    }
  ],
  "model_list_mode": "aliases"
}
```

`model_aliases` 中的 `id` 是 Claude Science 看到的模型 ID，`model` 是实际发给第三方 API 的模型名。别名命中时会优先于 `force_model`，所以用户在菜单里选择哪个第三方别名，代理就会调用对应的真实模型。

## 图片 / 读图能力

Claude Science 发出的 Anthropic 图片 block 会被代理转换成 OpenAI 兼容的 `image_url` 内容。只要后端模型本身支持视觉输入，就可以让模型真正读图，而不是用文本占位替代图片。

`inline_image_policy` 支持：

- `auto`：默认策略。DeepSeek 这类文本后端会省略图片；Custom/OpenAI 后端会保留图片。
- `preserve`：始终把图片发送给后端。适合 Kimi、GPT-4o、Qwen-VL 等视觉模型。
- `omit`：始终省略图片。适合只想跑文本的便宜模型。
- `omit_inline`：只省略 base64 内联图片，保留外部图片 URL。

对硅基流动 Kimi，代理会在本机把内联 PNG/WebP/GIF/HEIC 转成 JPEG data URL 再发送，避免部分服务拒绝 PNG base64。图片不会被上传到临时图床；只会随请求发送到你配置的后端 API。

读图验收由 agent 执行：

```bash
VERIFY_IMAGE=1 ./scripts/verify-proxy.sh
```

这个测试会生成一张红色图片，通过 Anthropic 图片格式发给本地代理，并要求后端模型回答 `red`。如果模型不支持视觉输入，这一步应该失败，agent 需要换成支持视觉的模型或把图片策略改回 `omit`。

## Agent 验收标准

下面这些命令由 agent 执行，不要求用户自己运行：

```bash
./scripts/doctor.sh
./scripts/self-test.sh
./scripts/verify-proxy.sh
curl -sS http://127.0.0.1:9876/health
curl -sS http://127.0.0.1:9876/v1/models
curl -sS http://127.0.0.1:9876/v1/messages \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-sonnet-4-5","max_tokens":32,"messages":[{"role":"user","content":"Reply OK"}]}'
```

如果配置的是视觉模型，agent 还应执行：

```bash
VERIFY_IMAGE=1 ./scripts/verify-proxy.sh
```

agent 还应检查最近请求：

```bash
curl -sS http://127.0.0.1:9876/api/recent-requests
```

## 构建发布包

维护者或 agent 可以在 macOS 上生成 `.app` 和 `.dmg`：

```bash
./scripts/build-macos-release.sh
./scripts/smoke-test-release-package.sh
```

产物位于：

```text
dist/Claude Science API Bridge.app
dist/Claude Science API Bridge.dmg
```

发布包不会包含 `config.json`、证书、日志、`.env` 或 Git 历史。详细说明见 `docs/release-packaging.md`。

## 项目结构

```text
.
├── AGENTS.md
├── README.md
├── SECURITY.md
├── config.example.json
├── proxy.py
├── setup-token.py
├── start.sh
├── install.sh
├── setup-network.sh
├── requirements.txt
├── scripts/
│   ├── doctor.sh
│   ├── install-safe.sh
│   ├── patch-daemon-auth.sh
│   ├── patch-daemon-models.sh
│   ├── restore-daemon-auth.sh
│   ├── self-test.sh
│   ├── start-claude-science.sh
│   ├── uninstall.sh
│   └── verify-proxy.sh
├── docs/
│   ├── agent-runbook.md
│   ├── github-publishing.md
│   ├── network-interception.md
│   ├── release-packaging.md
│   └── troubleshooting.md
├── packaging/
│   └── macos/
│       ├── app-launcher.sh
│       └── build-release.sh
└── static/
    └── dashboard.html
```

## 不要提交的文件

`.gitignore` 已排除本地敏感文件和运行态文件：

- `config.json`
- `.env`
- `certs/`
- `*.plist`
- 日志
- Python 缓存

发布前请确认：

```bash
git status --ignored
```

确保 API key、OAuth token、证书私钥和本地日志没有被加入 Git。

## 许可证

MIT。见 `LICENSE`。


友情链接 https://linux.do/
