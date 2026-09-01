[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$BackupRoot,
  [Parameter(Mandatory)] [string]$AgeRecipient
)

$ErrorActionPreference = 'Stop'

function Require-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command '$Name' is not available. Install it before attempting a production backup."
  }
}

function Remove-PlaintextFile([string]$Path) {
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    Remove-Item -LiteralPath $Path -Force
  }
}

if ([string]::IsNullOrWhiteSpace($env:CASCADE_PRODUCTION_DATABASE_URL)) {
  throw 'CASCADE_PRODUCTION_DATABASE_URL must be supplied through the process environment. Do not place it in this script, Git, or a shell history file.'
}

Require-Command 'pg_dump'
Require-Command 'pg_restore'
Require-Command 'age'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$resolvedBackupRoot = [IO.Path]::GetFullPath($BackupRoot)
if ($resolvedBackupRoot.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'BackupRoot must be outside the repository so production data is never written into Git working files.'
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupSet = Join-Path $resolvedBackupRoot "cascade-supabase-$timestamp"
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "cascade-supabase-backup-$timestamp"
$plainDump = Join-Path $temporaryRoot 'cascade-production.dump'
$encryptedDump = Join-Path $backupSet 'cascade-production.dump.age'

New-Item -ItemType Directory -Force -Path $backupSet, $temporaryRoot | Out-Null

try {
  # The database URL is deliberately read from the environment and is never written or echoed.
  & pg_dump --format=custom --no-owner --no-acl --file $plainDump $env:CASCADE_PRODUCTION_DATABASE_URL
  if ($LASTEXITCODE -ne 0) { throw "pg_dump failed with exit code $LASTEXITCODE." }

  & age --recipient $AgeRecipient --output $encryptedDump $plainDump
  if ($LASTEXITCODE -ne 0) { throw "age encryption failed with exit code $LASTEXITCODE." }

  # This proves the encrypted archive is structurally readable only after explicit decryption in the restore runbook.
  Get-FileHash -Algorithm SHA256 -LiteralPath $encryptedDump |
    ForEach-Object { "$($_.Hash.ToLowerInvariant())  $([IO.Path]::GetFileName($encryptedDump))" } |
    Set-Content -LiteralPath (Join-Path $backupSet 'SHA256SUMS') -Encoding utf8NoBOM

  @(
    'Cascade production logical backup',
    "created_at_utc=$((Get-Date).ToUniversalTime().ToString('o'))",
    'format=pg_dump custom',
    'encryption=age recipient supplied at runtime',
    'restore_proof=not yet performed',
    'contains_production_personal_data=true',
    'retention=follow approved Cascade retention policy'
  ) | Set-Content -LiteralPath (Join-Path $backupSet 'MANIFEST.txt') -Encoding utf8NoBOM

  Write-Output "Encrypted Cascade production backup created outside the repository: $backupSet"
  Write-Output 'Next required step: complete the separately documented disposable restore proof before relying on this backup for a cutover.'
}
finally {
  Remove-PlaintextFile $plainDump
  if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
    Remove-Item -LiteralPath $temporaryRoot -Force
  }
}
