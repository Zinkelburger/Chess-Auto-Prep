<#
.SYNOPSIS
  Why the bughouse engine will not start on this Windows machine.

.DESCRIPTION
  The engine is a separate process that the app extracts into its support
  directory, so Windows resolves the engine's imports against the engine's own
  folder, then System32, then the Windows folder, then the working directory,
  then everything on PATH. Only the first of those is the app's. When some
  other entry answers first with a file that is not a 64-bit image -- a 32-bit
  MSVCP140.dll left on PATH by an unrelated toolchain is the usual one -- the
  loader stops the engine before it runs a single instruction, and the app can
  only report a process that started, said nothing and exited.

  This script walks the same search order the loader does, reads every
  candidate's real PE header, and then tries to start the engine for real.

  Nothing here writes, installs or downloads anything. It needs no checkout of
  the project: copy this one file to the machine and run it.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File diagnose_bughouse_windows.ps1

.EXAMPLE
  # If the engine lives somewhere this script did not think to look:
  powershell -ExecutionPolicy Bypass -File diagnose_bughouse_windows.ps1 -EngineDir "D:\some\path\bughouse"
#>

[CmdletBinding()]
param(
  [string]$EngineDir,
  [string]$AppDir,
  # Skip the live launch and only audit the files.
  [switch]$NoRun
)

$ErrorActionPreference = 'Continue'

# What the app should have extracted, and how big each one is when it is whole.
# From assets/bughouse/manifest.json as shipped in v1.15.3.
$Expected = @{
  'hivemind-windows.exe' = 5161647
  'onnxruntime.dll'      = 16149344
  'hivemind.onnx'        = 54415625
}

# The same files by content, plus the Visual C++ runtime the app copies in from
# its own folder. Size is not enough and this is the machine that proves it: a
# file that is the right length but the wrong bytes is exactly what the Windows
# loader rejects with STATUS_INVALID_IMAGE_FORMAT, and it is invisible to every
# other check here -- the PE header still parses, so the architecture still
# reads back as x64. It is also permanent, because BughouseBundle re-extracts
# only when the size differs, so no upgrade and no reinstall ever replaces it.
#
# Engine, runtime and network are the payload_sha256 values in
# tools/bughouse.lock.json; the eight redistributable DLLs are the ones the
# release workflow deployed into the v1.15.3 Windows bundle. Both sets were
# verified against the published v1.15.3 artifact.
$ExpectedHash = @{
  'hivemind-windows.exe'     = '726cf9baad7d050b3d351e32d3ebd908eb249d9995b53263c62b5033ce759040'
  'onnxruntime.dll'          = '69d8e6d3879a3b4001cdc74c8ed9ccc7e7f799a5b847059738323404519ec471'
  'hivemind.onnx'            = '61f74ba7d9a79868b565d51ece450519a4dc6b38d697aabd117fc5b843281a2f'
  'concrt140.dll'            = '54716f0738af891f283d213b5c8d11b25896bb8ee3097d301eae718560cf974e'
  'msvcp140.dll'             = '7c26614e1d733892c2deac7e245ce115504b1d80592dd0a01b08e3e5a55f89ca'
  'msvcp140_1.dll'           = '206c931bf90fdad8816de3b5e2ef80b2bcaa9406c89ecc05fe6fddffe251e982'
  'msvcp140_2.dll'           = 'd50d7883f20d1dc6191768d3746f52dd9cac89c346ffaed5be1f110c2f34a838'
  'msvcp140_atomic_wait.dll' = '3d0cbfaa1bf3eecf5a3f4491d2960ee803cb994f30292c6adc4a07c498f60e2b'
  'msvcp140_codecvt_ids.dll' = '8a65c7596ef2e6938731f5a1058e7e40145b6d97967cc649231a076b9a608d78'
  'vcruntime140.dll'         = 'd1f4225df2cd877dbf130d5668a021dce3f94118455ff5ec952061c30afc9ce7'
  'vcruntime140_1.dll'       = 'a7146c08f89fe5b04541ab507cdb59ff7b44534d4ba3c668a426c6450a03434e'
}

# Every library the engine and its ONNX Runtime import that Windows does not
# guarantee, so each one is found by search and each one can be shadowed.
# KERNEL32/ADVAPI32 are KnownDLLs and api-ms-win-* are API sets: neither can be
# shadowed, so neither is listed.
# The two-board starting position, as the engine spells it: two crazyhouse
# FENs separated by a pipe. Same string as tools/test_bughouse_engine.py.
$StartDualFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1|rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1'

