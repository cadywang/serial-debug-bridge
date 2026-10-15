#Requires -Version 5.1
<#
.SYNOPSIS
    devctl -- remote control for the serial agent (PowerShell edition).

.DESCRIPTION
    Talks to serial_agent.ps1 over TCP or over SSH(stdio) and lets you:
        devctl exec  <command>      run a shell command on the embedded device
        devctl push  <local> <remote>   upload a file to the device
        devctl pull  <remote> <local>   download a file from the device
        devctl md5   <remote>           show the device-side md5 of a file
        devctl reset                    reset the board via DTR
        devctl info                     show agent / device information
        devctl shell                    interactive console (TCP only)

.EXAMPLE
    # Agent is listening on the client at 172.21.5.10:7801
    .\devctl.ps1 -Tcp 172.21.5.10:7801 exec "uname -a"

.EXAMPLE
    # Launch the agent on the client through SSH (no listening port needed)
    .\devctl.ps1 -Ssh user@172.21.5.10 -RemoteAgent 'C:\tools\serial_agent.ps1' `
                 -ComPort COM3 -Baud 115200 exec "ls -l /"

.EXAMPLE
    .\devctl.ps1 -Tcp 172.21.5.10:7801 push .\firmware.bin /tmp/firmware.bin
    .\devctl.ps1 -Tcp 172.21.5.10:7801 pull /etc/config.txt .\config.txt
#>
[CmdletBinding(DefaultParameterSetName = 'Tcp')]
param(
  [Parameter(Position = 0, Mandatory = $true)]
  [string]$Command,

  [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
  [string[]]$Rest,

  # ---- transport (exactly one) ----
  [Parameter(ParameterSetName = 'Tcp', Mandatory = $true)]
  [string]$Tcp,

  [Parameter(ParameterSetName = 'Ssh', Mandatory = $true)]
  [string]$Ssh,

  [int]$SshPort = 0,
  [string]$KeyFile = '',
  [string]$RemoteAgent = 'C:\tools\serial_agent.ps1',
  [string]$RemotePwsh = 'powershell.exe',
  [string]$ComPort = 'COM3',
  [int]$Baud = 115200,

  # ---- behaviour ----
  [int]$Timeout = 30000,
  [string]$Token = '',
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$script:Utf8   = New-Object System.Text.UTF8Encoding($false)
$script:Ascii  = [System.Text.Encoding]::ASCII
$script:In     = $null
$script:Out    = $null
$script:Proc   = $null
$script:LastRc = 0

function Write-Info { param([string]$m) if (-not $Quiet) { [Console]::Error.WriteLine($m) } }

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

function Send-Request {
  param([string]$Op, [hashtable]$Kv, [byte[]]$Body)
  if ($null -eq $Body) { $Body = [byte[]]@() }
  $fields = @($Op)
  if ($Kv) { foreach ($k in $Kv.Keys) { $fields += ($k + '=' + $Kv[$k]) } }
  $fields += ('len=' + $Body.Length)
  $head = ($fields -join ' ') + "`n"
  $hb = $script:Ascii.GetBytes($head)
  $script:Out.Write($hb, 0, $hb.Length)
  if ($Body.Length -gt 0) { $script:Out.Write($Body, 0, $Body.Length) }
  $script:Out.Flush()
}

function Receive-Reply {
  $line = Read-Line $script:In
  if ($null -eq $line) { throw 'agent closed the connection' }
  $tokens = $line.Split(' ')
  $status = $tokens[0]
  $kv = @{}
  for ($i = 1; $i -lt $tokens.Count; $i++) {
    if ($tokens[$i] -match '^(\w+)=(.*)$') { $kv[$Matches[1]] = $Matches[2] }
  }
  $len = 0
  if ($kv.ContainsKey('len')) { $len = [int]$kv['len'] }
  $body = Read-Exact -Stream $script:In -Length $len
  return [pscustomobject]@{ Status = $status; Kv = $kv; Body = $body }
}

function Invoke-Agent {
  param([string]$Op, [hashtable]$Kv, [byte[]]$Body)
  Send-Request -Op $Op -Kv $Kv -Body $Body
  return (Receive-Reply)
}

