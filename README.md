# cmux personal

这是 [LEOibyug/cmux](https://github.com/LEOibyug/cmux) 的个人 macOS 版本，基于 [cmux](https://github.com/manaflow-ai/cmux)。

## 保留的功能

- Ghostty 终端、工作区、分屏、内置浏览器和本地控制接口。
- 保险库对话历史，以及可动态调整的 `vault.enabledAgents` 来源选择。
- OMP 对话的彩色状态徽标；侧栏与标签同步，支持 hooks 和原生 OSC 7501 状态。
- 用户自行配置的 SSH、mosh、tmux，本地 Computer Use 和 Simulator。

不包含 Cloud、官方账号登录、团队、计费、手机配对、遥测或自动更新。仓库只维护本机 macOS 产品；GitHub Actions、官方发布流程和机器人协作配置均已移除。浏览器访问、Git 和用户发起的 SSH 网络操作不受限制。

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