$Dependencies = @(
  'onnxruntime.dll',
  'MSVCP140.dll', 'MSVCP140_1.dll', 'VCRUNTIME140.dll', 'VCRUNTIME140_1.dll',
  'SETUPAPI.dll', 'dbghelp.dll', 'dxgi.dll'
)

function Write-Head($text) {
  Write-Host ''
  Write-Host "== $text" -ForegroundColor Cyan
}

function Get-PeMachine([string]$path) {
  # Returns 'x64', 'x86', 'ARM64', 'not a PE' or an error string.
  try {
    $fs = [System.IO.File]::OpenRead($path)
  } catch {
    return "unreadable ($($_.Exception.Message))"
  }
  try {
    $head = New-Object byte[] 1024
    $read = $fs.Read($head, 0, 1024)
    if ($read -lt 64) { return 'too small to be a PE' }
    if ($head[0] -ne 0x4D -or $head[1] -ne 0x5A) { return 'not a PE' }
    $peAt = [BitConverter]::ToInt32($head, 0x3C)
    if ($peAt -lt 0 -or ($peAt + 6) -ge $read) { return 'PE header past the first 1 KB' }
    if ($head[$peAt] -ne 0x50 -or $head[$peAt + 1] -ne 0x45) { return 'not a PE' }
    $machine = [BitConverter]::ToUInt16($head, $peAt + 4)
    switch ($machine) {
      0x8664  { return 'x64' }
      0x014c  { return 'x86 (32-bit)' }
      0xAA64  { return 'ARM64' }
      0x01c4  { return 'ARM (32-bit)' }
      default { return ('machine 0x{0:x}' -f $machine) }
    }
  } finally {
    $fs.Close()
  }
}

function Read-EngineLine($reader, [int]$timeoutMs) {
  # A blocking ReadLine would hang on exactly the failure this script exists
  # for: a process that starts, prints nothing and never exits.
  $task = $reader.ReadLineAsync()
  if ($task.Wait($timeoutMs)) { return $task.Result }
  return $null
}

Write-Host 'Chess Auto Prep -- bughouse engine diagnosis' -ForegroundColor White
Write-Host ("OS            : " + (Get-CimInstance Win32_OperatingSystem).Caption)
Write-Host ("OS build      : " + [System.Environment]::OSVersion.Version.ToString())
Write-Host ("Process arch  : " + $env:PROCESSOR_ARCHITECTURE)
Write-Host ("PowerShell    : " + $PSVersionTable.PSVersion.ToString())

# ---------------------------------------------------------------- locate

if (-not $EngineDir) {
  $candidates = @(
    (Join-Path $env:APPDATA 'com.example\Chess Auto Prep\bughouse'),
    (Join-Path $env:LOCALAPPDATA 'com.example\Chess Auto Prep\bughouse')
  )
  foreach ($c in $candidates) {
    if (Test-Path (Join-Path $c 'hivemind-windows.exe')) { $EngineDir = $c; break }
  }
}
if (-not $EngineDir) {
  Write-Head 'Searching for the extracted engine'
  foreach ($root in @($env:APPDATA, $env:LOCALAPPDATA)) {
    if (-not $root) { continue }
    $hit = Get-ChildItem -Path $root -Filter 'hivemind-windows.exe' -Recurse -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($hit) { $EngineDir = $hit.DirectoryName; break }
  }
}

if (-not $EngineDir -or -not (Test-Path $EngineDir)) {
  Write-Host ''
  Write-Host 'The engine has never been extracted on this machine.' -ForegroundColor Yellow
  Write-Host 'Open Bughouse Lab in the app once (it extracts on first use), then run this again.'
  Write-Host 'If it still is not there, the app was built without the bughouse assets.'
  exit 2
}
Write-Host ("Engine folder : " + $EngineDir)

