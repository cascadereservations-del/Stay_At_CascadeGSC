[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$BackupSet,
  [string]$AgeIdentityFile = $env:AGE_IDENTITY_FILE
)

$ErrorActionPreference = 'Stop'
$n8nImage = 'n8nio/n8n:2.37.10'
$postgresImage = 'postgres:17.11-alpine3.24'
$helperImage = 'alpine:3.22.1'

function Invoke-Checked([string]$Command, [string[]]$Arguments, [string]$Failure) {
  & $Command @Arguments | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "$Failure (exit $LASTEXITCODE)." }
}

function Read-EnvValue([string]$Path, [string]$Key, [string]$Pattern) {
  $matches = @(Get-Content -LiteralPath $Path | Where-Object { $_ -match "^$([regex]::Escape($Key))=(.*)$" })
  if ($matches.Count -ne 1) { throw "Encrypted environment must contain exactly one $Key value." }
  $value = $matches[0].Substring($Key.Length + 1)
  if ($value -notmatch $Pattern) { throw "Encrypted environment contains an unsafe $Key format." }
  return $value
}

foreach ($command in @('docker', 'age')) {
  if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "$command is required." }
}
if ([string]::IsNullOrWhiteSpace($AgeIdentityFile)) { throw 'AGE_IDENTITY_FILE is required.' }
if (-not (Test-Path -LiteralPath $BackupSet -PathType Container)) { throw 'BackupSet must be an existing directory.' }
if (-not (Test-Path -LiteralPath $AgeIdentityFile -PathType Leaf)) { throw 'AGE identity file is missing.' }
if (-not (Test-Path -LiteralPath (Join-Path $BackupSet 'COMPLETE') -PathType Leaf)) { throw 'Backup is not marked COMPLETE.' }
if (Test-Path -LiteralPath (Join-Path $BackupSet 'INCOMPLETE')) { throw 'Backup is marked INCOMPLETE.' }

$requiredEncryptedFiles = @(
  'cascade-postgres.dump.age',
  'cascade-n8n-data.tar.gz.age',
  'cascade-files.tar.gz.age',
  'cascade-environment.env.age',
  'recovery-metadata.json.age'
)
$checksumPath = Join-Path $BackupSet 'SHA256SUMS'
if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) { throw 'SHA256SUMS is missing.' }
$checksumLines = @(Get-Content -LiteralPath $checksumPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($checksumLines.Count -ne $requiredEncryptedFiles.Count) { throw 'SHA256SUMS does not contain the required encrypted artifact set.' }
$seen = @{}
foreach ($line in $checksumLines) {
  if ($line -notmatch '^([a-f0-9]{64})  ([A-Za-z0-9.-]+)$') { throw 'SHA256SUMS contains an invalid line.' }
  $expectedHash = $Matches[1]
  $name = $Matches[2]
  if ($name -notin $requiredEncryptedFiles -or $seen.ContainsKey($name)) { throw 'SHA256SUMS contains an unexpected or duplicate artifact.' }
  $artifact = Join-Path $BackupSet $name
  if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) { throw "Encrypted artifact is missing: $name" }
  $actualHash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -ne $expectedHash) { throw "Encrypted artifact checksum failed: $name" }
  $seen[$name] = $true
}

$suffix = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$resourcePrefix = "cascade-restore-check-$suffix"
$dbContainer = "$resourcePrefix-postgres"
$dbVolume = "$resourcePrefix-postgres-data"
$n8nVolume = "$resourcePrefix-n8n-data"
$network = "$resourcePrefix-internal"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) $resourcePrefix
$restoredFiles = Join-Path $tempRoot 'files'
New-Item -ItemType Directory -Force -Path $tempRoot, $restoredFiles | Out-Null

