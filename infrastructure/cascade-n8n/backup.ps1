[CmdletBinding()]
param(
  [string]$ComposeFile = (Join-Path $PSScriptRoot 'compose.yaml'),
  [string]$EnvFile = (Join-Path $PSScriptRoot '.env'),
  [string]$BackupDirectory = $env:CASCADE_BACKUP_DIR,
  [string]$AgeRecipient = $env:AGE_RECIPIENT
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($BackupDirectory)) { throw 'CASCADE_BACKUP_DIR is required.' }
if ([string]::IsNullOrWhiteSpace($AgeRecipient)) { throw 'AGE_RECIPIENT is required.' }
if (-not [IO.Path]::IsPathFullyQualified($BackupDirectory)) { throw 'CASCADE_BACKUP_DIR must be an absolute external path.' }

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$backupRoot = [IO.Path]::GetFullPath($BackupDirectory)
if ($backupRoot.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Backups must be stored outside the repository.'
}

$timestamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$backupSet = Join-Path $backupRoot "cascade-n8n-$timestamp"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "cascade-n8n-backup-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $backupSet, $tempRoot | Out-Null

try {
  $databaseDump = Join-Path $tempRoot 'cascade-postgres.dump'
  $dataArchive = Join-Path $tempRoot 'cascade-n8n-data.tar.gz'

  $dumpArguments = @(
    '-f', $ComposeFile, '--env-file', $EnvFile,
    'exec', '-T', 'postgres',
    'pg_dump', '--format=custom', '--no-owner', '--no-acl',
    '--username', $env:CASCADE_N8N_DB_USER,
    '--dbname', $env:CASCADE_N8N_DB_NAME
  )
  $dumpProcess = Start-Process -FilePath 'docker-compose' -ArgumentList $dumpArguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $databaseDump
  if ($dumpProcess.ExitCode -ne 0) { throw "PostgreSQL backup failed with exit code $($dumpProcess.ExitCode)." }

  & docker run --rm --volumes-from cascade-n8n-app -v "${tempRoot}:/backup" alpine:3.22.1 tar -czf /backup/cascade-n8n-data.tar.gz -C /home/node/.n8n .
  if ($LASTEXITCODE -ne 0) { throw 'n8n data-volume backup failed.' }

  foreach ($source in @($databaseDump, $dataArchive)) {
    $destination = Join-Path $backupSet "$([IO.Path]::GetFileName($source)).age"
    & age -r $AgeRecipient -o $destination $source
    if ($LASTEXITCODE -ne 0) { throw "age encryption failed for $source." }
  }

  Get-ChildItem -LiteralPath $backupSet -File |
    Get-FileHash -Algorithm SHA256 |
    ForEach-Object { "$($_.Hash.ToLowerInvariant())  $([IO.Path]::GetFileName($_.Path))" } |
    Set-Content -LiteralPath (Join-Path $backupSet 'SHA256SUMS') -Encoding utf8NoBOM

  Write-Output "Encrypted Cascade backup created: $backupSet"
}
finally {
  $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
  $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTemp)) {
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
}
