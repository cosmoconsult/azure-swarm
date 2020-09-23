param(
    [Parameter(Mandatory = $False)]
    [string]
    $images = "",

    [Parameter(Mandatory = $True)]
    [string]
    $name,

    [Parameter(Mandatory = $False)]
    [switch]
    $restart,
    
    [Parameter(Mandatory = $False)]
    [string]
    $additionalPostScript = "",

    [Parameter(Mandatory = $False)]
    [string]
    $branch = "master",

    [Parameter(Mandatory = $True)]
    [string]
    $storageAccountName,

    [Parameter(Mandatory = $True)]
    [string]
    $storageAccountKey,

    [Parameter(Mandatory = $False)]
    [string]
    $authToken = $null
)

if (-not $restart) {
    # initial
    [DownloadWithRetry]::DoDownloadWithRetry("https://raw.githubusercontent.com/cosmoconsult/azure-swarm/$branch/scripts/mountAzFileShare.ps1", 5, 10, $null, "c:\scripts\mountAzFileShare.ps1", $false)

    $tries = 1
    while ($tries -le 10) { 
        Write-Host "Trying to mount Azure File Share"
        . c:\scripts\mountAzFileShare.ps1 -storageAccountName "$storageAccountName" -storageAccountKey "$storageAccountKey" -driveLetter "S"
        if (Test-Path "S:") {
            $tries = 11
        }
        Write-Host "Try $tries failed"
        $tries = $tries + 1
        Start-Sleep -Seconds 30
    }

    # Setup profile
    Write-Debug "Download profile file"
    [DownloadWithRetry]::DoDownloadWithRetry("https://raw.githubusercontent.com/cosmoconsult/azure-swarm/$branch/scripts/profile.ps1", 5, 10, $null, $PROFILE.AllUsersAllHosts, $false)

    # Choco and SSH
    Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
    choco feature enable -n allowGlobalConfirmation
    choco install --no-progress --limit-output vim
    choco install --no-progress --limit-output openssh -params '"/SSHServerFeature"'
    [DownloadWithRetry]::DoDownloadWithRetry("https://raw.githubusercontent.com/cosmoconsult/azure-swarm/$branch/configs/sshd_config_wpwd", 5, 10, $null, 'C:\ProgramData\ssh\sshd_config', $false)
    New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force
    Restart-Service sshd

    # Swarm setup
    New-NetFirewallRule -DisplayName "Allow Swarm TCP" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 2377, 7946 | Out-Null
    New-NetFirewallRule -DisplayName "Allow Swarm UDP" -Direction Inbound -Action Allow -Protocol UDP -LocalPort 4789, 7946 | Out-Null

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Unrestricted -Command `"& 'c:\scripts\workerConfig.ps1' -name $name -images '$images' -additionalPostScript '$additionalPostScript' -branch '$branch' -storageAccountName '$storageAccountName' -storageAccountKey '$storageAccountKey' -authToken '$authToken' -restart`" 2>&1 >> c:\scripts\log.txt"
    $trigger = New-ScheduledTaskTrigger -AtStartup -RandomDelay 00:00:30
    $principal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -TaskName "WorkerConfigReboot" -Description "This task should configure the worker after a reboot"
}
else {
    Invoke-Expression "docker swarm leave"
}


# Maybe pull images
Write-Host "pull $images"
Invoke-Expression "docker pull portainer/agent:windows1809-amd64" | Out-Null
if (-not [string]::IsNullOrEmpty($images)) {
    $imgArray = $images.Split(',');
    foreach ($img in $imgArray) {
        Write-Host "pull $img"
        Invoke-Expression "docker pull $img" | Out-Null
    }
}

