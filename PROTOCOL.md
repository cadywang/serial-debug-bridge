# 通信协议参考（devctl ⟷ serial_agent）

本协议同时被 `devctl.py` / `devctl.ps1` 与 `serial_agent.py` / `serial_agent.ps1`
实现，四个版本可任意互连。协议与语言无关，只有两点约定：**头行是 ASCII**，
**正文是定长原始字节**。

## 1. 传输层

* **TCP**：agent 监听 `0.0.0.0:7801`（可配）；devctl 主动连接。
* **stdio**：agent 以 `--stdio` / `-Stdio` 启动，协议直接跑在 stdin/stdout 上
  （用于 `devctl --ssh` 经 `ssh` 拉起）。
* 一个连接按「请求 → 响应」交替进行；`SHELL` 之后连接切换为**原始字节透传**。

## 2. 帧格式

```
请求：  <OP> [key=value ...] len=<n>\n  <n 字节正文>
响应：  OK   [key=value ...] len=<n>\n  <n 字节正文>
        ERR  code=<c> msg=<m> len=<n>\n <n 字节正文>
```

* 头行以单个 `\n` 结束（`\r` 会被忽略），字段以空格分隔，单位均为字节。
* `len=` 恒存在，表示紧随其后的正文长度；`len=0` 表示无正文。
* 正文可以包含任意字节（含 `\0`、`\n`），接收方按 `len` 精确读取。

## 3. 请求操作

| OP | 正文 | 说明 |
| --- | --- | --- |
| `PING` | 空 | 探活，返回 `OK`，正文 `pong` |
| `AUTH <token>` | token 字符串 | 仅当 agent 以 `--auth` 启动时需要，且必须是**首个**请求 |
| `INFO` | 空 | 返回代理/设备信息（多行文本） |
| `EXEC` | 命令文本（UTF-8） | 在设备上执行；可选 `timeout=<ms>` |
| `PUSH` | `base64(远端路径)\n<文件原始字节>` | 上传文件 |
| `PULL` | `base64(远端路径)` | 下载文件；响应正文即文件原始字节 |
| `MD5` | `base64(远端路径)` | 返回设备上文件的 md5（正文为 32 位十六进制） |
| `RESET` | 空 | 拉低再拉高 DTR；可选 `delay=<ms>` |
| `SHELL` | 空 | 收到 `OK` 后，连接转为**原始透传**（仅 TCP 传输支持） |
| `BYE` | 空 | 结束会话并关闭连接 |
| `SHUTDOWN` | 空 | 让 **agent 自己**退出并释放串口；响应 `OK pid=<n>` 后连接关闭 |

`SHUTDOWN` 停的是 client 上的 agent 进程（串口随之释放），不是设备。它需要一条协议通道，
因此只支持 TCP 与 stdio；`-Raw` / `--raw` 透传模式没有协议，请直接在 client 上结束进程。
响应里的 `pid` 让调用方确认停掉的是哪一个 agent。

## 4. 响应字段

| 响应 | 关键字段 | 含义 |
| --- | --- | --- |
| `OK` + `EXEC` | `rc=<n>` | 设备命令退出码 |
| `OK` + `PUSH` | `written=<n>` `md5=<hex>` `verified=<True/False>` | 写入字节数、本地 md5、设备侧 md5 是否一致 |
| `OK` + `PULL` | `md5=<hex>` | 下载内容的 md5 |
| `OK` + `SHUTDOWN` | `pid=<n>` | 即将退出的 agent 进程号 |
| `ERR` | `code=<c>` `msg=<m>` | 错误类别与说明 |

常见 `code`：`auth` `timeout` `device` `decode` `badrequest` `too-large`
`unknown-op` `unsupported`。`ERR` 的正文通常携带设备侧原始报错文本。

## 5. 在设备上定位命令输出：marker 与回显

设备控制台是 tty，会把你输入的字符**回显**出来，且回显与程序输出的先后顺序依实现而定。
agent 用如下方法与回显解耦：

1. 发送命令文本，再发送一行探针：

   ```sh
   echo "__DEVCTL_<随机token>__ $?"
   ```
2. 持续读取串口，直到匹配到正则 `__DEVCTL_<token>__\s*(\d+)`。
   由于**回显的那一行**里是 `$?`（不含数字），而**真实输出**里是具体退出码（含数字），
   因此第一次匹配一定命中真实输出，取其数字作为 `rc`。
3. 清理回显：在 marker 之前的文本里，
   * 先切掉「第一处命令回显」之前的所有内容（顺带去掉上一次残留的提示符）；
   * 再按精确匹配删掉其余命令行回显与探针回显；
   * 两端去空行后，剩下的就是命令的真实输出。

> 该策略对「先回显再执行」和「边回显边执行」两种时序都成立。

## 6. 文件传输细节

设备侧不安装任何东西，agent 会自动从下面这条「编码链」里挑第一个可用的：

| name | 上传（解码到设备） | 下载（从设备读出） |
| --- | --- | --- |
| `base64` | `base64 -d` | `base64` |
| `busybox-base64` | `busybox base64 -d` | `busybox base64` |
| `openssl-base64` | `openssl base64 -d` | `openssl base64` |
| `hex` | `awk`（十六进制→字节） | `od -v -b` |

探测方法：向 `/tmp/.devctl_probe` 写入 5 字节 `hello` 再读回比对，第一个成功者即被缓存。
可用 agent 的 `-Codec` / `--codec` 强制指定。

### 6.1 上传：逐块校验 + 重传

串口在高波特率下会偶发丢字符，因此上传**不是**一次性下发，而是分块（512/1024 字节）：

```
awk '<hex2bytes>' > '/tmp/.devctl_blk' << '__DEVCTL_HEOF_<i>__'
<该块数据的十六进制，每行 64 字符>
__DEVCTL_HEOF_<i>__
if [ "$(md5sum '/tmp/.devctl_blk' | cut -d" " -f1)" = "<该块的 md5>" ]; then \
    cat '/tmp/.devctl_blk' >> '<远端路径>'; echo __DEVCTL_A''CK_<i>__; \
  else echo __DEVCTL_BA''D_<i>__; fi
```

* 设备**自己计算**这一块的 md5；一致才追加到目标文件并回 `ACK`，否则回 `BAD`。
* agent 看到 `BAD`（或超时）就**重发该块**，最多 8 次。
* 全部块完成后，agent 再执行 `md5sum '<远端路径>'` 核对整文件，写回 `verified=<True/False>`。

> 标记写成 `__DEVCTL_A''CK_<i>__`（成对空引号）：回显里不会出现 `__DEVCTL_ACK_<i>__`，
> 因此 agent 匹配到的必然是 `echo` 的真实输出；**绝不能**用单个引号（会让 shell 停在续行）。

### 6.2 下载

agent 执行 `od -v -b '<远端路径>'`，把输出里每行的首列（偏移地址）丢弃，
其余 1~3 位八进制数值即各字节；拼回原始字节后回传（响应头带 `md5=`）。

远端路径在拼 shell 命令前统一做单引号转义。
## 7. 示例会话（TCP，抓包视角）

```
▶ EXEC timeout=30000 len=7
  uname -a
◀ OK rc=0 len=45
  Linux mock 5.10.0 #1 SMP ... GNU/Linux\n

▶ PUSH timeout=30000 len=35
  L3RtcC9hLmJpbg==\n<...文件字节...>
◀ OK rc=0 written=2000 md5=09ccbd... verified=True len=49
  ...
```

（`len`、正文均以字节计；上面为便于阅读做了示意。）