function Connect-Agent {
  if ($PSCmdlet.ParameterSetName -eq 'Tcp') {
    $h = $Tcp; $port = 7801
    if ($Tcp -match '^(.*):(\d+)$') { $h = $Matches[1]; $port = [int]$Matches[2] }
    $client = New-Object System.Net.Sockets.TcpClient
    $client.NoDelay = $true
    $client.Connect($h, $port)
    $script:In  = $client.GetStream()
    $script:Out = $client.GetStream()
    Write-Info ("connected to tcp:{0}:{1}" -f $h, $port)
  }
  else {
    $sshArgs = @('-T', '-o', 'BatchMode=yes')
    if ($SshPort -gt 0) { $sshArgs += @('-p', [string]$SshPort) }
    if ($KeyFile) { $sshArgs += @('-i', $KeyFile) }
    $remote = '{0} -NoProfile -ExecutionPolicy Bypass -File ''{1}'' -Stdio -Port {2} -Baud {3}' -f $RemotePwsh, $RemoteAgent, $ComPort, $Baud
    $sshArgs += @($Ssh, $remote)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'ssh'
    $psi.Arguments = ($sshArgs | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $false
    $script:Proc = [System.Diagnostics.Process]::Start($psi)
    $script:Out = $script:Proc.StandardInput.BaseStream
    $script:In  = $script:Proc.StandardOutput.BaseStream
    Write-Info ("ssh {0} -> {1} -Stdio -Port {2}" -f $Ssh, $RemoteAgent, $ComPort)
  }
}

function Disconnect-Agent {
  try { if ($script:Proc -and -not $script:Proc.HasExited) { $script:Proc.Kill() } } catch { }
  try { if ($script:In) { $script:In.Dispose() } } catch { }
  try { if ($script:Out) { $script:Out.Dispose() } } catch { }
}

function Get-BodyText { param([byte[]]$Bytes) return $script:Utf8.GetString($Bytes) }
# =====================================================================
# Commands
# =====================================================================
function Cmd-Info {
  $r = Invoke-Agent 'INFO' $null ([byte[]]@())
  if ($r.Status -ne 'OK') { Write-Info ('ERR: ' + (Get-BodyText $r.Body)); return 1 }
  [Console]::Out.Write((Get-BodyText $r.Body) + "`n")
  return 0
}

function Cmd-Reset {
  $r = Invoke-Agent 'RESET' $null ([byte[]]@())
  if ($r.Status -ne 'OK') { Write-Info ('ERR: ' + (Get-BodyText $r.Body)); return 1 }
  Write-Info 'reset sent'
  return 0
}

function Cmd-Exec {
  param([string]$CmdText)
  $kv = @{ timeout = [string]$Timeout }
  $r = Invoke-Agent 'EXEC' $kv ($script:Utf8.GetBytes($CmdText))
  $out = Get-BodyText $r.Body
  if ($r.Status -ne 'OK') {
    if ($out) { [Console]::Out.Write($out) }
    if ($out -and -not $out.EndsWith("`n")) { [Console]::Out.Write("`n") }
    Write-Info ('ERR: ' + $r.Status)
    return 124
  }
  if ($out) { [Console]::Out.Write($out) }
  if ($out -and -not $out.EndsWith("`n")) { [Console]::Out.Write("`n") }
  $rc = 0
  if ($r.Kv.ContainsKey('rc')) { $rc = [int]$r.Kv['rc'] }
  return $rc
}

function Cmd-Push {
  param([string]$Local, [string]$Remote)
  if (-not (Test-Path -LiteralPath $Local -PathType Leaf)) { Write-Info ("local file not found: " + $Local); return 2 }
  $data = [System.IO.File]::ReadAllBytes($Local)
  $head = $script:Ascii.GetBytes([Convert]::ToBase64String($script:Utf8.GetBytes($Remote)))
  $body = New-Object byte[] ($head.Length + 1 + $data.Length)
  [Array]::Copy($head, 0, $body, 0, $head.Length)
  $body[$head.Length] = 10
  [Array]::Copy($data, 0, $body, $head.Length + 1, $data.Length)
  $r = Invoke-Agent 'PUSH' (@{ timeout = [string]$Timeout }) $body
  $msg = Get-BodyText $r.Body
  if ($r.Status -ne 'OK') { Write-Info ('ERR: ' + $msg); return 1 }
  $verified = ''
  if ($r.Kv.ContainsKey('verified')) { $verified = $r.Kv['verified'] }
  Write-Info ("pushed {0} -> {1} ({2} bytes, md5={3}, verified={4})" -f $Local, $Remote, $data.Length, $r.Kv['md5'], $verified)
  if ($verified -ne 'True') {
    if ($msg) { [Console]::Out.Write($msg + "`n") }
    Write-Info 'WARNING: device-side md5 does NOT match; transfer may be corrupt'
    return 1
  }
  return 0
}

function Cmd-Pull {
  param([string]$Remote, [string]$Local)
  $head = $script:Ascii.GetBytes([Convert]::ToBase64String($script:Utf8.GetBytes($Remote)))
  $r = Invoke-Agent 'PULL' (@{ timeout = [string]$Timeout }) $head
  if ($r.Status -ne 'OK') { Write-Info ('ERR: ' + (Get-BodyText $r.Body)); return 1 }
  $dir = Split-Path -Parent $Local
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [System.IO.File]::WriteAllBytes($Local, $r.Body)
  $md5 = [System.BitConverter]::ToString([System.Security.Cryptography.MD5]::Create().ComputeHash($r.Body)).Replace('-','').ToLower()
  Write-Info ("pulled {0} -> {1} ({2} bytes, md5={3})" -f $Remote, $Local, $r.Body.Length, $md5)
  if ($r.Kv.ContainsKey('md5') -and $r.Kv['md5'] -ne $md5) { Write-Info 'WARNING: md5 mismatch between device and saved file'; return 1 }
  return 0
}

function Cmd-Md5 {
  param([string]$Remote)
  $head = $script:Ascii.GetBytes([Convert]::ToBase64String($script:Utf8.GetBytes($Remote)))
  $r = Invoke-Agent 'MD5' $null $head
  if ($r.Status -ne 'OK') { Write-Info ('ERR: ' + (Get-BodyText $r.Body)); return 1 }
  [Console]::Out.Write((Get-BodyText $r.Body) + "`n")
  return 0
}

function Cmd-Shell {
  if ($PSCmdlet.ParameterSetName -ne 'Tcp') { Write-Info 'shell is only supported with -Tcp'; return 2 }
  $r = Invoke-Agent 'SHELL' $null ([byte[]]@())
  if ($r.Status -ne 'OK') { Write-Info ('ERR: ' + (Get-BodyText $r.Body)); return 1 }
  Write-Info 'entering interactive console (Ctrl+] to quit)'
  $stream = $script:In
  $cout = [Console]::OpenStandardOutput()
  $buf = New-Object byte[] 4096
  while ($true) {
    if ($stream.DataAvailable) {
      $n = $stream.Read($buf, 0, $buf.Length)
      if ($n -le 0) { break }
      $cout.Write($buf, 0, $n); $cout.Flush()
    }
    if ([Console]::KeyAvailable) {
      $k = [Console]::ReadKey($true)
      if ($k.Key -eq 'Oem6' -or ($k.Modifiers -eq 'Control' -and $k.Key -eq ']')) { break }
      $s = ''
      if ($k.Key -eq 'Enter') { $s = "`r" }
      elseif ($k.Key -eq 'Backspace') { $s = [string][char]127 }
      elseif ($k.Key -eq 'Tab') { $s = "`t" }
      elseif ($k.KeyChar -ne [char]0) { $s = [string]$k.KeyChar }
      if ($s) { $b = $script:Ascii.GetBytes($s); $stream.Write($b, 0, $b.Length); $stream.Flush() }
    }
    Start-Sleep -Milliseconds 15
  }
  return 0
}

# =====================================================================
# Main
# =====================================================================
try {
  Connect-Agent
  if ($Token) {
    $r = Invoke-Agent 'AUTH' $null ($script:Utf8.GetBytes($Token))
    if ($r.Status -ne 'OK') { Write-Info 'ERR: authentication failed'; exit 3 }
  }

  $rc = 0
  switch ($Command.ToLowerInvariant()) {
    'info'  { $rc = Cmd-Info }
    'reset' { $rc = Cmd-Reset }
    'md5'   { $rc = Cmd-Md5 -Remote $Rest[0] }
    'exec'  { $rc = Cmd-Exec -CmdText ($Rest -join ' ') }
    'push'  { $rc = Cmd-Push -Local $Rest[0] -Remote $Rest[1] }
    'pull'  { $rc = Cmd-Pull -Remote $Rest[0] -Local $Rest[1] }
    'shell' { $rc = Cmd-Shell }
    default { Write-Info ("unknown command: " + $Command); $rc = 2 }
  }
  exit $rc
} finally {
  Disconnect-Agent
}