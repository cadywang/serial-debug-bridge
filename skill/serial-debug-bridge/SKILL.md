---
name: serial-debug-bridge
description: 在 server 上通过 serial-debug-bridge 操作接在 client 串口上的嵌入式设备：执行命令、传文件、复位、交互控制台，以及链路排障。适用于串口不在本机（devctl/agent/TCP/SSH/反向隧道）的场景。
metadata:
  short-description: 通过远端串口调试嵌入式设备
---

# serial-debug-bridge（server 侧操作）

## 心智模型

```
server: devctl  --TCP 或 SSH-->  client: serial_agent  --UART-->  嵌入式设备
```

串口插在哪台机器上，`serial_agent` 就在哪台机器上跑（下称 **client**）；
你在 **server** 上敲 `sdb`，`sdb` 调用 `devctl.py` 把命令/文件转给 agent，agent 再读写串口。

**设备控制台通常就是 root shell**：能连上 agent 等于能完全控制设备。

## 怎么调用：用 `scripts/sdb`

`scripts/sdb` 是唯一的推荐入口，它替你处理端点解析、鉴权参数和外层超时：

```bash
S="$HOME/.codex/skills/serial-debug-bridge/scripts/sdb"

$S info                         # 代理/设备信息（不碰设备）
$S exec 'uname -a; id -un'      # 在设备上执行；退出码 = 设备命令退出码
$S push ./fw.bin /tmp/fw.bin    # server -> 设备（设备侧 md5 校验）
$S pull /etc/hostname ./h       # 设备 -> server（落盘后 md5 校验）
$S md5 /tmp/fw.bin              # 设备侧 md5
$S reset                        # 通过 DTR 复位（会打断设备，先确认）
$S shutdown                     # 让 client 上的 agent 退出，释放串口
$S shell                        # 交互式控制台（仅 TCP），Ctrl+] 退出
```

等价的直接调用（需要自己拼参数）：

```bash
python3 ~/serial-debug-bridge/devctl.py --tcp 127.0.0.1:17801 exec "uname -a"
```

### 端点解析（环境变量 > 配置文件 > 默认）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `SDB_TCP` | `127.0.0.1:17801` | 连已监听的 agent；直连时写 `client-ip:7801` |
| `SDB_SSH` | 空 | `user@host`，让 devctl 通过 ssh 在 client 上拉起 agent |
| `SDB_PORT` / `SDB_BAUD` | `/dev/ttyUSB0` / `115200` | 仅 `SDB_SSH` 时用 |
| `SDB_REMOTE_AGENT` | 空 | client 上的 agent 路径（仅 `SDB_SSH`） |
| `SDB_TOKEN` | 空 | agent 用 `--auth` 启动时的口令 |
| `SDB_DEVCTL` | 见脚本 | `devctl.py` 路径 |
| `SDB_CONFIG` | `~/.config/serial-debug-bridge/target` | 配置文件（会被 source） |
| `SDB_TIMEOUT` | `180` | 外层硬超时秒数，`0` 关闭 |
| `SDB_EXTRA` | 空 | 附加 devctl 参数，按空格切分，如 `-q --timeout 300000` |

> **大文件务必放宽超时**：`SDB_EXTRA="-q" SDB_TIMEOUT=0 $S push big.bin /tmp/big.bin`。
> 60 KB 上传就要约 50 秒（见下）。

## 开工前的两步

```bash
# 1) 链路与设备身份：确认「我连上的确实是这台设备」
bash "$HOME/.codex/skills/serial-debug-bridge/scripts/sdb-check.sh"
bash "$HOME/.codex/skills/serial-debug-bridge/scripts/sdb-check.sh" --ports   # 顺带看端口占用

# 2) 设备有哪些传输工具
$S exec 'command -v busybox base64 openssl awk od md5sum'
```

`sdb-check.sh` 会打印端点、`info`、设备身份（`uname -a; hostname`）和传输能力；
`--ports` 会列出本机该端口的监听者，用来发现「端口被别的进程抢占」。

## 传输可靠性与速度（必须知道）

串口在高波特率下**收发两个方向都会偶发丢字节**，所以不要硬怼：

* **编码自适应**：`base64` → `busybox base64` → `openssl base64` → `hex+awk`。
  设备没有 base64 时（例如 Yocto 精简镜像）自动走 hex+awk。
* **上传逐块校验 + 重传**：按 1 KB 分块，设备侧自算 md5，追加后再核对文件大小，
  不一致就重发；失败重发前会自动发 Ctrl-C 复位可能被卡住的 shell。
* **发送方向用回显校验**：agent 会确认设备回显的命令与我们发送的一致，不一致自动重发
  （曾观察到 `uname -a` 被丢成 `uname`，从而执行了错误的命令）。
* **速度约 1～1.2 KB/s**。大文件先压缩：`$S exec 'tar czf /tmp/a.tgz <path>'` 再 `pull`。
* 单会话：agent 是单线程的，别并发发起多个 `sdb`。

## 排障（详见 references/troubleshooting.md）

