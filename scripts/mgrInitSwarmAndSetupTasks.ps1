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
    $additionalPreScript = "",
    
    [Parameter(Mandatory = $False)]
    [string]
    $additionalPostScript = "",

    [Parameter(Mandatory = $True)]
    [string]
    $externaldns,

    [Parameter(Mandatory = $False)]
    [string]
    $dockerdatapath = "C:/ProgramData/docker",
   
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
    $adminPwd,

    [Parameter(Mandatory = $False)]
    [string]
    $authToken = $null,

    [Parameter(Mandatory = $False)]
    [string]
    $debugScripts
)

if ($debugScripts -eq "true") {
    New-Item -ItemType File -Path "c:\enableDebugging"
    $DebugPreference = "Continue"
}

Write-Debug "Created folder"
New-Item -Path c:\scripts -ItemType Directory | Out-Null	

Write-Debug "Make sure the latest Docker EE is installed"
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Install-Module DockerMsftProvider -Force
Install-Package Docker -ProviderName DockerMsftProvider -Force
Start-Service docker

Write-Debug "Setup data disk"
$disks = Get-Disk | Where-Object partitionstyle -eq 'raw' | Sort-Object number
$letters = 70..89 | ForEach-Object { [char]$_ }
$count = 0
$labels = "data1", "data2"

foreach ($disk in $disks) {
    $driveLetter = $letters[$count].ToString()
    $disk | 
    Initialize-Disk -PartitionStyle MBR -PassThru |
    New-Partition -UseMaximumSize -DriveLetter $driveLetter |
    Format-Volume -FileSystem NTFS -NewFileSystemLabel $labels[$count] -Confirm:$false -Force
    $count++
}

Write-Debug "Handle additional pre script"
if ($additionalPreScript -ne "") {
    $headers = @{ }
    if (-not ([string]::IsNullOrEmpty($authToken))) {
        $headers = @{
            'Authorization' = $authToken
        }
    }
    Write-Debug "Download script"
    try { Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri $additionalPreScript -OutFile 'c:\scripts\additionalPreScript.ps1' }
    catch { Invoke-WebRequest -UseBasicParsing -Uri $additionalPreScript -OutFile 'c:\scripts\additionalPreScript.ps1' }
    
    Write-Debug "Call script"
    & 'c:\scripts\additionalPreScript.ps1' -branch "$branch" -isFirstMgr:$isFirstMgr -authToken "$authToken"
}

Write-Debug "Swarm firewall setup"
New-NetFirewallRule -DisplayName "Allow Swarm TCP" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 2377, 7946 | Out-Null
New-NetFirewallRule -DisplayName "Allow Swarm UDP" -Direction Inbound -Action Allow -Protocol UDP -LocalPort 4789, 7946 | Out-Null

