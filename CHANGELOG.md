# 更新日志（Changelog）

本项目遵循[保留式更新日志](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [1.0.0] - 2026-10-15

### 新增
- `serial_agent`：串口调试代理，把嵌入式设备的串口控制台桥接为 TCP / stdio 协议服务，
  支持 `EXEC` / `PUSH` / `PULL` / `MD5` / `RESET` / `SHELL` / `INFO` / `PING` / `AUTH`。
  - `agent/serial_agent.ps1`：Windows 实现，零第三方依赖（PowerShell 5.1+）。
  - `agent/serial_agent.py`：跨平台实现（Linux/macOS/Windows），真实串口需 `pyserial`。
  - `-Raw` / `--raw` 纯 TCP↔串口透传模式（ser2net 风格，可用 telnet/PuTTY 直连）。
  - `-Mock` / `--mock` 内置模拟设备，无需硬件即可跑完整自测。
- `devctl`：server 侧命令行工具。
  - `cli/devctl.py`（跨平台，主推）、`cli/devctl.ps1`（Windows）。
  - 四种接入方式：本地串口、TCP 直连、SSH(stdio)、SSH 反向隧道。
  - `exec` 透传设备命令退出码，便于脚本/CI 判定。
- 传输编码自适应：`base64` → `busybox base64` → `openssl base64` → `hex`(awk+od)，
  首次传输自动探测并缓存，可用 agent 的 `-Codec` / `--codec` 强制指定。
- 上传逐块 md5 校验 + 失败自动重传；下载完成后二次校验。
- 输出清洗：剥离 shell 提示符与 ANSI 颜色转义。
- 设备复位：通过 DTR 复位开发板（`devctl reset`）。
- 面向 server 的 Codex skill 打包（`skill/serial-debug-bridge/`）：`scripts/sdb` 端点包装脚本、
  `scripts/sdb-check.sh` 链路与设备身份自检、排障手册与调用约定。
- 工程化：MIT 许可、贡献/安全/行为准则文档、Issue 与 PR 模板、
  CI（Windows PowerShell 与跨平台 Python 两套 mock 测试 + 交叉实现检查）、
  `verify-live.sh` 真机端到端验证脚本。
- 提交信息强制采用 **Linux 内核规范**：`subsystem: 祈使句摘要`（≤72 列）、
  正文说明 what/why 并折行、必须带 `Signed-off-by:` DCO 签名；
  `tools/check-commits.py` 同时作为 CI 门禁与 `tools/git-hooks/commit-msg` 本地钩子，
  并明确拒绝 `feat:` / `fix:` 这类 conventional-commit 标签。

### 修复
- 分块写入时排空最后一块回显，导致结束标记丢失、上传超时。
- ACK 标记使用不成对的引号，导致设备 shell 卡在续行状态、块丢失。
- `-Stdio` 模式下 `SHELL` 误入轮询分支；现明确返回 `shell-requires-tcp`。
- `Raw-Pipe` 使用 `DataAvailable` 轮询，客户端断开后不退出，使单线程代理永久阻塞。
- 代理脚本参数 `$Codec` 与内部缓存变量同名（PowerShell 变量大小写不敏感）导致相互覆盖。
- `devctl.py` 把连接超时沿用为读超时，长传输被误判失败。
- 上传只校验了「解码后的临时文件」，目标路径被链路噪声改坏时 `cat` 会写到别处并成功返回，
  导致静默丢块；现在追加后再核对目标文件大小，不一致即重发。
- 发送方向同样会丢字节：一次实测中 `uname -a` 被丢成 `uname`，执行了错误的命令。
  现在用终端回显校验设备收到的命令行是否与发送一致，不一致自动重发。
- 建仓脚本在「只读令牌」下不再提前中断：仓库设置与话题降级为警告，推送与分支保护仍为
  硬失败，并在 403 时说明缺的是哪个权限（实测编辑器登录得到的 `ghu_...` 令牌是只读的）。
- 上传分块重发前先发送 Ctrl-C：被破坏的命令可能把 shell 留在 here-document 或未闭合
  引号里，否则后续重试会全部超时。

### 验证
- 本地 mock 自测：`serial_agent.ps1` + `devctl.ps1` **9/9**；`serial_agent.py` + `devctl.py` **8/8**
  （`auto` 与 `hex` 两种编码均通过）；跨版本组合（ps↔py）亦通过。
- 真机验证：client=Windows（COM3 @ 460800），设备=Realtek RTD1761 / Yocto（busybox ash，
  **无 base64**），经 SSH 反向隧道由 server 操作；`info` / `exec` / `pull` 正常，
  **4 KB、60 KB、200 KB** 二进制文件 push+pull 往返 md5 全部一致。

[Unreleased]: https://github.com/cadywang/serial-debug-bridge/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/cadywang/serial-debug-bridge/releases/tag/v1.0.0
