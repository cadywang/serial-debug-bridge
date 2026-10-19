#Requires -Version 5.1
<#
.SYNOPSIS
    End-to-end self test for serial_agent.ps1 + devctl.ps1 using the built-in
    mock device. No serial hardware is required.

.DESCRIPTION
    Starts the agent with -Mock on a loopback TCP port, then drives it through
    devctl.ps1 (as a child process, exactly like a real user would) and checks
    command execution, exit codes, file upload/download and the raw shell.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File selftest.ps1
#>
[CmdletBinding()]
param(
  [int]$Port = 0,
  [string]$Agent  = '',
  [string]$Devctl = '',
  [string]$Target = '',
  [ValidateSet('auto','base64','hex')][string]$Codec = 'auto'
)

$ErrorActionPreference = 'Stop'
# Work around a duplicated Path/PATH environment key (breaks Start-Process).
$pv = $env:Path; Remove-Item env:PATH -ErrorAction SilentlyContinue; $env:Path = $pv
$utf8 = New-Object System.Text.UTF8Encoding($false)
if (-not $Agent)  { $Agent  = Join-Path $PSScriptRoot '..\agent\serial_agent.ps1' }
if (-not $Devctl) { $Devctl = Join-Path $PSScriptRoot '..\cli\devctl.ps1' }
$Agent  = [System.IO.Path]::GetFullPath($Agent)
$Devctl = [System.IO.Path]::GetFullPath($Devctl)

$script:Pass = 0
$script:Fail = 0
$tmp = Join-Path (Split-Path -Parent $PSScriptRoot) '.tmp-selftest'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$skipStart = [bool]$Target

# The test agent binds 0.0.0.0, and on Windows a more specific 127.0.0.1
# listener wins over it -- VS Code forwards the ports it sees in the terminal,
# which is how the old fixed default (17801) ended up talking to a stranger and
# hanging inside devctl instead of failing. Ask the OS for a free port instead,
# and refuse to run against an explicit port that somebody already answers.
function Test-PortBusy {
  param([int]$P)
  try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $P); $c.Close(); return $true }
  catch { return $false }
}

if (-not $skipStart) {
  if ($Port -le 0) {
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $Port = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
    $probe.Stop()
  } elseif (Test-PortBusy -P $Port) {
    Write-Host ("selftest: 127.0.0.1:{0} already answers - refusing to guess who it is." -f $Port)
    Write-Host 'selftest: pass -Port <free port>, or stop whatever listens there.'
    exit 2
  }
}

$target = if ($Target) { $Target } else { "127.0.0.1:$Port" }

# Run devctl.ps1 the way a user would (out of process) and return its stdout.
function Invoke-Devctl {
  param([string[]]$Arguments, [switch]$Diag)
  $o = Join-Path $tmp 'devctl.out'
  $e = Join-Path $tmp 'devctl.err'
  Remove-Item $o, $e -ErrorAction SilentlyContinue
  $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Devctl,'-Tcp',$target)
  if (-not $Diag) { $a += '-Quiet' }
  if ($Arguments) { $a += $Arguments }
  $pr = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $a `
        -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
  $script:LastExit = $pr.ExitCode
  $text = if (Test-Path $o) { [System.IO.File]::ReadAllText($o) } else { '' }
  if ($Diag -and (Test-Path $e)) { $text += "`n" + [System.IO.File]::ReadAllText($e) }
  return $text
}
function Check {
  param([string]$Name, [bool]$Ok, [string]$Detail = '')
  if ($Ok) { $script:Pass++; Write-Host ("  [PASS] " + $Name) -ForegroundColor Green }
  else     { $script:Fail++; Write-Host ("  [FAIL] " + $Name + "   " + $Detail) -ForegroundColor Red }
}

Write-Host ("selftest: agent  = " + $Agent)
Write-Host ("selftest: devctl = " + $Devctl)
Write-Host ("selftest: target = " + $target)

