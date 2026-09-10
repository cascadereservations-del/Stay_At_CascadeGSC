[CmdletBinding()]
param(
  [ValidateSet('Backup', 'Restore')]
  [string]$Mode = 'Backup',
  [switch]$MonthlyGate
)

$ErrorActionPreference = 'Stop'

if ($MonthlyGate -and (Get-Date).Day -gt 7) {
  Write-Output 'Monthly restore gate skipped: today is not the first Sunday window.'
  exit 0
}

$gitBash = 'C:\Program Files\Git\bin\bash.exe'
$backupRoot = 'C:\Cascade-Backups'
$secretRoot = 'C:\Users\Lloyd\Cascade-Secrets'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$logRoot = Join-Path $backupRoot 'logs'

if (-not (Test-Path -LiteralPath $gitBash -PathType Leaf)) { throw 'Git Bash is required.' }
if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) { throw 'Backup root is missing.' }
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null

$env:CASCADE_SSH_BIN = '/c/Windows/System32/OpenSSH/ssh.exe'
$env:CASCADE_BACKUP_DIR = '/c/Cascade-Backups'
$env:CASCADE_SUPABASE_URL_FILE = '/c/Users/Lloyd/Cascade-Secrets/supabase-production-db-url.txt'
$env:CASCADE_SUPABASE_PASSPHRASE_FILE = '/c/Users/Lloyd/Cascade-Secrets/supabase-backup-passphrase.txt'

foreach ($name in @('supabase-production-db-url.txt', 'supabase-backup-passphrase.txt')) {
  $path = Join-Path $secretRoot $name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required owner-only file is missing: $name" }
}

$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$stdout = Join-Path $logRoot "$($Mode.ToLowerInvariant())-$stamp.log"
$stderr = Join-Path $logRoot "$($Mode.ToLowerInvariant())-$stamp.err.log"
$arguments = @('--noprofile', '--norc')

if ($Mode -eq 'Backup') {
  $script = Join-Path $repoRoot 'scripts\recovery\p5\supabase-backup-over-alfred.sh'
  $arguments += $script.Replace('\', '/')
} else {
  $set = Get-ChildItem -LiteralPath $backupRoot -Directory -Filter 'cascade-supabase-*' |
    Where-Object {
      (Test-Path -LiteralPath (Join-Path $_.FullName 'COMPLETE') -PathType Leaf) -and
      -not (Test-Path -LiteralPath (Join-Path $_.FullName 'INCOMPLETE')) -and
      (Test-Path -LiteralPath (Join-Path $_.FullName 'EXPECTED_LEDGER_ROWS') -PathType Leaf)
    } |
    Sort-Object Name -Descending |
    Select-Object -First 1
  if ($null -eq $set) { throw 'No COMPLETE backup set with EXPECTED_LEDGER_ROWS is available.' }
  $script = Join-Path $repoRoot 'scripts\recovery\p5\supabase-restore-check-on-alfred.sh'
  $arguments += $script.Replace('\', '/')
  $arguments += $set.FullName.Replace('\', '/')
}

$process = Start-Process -FilePath $gitBash -ArgumentList $arguments -Wait -PassThru -NoNewWindow `
  -RedirectStandardOutput $stdout -RedirectStandardError $stderr
if ($process.ExitCode -ne 0) {
  throw "$Mode job failed with exit code $($process.ExitCode). Review the owner-only log files under $logRoot."
}

Write-Output "$Mode job completed. Log: $stdout"
