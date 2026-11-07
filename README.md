# cmux personal

[cmux](https://github.com/manaflow-ai/cmux) 的 macOS 个人定制分支，主要维护 OMP 会话状态、可配置侧栏、对话历史来源管理，以及 Codexpress 集成。

## 个人版特性

### OMP 会话状态

工作区名称下方的状态条与终端标签同步显示代理状态：工作中使用蓝色旋转指示，等待输入使用黄色，已完成使用绿色，错误使用红色。支持 OMP hooks 与原生 OSC 7501 上报；新会话的 `idle` 状态不显示完成徽章。

完成徽章和数字提示在查看期间保留，查看后离开工作区、将通知标记已读，或同一窗格开始新任务时清除。各窗格独立记录状态，迟到的结束事件不会恢复已确认的完成提示。

### 终端图片双击预览

左键双击终端中实际显示的图片，在当前工作区右侧打开原生图片预览，支持适配、缩放、像素 1:1 和拖动查看。可用于 OMP 的 PDF 页面、工具图片和公式图块，也支持仍保有数据的历史图片。

预览读取 Ghostty 持有的完整图像，不依赖原始文件路径，不使用终端截图，也不请求模型或外部服务。清晰度以终端已接收的数据为限。

同一工作区复用专用图片预览，不替换手工打开的文件。关闭后返回来源终端，输入草稿与运行状态保留；预览副本仅存于内存，不写入会话恢复记录。终端程序启用鼠标支持时仍可使用，图片外的选词、拖选与链接操作保持原有行为。

### 可配置侧栏

- 分别调整工作区标题、状态及各类附加信息的字号。
- 设置每项信息的行数上限，自动换行后截断。
- 开关、排序通知预览、描述、分支目录、PR、端口、自定义信息、日志与进度。
- 独立控制侧栏和标签中的代理状态，以及状态动画；系统“减少动态效果”设置同样生效。

相关选项位于“设置 → 侧边栏”。代理状态条固定在工作区名称下一行，其余信息按配置排列。

### 保险库来源选择

保险库的“代理来源”菜单支持动态选择需要读取的 agent 对话历史，也可通过全局配置 `vault.enabledAgents` 设置。

未选中的来源停止扫描、索引和搜索，而非仅隐藏结果；原始会话文件不会被删除，运行中的代理识别与 hooks 不受影响。支持仅启用 OMP、选择多个来源、关闭全部来源，或跟随默认来源列表。

### Codexpress 来源面板

侧栏底部的可折叠面板通过本机管理 API 读取 [Codexpress](https://github.com/LEOibyug/Codexpress) 网关状态，可同时展示多个来源：

- 官方账号并排显示实际存在的 `5h`、`week` 额度及重置时间。
- 第三方来源显示余额，币种与金额分开排版。
- 来源名称旁显示 API 提供的活跃请求数 `active_requests`。
- 提供抢占、取消抢占、刷新与重置卡操作；重置由 Codexpress 原生弹窗确认，操作超时或结果未知时不自动重发。

“设置 → 侧边栏”中可启停面板，调整字号、读取间隔和各项信息及按钮的可见性。周期读取使用网关已有数据，主动刷新按钮才请求更新对应来源的余额或额度。

周期读取使用轻量状态接口，不附带历史用量聚合。供应商刷新失败与本机 API 连接错误分开展示，保留上次余额和额度；按网关返回的下次查询时间暂停重复刷新，到期恢复按钮。来源恢复后清除该来源的刷新错误，不影响其他操作错误或抢占、重置功能。

连接支持自动发现，也支持手动配置管理端口与 API Key，默认端口为 `17867`。API Key 保存在独立的 `0600` 私有文件中，不写入 `cmux.json`、UserDefaults 或仓库。面板仅连接本机回环地址，不修改 Codex、供应商凭据或系统代理，也不会自动启用或重启 Codexpress。

## 维护范围

- 仅维护 macOS 原生产品，保留终端、浏览器、本地控制接口，以及 SSH、mosh、tmux 等使用路径。
- 移除 cmux Cloud、cmux 官方账号登录、团队、计费、手机配对、遥测和自动更新检查。
- 界面维护英文、简体中文与繁体中文，其他语言选项回退为英文；终端内容与网页语言不受影响。
- 上游更新采用选择性合并，不自动同步整个上游，不维护旧版本配置迁移层。
- 仓库不配置 GitHub Actions、官方发布流程或机器人协作门禁。

## 本地开发

构建需要完整 Xcode、Metal 工具链、Zig 0.16 和 Rust。环境准备入口为 `scripts/setup.sh`，开发构建使用 `scripts/reload.sh --tag <tag>` 隔离应用名称、bundle ID、socket 与用户目录。GhosttyKit 可使用预编译产物；已有验证产物可直接复用。

开发命令通过 `./scripts/dev.sh <命令> [参数...]` 执行，或先载入 `scripts/project-env.sh`。构建与依赖缓存放在项目内的 `cache/`，日志、截图、socket 和隔离 HOME 放在 `tmp/`，均不提交。正式应用启动时使用正常用户环境，不继承开发用的 HOME 或 socket 覆盖。

验证按功能边界进行：行为修改执行定向构建与隔离 smoke，缺陷修复优先扩展已有行为回归；纯文案、注释不重复构建或回归。不默认运行全量测试，也不增加只检查源码文本、转发或实现细节的测试。

## 本地安装与更新

本地更新入口为 `scripts/update-local.sh`：增量构建 Release，清理开发标记，以固定本地证书签名，并准备一次性安装任务。应用运行期间只暂存更新包，正常退出后在原安装位置原子替换；应用由使用者自行重新打开。更新过程不强退应用、不自动重启，也不联网下载应用更新。

```bash
# 首次创建本地签名证书，仅需一次：
./scripts/dev.sh python3 scripts/local_signing.py init
./scripts/update-local.sh
./scripts/update-local.sh --status
# 复用已验证的项目内 Release 产物，省去重建：
./scripts/update-local.sh --reuse-artifact '<项目内 Release 产物>'
```

签名使用 [rcodesign](https://gregoryszorc.com/docs/apple-codesign/stable/apple_codesign_rcodesign_signing.html) 直接读取 `.cmux/signing/` 中的固定 PEM 证书与无密码私钥，不依赖钥匙串或 Apple 开发者账号。签名文件不提交仓库，应单独备份；文件缺失或身份不匹配时更新停止，不自动生成替代身份。

Computer Use 仅安装随应用提供、且与当前 cmux 使用同一证书签名的 helper，不依赖旧缓存或上游 NIGHTLY、RC 安装。复制后的 helper 仍会验证签名和完整性。

本地证书签名不等同于 Apple 公证。首次从上游、ad-hoc 或其他证书切换时，cmux 及 Computer Use helper 可能需要重新授予隐私权限；后续更新保持同一证书身份。

## 文档

- [保险库与代理来源](docs/vault.md)
- [OMP 和其他代理 hooks](docs/agent-hooks.md)
- [原生终端状态协议](docs/program-status.md)
- [外观设置](docs/customizing-appearance.md)
- [配置 schema](schemas/cmux.schema.json)
- [Shell 集成](docs/shell-integration.md)
- [本地 tmux](docs/local-tmux.md)

## 许可证

除文件或独立声明另有规定外，项目代码采用 GPL-3.0-or-later。保留上游作者及第三方的版权与归属声明，详见 [LICENSE](LICENSE) 和 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。`agent-chat/messages/` 等带有独立许可证的材料按各自声明授权。