if (-not $AppDir) {
  $proc = Get-Process -Name 'chess_auto_prep' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($proc) {
    $AppDir = Split-Path $proc.Path -Parent
  } else {
    foreach ($c in @(
      (Join-Path $env:ProgramFiles 'Chess Auto Prep'),
      (Join-Path ${env:ProgramFiles(x86)} 'Chess Auto Prep'),
      (Join-Path $env:LOCALAPPDATA 'Programs\Chess Auto Prep')
    )) {
      if ($c -and (Test-Path (Join-Path $c 'chess_auto_prep.exe'))) { $AppDir = $c; break }
    }
  }
}
if ($AppDir) {
  Write-Host ("App folder    : " + $AppDir)
  # Which build this is. A report that does not name the version is a report
  # about an unknown program.
  $appExe = Join-Path $AppDir 'chess_auto_prep.exe'
  if (Test-Path $appExe) {
    $info = (Get-Item $appExe).VersionInfo
    Write-Host ("App version   : " + $info.ProductVersion + " (file " + $info.FileVersion + ")")
  }
} else {
  Write-Host 'App folder    : not found (pass -AppDir if you know it)' -ForegroundColor Yellow
}

# Safe DLL search mode has been the default since Windows XP SP2; with it off,
# the working directory is searched *second*, ahead of System32, which widens
# the set of places a wrong copy of a library can come from.
$safeMode = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'SafeDllSearchMode' -ErrorAction SilentlyContinue).SafeDllSearchMode
if ($null -eq $safeMode) {
  Write-Host 'DLL search    : safe mode (the default)'
} elseif ($safeMode -eq 0) {
  Write-Host 'DLL search    : SafeDllSearchMode is OFF -- the working directory is searched before System32' -ForegroundColor Yellow
} else {
  Write-Host 'DLL search    : safe mode'
}

# ------------------------------------------------------- extracted files

Write-Head 'What the app extracted'
$problems = New-Object System.Collections.ArrayList
Write-Host '  (a file written later than its neighbours was re-extracted, which is what an interrupted first write leaves behind)'
foreach ($f in (Get-ChildItem $EngineDir -File | Sort-Object Name)) {
  $line = "  {0,-26} {1,12:N0} bytes  {2}" -f $f.Name, $f.Length, $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
  if ($Expected.ContainsKey($f.Name)) {
    if ($f.Length -ne $Expected[$f.Name]) {
      $line += ("  WRONG SIZE -- should be {0:N0}" -f $Expected[$f.Name])
      [void]$problems.Add("$($f.Name) is the wrong size; the extraction did not finish")
    } else {
      $line += '  (size ok)'
    }
  }
  if ($f.Extension -in '.exe', '.dll') {
    $line += ('  [{0}]' -f (Get-PeMachine $f.FullName))
  }
  Write-Host $line
}
foreach ($name in $Expected.Keys) {
  if (-not (Test-Path (Join-Path $EngineDir $name))) {
    Write-Host ("  {0,-26} MISSING" -f $name) -ForegroundColor Red
    [void]$problems.Add("$name was never extracted")
  }
}

# ------------------------------------------------------------- the bytes

# The check the app cannot do for itself. Everything above this point can be
# perfect -- every file present, every size right, every PE header reading back
# as x64 -- while one of these files is still not the file we shipped, and that
# is the only remaining way the loader says STATUS_INVALID_IMAGE_FORMAT with
# nothing else out of place.
Write-Head 'Whether those files are the bytes we shipped'
$checked = 0
$unknown = New-Object System.Collections.ArrayList
foreach ($f in (Get-ChildItem $EngineDir -File | Sort-Object Name)) {
  $want = $ExpectedHash[$f.Name.ToLowerInvariant()]
  if (-not $want) { [void]$unknown.Add($f.Name); continue }
  $checked++
  try {
    $got = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  } catch {
    Write-Host ("  {0,-26} could not be read: {1}" -f $f.Name, $_.Exception.Message) -ForegroundColor Red
    [void]$problems.Add("$($f.Name) could not be read to hash it -- something is holding or blocking it")
    continue
  }
  if ($got -eq $want) {
    Write-Host ("  {0,-26} ok" -f $f.Name)
  } else {
    Write-Host ("  {0,-26} DIFFERENT BYTES" -f $f.Name) -ForegroundColor Red
    Write-Host ("  {0,-26}   on disk  {1}" -f '', $got)
    Write-Host ("  {0,-26}   shipped  {1}" -f '', $want)
    [void]$problems.Add("$($f.Name) is the right size but not the file we shipped -- it is corrupt on disk, and because the app only re-extracts on a size mismatch it will stay that way until the bughouse folder is deleted")
  }
}
if ($checked -eq 0) {
  Write-Host '  nothing here to compare against the shipped hashes' -ForegroundColor Yellow
}
if ($unknown.Count -gt 0) {
  Write-Host ('  not checked (no shipped hash for these): ' + ($unknown -join ', '))
}

