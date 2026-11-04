# Installs or updates Prosperity Voice on this PC by building it here from the source code.
# Safe to run again: running it again updates the app. See INSTALL.md.
# Run from PowerShell:  powershell -ExecutionPolicy Bypass -File windows\install.ps1 [-Cleanup claude|chatgpt|grok|off]
# -Cleanup sets which AI cleans up dictation (ask the user first). Without it, a new install picks the
# first of Claude, ChatGPT, Grok that's installed, and an update keeps the setting.
param([ValidateSet('claude', 'chatgpt', 'grok', 'off')][string]$Cleanup = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $env:LOCALAPPDATA 'Programs\Prosperity Voice'
$exe = Join-Path $dest 'ProsperityVoice.exe'

function Fail($message) { Write-Host "ERROR: $message" -ForegroundColor Red; exit 1 }

Write-Host '==> Checking this PC'
if (-not [Environment]::Is64BitOperatingSystem) { Fail 'Prosperity Voice needs 64-bit Windows 10 or 11.' }
$sdks = & { try { dotnet --list-sdks 2>$null } catch { @() } }
if (-not ($sdks | Where-Object { $_ -match '^(9|1\d)\.' })) {
    Fail ('The .NET 9 SDK is missing. Run: winget install --id Microsoft.DotNet.SDK.9 -e ' +
          '--accept-package-agreements --accept-source-agreements, then refresh PATH (see INSTALL.md) ' +
          'and run this script again.')
}

$sys = Join-Path $env:SystemRoot 'System32'
$vc = 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll', 'vcomp140.dll' |
    Where-Object { -not (Test-Path (Join-Path $sys $_)) }
if ($vc) {
    Fail ('The Microsoft Visual C++ Redistributable is missing (the speech engine needs it). Run: ' +
          'winget install --id Microsoft.VCRedist.2015+.x64 -e --accept-package-agreements --accept-source-agreements ' +
          '(then run this script again).')
}

Write-Host '==> Closing Prosperity Voice if it is running'
Get-Process ProsperityVoice -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1
# The install folder holds only the app; clear it so no files from an older build are left behind.
if (Test-Path $dest) { Get-ChildItem $dest -Force | Remove-Item -Recurse -Force }

Write-Host '==> Building (the first build downloads packages and takes a few minutes)'
dotnet publish (Join-Path $root 'windows\ProsperityVoice.csproj') -c Release -o $dest --nologo
if ($LASTEXITCODE -ne 0) { Fail 'The build failed. See the messages above.' }

Write-Host '==> Self-test (downloads the speech model, about 150 MB, the first time, then tests speech)'
$test = Start-Process -FilePath $exe -ArgumentList '--selftest' -NoNewWindow -Wait -PassThru
if ($test.ExitCode -ne 0) { Fail 'The self-test failed. See the messages above.' }

Write-Host '==> Start menu shortcut'
$programs = [Environment]::GetFolderPath('Programs')
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut((Join-Path $programs 'Prosperity Voice.lnk'))
$link.TargetPath = $exe
$link.WorkingDirectory = $dest
$link.Save()

if ($Cleanup) {
    Write-Host '==> Setting cleanup AI'
    $set = Start-Process -FilePath $exe -ArgumentList '--set-cleanup', $Cleanup -NoNewWindow -Wait -PassThru
    if ($set.ExitCode -ne 0) { Fail "Couldn't set the cleanup AI to $Cleanup." }
}

Write-Host '==> Starting Prosperity Voice'
Start-Process -FilePath $exe

Write-Host ''
Write-Host '==> Cleanup AI'
if ($Cleanup) { Write-Host "Cleanup is set to: $Cleanup (change it any time in Settings)." }
$found = 'claude', 'codex', 'grok' | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue }
if ($Cleanup) {
} elseif ($found) {
    Write-Host "Found: $($found -join ', '). On first launch Prosperity Voice uses the first of Claude, ChatGPT (codex), Grok"
    Write-Host 'that is installed, on your own subscription. Change it any time in Settings.'
} else {
    Write-Host 'No Claude, ChatGPT (codex), or Grok tool found, so text is pasted without cleanup.'
    Write-Host 'Install one of them (Claude Code, OpenAI Codex, or xAI grok), log in, and pick it in Settings.'
}

Write-Host ''
Write-Host '==> Done. Prosperity Voice is running (tray icon, bottom right) and starts when you log in.'
Write-Host 'Click in any text box, hold Right Ctrl, talk, and let go.'
Write-Host 'If Windows asks to let Prosperity Voice use the microphone, click Allow.'
