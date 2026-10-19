# 串口调试桥（Serial Debug Bridge）

> 让 **server（172.21.44.42）** 能够像本地一样操作接在 **client** 上的嵌入式设备：
> 在 server 上敲命令 → 到设备上执行 → 结果回传 server；server 与设备之间还能互传文件。

[![CI](https://github.com/cadywang/serial-debug-bridge/actions/workflows/ci.yml/badge.svg)](https://github.com/cadywang/serial-debug-bridge/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PRs&#32;Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-2472A8)](agent/serial_agent.ps1)
[![Python](https://img.shields.io/badge/Python-3.8%2B-3776AB)](agent/serial_agent.py)
[![platforms](https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20macOS-lightgrey)](README.md)

---

## 1. 背景与目标

| 角色 | 说明 |
| --- | --- |
| **嵌入式设备（device）** | 目标板，只有一个串口（UART）控制台，例如 `/dev/ttyUSB0` / `COM3`。 |
| **client** | 设备串口**物理连接**的那台机器。当前是串口接入点；未来可能通过网络访问它。 |
| **server（172.21.44.42）** | 你实际工作的机器。希望在这里敲命令、传文件。 |

本方案把「设备串口」和「server 的操作入口」解耦，达成：

* ✔ **在 server 上执行设备命令并取回输出**（交互式 shell 也支持）；
* ✔ **server → 设备** 传文件（上传 / 下载，带 md5 校验）；
* ✔ **两种接入都能用**：
  * 现在：设备串口接在 client（本地 / 网络到 client）；
  * 未来：通过网络连到 client（TCP 直连 / SSH / 反向隧道）。
* ✔ 不依赖设备侧安装任何东西（只用设备上现成的 `sh` / `base64` / `md5sum`）。

---

## 2. 架构

整个系统只有两个核心组件：

```
   ┌──────────────┐        ┌───────────────────────────────┐        ┌──────────────┐
   │   server     │        │            client             │        │  嵌入式设备   │
   │ 172.21.44.42 │        │  (串口插在这台机器上)          │        │              │
   │              │        │                               │        │              │
   │   devctl  ───┼──TCP──▶│  serial_agent  ◀── 串口 ──────┼───────▶│  串口控制台   │
   │  (CLI 工具)   │  或    │  (ps1 / py 两版)              │  UART  │  (busybox sh)│
   │              │──SSH──▶│                               │        │              │
   └──────────────┘        └───────────────────────────────┘        └──────────────┘
        你在这里敲命令              把「网络」翻译成「串口」               被调试的目标板
```

* **`serial_agent`（跑在 client）**：打开串口，把「网络请求」翻译成对串口的读写。
  两版选其一：
  * `serial_agent.ps1` —— Windows 专用，**零依赖**（PowerShell 5.1+ 直接跑）。
  * `serial_agent.py` —— 跨平台（Linux / macOS / Windows），真实串口需要 `pyserial`；
    `--mock` 自测模式不需要任何依赖。
* **`devctl`（跑在 server）**：命令行工具，通过 TCP 或 SSH 把命令发给 agent。
  两版选其一：
  * `devctl.py` —— 跨平台，**Linux server 首选**（只需 Python 3）。
  * `devctl.ps1` —— Windows server 用。

两个组件之间的通信协议与语言无关（见附录 / `PROTOCOL.md`），所以
**四种版本可以任意组合**（py 的 devctl 连 ps 的 agent，反之亦然）。

---

## 3. 目录结构

```
serial-debug-bridge/
├── README.md                  ← 本文档（中文）
├── PROTOCOL.md                ← 通信协议参考（中文）
├── CONTRIBUTING.md            ← 贡献流程与代码规范（中文）
├── REVIEW_POLICY.md           ← 审查与合并规则：闸门、补丁同步、实测坑（中文）
├── CHANGELOG.md               ← 更新日志（Keep a Changelog）
├── SECURITY.md                ← 漏洞披露策略与安全须知
├── SUPPORT.md                 ← 求助与提问需要带的信息
├── CODE_OF_CONDUCT.md         ← 贡献者公约
├── LICENSE                    ← MIT
├── .editorconfig / .gitattributes / .gitignore
├── agent/                     ← 跑在 client（串口所在机器）
│   ├── serial_agent.ps1       ← Windows 代理（零依赖）
│   ├── serial_agent.py        ← 跨平台代理（Python 3）
│   ├── requirements.txt       ← 仅真实串口需要 pyserial
│   ├── start-agent.bat        ← Windows 启动脚本
│   ├── start-agent.sh         ← Linux 启动脚本
│   ├── stop-agent.ps1 / .bat  ← Windows 停止脚本（释放串口）
│   ├── stop-agent.sh          ← Linux/macOS 停止脚本
│   └── serial-agent.service   ← systemd 单元示例（Linux 开机自启）
├── cli/                       ← 跑在 server
│   ├── devctl.py              ← 主用 CLI（跨平台，Python 3）
│   └── devctl.ps1             ← Windows CLI（PowerShell）
├── tests/                     ← 自测（不需要真实硬件）
│   ├── selftest.ps1           ← PowerShell 代理 + CLI 全链路
│   ├── test_e2e.py            ← Python 代理 + CLI 全链路
│   └── verify-live.sh         ← 真机端到端验证（含 md5 往返比对）
├── governance/                ← 仓库治理声明（机器可读）
│   ├── branch-protection.json ← main 分支保护策略
│   └── repository-settings.json
└── tools/
    └── create-github-repo.ps1 ← 一键建仓 + 推送 + 施加保护
```
## 4. 环境要求

| 位置 | 需要 |
| --- | --- |
| **client（Windows）** | Windows 10/11 + 自带 PowerShell 5.1。**无需安装任何东西。** |
| **client（Linux）** | Python 3；真实串口再装 `pyserial`（`pip install pyserial`）。 |
| **server（Linux）** | Python 3（发行版自带）。**无需第三方库。** |
| **server（Windows）** | 自带 PowerShell 5.1。 |

> 设备侧不需要安装任何软件，只使用 busybox/coreutils 里通常都有的
> `sh`、`base64`、`md5sum`。

---

## 5. 快速开始

下面假设：

* server = `172.21.44.42`（Linux，已放好本项目的 `cli/devctl.py`）；
* client = `172.21.5.10`（串口接在它上面）；
* 设备串口：Windows 上是 `COM3`，Linux 上是 `/dev/ttyUSB0`，波特率 `115200`。

### 场景一：client 是 Windows（推荐、零依赖）

**① 在 client 上启动 agent**（任选一种）：

```powershell
# 方式 1：双击/运行现成脚本（编辑里面的 COM 口与波特率）
agent\start-agent.bat

# 方式 2：直接命令行
powershell -NoProfile -ExecutionPolicy Bypass -File C:\tools\serial_agent.ps1 -Port COM3 -Baud 115200 -TcpPort 7801
```

看到日志 `Transport: TCP, listening on 0.0.0.0:7801` 即表示就绪。

**② 在 server 上操作设备**：

```bash
# 查看设备信息 / 连通性
python3 cli/devctl.py --tcp 172.21.5.10:7801 info

# 在设备上执行命令（结果直接打印回 server）
python3 cli/devctl.py --tcp 172.21.5.10:7801 exec "uname -a"
python3 cli/devctl.py --tcp 172.21.5.10:7801 exec "ls -l /tmp"

# 上传文件：server -> 设备
python3 cli/devctl.py --tcp 172.21.5.10:7801 push ./firmware.bin /tmp/firmware.bin

# 下载文件：设备 -> server
python3 cli/devctl.py --tcp 172.21.5.10:7801 pull /etc/config.txt ./config.txt

# 交互式控制台（相当于把串口“搬”到 server 终端）
python3 cli/devctl.py --tcp 172.21.5.10:7801 shell
```

**③ 用完停掉 agent**（串口是独占的：agent 活着，别的程序就打不开这个口）：

```powershell
# 在 client 上：结束本机的 agent 并释放串口（-List 只列不杀，-Port 只停指定的口）
powershell -NoProfile -ExecutionPolicy Bypass -File C:\tools\stop-agent.ps1 -Port COM3
```

也可以从 server 侧让 agent 自己退出（TCP 与 SSH 都支持）：

```bash
python3 cli/devctl.py --tcp 172.21.5.10:7801 shutdown
```

### 场景二：client 是 Linux（Python 代理）

```bash
# 在 client 上
pip3 install pyserial                     # 仅真实串口需要一次
python3 agent/serial_agent.py --port /dev/ttyUSB0 --baud 115200 --tcp-port 7801
# 或： ./agent/start-agent.sh
```

在 server 上的用法与场景一完全相同（`devctl.py --tcp 172.21.5.10:7801 ...`）。

### 场景三：串口直接插在 server 上

agent 与 devctl 跑在同一台机器上，走本地回环即可：

```bash
# 终端 A：启动 agent（Python 版）
python3 agent/serial_agent.py --port /dev/ttyUSB0 --baud 115200 --tcp-port 7801

# 终端 B：操作设备
python3 cli/devctl.py --tcp 127.0.0.1:7801 exec "uname -a"
```

---

## 6. 接入方式详解（覆盖“现在串口 / 未来网络”）

不管拓扑怎么变，问题最终只有一个：**devctl 如何到达 client 上的 agent**。
下面 4 种方式全部支持，按你的网络条件任选。

### 方式 A：串口本机直连（server 上就有串口）

device ──串口── server，agent 与 devctl 同机，走 `127.0.0.1`。见「场景三」。

### 方式 B：TCP 直连（client 能被 server 直接访问）★最常用

```
client 运行 agent 监听 0.0.0.0:7801  ──  server: devctl --tcp <client-ip>:7801
```
* 前提：server 能 ping/连通 client 的 7801 端口（同一内网、或已放行防火墙）。
* 优点：简单、低延迟；支持交互式 `shell`。
* Windows 放行端口：`New-NetFirewallRule -DisplayName "serial-agent" -Direction Inbound -Protocol TCP -LocalPort 7801 -Action Allow`

### 方式 C：SSH（server 主动 ssh 到 client，client **无需**开端口）

```
server: devctl --ssh user@<client-ip> ...   ──ssh──▶  client 上自动拉起 agent(stdio) ──串口──▶ device
```
* 前提：server 能 SSH 登录 client（client 上要有 SSH 服务端）。
  * Windows client：启用「OpenSSH 服务器」功能即可。
  * Linux client：`sshd` 一般已装。
* 优点：**不用在 client 上开放任何 TCP 端口**；复用 SSH 的加密与认证；天然适合“未来通过网络连到 client”。
* 注意：SSH 传参下**不支持交互式 `shell`**（stdio 是纯协议通道）；如需交互请用方式 B，或在 client 本机看串口。

Windows client 示例：

```bash
python3 cli/devctl.py --ssh user@172.21.5.10 \
    --remote-kind ps \
    --remote-python 'powershell.exe' \
    --remote-agent 'C:\tools\serial_agent.ps1' \
    --port COM3 --baud 115200 \
    exec "uname -a"
```

Linux client 示例：

```bash
python3 cli/devctl.py --ssh root@172.21.5.10 \
    --remote-agent /opt/serial-debug-bridge/serial_agent.py \
    --port /dev/ttyUSB0 --baud 115200 \
    exec "ls -l /"
```

### 方式 D：SSH 反向隧道（client 在 NAT 后面，只能 client → server）

适用于「client 无法被 server 主动访问，但 client 能主动连 server」的场景。
思路：在 **client** 上建立反向隧道，把 client 本地的 agent 端口映射到 server 上：

```bash
# ① client 上：启动 agent（监听本机 7801）
python3 agent/serial_agent.py --port /dev/ttyUSB0 --baud 115200 --tcp-port 7801

# ② client 上：把 client:7801 反向映射到 server:127.0.0.1:7801
#    （-N -R 表示只做端口转发、不执行远程命令；可加 autossh 保活）
ssh -N -R 127.0.0.1:7801:127.0.0.1:7801 user@172.21.44.42

# ③ server 上：像本地一样用
python3 cli/devctl.py --tcp 127.0.0.1:7801 exec "uname -a"
```
（若 server 的 sshd 允许 `GatewayPorts`，也可把 `-R` 的监听地址改成 `0.0.0.0` 供他人使用。）

### 方式对比

| 方式 | 谁在监听 | client 需要开端口 | 支持交互 shell | 典型场景 |
| --- | --- | --- | --- | --- |
| A 本地串口 | 无（127.0.0.1） | — | ✔ | 串口就在 server 上 |
| B TCP 直连 | client:7801 | ✅ 是 | ✔ | 内网 / 已放行 |
| C SSH | 无 | ❌ 否 | ✘ | 只许 server→client SSH |
| D 反向隧道 | client:7801 + server 隧道 | ❌ 否（client 出站） | ✔ | client 在 NAT 后 |

---

## 7. devctl 命令参考

### 7.1 通用选项（两种 devctl 通用）

| 选项 (`devctl.py`) | 选项 (`devctl.ps1`) | 说明 |
| --- | --- | --- |
| `--tcp HOST[:PORT]` | `-Tcp HOST:PORT` | 连接 TCP 代理，端口默认 `7801` |
| `--ssh USER@HOST` | `-Ssh USER@HOST` | 通过 SSH 拉起 client 上的代理 |
| `--ssh-port N` | `-SshPort N` | SSH 端口（默认 22） |
| `-i FILE` | `-KeyFile FILE` | SSH 私钥 |
| `--remote-kind py\|ps` | —（用 `-RemotePwsh`） | ssh 时 client 上跑的是 py 还是 ps 代理 |
| `--remote-python` | `-RemotePwsh` | ssh 时 client 上的解释器（`python3` / `powershell.exe`） |
| `--remote-agent PATH` | `-RemoteAgent PATH` | ssh 时 client 上代理脚本的路径 |
| `--port DEV` | `-ComPort DEV` | ssh 时 client 上的串口（默认 `/dev/ttyUSB0` / `COM3`） |
| `--baud N` | `-Baud N` | 波特率（默认 115200） |
| `--timeout MS` | `-Timeout MS` | 单条命令超时（毫秒，默认 30000） |
| `--token TOKEN` | `-Token TOKEN` | 代理若用 `--auth` 启动，这里给出相同口令 |
| `-q` | `-Quiet` | 只输出结果，不打印诊断信息 |

### 7.2 子命令

| 子命令 | 作用 | 退出码 |
| --- | --- | --- |
| `exec <命令>` | 在设备上执行命令，stdout+stderr 原样返回 | 返回**设备命令自身的退出码**；超时=124 |
| `push <本地> <远端>` | 上传文件（server→device），带 md5 校验 | 0=成功且校验通过 |
| `pull <远端> <本地>` | 下载文件（device→server），带 md5 校验 | 0=成功且校验通过 |
| `md5 <远端>` | 打印设备上某文件的 md5 | 0/1 |
| `reset` | 通过 DTR 复位开发板 | 0/1 |
| `shutdown` | 让 agent 退出并释放串口（TCP / SSH 均可） | 0/1 |
| `info` | 打印代理/设备/版本信息 | 0/1 |
| `shell` | 进入交互式串口控制台（**仅 TCP**；Ctrl+`]` 退出） | 0 |

> `exec` 会把设备端命令的退出码作为 devctl 自己的退出码，因此可以直接串到脚本/CI 里判断成败。

### 7.3 示例

```bash
# 判断设备上某文件是否存在
if python3 cli/devctl.py --tcp 172.21.5.10:7801 exec "test -f /etc/passwd"; then
    echo "exists"
fi

# 把整个目录打成 tar 再传回 server
python3 cli/devctl.py --tcp 172.21.5.10:7801 exec "tar czf /tmp/log.tgz /var/log"
python3 cli/devctl.py --tcp 172.21.5.10:7801 pull /tmp/log.tgz ./log.tgz
```

---

## 8. agent 参数参考

### 8.1 `serial_agent.ps1`（Windows client）

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-Port` | `COM3` | 串口名（也可写 `\\.\COM10`） |
| `-Baud` | `115200` | 波特率 |
| `-Parity` / `-DataBits` / `-StopBits` / `-Handshake` | `None` / `8` / `One` / `None` | 串口参数 |
| `-Listen` | `0.0.0.0` | TCP 绑定地址 |
| `-TcpPort` | `7801` | TCP 端口 |
| `-Stdio` | 关 | 以 stdio 方式服务（供 SSH 调用） |
| `-Raw` | 关 | 纯 TCP↔串口透传（ser2net 风格，可用 PuTTY/telnet 直连） |
| `-Mock` | 关 | 使用内置模拟设备（无需硬件，用于自测） |
| `-Codec` | `auto` | 强制传输编码：`auto`/`base64`/`busybox-base64`/`openssl-base64`/`hex` |
| `-Auth` | 空 | 非空则要求首包 `AUTH <token>` |
| `-DefaultTimeoutMs` | `30000` | 默认命令超时 |
| `-MaxBodyBytes` | 33554432 | 单个请求正文上限（32 MiB） |
| `-LogFile` | 空 | 追加写日志文件 |

### 8.2 `serial_agent.py`（跨平台 client）

与上表一一对应：`--port` `--baud` `--parity` `--data-bits` `--stop-bits` `--handshake`
`--listen` `--tcp-port` `--stdio` `--raw` `--mock` `--auth` `--default-timeout-ms` `--log-file`。

> **虚拟串口/COM10 及以上**：Windows 上请写成 `-Port '\\.\COM10'`。

---

## 9. 文件传输是怎么实现的（自适应编码 + 逐块校验重传）

设备侧不装任何东西，只用设备上现成的工具。要点：

1. **编码自适应。** agent 首次传输前会探测设备可用的编解码方式，优先级为：
   `base64` → `busybox base64` → `openssl base64` → **hex+awk**。
   大多数设备有 `base64`；**本次实测的 Yocto 设备（精简镜像）没有任何 base64**，
   于是自动落到 hex+awk —— 用设备上的 `awk` 把十六进制文本还原成字节，
   下载时用 busybox 的 `od -v -b` 把字节读成八进制文本。可用 `-Codec` / `--codec` 强制指定。

2. **逐块校验 + 重传（关键）。** 串口在较高波特率（本例 460800）下会**偶发丢字符**，
   整块写入必然出错。因此上传按 512/1024 字节分块，每块：

   * agent 把这一块的 md5 一起下发；
   * 设备先解码到临时文件，**自己算 md5** 与下发的值比对；
   * 一致才 `cat >>` 追加进目标文件并回 `ACK`；不一致则回 `BAD`，agent **自动重发该块**（最多 8 次）；
   * agent 最后再用 `md5sum` 核对整个文件，`devctl` 提示 `verified=True/False`。

   于是即使链路偶发丢字节，最终文件仍与源文件**逐字节一致**。

3. **下载（pull）** 走的是另一条路：agent 在设备上执行 `od -v -b <文件>`，
   把设备上的字节读回 server，devctl 落盘后再比一次 md5。

> **实测结论**（client=Windows，COM3@460800，设备=Yocto 机顶盒，经反向 SSH 隧道从 server 操作）：
> `info` / `exec`（含提示符与 ANSI 颜色清理）/ `pull` 均正常；
> **4KB、60KB、200KB 二进制文件的 push 与 pull 往返 md5 完全一致**。
> 速度约 **1~1.2 KB/s**（受逐块校验与串口重发限制）。大文件建议先
> `tar cz` 压缩后再传，或降低波特率以提高可靠性。
## 10. 常驻 / 开机自启

### 停止 agent（释放串口）

串口**独占**：agent 活着就一直占着它，别的程序（串口终端、IDE 的串口监视器、新起的
agent）都会打不开。按情况选一种停法：

| 情况 | 怎么停 |
| --- | --- |
| 还能连上 agent（TCP / SSH） | `devctl ... shutdown`（agent 自己退出并回 `pid`） |
| 连不上，人在 client 上（Windows） | `powershell -File agent\stop-agent.ps1 -Port COM3`（`-List` 只列不杀） |
| 连不上，人在 client 上（Linux） | `./agent/stop-agent.sh --port /dev/ttyUSB0`（`--list` 只列不杀） |
| 装了 systemd 单元 | `sudo systemctl stop serial-agent` |

> `shutdown` 与 stop-agent 脚本都只结束 **agent 进程**（串口随之释放），设备本身不受影响。
> `-Raw` 透传模式没有协议通道，只能用本地脚本停。

### client = Linux（systemd）

```bash
sudo cp agent/serial-agent.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now serial-agent
sudo systemctl status serial-agent
# 实时日志
journalctl -u serial-agent -f
```

### client = Windows

任选一种：

* **任务计划程序**：新建任务 → 触发器「计算机启动时」→ 操作
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\tools\serial_agent.ps1 -Port COM3 -Baud 115200 -TcpPort 7801`
  → 勾选「不管用户是否登录都运行」。
* **NSSM**：`nssm install SerialAgent "powershell.exe" "-NoProfile -ExecutionPolicy Bypass -File C:\tools\serial_agent.ps1 -Port COM3 -Baud 115200"`

### 保活（反向隧道）

方式 D 的隧道建议用 `autossh`：
`autossh -M 0 -N -R 127.0.0.1:7801:127.0.0.1:7801 user@172.21.44.42`

---

## 11. 安全建议

* **优先用方式 C（SSH）**：不在 client 上开放端口，复用 SSH 的加密与认证。
* 必须用 TCP（方式 B）时：
  * 只在可信内网开放，或用防火墙限制来源 IP；
  * 用 `-Auth <口令>` 启动 agent（`--auth` / `-Auth`），devctl 侧用 `--token` `-Token` 提供相同口令；
  * 不要把 `7801` 直接暴露到公网。
* 设备控制台通常就是 **root shell**：谁能连上 agent 谁就能完全控制设备，请按此标准防护。
* Windows client 上把 agent 运行在专用账号下，避免不必要的权限。

---

## 12. 故障排查（FAQ）

**Q1. `exec` 一直超时（返回 124）？**
* 设备控制台**没停在 shell 提示符**上（比如停在登录界面、或正在跑某个前台程序）。
  先用 `devctl ... shell` 进入看看到底停在哪；登录/退出前台程序后 `exec` 即可正常工作。
  （agent 会一直持有串口，所以一旦进入 shell，后续 `exec` 都有效。）
* 设备**重启后会停在 `login:`**：直接以 **root** 登录（这些开发板 root 通常无密码），
  **不要反复用 `exec` 试** —— 它会把命令当用户名、探针行当密码，每次白等一个 30 秒超时。
  登录方式（`devctl ... shell` 手动登录，或 raw 透传模式发 `root`）见 skill 的
  `references/troubleshooting.md` 第 10 节。
* 波特率/串口名不对：核对 `-Port` `-Baud` / `--port` `--baud`，确认设备实际参数。
* 换行/回车不对：极少数设备只认 `\r`，可在设备侧 `stty` 调整，或先 `shell` 手动敲一次。

**Q2. 命令输出里混进了我敲的命令本身（回显）？**
* 正常现象。agent 会自动剥离终端回显；若设备非常规，可在设备上执行一次 `stty -echo`。
* 若仍有残留，多为设备提示符（如 `# `）被一起带回，属显示层问题，不影响退出码。

**Q3. `push`/`pull` 报 `base64-decode-failed` 或 `read-failed`？**
* 设备上缺少 `base64` 或 `md5sum`；`exec "which base64 md5sum"` 确认。
* 目标目录不存在/不可写（`push` 不会自动 `mkdir`）：先 `exec "mkdir -p /tmp"`。

**Q4. `pull` 下来的文件和设备上不一致？**
* devctl 会比对 md5 并在不一致时**打印 WARNING 且返回非 0**；检查是不是串口干扰/波特率不稳。
  大文件建议降低波特率或缩短线缆后再试。

**Q5. 连不上 client:7801？**
* client 防火墙未放行；或 agent 只绑了 `127.0.0.1`（应绑 `0.0.0.0`）。
* 用 `exec`/`info` 之外先 `ping`、`telnet client 7801` 验证网络路径。

**Q6. 一个 client 上能同时接多个设备吗？**
* 可以。每个串口启动一个 agent 实例，用**不同 TCP 端口**（如 7801、7802）。

**Q7. 交互式 `shell` 支持哪些传输？**
* 只支持 **TCP（方式 A/B/D）**。SSH（方式 C）的 stdio 是纯协议通道，`shell` 会返回
  `shell-requires-tcp`；请改用 TCP 或在 client 本机看串口。

**Q8. Windows 的 `-Port COM10` 报错？**
* 用 `-Port '\\.\COM10'`。

**Q9. 串口打不开（“访问被拒绝” / busy）？**
* 先看是不是本项目的 agent 还活着——串口是独占的，agent 活着别的程序就打不开：
  * 还能连上 → `devctl ... shutdown`（agent 自己退出并释放串口）；
  * 连不上（进程成了孤儿） → 在 client 上跑 `agent\stop-agent.ps1 -Port COM3`（Windows）
    或 `agent/stop-agent.sh --port /dev/ttyUSB0`（Linux），先加 `-List` / `--list` 看看会停谁。
  细节见 §10「停止 agent（释放串口）」。
* 不是 agent 的话，串口终端（PuTTY / MobaXterm / IDE 的串口监视器）也会一直占着它，先关掉它们。
* Windows 上想确认到底是谁持有句柄，可用 Sysinternals 的 `handle64.exe -a <设备名>`
  （FTDI 转串口上设备名是 `VCP0`）。

---

## 13. 自测（不需要真实硬件）

两套自测都使用 agent 的 `-Mock` / `--mock` 内置模拟设备，
完整跑一遍「执行命令 / 退出码 / 上传 / 下载 / md5 / 复位 / 交互 shell」：

```powershell
# Windows：用 PowerShell 驱动
powershell -ExecutionPolicy Bypass -File tests\selftest.ps1
powershell -ExecutionPolicy Bypass -File tests\selftest.ps1 -Codec hex
# 也可指定已运行的代理：
powershell -ExecutionPolicy Bypass -File tests\selftest.ps1 -Target 127.0.0.1:7801
```

```bash
# 任意平台：用 Python 驱动 devctl.py
python3 tests/test_e2e.py
python3 tests/test_e2e.py --target 127.0.0.1:7801
```

预期结果均为 `N passed, 0 failed`（跨版本组合：ps↔py 均已验证）。

---

## 14. 假设与限制

* **前提**：设备串口控制台**已经停在 shell 提示符**（多数开发板自动进 shell；需要登录的设备请先登录）。
* **串口独占**：一个串口同一时刻只服务一个 agent 实例（要换 agent 或改用 `-Raw`，先按 §10 停掉旧的）；
  agent 内部一次处理一个会话。
* **交互 shell 仅 TCP**（见 Q7）。
* **设备侧依赖** `sh` + `base64` + `md5sum`（busybox/coreutils 标准件）。`reset` 依赖串口的 DTR 线（若设备未接 DTR-to-RESET，则无效）。
* **编码**：命令正文按 UTF-8 发送；输出按 UTF-8 解码（无法解码的字节以替换符显示），md5 校验基于**原始字节**，不受编码影响。
* **单条正文上限**默认 32 MiB（可在 agent 侧用 `--max-body-bytes` 调整）；超大文件建议先 `tar` 并分片。

---

## 15. 仓库治理与协作

本仓库按专业开源项目的标准组织，**`main` 分支已启用保护**，任何改动都必须走 PR：

| 规则 | 值 |
| --- | --- |
| 直推 `main` | ❌ 禁止（`enforce_admins: true`，管理员也一样） |
| 合并方式 | ✅ 仅 **Rebase and merge**（PR 里每个提交原样落到 `main`，含 `Signed-off-by`），线性历史 |
| 必需审查 | ✅ 必须走 PR + CI 全绿；单人维护模式下由维护者审阅后合并（`required_approving_review_count: 0`，原因见 [REVIEW_POLICY.md](REVIEW_POLICY.md)） |
| 过期审查 | 有新提交后自动作废（`dismiss_stale_reviews`） |
| 最近推送审批 | ⚙️ 单人模式下关闭（`require_last_push_approval: false`）；有第二位维护者时开启 |
| 必需状态检查 | ✅ CI 六个 job 全绿且为最新提交（见下表） |
| 讨论resolve | ✅ 全部 conversation 需被解决 |
| 强推 / 删除分支 | ❌ 禁止 |
| 合并后删除分支 | ✅ 自动删除 |

CI 必需检查（`governance/branch-protection.json` 中的 contexts）：

1. `Hygiene (encoding, line endings, syntax)`
2. `PowerShell agent + CLI (mock)`
3. `Python agent + CLI (mock) (ubuntu-latest)`
4. `Python agent + CLI (mock) (windows-latest)`
5. `Cross implementation check`
6. `PR gate (title + merge checklist)`

前五个在 `.github/workflows/ci.yml`，第六个在 `.github/workflows/pr-gate.yml`：
`pr-gate` 校验 **PR 标题符合内核规范**（标题是检索与变更日志的入口，而且一旦有人改回
squash 合并，它就会变成 `main` 上的提交标题）与 **模板里「合并前清单」是否逐条勾选**，
编辑 PR 描述后会重跑。改门禁或改清单都要走 PR，清单条目在 `.github/pull_request_template.md`。

相关约定：

* 贡献流程、代码风格（**代码注释英文 / 文档中文**、UTF-8 无 BOM、LF）见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。
* 审查与合并规则（三道闸门、补丁同步清单、已实测的坑）见 [`REVIEW_POLICY.md`](REVIEW_POLICY.md)。
* 安全问题**不要**开公开 Issue，见 [`SECURITY.md`](SECURITY.md)。
* 提问前先看 [`SUPPORT.md`](SUPPORT.md)，Issue/PR 模板在 `.github/`。
* 依赖更新由 `.github/dependabot.yml` 发起 PR（同样要过 CI 五个 job；bot 生成的提交按 `--skip-bots` 豁免 commit 风格检查，见 [`REVIEW_POLICY.md`](REVIEW_POLICY.md)）。
* 面向 server 的 Codex skill 在 `skill/serial-debug-bridge/`，安装到 server 的
  `~/.codex/skills/` 后即可让 server 侧的 Codex 直接调用（`scripts/sdb` 为统一入口，
  `scripts/sdb-check.sh` 做链路与设备身份自检）：
  `scp -r skill/serial-debug-bridge <server>:~/.codex/skills/`
* 重新施加/校验保护规则：
  `pwsh -File tools/create-github-repo.ps1 -Owner <you>`（幂等，支持 `-DryRun`）。

---
## 16. 附录：协议速览

请求/响应都是「**一行 ASCII 头 + 定长二进制正文**」：

```
请求：  <OP> [k=v ...] len=<n>\n <n 字节正文>
响应：  OK  [k=v ...] len=<n>\n <n 字节正文>
        ERR code=<c> msg=<m> len=<n>\n <n 字节正文>
```

操作：`PING` `INFO` `EXEC` `PUSH` `PULL` `MD5` `RESET` `SHELL` `AUTH` `BYE`。
完整字段定义见 [`PROTOCOL.md`](PROTOCOL.md)。
