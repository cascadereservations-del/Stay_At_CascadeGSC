[CmdletBinding()]
param(
  [string]$ComposeFile = (Join-Path $PSScriptRoot 'compose.yaml'),
  [string]$EnvFile = (Join-Path $PSScriptRoot '.env'),
  [string]$FilesDirectory = (Join-Path $PSScriptRoot 'files'),
  [string]$BackupDirectory = $env:CASCADE_BACKUP_DIR,
  [string]$AgeRecipient = $env:AGE_RECIPIENT,
  [switch]$Quiesce
)

$ErrorActionPreference = 'Stop'
$appContainer = 'cascade-n8n-app'

function Invoke-Checked([string]$Command, [string[]]$Arguments, [string]$Failure) {
  & $Command @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Failure (exit $LASTEXITCODE)." }
}

function Invoke-BinaryCapture([string]$Command, [string[]]$Arguments, [string]$OutputPath, [string]$Failure) {
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $Command
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  [void]$process.Start()
  $exitCode = $null
  $file = [IO.File]::Create($OutputPath)
  try {
    $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($file)
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    [void]$stdoutTask.GetAwaiter().GetResult()
    [void]$stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
  }
  finally {
    $file.Dispose()
    $process.Dispose()
  }
  if ($exitCode -ne 0) { throw "$Failure (exit $exitCode)." }
}

if (-not $Quiesce) { throw 'A consistent backup requires -Quiesce and a reviewed maintenance action.' }
foreach ($command in @('docker', 'docker-compose', 'age')) {
  if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "$command is required." }
}
if ([string]::IsNullOrWhiteSpace($BackupDirectory)) { throw 'CASCADE_BACKUP_DIR is required.' }
if ([string]::IsNullOrWhiteSpace($AgeRecipient)) { throw 'AGE_RECIPIENT is required.' }
if (-not [IO.Path]::IsPathFullyQualified($BackupDirectory)) { throw 'CASCADE_BACKUP_DIR must be an absolute external path.' }
foreach ($path in @($ComposeFile, $EnvFile)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required file is missing: $path" }
}
if (-not (Test-Path -LiteralPath $FilesDirectory -PathType Container)) { throw "Files directory is missing: $FilesDirectory" }
$ComposeFile = [IO.Path]::GetFullPath($ComposeFile)
$EnvFile = [IO.Path]::GetFullPath($EnvFile)
$FilesDirectory = [IO.Path]::GetFullPath($FilesDirectory)

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$backupRoot = [IO.Path]::GetFullPath($BackupDirectory)
if ($backupRoot.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Backups must be stored outside the repository.'
}

$timestamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$backupSet = Join-Path $backupRoot "cascade-n8n-$timestamp"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "cascade-n8n-backup-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $backupSet, $tempRoot | Out-Null
Set-Content -LiteralPath (Join-Path $backupSet 'INCOMPLETE') -Value 'Backup has not completed.' -Encoding utf8NoBOM

$wasRunning = (& docker inspect --format '{{.State.Running}}' $appContainer 2>$null) -eq 'true'
if ($LASTEXITCODE -ne 0) { throw "Expected container is missing: $appContainer" }
$stoppedForBackup = $false

