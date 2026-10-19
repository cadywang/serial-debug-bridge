#Requires -Version 5.1
<#
.SYNOPSIS
    Stop a serial agent on this Windows client and release the serial port it
    holds.

.DESCRIPTION
    A serial port is served by one program at a time, and an agent holds it for
    as long as it runs. Use "devctl ... shutdown" while the agent still answers
    (TCP or SSH): it exits by itself and reports its pid. Use this script for
    the other case -- the agent outlived its window or its listener while its
    process (and the port) survived, so nothing can reach it any more.

    Both agents are handled: serial_agent.ps1 running under powershell.exe or
    pwsh.exe, and serial_agent.py running under Python. They are recognised by
    the way they are launched (-File <script> / <script> as an argument), so an
    unrelated program that merely mentions the file name is left alone.

    Filters, both optional:

        -Port COM3      only the agent serving that serial port
        -TcpPort 7801   only the agent listening on that TCP port
        -List           print what was found, stop nothing

    Exit status: 0 when no matching agent is left, 1 when one survived.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File stop-agent.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File stop-agent.ps1 -Port COM3

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File stop-agent.ps1 -TcpPort 7801 -List
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
  [string]$Port = '',
  [int]$TcpPort = 0,
  [switch]$List
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Read "-Name value" / "--name value" (also the =value spelling) out of a
# command line: the PowerShell agent is started with -Port/-TcpPort and the
# Python agent with --port/--tcp-port. An ambiguous prefix such as -TcpP is
# deliberately not reconstructed -- report the value as unknown rather than
# guess at a port.
function Get-ArgValue {
  param([string]$CommandLine, [string]$Name)
  # 'tcp-port' also has to match the PowerShell spelling -TcpPort, so the
  # separator inside the option name is optional too.
  $pat = '(?i)(?:^|\s)--?' + ($Name -replace '-', '-?') + '(?:\s+|=)(?:"([^"]*)"|(\S+))'
  $m = [regex]::Match($CommandLine, $pat)
  if (-not $m.Success) { return '' }
  if ($m.Groups[1].Success) { return $m.Groups[1].Value }
  return $m.Groups[2].Value
}

function Get-AgentProcess {
  $scriptAgent = '-File\s+"?[^"]*serial_agent\.ps1'
  $pythonAgent = '(^|\s)(\S*[\\/])?serial_agent\.py(\s|$)'
  foreach ($p in (Get-CimInstance Win32_Process)) {
    if (-not $p.CommandLine) { continue }
    $isScript = $p.Name -match '^(powershell|pwsh)\.exe$'
    $isPython = $p.Name -match '^(python|python3|pythonw|py)\.exe$'
    if ($isScript) {
      if ($p.CommandLine -notmatch $scriptAgent) { continue }
    } elseif ($isPython) {
      if ($p.CommandLine -notmatch $pythonAgent) { continue }
    } else {
      continue
    }
    [pscustomobject]@{
      ProcessId   = [int]$p.ProcessId
      Kind        = $(if ($isScript) { 'ps1' } else { 'py' })
      SerialPort  = Get-ArgValue -CommandLine $p.CommandLine -Name 'port'
      TcpPort     = Get-ArgValue -CommandLine $p.CommandLine -Name 'tcp-port'
      Started     = $p.CreationDate
      CommandLine = $p.CommandLine
    }
  }
}

# -WhatIf is honoured by ShouldProcess below; keep it away from the CIM
# discovery, where the CimCmdlets module reports its own alias churn instead.
$whatIf = $WhatIfPreference
$WhatIfPreference = $false

$agents = @(Get-AgentProcess)
if ($Port) { $agents = @($agents | Where-Object { $_.SerialPort -ieq $Port }) }
if ($TcpPort -gt 0) { $agents = @($agents | Where-Object { $_.TcpPort -eq [string]$TcpPort }) }

$filterText = @()
if ($Port) { $filterText += ("port '" + $Port + "'") }
if ($TcpPort -gt 0) { $filterText += ('tcp-port ' + $TcpPort) }

if ($agents.Count -eq 0) {
  if ($filterText.Count -gt 0) {
    Write-Host ('stop-agent: no agent found for ' + ($filterText -join ', '))
  } else {
    Write-Host 'stop-agent: no serial agent process found.'
  }
  Write-Host 'stop-agent: another program can still hold the port (serial terminal,'
  Write-Host 'stop-agent: IDE monitor, another machine); see README section 12.'
  exit 0
}

foreach ($a in $agents) {
  $serial = $a.SerialPort
  if (-not $serial) { $serial = '-' }
  $tcp = $a.TcpPort
  if (-not $tcp) { $tcp = '-' }
  Write-Host ("  pid={0,-6} {1,-4} port={2,-12} tcp={3,-6} started={4}" -f `
    $a.ProcessId, $a.Kind, $serial, $tcp, $a.Started)
}
if ($List) { exit 0 }

$WhatIfPreference = $whatIf

$stopping = @()
$failed = 0
foreach ($a in $agents) {
  $what = 'pid ' + $a.ProcessId
  if ($a.SerialPort) { $what += (' (port ' + $a.SerialPort + ')') }
  if (-not $PSCmdlet.ShouldProcess($what, 'Stop-Process -Force')) { continue }
  $stopping += $a.ProcessId
  try {
    Stop-Process -Id $a.ProcessId -Force -ErrorAction Stop
    Write-Host ('stop-agent: stopped ' + $what)
  } catch {
    Write-Host ('stop-agent: could not stop ' + $what + ': ' + $_.Exception.Message)
    $failed++
  }
}

# Stop-Process returns before the process is really gone, and the port is only
# free once it is.
if ($stopping.Count -gt 0) {
  Start-Sleep -Milliseconds 500
  foreach ($procId in $stopping) {
    if (Get-Process -Id $procId -ErrorAction SilentlyContinue) {
      Write-Host ('stop-agent: still running: pid ' + $procId)
      $failed++
    }
  }
}

if ($failed -gt 0) { exit 1 }
exit 0