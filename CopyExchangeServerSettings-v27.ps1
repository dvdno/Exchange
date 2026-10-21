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
# MIIFrwYJKoZIhvcNAQcCoIIFoDCCBZwCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUlwJ9ieJL0TorDSIwO6MAvUSB
# THmgggM0MIIDMDCCAhigAwIBAgIQZykOzdVedZpLqJsgphmCpzANBgkqhkiG9w0B
# AQsFADAwMS4wLAYDVQQDDCVFeGNoYW5nZSBTZXR0aW5ncyBDb3B5IFNjcmlwdCAo
# TG9jYWwpMB4XDTI2MDkyMjA5MDgwMFoXDTI3MDkyMjA5MTgwMFowMDEuMCwGA1UE
# AwwlRXhjaGFuZ2UgU2V0dGluZ3MgQ29weSBTY3JpcHQgKExvY2FsKTCCASIwDQYJ
# KoZIhvcNAQEBBQADggEPADCCAQoCggEBAJw1UFP0DA/2RpwpkCqxkNjYfbPeiBig
# 7G+Vqob2hic68hZd8w7pibrr9yhMRBil4HqchjqbPvEc3PF+j4KoDk8S3SRL91Ic
# H+SZGIG/CLB6oYBejqFJY/iplaYmsK/KzyJW1s7YnLB2Ggg/bY+fg77rVfvZFsiN
# Vb6oXqkZiOAiCSO/uSjv8xqR92+vHSuqIp7SvxewXljkpTGx4YcEEgvyPP/ZUMAY
# hwdl7VPVrem9m9eCLe7Lr5iWBDGUgjleBb4P2QclHXYyljLeh7NPKV2YGVXjlHLi
# whapBCDG+vEcI8FsICXKjmLoe/J7GFNCdnpYphH76FMrZ9xV8Be6XxECAwEAAaNG
# MEQwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMB0GA1UdDgQW
# BBTZhA8ejiGjSFckCSaJGrK7lzOyNTANBgkqhkiG9w0BAQsFAAOCAQEAM6DrStwp
# pFrqrND4S5TCxaJ6obB6kcTlO+Q/PulWgZLCoFDlztWGD5fu3uv3ZExlV8uSYF+1
# IXYwIY28CfV/R9QTnWNBJ9atrsBO96blSVRGTiPC0x+hywfNRqVW5/N+bZc74mGZ
# GxP6+mCUmEPyBXXBVkwdSu8hIcST0uTO29IUXLqsFvZLtWCZz1DA0pLHwmMgva5b
# e5Ebyh1dBo9mE6Rtq38u5Dl5yQvRgUDeX8DTF8kMktFvEix0AiPjOSnA+0BZD16d
# 7sc3MQ29O2UUNGQc+mO/e9obrGTA3spusc8+SNVA7lhWTQLrt4qVG47dMBCeqTLR
# wDXAPryeJX71tTGCAeUwggHhAgEBMEQwMDEuMCwGA1UEAwwlRXhjaGFuZ2UgU2V0
# dGluZ3MgQ29weSBTY3JpcHQgKExvY2FsKQIQZykOzdVedZpLqJsgphmCpzAJBgUr
# DgMCGgUAoHgwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZBgkqhkiG9w0BCQMx
# DAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAjBgkq
# hkiG9w0BCQQxFgQUjnZSmy7plzm5WFDZepKtJx64gcUwDQYJKoZIhvcNAQEBBQAE
# ggEAkR5SdxXkCtJPnrT5ZtoSFI4nUuKWfdytjGOCKMuQlmIw4+0mtNOxBPEF2pWe
# akKunGt+WJJf/5bRO7fhoKvOMVuvZZTo83X8wRKJLZpDdw7Wjd1AWXevNLVjLuB2
# 8d8/lmARDK93h54QtuLbwBuDzCwwBDibIOdd9nhlN/pujyQKFTCud+wU0hBNQnti
# wZuPPlCEnYCUv9EPGtUWiqa8KQXkNRZPYpMGqix1zXaEbKimQRwbCk8dNnpyZmUk
# /Ys3d2jsaJ6Eek27+lQYHnjvCNxvlIVWXjiE5N/OIJ+U1pNl67ZskJPian0FGkm9
# 3T9HTlrjAMr0lstGXPP4ebfb/A==
# SIG # End signature block
