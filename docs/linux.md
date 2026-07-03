# Linux 适配说明

Linux 支持目前覆盖本地代理、Dashboard、配置管理和 OpenAI 兼容第三方 API 转换。Claude Science 桌面应用本身仍是 macOS 应用，因此 Linux 侧不会启动 Claude Science，也不会执行 macOS daemon OAuth/模型菜单补丁。

适合的 Linux 使用场景：

- 在 Linux 上运行本地 Anthropic-compatible 代理
- 让支持 `ANTHROPIC_BASE_URL` 的客户端接入第三方 API
- 使用 Dashboard 管理 provider、模型映射、图片输入策略和更新检查
- 用 systemd user service 或用户后台进程保持代理运行

## 安装

```bash
git clone https://github.com/Jyx0208/claude-science-api-bridge.git
cd claude-science-api-bridge
./scripts/install-safe.sh
```

安装脚本会：

1. 创建 `.venv` 并安装 Python 依赖
2. 如果没有 `config.json`，从 `config.example.json` 创建
3. 从环境变量写入 provider 配置
4. 优先安装并启动 `systemd --user` 服务
5. 如果 systemd user 不可用，退回到当前用户后台进程
6. 打开本地 HTTP 代理：`http://127.0.0.1:9876`

脚本不会修改系统代理、DNS、VPN、TUN、`/etc/hosts`、系统证书或 443 端口。

## 用环境变量一次性配置

以硅基流动 Kimi 为例：

```bash
CUSTOM_API_KEY="sk-..." \
CUSTOM_BASE_URL="https://api.siliconflow.cn" \
DEFAULT_BACKEND="custom" \
FORCE_MODEL="Pro/moonshotai/Kimi-K2.6" \
CUSTOM_UPSTREAM_MODE="openai" \
INLINE_IMAGE_POLICY="preserve" \
./scripts/install-safe.sh
```

然后给兼容客户端设置：

```bash
export ANTHROPIC_BASE_URL="http://127.0.0.1:9876"
```

## systemd 用户服务

安装成功后可检查：

```bash
systemctl --user status claude-science-api-bridge.service
curl -sS http://127.0.0.1:9876/health
```

重启：

```bash
systemctl --user restart claude-science-api-bridge.service
```

查看日志：

```bash
journalctl --user -u claude-science-api-bridge.service -f
```

如果系统没有启用 systemd user session，安装脚本会启动 fallback 后台进程，并把 PID 写入：

```text
~/.claude-science/proxy.pid
```

## 验证

```bash
./scripts/self-test.sh
./scripts/verify-proxy.sh
curl -sS http://127.0.0.1:9876/v1/models
```

视觉模型验证：

```bash
VERIFY_IMAGE=1 ./scripts/verify-proxy.sh
```

## 卸载服务

```bash
./scripts/uninstall.sh
```

这只会移除 Linux user service 或 fallback 进程，不会删除 `config.json`、API key、日志或 token。

## 当前限制

- Claude Science 桌面启动和 daemon patch 仍是 macOS 专用。
- Linux 暂未提供 `.deb`、`.rpm`、AppImage 或 Docker 发布包。
- Dashboard 的一键更新目前安装 macOS DMG；Linux 包管理式更新会在后续版本补齐。
