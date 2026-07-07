# CC Switch 集成：Claude Science

本项目的目标应用是 **Claude Science**，不是 Claude Desktop。

Claude Science 的请求链路由 Claude Science daemon 发起，并通过本项目的本地 Bridge 转发到 DeepSeek、Kimi、OpenAI 兼容服务或其它第三方 API。Claude Desktop 使用的是另一套 3P profile 配置，不能拿来替代 Claude Science。

## 当前状态

`scripts/integrate-ccswitch.py` 会把当前 Bridge 中的真实 Provider profiles 写入 CC Switch 数据库，使用独立的：

```text
app_type = claude-science
provider_id = claude-science-profile-*
```

这不会影响 CC Switch 现有的 Claude Code 或 Claude Desktop 面板。

注意：官方 CC Switch 3.16.x 的 app 类型是源码硬编码的，当前二进制不会显示 `claude-science` 面板。要在 CC Switch 中真正出现独立的 Claude Science 切换界面，需要套用本仓库提供的源码补丁：

```text
patches/cc-switch-claude-science.patch
```

这个补丁遵循 CC Switch 原 UI 逻辑：

- 在 AppSwitcher 中新增 `Claude Science`，沿用胶囊式应用切换器
- 复用 CC Switch 的 Provider 列表、Provider 表单、预设选择、测速和 toast 风格
- Claude Science 使用独立 `app_type=claude-science`
- 切换 Provider 时先更新 CC Switch 当前选择，再调用 Bridge 的 `/api/ccswitch/apply-provider`
- 不写 Claude Desktop profile，不写 Claude Code live config，不参与 CC Switch 的 Skills/MCP 同步

## 不要做的事

不要把 Claude Science Provider 写进 `claude-desktop`。那是 Claude Desktop，不是 Claude Science。

也不要默认写进 `claude`。那是 Claude Code，最多只能作为临时兼容入口，不能代表 Claude Science 原生集成。

## 同步命令

```bash
cd ~/.claude-science/proxy
python3 scripts/integrate-ccswitch.py --activate
```

检查状态：

```bash
python3 scripts/integrate-ccswitch.py --status
```

如确实需要临时在 CC Switch 的 Claude Code 面板里查看这个 Provider，可显式运行：

```bash
python3 scripts/integrate-ccswitch.py --compat-claude-code --activate
```

这只是兼容入口，不是推荐路径。

## 套用 CC Switch 源码补丁

给 agent 的推荐命令：

```bash
cd ~/.claude-science/proxy
./scripts/patch-ccswitch-source.sh
```

默认会 clone 或使用：

```text
~/.claude-science/cc-switch-src
```

也可以指定已有 CC Switch 源码目录：

```bash
./scripts/patch-ccswitch-source.sh /path/to/cc-switch
```

脚本只修改 CC Switch 源码目录，不会修改已安装的 `CC Switch.app`，不会改 Clash、系统代理、DNS、hosts、证书或 443 端口。

如果只需要套补丁，运行：

```bash
cd ~/.claude-science/proxy
./scripts/patch-ccswitch-source.sh
```

如果需要直接构建补丁版 CC Switch，推荐让 agent 运行：

```bash
cd ~/.claude-science/proxy
./scripts/build-patched-ccswitch.sh --install-rust --open
```

这个脚本会 clone 或复用 CC Switch 源码、套用 Claude Science 补丁、安装前端依赖、运行 TypeScript 检查，并在有 Rust/cargo 时执行 `pnpm tauri build`。如果本机没有 Rust/cargo，`--install-rust` 会把 Rust 安装到当前用户的 `~/.cargo` 和 `~/.rustup`，不需要 sudo。构建出的 CC Switch 才会在界面里出现独立的 Claude Science 面板。

默认构建目标是 macOS `.app`，成功后会额外生成：

```text
src-tauri/target/release/bundle/macos/CC-Switch-Claude-Science-aarch64.zip
```

脚本会对 `.app` 做本地 ad-hoc 签名，并关闭上游 updater artifact 签名要求。DMG 不是默认目标，因为未配置 Apple Developer 公证和 GUI 装饰环境时，DMG 步骤比 `.app` 更容易失败；如确实需要，可添加 `--dmg`。

## 切换链路

1. Bridge Dashboard 或 `scripts/integrate-ccswitch.py` 把 Bridge provider profiles 同步到 CC Switch DB。
2. 补丁版 CC Switch 显示 `Claude Science` 应用面板。
3. 用户在 CC Switch 中选择 Claude Science Provider。
4. CC Switch 后端只更新 `claude-science` 当前 Provider，不写任何 live config。
5. CC Switch 前端调用 `http://127.0.0.1:9876/api/ccswitch/apply-provider`。
6. Bridge 将该 Provider 转换为 Claude Science 可用的第三方 API 配置。
