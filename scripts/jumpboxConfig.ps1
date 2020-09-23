param(
    [Parameter(Mandatory = $False)]
    [string]
    $branch = "master",

    [Parameter(Mandatory = $False)]
    [switch]
    $restart,
    
    [Parameter(Mandatory = $False)]
    [string]
    $additionalPreScript = "",
    
    [Parameter(Mandatory = $False)]
    [string]
    $additionalPostScript = "",

    [Parameter(Mandatory = $True)]
    [string]
    $name,

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

if (-not $restart) {
    # Handle additional script
    if ($additionalPreScript -ne "") {
        [DownloadWithRetry]::DoDownloadWithRetry($additionalPreScript, 5, 10, $authToken, 'c:\scripts\additionalPreScript.ps1', $false)
        & 'c:\scripts\additionalPreScript.ps1' -branch "$branch" -authToken "$authToken"
    }
}
else {
    # Handle additional script
    if ($additionalPreScript -ne "") {
        & 'c:\scripts\additionalPreScript.ps1' -branch "$branch" -authToken "$authToken" -restart 
    }
}

if (-not $restart) {
    # Setup profile
    Write-Debug "Download profile file"
    [DownloadWithRetry]::DoDownloadWithRetry("https://raw.githubusercontent.com/cosmoconsult/azure-swarm/$branch/scripts/profile.ps1", 5, 10, $null, $PROFILE.AllUsersAllHosts, $false)
    
    # SSH and Choco setup
    Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
    choco feature enable -n allowGlobalConfirmation
    choco install --no-progress --limit-output vim
    choco install --no-progress --limit-output openssh -params '"/SSHServerFeature"'
    [DownloadWithRetry]::DoDownloadWithRetry("https://raw.githubusercontent.com/cosmoconsult/azure-swarm/$branch/configs/sshd_config_wopwd", 5, 10, $null, 'C:\ProgramData\ssh\sshd_config', $false)

    Write-Host "try to get access token"
    $content = [DownloadWithRetry]::DoDownloadWithRetry('http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net', 5, 10, $null, $null, $true) | ConvertFrom-Json
    $KeyVaultToken = $content.access_token
    $tries = 1
    while ($tries -le 10) { 
        try {
            Write-Host "download SSH key"
            $secretJson = [DownloadWithRetry]::DoDownloadWithRetry("https://$name-vault.vault.azure.net/secrets/sshPubKey?api-version=2016-10-01", 5, 10, "Bearer $KeyVaultToken", $null, $false) | ConvertFrom-Json
            
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

    New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force
    Restart-Service sshd

    # Handle additional script
    if ($additionalPostScript -ne "") {
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
                if ($headers.Count -ne 0) {
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