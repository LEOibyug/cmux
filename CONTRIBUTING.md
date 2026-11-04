# 本地开发

此仓库只维护个人 macOS 版本，不使用 GitHub Actions、官方发布流水线或自动上游同步。

## 前提

- macOS 14+，完整 Xcode；版本见 `.xcode-version`。
- Xcode Metal 工具链：`xcodebuild -downloadComponent MetalToolchain`。
- Ghostty 固定版本的 Zig（当前为 0.16.0）和 Rust/rustup。
- Homebrew rustup 需要将 `/opt/homebrew/opt/rustup/bin` 加入 `PATH`。

## 首次构建

```sh
git clone --recursive https://github.com/LEOibyug/cmux.git
cd cmux
./scripts/setup.sh
(cd cmux-tui && cargo build --release --locked -p cmux-tui --bin cmux-tui)
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --release --tag personal --no-global-cli-links
```

`setup.sh` 准备固定依赖和本地 Git hooks；`reload.sh` 不需要后端、官方账号或服务凭据。SSH helper 使用本地 `cmux-tui/target/release/cmux-tui`，也可用 `CMUX_TUI_CLIENT_LOCAL` 明确指定。

后续构建复用相同 tag 和 DerivedData。已有缓存目录时，用 `--derived-data <绝对路径>`；加 `--launch` 启动隔离验证版。不要使用裸 `xcodebuild`、未标记的开发版或全局 `/tmp/cmux-cli`。

## 按功能验证

只验证本次改动实际影响的路径：

1. Swift 改动先做定向语法检查：`python3 scripts/verify-local.py --only swift-syntax --swift-changed`。
2. 原生行为有变化时，编译上述 tagged app，并在其中实际操作一次对应功能。
3. 只有不确定的边界或用户指定时，才运行相关测试。不默认跑全量 app-host/UI/回归套件。
4. UI 文案变化运行 `./scripts/localize-changes`；新增 Swift 文件用 `scripts/wire-app-sources.py` 接入构建。

针对隔离版使用：

```sh
CMUX_TAG=personal scripts/cmux-debug-cli.sh identify --json
```

若构建使用了自定义 DerivedData，同时传入 `CMUX_DERIVED_DATA`。完整流程参考 [tagged builds](skills/cmux-dev-workflow/references/tagged-builds.md)。

## 提交与安装

只提交源码和必要构建输入，不提交用户配置、对话、凭据、缓存、安装回执或临时验证脚本。提交并推送到个人 fork；上游更新只按用户要求选择性整合，不追求兼容过去版本。

正式安装前由用户退出当前 cmux，再复用已验证产物替换。不得退出、强退或覆盖承载会话的运行中主程序；本地签名不代表官方公证，系统权限可能需要重新授予。

许可证与第三方归属见 [LICENSE](LICENSE) 和 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。
