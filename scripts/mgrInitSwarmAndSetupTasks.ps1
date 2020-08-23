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

    [Parameter(Mandatory = $True)]
    [string]
    $externaldns,
   
    [Parameter(Mandatory = $True)]
    [string]
    $email,

    [Parameter(Mandatory = $False)]
    [switch]
    $isFirstMgr,

    [Parameter(Mandatory = $True)]
    [string]
    $storageAccountName,

    [Parameter(Mandatory = $True)]
    [string]
    $storageAccountKey,

    [Parameter(Mandatory = $True)]
    [string]
    $adminPwd
)

New-Item -Path c:\scripts -ItemType Directory | Out-Null	

# Make sure the latest Docker EE is installed
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Install-Module DockerMsftProvider -Force
Install-Package Docker -ProviderName DockerMsftProvider -Force
Start-Service docker

# Swarm setup
New-NetFirewallRule -DisplayName "Allow Swarm TCP" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 2377, 7946 | Out-Null
New-NetFirewallRule -DisplayName "Allow Swarm UDP" -Direction Inbound -Action Allow -Protocol UDP -LocalPort 4789, 7946 | Out-Null

if ($isFirstMgr) {
    Invoke-Expression "docker swarm init --advertise-addr 10.0.3.4 --default-addr-pool 10.10.0.0/16"

    # Store password as secret
    Out-File -FilePath ".\adminPwd" -NoNewline -InputObject $adminPwd -Encoding ascii
    docker secret create adminPwd ".\adminPwd"
    Remove-Item ".\adminPwd"

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
            
            $joinCommandMgr = "docker swarm join --token $tokenMgr 10.0.3.4:2377"
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
}
else {
    $tries = 1
    while ($tries -le 10) { 
        try {
            Write-Host "get join command (try $tries)"
            $response = Invoke-WebRequest -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' -Method GET -Headers @{Metadata = "true" } -UseBasicParsing
            $content = $response.Content | ConvertFrom-Json
            $KeyVaultToken = $content.access_token
            $secretJson = (Invoke-WebRequest -Uri https://$name-vault.vault.azure.net/secrets/JoinCommandMgr?api-version=2016-10-01 -Method GET -Headers @{Authorization = "Bearer $KeyVaultToken" } -UseBasicParsing).content | ConvertFrom-Json
            $tries = 11
        }
        catch {
            Write-Host "Vault maybe not there yet, could still be deploying (try $tries)"
            Write-Host $_.Exception
        }
        finally {
            if ($tries -le 10) {
                Write-Host "Increase tries and try again"
                $tries = $tries + 1
                Start-Sleep -Seconds 30
            }
        }
    }
    $tries = 1
    while ($tries -le 10) { 
        try {
            Write-Host "try to join (try $tries): $($secretJson.value)"
            $job = start-job -ScriptBlock { 
                Param ($joinCommand)
                Invoke-Expression "$joinCommand"
            } -ArgumentList $secretJson.value
            $counter = 0
            while (($job.State -like "Running") -and ($counter -lt 4)) {
                Write-Host "check $counter"
                Start-Sleep -Seconds 10
                $counter = $counter + 1
            }
            if ($Job.State -like "Running") { $job | Stop-Job }
            $jobResult = ($job | Receive-Job)
            Write-Host "Swarm join result: $jobResult"
            $job | Remove-Job

            Write-Host "check node status (try $tries)"
            $job = start-job { docker info --format '{{.Swarm.LocalNodeState}}' } 
            $counter = 0
            while (($job.State -like "Running") -and ($counter -lt 4)) {
                Write-Host "check $counter"
                Start-Sleep -Seconds 10
                $counter = $counter + 1
            }
            if ($Job.State -like "Running") { $job | Stop-Job }
            $jobResult = ($job | Receive-Job)
            Write-Host "Docker info LocalNodeState result: $jobResult"
            $job | Remove-Job

            if ($jobResult -eq 'active') {
                Write-Host "Successfully joined"
                $tries = 11
            }
            else {
                Write-Host "Join didn't work, trying to leave"
                docker swarm leave
            }   
        }
        catch {
            Write-Host "Error trying to join (try $tries)"
            Write-Host $_.Exception
        }
        finally {
            if ($tries -le 10) {
                Write-Host "Increase tries and try again"
                $tries = $tries + 1
                Start-Sleep -Seconds 30
            }
        } 
    }
}

# Setup profile
if (!(Test-Path -Path $PROFILE.AllUsersAllHosts)) {
    New-Item -ItemType File -Path $PROFILE.AllUsersAllHosts -Force
}
"function prompt {`"PS [`$env:COMPUTERNAME]:`$(`$executionContext.SessionState.Path.CurrentLocation)`$('>' * (`$nestedPromptLevel + 1)) `"}" | Out-File $PROFILE.AllUsersAllHosts

# Setup tasks
Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/cosmoconsult/azure-swarm/$branch/scripts/mgrConfig.ps1" -OutFile c:\scripts\mgrConfig.ps1
Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/cosmoconsult/azure-swarm/$branch/scripts/mountAzFileShare.ps1" -OutFile c:\scripts\mountAzFileShare.ps1

& 'c:\scripts\mgrConfig.ps1' -name "$name" -externaldns "$externaldns" -email "$email" -additionalScript "$additionalScript" -branch "$branch" -storageAccountName "$storageAccountName" -storageAccountKey "$storageAccountKey" -isFirstMgr:$isFirstMgr 2>&1 >> c:\scripts\log.txt

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Unrestricted -Command `"& 'c:\scripts\mgrConfig.ps1' -name $name -externaldns '$externaldns' -email '$email' -additionalScript '$additionalScript' -branch '$branch' -storageAccountName '$storageAccountName' -storageAccountKey '$storageAccountKey' -isFirstMgr:`$$isFirstMgr -restart`" 2>&1 >> c:\scripts\log.txt"
$trigger = New-ScheduledTaskTrigger -AtStartup -RandomDelay 00:00:30
$principal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -TaskName "MgrConfigReboot" -Description "This task should configure the manager after a reboot"