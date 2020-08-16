param(
    [Parameter(Mandatory = $False)]
    [string]
    $images = "",

    [Parameter(Mandatory = $True)]
    [string]
    $name,

    [Parameter(Mandatory = $True)]
    [string]
    $branch,
    
    [Parameter(Mandatory = $False)]
    [string]
    $additionalScript = "",

    [Parameter(Mandatory=$True)]
    [string]
    $externaldns,
   
    [Parameter(Mandatory=$True)]
    [string]
    $email,

    [Parameter(Mandatory=$False)]
    [switch]
    $isLeader
)

New-Item -Path c:\iac -ItemType Directory | Out-Null	
New-Item -Path c:\iac\le -ItemType Directory | Out-Null	
New-Item -Path c:\iac\le\acme.json | Out-Null

# Swarm setup
New-NetFirewallRule -DisplayName "Allow Swarm TCP" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 2377, 7946 | Out-Null
New-NetFirewallRule -DisplayName "Allow Swarm UDP" -Direction Inbound -Action Allow -Protocol UDP -LocalPort 4789, 7946 | Out-Null

if (isLeader) {
    Invoke-Expression "docker swarm init --advertise-addr 10.0.3.4 --default-addr-pool 10.10.0.0/16"

    # Store joinCommand in Azure Key Vault
    $token = Invoke-Expression "docker swarm join-token -q worker"
    $tokenMgr = Invoke-Expression "docker swarm join-token -q manager"
    $tries = 1
    while ($tries -le 10) { 
        try {
            Write-Host "set join commands (try $tries)"
            $response = Invoke-WebRequest -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' -Method GET -Headers @{Metadata = "true" } -UseBasicParsing
            $content = $response.Content | ConvertFrom-Json
            $KeyVaultToken = $content.access_token
            $joinCommand = "docker swarm join --token $token 10.0.3.4:2377"
            $Body = @{
                value = $joinCommand
            }
            Invoke-WebRequest -Uri https://$name-vault.vault.azure.net/secrets/JoinCommand?api-version=2016-10-01 -Method PUT -Headers @{Authorization = "Bearer $KeyVaultToken" } -Body (ConvertTo-Json $Body) -ContentType "application/json" -UseBasicParsing
            
            $joinCommandMgr = "docker swarm join --token $token 10.0.3.4:2377"
            $Body = @{
                value = $joinCommandMgr
            }
            Invoke-WebRequest -Uri https://$name-vault.vault.azure.net/secrets/JoinCommandMgr?api-version=2016-10-01 -Method PUT -Headers @{Authorization = "Bearer $KeyVaultToken" } -Body (ConvertTo-Json $Body) -ContentType "application/json" -UseBasicParsing

            Write-Host "try to read join commands"
            $secretJson = (Invoke-WebRequest -Uri https://$name-vault.vault.azure.net/secrets/JoinCommand?api-version=2016-10-01 -Method GET -Headers @{Authorization = "Bearer $KeyVaultToken" } -UseBasicParsing).content | ConvertFrom-Json
            $secretJsonMgr = (Invoke-WebRequest -Uri https://$name-vault.vault.azure.net/secrets/JoinCommandMgr?api-version=2016-10-01 -Method GET -Headers @{Authorization = "Bearer $KeyVaultToken" } -UseBasicParsing).content | ConvertFrom-Json

            if ($secretJson.value -eq $joinCommand -and $secretJsonMgr.value -eq $joinCommandMgr) {
                $tries = 11
            }
        }
        catch {
            Write-Host "Vault maybe not there yet, could still be deploying (try $tries)"
            Write-Host $_.Exception
            $tries = $tries + 1
            Start-Sleep -Seconds 30
        }
    }
} else {
    $tries = 1
    while ($tries -le 10) { 
        try {
            Write-Host "get join command (try $tries)"
            $response = Invoke-WebRequest -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' -Method GET -Headers @{Metadata = "true" } -UseBasicParsing
            $content = $response.Content | ConvertFrom-Json
            $KeyVaultToken = $content.access_token
            $secretJson = (Invoke-WebRequest -Uri https://$name-vault.vault.azure.net/secrets/JoinCommandMgr?api-version=2016-10-01 -Method GET -Headers @{Authorization = "Bearer $KeyVaultToken" } -UseBasicParsing).content | ConvertFrom-Json
            
            Write-Host "join"
            Invoke-Expression $secretJson.value 
            $tries = 11
        }
        catch {
            Write-Host "Vault maybe not there yet, could still be deploying (try $tries)"
            Write-Host $_.Exception
            $tries = $tries + 1
            Start-Sleep -Seconds 30
        }
    }
}




# Setup tasks
Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/cosmoconsult/azure-swarm/$branch/scripts/mgrConfig.ps1" -OutFile c:\iac\mgrConfig.ps1

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Unrestricted -Command `"& 'c:\iac\mgrConfig.ps1' -name $name -externaldns '$externaldns' -email '$email' -additionalScript '$additionalScript' -branch '$branch' -isLeader:$isLeader`" 2>&1 >> c:\iac\log.txt"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10)
$principal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -TaskName "MgrConfig" -Description "This task should configure the manager"

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Unrestricted -Command `"& 'c:\iac\mgrConfig.ps1' -name $name -externaldns '$externaldns' -email '$email' -additionalScript '$additionalScript' -branch '$branch' -isLeader:$isLeader -restart`" 2>&1 >> c:\iac\log.txt"
$trigger = New-ScheduledTaskTrigger -AtStartup -RandomDelay 00:00:30
$principal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -TaskName "MgrConfigReboot" -Description "This task should configure the manager after a reboot"