1. **`agent closed the connection` / 莫名超时**
   端点被别的进程抢了。**VS Code 会自动转发它检测到的端口并绑定 `127.0.0.1`**，
   比反向隧道（通常连 `127.0.0.1`）更具体从而抢走连接。
   用 `sdb-check.sh --ports` 看监听者，改连 `127.0.0.2:port` 或换端口。
2. **设备 shell 停在 `>`**（上次传输被中断留下的未闭合引号/here-document）
   agent 超时会自动发 Ctrl-C；必要时 `$S shell` 里手动 Ctrl-C，或兜底 `$S reset`（先确认）。
3. **`push` 报 `verified=False`** 重试；持续失败就降波特率，或先压缩文件。
4. **传输中途失败且控制台出现启动横幅 / `login:`**
   设备自己重启了，不是桥的问题。agent 超时会把控制台最后 200 字节打进日志
   （`console said: ...`），先看那条；重新登录后再传。

5. **agent 停不下来 / 串口被它占住**
   还连得上就 `$S shutdown`（agent 自己退出并释放串口）；连不上（孤儿进程）就在 client 上跑
   `agent/stop-agent.ps1 -Port COM3`（Windows）或 `agent/stop-agent.sh --port /dev/ttyUSB0`（Linux），
   先加 `-List` / `--list` 看会停谁。详见 `references/troubleshooting.md` §12。

6. **设备停在 `login:`（重启后最常见）——先以 root 登录，别硬试**
   登录提示符要的是「用户名 + 密码」两行，而 `exec` 发的是「命令 + 探针」，
   于是命令被当成用户名、探针行被当成密码：**必然失败，还白等一个 30 秒超时**（试几次就是几分钟）。
   这些开发板 root 通常**无密码**，直接登录即可：

   * 人在终端：`$S shell` → 看到 `login:` 输入 `root` 回车 → `Ctrl+]` 退出；
   * 脚本化 / 无人值守：client 上以 **raw 透传**启动 agent（串口独占，先停掉协议模式 agent：
     `$S shutdown`，或在 client 上跑 `stop-agent.ps1` / `stop-agent.sh`）：
     `powershell -File <client>\agent\serial_agent.ps1 -Port COM3 -Baud 460800 -TcpPort 17801 -Raw`，
     再从 server 侧发两行：`printf '\nroot\n' | nc 127.0.0.1 17801`，看到 `root@<host>:~#` 即成功；
     然后停掉 raw agent（raw 模式没有协议通道，只能用 client 上的 `stop-agent` 脚本）、
     改回协议模式重启 agent。

   登录状态会一直保持（agent 持有同一条串口会话），所以**一次会话只需登录一次**。
   详见 `references/troubleshooting.md` §10。

## 发现 bug：请提交 patch，不要只绕过去

这套桥（`agent/*`、`cli/*`、`tests/*`、`skill/*`）由维护者在 GitHub 上持续修正。
**使用中踩到 bug，除了当下绕过，还要把修复交回上游**：

1. **先给最小复现**：触发命令、期望结果、实际输出（含退出码）、agent 日志（`-LogFile`）。
   先跑一遍 `sdb-check.sh` 并把输出附上——不少「桥的 bug」其实是设备重启或端口被占。
2. **改代码要成对改**：`agent/serial_agent.ps1` ↔ `agent/serial_agent.py`、
   `cli/devctl.ps1` ↔ `cli/devctl.py` 必须同步（本工具支持 ps↔py 交叉使用）；涉及协议时同步 `PROTOCOL.md`。
3. **跑自测再提**：`powershell -File tests/selftest.ps1`（含 `-Codec hex`）、
   `python3 tests/test_e2e.py`（含 `--agent-args "--codec hex"`）；有条件再跑 `bash tests/verify-live.sh <client>:<port>`。
4. **按仓库规范提交**：内核风格 commit（`<subsystem>: <祈使句摘要>`，正文 ≤72 列，`git commit -s` 带
   `Signed-off-by:`），从 `main` 切分支（`agent/...`、`cli/...`、`skill/...`）后提 PR，并在 PR 里贴自测输出。
5. **没有写权限时**：把 `git diff` 存成 `fix.patch`，连同最小复现与自测输出一起交给维护者。
6. **确实只能绕过时**（换编码、降波特率、改端口等）：在结果里写清**绕过了什么、为什么、风险是什么**，
   并给出建议的修复方向——别让同一个坑下次再踩。

> 仓库约定：补丁必须走 PR、CI 全绿后由维护者合并（`main` 不接受直接推送），且**两套实现与文档必须同步修改**——详见仓库根目录的 `REVIEW_POLICY.md` 与 `CONTRIBUTING.md`。

## 安全

* 破坏性操作（`rm`、`dd`、写 flash、`reset`、刷固件）**必须**先与用户确认，
  并先 `$S exec 'uname -a; hostname'` 确认目标是预期设备——端口/隧道可能指向另一台设备。
* `push` 会覆盖目标路径，先 `$S exec 'ls -l <dir>'` 看看。
* 不要把 agent 端口暴露到公网；TCP 方式配合 `SDB_TOKEN`（agent 用 `--auth` 启动）或 SSH。
