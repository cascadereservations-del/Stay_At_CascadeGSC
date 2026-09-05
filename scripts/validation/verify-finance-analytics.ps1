param([string]$Container='supabase_db_direct-booking')

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$migrationPath=Join-Path $repoRoot 'supabase/migrations/20260905070000_finance_reconciliation_analytics.sql'
$testPath=Join-Path $repoRoot 'supabase/tests/database/finance_reconciliation_analytics.sql'
$rollbackPath=Join-Path $repoRoot 'supabase/rollbacks/20260905070000_finance_reconciliation_analytics.sql'
$database='cascade_wave5_rollback'
$dumpPath='/tmp/cascade-wave5-rollback.dump'

function Invoke-Docker([string[]]$Arguments) {
  $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
  try {$output=& docker @Arguments 2>&1;$exitCode=$LASTEXITCODE} finally {$ErrorActionPreference=$previous}
  if($exitCode -ne 0){throw ($output -join "`n")};return $output
}

$migration=Get-Content -Raw -LiteralPath $migrationPath
$suite=Get-Content -Raw -LiteralPath $testPath
if($suite -notmatch '^begin;' -or $suite -notmatch 'rollback;\s*$'){throw 'Rollback-only suite required'}
$batch="begin;`n"+$migration+$suite.Substring(6)
$output=$batch | & docker exec -i $Container psql -X -A -t -v ON_ERROR_STOP=1 -U postgres -d postgres 2>&1
if($LASTEXITCODE -ne 0 -or ($output -join "`n") -match '(?m)^not ok|Looks like you'){throw ($output -join "`n")}
if(($output -join "`n") -notmatch '(?m)^1\.\.50\s*$' -or @($output|Where-Object{$_ -match '^ok \d+'}).Count -ne 50){throw 'Expected 50 pgTAP assertions'}
Write-Output 'Wave 5 pgTAP passed: 50/50; candidate DDL and fixtures rolled back.'

try {
  Invoke-Docker @('exec',$Container,'pg_dump','--format=custom','--no-owner','--no-privileges','-U','postgres','-d','postgres','-f',$dumpPath)|Out-Null
  Invoke-Docker @('exec',$Container,'dropdb','--if-exists','--force','-U','postgres',$database)|Out-Null
  Invoke-Docker @('exec',$Container,'createdb','-U','postgres',$database)|Out-Null
  Invoke-Docker @('exec',$Container,'pg_restore','--no-owner','--no-privileges','--exclude-schema=realtime','--exclude-schema=vault','-U','postgres','-d',$database,$dumpPath)|Out-Null
  $migration | & docker exec -i $Container psql -X -v ON_ERROR_STOP=1 -U postgres -d $database | Out-Null
  if($LASTEXITCODE -ne 0){throw 'Wave 5 migration failed in disposable database'}
  Get-Content -Raw -LiteralPath $rollbackPath | & docker exec -i $Container psql -X -v ON_ERROR_STOP=1 -U postgres -d $database | Out-Null
  if($LASTEXITCODE -ne 0){throw 'Wave 5 rollback failed in disposable database'}
  $check=Invoke-Docker @('exec',$Container,'psql','-X','-A','-t','-v','ON_ERROR_STOP=1','-U','postgres','-d',$database,'-c',"select to_regclass('public.finance_reconciliation_candidates') is null and to_regclass('public.finance_reconciled_facts') is null and to_regclass('public.management_target_versions') is null and to_regprocedure('public.get_management_metrics(uuid,date,date)') is null")
  if(($check|Select-Object -Last 1).Trim() -ne 't'){throw 'Wave 5 rollback left candidate objects behind'}
  Write-Output 'Wave 5 compensating rollback passed in a disposable restored database.'
}
finally {
  $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
  & docker exec $Container dropdb --if-exists --force -U postgres $database 2>&1|Out-Null
  & docker exec $Container rm -f $dumpPath 2>&1|Out-Null
  $ErrorActionPreference=$previous
}