$stdout = Join-Path $tmp 'agent.out'
$stderr = Join-Path $tmp 'agent.err'
$proc = $null
if (-not $skipStart) {
$agentArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $Agent, '-Mock','-TcpPort', [string]$Port)
if ($Codec -ne 'auto') { $agentArgs += @('-Codec', $Codec) }
$proc = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru `
  -ArgumentList $agentArgs -RedirectStandardOutput $stdout -RedirectStandardError $stderr
}

function Wait-Port {
  param([int]$P, [int]$Seconds = 20)
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $P); $c.Close(); return $true }
    catch { Start-Sleep -Milliseconds 150 }
  }
  return $false
}

try {
  $tport = [int]($target -split ':')[-1]
  if (-not (Wait-Port -P $tport)) { throw "agent did not start listening on $target (see $stderr)" }

  # 1) info
  $out = Invoke-Devctl @('info')
  Check 'info reports the mock device' ($out -match 'mock=True')

  # 2) exec
  $out = Invoke-Devctl @('exec','uname -a')
  Check 'exec captures command output' ($out -match 'Linux mock')

  # 3) exit code propagation
  $out = Invoke-Devctl @('exec','nonexistent-cmd-xyz')
  Check 'exec propagates the device exit code (127)' ($script:LastExit -eq 127) ("rc=" + $script:LastExit)

  # 4) binary push/pull round trip
  $bytes = New-Object byte[] 4096
  (New-Object System.Random 12345).NextBytes($bytes)
  $src = Join-Path $tmp 'payload.bin'
  [System.IO.File]::WriteAllBytes($src, $bytes)
  $out = Invoke-Devctl @('push', $src, '/tmp/payload.bin') -Diag
  Check 'push reports verified=True' ($out -match 'verified=True') $out

  $dst = Join-Path $tmp 'payload.out'
  $out = Invoke-Devctl @('pull', '/tmp/payload.bin', $dst)
  $same = $false
  if (Test-Path $dst) {
    $back = [System.IO.File]::ReadAllBytes($dst)
    $same = ($back.Length -eq $bytes.Length)
    if ($same) { for ($i = 0; $i -lt $back.Length; $i++) { if ($back[$i] -ne $bytes[$i]) { $same = $false; break } } }
  }
  Check 'pull is byte-identical to the original' $same

  # 5) md5
  $out = Invoke-Devctl @('md5','/tmp/payload.bin')
  $expect = [System.BitConverter]::ToString([System.Security.Cryptography.MD5]::Create().ComputeHash($bytes)).Replace('-','').ToLower()
  Check 'device md5 equals local md5' ($out.Trim() -eq $expect) ("got=" + $out.Trim() + " want=" + $expect)

  # 6) larger text file
  $text = ((1..500 | ForEach-Object { "line $_ : the quick brown fox jumps over the lazy dog" }) -join "`n")
  $t1 = Join-Path $tmp 'text.txt'; [System.IO.File]::WriteAllText($t1, $text, $utf8)
  $t2 = Join-Path $tmp 'text.out'
  Invoke-Devctl @('push', $t1, '/tmp/text.txt') | Out-Null
  Invoke-Devctl @('pull', '/tmp/text.txt', $t2) | Out-Null
  Check 'text file round trip' ((Test-Path $t2) -and ([System.IO.File]::ReadAllText($t2) -eq $text))

  # 7) reset
  $out = Invoke-Devctl @('reset')
  Check 'reset accepted' ($script:LastExit -eq 0)

  # 8) raw interactive shell (SHELL op)
  $client = New-Object System.Net.Sockets.TcpClient
  $client.NoDelay = $true
  $client.Connect('127.0.0.1', $tport)
  $st = $client.GetStream()
  $req = [System.Text.Encoding]::ASCII.GetBytes("SHELL len=0`n")
  $st.Write($req, 0, $req.Length); $st.Flush()
  Start-Sleep -Milliseconds 200
  $line = [System.Text.Encoding]::ASCII.GetBytes("uname -a`r")
  $st.Write($line, 0, $line.Length); $st.Flush()
  Start-Sleep -Milliseconds 300
  $buf = New-Object byte[] 8192
  $n = $st.Read($buf, 0, $buf.Length)
  $raw = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
  $client.Close()
  Check 'interactive shell returns device output' ($raw -match 'Linux mock') ("raw=[" + $raw.Trim() + "]")

  # 9) shutdown: the agent answers, exits and gives the port back. Skipped
  #    with -Target, because that agent belongs to whoever started it.
  if (-not $skipStart) {
    $out = Invoke-Devctl @('shutdown') -Diag
    Check 'shutdown is acknowledged' ($script:LastExit -eq 0) $out
    $gone = $false
    for ($i = 0; $i -lt 40; $i++) {
      if ($proc.HasExited) { $gone = $true; break }
      Start-Sleep -Milliseconds 250
    }
    Check 'the agent exits after shutdown' $gone
    $free = $false
    try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $tport); $c.Close() }
    catch { $free = $true }
    Check 'the TCP port is released with it' $free
  }
}
finally {
  try { if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force } } catch { }
  Write-Host ''
  Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail)
  if ($script:Fail -gt 0 -and (Test-Path $stderr)) {
    Write-Host '--- agent stderr (last 30) ---'
    Get-Content $stderr | Select-Object -Last 30
  }
}
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }