param(
    [Parameter(Mandatory = $False)]
    [string]
    $branch = "master",

    [Parameter(Mandatory = $False)]
    [switch]
    $restart,
    
    [Parameter(Mandatory = $False)]
    [string]
    $additionalScript = "",

    [Parameter(Mandatory = $True)]
    [string]
    $externaldns,

    [Parameter(Mandatory = $True)]
    [string]
    $name,
   
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
    $storageAccountKey
)

if (-not $restart) {
    if ($isFirstMgr) {
        # Deploy Portainer / Traefik
        Invoke-Expression "docker network create --driver=overlay traefik-public" | Out-Null
        Start-Sleep -Seconds 10

        New-Item -Path c:\iac\compose -ItemType Directory | Out-Null
        Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/cosmoconsult/azure-swarm/$branch/configs/docker-compose.yml.template" -OutFile c:\iac\compose\docker-compose.yml.template
        $template = Get-Content 'c:\iac\compose\docker-compose.yml.template' -Raw
        $expanded = Invoke-Expression "@`"`r`n$template`r`n`"@"
        $expanded | Out-File "c:\iac\compose\docker-compose.yml" -Encoding ASCII

        Invoke-Expression "docker stack deploy -c c:\iac\compose\docker-compose.yml base"
    }

    # SSH and Choco setup
    Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
    choco feature enable -n allowGlobalConfirmation
    choco install --no-progress --limit-output vim
    choco install --no-progress --limit-output openssh -params '"/SSHServerFeature"'
    Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/cosmoconsult/azure-swarm/$branch/configs/sshd_config_wpwd" -OutFile C:\ProgramData\ssh\sshd_config

    Write-Host "try to get access token"
    $response = Invoke-WebRequest -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' -Method GET -Headers @{Metadata = "true" } -UseBasicParsing
    $content = $response.Content | ConvertFrom-Json
    $KeyVaultToken = $content.access_token
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

    Restart-Service sshd
}

$tries = 1
while ($tries -le 10) { 
    Write-Host "Trying to mount Azure File Share"
    . c:\iac\mountAzFileShare.ps1 -storageAccountName "$storageAccountName" -storageAccountKey "$storageAccountKey" -driveLetter "S"
    if (Test-Path "S:") {
        $tries = 11
    }
    Write-Host "Try $tries failed"
    $tries = $tries + 1
    Start-Sleep -Seconds 30
}

if (-not $restart) {
    # Handle additional script
    if ($additionalScript -ne "") {
        Invoke-WebRequest -UseBasicParsing -Uri $additionalScript -OutFile 'c:\iac\additionalScript.ps1'
        & 'c:\iac\additionalScript.ps1' -branch "$branch" -externaldns "$externaldns"
    }
}
else {
    # Handle additional script
    if ($additionalScript -ne "") {
        & 'c:\iac\additionalScript.ps1' -branch "$branch" -externaldns "$externaldns" -restart
    }
}