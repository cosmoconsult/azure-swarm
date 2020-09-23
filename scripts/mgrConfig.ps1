param(
    [Parameter(Mandatory = $False)]
    [string]
    $branch = "master",

    [Parameter(Mandatory = $False)]
    [switch]
    $restart,
    
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
    $storageAccountKey,

    [Parameter(Mandatory = $False)]
    [string]
    $authToken = $null
)

if (-not $restart) {
    $tries = 1
    while ($tries -le 10) { 
        Write-Debug "Trying to mount Azure File Share"
        . c:\scripts\mountAzFileShare.ps1 -storageAccountName "$storageAccountName" -storageAccountKey "$storageAccountKey" -driveLetter "S"
        if (Test-Path "S:") {
            $tries = 11
        }
        else {
            Write-Debug "Try $tries failed, sleep and try again"
            $tries = $tries + 1
            Start-Sleep -Seconds 30
            Write-Debug "awoke for try $tries"
        }
    }
    if ($isFirstMgr) {
        Write-Debug "create folders"
        New-Item -Path s:\le -ItemType Directory | Out-Null	
        New-Item -Path s:\le\acme.json | Out-Null

        Write-Debug "Create overlay network"
        Invoke-Expression "docker network create --driver=overlay traefik-public" | Out-Null
        Start-Sleep -Seconds 10

        Write-Debug "Create folders"
        New-Item -Path s:\compose -ItemType Directory | Out-Null
        New-Item -Path s:\compose\base -ItemType Directory | Out-Null
        New-Item -Path s:\portainer-data -ItemType Directory | Out-Null

        Write-Debug "Download compose file"
        [DownloadWithRetry]::DoDownloadWithRetry("https://raw.githubusercontent.com/cosmoconsult/azure-swarm/$branch/configs/docker-compose.yml.template", 5, 10, $null, 's:\compose\base\docker-compose.yml.template', $false)
        $template = Get-Content 's:\compose\base\docker-compose.yml.template' -Raw
        $expanded = Invoke-Expression "@`"`r`n$template`r`n`"@"
        $expanded | Out-File "s:\compose\base\docker-compose.yml" -Encoding ASCII

        Write-Debug "Deploy Portainer / Traefik"
        Invoke-Expression "docker stack deploy -c s:\compose\base\docker-compose.yml base"
    }

    # SSH and Choco setup
    Write-Debug "Install chocolatey"
    Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
    choco feature enable -n allowGlobalConfirmation
    choco install --no-progress --limit-output vim
    choco install --no-progress --limit-output openssh -params '"/SSHServerFeature"'

    Write-Debug "Download ssh config file"
    [DownloadWithRetry]::DoDownloadWithRetry("https://raw.githubusercontent.com/cosmoconsult/azure-swarm/$branch/configs/sshd_config_wpwd", 5, 10, $null, 'C:\ProgramData\ssh\sshd_config', $false)

    Write-Debug "try to get access token"
    $content = [DownloadWithRetry]::DoDownloadWithRetry('http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net', 5, 10, $null, $null, $true) | ConvertFrom-Json
    $KeyVaultToken = $content.access_token
    $tries = 1
    while ($tries -le 10) { 
        try {
            Write-Debug "download SSH key"
            $secretJson = [DownloadWithRetry]::DoDownloadWithRetry("https://$name-vault.vault.azure.net/secrets/sshPubKey?api-version=2016-10-01", 5, 10, "Bearer $KeyVaultToken", $null, $false) | ConvertFrom-Json
            Write-Debug "got $secretJson"
            
            $secretJson.value | Out-File 'c:\ProgramData\ssh\administrators_authorized_keys' -Encoding utf8

            Write-Debug "set acl for authorized keys"
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

    Write-Debug "Make PS the default shell"
    New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force

    Write-Debug "restart ssh"
    Restart-Service sshd
}

Write-Debug "Handle additional post script"
if (-not $restart) {
    # Handle additional script
    if ($additionalPostScript -ne "") {
        Write-Debug "Download script"
        [DownloadWithRetry]::DoDownloadWithRetry($additionalPostScript, 5, 10, $authToken, 'c:\scripts\additionalPostScript.ps1', $false)
        Write-Debug "Call script"
        & 'c:\scripts\additionalPostScript.ps1' -branch "$branch" -externaldns "$externaldns" -isFirstMgr:$isFirstMgr -authToken "$authToken"
    }
}
else {
    # Handle additional script
    if ($additionalPostScript -ne "") {
        Write-Debug "Call script"
        & 'c:\scripts\additionalPostScript.ps1' -branch "$branch" -externaldns "$externaldns" -isFirstMgr:$isFirstMgr -authToken "$authToken" -restart 
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