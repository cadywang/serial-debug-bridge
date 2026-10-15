#Requires -Version 5.1
<#
.SYNOPSIS
    Serial debug bridge agent (runs on the CLIENT -- the machine the embedded
    device's UART is physically plugged into).

.DESCRIPTION
    Bridges an embedded device serial console to TCP or stdio and speaks a tiny
    "header line + binary body" protocol so a remote devctl can:
      * run shell commands on the device and capture output   (EXEC)
      * upload a file from the server to the device           (PUSH)
      * download a file from the device to the server         (PULL)
      * reset the board via DTR                               (RESET)

        remote devctl  <--TCP / SSH-->  this agent  <--UART-->  embedded device

    No third-party dependencies: uses only System.IO.Ports and
    System.Net.Sockets from the .NET Framework, so any Windows with
    PowerShell 5.1+ can run it without installing Python.

.EXAMPLE
    # Mode A: listen on TCP and wait for the remote devctl (default 0.0.0.0:7801)
    powershell -ExecutionPolicy Bypass -File serial_agent.ps1 -Port COM3 -Baud 115200

.EXAMPLE
    # Mode B: serve over stdin/stdout, meant to be launched through SSH
    powershell -ExecutionPolicy Bypass -File serial_agent.ps1 -Stdio -Port COM3 -Baud 115200

.EXAMPLE
    # Self test: no hardware needed, use the built-in mock device
    powershell -ExecutionPolicy Bypass -File serial_agent.ps1 -Mock -TcpPort 7801
#>
[CmdletBinding()]
param(
  # ---- transport ----
  [string]$Listen = '0.0.0.0',
  [int]$TcpPort = 7801,
  [switch]$Stdio,
  [switch]$Raw,

  # ---- serial port ----
  [string]$Port = 'COM3',
  [int]$Baud = 115200,
  [ValidateSet('None','Odd','Even','Mark','Space')][string]$Parity = 'None',
  [ValidateSet(5,6,7,8)][int]$DataBits = 8,
  [ValidateSet('One','OnePointFive','Two')][string]$StopBits = 'One',
  [ValidateSet('None','XOnXOff','RequestToSend','RequestToSendXOnXOff')][string]$Handshake = 'None',
  [switch]$Mock,
  [string]$Codec = 'auto',

  # ---- behaviour ----
  [string]$Auth = '',
  [int]$DefaultTimeoutMs = 30000,
  [int]$MaxBodyBytes = 33554432,
  [string]$LogFile = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:AGENT_VERSION = '1.0.0'
$script:Utf8   = New-Object System.Text.UTF8Encoding($false)
$script:Ascii  = [System.Text.Encoding]::ASCII
$script:Latin1 = [System.Text.Encoding]::GetEncoding(28591)   # 1 byte <-> 1 char, used for marker scanning
$script:Serial = $null
$script:Codecs = @(
  [pscustomobject]@{ Name='base64';         Enc='base64';         Dec='base64 -d' }
  [pscustomobject]@{ Name='busybox-base64'; Enc='busybox base64'; Dec='busybox base64 -d' }
  [pscustomobject]@{ Name='openssl-base64'; Enc='openssl base64'; Dec='openssl base64 -d' }
  [pscustomobject]@{ Name='hex';            Enc=$null;           Dec=$null }
)
$script:CodecSel = $null
$script:CodecProbed = $false
if ($Codec -and $Codec -ne 'auto' -and (@($script:Codecs | ForEach-Object { $_.Name }) -notcontains $Codec)) {
  Write-Log ('unknown -Codec ''' + $Codec + ''' ; using auto') 'WARN'
  $Codec = 'auto'
}

# ---------------------------------------------------------------------
# logging (always to stderr so it never pollutes the stdio protocol)
# ---------------------------------------------------------------------
function Write-Log {
  param([string]$Message, [string]$Level = 'INFO')
  $line = '[{0}] {1,-5} {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
  try { [Console]::Error.WriteLine($line) } catch { }
  if ($LogFile) {
    try { [System.IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine, $script:Utf8) } catch { }
  }
}

# ---------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------
function ConvertTo-Hex {
  param([byte[]]$Bytes)
  if ($null -eq $Bytes) { return '' }
  $sb = New-Object System.Text.StringBuilder
  foreach ($b in $Bytes) { [void]$sb.Append($b.ToString('x2')) }
  return $sb.ToString()
}
function Get-Md5Hex {
  param([byte[]]$Bytes)
  if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
  $md5 = [System.Security.Cryptography.MD5]::Create()
  try { return (ConvertTo-Hex $md5.ComputeHash($Bytes)) } finally { $md5.Dispose() }
}
function New-Token {
  return [guid]::NewGuid().ToString('N').Substring(0, 12)
}
function ConvertFrom-B64 {
  param([string]$Text)
  if ([string]::IsNullOrEmpty($Text) -or $Text -eq '-') { return [byte[]]@() }
  return [Convert]::FromBase64String($Text)
}
function ConvertTo-B64 {
  param([byte[]]$Bytes)
  if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '-' }
  return [Convert]::ToBase64String($Bytes)
}
# wrap a value in single quotes for a POSIX shell
function Quote-Sh {
  param([string]$Value)
  return "'" + ($Value -replace "'", "'\''") + "'"
}
# =====================================================================
# Device layer: real serial port, or the built-in mock device (-Mock)
# =====================================================================
function Open-Device {
  if ($Mock) {
    $script:MockFiles   = @{}
    $script:MockCwd     = '/'
    $script:MockPending = New-Object System.Text.StringBuilder
    $script:MockOut     = New-Object System.IO.MemoryStream
    $script:MockLastRc  = 0
    $script:MockHere    = $null
    Write-Log 'Using built-in mock device (-Mock); no serial port is opened.'
    return
  }
  $par = [System.IO.Ports.Parity]::$Parity
  $stop = [System.IO.Ports.StopBits]::$StopBits
  $sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, $par, $DataBits, $stop
  $sp.Handshake = [System.IO.Ports.Handshake]::$Handshake
  $sp.DtrEnable = $true
  $sp.RtsEnable = $true
  $sp.ReadTimeout = 500
  $sp.WriteTimeout = 60000
  $sp.Open()
  $script:Serial = $sp
  Write-Log ("Opened serial port {0} @ {1} {2}{3}{4}" -f $Port, $Baud, $DataBits, $Parity.Substring(0,1), $StopBits)
}

function Close-Device {
  if ($script:Serial) { try { $script:Serial.Close() } catch { }; $script:Serial = $null }
}

function Get-DeviceName {
  if ($Mock) { return 'MOCK' }
  return ('{0}@{1}' -f $Port, $Baud)
}

function Device-Write {
  param([byte[]]$Bytes, [switch]$NoFlow)
  if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return }
  if ($Mock) { Mock-Feed $Bytes; return }
  if ($NoFlow -or $Bytes.Length -le 1024) {
    $script:Serial.Write($Bytes, 0, $Bytes.Length)
    return
  }
  # Flow control for large payloads (file transfers): send a small chunk, then
  # wait until the device has ECHOED it back (proof it was consumed) before
  # sending the next chunk. Without this the device UART input buffer overflows
  # and silently drops bytes, corrupting the transfer.
  $chunk = 512
  $off = 0
  while ($off -lt $Bytes.Length) {
    # Drop any stale echo left over from the previous chunk, so the wait
    # below really measures THIS chunk's round trip (otherwise the backlog
    # satisfies the wait instantly and we end up bursting -> drops).
    $av0 = $script:Serial.BytesToRead
    if ($av0 -gt 0) { $b0 = New-Object byte[] $av0; [void]$script:Serial.Read($b0, 0, $av0) }
    $n = [Math]::Min($chunk, $Bytes.Length - $off)
    $script:Serial.Write($Bytes, $off, $n)
    $off += $n
    if ($off -ge $Bytes.Length) { break }
    # Wait for the device to echo this chunk back before sending the next one.
    # This is the flow control that keeps the device UART input buffer from
    # overflowing. We never "give up and flood": that silently loses bytes.
    $got = 0
    $deadline = [DateTime]::UtcNow.AddMilliseconds(10000)
    while ($got -lt $n -and [DateTime]::UtcNow -lt $deadline) {
      $av = $script:Serial.BytesToRead
      if ($av -gt 0) {
        $buf = New-Object byte[] ([Math]::Min($av, 8192))
        $got += $script:Serial.Read($buf, 0, $buf.Length)
      } else { Start-Sleep -Milliseconds 2 }
    }
    if ($got -lt $n) { Write-Log ('flow-control: echo short for chunk (' + $got + ' of ' + $n + ')') 'WARN' }
  }
}
function Device-BytesToRead {
  if ($Mock) { return [int]$script:MockOut.Length }
  return [int]$script:Serial.BytesToRead
}

function Device-Read {
  param([int]$Max = 4096)
  if ($Mock) { return ,(Mock-Drain $Max) }
  $avail = $script:Serial.BytesToRead
  if ($avail -le 0) { return ,([byte[]]@()) }
  $n = [Math]::Min($Max, $avail)
  $buf = New-Object byte[] $n
  $r = $script:Serial.Read($buf, 0, $n)
  if ($r -le 0) { return ,([byte[]]@()) }
  if ($r -eq $n) { return ,$buf }
  $out = New-Object byte[] $r
  [Array]::Copy($buf, $out, $r)
  return ,$out
}

# Toggle DTR (the usual way to reset a board that wires DTR to its reset pin).
function Device-Reset {
  param([int]$DelayMs = 200)
  if ($Mock) { Write-Log 'Mock device: reset ignored.'; return }
  try { $script:Serial.DtrEnable = $false } catch { }
  Start-Sleep -Milliseconds ([Math]::Max(50, $DelayMs))
  try { $script:Serial.DtrEnable = $true } catch { }
}

# ---------------------------------------------------------------------
# Run a (possibly multi-line) script on the device.
#
#   we send:  <script>
#             echo "__DEVCTL_<token>__ $?"
#   and read until we see "__DEVCTL_<token>__ <rc>" come back.
#
# The unique token guarantees we never stop on the echo of our own input,
# because the echoed probe line contains "$?" (no digits) while the real
# output line contains the exit status (digits).
# ---------------------------------------------------------------------
$script:AnsiRe = [regex]'\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])'
$script:PromptRe = [regex]'^(?:[A-Za-z0-9_.\-]+@[A-Za-z0-9_.\-]+:[^\s]*|[A-Za-z0-9_.\-]+@[A-Za-z0-9_.\-]+|bash-\d+\.\d+|sh-\d+\.\d+)?\s*[#$>]\s*$'

function Remove-TrailingPrompt {
  param([string]$Text)
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($l in ($Text -split "`n")) { $lines.Add($l) }
  while ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim() -eq '') { $lines.RemoveAt($lines.Count - 1) }
  if ($lines.Count -gt 0 -and $script:PromptRe.IsMatch($lines[$lines.Count - 1].Trim())) { $lines.RemoveAt($lines.Count - 1) }
  return ($lines.ToArray() -join "`n")
}
# Send Ctrl-C and drain, so a shell left inside a here-document or an
# unclosed quote by a corrupted command returns to a prompt.
function Recover-Device {
  if ($Mock) { return }
  try {
    Device-Write ([byte[]]@(3, 10))
    Start-Sleep -Milliseconds 200
    $av = $script:Serial.BytesToRead
    if ($av -gt 0) { $buf = New-Object byte[] $av; [void]$script:Serial.Read($buf, 0, $av) }
  } catch { }
}

function Invoke-OnDeviceOnce {
  param([string]$Text, [int]$TimeoutMs = $DefaultTimeoutMs)

  $tok   = New-Token
  $mark  = '__DEVCTL_' + $tok + '__'
  $probe = 'echo "' + $mark + ' $?"'

  $payload = ''
  if ($Text) {
    $payload = $Text
    if (-not $payload.EndsWith("`n")) { $payload += "`n" }
  }
  $payload += $probe + "`n"

  Device-Write ($script:Utf8.GetBytes($payload))

  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  $sb = New-Object System.Text.StringBuilder
  $rx = [regex]([regex]::Escape($mark) + '\s*(\d+)')

  while ([DateTime]::UtcNow -lt $deadline) {
    if ((Device-BytesToRead) -gt 0) {
      $chunk = Device-Read 4096
      if ($chunk.Length -gt 0) { [void]$sb.Append($script:Latin1.GetString($chunk)) }
      $s = $sb.ToString()
      $m = $rx.Match($s)
      if ($m.Success) {
        $rc = [int]$m.Groups[1].Value
        $pre = $s.Substring(0, $m.Index)
        $rawPre = $pre

        # Strip the terminal echo. A console echoes the bytes we typed, in the
        # same order they arrived, but interleaving of "echo" and "program
        # output" is timing dependent. So we do not rely on ordering: we cut
        # everything up to and including the first echoed command line (this
        # also drops any stale shell prompt), then remove the remaining echoed
        # command lines and the echoed probe line by exact match.
        $cmdLines = @()
        if ($Text) {
          foreach ($ln in ($Text -split "`n")) {
            $c = $ln.TrimEnd("`r")
            if ($c.Length -ge 2) { $cmdLines += $c }
          }
        }
        # The UART can drop bytes in the send direction as well, which would
        # turn "uname -a" into "uname" and run a different command than asked.
        # The terminal echo is a free integrity check: when echo is on, every
        # line we sent must appear, in order, before the marker.
        $echoOk = $true
        if ($cmdLines.Count -gt 0 -and $rawPre.IndexOf($probe) -ge 0) {
          $pos = 0
          foreach ($ln in $cmdLines) {
            $k = $rawPre.IndexOf($ln, $pos)
            if ($k -lt 0) { $echoOk = $false; break }
            $pos = $k + $ln.Length
          }
        }
        if ($cmdLines.Count -gt 0) {
          $j = $pre.IndexOf($cmdLines[0])
          if ($j -ge 0) { $pre = $pre.Substring($j + $cmdLines[0].Length) }
        }
        $j = $pre.IndexOf($probe)
        if ($j -ge 0) { $pre = $pre.Remove($j, $probe.Length) }
        for ($k = 1; $k -lt $cmdLines.Count; $k++) {
          $j = $pre.IndexOf($cmdLines[$k])
          if ($j -ge 0) { $pre = $pre.Remove($j, $cmdLines[$k].Length) }
        }
        $pre = $script:AnsiRe.Replace($pre, '')
        $pre = Remove-TrailingPrompt $pre
        $pre = $pre -replace '^[\r\n]+', ''
        while ($pre.EndsWith("`r") -or $pre.EndsWith("`n")) { $pre = $pre.Substring(0, $pre.Length - 1) }
        $text = $script:Utf8.GetString($script:Latin1.GetBytes($pre))
        return [pscustomobject]@{ Ok = $true; Rc = $rc; Out = $text; Raw = $s; EchoOk = $echoOk }
      }
    } else {
      Start-Sleep -Milliseconds 10
    }
  }
  # Say what the console was actually printing: a boot banner or a login prompt
  # explains a timeout far better than "device did not respond".
  $tail = $sb.ToString() -replace "`r", '' -replace "`n", ' | '
  if ($tail.Length -gt 220) { $tail = $tail.Substring($tail.Length - 220) }
  if ($tail.Trim().Length -gt 0) { Write-Log ('timeout waiting for the marker; console said: ' + $tail) 'WARN' }
  Recover-Device

  return [pscustomobject]@{ Ok = $false; Rc = -1; Out = $sb.ToString(); Raw = $sb.ToString() }
}
# =====================================================================
# Protocol framing
#
#   request   :  <OP> [key=value ...] len=<n>\n <n raw bytes>
#   response  :  OK  [key=value ...] len=<n>\n <n raw bytes>
#                ERR code=<c> msg=<m> len=<n>\n <n raw bytes>
#
# All header fields are ASCII. Bodies are raw bytes (length-prefixed), so any
# binary content is transported verbatim.
# =====================================================================
function Read-Line {
  param([System.IO.Stream]$Stream)
  $ms = New-Object System.IO.MemoryStream
  while ($true) {
    $b = $Stream.ReadByte()
    if ($b -lt 0) { if ($ms.Length -eq 0) { return $null } else { break } }
    if ($b -eq 10) { break }
    if ($b -eq 13) { continue }
    $ms.WriteByte([byte]$b)
  }
  return $script:Ascii.GetString($ms.ToArray())
}

function Read-Exact {
  param([System.IO.Stream]$Stream, [int]$Length)
  if ($Length -le 0) { return ,([byte[]]@()) }
  $buf = New-Object byte[] $Length
  $got = 0
  while ($got -lt $Length) {
    $n = $Stream.Read($buf, $got, $Length - $got)
    if ($n -le 0) { throw 'connection closed while reading body' }
    $got += $n
  }
  return ,$buf
}

function Send-Message {
  param([System.IO.Stream]$Stream, [string]$StatusLine, [byte[]]$Body)
  if ($null -eq $Body) { $Body = [byte[]]@() }
  $head = $StatusLine + ' len=' + $Body.Length + "`n"
  $hb = $script:Ascii.GetBytes($head)
  $Stream.Write($hb, 0, $hb.Length)
  if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
  $Stream.Flush()
}

function Wait-Any {
  param([string[]]$Markers, [int]$TimeoutMs)
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  $sb = New-Object System.Text.StringBuilder
  while ([DateTime]::UtcNow -lt $deadline) {
    if ((Device-BytesToRead) -gt 0) {
      $b = Device-Read 4096
      if ($b.Length -gt 0) { [void]$sb.Append($script:Latin1.GetString($b)) }
      $s = $sb.ToString()
      foreach ($m in $Markers) { if ($s.Contains($m)) { return $m } }
    } else { Start-Sleep -Milliseconds 2 }
  }
  $tail = $sb.ToString() -replace "`r", '' -replace "`n", ' | '
  if ($tail.Length -gt 220) { $tail = $tail.Substring($tail.Length - 220) }
  if ($tail.Trim().Length -gt 0) { Write-Log ('marker not seen; console said: ' + $tail) 'WARN' }
  return ''
}

# Verified block upload. Each block is decoded on the device to a temp file,
# the DEVICE compares its md5 against the value we computed, and only appends
# when they match - otherwise we retransmit the block. This makes the upload
# correct even though the UART link occasionally drops a character at 460800.
function Invoke-PushHex {
  param([string]$Q, [byte[]]$Data, [int]$TimeoutMs)
  $awk = '{n=length($0);for(i=1;i<=n;i+=2){h=substr($0,i,2);a=index("0123456789abcdef",substr(h,1,1))-1;b=index("0123456789abcdef",substr(h,2,1))-1;printf "%c",a*16+b}}'
  $tmp = "'/tmp/.devctl_blk'"
  Device-Write ($script:Utf8.GetBytes(': > ' + $Q + "`n")) -NoFlow
  $blk = 1024
  $off = 0
  $i = 0
  $to = 3000
  while ($off -lt $Data.Length) {
    $n = [Math]::Min($blk, $Data.Length - $off)
    $chunk = New-Object byte[] $n
    [Array]::Copy($Data, $off, $chunk, 0, $n)
    # After appending, the target must have grown by exactly the bytes sent so
    # far. A corrupted destination path makes cat succeed against some other
    # writable file, so without this check that block is lost while we still
    # see an ACK.
    $expectSize = $off + $n
    $want = Get-Md5Hex $chunk
    $hex = ConvertTo-Hex $chunk
    $lines = New-Object System.Collections.Generic.List[string]
    for ($k = 0; $k -lt $hex.Length; $k += 64) { $lines.Add($hex.Substring($k, [Math]::Min(64, $hex.Length - $k))) }
    $delim = '__DEVCTL_HEOF_' + $i + '__'
    $body = 'awk ' + (Quote-Sh $awk) + ' > ' + $tmp + ' << ' + (Quote-Sh $delim) + "`n" +
            ($lines -join "`n") + "`n" + $delim + "`n" +
            'if [ "$(md5sum ' + $tmp + ' | cut -d" " -f1)" = "' + $want + '" ] && cat ' + $tmp + ' >> ' + $Q + ' && [ "$(wc -c < ' + $Q + ' | tr -d " ")" = "' + $expectSize + '" ]; then echo __DEVCTL_A''''CK_' + $i + '__; else echo __DEVCTL_BA''''D_' + $i + '__; fi'

    $done = $false
    for ($try = 1; $try -le 8; $try++) {
      Device-Write ($script:Utf8.GetBytes($body + "`n")) -NoFlow
      $hit = Wait-Any @(('__DEVCTL_ACK_' + $i + '__'), ('__DEVCTL_BAD_' + $i + '__')) $to
      if ($hit -eq ('__DEVCTL_ACK_' + $i + '__')) { $done = $true; break }
      # A corrupted block can leave the shell inside a here-document or an
      # unclosed quote, which makes every later retry time out too. Reset the
      # line first, then send the block again.
      Write-Log ('block ' + $i + ' not acknowledged ($hit); recovering and retrying') 'WARN'
      Recover-Device
    }
    if (-not $done) { Write-Log ("hex push block $i failed after retries") 'WARN'; return $false }
    $off += $n
    $i++
  }
  return $true
}
function Invoke-PushWithCodec {
  param($Codec, [string]$Q, [byte[]]$Data, [int]$TimeoutMs)
  if ($Codec.Name -eq 'hex') { return (Invoke-PushHex -Q $Q -Data $Data -TimeoutMs $TimeoutMs) }
  $r = Invoke-OnDevice -Text (Build-PushScript $Codec $Q $Data) -TimeoutMs $TimeoutMs
  return ($r.Ok -and $r.Rc -eq 0)
}
function Get-PullCommand {
  param($Codec, [string]$Q)
  if ($Codec.Name -eq 'hex') { return ('od -v -b ' + $Q) }
  return ($Codec.Enc + ' ' + $Q)
}
function Convert-PullData {
  param($Codec, [string]$Text)
  if ($Codec.Name -eq 'hex') { return ,(ConvertFrom-OdOctal $Text) }
  return ,([Convert]::FromBase64String(($Text -replace '\s', '')))
}
function Wait-Marker {
  param([string]$Marker, [int]$TimeoutMs)
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  $sb = New-Object System.Text.StringBuilder
  while ([DateTime]::UtcNow -lt $deadline) {
    if ((Device-BytesToRead) -gt 0) {
      $b = Device-Read 4096
      if ($b.Length -gt 0) { [void]$sb.Append($script:Latin1.GetString($b)) }
      if ($sb.ToString().Contains($Marker)) { return $true }
    } else { Start-Sleep -Milliseconds 2 }
  }
  return $false
}

# Lock-step octal upload: send one block, wait until the device confirms it
# actually executed that block, then send the next. This keeps only ~2 KB in
# flight per block, which no tty input buffer can drop.
function Invoke-PushOctal {
  param([string]$Q, [byte[]]$Data, [int]$TimeoutMs)
  Device-Write ($script:Utf8.GetBytes(': > ' + $Q + "`n")) -NoFlow
  $blk = 512
  $off = 0
  $i = 0
  while ($off -lt $Data.Length) {
    $n = [Math]::Min($blk, $Data.Length - $off)
    $chunk = New-Object byte[] $n
    [Array]::Copy($Data, $off, $chunk, 0, $n)
    $off += $n
    $cmd = "printf '" + (ConvertTo-OctalEscape $chunk) + "' >> " + $Q + '; echo __DEVCTL_A"CK_' + $i + '__'
    Device-Write ($script:Utf8.GetBytes($cmd + "`n"))
    if (-not (Wait-Marker ('__DEVCTL_ACK_' + $i + '__') 8000)) { Write-Log ("push block $i ack timeout") 'WARN'; return $false }
    $i++
  }
  return $true
}
function Ensure-Codec {
  if ($script:CodecSel) { return $script:CodecSel }
  if ($Codec -and $Codec -ne 'auto') {
    foreach ($c in $script:Codecs) { if ($c.Name -eq $Codec) { $script:CodecSel = $c; Write-Log ('codec (forced): ' + $c.Name); return $c } }
    Write-Log ('unknown forced codec: ' + $Codec) 'WARN'
    return $null
  }
  if ($script:CodecProbed) { return $null }
  $script:CodecProbed = $true
  $probe = "'/tmp/.devctl_probe'"
  $hello = [byte[]](0x68, 0x65, 0x6c, 0x6c, 0x6f)
  foreach ($codec in $script:Codecs) {
    try {
      $pushOk = Invoke-PushWithCodec -Codec $codec -Q $probe -Data $hello -TimeoutMs 8000
      if (-not $pushOk) { continue }
      $r = Invoke-OnDevice -Text (Get-PullCommand -Codec $codec -Q $probe) -TimeoutMs 8000
      if (-not ($r.Ok -and $r.Rc -eq 0)) { continue }
      [byte[]]$data = $null
      try { $data = Convert-PullData -Codec $codec -Text $r.Out } catch { continue }
      if ($data.Length -eq 5 -and $data[0] -eq 0x68) {
        $script:CodecSel = $codec
        [void](Invoke-OnDevice -Text ('rm -f ' + $probe) -TimeoutMs 4000)
        Write-Log ('codec detected: ' + $codec.Name)
        return $script:CodecSel
      }
    } catch { }
  }
  Write-Log 'codec detection failed - is the device shell at a prompt?' 'WARN'
  return $null
}
function Get-CodecCandidates {
  if ($script:CodecSel) { return @($script:CodecSel) }
  return $script:Codecs
}
function ConvertTo-OctalEscape {
  param([byte[]]$Bytes)
  $sb = New-Object System.Text.StringBuilder
  foreach ($b in $Bytes) { [void]$sb.Append('\' + [Convert]::ToString([int]$b, 8).PadLeft(3, '0')) }
  return $sb.ToString()
}
function Build-PushScript {
  param($Codec, [string]$Q, [byte[]]$Data)
  if ($Codec.Name -eq 'octal') {
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add(': > ' + $Q)
    for ($i = 0; $i -lt $Data.Length; $i += 128) {
      $n = [Math]::Min(128, $Data.Length - $i)
      $chunk = New-Object byte[] $n
      [Array]::Copy($Data, $i, $chunk, 0, $n)
      $parts.Add("printf '" + (ConvertTo-OctalEscape $chunk) + "' >> " + $Q)
    }
    $parts.Add('true')
    return ($parts -join "`n")
  }
  $b64 = [Convert]::ToBase64String($Data)
  $lines = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $b64.Length; $i += 64) { $lines.Add($b64.Substring($i, [Math]::Min(64, $b64.Length - $i))) }
  if ($lines.Count -eq 0) { $lines.Add('') }
  $delim = '__DEVCTL_PUSH_' + (New-Token) + '__'
  return ($Codec.Dec + ' > ' + $Q + ' << ' + (Quote-Sh $delim) + "`n" + ($lines -join "`n") + "`n" + $delim)
}
function ConvertFrom-OdOctal {
  param([string]$Text)
  $out = New-Object System.Collections.Generic.List[byte]
  foreach ($line in ($Text -split "`n")) {
    $toks = $line.Trim() -split '\s+'
    for ($i = 1; $i -lt $toks.Count; $i++) {
      $tk = $toks[$i]
      if ($tk.Length -ge 1 -and $tk.Length -le 3 -and $tk -match '^[0-7]+$') { $out.Add([byte]([Convert]::ToInt32($tk, 8))) }
    }
  }
  return ,$out.ToArray()
}
# Resend when the echo shows the device did not receive the text we sent.
# Running the corrupted command would be worse than retrying it: "uname -a"
# silently became "uname" during one observed transfer.
function Invoke-OnDevice {
  param([string]$Text, [int]$TimeoutMs = $DefaultTimeoutMs)
  $last = $null
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    $last = Invoke-OnDeviceOnce -Text $Text -TimeoutMs $TimeoutMs
    if (-not $last.Ok) { return $last }
    if ($null -ne $last.PSObject.Properties['EchoOk'] -and -not $last.EchoOk) {
      Write-Log ('device echo mismatch on attempt ' + $attempt + '; resending') 'WARN'
      Start-Sleep -Milliseconds 150
      continue
    }
    return $last
  }
  return $last
}
function Invoke-Request {
  param(
    [System.IO.Stream]$Out,
    [string]$Op,
    [hashtable]$Kv,
    [byte[]]$Body
  )

  switch ($Op) {
    'PING' {
      Send-Message $Out 'OK' ($script:Utf8.GetBytes('pong'))
      return $true
    }
    'INFO' {
      $info = @(
        'agent='  + $script:AGENT_VERSION
        'device=' + (Get-DeviceName)
        'mock='   + $Mock.IsPresent
        'host='   + [Environment]::MachineName
        'os='     + [Environment]::OSVersion.VersionString
        'time='   + (Get-Date).ToString('s')
      ) -join "`n"
      Send-Message $Out 'OK' ($script:Utf8.GetBytes($info))
      return $true
    }
    'RESET' {
      $d = 200
      if ($Kv.ContainsKey('delay')) { $d = [int]$Kv['delay'] }
      Device-Reset -DelayMs $d
      Send-Message $Out 'OK' ($script:Utf8.GetBytes('reset'))
      return $true
    }
    'EXEC' {
      $timeout = $DefaultTimeoutMs
      if ($Kv.ContainsKey('timeout')) { $timeout = [int]$Kv['timeout'] }
      $cmd = $script:Utf8.GetString($Body)
      $r = Invoke-OnDevice -Text $cmd -TimeoutMs $timeout
      if (-not $r.Ok) {
        Send-Message $Out 'ERR code=timeout msg=device-did-not-respond' ($script:Utf8.GetBytes($r.Out))
      } else {
        Send-Message $Out ('OK rc=' + $r.Rc) ($script:Utf8.GetBytes($r.Out))
      }
      return $true
    }
    'PUSH' {
      # body = base64(remote path) \n <raw file bytes>
      $nl = -1
      for ($i = 0; $i -lt $Body.Length; $i++) { if ($Body[$i] -eq 10) { $nl = $i; break } }
      if ($nl -lt 0) { Send-Message $Out 'ERR code=badrequest msg=missing-path' ([byte[]]@()); return $true }
      $remote = $script:Utf8.GetString((ConvertFrom-B64 ($script:Ascii.GetString($Body, 0, $nl))))
      $data = New-Object byte[] ($Body.Length - $nl - 1)
      if ($data.Length -gt 0) { [Array]::Copy($Body, $nl + 1, $data, 0, $data.Length) }
      $timeout = $DefaultTimeoutMs
      if ($Kv.ContainsKey('timeout')) { $timeout = [int]$Kv['timeout'] }
      $q = Quote-Sh $remote
      $codec = Ensure-Codec
      if (-not $codec) { Send-Message $Out 'ERR code=device msg=codec-unknown' ($script:Utf8.GetBytes('no usable transfer codec; is the device shell at a prompt?')); return $true }
      if (-not (Invoke-PushWithCodec -Codec $codec -Q $q -Data $data -TimeoutMs $timeout)) {
        Send-Message $Out 'ERR code=device msg=push-failed' ($script:Utf8.GetBytes('upload failed (lock-step ack timeout)')); return $true
      }
      $want = Get-Md5Hex $data
      $got = ''
      $r2 = Invoke-OnDevice -Text ('md5sum ' + $q + ' 2>/dev/null') -TimeoutMs 8000
      if ($r2.Ok -and $r2.Rc -eq 0) { $got = (($r2.Out -split "`n")[0] -split '\s+')[0] }
      Send-Message $Out ('OK rc=0 written=' + $data.Length + ' md5=' + $want + ' verified=' + ($got -eq $want)) ($script:Utf8.GetBytes($r2.Out))
      return $true
    }
    'PULL' {
      $remote = $script:Utf8.GetString((ConvertFrom-B64 ($script:Utf8.GetString($Body))))
      $timeout = $DefaultTimeoutMs
      if ($Kv.ContainsKey('timeout')) { $timeout = [int]$Kv['timeout'] }
      $q = Quote-Sh $remote
      $codec = Ensure-Codec
      if (-not $codec) { Send-Message $Out 'ERR code=device msg=codec-unknown' ($script:Utf8.GetBytes('no usable transfer codec; is the device shell at a prompt?')); return $true }
      $r = Invoke-OnDevice -Text (Get-PullCommand -Codec $codec -Q $q) -TimeoutMs $timeout
      if (-not $r.Ok) { Send-Message $Out 'ERR code=timeout msg=pull-timeout' ($script:Utf8.GetBytes($r.Out)); return $true }
      if ($r.Rc -ne 0) { Send-Message $Out 'ERR code=device msg=read-failed' ($script:Utf8.GetBytes($r.Out)); return $true }
      [byte[]]$data = $null
      try { $data = Convert-PullData -Codec $codec -Text $r.Out } catch { Send-Message $Out 'ERR code=decode msg=decode-failed' ([byte[]]@()); return $true }
      Send-Message $Out ('OK rc=0 md5=' + (Get-Md5Hex $data)) $data
      return $true
    }
    'MD5' {
      $remote = $script:Utf8.GetString((ConvertFrom-B64 ($script:Utf8.GetString($Body))))
      $r = Invoke-OnDevice -Text ('md5sum ' + (Quote-Sh $remote) + ' 2>/dev/null') -TimeoutMs 8000
      if (-not $r.Ok) { Send-Message $Out 'ERR code=timeout msg=md5-timeout' ($script:Utf8.GetBytes($r.Out)); return $true }
      $hex = (($r.Out -split "`n")[0] -split '\s+')[0]
      Send-Message $Out 'OK' ($script:Utf8.GetBytes($hex))
      return $true
    }
    'BYE' {
      Send-Message $Out 'OK' ([byte[]]@())
      return $false
    }
    default {
      Send-Message $Out 'ERR code=unknown-op msg=unsupported' ($script:Utf8.GetBytes($Op))
      return $true
    }
  }
}

function Serve-Stream {
  param([System.IO.Stream]$In, [System.IO.Stream]$Out, [string]$Peer, [ref]$Authorized)
  Write-Log ("Session start: {0}" -f $Peer)
  try {
    while ($true) {
      $header = Read-Line $In
      if ($null -eq $header) { break }
      if ($header.Trim().Length -eq 0) { continue }
      $tokens = $header.Split(' ')
      $op = $tokens[0].ToUpperInvariant()
      $kv = @{}
      for ($i = 1; $i -lt $tokens.Count; $i++) {
        if ($tokens[$i] -match '^(\w+)=(.*)$') { $kv[$Matches[1]] = $Matches[2] }
      }
      $len = 0
      if ($kv.ContainsKey('len')) { $len = [int]$kv['len'] }
      if ($len -gt $MaxBodyBytes) { Send-Message $Out 'ERR code=too-large msg=body-too-large' ([byte[]]@()); continue }
      $body = Read-Exact -Stream $In -Length $len

      if (-not $Authorized.Value) {
        if ($op -eq 'AUTH') {
          $token = $script:Utf8.GetString($body)
          if ($token -eq $Auth) { $Authorized.Value = $true; Send-Message $Out 'OK' ($script:Utf8.GetBytes('authorized')) }
          else { Send-Message $Out 'ERR code=auth msg=token-mismatch' ([byte[]]@()) }
          continue
        } else {
          Send-Message $Out 'ERR code=auth msg=not-authorized' ([byte[]]@())
          continue
        }
      }

      if ($op -eq 'SHELL') {
        if ($In -is [System.Net.Sockets.NetworkStream]) {
          Send-Message $Out 'OK' ([byte[]]@())
          Raw-Pipe -In $In -Out $Out
        } else {
          Send-Message $Out 'ERR code=unsupported msg=shell-requires-tcp' ([byte[]]@())
        }
        break
      }
      $keep = Invoke-Request -Out $Out -Op $op -Kv $kv -Body $body
      if (-not $keep) { break }
    }
  } catch {
    Write-Log ("Session error: {0} :: {1}" -f $_.Exception.Message, $_.ScriptStackTrace) 'WARN'
  } finally {
    Write-Log ("Session end: {0}" -f $Peer)
  }
}
# =====================================================================
# Built-in mock device (self test only -- no real hardware involved).
# It emulates just enough of a busybox shell for EXEC/PUSH/PULL to work:
# terminal echo, "echo", here-document base64 decode, base64, md5sum, ...
# =====================================================================
function Mock-Emit {
  param([string]$Text)
  $b = $script:Utf8.GetBytes($Text)
  $script:MockOut.Write($b, 0, $b.Length)
}
function Mock-Drain {
  param([int]$Max)
  $all = $script:MockOut.ToArray()
  $script:MockOut.SetLength(0)
  if ($all.Length -le $Max) { return $all }
  $rest = New-Object byte[] ($all.Length - $Max)
  [Array]::Copy($all, $Max, $rest, 0, $rest.Length)
  $script:MockOut.Write($rest, 0, $rest.Length)
  $out = New-Object byte[] $Max
  [Array]::Copy($all, $out, $Max)
  return $out
}
function Mock-Feed {
  param([byte[]]$Bytes)
  $text = $script:Latin1.GetString($Bytes)
  $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")   # emulate a tty's ICRNL
  [void]$script:MockPending.Append($text)
  while ($true) {
    $s = $script:MockPending.ToString()
    $i = $s.IndexOf("`n")
    if ($i -lt 0) { break }
    $line = $s.Substring(0, $i)
    [void]$script:MockPending.Remove(0, $i + 1)
    Mock-HandleLine ($line.TrimEnd("`r"))
  }
}
function Mock-HandleLine {
  param([string]$Line)
  Mock-Emit ($Line + "`r`n")     # terminal echo
  if ($script:MockHere) {
    if ($Line -eq $script:MockHere.Delim) {
      Mock-RunHeredoc $script:MockHere.Cmd $script:MockHere.Body.ToString()
      $script:MockHere = $null
    } else {
      [void]$script:MockHere.Body.Append($Line + "`n")
    }
    return
  }
  if ($Line -match "<<\s*'([^']+)'") {
    $script:MockHere = @{ Delim = $Matches[1]; Cmd = $Line; Body = New-Object System.Text.StringBuilder }
    return
  }
  Mock-Exec $Line
}
function Mock-Path {
  param([string]$P)
  $P = $P.Trim("'").Trim('"')
  if ($P.StartsWith('./')) { $P = $script:MockCwd.TrimEnd('/') + $P.Substring(1) }
  elseif (-not $P.StartsWith('/')) { $P = $script:MockCwd.TrimEnd('/') + '/' + $P }
  return $P
}
function Mock-RunHeredoc {
  param([string]$Cmd, [string]$BodyText)
  if ($Cmd -match 'awk\s+.*?>\s*(\S+)\s*<<') {
    $path = Mock-Path $Matches[1]
    $hx = $BodyText -replace '\s', ''
    try {
      $bytes = New-Object byte[] ([int]($hx.Length / 2))
      for ($i = 0; $i -lt $hx.Length; $i += 2) { $bytes[$i / 2] = [Convert]::ToByte($hx.Substring($i, 2), 16) }
      $script:MockFiles[$path] = $bytes
      $script:MockLastRc = 0
    } catch { Mock-Emit "awk: bad input`r`n"; $script:MockLastRc = 1 }
    return
  }  if ($Cmd -match 'base64\s+-d\s*>\s*(\S+)\s*<<') {
    $path  = Mock-Path $Matches[1]
    $clean = $BodyText -replace '\s', ''
    try {
      $script:MockFiles[$path] = [Convert]::FromBase64String($clean)
      $script:MockLastRc = 0
    } catch {
      Mock-Emit "base64: invalid input`r`n"
      $script:MockLastRc = 1
    }
    return
  }
  Mock-Emit "sh: syntax error`r`n"
  $script:MockLastRc = 2
}
function Mock-Exec {
  param([string]$Line)
  $t = $Line.Trim()
  if ($t.Length -eq 0) { $script:MockLastRc = 0; return }
  if ($t.StartsWith('#')) { return }

  if ($t -match '^echo\s+(.*)$') {
    $a = $Matches[1].Trim().Trim('"').Trim("'")
    $a = $a -replace '\$\?', ([string]$script:MockLastRc)
    Mock-Emit ($a + "`r`n"); $script:MockLastRc = 0; return
  }
  if ($t -match "^printf\s+'%s'\s+'(.*)'$") { Mock-Emit $Matches[1]; $script:MockLastRc = 0; return }
  if ($t -match '^:\s*>\s*(\S+)$') { $script:MockFiles[(Mock-Path $Matches[1])] = [byte[]]@(); $script:MockLastRc = 0; return }
  if ($t -match '^rm\s+-f\s+(.+)$') {
    foreach ($f in ($Matches[1] -split '\s+')) { [void]$script:MockFiles.Remove((Mock-Path $f)) }
    $script:MockLastRc = 0; return
  }
  if ($t.StartsWith('if [') -and $t.Contains('md5sum')) {
    $mt = [regex]::Match($t, 'md5sum (\S+)'); $mw = [regex]::Match($t, '= "([0-9a-f]{32})"')
    $mc = [regex]::Match($t, 'cat (\S+) >> (\S+)')
    $ms = [regex]::Match($t, 'wc -c < (\S+)\)" = "(\d+)"')
    $mi = [regex]::Match($t, "__DEVCTL_A''CK_(\d+)__")
    $mb = [regex]::Match($t, "__DEVCTL_BA''D_(\d+)__")
    if ($mt.Success -and $mw.Success -and $mc.Success -and $mi.Success -and $mb.Success) {
      $tmp = Mock-Path $mt.Groups[1].Value; $want = $mw.Groups[1].Value
      $tgt = Mock-Path $mc.Groups[2].Value
      $ack = '__DEVCTL_ACK_' + $mi.Groups[1].Value + '__'
      $bad = '__DEVCTL_BAD_' + $mb.Groups[1].Value + '__'
      $cur = if ($script:MockFiles.ContainsKey($tmp)) { $script:MockFiles[$tmp] } else { [byte[]]@() }
      $ok = ((Get-Md5Hex $cur) -eq $want)
      if ($ok) {
        $prev = if ($script:MockFiles.ContainsKey($tgt)) { $script:MockFiles[$tgt] } else { [byte[]]@() }
        $script:MockFiles[$tgt] = $prev + $cur
        if ($ms.Success) { $ok = ($script:MockFiles[$tgt].Length -eq [int]$ms.Groups[2].Value) }
      }
      if ($ok) { Mock-Emit ($ack + "`r`n") } else { Mock-Emit ($bad + "`r`n") }
      $script:MockLastRc = 0; return
    }
  }
  if ($t -match '^od\s+-v\s+-b\s+(\S+)$') {
    $pth = Mock-Path $Matches[1]
    if ($script:MockFiles.ContainsKey($pth)) {
      $dat = $script:MockFiles[$pth]
      $out = New-Object System.Collections.Generic.List[string]
      for ($i = 0; $i -lt $dat.Length; $i += 16) {
        $n = [Math]::Min(16, $dat.Length - $i)
        $row = New-Object System.Collections.Generic.List[string]
        for ($k = 0; $k -lt $n; $k++) { $row.Add([Convert]::ToString([int]$dat[$i + $k], 8).PadLeft(3, '0')) }
        $out.Add(('{0:d7} ' -f $i) + ($row -join ' '))
      }
      $out.Add('{0:d7}' -f $dat.Length)
      Mock-Emit (($out -join "`r`n") + "`r`n")
      $script:MockLastRc = 0
    } else { Mock-Emit ('od: ' + $Matches[1] + ': No such file or directory' + "`r`n"); $script:MockLastRc = 1 }
    return
  }  if ($t -match '^md5sum\s+(\S+)') {
    $p = Mock-Path $Matches[1]
    if ($script:MockFiles.ContainsKey($p)) { Mock-Emit ((Get-Md5Hex $script:MockFiles[$p]) + '  ' + $Matches[1] + "`r`n"); $script:MockLastRc = 0 }
    else { Mock-Emit ('md5sum: ' + $Matches[1] + ': No such file or directory' + "`r`n"); $script:MockLastRc = 1 }
    return
  }
  if ($t -match '^base64\s+(\S+)') {
    $p = Mock-Path $Matches[1]
    if ($script:MockFiles.ContainsKey($p)) { Mock-Emit ([Convert]::ToBase64String($script:MockFiles[$p]) + "`r`n"); $script:MockLastRc = 0 }
    else { Mock-Emit ('base64: ' + $Matches[1] + ': No such file or directory' + "`r`n"); $script:MockLastRc = 1 }
    return
  }
  if ($t -match '^cat\s+(\S+)') {
    $p = Mock-Path $Matches[1]
    if ($script:MockFiles.ContainsKey($p)) { Mock-Emit ($script:Utf8.GetString($script:MockFiles[$p])); $script:MockLastRc = 0 }
    else { Mock-Emit ('cat: ' + $Matches[1] + ': No such file or directory' + "`r`n"); $script:MockLastRc = 1 }
    return
  }
  if ($t -match '^ls') {
    $keys = @($script:MockFiles.Keys | Sort-Object)
    if ($keys.Count -eq 0) { Mock-Emit "`r`n" } else { Mock-Emit (($keys -join "`r`n") + "`r`n") }
    $script:MockLastRc = 0; return
  }
  if ($t -match '^uname')  { Mock-Emit "Linux mock 5.10.0 #1 SMP PREEMPT armv7l GNU/Linux`r`n"; $script:MockLastRc = 0; return }
  if ($t -match '^date')   { Mock-Emit ((Get-Date).ToString('ddd MMM d HH:mm:ss yyyy') + "`r`n"); $script:MockLastRc = 0; return }
  if ($t -match '^pwd')    { Mock-Emit ($script:MockCwd + "`r`n"); $script:MockLastRc = 0; return }
  if ($t -match '^(whoami|id)') { Mock-Emit "root`r`n"; $script:MockLastRc = 0; return }
  if ($t -match '^cd\s+(\S+)')  { $script:MockCwd = (Mock-Path $Matches[1]); $script:MockLastRc = 0; return }

  $first = ($t -split '\s+')[0]
  Mock-Emit ('sh: ' + $first + ': not found' + "`r`n")
  $script:MockLastRc = 127
}
# ---------------------------------------------------------------------
# Raw passthrough used by the interactive SHELL op (TCP only): bytes from
# the client go straight to the UART and vice versa, with no framing.
# ---------------------------------------------------------------------
function Raw-Pipe {
  param([System.IO.Stream]$In, [System.IO.Stream]$Out)
  Write-Log 'Entering interactive raw shell passthrough.'
  $buf = New-Object byte[] 65536
  try { $In.ReadTimeout = 200 } catch { }
  while ($true) {
    $idle = $true
    if ((Device-BytesToRead) -gt 0) {
      $b = Device-Read 65536
      if ($b.Length -gt 0) { $Out.Write($b, 0, $b.Length); $Out.Flush(); $idle = $false }
    }
    $data = $null
    try {
      $n = $In.Read($buf, 0, $buf.Length)
      if ($n -le 0) { break }
      $data = New-Object byte[] $n
      [Array]::Copy($buf, $data, $n)
    } catch [System.TimeoutException] { $data = $null } catch [System.IO.IOException] { $data = $null }
    if ($null -ne $data) { Device-Write $data; Write-Log ('rawpipe after write dev=' + (Device-BytesToRead)); $idle = $false }
    if ($idle) { Start-Sleep -Milliseconds 5 }
  }
  Write-Log 'Interactive raw shell passthrough finished.'
}
function Show-Banner {
  $extra = ''
  if ($Auth) { $extra = ' auth=on' }
  Write-Log ("serial_agent {0}  device={1}{2}" -f $script:AGENT_VERSION, (Get-DeviceName), $extra)
  if ($Stdio) {
    Write-Log 'Transport: stdio (intended to be launched through SSH)'
  } else {
    Write-Log ("Transport: TCP, listening on {0}:{1}" -f $Listen, $TcpPort)
  }
}

Open-Device
Show-Banner

try {
  if ($Raw) {
    # Pure TCP <-> UART passthrough (ser2net style); handy with telnet/nc/PuTTY.
    $ip = [System.Net.IPAddress]::Any
    if ($Listen -ne '0.0.0.0') { $ip = [System.Net.IPAddress]::Parse($Listen) }
    $listener = New-Object System.Net.Sockets.TcpListener $ip, $TcpPort
    $listener.Start()
    Write-Log ("Raw mode: listening on {0}:{1}" -f $Listen, $TcpPort)
    while ($true) {
      $client = $listener.AcceptTcpClient()
      $client.NoDelay = $true
      try { Raw-Pipe -In $client.GetStream() -Out $client.GetStream() }
      finally { try { $client.Close() } catch { } }
    }
  } elseif ($Stdio) {
    $authorized = $false
    if (-not $Auth) { $authorized = $true }
    $authorizedRef = [ref]$authorized
    $inStream  = [Console]::OpenStandardInput()
    $outStream = [Console]::OpenStandardOutput()
    Serve-Stream -In $inStream -Out $outStream -Peer 'stdio' -Authorized $authorizedRef
  } else {
    $ip = [System.Net.IPAddress]::Any
    if ($Listen -ne '0.0.0.0') { $ip = [System.Net.IPAddress]::Parse($Listen) }
    $listener = New-Object System.Net.Sockets.TcpListener $ip, $TcpPort
    $listener.Start()
    Write-Log 'Waiting for a remote devctl connection... (Ctrl+C to stop)'
    while ($true) {
      $client = $listener.AcceptTcpClient()
      $client.NoDelay = $true
      $peer = $client.Client.RemoteEndPoint.ToString()
      $authorized = $false
      if (-not $Auth) { $authorized = $true }
      $authorizedRef = [ref]$authorized
      try {
        Serve-Stream -In $client.GetStream() -Out $client.GetStream() -Peer $peer -Authorized $authorizedRef
      } finally {
        try { $client.Close() } catch { }
      }
    }
  }
} finally {
  Close-Device
  Write-Log 'Exited.'
}
