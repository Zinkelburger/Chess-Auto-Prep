# Runs on Windows PowerShell 5.1 as well as PowerShell 7. No Pester dependency.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'diagnose_bughouse_windows.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$function = $ast.Find({ param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-EngineLine'
}, $true)
Invoke-Expression $function.Extent.Text

# A real pipe with delayed banner and readiness response. Multiple timeouts
# must retain the pending read, and EOF must stop further reads.
$payload = "Start-Sleep -Milliseconds 800; [Console]::WriteLine('uciok'); Start-Sleep -Milliseconds 800; [Console]::WriteLine('readyok')"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = (Get-Process -Id $PID).Path
$psi.Arguments = "-NoProfile -NonInteractive -EncodedCommand $encoded"
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$p = New-Object System.Diagnostics.Process
$p.StartInfo = $psi
try {
  [void]$p.Start()
  $state = @{ Reader = $p.StandardOutput; Pending = $null; Ended = $false }
  $lines = New-Object System.Collections.ArrayList
  $timeouts = 0
  $deadline = [DateTime]::UtcNow.AddSeconds(20)
  while (-not $state.Ended -and [DateTime]::UtcNow -lt $deadline) {
    $pending = $state.Pending
    $line = Read-EngineLine $state 50
    if ($null -ne $line) { [void]$lines.Add($line) }
    elseif (-not $state.Ended) {
      $timeouts++
      if ($null -ne $pending -and -not [Object]::ReferenceEquals($pending, $state.Pending)) {
        throw 'Timeout replaced the pending read'
      }
    }
  }
  if (($lines -join ',') -ne 'uciok,readyok') { throw "Lost or reordered lines: $lines" }
  if ($timeouts -lt 2) { throw 'Fixture did not exercise repeated timeouts' }
  if (-not $state.Ended) { throw 'EOF was not detected' }
  if ($null -ne (Read-EngineLine $state 1)) { throw 'Read returned data after EOF' }
} finally {
  if (-not $p.HasExited) { $p.Kill() }
  $p.Dispose()
}
Write-Host 'Windows diagnosis delayed-pipe tests passed'
