# Deploy-1 live probe for telegram-cassy. Run from PowerShell 5.1 after the deploy.
# Posts a synthetic Telegram update into the FINANCE chat so Cassy replies there; you read it on your phone.
# Usage:  .\probe.ps1 -Secret '<TELEGRAM_WEBHOOK_SECRET>' -Text 'Cassy, who arrives this week?'
param(
  [Parameter(Mandatory=$true)][string]$Secret,
  [string]$ChatId = '-1003819352746',
  [string]$Text = 'Cassy, who arrives this week?'
)
$body = @{ update_id = [int](Get-Date -UFormat %s); message = @{ message_id = 1; text = $Text; chat = @{ id = [long]$ChatId; type = 'supergroup' }; from = @{ id = 1; first_name = 'probe' } } } | ConvertTo-Json -Depth 5
$r = Invoke-RestMethod -Method Post -Uri 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/telegram-cassy' -Headers @{ 'X-Telegram-Bot-Api-Secret-Token' = $Secret } -ContentType 'application/json' -Body $body
$r | ConvertTo-Json -Compress