try {
  $decrypted = [ordered]@{
    'cascade-postgres.dump.age' = 'cascade-postgres.dump'
    'cascade-n8n-data.tar.gz.age' = 'cascade-n8n-data.tar.gz'
    'cascade-files.tar.gz.age' = 'cascade-files.tar.gz'
    'cascade-environment.env.age' = 'cascade-environment.env'
    'recovery-metadata.json.age' = 'recovery-metadata.json'
  }
  foreach ($entry in $decrypted.GetEnumerator()) {
    Invoke-Checked 'age' @('-d', '-i', $AgeIdentityFile, '-o', (Join-Path $tempRoot $entry.Value), (Join-Path $BackupSet $entry.Key)) "Decryption failed for $($entry.Key)"
  }

  $environmentFile = Join-Path $tempRoot 'cascade-environment.env'
  $dbName = Read-EnvValue $environmentFile 'CASCADE_N8N_DB_NAME' '^[a-z][a-z0-9_]{2,62}$'
  $dbUser = Read-EnvValue $environmentFile 'CASCADE_N8N_DB_USER' '^[a-z][a-z0-9_]{2,62}$'
  $dbPassword = Read-EnvValue $environmentFile 'CASCADE_N8N_DB_PASSWORD' '^[A-Za-z0-9_-]{32,}$'
  $encryptionKey = Read-EnvValue $environmentFile 'CASCADE_N8N_ENCRYPTION_KEY' '^[A-Za-z0-9_-]{64,}$'
  $metadata = Get-Content -LiteralPath (Join-Path $tempRoot 'recovery-metadata.json') -Raw | ConvertFrom-Json
  if ($metadata.schema_version -ne 1 -or $metadata.consistent_capture -ne $true) { throw 'Recovery metadata is unsupported or not a consistent capture.' }
  if ($metadata.image -ne $n8nImage) { throw 'Recovery metadata image does not match the reviewed restore image.' }

  $dbEnv = Join-Path $tempRoot 'postgres.env'
  @("POSTGRES_DB=$dbName", "POSTGRES_USER=$dbUser", "POSTGRES_PASSWORD=$dbPassword") | Set-Content -LiteralPath $dbEnv -Encoding ascii
  $n8nEnv = Join-Path $tempRoot 'n8n.env'
  @(
    'DB_TYPE=postgresdb',
    "DB_POSTGRESDB_HOST=$dbContainer",
    'DB_POSTGRESDB_PORT=5432',
    "DB_POSTGRESDB_DATABASE=$dbName",
    "DB_POSTGRESDB_USER=$dbUser",
    "DB_POSTGRESDB_PASSWORD=$dbPassword",
    "N8N_ENCRYPTION_KEY=$encryptionKey",
    'N8N_DIAGNOSTICS_ENABLED=false',
    'N8N_VERSION_NOTIFICATIONS_ENABLED=false',
    'N8N_TEMPLATES_ENABLED=false'
  ) | Set-Content -LiteralPath $n8nEnv -Encoding ascii

  Invoke-Checked 'docker' @('network', 'create', '--internal', $network) 'Disposable isolated network creation failed'
  Invoke-Checked 'docker' @('volume', 'create', $dbVolume) 'Disposable PostgreSQL volume creation failed'
  Invoke-Checked 'docker' @('volume', 'create', $n8nVolume) 'Disposable n8n volume creation failed'
  Invoke-Checked 'docker' @('run', '--rm', '--network', 'none', '-v', "${n8nVolume}:/restore", '-v', "${tempRoot}:/backup:ro", $helperImage, 'sh', '-c', 'cd /restore && tar -xzf /backup/cascade-n8n-data.tar.gz') 'n8n data-volume restore failed'
  Invoke-Checked 'docker' @('run', '--rm', '--network', 'none', '-v', "${restoredFiles}:/restore", '-v', "${tempRoot}:/backup:ro", $helperImage, 'sh', '-c', 'cd /restore && tar -xzf /backup/cascade-files.tar.gz') 'Files-directory restore failed'

  Invoke-Checked 'docker' @('run', '-d', '--name', $dbContainer, '--network', $network, '--env-file', $dbEnv, '-v', "${dbVolume}:/var/lib/postgresql/data", $postgresImage) 'Disposable PostgreSQL container failed to start'
  $ready = $false
  for ($attempt = 0; $attempt -lt 30; $attempt++) {
    & docker exec $dbContainer pg_isready -U $dbUser -d $dbName *> $null
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    Start-Sleep -Seconds 2
  }
  if (-not $ready) { throw 'Disposable PostgreSQL container did not become healthy.' }

  Invoke-Checked 'docker' @('cp', (Join-Path $tempRoot 'cascade-postgres.dump'), "${dbContainer}:/tmp/cascade-postgres.dump") 'Database dump copy failed'
  Invoke-Checked 'docker' @('exec', $dbContainer, 'pg_restore', '--exit-on-error', '--no-owner', '--no-acl', '-U', $dbUser, '-d', $dbName, '/tmp/cascade-postgres.dump') 'PostgreSQL restore check failed'
  $counts = & docker exec $dbContainer psql -At -U $dbUser -d $dbName -c "select json_build_object('workflow_count', count(*), 'active_workflow_count', count(*) filter (where active), 'credential_count', (select count(*) from credentials_entity)) from workflow_entity;"
  if ($LASTEXITCODE -ne 0) { throw 'Restored n8n tables are not queryable.' }
  $actual = $counts | ConvertFrom-Json
  foreach ($field in @('workflow_count', 'active_workflow_count', 'credential_count')) {
    if ([int]$actual.$field -ne [int]$metadata.$field) { throw "Restored $field does not match the captured value." }
  }

  & docker run --rm --network $network --env-file $n8nEnv -v "${n8nVolume}:/home/node/.n8n" --entrypoint sh $n8nImage -c 'mkdir -p /tmp/workflows && n8n export:workflow --backup --output=/tmp/workflows' *> $null
  if ($LASTEXITCODE -ne 0) { throw 'Restored workflows could not be decrypted and exported.' }
  if ([int]$metadata.credential_count -gt 0) {
    & docker run --rm --network $network --env-file $n8nEnv -v "${n8nVolume}:/home/node/.n8n" $n8nImage export:credentials --all --decrypted --output=/tmp/credentials.json *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Restored credentials could not be decrypted with the escrowed key.' }
  }

  Write-Output "Disposable isolated restore passed: workflows=$([int]$actual.workflow_count); active=$([int]$actual.active_workflow_count); credentials=$([int]$actual.credential_count); prefix=$resourcePrefix"
}
finally {
  if (-not $resourcePrefix.StartsWith('cascade-restore-check-', [StringComparison]::Ordinal)) { throw 'Unsafe cleanup prefix; refusing cleanup.' }
  & docker rm -f $dbContainer 2>$null | Out-Null
  & docker volume rm $dbVolume 2>$null | Out-Null
  & docker volume rm $n8nVolume 2>$null | Out-Null
  & docker network rm $network 2>$null | Out-Null

  $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
  $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTemp)) {
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
}