try {
  if ($wasRunning) {
    Invoke-Checked 'docker-compose' @('--project-name', 'cascade-n8n', '--env-file', $EnvFile, '-f', $ComposeFile, 'stop', 'n8n') 'Failed to quiesce n8n'
    $stoppedForBackup = $true
  }

  $databaseDump = Join-Path $tempRoot 'cascade-postgres.dump'
  $dataArchive = Join-Path $tempRoot 'cascade-n8n-data.tar.gz'
  $filesArchive = Join-Path $tempRoot 'cascade-files.tar.gz'
  $environmentCopy = Join-Path $tempRoot 'cascade-environment.env'
  $metadataFile = Join-Path $tempRoot 'recovery-metadata.json'

  $dumpArguments = @(
    '--project-name', 'cascade-n8n', '--env-file', $EnvFile, '-f', $ComposeFile,
    'exec', '-T', 'postgres', 'sh', '-c',
    'exec pg_dump --format=custom --no-owner --no-acl --username="$POSTGRES_USER" --dbname="$POSTGRES_DB"'
  )
  Invoke-BinaryCapture 'docker-compose' $dumpArguments $databaseDump 'PostgreSQL backup failed'

  $counts = & docker-compose --project-name cascade-n8n --env-file $EnvFile -f $ComposeFile exec -T postgres sh -c 'psql -At --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" -c "select json_build_object(''workflow_count'', count(*), ''active_workflow_count'', count(*) filter (where active), ''credential_count'', (select count(*) from credentials_entity)) from workflow_entity;"'
  if ($LASTEXITCODE -ne 0) { throw 'Could not inventory recoverable n8n records.' }
  $countObject = $counts | ConvertFrom-Json
  $imageDigest = (& docker image inspect n8nio/n8n:2.37.10 --format '{{index .RepoDigests 0}}').Trim()
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($imageDigest)) { throw 'Could not resolve the n8n image digest.' }
  [ordered]@{
    schema_version = 1
    captured_at = [DateTimeOffset]::UtcNow.ToString('o')
    image = 'n8nio/n8n:2.37.10'
    image_digest = $imageDigest
    workflow_count = [int]$countObject.workflow_count
    active_workflow_count = [int]$countObject.active_workflow_count
    credential_count = [int]$countObject.credential_count
    consistent_capture = $true
  } | ConvertTo-Json | Set-Content -LiteralPath $metadataFile -Encoding utf8NoBOM

  Copy-Item -LiteralPath $EnvFile -Destination $environmentCopy
  Invoke-Checked 'docker' @('run', '--rm', '--network', 'none', '--volumes-from', $appContainer, '-v', "${tempRoot}:/backup", 'alpine:3.22.1', 'tar', '-czf', '/backup/cascade-n8n-data.tar.gz', '-C', '/home/node/.n8n', '.') 'n8n data-volume backup failed'
  Invoke-Checked 'docker' @('run', '--rm', '--network', 'none', '-v', "${FilesDirectory}:/source:ro", '-v', "${tempRoot}:/backup", 'alpine:3.22.1', 'tar', '-czf', '/backup/cascade-files.tar.gz', '-C', '/source', '.') 'Files-directory backup failed'

  foreach ($source in @($databaseDump, $dataArchive, $filesArchive, $environmentCopy, $metadataFile)) {
    $destination = Join-Path $backupSet "$([IO.Path]::GetFileName($source)).age"
    Invoke-Checked 'age' @('-r', $AgeRecipient, '-o', $destination, $source) "age encryption failed for $([IO.Path]::GetFileName($source))"
  }

  Get-ChildItem -LiteralPath $backupSet -Filter '*.age' -File |
    Sort-Object Name |
    Get-FileHash -Algorithm SHA256 |
    ForEach-Object { "$($_.Hash.ToLowerInvariant())  $([IO.Path]::GetFileName($_.Path))" } |
    Set-Content -LiteralPath (Join-Path $backupSet 'SHA256SUMS') -Encoding ascii
  Remove-Item -LiteralPath (Join-Path $backupSet 'INCOMPLETE')
  Set-Content -LiteralPath (Join-Path $backupSet 'COMPLETE') -Value $timestamp -Encoding ascii
  Write-Output "Encrypted Cascade backup created: $backupSet"
}
finally {
  if ($stoppedForBackup) {
    & docker-compose --project-name cascade-n8n --env-file $EnvFile -f $ComposeFile start n8n
    if ($LASTEXITCODE -ne 0) { Write-Error 'Backup cleanup could not restart n8n; operator action is required.' }
  }
  $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
  $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTemp)) {
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
}
