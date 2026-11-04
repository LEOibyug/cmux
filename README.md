# cmux personal

这是 [LEOibyug/cmux](https://github.com/LEOibyug/cmux) 的个人 macOS 版本，基于 [cmux](https://github.com/manaflow-ai/cmux)。

## 保留的功能

- Ghostty 终端、工作区、分屏、内置浏览器和本地控制接口。
- 保险库对话历史，以及可动态调整的 `vault.enabledAgents` 来源选择。
- OMP 对话的彩色状态徽标固定在工作区名称下一行；侧栏与标签同步，结束后显示“已完成”并在查看时保留徽章和数字指示；查看后离开工作区、手动标记已读，或同一窗格开始新任务并显示“工作中”后清除，不再常驻显示“空闲”。
- 设置 → 侧边栏：分别调整各类字号、每项信息的行数上限、状态可见性和动画；通知预览、描述、分支目录、PR、端口、自定义信息、日志与进度均可开关、排序。
- 左侧栏底部的 Codexpress 来源面板：余额、官方额度、抢占和重置卡确认。
- 用户自行配置的 SSH、mosh、tmux，本地 Computer Use 和 Simulator。

不包含 Cloud、官方账号登录、团队、计费、手机配对、遥测或自动更新。仓库只维护本机 macOS 产品；GitHub Actions、官方发布流程和机器人协作配置均已移除。浏览器访问、Git 和用户发起的 SSH 网络操作不受限制。

界面仅维护英文、简体中文与繁体中文；其他语言选项统一使用英文。「跟随系统」在系统首选语言为中文时采用相应中文，否则使用英文。终端、浏览器网页和用户文件的语言不受影响。

## Codexpress 来源面板

需要支持管理 API 的 Codexpress。在 Codexpress「接入 → 管理 API」启用本机服务。cmux 的「设置 → 侧边栏 → 管理连接」可选择自动或手动：自动从 `~/Library/Application Support/Codexpress/control-access.json` 读取端口与管理 Key；手动使用界面保存的端口与 Key，默认端口为 17867，可设置为 1–65535。Key 输入遮蔽，点击保存后存入独立的 0600 私有文件，不写入 `cmux.json`、UserDefaults 或仓库；手动模式没有 Key 时明确提示，不回退自动模式。两种方式均只连接本机回环，不修改 Codex、供应商凭据或系统代理。自动发现支持启动时的 `CODEXPRESS_STATE_DIR`，其配置和目录必须私有且不能使用符号链接。

面板固定在工作区列表下方，可折叠，来源多时内部滚动。官方来源并排显示实际存在的一种或两种限额（`5h`、`week`），第三方显示余额（如 `US$ 818.99`）；名称旁的数字直接使用 API 的 `active_requests`。按钮排在来源行内，完整状态、陈旧提示等次要信息放在悬浮说明中。设置 → 侧边栏可调整面板开关、字号、本机状态间隔（默认 2 秒，范围 1–60 秒）、请求数、重置时间与操作按钮；关闭面板也会停止轮询。周期读取不查询上游，只有来源行的刷新按钮主动刷新对应余额或额度和卡片。未知数值不显示为零，不汇总不同币种。

「抢占」持续优先选择该来源；「停止」只取消对应抢占，不打断现有输出，也不切换 Codex 的连接模式。「重置」只创建唯一编号的确认请求，实际账号、卡片和消费由 Codexpress 原生弹窗确认。超时或结果未知时不重发操作，只查询原编号；待核实的重置保持锁定，不自动换卡。

未开启服务或运行中的旧网关不支持管理 API 时，面板显示接入提示。cmux 不会自动启用服务或重启 Codexpress，避免打断使用中的对话。

## 本地开发

构建前提与命令见 [AGENTS.md](AGENTS.md)（tagged 构建、GhosttyKit 预编译、签名与替换）。已有可用产物时直接复用，不重复编译。

改动只做对应功能的本机编译和隔离 smoke；不默认运行全量回归或远端 CI。不维护旧版本配置适配层。替换安装前，先由用户退出正在运行的 cmux；配置和原始对话独立保留。

保留日常构建、签名、本地化和工程合并工具；这些工具不依赖 CI 合并解析器或发布签名检查。
Computer Use 随程序提供的技能资料保存在 `Resources/cmux-cua/`，不属于仓库开发规则。
所有开发产物和过程文件仅放项目自身的 `cache/`、`tmp/`，不提交到 Git。使用 `./scripts/dev.sh <命令> [参数...]`，或先 `source scripts/project-env.sh`；构建脚本也会自动载入。Xcode DerivedData、SwiftPM、Rust、Zig、Go 和 UI 预览缓存不再写入用户目录，日志、截图和隔离应用 HOME 不再使用系统临时目录。显式指定项目外缓存/输出会被拒绝。清理 `cache/` 会丢失增量编译缓存，下次构建需重新下载或编译；安装程序和真实用户数据不在清理范围。macOS 自身维护的系统服务状态不受这些脚本控制。
正式安装启动时不要继承开发隔离环境，尤其是 `CFFIXED_USER_HOME`；该变量会让自动发现和其他用户配置指向项目缓存。隔离环境只用于构建和 tagged 验证，安装后的日常应用使用真实用户 HOME。

## 更新方式

仅在用户主动要求时，检查上游并选择性合并需要的提交；不自动同步整个上游。合入时保留个人功能和纯本地边界，不重新引入账号服务、遥测或更新器。

## 使用参考

- [保险库与代理来源](docs/vault.md)
- [OMP 和其他代理 hooks](docs/agent-hooks.md)
- [原生终端状态协议](docs/program-status.md)
- [外观设置](docs/customizing-appearance.md)
- [配置 schema](schemas/cmux.schema.json)
- [Shell 集成](docs/shell-integration.md)
- [本地 tmux](docs/local-tmux.md)

## 许可证

保留原作者和第三方的版权与归属声明。许可证见 [LICENSE](LICENSE) 与 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)；带有独立许可声明的材料仍按各自声明授权。个人定制和移除服务不改变原有授权。
本机对话界面仍使用的多语言文案保存在 `agent-chat/messages/`，其原有 [独立许可证](agent-chat/messages/LICENSE) 随文件保留；不是把原网站整体纳入本机产品。
