# macOS 发布包

本项目提供轻量 macOS `.app + .dmg` 发布包。目标是让普通用户不需要打开终端：

1. 下载 `.dmg`
2. 双击 `Claude Science API Bridge.app`
3. 按系统弹窗选择 provider 并输入自己的 API key
4. App 自动安装本地代理、配置 LaunchAgent、刷新本地 OAuth、补丁模型菜单、启动 Claude Science、打开 Dashboard

## 构建

由维护者或 agent 执行：

```bash
./scripts/build-macos-release.sh
```

输出：

```text
dist/Claude Science API Bridge.app
dist/Claude Science API Bridge.dmg
```

构建脚本不会打包以下本机敏感文件：

- `config.json`
- `.env`
- `certs/`
- `.daemon-model-patch.json`
- `.git`
- `.venv`
- 日志和 Python 缓存

## App 首次启动行为

App 内置仓库代码，首次启动时会同步到：

```text
~/.claude-science/proxy
```

如果本机还没有配置 API key，App 会用系统弹窗询问：

- Provider
- API key
- Custom provider 的 base URL 和模型名

API key 只写入本机 `~/.claude-science/proxy/config.json`，权限为 `0600`。它不会进入命令行参数、日志、Git 仓库或发布包。

随后 App 会执行：

```bash
./scripts/install-safe.sh
./scripts/start-claude-science.sh
```

安全边界与命令行安装相同：默认不会修改 Clash、VPN、TUN、DNS、系统代理、`/etc/hosts`、系统证书信任或 443 端口。

## 用户说明

首次打开未公证 app 时，macOS 可能提示无法验证开发者。用户可以：

1. 在 Finder 里右键 `Claude Science API Bridge.app`
2. 选择“打开”
3. 在弹窗中再次点击“打开”

这是未做 Apple 公证的开源发布包常见行为。当前构建脚本只做 ad-hoc 签名。

## 维护者发布前检查

```bash
./scripts/self-test.sh
./scripts/build-macos-release.sh
git status --ignored
```

确认 `dist/` 是 ignored，且 `config.json`、`certs/` 没有被暂存。
