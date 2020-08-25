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
    $storageAccountName,

    [Parameter(Mandatory = $True)]
    [string]
    $storageAccountKey
)

New-Item -Path c:\scripts -ItemType Directory | Out-Null

# Make sure the latest Docker EE is installed
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Install-Module DockerMsftProvider -Force
Install-Package Docker -ProviderName DockerMsftProvider -Force
Start-Service docker

if (-not $restart) {
    # Handle additional script
    if ($additionalPreScript -ne "") {
        Invoke-WebRequest -UseBasicParsing -Uri $additionalPreScript -OutFile 'c:\scripts\additionalPreScript.ps1'
        & 'c:\scripts\additionalPreScript.ps1' -branch "$branch"
    }
}
else {
    # Handle additional script
    if ($additionalPreScript -ne "") {
        & 'c:\scripts\additionalPreScript.ps1' -branch "$branch" -restart 
    }
}

Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/cosmoconsult/azure-swarm/$branch/scripts/workerConfig.ps1" -OutFile c:\scripts\workerConfig.ps1
Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/cosmoconsult/azure-swarm/$branch/scripts/mountAzFileShare.ps1" -OutFile c:\scripts\mountAzFileShare.ps1

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
if (!(Test-Path -Path $PROFILE.AllUsersAllHosts)) {
    New-Item -ItemType File -Path $PROFILE.AllUsersAllHosts -Force
}
"function prompt {`"PS [`$env:COMPUTERNAME]:`$(`$executionContext.SessionState.Path.CurrentLocation)`$('>' * (`$nestedPromptLevel + 1)) `"}" | Out-File $PROFILE.AllUsersAllHosts

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Unrestricted -Command `"& 'c:\scripts\workerConfig.ps1' -name $name -images '$images' -additionalPostScript '$additionalPostScript' -branch '$branch' -storageAccountName '$storageAccountName' -storageAccountKey '$storageAccountKey'`" 2>&1 >> c:\scripts\log.txt"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10)
$principal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -TaskName "WorkerConfig" -Description "This task should configure the worker"

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Unrestricted -Command `"& 'c:\scripts\workerConfig.ps1' -name $name -images '$images' -additionalPostScript '$additionalPostScript' -branch '$branch' -storageAccountName '$storageAccountName' -storageAccountKey '$storageAccountKey' -restart`" 2>&1 >> c:\scripts\log.txt"
$trigger = New-ScheduledTaskTrigger -AtStartup -RandomDelay 00:00:30
$principal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -TaskName "WorkerConfigReboot" -Description "This task should configure the worker after a reboot"