if ($isFirstMgr) {
    Write-Debug "First manager, initialize swarm"
    Invoke-Expression "docker swarm init --advertise-addr 10.0.3.4 --default-addr-pool 10.10.0.0/16"

    Write-Debug "Store password as secret"
    Out-File -FilePath ".\adminPwd" -NoNewline -InputObject $adminPwd -Encoding ascii
    docker secret create adminPwd ".\adminPwd"
    Remove-Item ".\adminPwd"

    Write-Debug "Store joinCommand in Azure Key Vault"
    $token = Invoke-Expression "docker swarm join-token -q worker"
    $tokenMgr = Invoke-Expression "docker swarm join-token -q manager"
    $tries = 1
    while ($tries -le 10) { 
        try {
            Write-Debug "set join commands (try $tries)"
            $response = Invoke-WebRequest -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' -Method GET -Headers @{Metadata = "true" } -UseBasicParsing
            $content = $response.Content | ConvertFrom-Json
            $KeyVaultToken = $content.access_token
            $joinCommand = "docker swarm join --token $token 10.0.3.4:2377"
            $Body = @{
                value = $joinCommand
            }
            $result = Invoke-WebRequest -Uri https://$name-vault.vault.azure.net/secrets/JoinCommand?api-version=2016-10-01 -Method PUT -Headers @{Authorization = "Bearer $KeyVaultToken" } -Body (ConvertTo-Json $Body) -ContentType "application/json" -UseBasicParsing
            Write-Debug $result
            
            $joinCommandMgr = "docker swarm join --token $tokenMgr 10.0.3.4:2377"
            $Body = @{
                value = $joinCommandMgr
            }
            $result = Invoke-WebRequest -Uri https://$name-vault.vault.azure.net/secrets/JoinCommandMgr?api-version=2016-10-01 -Method PUT -Headers @{Authorization = "Bearer $KeyVaultToken" } -Body (ConvertTo-Json $Body) -ContentType "application/json" -UseBasicParsing
            Write-Debug $result

            Write-Debug "try to read join commands"
            $secretJson = (Invoke-WebRequest -Uri https://$name-vault.vault.azure.net/secrets/JoinCommand?api-version=2016-10-01 -Method GET -Headers @{Authorization = "Bearer $KeyVaultToken" } -UseBasicParsing).content | ConvertFrom-Json
            Write-Debug "worker join command result: $secretJson"
            $secretJsonMgr = (Invoke-WebRequest -Uri https://$name-vault.vault.azure.net/secrets/JoinCommandMgr?api-version=2016-10-01 -Method GET -Headers @{Authorization = "Bearer $KeyVaultToken" } -UseBasicParsing).content | ConvertFrom-Json
            Write-Debug "manager join command result: $secretJsonMgr"

            if ($secretJson.value -eq $joinCommand -and $secretJsonMgr.value -eq $joinCommandMgr) {
                Write-Debug "join commands are matching"
                $tries = 11
            }
        }
        catch {
            Write-Host "Vault maybe not there yet, could still be deploying (try $tries)"
            Write-Debug $_.Exception
            $tries = $tries + 1
            Start-Sleep -Seconds 30
        }
    }
}
else {
    $tries = 1
    while ($tries -le 10) { 
        try {
            Write-Debug "get join command (try $tries)"
            $response = Invoke-WebRequest -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' -Method GET -Headers @{Metadata = "true" } -UseBasicParsing
            $content = $response.Content | ConvertFrom-Json
            $KeyVaultToken = $content.access_token
            $secretJson = (Invoke-WebRequest -Uri https://$name-vault.vault.azure.net/secrets/JoinCommandMgr?api-version=2016-10-01 -Method GET -Headers @{Authorization = "Bearer $KeyVaultToken" } -UseBasicParsing).content | ConvertFrom-Json
            Write-Debug "join command result: $secretJson"
            $tries = 11
        }
        catch {
            Write-Host "Vault maybe not there yet, could still be deploying (try $tries)"
            Write-Host $_.Exception
        }
        finally {
            if ($tries -le 10) {
                Write-Debug "Increase tries, sleep and try again"
                $tries = $tries + 1
                Start-Sleep -Seconds 30
                Write-Debug "awoke for try $tries"
            }
        }
    }
    $tries = 1
    while ($tries -le 10) { 
        try {
            Write-Debug "try to join (try $tries): $($secretJson.value)"
            $job = start-job -ScriptBlock { 
                Param ($joinCommand)
                Invoke-Expression "$joinCommand"
            } -ArgumentList $secretJson.value
            Write-Debug "Job kicked off, waiting for finish"
            $job | Wait-Job -Timeout 30
            Write-Debug "get job results"
            $jobResult = ($job | Receive-Job)
            Write-Host "Swarm join result: $jobResult"
            Write-Debug "try to remove job"
            $job | Remove-Job

            Write-Debug "check node status (try $tries)"
            $job = start-job { docker info --format '{{.Swarm.LocalNodeState}}' } 
            Write-Debug "Job kicked off, waiting for finish"
            $job | Wait-Job -Timeout 30
            Write-Debug "get job results"
            $jobResult = ($job | Receive-Job)
            Write-Host "Docker info LocalNodeState result: $jobResult"
            Write-Debug "try to remove job"
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
                Write-Debug "Increase tries and try again"
                $tries = $tries + 1
                Start-Sleep -Seconds 30
                Write-Debug "awoke for try $tries"
            }
        } 
    }
}

# Setup profile
if (!(Test-Path -Path $PROFILE.AllUsersAllHosts)) {
    Write-Debug "Create profile file $($PROFILE.AllUsersAllHosts)"
    New-Item -ItemType File -Path $PROFILE.AllUsersAllHosts -Force
}
Write-Debug "Download profile file"
Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/cosmoconsult/azure-swarm/$branch/scripts/profile.ps1" -OutFile $PROFILE.AllUsersAllHosts

# Setup tasks
Write-Debug "Download task files"
Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/cosmoconsult/azure-swarm/$branch/scripts/mgrConfig.ps1" -OutFile c:\scripts\mgrConfig.ps1
Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/cosmoconsult/azure-swarm/$branch/scripts/mountAzFileShare.ps1" -OutFile c:\scripts\mountAzFileShare.ps1

Write-Debug "call mgrConfig script"
& 'c:\scripts\mgrConfig.ps1' -name "$name" -externaldns "$externaldns" -dockerdatapath "$dockerdatapath" -email "$email" -additionalPostScript "$additionalPostScript" -branch "$branch" -storageAccountName "$storageAccountName" -storageAccountKey "$storageAccountKey" -isFirstMgr:$isFirstMgr -authToken "$authToken" 2>&1 >> c:\scripts\log.txt

Write-Debug "set up reboot task"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Unrestricted -Command `"& 'c:\scripts\mgrConfig.ps1' -name $name -externaldns '$externaldns' -dockerdatapath '$dockerdatapath' -email '$email' -additionalPostScript '$additionalPostScript' -branch '$branch' -storageAccountName '$storageAccountName' -storageAccountKey '$storageAccountKey' -isFirstMgr:`$$isFirstMgr -restart -authToken '$authToken'`" 2>&1 >> c:\scripts\log.txt"
$trigger = New-ScheduledTaskTrigger -AtStartup -RandomDelay 00:00:30
$principal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -TaskName "MgrConfigReboot" -Description "This task should configure the manager after a reboot"