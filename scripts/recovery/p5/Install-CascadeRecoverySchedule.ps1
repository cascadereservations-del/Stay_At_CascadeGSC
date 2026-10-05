[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$runner = (Resolve-Path (Join-Path $PSScriptRoot 'Invoke-CascadeRecoverySchedule.ps1')).Path
$powershell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$identity = "$env:USERDOMAIN\$env:USERNAME"

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Hours 3)
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited

$backupAction = New-ScheduledTaskAction -Execute $powershell `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runner`" -Mode Backup"
$backupTrigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek Sunday -At '08:00'
$backup = New-ScheduledTask -Action $backupAction -Trigger $backupTrigger -Settings $settings -Principal $principal `
  -Description 'Encrypted Cascade Supabase backup via Git Bash and Alfred. Runs as Lloyd while logged on.'
Register-ScheduledTask -TaskName 'Cascade Supabase Weekly Backup' -InputObject $backup -Force | Out-Null

$restoreAction = New-ScheduledTaskAction -Execute $powershell `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runner`" -Mode Restore -MonthlyGate"
$restoreTrigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek Sunday -At '09:00'
$restore = New-ScheduledTask -Action $restoreAction -Trigger $restoreTrigger -Settings $settings -Principal $principal `
  -Description 'First-Sunday disposable restore drill of the latest COMPLETE Cascade backup via Alfred.'
Register-ScheduledTask -TaskName 'Cascade Supabase Monthly Restore Drill' -InputObject $restore -Force | Out-Null

# SPEC-40: guest ID photo backup (daily, encrypted, incremental) and its monthly restore drill. Heartbeats
# guest-id-photos-backup / guest-id-photos-drill are watched by job-heartbeat-monitor.
$photosAction = New-ScheduledTaskAction -Execute $powershell `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runner`" -Mode Photos"
$photosTrigger = New-ScheduledTaskTrigger -Daily -At '08:20'
$photos = New-ScheduledTask -Action $photosAction -Trigger $photosTrigger -Settings $settings -Principal $principal `
  -Description 'Encrypted incremental backup of the guest-id-photos bucket (monthly full set), mirrored to Alfred, plus the queued orphan purge. Runs as Lloyd while logged on.'
Register-ScheduledTask -TaskName 'Cascade Guest ID Photos Daily Backup' -InputObject $photos -Force | Out-Null

$photosDrillAction = New-ScheduledTaskAction -Execute $powershell `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runner`" -Mode PhotosDrill -MonthlyGate"
$photosDrillTrigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek Sunday -At '09:30'
$photosDrill = New-ScheduledTask -Action $photosDrillAction -Trigger $photosDrillTrigger -Settings $settings -Principal $principal `
  -Description 'First-Sunday in-memory restore drill of the newest guest ID photo chain: decrypt, coverage of the live bucket, Alfred copy.'
Register-ScheduledTask -TaskName 'Cascade Guest ID Photos Monthly Drill' -InputObject $photosDrill -Force | Out-Null

Get-ScheduledTask -TaskName 'Cascade Supabase Weekly Backup', 'Cascade Supabase Monthly Restore Drill', 'Cascade Guest ID Photos Daily Backup', 'Cascade Guest ID Photos Monthly Drill' |
  Select-Object TaskName, State
