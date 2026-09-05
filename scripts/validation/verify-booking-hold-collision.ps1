param(
  [string]$Container = 'supabase_db_direct-booking'
)

$ErrorActionPreference = 'Stop'
$database = 'cascade_module_e_collision'
$dumpPath = '/tmp/cascade-module-e-collision.dump'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$migrationPath = Join-Path $repoRoot 'supabase\migrations\20260905030000_booking_lifecycle.sql'

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
  if ($exitCode -ne 0) {
    throw ($output -join "`n")
  }
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
    & docker exec -i $Container psql -v ON_ERROR_STOP=1 -U postgres -d $database | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Module E migration failed in disposable database' }

  $fixture = @"
insert into public.properties(id,name,is_active)
values('91000000-0000-4000-8000-000000000001','Concurrent Hold Property',true)
on conflict(id) do nothing;
insert into public.booking_inquiries(id,property_id,guest_name,checkin_date,checkout_date,source,status)
values
 ('93000000-0000-4000-8000-000000000001','91000000-0000-4000-8000-000000000001','Collision Winner',current_date+200,current_date+203,'direct','pending'),
 ('93000000-0000-4000-8000-000000000002','91000000-0000-4000-8000-000000000001','Collision Loser',current_date+201,current_date+204,'direct','pending');
"@
  $fixture | & docker exec -i $Container psql -v ON_ERROR_STOP=1 -U postgres -d $database | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Collision fixtures failed' }

  $firstSql = "begin; set role service_role; select public.create_booking_hold('93000000-0000-4000-8000-000000000001',now()+interval '30 minutes','module-e-concurrent-hold-01'); select pg_sleep(2); commit;"
  $secondSql = "set role service_role; select public.create_booking_hold('93000000-0000-4000-8000-000000000002',now()+interval '30 minutes','module-e-concurrent-hold-02');"
  $first = Start-Job -ScriptBlock {
    param($ContainerName,$DatabaseName,$Sql)
    $ErrorActionPreference = 'Continue'
    & docker exec $ContainerName psql -v ON_ERROR_STOP=1 -U postgres -d $DatabaseName -c $Sql 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE }
  } -ArgumentList $Container,$database,$firstSql

  Start-Sleep -Milliseconds 350
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $previousErrorPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $secondOutput = & docker exec $Container psql -v ON_ERROR_STOP=1 -U postgres -d $database -c $secondSql 2>&1
  $secondExit = $LASTEXITCODE
  $ErrorActionPreference = $previousErrorPreference
  $watch.Stop()
  Wait-Job -Job $first | Out-Null
  $firstOutput = Receive-Job -Job $first
  Remove-Job -Job $first
  $firstExit = ($firstOutput | Where-Object { $_ -is [pscustomobject] } | Select-Object -Last 1).ExitCode

  if ($firstExit -ne 0) { throw 'Winning session failed' }
  if ($secondExit -eq 0 -or ($secondOutput -join "`n") -notmatch 'booking dates unavailable') {
    throw 'Competing session did not fail closed on the overlapping hold'
  }
  if ($watch.ElapsedMilliseconds -lt 1000) {
    throw 'Competing session did not wait for the property transaction lock'
  }

  $verification = Invoke-Docker @(
    'exec',$Container,'psql','-At','-v','ON_ERROR_STOP=1','-U','postgres','-d',$database,
    '-c',"select count(*) || ':' || count(*) filter (where status='active') from public.booking_holds;"
  )
  if (($verification -join '').Trim() -ne '1:1') {
    throw 'Collision test did not leave exactly one active hold'
  }

  Write-Output ("PASS concurrent hold collision: loser waited {0} ms; exactly one active hold" -f $watch.ElapsedMilliseconds)
}
finally {
  $ErrorActionPreference = 'Continue'
  & docker exec $Container dropdb --if-exists --force -U postgres $database 2>&1 | Out-Null
  & docker exec $Container rm -f $dumpPath 2>&1 | Out-Null
}
