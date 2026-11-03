# cmux personal

这是 [LEOibyug/cmux](https://github.com/LEOibyug/cmux) 的个人 macOS 版本，基于 [cmux](https://github.com/manaflow-ai/cmux)。

## 保留的功能

- Ghostty 终端、工作区、分屏、内置浏览器和本地控制接口。
- 保险库对话历史，以及可动态调整的 `vault.enabledAgents` 来源选择。
- OMP 对话的彩色状态徽标；侧栏与标签同步，支持 hooks 和原生 OSC 7501 状态。
- 工作区信息按标题、agent 状态、描述、分支、目录、辅助信息分级字号；自动换行至最多两行，超出后尾部省略，侧栏宽度变化时同步调整行高。
- 左侧栏底部的 Codexpress 来源面板：余额、官方额度、抢占和重置卡确认。
- 用户自行配置的 SSH、mosh、tmux，本地 Computer Use 和 Simulator。

不包含 Cloud、官方账号登录、团队、计费、手机配对、遥测或自动更新。仓库只维护本机 macOS 产品；GitHub Actions、官方发布流程和机器人协作配置均已移除。浏览器访问、Git 和用户发起的 SSH 网络操作不受限制。

界面仅维护英文、简体中文与繁体中文；其他语言选项统一使用英文。「跟随系统」在系统首选语言为中文时采用相应中文，否则使用英文。终端、浏览器网页和用户文件的语言不受影响。

## Codexpress 来源面板

需要支持管理 API 的 Codexpress。在 Codexpress「接入 → 管理 API」启用本机服务；cmux 从 `~/Library/Application Support/Codexpress/control-access.json` 读取独立端口与管理 Key，不复制密钥、不修改 Codex、供应商凭据或系统代理。自定义数据目录可通过启动 cmux 时的 `CODEXPRESS_STATE_DIR` 指定，配置文件和所属目录必须为当前用户私有，不能使用符号链接。

面板固定在工作区列表下方，可折叠，来源多时内部滚动。面板可见时每 2 秒读取本机状态；Codexpress 更新余额、额度或请求状态后自动同步。读取状态不查询上游，顶部刷新也只读本机；来源行的刷新按钮才主动刷新该来源的余额或额度和卡片。断连保留上次快照并标记陈旧，未知数值不显示为零，不汇总不同币种。

「抢占」持续优先选择该来源；「停止」只取消对应抢占，不打断现有输出，也不切换 Codex 的连接模式。「重置」只创建唯一编号的确认请求，实际账号、卡片和消费由 Codexpress 原生弹窗确认。超时或结果未知时不重发操作，只查询原编号；待核实的重置保持锁定，不自动换卡。

未开启服务或运行中的旧网关不支持管理 API 时，面板显示接入提示。cmux 不会自动启用服务或重启 Codexpress，避免打断使用中的对话。

## 本地开发

构建前提与命令见 [CONTRIBUTING.md](CONTRIBUTING.md)。已有可用产物时直接复用，不重复编译。

改动只做对应功能的本机编译和隔离 smoke；不默认运行全量回归或远端 CI。不维护旧版本配置适配层。替换安装前，先由用户退出正在运行的 cmux；配置和原始对话独立保留。

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
