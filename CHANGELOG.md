# 更新日志（Changelog）

本项目遵循[保留式更新日志](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 新增
- `SHUTDOWN` 操作：`devctl ... shutdown` 让 client 上的 agent **自己退出并释放串口**
  （TCP 与 SSH/stdio 都支持，响应 `OK pid=<n>`）。此前只能到 client 机器上找进程或按
  Ctrl+C；两套 agent 与两套 CLI 同步实现，`PROTOCOL.md` / `README.md` 一并更新。
- `agent/stop-agent.ps1`（双击版 `stop-agent.bat`）与 `agent/stop-agent.sh`：agent 成了孤儿、
  占着串口又连不上时，在 client 本机按**启动方式**把它找出来并结束（`-Port` / `-TcpPort`
  过滤，`-List` / `--list` 只列不杀，`-WhatIf` 预演）；停完会复核进程是否真的没了，
  复核不通过就报失败，不会假装成功。
- 自测与 CI 覆盖停止路径：两套自测各自验证「shutdown 后进程退出、TCP 端口释放」，
  CI 新增 `devctl.py → serial_agent.ps1` 的 SHUTDOWN 交叉检查，以及 Windows
  `stop-agent.ps1`、Linux `stop-agent.sh` 各一次真实停止验证。
- PR 门禁（`.github/workflows/pr-gate.yml` 的 `pr-gate`）：**PR 标题**必须走内核规范
  `<subsystem>: <祈使句摘要>`，模板里的**「合并前清单」必须逐条勾选**，否则不能合并；
  编辑 PR 描述（也就是勾清单）会自动重跑，避免用过期结果放行。标题规则与 commit 子标题
  共用同一个函数（`tools/check-commits.py` 的 `subject_errors`）；清单条目来自
  `.github/pull_request_template.md` 的「合并前清单」小节——改清单就得改模板，模板本身
  也要过这道门禁，所以清单没法在合并时被悄悄放宽。工具 `tools/check-pr.py`，
  自测 `tests/test_check_pr.py`（18 例）；机器人 PR（dependabot）跳过。

### 修复
- CI 的提交规范门禁误拒 GitHub 网页端 squash 合并产生的提交：作者被改写成
  `<ID>+<login>@users.noreply.github.com`、自动追加 `Co-authored-by:`，正文还可能夹在
  trailer 块之间（`main` 上 #4 / #5 合并后的构建就是这么红的）。现在 GitHub noreply
  的两种写法视为同一账号、`Co-authored-by:` 进入白名单，且只检查**最后一个** trailer
  块之后的正文；新增 `tests/test_check_commits.py`（15 例）并由 hygiene job 执行。
- 网页端 squash 合并会把 **PR 标题**写成 `main` 上的提交标题：标题不合内核规范时，
  commit 规范门禁在**合并之后**才把 `main` 判红，而受保护的历史又改不回来
  （#7 合并后的构建就是这么红的）。现在识别这种由 GitHub 自己写出的提交
  （committer 是 `GitHub <noreply@github.com>`、标题以 ` (#N)` 结尾）：只跳过标题
  规范检查——标题改由新增的 PR 门禁在**合并前**拦截（见上「新增」）——
  DCO 与正文格式照旧校验；`tests/test_check_commits.py` 增到 18 例。
- 合并方式改为**只允许 Rebase and merge**（`governance/repository-settings.json`）：
  Squash 会把整个 PR 压成一个提交，提交标题变成 PR 标题、每个提交的 `Signed-off-by:`
  也不再是原文——#7 就是这么把 `main` 判红的，而 `main` 的历史改不回来。rebase 让 PR 里
  的原始提交原样落到 `main`，代价是提交信息必须一开始就写对；`pr-gate` 仍在合并前校验
  PR 标题与模板清单。
- 本地自测不再卡死：`tests/selftest.ps1` 曾默认用 17801，而这个端口在本机常已被 VS Code 的
  端口转发占着（Windows 上更具体的 `127.0.0.1` 监听会盖过 agent 的 `0.0.0.0`），devctl 于是
  连到了陌生人身上并永远等回复。现在两套自测**默认向系统要一个空闲端口**
  （`-Port` / `--port` 仍可指定），指定的端口已被占用时立刻报错退出（退出码 2）。
- `tools/create-github-repo.ps1` 在 squash 关闭时会被 GitHub 拒掉（`no_squash_merge_strategy`，
  422）——治理文件里还留着 `squash_merge_commit_message` / `squash_merge_commit_title` /
  `merge_commit_title`，而 GitHub 不允许给已关闭的合并策略设置这些字段。现在只发送
  **当前启用**且有值的字段，治理文件也不再保留这三项（本次对齐线上设置时就是这么被拒的）。
- `tools/create-github-repo.ps1 -DryRun` 不再改动本地仓库：`git remote add/set-url` 与
  `git branch -M main` 移进了真正推送的分支——以前 dry-run 也会把**当前分支**改名成 `main`。
- `cli/devctl.ps1` 的连接没有超时（`devctl.py` 一直是 15 秒），端口不通时脚本会一直挂着。
  现在两版一致：连不上或超时在 15 秒内报错退出（退出码 1），错误信息也去掉了 .NET 包装。

### 验证
- 本地 mock 自测（Windows）：`serial_agent.ps1` + `devctl.ps1` **12/12**（`auto` 与 `hex`
  两种编码），`serial_agent.py` + `devctl.py` **11/11**；交叉组合
  （`devctl.py → serial_agent.ps1`、`devctl.ps1 → serial_agent.py`）的 `shutdown` 亦通过，
  之后 agent 进程退出、TCP 端口重新可绑定。
- 失败路径复查（本机 Windows）：`selftest.ps1` 默认端口 12/12、指定端口 + `-Codec hex` 12/12；
  `test_e2e.py` 默认端口 11/11、`--codec hex` 11/11；对已占用端口两者都**秒退并返回 2**；
  `devctl.ps1` 对不通的端口立即报错退出 1，对黑洞地址 15 秒超时退出 1，mock agent 正常。

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
- 超时不再只报「设备无响应」：agent 会把控制台最后约 200 字节写进日志，用来立刻分辨
  「设备重启 / 停在登录提示」和「真的卡住」。
- 建仓脚本在「只读令牌」下不再提前中断：仓库设置与话题降级为警告，推送与分支保护仍为
  硬失败，并在 403 时说明缺的是哪个权限（实测编辑器登录得到的 `ghu_...` 令牌是只读的）。
- 上传分块重发前先发送 Ctrl-C：被破坏的命令可能把 shell 留在 here-document 或未闭合
  引号里，否则后续重试会全部超时。

### 验证
- 本地 mock 自测：`serial_agent.ps1` + `devctl.ps1` **9/9**；`serial_agent.py` + `devctl.py` **8/8**
  （`auto` 与 `hex` 两种编码均通过）；跨版本组合（ps↔py）亦通过。
- 真机验证：client=Windows（COM3 @ 460800），设备=Yocto 机顶盒（busybox ash，
  **无 base64**），经 SSH 反向隧道由 server 操作；`info` / `exec` / `pull` 正常，
  **4 KB、60 KB、200 KB** 二进制文件 push+pull 往返 md5 全部一致。

[Unreleased]: https://github.com/cadywang/serial-debug-bridge/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/cadywang/serial-debug-bridge/releases/tag/v1.0.0
