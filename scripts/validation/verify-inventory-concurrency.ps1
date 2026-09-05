param(
  [string]$Container = 'supabase_db_direct-booking'
)

$ErrorActionPreference = 'Stop'
$database = 'cascade_wave4_concurrency'
$dumpPath = '/tmp/cascade-wave4-concurrency.dump'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$migrationPath = Join-Path $repoRoot 'supabase/migrations/20260905060000_inventory_forecast_purchase_review.sql'
$rollbackPath = Join-Path $repoRoot 'supabase/rollbacks/20260905060000_inventory_forecast_purchase_review.sql'
$movementJob = $null

function Invoke-Docker([string[]]$Arguments) {
  $previousErrorPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & docker @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousErrorPreference
  }
  if ($exitCode -ne 0) { throw ($output -join "`n") }
  return $output
}

try {
  Invoke-Docker @('exec',$Container,'pg_dump','--format=custom','--no-owner','--no-privileges','-U','postgres','-d','postgres','-f',$dumpPath) | Out-Null
  Invoke-Docker @('exec',$Container,'dropdb','--if-exists','--force','-U','postgres',$database) | Out-Null
  Invoke-Docker @('exec',$Container,'createdb','-U','postgres',$database) | Out-Null
  Invoke-Docker @(
    'exec',$Container,'pg_restore','--no-owner','--no-privileges',
    '--exclude-schema=realtime','--exclude-schema=vault',
    '-U','postgres','-d',$database,$dumpPath
  ) | Out-Null

  Get-Content -Raw -LiteralPath $migrationPath |
    & docker exec -i $Container psql -X -v ON_ERROR_STOP=1 -U postgres -d $database | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Wave 4 migration failed in disposable database' }

  $fixture = @"
insert into public.properties(id,name,is_active)
values('d1000000-0000-4000-8000-000000000001','Concurrent Inventory Property',true);
insert into auth.users(id) values('d2000000-0000-4000-8000-000000000001');
insert into public.staff_access_profiles(user_id,role)
values('d2000000-0000-4000-8000-000000000001','admin');
insert into public.staff_property_access(user_id,property_id)
values('d2000000-0000-4000-8000-000000000001','d1000000-0000-4000-8000-000000000001');
insert into public.inventory_items(id,property_id,name,category,qty_on_hand)
values('d3000000-0000-4000-8000-000000000001','d1000000-0000-4000-8000-000000000001','Concurrent soap','Supplies',20);
set role authenticated;
set request.jwt.claims='{"sub":"d2000000-0000-4000-8000-000000000001","aal":"aal2"}';
select public.record_inventory_movement('d3000000-0000-4000-8000-000000000001','reconcile',20,'Opening concurrent count','wave4-concurrent-open-01');
select public.record_inventory_movement('d3000000-0000-4000-8000-000000000001','usage',-14,'Concurrent baseline usage','wave4-concurrent-use-001');
select public.forecast_inventory('d3000000-0000-4000-8000-000000000001',7,14,'wave4-concurrent-forecast');
reset role;
"@
  $fixture | & docker exec -i $Container psql -X -v ON_ERROR_STOP=1 -U postgres -d $database | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Wave 4 concurrency fixtures failed' }

  $forecastId = (Invoke-Docker @(
    'exec',$Container,'psql','-X','-A','-t','-v','ON_ERROR_STOP=1','-U','postgres','-d',$database,
    '-c',"select id from public.inventory_forecasts where idempotency_key='wave4-concurrent-forecast'"
  ) | Select-Object -Last 1).Trim()
  if ($forecastId -notmatch '^[0-9a-f-]{36}$') { throw 'Could not resolve disposable forecast ID' }

  $claims = '{"sub":"d2000000-0000-4000-8000-000000000001","aal":"aal2"}'
  $movementSql = "begin; set role authenticated; set request.jwt.claims='$claims'; select 'LOCK_READY:' || public.record_inventory_movement('d3000000-0000-4000-8000-000000000001','receipt',1,'Concurrent stock receipt','wave4-concurrent-receipt')::text; select pg_sleep(5); commit;"
  $reviewSql = "set role authenticated; set request.jwt.claims='$claims'; select public.review_inventory_purchase('$forecastId','approved',22,'Concurrent stale review','wave4-concurrent-review1');"

  $movementJob = Start-Job -ScriptBlock {
    param($ContainerName,$DatabaseName,$Sql)
    $ErrorActionPreference = 'Continue'
    $Sql | & docker exec -i $ContainerName psql -X -v ON_ERROR_STOP=1 -U postgres -d $DatabaseName 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE }
  } -ArgumentList $Container,$database,$movementSql

  $movementReady = $false
  foreach ($attempt in 1..100) {
    $movementProgress = Receive-Job -Job $movementJob -Keep
    if (($movementProgress -join "`n") -match 'LOCK_READY:') { $movementReady = $true; break }
    if ($movementJob.State -ne 'Running') { break }
    Start-Sleep -Milliseconds 100
  }
  if (-not $movementReady) {
    $movementProgress = Receive-Job -Job $movementJob -Keep
    throw "Stock session did not acquire its item lock in time: $($movementProgress -join "`n")"
  }

  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $previousErrorPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $reviewOutput = $reviewSql | & docker exec -i $Container psql -X -v ON_ERROR_STOP=1 -U postgres -d $database 2>&1
  $reviewExit = $LASTEXITCODE
  $ErrorActionPreference = $previousErrorPreference
  $watch.Stop()

  Wait-Job -Job $movementJob | Out-Null
  $movementOutput = Receive-Job -Job $movementJob
  Remove-Job -Job $movementJob
  $movementJob = $null
  $movementResult = $movementOutput | Where-Object { $_.PSObject.Properties.Name -contains 'ExitCode' } | Select-Object -Last 1
  $movementExit = $movementResult.ExitCode
  if ($movementExit -ne 0) {
    $movementText = ($movementOutput | Where-Object { -not ($_.PSObject.Properties.Name -contains 'ExitCode') }) -join "`n"
    throw "Concurrent stock movement failed (exit $movementExit): $movementText"
  }
  if ($reviewExit -eq 0 -or ($reviewOutput -join "`n") -notmatch 'stale forecast') {
    throw "Concurrent review did not fail closed after stock changed: $($reviewOutput -join "`n")"
  }
  if ($watch.ElapsedMilliseconds -lt 1200) { throw 'Review did not wait for the inventory item lock' }

  $result = Invoke-Docker @(
    'exec',$Container,'psql','-X','-A','-t','-v','ON_ERROR_STOP=1','-U','postgres','-d',$database,
    '-c',"select qty_on_hand,(select count(*) from public.inventory_purchase_reviews) from public.inventory_items where id='d3000000-0000-4000-8000-000000000001'"
  )
  $resultLine = ($result | Select-Object -Last 1).Trim()
  if ($resultLine -ne '7.00|0') { throw "Unexpected concurrency result: $resultLine" }

  Get-Content -Raw -LiteralPath $rollbackPath |
    & docker exec -i $Container psql -X -v ON_ERROR_STOP=1 -U postgres -d $database | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Wave 4 compensating rollback failed in disposable database' }
  $rollbackResult = Invoke-Docker @(
    'exec',$Container,'psql','-X','-A','-t','-v','ON_ERROR_STOP=1','-U','postgres','-d',$database,
    '-c',"select to_regclass('public.inventory_stock_movements') is null and to_regclass('public.inventory_forecasts') is null and to_regclass('public.inventory_purchase_reviews') is null and to_regprocedure('public.inventory_human_authorized(uuid)') is null"
  )
  if (($rollbackResult | Select-Object -Last 1).Trim() -ne 't') { throw 'Wave 4 rollback left candidate objects behind' }

  Write-Output "Wave 4 concurrency proof passed: review waited $($watch.ElapsedMilliseconds) ms, observed committed stock change, and failed closed."
  Write-Output 'Disposable result: canonical stock 7.00; purchase reviews 0.'
  Write-Output 'Compensating rollback passed: Wave 4 tables and authority function removed without CASCADE.'
}
finally {
  $previousErrorPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  if ($null -ne $movementJob) {
    Stop-Job -Job $movementJob | Out-Null
    Remove-Job -Job $movementJob | Out-Null
  }
  & docker exec $Container dropdb --if-exists --force -U postgres $database 2>&1 | Out-Null
  & docker exec $Container rm -f $dumpPath 2>&1 | Out-Null
  $ErrorActionPreference = $previousErrorPreference
}
