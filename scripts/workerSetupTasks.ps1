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
    $storageAccountKey,

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

New-Item -Path c:\scripts -ItemType Directory | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/cosmoconsult/azure-swarm/$branch/scripts/workerConfig.ps1" -OutFile c:\scripts\workerConfig.ps1

# Make sure the latest Docker EE is installed
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Install-Module DockerMsftProvider -Force
Install-Package Docker -ProviderName DockerMsftProvider -Force
Start-Service docker

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Unrestricted -Command `"& 'c:\scripts\workerConfig.ps1' -name $name -images '$images' -additionalPostScript '$additionalPostScript' -branch '$branch' -storageAccountName '$storageAccountName' -storageAccountKey '$storageAccountKey' -authToken '$authToken'`" 2>&1 >> c:\scripts\log.txt"
$trigger = New-ScheduledTaskTrigger -AtStartup -RandomDelay 00:00:30
$principal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -TaskName "WorkerConfigInitial" -Description "This task should configure the worker initially"

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

Restart-Computer -Force