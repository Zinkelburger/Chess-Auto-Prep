param([Parameter(Mandatory=$true)][string]$Request)
$ErrorActionPreference = 'Stop'
# Dart writes UTF-8 JSON. Windows PowerShell 5.1 otherwise decodes it using
# the system code page, corrupting non-ASCII user/install directory names.
$config = Get-Content -LiteralPath $Request -Raw -Encoding UTF8 | ConvertFrom-Json
$stateDir = Split-Path -Parent $Request
$log = Join-Path $stateDir 'install.log'
$ready = Join-Path $stateDir 'helper-ready'
$lock = $null
$exitCode = 0
try {
    $lock = [System.IO.File]::Open((Join-Path (Split-Path -Parent $stateDir) 'install.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    # Readiness is published only after capturing the old process handle.
    $app = Get-Process -Id $config.processId -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $ready -Value 'ready'
    while ($app -and !$app.HasExited) {
        if (!(Test-Path -LiteralPath $config.armed)) { return }
        Start-Sleep -Milliseconds 500
        $app.Refresh()
    }
    if (!(Test-Path -LiteralPath $config.armed)) { return }
    $hash = (Get-FileHash -LiteralPath $config.payload -Algorithm SHA256).Hash
    if ($hash -ne $config.sha256) { throw 'Update checksum mismatch' }
    $installDir = Split-Path -Parent $config.executable
    # Inno handles upgrades in the existing directory, retaining task choices.
    # No forced closing of other instances, and no machine reboot.
    $setup = Start-Process -FilePath $config.payload -ArgumentList @('/SILENT', '/NORESTART', '/NOCLOSEAPPLICATIONS', '/NORESTARTAPPLICATIONS', ('/DIR="' + $installDir + '"'), ('/LOG="' + (Join-Path $stateDir 'setup.log') + '"')) -Wait -PassThru
    if ($setup.ExitCode -ne 0) { throw "Installer exited with $($setup.ExitCode)" }
    Remove-Item -LiteralPath (Join-Path (Split-Path -Parent $stateDir) 'last-error.txt') -ErrorAction SilentlyContinue
    Add-Content -LiteralPath $log -Value 'Installation completed.'
    Start-Process -FilePath $config.executable
} catch {
    $exitCode = 1
    Add-Content -LiteralPath $log -Value ($_ | Out-String)
    Add-Content -LiteralPath $log -Value $_.ScriptStackTrace
    Set-Content -LiteralPath (Join-Path (Split-Path -Parent $stateDir) 'last-error.txt') -Value ("Update installation failed: " + $_.ToString() + ". Details: " + $log)
    Write-Error -Message $_.ToString() -ErrorAction Continue
} finally {
    Remove-Item -LiteralPath $ready -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $config.armed -ErrorAction SilentlyContinue
    if ($lock) { $lock.Dispose() }
}
exit $exitCode
