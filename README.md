# Claude Science API Bridge

让 Claude Science 安全接入 DeepSeek、OpenAI 与任意 OpenAI 兼容第三方 API 的本地代理和 agent 配置手册。

这个项目不只是一个代理程序，也是一份给 AI agent 读取的操作说明书。把仓库交给 Codex、Claude Code 或其他本地 agent 后，它可以先读 `AGENTS.md` 和 `docs/agent-runbook.md`，再按步骤完成诊断、安装、配置和验证。

## 功能

- 在本机启动 Anthropic 兼容接口：`http://127.0.0.1:9876`
- 将 Claude Science 的 Anthropic Messages API 请求转换为 OpenAI Chat Completions 请求
- 将 DeepSeek、OpenAI 或其他 OpenAI 兼容接口的响应转换回 Anthropic 格式
- 支持流式、非流式、工具调用、工具结果、图片 block 和基础 token 计数
- 自动生成 Claude Science 可接受的本地 fake OAuth token
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

## 快速开始

```bash
cd ~/.claude-science/proxy
./install.sh
open http://127.0.0.1:9876/dashboard
```

然后在面板里：

1. 配置 DeepSeek、OpenAI 或 Custom OpenAI-compatible API。
2. 设置 `default_backend`。
3. 设置 `force_model` 为你的第三方服务实际支持的模型名。
4. 启动 Claude Science：

```bash
open -a "Claude Science"
```

## 给 Agent 的入口

如果你是 AI agent，请按顺序读取：

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
```

`doctor.sh` 是只读诊断脚本；agent 应先运行它，不要直接猜测用户机器状态。

## Provider 配置示例

### DeepSeek

```json
{
  "deepseek_api_key": "REDACTED",
  "deepseek_base_url": "https://api.deepseek.com",
  "default_backend": "deepseek",
  "force_model": "deepseek-chat"
}
```

### OpenAI

```json
{
  "openai_api_key": "REDACTED",
  "openai_base_url": "https://api.openai.com",
  "default_backend": "openai",
  "force_model": "gpt-4o"
}
```

### 任意 OpenAI 兼容 API

```json
{
  "custom_api_key": "REDACTED",
  "custom_base_url": "https://provider.example.com",
  "default_backend": "custom",
  "force_model": "provider-model-name"
}
```

`custom_base_url` 可以写成 `https://provider.example.com`，也可以写成 `https://provider.example.com/v1`，代理会自动规范化。

## 验证

```bash
curl -sS http://127.0.0.1:9876/health
curl -sS http://127.0.0.1:9876/v1/models
curl -sS http://127.0.0.1:9876/v1/messages \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-sonnet-4-5","max_tokens":32,"messages":[{"role":"user","content":"Reply OK"}]}'
```

查看最近请求：

```bash
curl -sS http://127.0.0.1:9876/api/recent-requests
```

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
│   ├── self-test.sh
│   ├── start-claude-science.sh
│   └── uninstall.sh
├── docs/
│   ├── agent-runbook.md
│   ├── github-publishing.md
│   ├── network-interception.md
│   └── troubleshooting.md
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

