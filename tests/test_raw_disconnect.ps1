#Requires -Version 5.1
<#
.SYNOPSIS
    Regression test: losing a raw-mode client must not stop the agent.

.DESCRIPTION
    Starts serial_agent.ps1 with -Mock -Raw, keeps one connection idle across
    several read timeouts, then resets it while the mock device still has output
    pending. The agent must survive the failed socket write and accept the next
    client instead of exiting.
#>
[CmdletBinding()]
param(
  [int]$Port = 0,
  [string]$Agent = ''
)

$ErrorActionPreference = 'Stop'
# Work around a duplicated Path/PATH environment key (breaks Start-Process).
$pv = $env:Path; Remove-Item env:PATH -ErrorAction SilentlyContinue; $env:Path = $pv
if (-not $Agent) { $Agent = Join-Path $PSScriptRoot '..\agent\serial_agent.ps1' }
$Agent = [System.IO.Path]::GetFullPath($Agent)
$tmp = Join-Path (Split-Path -Parent $PSScriptRoot) '.tmp-agent'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$script:Pass = 0
$script:Fail = 0

function Check {
  param([string]$Name, [bool]$Ok, [string]$Detail = '')
  if ($Ok) { $script:Pass++; Write-Host ("  [PASS] " + $Name) -ForegroundColor Green }
  else     { $script:Fail++; Write-Host ("  [FAIL] " + $Name + "   " + $Detail) -ForegroundColor Red }
}

function Test-PortBusy {
  param([int]$P)
  try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $P); $c.Close(); return $true }
  catch { return $false }
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

function Read-Until {
  param([System.IO.Stream]$Stream, [string]$Needle, [int]$TimeoutMs = 5000)
  $sb = New-Object System.Text.StringBuilder
  $buf = New-Object byte[] 4096
  $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
  try { $Stream.ReadTimeout = 200 } catch { }
  while ((Get-Date) -lt $deadline) {
    try {
      $n = $Stream.Read($buf, 0, $buf.Length)
      if ($n -le 0) { break }
      [void]$sb.Append([System.Text.Encoding]::ASCII.GetString($buf, 0, $n))
      if ($sb.ToString().Contains($Needle)) { break }
    } catch [System.TimeoutException] {
    } catch [System.IO.IOException] {
    }
  }
  return $sb.ToString()
}

if ($Port -le 0) {
  $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
  $probe.Start()
  $Port = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
  $probe.Stop()
} elseif (Test-PortBusy -P $Port) {
  Write-Host ("raw-disconnect: 127.0.0.1:{0} already answers - refusing to guess who it is." -f $Port)
  exit 2
}

$stdout = Join-Path $tmp 'raw-agent.out'
$stderr = Join-Path $tmp 'raw-agent.err'
Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue
$proc = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru `
  -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Agent,
                  '-Mock','-Listen','127.0.0.1','-TcpPort',[string]$Port,'-Raw') `
  -RedirectStandardOutput $stdout -RedirectStandardError $stderr

try {
  if (-not (Wait-Port -P $Port)) { throw "raw agent did not start listening on 127.0.0.1:$Port (see $stderr)" }

  # An idle NetworkStream read times out repeatedly. That must be treated as
  # "no input yet", not as a dead peer.
  $a = New-Object System.Net.Sockets.TcpClient
  $a.NoDelay = $true
  $a.Connect('127.0.0.1', $Port)
  $sa = $a.GetStream()
  Start-Sleep -Milliseconds 900
  Check 'connection survives repeated read timeouts' (-not $proc.HasExited)

  $cmd = [System.Text.Encoding]::ASCII.GetBytes("uname -a`r")
  $sa.Write($cmd, 0, $cmd.Length); $sa.Flush()
  $out = Read-Until -Stream $sa -Needle 'Linux mock' -TimeoutMs 5000
  Check 'idle connection still serves commands' ($out -match 'Linux mock') ("raw=[" + $out.Trim() + "]")

  # Make the mock device emit a large response, then reset the TCP connection
  # immediately. The agent will try to forward that response to a dead socket.
  $big = 'echo ' + ('A' * 16384) + "`r"
  $bytes = [System.Text.Encoding]::ASCII.GetBytes($big)
  $sa.Write($bytes, 0, $bytes.Length); $sa.Flush()
  $a.LingerState = New-Object System.Net.Sockets.LingerOption($true, 0)
  $a.Close()
  Start-Sleep -Milliseconds 1500

  Check 'agent stays alive after the client resets' (-not $proc.HasExited)

  $b = New-Object System.Net.Sockets.TcpClient
  $b.NoDelay = $true
  $b.Connect('127.0.0.1', $Port)
  $sb = $b.GetStream()
  $cmd = [System.Text.Encoding]::ASCII.GetBytes("uname -a`r")
  $sb.Write($cmd, 0, $cmd.Length); $sb.Flush()
  $out = Read-Until -Stream $sb -Needle 'Linux mock' -TimeoutMs 5000
  Check 'agent accepts the next client' ($out -match 'Linux mock') ("raw=[" + $out.Trim() + "]")
  $b.Close()
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
