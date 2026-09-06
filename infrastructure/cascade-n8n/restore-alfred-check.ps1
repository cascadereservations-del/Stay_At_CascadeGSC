[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$BackupSet,
  [Parameter(Mandatory)] [string]$AgeIdentityFile,
  [string]$AgeExecutable = 'C:\Users\Lloyd\AppData\Local\Microsoft\WinGet\Packages\FiloSottile.age_Microsoft.Winget.Source_8wekyb3d8bbwe\age\age.exe'
)

$ErrorActionPreference = 'Stop'
$n8nImage = 'n8nio/n8n@sha256:307d6065be25619aa24cfc63a7c2f04ca56d084a08c05c8e9f189a89f353b1ec'
$helperImage = 'alpine:3.22.1'

function Invoke-Checked([string]$Command, [string[]]$Arguments, [string]$Failure) {
  & $Command @Arguments | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "$Failure (exit $LASTEXITCODE)." }
}

foreach ($path in @($BackupSet, $AgeIdentityFile, $AgeExecutable)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Required recovery path is missing: $path" }
}
foreach ($command in @('docker', 'tar')) {
  if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "$command is required." }
}

$cipherName = 'alfred-n8n-recovery.tar.gz.age'
$cipherPath = Join-Path $BackupSet $cipherName
$checksumPath = Join-Path $BackupSet 'SHA256SUMS'
if (-not (Test-Path -LiteralPath (Join-Path $BackupSet 'COMPLETE') -PathType Leaf)) { throw 'Backup is not marked COMPLETE.' }
if (-not (Test-Path -LiteralPath $cipherPath -PathType Leaf)) { throw 'Encrypted recovery artifact is missing.' }
if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) { throw 'SHA256SUMS is missing.' }

$checksumLines = @(Get-Content -LiteralPath $checksumPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($checksumLines.Count -ne 1 -or $checksumLines[0] -notmatch '^([a-f0-9]{64})  alfred-n8n-recovery\.tar\.gz\.age$') {
  throw 'SHA256SUMS does not describe the exact encrypted Alfred recovery artifact.'
}
$expectedCipherHash = $Matches[1]
$actualCipherHash = (Get-FileHash -LiteralPath $cipherPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualCipherHash -ne $expectedCipherHash) { throw 'Encrypted recovery artifact checksum failed.' }

$suffix = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$resourcePrefix = "cascade-alfred-restore-$suffix"
$network = "$resourcePrefix-internal"
$n8nVolume = "$resourcePrefix-n8n-data"
$queryContainer = "$resourcePrefix-query"
$workflowContainer = "$resourcePrefix-workflows"
$credentialContainer = "$resourcePrefix-credentials"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) $resourcePrefix
$archiveRoot = Join-Path $tempRoot 'archive'
$outerArchive = Join-Path $tempRoot 'recovery.tar.gz'
New-Item -ItemType Directory -Force -Path $tempRoot, $archiveRoot | Out-Null

