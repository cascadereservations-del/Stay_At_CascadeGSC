# Uses only the existing local container. Never starts Docker or changes its configuration.
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$container='supabase_db_direct-booking'
$migration=Get-Content -Raw (Join-Path $repoRoot 'supabase/migrations/20260905060000_inventory_forecast_purchase_review.sql')
$suite=Get-Content -Raw (Join-Path $repoRoot 'supabase/tests/database/inventory_forecast_purchase_review.sql')
# Put candidate DDL inside the suite's transaction. Disconnect/error also rolls back.
if ($suite -notmatch '^begin;' -or $suite -notmatch 'rollback;\s*$') { throw 'Rollback-only suite required' }
$batch="begin;`n"+$migration+$suite.Substring(6)
$output=$batch | & docker exec -i $container psql -X -A -t -v ON_ERROR_STOP=1 -U postgres -d postgres 2>&1
$exitCode=$LASTEXITCODE
$output | Write-Output
if ($exitCode -ne 0 -or ($output -join "`n") -match '(?m)^not ok|Looks like you') { throw 'Wave 4 database validation failed' }
if (($output -join "`n") -notmatch '(?m)^1\.\.31\s*$' -or @($output | Where-Object { $_ -match '^ok \d+' }).Count -ne 31) { throw 'Expected 31 pgTAP assertions' }