# If the bytes are right, the next suspect is not the files at all but what
# this machine does to them on load. Windows' own Exploit Protection can be
# set per image, and a mitigation that an image cannot satisfy is refused by
# the loader before the process runs -- which looks identical from the app.
Write-Head 'Per-image protection settings for the engine'
try {
  $mit = Get-ProcessMitigation -Name 'hivemind-windows.exe' -ErrorAction Stop
  $on = New-Object System.Collections.ArrayList
  # Walked rather than named, because which mitigation groups the cmdlet
  # returns depends on the Windows build, and a group missing from a hand-typed
  # list is a mitigation this script would not have reported.
  foreach ($group in $mit.PSObject.Properties) {
    if ($group.Name -in 'ProcessName', 'Source') { continue }
    $value = $group.Value
    if ($null -eq $value -or $value -is [string]) { continue }
    foreach ($prop in $value.PSObject.Properties) {
      if ("$($prop.Value)" -eq 'ON') { [void]$on.Add("$($group.Name).$($prop.Name)") }
    }
  }
  if ($on.Count -eq 0) {
    Write-Host '  none set for this image beyond the system defaults'
  } else {
    Write-Host ('  set for this image: ' + ($on -join ', ')) -ForegroundColor Yellow
    [void]$problems.Add('Exploit Protection has per-image mitigations set for hivemind-windows.exe; clear them in Windows Security > App & browser control > Exploit protection > Program settings')
  }
} catch {
  Write-Host '  could not be read on this Windows (Get-ProcessMitigation is unavailable here)'
}

# ---------------------------------------------------- the loader's search

Write-Head 'Where Windows resolves each library the engine needs'
$searchDirs = New-Object System.Collections.ArrayList
[void]$searchDirs.Add($EngineDir)
[void]$searchDirs.Add((Join-Path $env:SystemRoot 'System32'))
[void]$searchDirs.Add($env:SystemRoot)
[void]$searchDirs.Add((Get-Location).Path)
foreach ($entry in ($env:PATH -split ';')) {
  if ($entry.Trim()) { [void]$searchDirs.Add($entry.Trim()) }
}

foreach ($dep in $Dependencies) {
  $found = $null
  foreach ($dir in $searchDirs) {
    $candidate = Join-Path $dir $dep
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $found = $candidate; break }
  }
  if (-not $found) {
    Write-Host ("  {0,-22} NOT FOUND ANYWHERE" -f $dep) -ForegroundColor Red
    [void]$problems.Add("$dep is not on this machine at all")
    continue
  }
  $arch = Get-PeMachine $found
  $line = "  {0,-22} {1,-14} {2}" -f $dep, $arch, $found
  if ($arch -eq 'x64') {
    Write-Host $line
  } else {
    Write-Host $line -ForegroundColor Red
    [void]$problems.Add("$dep resolves to a $arch file at $found -- the engine is 64-bit and cannot load it")
  }
}

# Every other copy on PATH, because the one that wins today is not
# necessarily the one that wins after an install reorders PATH.
Write-Head 'Other copies of those libraries on this machine'
$shadows = 0
foreach ($dep in $Dependencies) {
  $seen = 0
  foreach ($dir in $searchDirs) {
    $candidate = Join-Path $dir $dep
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
    $seen++
    if ($seen -eq 1) { continue }
    $arch = Get-PeMachine $candidate
    $shadows++
    $line = "  {0,-22} {1,-14} {2}" -f $dep, $arch, $candidate
    if ($arch -eq 'x64') { Write-Host $line } else { Write-Host ($line + '   <-- 32-bit copy on the search path') -ForegroundColor Yellow }
  }
}
if ($shadows -eq 0) { Write-Host '  none -- every library has exactly one copy on the search path' }

# Windows 10 and 11 ship their own ONNX Runtime in System32 for Windows ML. It
# is a different, older build than the one the engine is compiled against, and
# it only ever gets loaded if the engine's own copy is missing or unreadable --
# in which case the engine does not fail to find a runtime, it silently finds
# the wrong one. Worth naming, because "there are two of these on the machine"
# is the sort of thing that looks fine until it is not.
$systemOrt = Join-Path (Join-Path $env:SystemRoot 'System32') 'onnxruntime.dll'
if (Test-Path -LiteralPath $systemOrt) {
  $ours = Join-Path $EngineDir 'onnxruntime.dll'
  if (Test-Path -LiteralPath $ours) {
    Write-Host "  note: Windows has its own onnxruntime.dll in System32; the engine's own copy is present and wins."
  } else {
    Write-Host "  WARNING: the engine has no onnxruntime.dll of its own, so Windows' System32 copy will be loaded instead. That is the wrong version." -ForegroundColor Red
    [void]$problems.Add("the engine's onnxruntime.dll is missing, so Windows would load its own incompatible copy from System32")
  }
}

