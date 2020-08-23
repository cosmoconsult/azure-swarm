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
    $additionalScript = "",

    [Parameter(Mandatory = $False)]
    [string]
    $branch = "master",

    [Parameter(Mandatory = $True)]
    [string]
    $storageAccountName,

    [Parameter(Mandatory = $True)]
    [string]
    $storageAccountKey
)

if (-not $restart) {
    # Choco and SSH
    Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
    choco feature enable -n allowGlobalConfirmation
    choco install --no-progress --limit-output vim
    choco install --no-progress --limit-output openssh -params '"/SSHServerFeature"'
    Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/cosmoconsult/azure-swarm/$branch/configs/sshd_config_wpwd" -OutFile C:\ProgramData\ssh\sshd_config
    New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force
    Restart-Service sshd

    # Swarm setup
    New-NetFirewallRule -DisplayName "Allow Swarm TCP" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 2377, 7946 | Out-Null
    New-NetFirewallRule -DisplayName "Allow Swarm UDP" -Direction Inbound -Action Allow -Protocol UDP -LocalPort 4789, 7946 | Out-Null
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
Write-Host "get join command"
$response = Invoke-WebRequest -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' -Method GET -Headers @{Metadata = "true" } -UseBasicParsing
$content = $response.Content | ConvertFrom-Json
$KeyVaultToken = $content.access_token
$tries = 1
while ($tries -le 10) { 
    try {
        Write-Host "get join command (try $tries)"
        $response = Invoke-WebRequest -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' -Method GET -Headers @{Metadata = "true" } -UseBasicParsing
        $content = $response.Content | ConvertFrom-Json
        $KeyVaultToken = $content.access_token
        $secretJson = (Invoke-WebRequest -Uri https://$name-vault.vault.azure.net/secrets/JoinCommand?api-version=2016-10-01 -Method GET -Headers @{Authorization = "Bearer $KeyVaultToken" } -UseBasicParsing).content | ConvertFrom-Json
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
        Write-Host "try to join (try $tries)"
        Invoke-Expression $secretJson.value 
        Start-Sleep -Seconds 30
        $job = start-job { docker info --format '{{.Swarm.LocalNodeState}}' } 
        $counter = 0
        while (($job.State -like "Running") -and ($counter -lt 3)) {
            Start-Sleep -Seconds 10
            $counter = $counter + 1
        }
        if ($Job.State -like "Running") { $job | Stop-Job }
        $result = ($job | Receive-Job)
        Write-Host "Docker info LocalNodeState result: $result"
        $job | Remove-Job

        if ($result -eq 'active') {
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
$tries = 1
while ($tries -le 10) { 
    try {
        Write-Host "download SSH key"
        $secretJson = (Invoke-WebRequest -Uri https://$name-vault.vault.azure.net/secrets/sshPubKey?api-version=2016-10-01 -Method GET -Headers @{Authorization = "Bearer $KeyVaultToken" } -UseBasicParsing).content | ConvertFrom-Json
        
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

if (-not $restart) {
    # Handle additional script
    if ($additionalScript -ne "") {
        Invoke-WebRequest -UseBasicParsing -Uri $additionalScript -OutFile 'c:\scripts\additionalScript.ps1'
        & 'c:\scripts\additionalScript.ps1' -branch "$branch"
    }
}
else {
    # Handle additional script
    if ($additionalScript -ne "") {
        & 'c:\scripts\additionalScript.ps1' -branch "$branch" -restart 
    }
}