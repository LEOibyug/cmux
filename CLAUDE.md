# cmux 个人仓库规则

个人快速迭代仓库（fork: [LEOibyug/cmux](https://github.com/LEOibyug/cmux)，上游 `manaflow-ai/cmux`）。
只维护本机 macOS 原生产品；无远端 CI、无发布流程、无旧版本迁移层。规则就这几条：

## 硬规则

- 不退出、不杀、不重启、不 profile 用户正在运行的稳定 cmux（`/Applications/cmux.app`，
  `com.cmuxterm.app`），也不能通过 Release 构建或同 bundle ID 的其他包间接做到。复现一律用
  tagged build 并附加到它的 PID。不要设置 `CMUX_ALLOW_REPLACING_RUNNING_CMUX`；只有用户可以。
- Dogfood 通过 `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh`；输出里不要出现原始 `.app` 路径或 `file://` URL。
- app 链接代码（`Sources/`、`CLI/`、`TunnelExtension/` 及其 packages）保持 Swift 6.0 兼容：
  参数/实参列表无尾逗号（SE-0439）；类型声明上不用 `nonisolated`（SE-0449，成员级可以）；
  `@concurrent` 保持现有 `#if compiler(>=6.2)` / `@Sendable` 分裂写法。
- 汇报只写实际执行过的验证；没跑的就明说没跑。
- 所有开发过程文件仅写本项目目录：`cache/` 放构建/依赖/工具缓存，`tmp/` 放临时脚本、日志、截图、隔离 HOME 和 socket；两者不提交。
- 任意构建/验证命令通过 `scripts/dev.sh <命令> ...` 或先 `source scripts/project-env.sh`；禁止将 DerivedData、SwiftPM/Rust/Zig/Go 缓存写到用户目录或 `/tmp`，禁止建立指向外部缓存的符号链接。直接开发入口也自动应用此环境并拒绝外部输出覆盖。
- 工具链安装保留在项目缓存（已有系统工具链只读使用）；正式应用的用户数据/安装和 macOS 自身服务维护的系统状态不属于开发缓存，不为验证改动。原生应用验证须显式使用项目内隔离 HOME；不能承诺拦截 macOS 服务自身的系统写入。

## 构建与安装

- Tagged 构建（隔离 app 名、bundle ID、socket、DerivedData）：

  ```bash
  ./scripts/dev.sh bash -c 'cd cmux-tui && cargo build --release --locked -p cmux-tui --bin cmux-tui'
  ./scripts/reload.sh --tag <tag> --no-global-cli-links          # 构建
  ./scripts/reload.sh --tag <tag> --launch --no-global-cli-links # 构建+启动
  ./scripts/reload.sh --tag <tag> --build-only --no-global-cli-links # 只验证产物
  ./scripts/reload.sh --release --tag <tag> ...                  # 优化构建
  ```

  所有 tag 复用 `cache/xcode`；依赖在 `cache/swiftpm`，tag 日志/socket/隔离 HOME 在 `tmp/`。tag 用 1–40 个字母/数字/`_`/`-`。
- GhosttyKit 预编译：`./scripts/download-prebuilt-ghosttykit.sh`，构建时配 `CMUX_GHOSTTYKIT_PREPROVISIONED=1`。
- 构建前置：Metal 工具链、Zig 0.16、Rust（PATH 加 `/opt/homebrew/opt/rustup/bin`）；一键安装见 `scripts/setup.sh`。
- 替换稳定安装必须先由用户退出运行中的 cmux；本地 ad-hoc 签名用 `scripts/sign-cmux-bundle.sh`。

## 日常

- 直推 `main`；不跑远端 CI，不做 PR 仪式，选择性合并上游（保持本地边界：无账号服务/遥测/更新器）。
- 测试按需运行（`scripts/dev.sh swift test --package-path ...`）；增删改名 `cmuxTests/` 文件后跑 `scripts/sync-test-wiring`。
- 界面只维护英文、简体中文、繁体中文；改文案后跑 `scripts/localize-changes` 校验三语言 catalog。
- 新增 app 源文件用 `scripts/wire-app-sources.py` 接入工程；工程文件冲突用 `scripts/merge-pbxproj.py`。