try {
  Invoke-Checked $AgeExecutable @('-d', '-i', $AgeIdentityFile, '-o', $outerArchive, $cipherPath) 'Recovery artifact decryption failed'
  Invoke-Checked 'tar' @('-xzf', $outerArchive, '-C', $tempRoot) 'Recovery archive extraction failed'

  $metadataPath = Join-Path $tempRoot 'metadata.json'
  $validationPath = Join-Path $tempRoot 'sqlite-validation.json'
  $databasePath = Join-Path $tempRoot 'database.sqlite'
  $volumeArchivePath = Join-Path $tempRoot 'n8n-volume-files.tar.gz'
  $keyPath = Join-Path $tempRoot 'N8N_ENCRYPTION_KEY'
  foreach ($required in @($metadataPath, $validationPath, $databasePath, $volumeArchivePath, $keyPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Recovery payload is missing: $required" }
  }

  $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
  $sourceValidation = Get-Content -LiteralPath $validationPath -Raw | ConvertFrom-Json
  if ($metadata.schema_version -ne 1 -or $metadata.source -ne 'alfred-existing-n8n' -or $metadata.database_engine -ne 'sqlite') {
    throw 'Recovery metadata is unsupported.'
  }
  if ($metadata.image_id -ne 'sha256:307d6065be25619aa24cfc63a7c2f04ca56d084a08c05c8e9f189a89f353b1ec') {
    throw 'Recovery image does not match the reviewed n8n digest.'
  }
  if ($sourceValidation.integrity_check -ne 'ok') { throw 'Source SQLite integrity check did not pass.' }
  foreach ($field in @('workflow_count', 'active_workflow_count', 'credential_count')) {
    if ([int]$sourceValidation.$field -ne [int]$metadata.$field) { throw "Source $field metadata mismatch." }
  }

  $keyLines = @(Get-Content -LiteralPath $keyPath)
  if ($keyLines.Count -ne 1 -or [string]::IsNullOrWhiteSpace($keyLines[0])) { throw 'Escrowed n8n encryption key is invalid.' }
  $n8nEnv = Join-Path $tempRoot 'n8n.env'
  @(
    'DB_TYPE=sqlite',
    "N8N_ENCRYPTION_KEY=$($keyLines[0])",
    'N8N_DIAGNOSTICS_ENABLED=false',
    'N8N_VERSION_NOTIFICATIONS_ENABLED=false',
    'N8N_TEMPLATES_ENABLED=false',
    'N8N_PERSONALIZATION_ENABLED=false',
    'N8N_HIRING_BANNER_ENABLED=false',
    'N8N_MCP_ENABLED=false',
    'N8N_PUBLIC_API_DISABLED=true',
    'N8N_PUBLIC_API_SWAGGERUI_DISABLED=true'
  ) | Set-Content -LiteralPath $n8nEnv -Encoding ascii

  Invoke-Checked 'docker' @('network', 'create', '--internal', $network) 'Disposable internal network creation failed'
  Invoke-Checked 'docker' @('volume', 'create', $n8nVolume) 'Disposable n8n volume creation failed'

  Invoke-Checked 'docker' @(
    'run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL',
    '--security-opt', 'no-new-privileges:true', '-v', "${tempRoot}:/backup", $helperImage,
    'sh', '-c', 'mkdir -p /backup/archive && tar -xzf /backup/n8n-volume-files.tar.gz -C /backup/archive'
  ) 'n8n file archive extraction failed'

  $sourceN8n = Join-Path $archiveRoot 'home\node\.n8n'
  if (-not (Test-Path -LiteralPath $sourceN8n -PathType Container)) { throw 'Recovered n8n data directory is missing.' }
  Invoke-Checked 'docker' @(
    'run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--cap-add', 'CHOWN',
    '--security-opt', 'no-new-privileges:true', '-v', "${n8nVolume}:/restore", '-v', "${sourceN8n}:/source:ro",
    $helperImage, 'sh', '-c', 'cp -a /source/. /restore/ && chown -R 1000:1000 /restore'
  ) 'n8n data-volume restore failed'
  Invoke-Checked 'docker' @(
    'run', '--rm', '--network', 'none', '--read-only', '--user', '1000:1000', '--cap-drop', 'ALL',
    '--security-opt', 'no-new-privileges:true', '-v', "${n8nVolume}:/restore", '-v', "${tempRoot}:/backup:ro",
    $helperImage, 'sh', '-c', 'cp /backup/database.sqlite /restore/database.sqlite && rm -f /restore/database.sqlite-shm /restore/database.sqlite-wal'
  ) 'SQLite database restore failed'

  $queryScript = Join-Path $tempRoot 'query.js'
  @'
const sqlite3 = require(require.resolve('sqlite3', { paths: ['/usr/local/lib/node_modules/n8n'] }));
const db = new sqlite3.Database(
  'file:/home/node/.n8n/database.sqlite?immutable=1',
  sqlite3.OPEN_READONLY | sqlite3.OPEN_URI
);
db.get(
  "SELECT (SELECT count(*) FROM workflow_entity) AS workflow_count, (SELECT count(*) FROM workflow_entity WHERE active = 1) AS active_workflow_count, (SELECT count(*) FROM credentials_entity) AS credential_count",
  (queryError, row) => {
    if (queryError) throw queryError;
    db.get('PRAGMA integrity_check', (integrityError, integrity) => {
      if (integrityError) throw integrityError;
      console.log(JSON.stringify({ ...row, integrity_check: integrity.integrity_check }));
      db.close((closeError) => { if (closeError) throw closeError; });
    });
  }
);
'@ | Set-Content -LiteralPath $queryScript -Encoding utf8

  $queryOutput = & docker run --rm --name $queryContainer --network $network --read-only --cap-drop ALL --security-opt no-new-privileges:true -v "${n8nVolume}:/home/node/.n8n:ro" -v "${tempRoot}:/check:ro" --entrypoint node $n8nImage /check/query.js
  if ($LASTEXITCODE -ne 0) { throw 'Restored SQLite database query failed.' }
  $actual = ($queryOutput | Select-Object -Last 1) | ConvertFrom-Json
  if ($actual.integrity_check -ne 'ok') { throw 'Restored SQLite integrity check failed.' }
  foreach ($field in @('workflow_count', 'active_workflow_count', 'credential_count')) {
    if ([int]$actual.$field -ne [int]$metadata.$field) { throw "Restored $field does not match the capture metadata." }
  }

  $commonRun = @(
    'run', '--rm', '--network', $network, '--read-only', '--cap-drop', 'ALL',
    '--security-opt', 'no-new-privileges:true', '--env-file', $n8nEnv,
    '--tmpfs', '/tmp:size=256m,mode=1777', '--tmpfs', '/home/node/.cache:size=64m,mode=1777',
    '-v', "${n8nVolume}:/home/node/.n8n"
  )
  Invoke-Checked 'docker' ($commonRun + @('--name', $workflowContainer, $n8nImage, 'export:workflow', '--all', '--output=/tmp/workflows.json')) 'Restored workflows could not be exported'
  if ([int]$metadata.credential_count -gt 0) {
    Invoke-Checked 'docker' ($commonRun + @('--name', $credentialContainer, $n8nImage, 'export:credentials', '--all', '--decrypted', '--output=/tmp/credentials.json')) 'Restored credentials could not be decrypted'
  }

  $networkDetails = & docker network inspect $network --format '{{.Internal}}'
  if ($LASTEXITCODE -ne 0 -or ($networkDetails | Select-Object -Last 1).Trim() -ne 'true') { throw 'Disposable restore network is not internal.' }
  $publishedPorts = @(& docker ps -a --filter "name=$resourcePrefix" --format '{{.Ports}}' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($publishedPorts.Count -ne 0) { throw 'Disposable restore unexpectedly published a host port.' }

  Write-Output "Disposable isolated Alfred restore passed: workflows=$([int]$actual.workflow_count); active=$([int]$actual.active_workflow_count); credentials=$([int]$actual.credential_count); sqlite_integrity=ok; network_internal=true; published_ports=0; prefix=$resourcePrefix"
}
finally {
  if (-not $resourcePrefix.StartsWith('cascade-alfred-restore-', [StringComparison]::Ordinal)) { throw 'Unsafe cleanup prefix; refusing cleanup.' }
  foreach ($container in @($queryContainer, $workflowContainer, $credentialContainer)) {
    & docker rm -f $container 2>$null | Out-Null
  }
  & docker volume rm $n8nVolume 2>$null | Out-Null
  & docker network rm $network 2>$null | Out-Null

  $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
  $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTemp)) {
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
}
