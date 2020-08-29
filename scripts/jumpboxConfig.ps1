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
        $headers = @{ }
        if (-not ([string]::IsNullOrEmpty($authToken))) {
            $headers = @{
                'Authorization' = $authToken
            }
        }
        Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri $additionalPreScript -OutFile 'c:\scripts\additionalPreScript.ps1'
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
    # SSH and Choco setup
    Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
    choco feature enable -n allowGlobalConfirmation
    choco install --no-progress --limit-output vim
    choco install --no-progress --limit-output openssh -params '"/SSHServerFeature"'
    Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/cosmoconsult/azure-swarm/$branch/configs/sshd_config_wopwd" -OutFile C:\ProgramData\ssh\sshd_config

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

    New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force
    Restart-Service sshd

    # Handle additional script
    if ($additionalPostScript -ne "") {
        $headers = @{ }
        if (-not ([string]::IsNullOrEmpty($authToken))) {
            $headers = @{
                'Authorization' = $authToken
            }
        }
        Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri $additionalPostScript -OutFile 'c:\scripts\additionalPostScript.ps1'
        & 'c:\scripts\additionalPostScript.ps1' -branch "$branch" -authToken "$authToken"
    }
}
else {
    # Handle additional script
    if ($additionalPostScript -ne "") {
        & 'c:\scripts\additionalPostScript.ps1' -branch "$branch" -authToken "$authToken" -restart 
    }
}