param(
    [Parameter(Mandatory = $False)]
    [string]
    $images = "",

    [Parameter(Mandatory = $True)]
    [string]
    $resourceGroupName,

    [Parameter(Mandatory = $True)]
    [string]
    $branch,
    
    [Parameter(Mandatory = $False)]
    [string]
    $additionalScript = ""
)

New-Item -Path c:\iac -ItemType Directory | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/tfenster/BC-Swarm/$branch/Swarm/workerConfig.ps1" -OutFile c:\iac\workerConfig.ps1

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Unrestricted -Command `"& 'c:\iac\workerConfig.ps1' -resourceGroupName $resourceGroupName -images '$images' -additionalScript '$additionalScript' -branch '$branch'`" 2>&1 >> c:\iac\log.txt"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10)
$principal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -TaskName "WorkerConfig" -Description "This task should configure the worker"

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Unrestricted -Command `"& 'c:\iac\workerConfig.ps1' -resourceGroupName $resourceGroupName -images '$images' -additionalScript '$additionalScript' -branch '$branch' -restart`" 2>&1 >> c:\iac\log.txt"
$trigger = New-ScheduledTaskTrigger -AtStartup -RandomDelay 00:00:30
$principal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -TaskName "WorkerConfigReboot" -Description "This task should configure the worker after a reboot"