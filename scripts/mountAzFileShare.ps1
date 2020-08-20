param(
    [Parameter(Mandatory = $True)]
    [string]
    $storageAccountName,

    [Parameter(Mandatory = $True)]
    [string]
    $storageAccountKey,

    [Parameter(Mandatory = $False)]
    [string]
    $driveLetter = "S"
)

New-PSDrive -Name $driveLetter -PSProvider FileSystem -Root "\\$storageAccountName.file.core.windows.net\share" -Scope Global -Persist -Credential (New-Object System.Management.Automation.PSCredential ("Azure\$storageAccountName", (ConvertTo-SecureString -AsPlainText -Force "$storageAccountKey") ))