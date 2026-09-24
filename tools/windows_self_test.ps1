<#
Runs a built Chess Auto Prep v2 with --self-test-bughouse and checks what it
reports: the bughouse engine installed into this user's AppData from the
app's own bundle, started, and answered a search.

  -Fresh   remove the engine folder an earlier run installed, first
  -Damage  overwrite 4 KiB in the middle of the installed network first, then
           require the app to have written it back to the bundled hash

Reports land in $env:RUNNER_TEMP (or the temp folder) as self-test-<Name>.json.
Used by .github/workflows/windows-check.yml; runs on any Windows 10/11 PC too.
#>
param(
  [Parameter(Mandatory)] [string] $Exe,
  [Parameter(Mandatory)] [string] $Name,
  [switch] $Fresh,
  [switch] $Damage,
  [int] $TimeoutSeconds = 600
)
$ErrorActionPreference = 'Stop'
$temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }

function Last-EngineFolder {
  $last = Get-ChildItem $temp -Filter 'self-test-*.json' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime | Select-Object -Last 1
  if (-not $last) { return $null }
  return (Get-Content $last.FullName -Raw | ConvertFrom-Json).engineFolder
}

$network = $null
if ($Fresh) {
  $folder = Last-EngineFolder
  if ($folder -and (Test-Path $folder)) {
    Write-Host "Removing $folder"
    Remove-Item -Recurse -Force $folder
  }
}
if ($Damage) {
  $folder = Last-EngineFolder
  if (-not $folder) { throw 'No earlier report says where the engine is' }
  $network = Join-Path $folder 'hivemind.onnx'
  $bytes = [IO.File]::ReadAllBytes($network)
  $middle = [int]($bytes.Length / 2)
  for ($i = 0; $i -lt 4096; $i++) { $bytes[$middle + $i] = 0x5A }
  [IO.File]::WriteAllBytes($network, $bytes)
  Write-Host "Damaged $network (same size, wrong bytes)"
}

$report = Join-Path $temp "self-test-$Name.json"
if (Test-Path $report) { Remove-Item $report }
$started = Get-Date
$proc = Start-Process -FilePath $Exe -ArgumentList "--self-test-bughouse=`"$report`"" -PassThru
if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
  Stop-Process -Id $proc.Id -Force
  throw "${Name}: no answer in $TimeoutSeconds s"
}
$seconds = [int]((Get-Date) - $started).TotalSeconds
if (-not (Test-Path $report)) { throw "${Name}: exited $($proc.ExitCode) without a report" }
$result = Get-Content $report -Raw | ConvertFrom-Json
Get-Content $report
if (-not $result.ok) { throw "${Name} failed after $seconds s: $($result.failure)" }
Write-Host "${Name} passed in $seconds s: best $($result.best)"

$names = $result.files.PSObject.Properties.Name | ForEach-Object { $_.ToLower() }
foreach ($need in @('hivemind-windows.exe', 'hivemind_ort.dll', 'hivemind.onnx', 'msvcp140.dll', 'vcruntime140.dll')) {
  if ($names -notcontains $need) { throw "${Name}: $need is not beside the engine" }
}
if ($names -contains 'onnxruntime.dll') { throw "${Name}: a generic onnxruntime.dll is beside the engine" }

if ($Damage) {
  $manifest = Join-Path (Split-Path $Exe) 'data\flutter_assets\assets\bughouse\manifest.json'
  $want = (Get-Content $manifest -Raw | ConvertFrom-Json).'hivemind.onnx'.sha256
  $have = (Get-FileHash $network -Algorithm SHA256).Hash.ToLower()
  if ($have -ne $want) { throw "${Name}: the damaged network was not written back ($have)" }
  Write-Host 'The damaged network was written back from the bundle'
}
