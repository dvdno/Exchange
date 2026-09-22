<#
    Name        : CopyExchangeServerSettings.ps1
    Version     : 2.0.0.5
    Last Update : 2022/11/27
    Created by  : David Danino, Microsoft
    Usage       : Run from elevated instance of Exchange Management Shell on the target (new) Exchange server.
#>

function Write-Section {
    param([string]$Message)
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor DarkGray
    Write-Host $Message -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor DarkGray
}

function Write-Step {
    param([string]$Message)
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) -ForegroundColor Yellow
}

Write-Section "Exchange Server Settings Copy"
Write-Host "This script copies selected settings from an existing Exchange server to this server." -ForegroundColor Gray
Write-Host ""
Write-Host "From which Exchange server would you like to copy settings from?" -ForegroundColor Cyan
$SOURCE = (Read-Host)
Get-ExchangeServer $SOURCE -ErrorAction Stop
$TARGET = (hostname)
Write-Host ("Source: {0}" -f $SOURCE) -ForegroundColor Gray
Write-Host ("Target: {0}" -f $TARGET) -ForegroundColor Gray

Write-Section "Autodiscover Service Connection Point"
Write-Step "Current target value:"
Get-ClientAccessService $TARGET | Format-Table Name,AutodiscoverServiceInternalUri -AutoSize
$CAS = Get-ClientAccessService $SOURCE | select AutodiscoverServiceInternaluri
Set-ClientAccessService $TARGET -AutodiscoverServiceInternaluri $CAS.AutodiscoverServiceInternaluri
 
Write-Step "Updated target value:"
Get-ClientAccessService $TARGET | Format-Table Name,AutodiscoverServiceInternalUri -AutoSize

Write-Section "Virtual Directory URLs"
Write-Step "Copying MAPI, Web Services, OAB, OWA, ECP, and Outlook Anywhere settings..."
$MAPI = Get-MapiVirtualDirectory -Server $SOURCE -AdPropertiesOnly
Get-MapiVirtualDirectory -Server $TARGET | Set-MapiVirtualDirectory -InternalUrl $MAPI.InternalUrl -ExternalUrl $MAPI.ExternalUrl -WarningAction SilentlyContinue
$EWS = Get-WebServicesVirtualDirectory -Server $SOURCE -AdPropertiesOnly
Get-WebServicesVirtualDirectory -Server $TARGET | Set-WebServicesVirtualDirectory -InternalUrl $EWS.InternalUrl -ExternalUrl $EWS.ExternalUrl -WarningAction SilentlyContinue
$OAB = Get-OabVirtualDirectory -Server $SOURCE -AdPropertiesOnly
Get-OabVirtualDirectory -Server $TARGET | Set-OabVirtualDirectory -InternalUrl $OAB.InternalUrl -ExternalUrl $OAB.ExternalUrl -WarningAction SilentlyContinue
$OWA = Get-OwaVirtualDirectory -Server $SOURCE -AdPropertiesOnly
Get-OwaVirtualDirectory -Server $TARGET | Set-OwaVirtualDirectory -InternalUrl $OWA.InternalUrl -ExternalUrl $OWA.ExternalUrl -WarningAction SilentlyContinue
$ECP = Get-EcpVirtualDirectory -Server $SOURCE -AdPropertiesOnly
Get-EcpVirtualDirectory -Server $TARGET | Set-EcpVirtualDirectory -InternalUrl $ECP.InternalUrl -ExternalUrl $ECP.ExternalUrl -WarningAction SilentlyContinue
$OLA = Get-OutlookAnywhere -AdPropertiesOnly -Server $SOURCE
Get-OutlookAnywhere -AdPropertiesOnly -Server $TARGET | Set-OutlookAnywhere -InternalHostname $OLA.InternalHostname -DefaultAuthenticationMethod Negotiate -InternalClientsRequireSsl $True -WarningAction SilentlyContinue

Write-Section "IIS Configuration"
Write-Step "Disabling IIS logging and restarting Exchange application pools..."
Import-Module -Name WebAdministration
Get-ItemProperty -Path 'IIS:\Sites\*' | Set-ItemProperty -Name Logfile.enabled -Value $False
Restart-WebAppPool MSExchangeServicesAppPool
Restart-WebAppPool MSExchangeAutodiscoverAppPool

Write-Section "Exchange Certificate"
Write-Step "Exporting the IIS certificate from $SOURCE and importing it on $TARGET..."
$CERT = Get-ExchangeCertificate -Server $SOURCE | ? {$_.Services -Like "*IIS*" -and $_.IsSelfSigned -eq $false} | select Thumbprint
$PASS = ConvertTo-SecureString "123456" -AsPlainText -Force
mkdir C:\temp -ErrorAction SilentlyContinue | Out-Null
$bincert = Export-ExchangeCertificate -Server $SOURCE -Thumbprint $CERT.Thumbprint -BinaryEncoded -Password (ConvertTo-SecureString -String '123456' -AsPlainText -Force)
[System.IO.File]::WriteAllBytes('C:\Temp\ExchangeCert-Temp.pfx', $bincert.FileData)
Import-ExchangeCertificate -Server $TARGET -FileData ([System.IO.File]::ReadAllBytes('\\localhost\C$\temp\ExchangeCert-Temp.pfx')) -PrivateKeyExportable $true -Password $PASS
Remove-Item "C:\temp\ExchangeCert-Temp.pfx" -ErrorAction SilentlyContinue -Confirm:$False
Enable-ExchangeCertificate -Thumbprint $CERT.Thumbprint -Services IIS -DoNotRequireSsl
Get-ExchangeCertificate | ? {$_.Services -Like "*IIS*" -and $_.IsSelfSigned -eq $false} | FL CertificateDomains,Thumbprint,NotAfter,Issuer,Services

Write-Section "Completed"
Write-Host "Exchange settings were copied from $SOURCE to $TARGET." -ForegroundColor Green
Write-Host "Review any warning or error messages above for skipped items." -ForegroundColor Gray
