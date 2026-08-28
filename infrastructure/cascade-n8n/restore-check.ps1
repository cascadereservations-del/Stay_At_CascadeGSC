[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$BackupSet,
  [string]$AgeIdentityFile = $env:AGE_IDENTITY_FILE
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($AgeIdentityFile)) { throw 'AGE_IDENTITY_FILE is required.' }
if (-not (Test-Path -LiteralPath $BackupSet -PathType Container)) { throw 'BackupSet must be an existing directory.' }
if (-not (Test-Path -LiteralPath $AgeIdentityFile -PathType Leaf)) { throw 'AGE identity file is missing.' }

$suffix = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$resourcePrefix = "cascade-restore-check-$suffix"
$dbContainer = "$resourcePrefix-postgres"
$dbVolume = "$resourcePrefix-postgres-data"
$n8nVolume = "$resourcePrefix-n8n-data"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) $resourcePrefix
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  $databaseDump = Join-Path $tempRoot 'cascade-postgres.dump'
  $dataArchive = Join-Path $tempRoot 'cascade-n8n-data.tar.gz'
  & age -d -i $AgeIdentityFile -o $databaseDump (Join-Path $BackupSet 'cascade-postgres.dump.age')
  if ($LASTEXITCODE -ne 0) { throw 'Database backup decryption failed.' }
  & age -d -i $AgeIdentityFile -o $dataArchive (Join-Path $BackupSet 'cascade-n8n-data.tar.gz.age')
  if ($LASTEXITCODE -ne 0) { throw 'n8n data backup decryption failed.' }

  & docker volume create $dbVolume | Out-Null
  & docker volume create $n8nVolume | Out-Null
  & docker run -d --name $dbContainer -e POSTGRES_DB=restore_check -e POSTGRES_USER=restore_check -e POSTGRES_PASSWORD=restore-check-only -v "${dbVolume}:/var/lib/postgresql/data" postgres:17.11-alpine3.24 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Disposable PostgreSQL container failed to start.' }

  $ready = $false
  for ($attempt = 0; $attempt -lt 30; $attempt++) {
    & docker exec $dbContainer pg_isready -U restore_check -d restore_check *> $null
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    Start-Sleep -Seconds 2
  }
  if (-not $ready) { throw 'Disposable PostgreSQL container did not become healthy.' }

  & docker cp $databaseDump "${dbContainer}:/tmp/cascade-postgres.dump"
  & docker exec $dbContainer pg_restore --exit-on-error --no-owner --no-acl -U restore_check -d restore_check /tmp/cascade-postgres.dump
  if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL restore check failed.' }
  & docker exec $dbContainer psql -U restore_check -d restore_check -v ON_ERROR_STOP=1 -c 'select count(*) from workflow_entity;' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Restored n8n workflow table is not queryable.' }

  & docker run --rm -v "${n8nVolume}:/restore" -v "${tempRoot}:/backup:ro" alpine:3.22.1 sh -c 'cd /restore && tar -xzf /backup/cascade-n8n-data.tar.gz && test -f config'
  if ($LASTEXITCODE -ne 0) { throw 'n8n data-volume restore check failed.' }

  Write-Output "Disposable restore check passed: $resourcePrefix"
}
finally {
  if (-not $resourcePrefix.StartsWith('cascade-restore-check-', [StringComparison]::Ordinal)) {
    throw 'Unsafe cleanup prefix; refusing cleanup.'
  }
  & docker rm -f $dbContainer 2>$null | Out-Null
  & docker volume rm $dbVolume 2>$null | Out-Null
  & docker volume rm $n8nVolume 2>$null | Out-Null

  $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
  $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTemp)) {
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
}
