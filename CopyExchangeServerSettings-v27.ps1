<#
    Name        : CopyExchangeServerSettings-v27.ps1
    Version     : 2.7.0.0
    Last Update : 2026/10/21
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

function Get-ValidIISCertificate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName
    )

    $cert = Get-ExchangeCertificate -Server $ServerName |
        Where-Object {
            $_.Services -match 'IIS' -and
            $_.IsSelfSigned -eq $false -and
            $_.NotAfter -gt (Get-Date)
        } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1

    if (-not $cert) {
        throw "No valid, non-self-signed IIS certificate was found on server '$ServerName'."
    }

    if ([string]::IsNullOrWhiteSpace($cert.Thumbprint)) {
        throw "The certificate found on server '$ServerName' has an empty or missing Thumbprint value."
    }

    if ($cert.Thumbprint -notmatch '^[A-Fa-f0-9]{40}$') {
        throw "The certificate thumbprint '$($cert.Thumbprint)' on server '$ServerName' is invalid. Expected a 40-character hexadecimal value."
    }

    $validatedCert = Get-ExchangeCertificate -Server $ServerName -Thumbprint $cert.Thumbprint -ErrorAction Stop
    if (-not $validatedCert) {
        throw "Unable to retrieve a certificate for thumbprint '$($cert.Thumbprint)' from server '$ServerName'."
    }

    if ($validatedCert.IsSelfSigned -eq $true) {
        throw "Certificate '$($validatedCert.Thumbprint)' is self-signed and cannot be exported or used for IIS."
    }

    if ($validatedCert.NotAfter -le (Get-Date)) {
        throw "Certificate '$($validatedCert.Thumbprint)' has expired on $($validatedCert.NotAfter)."
    }

    return $validatedCert
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
$CAS = Get-ClientAccessService $SOURCE | Select-Object AutodiscoverServiceInternaluri
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
$CERT = Get-ValidIISCertificate -ServerName $SOURCE
$PASS = ConvertTo-SecureString "123456" -AsPlainText -Force
New-Item -ItemType Directory -Path 'C:\temp' -Force | Out-Null

try {
    $bincert = Export-ExchangeCertificate -Server $SOURCE -Thumbprint $CERT.Thumbprint -BinaryEncoded -Password (ConvertTo-SecureString -String '123456' -AsPlainText -Force) -ErrorAction Stop
    if (-not $bincert -or [string]::IsNullOrWhiteSpace($bincert.FileData)) {
        throw "The export operation returned no certificate data for thumbprint '$($CERT.Thumbprint)'."
    }

    [System.IO.File]::WriteAllBytes('C:\Temp\ExchangeCert-Temp.pfx', $bincert.FileData)
    Import-ExchangeCertificate -Server $TARGET -FileData ([System.IO.File]::ReadAllBytes('\\localhost\C$\temp\ExchangeCert-Temp.pfx')) -PrivateKeyExportable $true -Password $PASS -ErrorAction Stop | Out-Null
    Remove-Item "C:\temp\ExchangeCert-Temp.pfx" -ErrorAction SilentlyContinue -Confirm:$False
    Enable-ExchangeCertificate -Thumbprint $CERT.Thumbprint -Services IIS -DoNotRequireSsl -ErrorAction Stop
} catch {
    throw "Failed to validate or export certificate '$($CERT.Thumbprint)' from '$SOURCE': $($_.Exception.Message)"
}

Get-ExchangeCertificate | Where-Object { $_.Services -Like "*IIS*" -and $_.IsSelfSigned -eq $false } | Format-Table CertificateDomains,Thumbprint,NotAfter,Issuer,Services

Write-Section "Completed"
Write-Host "Exchange settings were copied from $SOURCE to $TARGET." -ForegroundColor Green
Write-Host "Review any warning or error messages above for skipped items." -ForegroundColor Gray