# ------------------------------------------------------------ app folder

if ($AppDir) {
  Write-Head 'The Visual C++ runtime the app ships (and copies beside the engine)'
  Get-ChildItem $AppDir -Filter '*140*.dll' -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
    Write-Host ("  {0,-30} {1,10:N0} bytes  [{2}]" -f $_.Name, $_.Length, (Get-PeMachine $_.FullName))
  }
}

# ----------------------------------------------------------- live launch

if (-not $NoRun) {
  $exe = Join-Path $EngineDir 'hivemind-windows.exe'
  if (-not (Test-Path $exe)) {
    Write-Head 'Starting the engine for real'
    Write-Host '  no engine to start' -ForegroundColor Red
  } else {
    # Two launches, because they answer different questions. The first is the
    # exact shape the app uses -- the engine's own directory as the working
    # directory and the network named relative to it -- and the second passes
    # the absolute path, which is the shape that has to survive Windows command
    # line quoting. The support directory is "...\Chess Auto Prep\bughouse",
    # so that path contains spaces, and an argument split on them is what makes
    # the engine answer "Unknown UCI option: Auto".
    $attempts = @(
      @{ Label = 'as the app launches it (network named relative to the engine)';
         Args  = '--model hivemind.onnx' },
      @{ Label = 'with the full path to the network (tests quoting)';
         Args  = ('--model "' + (Join-Path $EngineDir 'hivemind.onnx') + '"') }
    )

    foreach ($attempt in $attempts) {
      Write-Head ('Starting the engine for real -- ' + $attempt.Label)
      Write-Host ('  command: "' + $exe + '" ' + $attempt.Args)
      Write-Host ('  in     : ' + $EngineDir)

      # System.Diagnostics.Process rather than Start-Process: Start-Process
      # joins -ArgumentList with spaces and does not quote, which is what broke
      # the first version of this script, and its -PassThru object's exit code
      # is not reliably available in Windows PowerShell 5.1.
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $exe
      $psi.Arguments = $attempt.Args
      $psi.WorkingDirectory = $EngineDir
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      $psi.RedirectStandardInput = $true
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true

      $p = New-Object System.Diagnostics.Process
      $p.StartInfo = $psi
      try {
        [void]$p.Start()
      } catch {
        Write-Host ('  could not start it: ' + $_.Exception.Message) -ForegroundColor Red
        [void]$problems.Add('the engine could not be started at all: ' + $_.Exception.Message)
        continue
      }

      # stderr is read asynchronously so a full stderr pipe cannot block the
      # stdout read, which is the classic way a script like this hangs.
      $errTask = $p.StandardError.ReadToEndAsync()
      $clock = [System.Diagnostics.Stopwatch]::StartNew()
      $lines = New-Object System.Collections.ArrayList
      $uciokAt = $null
      $readyokAt = $null
      $bestmove = $null

      try {
        $p.StandardInput.WriteLine('uci')
        $p.StandardInput.Flush()
      } catch { }

      # The app allows the engine 90 seconds to answer `uci`, because the first
      # load reads a 54 MB network off disk and a machine whose antivirus is
      # scanning it for the first time can take most of that. Anything less
      # here would report a slow machine as a broken one.
      while ($clock.Elapsed.TotalSeconds -lt 120) {
        $line = Read-EngineLine $p.StandardOutput 2000
        if ($null -eq $line) {
          if ($p.HasExited) { break }
          continue
        }
        [void]$lines.Add($line)
        if ($line -match '^uciok') {
          $uciokAt = $clock.Elapsed.TotalSeconds
          try { $p.StandardInput.WriteLine('isready'); $p.StandardInput.Flush() } catch { }
        } elseif ($line -match '^readyok') {
          $readyokAt = $clock.Elapsed.TotalSeconds
          # Prove a search, not just a handshake: loading the network and
          # running it are different things, and only the second is the feature.
          # A bughouse position is two crazyhouse FENs, pipe-separated, and the
          # engine needs to be told which team it is playing before it will
          # answer with a joint move.
          try {
            $p.StandardInput.WriteLine('setoption name Team value white')
            $p.StandardInput.WriteLine('position fen ' + $StartDualFen)
            $p.StandardInput.WriteLine('go nodes 50')
            $p.StandardInput.Flush()
          } catch { }
        } elseif ($line -match '^bestmove') {
          $bestmove = $line
          break
        }
      }
      $elapsed = $clock.Elapsed.TotalSeconds

      try { $p.StandardInput.WriteLine('quit'); $p.StandardInput.Flush(); $p.StandardInput.Close() } catch { }

      # Polled on HasExited rather than WaitForExit(int): a property has no
      # overload to resolve, and overload resolution is where the first version
      # of this script died with "Specified cast is not valid".
      $deadline = (Get-Date).AddSeconds(10)
      while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
      }
      $stillRunning = -not $p.HasExited
      if ($stillRunning) {
        try { $p.Kill() } catch { }
        Start-Sleep -Milliseconds 300
      }
      $stderr = $errTask.Result
      $stdout = ($lines -join "`n")
      $backend = ($lines | Where-Object { $_ -match 'backend' } | Select-Object -First 1)

      if ($stillRunning) {
        $code = $null
        $hex = '(was still running; killed)'
      } else {
        $code = $p.ExitCode
        $hex = '0x' + $code.ToString('X8')
      }

      if ($bestmove) {
        Write-Host ('  uciok after ' + ('{0:N1}' -f $uciokAt) + 's, readyok after ' + ('{0:N1}' -f $readyokAt) + 's, searched in ' + ('{0:N1}' -f $elapsed) + 's total') -ForegroundColor Green
        if ($backend) { Write-Host ('  ' + $backend.Trim()) }
        Write-Host ('  ' + $bestmove.Trim()) -ForegroundColor Green
        Write-Host '  this engine works on this machine' -ForegroundColor Green
      } elseif ($null -ne $uciokAt) {
        Write-Host ('  answered uci after ' + ('{0:N1}' -f $uciokAt) + 's but never produced a move (' + ('{0:N1}' -f $elapsed) + 's)') -ForegroundColor Red
        [void]$problems.Add('the engine handshakes but never finishes a search -- the network loads and the search does not')
      } elseif ($stillRunning) {
        Write-Host ('  still running after ' + ('{0:N1}' -f $elapsed) + 's and never answered uci') -ForegroundColor Red
        [void]$problems.Add('the engine started but never answered uci within 120s -- it is stuck before or during loading the network')
      } else {
        Write-Host ('  exited with ' + $code + ' (' + $hex + ') after ' + ('{0:N1}' -f $elapsed) + 's without answering uci') -ForegroundColor Red
        switch ($hex) {
          '0xC000007B' { [void]$problems.Add('STATUS_INVALID_IMAGE_FORMAT: a library it loaded is not a valid 64-bit image, or a file did not finish being written -- see the resolution table above') }
          '0xC0000135' { [void]$problems.Add('STATUS_DLL_NOT_FOUND: install the Microsoft Visual C++ Redistributable (x64)') }
          '0xC0000139' { [void]$problems.Add('STATUS_ENTRYPOINT_NOT_FOUND: a library it loaded is the wrong version') }
          '0xC000001D' { [void]$problems.Add('STATUS_ILLEGAL_INSTRUCTION: this CPU is too old for the shipped build') }
          '0xC0000005' { [void]$problems.Add('the engine crashed with an access violation') }
          default {
            [void]$problems.Add(('the engine exited with ' + $code + ' (' + $hex + ') instead of starting -- read its stderr below'))
          }
        }
      }

      foreach ($pair in @(@('stdout', $stdout), @('stderr', $stderr))) {
        if ($pair[1] -and $pair[1].Trim()) {
          Write-Host ('  --- ' + $pair[0] + ' ---')
          ($pair[1] -split "`n" | Select-Object -First 20) | ForEach-Object { Write-Host ('  ' + $_.TrimEnd()) }
        }
      }
    }
  }
}

# -------------------------------------------------------------- verdict

Write-Head 'Verdict'
if ($problems.Count -eq 0) {
  Write-Host '  Nothing wrong found. Every library resolves to a 64-bit file and the engine starts.' -ForegroundColor Green
} else {
  foreach ($p in $problems) { Write-Host ("  * " + $p) -ForegroundColor Yellow }
}
Write-Host ''
Write-Host 'Send the whole of this output back with the bug report.'