# Join Swarm
Write-Debug "get join command (try $tries)"
$content = [DownloadWithRetry]::DoDownloadWithRetry('http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net', 5, 10, $null, $null, $true) | ConvertFrom-Json
$KeyVaultToken = $content.access_token
$secretJson = [DownloadWithRetry]::DoDownloadWithRetry("https://$name-vault.vault.azure.net/secrets/JoinCommand?api-version=2016-10-01", 30, 10, "Bearer $KeyVaultToken", $null, $false) | ConvertFrom-Json
Write-Debug "join command result: $secretJson"
$tries = 1
while ($tries -le 10) { 
    try {
        Write-Host "try to join (try $tries): $($secretJson.value)"
        $job = start-job -ScriptBlock { 
            Param ($joinCommand)
            Invoke-Expression "$joinCommand"
        } -ArgumentList $secretJson.value
        Write-Debug "Job kicked off, waiting for finish"
        $job | Wait-Job -Timeout 30
        Write-Debug "get job results"
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

if (-not $restart) {
    $tries = 1
    while ($tries -le 10) { 
        try {
            Write-Host "download SSH key"
            $secretJson = [DownloadWithRetry]::DoDownloadWithRetry("https://$name-vault.vault.azure.net/secrets/sshPubKey?api-version=2016-10-01", 5, 10, "Bearer $KeyVaultToken", $null, $false) | ConvertFrom-Json
            Write-Debug "got $secretJson"
            
            $secretJson.value | Out-File 'c:\ProgramData\ssh\administrators_authorized_keys' -Encoding utf8

            ### adapted (pretty much copied) from https://gitlab.com/DarwinJS/ChocoPackages/-/blob/master/openssh/tools/chocolateyinstall.ps1#L433
            $path = "c:\ProgramData\ssh\administrators_authorized_keys"
            $acl = Get-Acl -Path $path
            # following SDDL implies 
            # - owner - built in Administrators
            # - disabled inheritance
            # - Full access to System
            # - Full access to built in Administrators
            $acl.SetSecurityDescriptorSddlForm("O:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)")
            Set-Acl -Path $path -AclObject $acl
            ### end of copy
        
            $tries = 11
        }
        catch {
            Write-Host "Vault maybe not there yet, could still be deploying (try $tries)"
            Write-Host $_.Exception
            $tries = $tries + 1
            Start-Sleep -Seconds 30
        }
    }

    # Handle additional script
    if ($additionalPostScript -ne "") {
        $headers = @{ }
        if (-not ([string]::IsNullOrEmpty($authToken))) {
            $headers = @{
                'Authorization' = $authToken
            }
        }
        [DownloadWithRetry]::DoDownloadWithRetry($additionalPostScript, 5, 10, $authToken, 'c:\scripts\additionalPostScript.ps1', $false)
        & 'c:\scripts\additionalPostScript.ps1' -branch "$branch" -authToken "$authToken"
    }
}
else {
    # Handle additional script
    if ($additionalPostScript -ne "") {
        & 'c:\scripts\additionalPostScript.ps1' -branch "$branch" -authToken "$authToken" -restart 
    }
}

class DownloadWithRetry {
    static [string] DoDownloadWithRetry([string] $uri, [int] $maxRetries, [int] $retryWaitInSeconds, [string] $authToken, [string] $outFile, [bool] $metadata) {
        $retryCount = 0
        $headers = @{}
        if (-not ([string]::IsNullOrEmpty($authToken))) {
            $headers = @{
                'Authorization' = $authToken
            }
        }
        if ($metadata) {
            $headers.Add('Metadata', 'true')
        }
        Write-Host $headers.Count

        while ($retryCount -le $maxRetries) {
            try {
                if ($headers.Count -ne 0) {
                    if ([string]::IsNullOrEmpty($outFile)) {
                        $result = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing
                        return $result.Content
                    }
                    else {
                        $result = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing -OutFile $outFile
                        return ""
                    }
                }
                else {
                    throw;
                }
            }
            catch {
                if ($headers.Count -eq 0) {
                    write-host "download failed"
                }
                try {
                    if ([string]::IsNullOrEmpty($outFile)) {
                        $result = Invoke-WebRequest -Uri $uri -UseBasicParsing
                        return $result.Content
                    }
                    else {
                        $result = Invoke-WebRequest -Uri $uri -UseBasicParsing -OutFile $outFile
                        return ""
                    }
                }
                catch {
                    write-host "download failed"
                    $retryCount++;
                    if ($retryCount -le $maxRetries) {
                        Start-Sleep -Seconds $retryWaitInSeconds
                    }            
                }
            }
        }
        return ""
    }
}