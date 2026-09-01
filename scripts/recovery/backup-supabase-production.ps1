[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$BackupRoot,
  [Parameter(Mandatory)] [string]$PassphraseFile,
  [Parameter(Mandatory)] [string]$ConnectionUrlFile
)

$ErrorActionPreference = 'Stop'

function Require-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command '$Name' is not available."
  }
}

function Assert-OutsideRepository([string]$Path, [string]$Name) {
  $resolved = [IO.Path]::GetFullPath($Path)
  $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
  if ($resolved.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "$Name must be outside the repository so production secrets and data never enter Git working files."
  }
  return $resolved
}

function Escape-PgPass([string]$Value) {
  return $Value.Replace('\', '\\').Replace(':', '\:')
}

Require-Command 'docker'
$resolvedBackupRoot = Assert-OutsideRepository $BackupRoot 'BackupRoot'
$resolvedPassphraseFile = Assert-OutsideRepository $PassphraseFile 'PassphraseFile'
$resolvedConnectionUrlFile = Assert-OutsideRepository $ConnectionUrlFile 'ConnectionUrlFile'
if (-not (Test-Path -LiteralPath $resolvedPassphraseFile -PathType Leaf)) {
  throw 'PassphraseFile must be an existing, owner-controlled file outside the repository.'
}
if ([string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $resolvedPassphraseFile -Raw))) {
  throw 'PassphraseFile must not be empty.'
}
if (-not (Test-Path -LiteralPath $resolvedConnectionUrlFile -PathType Leaf)) {
  throw 'ConnectionUrlFile must be an existing, owner-controlled file outside the repository.'
}
$connectionRaw = Get-Content -LiteralPath $resolvedConnectionUrlFile -Raw
$connectionUrl = if ($null -eq $connectionRaw) { '' } else { $connectionRaw.Trim() }
if ([string]::IsNullOrWhiteSpace($connectionUrl)) {
  throw 'ConnectionUrlFile must contain the production PostgreSQL connection URL. Do not place that URL in Git, chat, or shell history.'
}

try {
  $databaseUri = [Uri]$connectionUrl
} catch {
  throw 'ConnectionUrlFile must contain a valid PostgreSQL connection URL.'
}
if ($databaseUri.Scheme -notin @('postgres', 'postgresql')) {
  throw 'CASCADE_PRODUCTION_DATABASE_URL must use postgres:// or postgresql://.'
}

$userInfo = [Uri]::UnescapeDataString($databaseUri.UserInfo)
$separator = $userInfo.IndexOf(':')
if ($separator -lt 1) { throw 'Database URL must contain a username and password.' }
$databaseUser = $userInfo.Substring(0, $separator)
$databasePassword = $userInfo.Substring($separator + 1)
$databaseName = $databaseUri.AbsolutePath.TrimStart('/')
if ([string]::IsNullOrWhiteSpace($databaseName)) { throw 'Database URL must include a database name.' }
$databasePort = if ($databaseUri.IsDefaultPort) { 5432 } else { $databaseUri.Port }

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupSet = Join-Path $resolvedBackupRoot "cascade-supabase-$timestamp"
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "cascade-supabase-backup-$timestamp"
$pgPassFile = Join-Path $temporaryRoot 'pgpass'
$plainDump = Join-Path $temporaryRoot 'cascade-production.dump'
$encryptedDump = Join-Path $temporaryRoot 'cascade-production.dump.enc'

New-Item -ItemType Directory -Force -Path $backupSet, $temporaryRoot | Out-Null

try {
  $pgPass = "$(Escape-PgPass $databaseUri.Host):$(Escape-PgPass $databasePort.ToString()):$(Escape-PgPass $databaseName):$(Escape-PgPass $databaseUser):$(Escape-PgPass $databasePassword)"
  Set-Content -LiteralPath $pgPassFile -Value $pgPass -Encoding ascii -NoNewline

  # postgres:17 is already present locally. No image pull is allowed by this backup command.
  & docker image inspect postgres:17 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'The local postgres:17 image is required and was not found. Do not pull an image during a production cutover.' }

  $volumeTemp = "$temporaryRoot`:/work"
  $volumePgPass = "$pgPassFile`:/run/secrets/pgpass:ro"
  $volumePassphrase = "$resolvedPassphraseFile`:/run/secrets/backup-passphrase:ro"
  $containerScript = @'
set -eu
export PGPASSFILE=/run/secrets/pgpass
pg_dump --format=custom --no-owner --no-acl --file /work/cascade-production.dump
openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -md sha512 -salt \
  -in /work/cascade-production.dump \
  -out /work/cascade-production.dump.enc \
  -pass file:/run/secrets/backup-passphrase
rm -f /work/cascade-production.dump
'@

  & docker run --rm --pull never `
    --volume $volumeTemp `
    --volume $volumePgPass `
    --volume $volumePassphrase `
    --env "PGHOST=$($databaseUri.Host)" `
    --env "PGPORT=$databasePort" `
    --env "PGUSER=$databaseUser" `
    --env "PGDATABASE=$databaseName" `
    postgres:17 sh -c $containerScript
  if ($LASTEXITCODE -ne 0) { throw "Docker backup job failed with exit code $LASTEXITCODE." }
  if (-not (Test-Path -LiteralPath $encryptedDump -PathType Leaf)) { throw 'Encrypted backup output is missing.' }

  Move-Item -LiteralPath $encryptedDump -Destination (Join-Path $backupSet 'cascade-production.dump.enc')
  $finalDump = Join-Path $backupSet 'cascade-production.dump.enc'
  Get-FileHash -Algorithm SHA256 -LiteralPath $finalDump |
    ForEach-Object { "$($_.Hash.ToLowerInvariant())  $([IO.Path]::GetFileName($finalDump))" } |
    Set-Content -LiteralPath (Join-Path $backupSet 'SHA256SUMS') -Encoding utf8NoBOM

  @(
    'Cascade production logical backup',
    "created_at_utc=$((Get-Date).ToUniversalTime().ToString('o'))",
    'format=pg_dump custom',
    'encryption=openssl aes-256-cbc pbkdf2 sha512 600000 iterations',
    'runtime=existing local postgres:17 Docker image; pull disabled',
    'restore_proof=not yet performed',
    'contains_production_personal_data=true',
    'retention=follow approved Cascade retention policy'
  ) | Set-Content -LiteralPath (Join-Path $backupSet 'MANIFEST.txt') -Encoding utf8NoBOM

  Write-Output "Encrypted Cascade production backup created outside the repository: $backupSet"
  Write-Output 'Next required step: complete the separately documented disposable restore proof before relying on this backup for a cutover.'
}
finally {
  if (Test-Path -LiteralPath $plainDump -PathType Leaf) { Remove-Item -LiteralPath $plainDump -Force }
  if (Test-Path -LiteralPath $pgPassFile -PathType Leaf) { Remove-Item -LiteralPath $pgPassFile -Force }
  if (Test-Path -LiteralPath $temporaryRoot -PathType Container) { Remove-Item -LiteralPath $temporaryRoot -Force }
}
