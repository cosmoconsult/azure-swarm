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

$secpassword = ConvertTo-SecureString $storageAccountKey -AsPlainText -Force
$creds = New-Object System.Management.Automation.PSCredential("Azure\$storageAccountName", $secpassword)
New-SmbGlobalMapping -RemotePath "\\$storageAccountName.file.core.windows.net\share" -Credential $creds -LocalPath $driveLetter -Persistent $true -RequirePrivacy $true
Invoke-Expression "icacls.exe $($driveLetter):\ /grant 'Everyone:(OI)(CI)(F)'"