# SIG # Begin signature block
# MIIF1AYJKoZIhvcNAQcCoIIFxTCCBcECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBZV2HdRMkin4IC
# ngrovqGKPYtOf7N6+Hr5MuLzbSviLqCCAzQwggMwMIICGKADAgECAhBnKQ7N1V51
# mkuomyCmGYKnMA0GCSqGSIb3DQEBCwUAMDAxLjAsBgNVBAMMJUV4Y2hhbmdlIFNl
# dHRpbmdzIENvcHkgU2NyaXB0IChMb2NhbCkwHhcNMjYwOTIyMDkwODAwWhcNMjcw
# OTIyMDkxODAwWjAwMS4wLAYDVQQDDCVFeGNoYW5nZSBTZXR0aW5ncyBDb3B5IFNj
# cmlwdCAoTG9jYWwpMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnDVQ
# U/QMD/ZGnCmQKrGQ2Nh9s96IGKDsb5WqhvaGJzryFl3zDumJuuv3KExEGKXgepyG
# Ops+8Rzc8X6PgqgOTxLdJEv3Uhwf5JkYgb8IsHqhgF6OoUlj+KmVpiawr8rPIlbW
# zticsHYaCD9tj5+DvutV+9kWyI1VvqheqRmI4CIJI7+5KO/zGpH3b68dK6ointK/
# F7BeWOSlMbHhhwQSC/I8/9lQwBiHB2XtU9Wt6b2b14It7suvmJYEMZSCOV4Fvg/Z
# ByUddjKWMt6Hs08pXZgZVeOUcuLCFqkEIMb68RwjwWwgJcqOYuh78nsYU0J2elim
# EfvoUytn3FXwF7pfEQIDAQABo0YwRDAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAww
# CgYIKwYBBQUHAwMwHQYDVR0OBBYEFNmEDx6OIaNIVyQJJokasruXM7I1MA0GCSqG
# SIb3DQEBCwUAA4IBAQAzoOtK3CmkWuqs0PhLlMLFonqhsHqRxOU75D8+6VaBksKg
# UOXO1YYPl+7e6/dkTGVXy5JgX7UhdjAhjbwJ9X9H1BOdY0En1q2uwE73puVJVEZO
# I8LTH6HLB81GpVbn835tlzviYZkbE/r6YJSYQ/IFdcFWTB1K7yEhxJPS5M7b0hRc
# uqwW9ku1YJnPUMDSksfCYyC9rlt7kRvKHV0Gj2YTpG2rfy7kOXnJC9GBQN5fwNMX
# yQyS0W8SLHQCI+M5KcD7QFkPXp3uxzcxDb07ZRQ0ZBz6Y7972husZMDeym6xzz5I
# 1UDuWFZNAuu3ipUbjt0wEJ6pMtHANcA+vJ4lfvW1MYIB9jCCAfICAQEwRDAwMS4w
# LAYDVQQDDCVFeGNoYW5nZSBTZXR0aW5ncyBDb3B5IFNjcmlwdCAoTG9jYWwpAhBn
# KQ7N1V51mkuomyCmGYKnMA0GCWCGSAFlAwQCAQUAoIGEMBgGCisGAQQBgjcCAQwx
# CjAIoAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGC
# NwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIM4OMlWK6P+BIQxL
# vAnDxVlNsrc6o0LxOvkEj7PlFSemMA0GCSqGSIb3DQEBAQUABIIBADrYpG16azKl
# 2mKyTJ404Xn9aDoJU6rOlIdXeSHAaQmDf5pXaRYzxKb87xHaa8UeXKDxHO4Wn9Ws
# hfhT4gOMqT7gLKZo3CtsHVuI819TzMKRXhFIbdbnRYHQNeAVVCXEUmkbPAUEN/t5
# +JVhX3Z+Hq2bc05RS2ADjtYi2a1N4EW8s1nN+1AGdk26F4sP1E10kPtIP+fe3lqK
# 5Bfd7OM35N0PcZ+PlnJ7caJmZTltOEBcQ7nGL40C38bsIAR8bg77Lu+q5iIHdZgs
# MqQH3R9cSahsJNpNSz3lRgOB/P2Wv6SqeXn2FP6+4o4G0Qdjs32nVj/VU0HPsNx4
# D9Ceg3pV2JI=
# SIG # End signature block
