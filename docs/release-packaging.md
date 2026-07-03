# macOS 发布包

本项目提供轻量 macOS `.app + .dmg` 发布包。目标是让普通用户不需要打开终端：

1. 下载 `.dmg`
2. 双击 `Claude Science API Bridge.app`
3. 按系统弹窗选择 provider 并输入自己的 API key
4. App 自动安装本地代理、配置 LaunchAgent、刷新本地 OAuth、补丁模型菜单、启动 Claude Science、打开 Dashboard

## 构建

由维护者或 agent 执行：

```bash
printf '0.2.6\n' > VERSION
./scripts/build-macos-release.sh
./scripts/smoke-test-release-package.sh
```

`packaging/macos/build-release.sh` 会把 `VERSION` 写入 `Info.plist`，代理也会在 `/health` 和 Dashboard 中显示同一个版本。发布 GitHub Release 后，已安装用户的 Dashboard 会检查 Latest Release，并在发现更高版本时显示更新提醒和“一键更新”按钮。

一键更新依赖 GitHub Release 里存在这个 DMG asset：

```text
Claude.Science.API.Bridge.dmg
```

如果 GitHub API 暂时限流，Dashboard 会回退到 `releases/latest/download/Claude.Science.API.Bridge.dmg`，所以发布时请保持 asset 文件名稳定。

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

最便捷安装方式：

```bash
curl -fsSL https://raw.githubusercontent.com/Jyx0208/claude-science-api-bridge/main/scripts/install-macos-app.sh | bash
```

这个脚本会：

1. 下载 latest release 的 DMG
2. 挂载 DMG
3. 复制 App 到 `~/Applications`
4. 移除 `com.apple.quarantine` 标记
5. 打开 App

这能绕过未公证包的 Gatekeeper 首次打开阻塞，但前提是用户信任本项目源码和 GitHub Release。

首次打开未公证 app 时，macOS 可能提示无法验证开发者。用户可以：

1. 在 Finder 里右键 `Claude Science API Bridge.app`
2. 选择“打开”
3. 在弹窗中再次点击“打开”

这是未做 Apple 公证的开源发布包常见行为。当前构建脚本只做 ad-hoc 签名。

另一种本机临时方式是移除 quarantine 标记：

```bash
xattr -dr com.apple.quarantine "/Applications/Claude Science API Bridge.app"
```

只应对自己信任、来源明确的包这样做。

## 正式公证发布

要消除“Apple 无法验证是否包含恶意软件”这类 Gatekeeper 警告，需要 Apple Developer Program 账号、Developer ID Application 证书，以及 Apple notarytool 凭证。

Apple 官方文档说明，分发到 Mac App Store 之外的 Developer ID 软件通常需要 notarization；notarytool 是当前推荐的公证工具。参考：

- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [TN3147: Migrating to the latest notarization tool](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)

推荐先把 notarytool 凭证保存到 Keychain：

```bash
xcrun notarytool store-credentials "claude-science-api-bridge-notary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

然后执行：

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
NOTARYTOOL_PROFILE="claude-science-api-bridge-notary" \
./scripts/notarize-macos-release.sh
```

脚本会：

1. 重新构建 `.app`
2. 用 Developer ID 和 hardened runtime 签名 `.app`
3. 重新生成并签名 `.dmg`
4. 用 `xcrun notarytool submit --wait` 提交 Apple 公证
5. 用 `xcrun stapler staple` 把票据 stapled 到 DMG
6. 用 `spctl` 做 Gatekeeper 评估

## 维护者发布前检查

```bash
./scripts/self-test.sh
./scripts/smoke-test-release-package.sh
git status --ignored
```

确认 `dist/` 是 ignored，且 `config.json`、`certs/` 没有被暂存。

`smoke-test-release-package.sh` 会使用临时 HOME 运行 `.app` 内的 launcher，模拟首次选择 SiliconFlow Kimi 并生成本地配置。它不会启动真实 Claude Science、不会写真实 `~/.claude-science/proxy/config.json`，也不会触碰网络代理设置。
