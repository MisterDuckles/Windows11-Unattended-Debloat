<#
.SYNOPSIS
    Gestroomlijnde, volautomatische ISO builder voor Windows 11 Unattended & Debloat.

.DESCRIPTION
    Dit script automatiseert het proces van het maken van een aangepaste Windows 11 ISO.
    Het mount een bron-ISO, voegt autounattend.xml en de debloat scripts toe,
    en genereert een nieuwe bootable ISO via oscdimg.exe (Windows ADK).

.PARAMETER SourceIso
    Pad naar de originele Windows 11 ISO. 
    Standaard: C:\Users\Gebruiker\Downloads\Win11_25H2_EnglishInternational_x64.iso

.PARAMETER OutputIso
    Pad voor de nieuwe ISO.
    Standaard: .\Windows11_25H2_Unattended_Debloat.iso
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$SourceIso = "C:\Users\Gebruiker\Downloads\Win11_25H2_EnglishInternational_x64.iso",

    [Parameter(Mandatory = $false)]
    [string]$OutputIso = ".\Windows11_25H2_Unattended_Debloat.iso"
)

# Visual styling helpers
function Write-Header {
    param ([string]$Text)
    Write-Host ""
    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Yellow
    Write-Host "==========================================================================" -ForegroundColor Cyan
}

function Write-Success {
    param ([string]$Text)
    Write-Host "[v] $Text" -ForegroundColor Green
}

function Write-Warn {
    param ([string]$Text)
    Write-Host "[!] $Text" -ForegroundColor Yellow
}

function Write-Err {
    param ([string]$Text)
    Write-Host "[X] $Text" -ForegroundColor Red
}

Write-Header 'Windows 11 Unattended - Automatische ISO Builder'

# -------------------------------------------------------------------------
# VALIDATIE: Bestanden en Tools
# -------------------------------------------------------------------------
$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Get-Location }

$unattendXmlPath = Join-Path $scriptRoot "autounattend.xml"
$debloatScriptPath = Join-Path $scriptRoot 'sources\$OEM$\$$\Setup\Scripts\debloat.ps1'

Write-Host "`n[1/5] Controleren van vereiste bestanden..." -ForegroundColor Cyan

$allValid = $true
if (-not (Test-Path $unattendXmlPath)) {
    Write-Err "ONTBREEKT: autounattend.xml niet gevonden op $unattendXmlPath"
    $allValid = $false
}
if (-not (Test-Path $debloatScriptPath)) {
    Write-Err "ONTBREEKT: debloat.ps1 niet gevonden op $debloatScriptPath"
    $allValid = $false
}
if (-not (Test-Path $SourceIso)) {
    Write-Err "ONTBREEKT: Bron ISO niet gevonden op $SourceIso"
    $allValid = $false
}

if (-not $allValid) {
    Write-Err "Afgebroken: Niet alle vereiste bestanden zijn aanwezig."
    exit 1
}
Write-Success "Alle lokale bestanden en bron ISO zijn aanwezig."

# Zoeken naar oscdimg.exe (Windows ADK)
function Find-OscdimgExe {
    $candidates = @(
        "oscdimg.exe",
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\oscdimg\oscdimg.exe",
        "$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\oscdimg\oscdimg.exe",
        "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\oscdimg\oscdimg.exe"
    )

    foreach ($candidate in $candidates) {
        if (Get-Command $candidate -ErrorAction SilentlyContinue) {
            return (Get-Command $candidate).Source
        }
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }

    $kitRoot = Join-Path $env:ProgramFiles 'Windows Kits\10'
    if (Test-Path $kitRoot) {
        $found = Get-ChildItem -Path $kitRoot -Filter 'oscdimg.exe' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) {
            return $found.FullName
        }
    }

    return $null
}

function Install-WindowsAdk {
    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetCmd) {
        Write-Err "winget is niet beschikbaar op deze machine. Installeer Windows ADK handmatig of zet winget eerst op."
        return $false
    }

    Write-Host "Bezig met installeren van Windows ADK via winget..." -ForegroundColor Cyan
    $installArgs = @(
        'install',
        '--id', 'Microsoft.WindowsADK',
        '--accept-source-agreements',
        '--accept-package-agreements',
        '--silent'
    )

    $installProcess = Start-Process -FilePath $wingetCmd.Source -ArgumentList ($installArgs -join ' ') -Wait -NoNewWindow -PassThru
    if ($installProcess.ExitCode -ne 0) {
        Write-Err "De installatie van Windows ADK is mislukt. Controleer de winget output en probeer het opnieuw."
        return $false
    }

    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
    return $true
}

Write-Host "`n[2/5] Zoeken naar Windows ADK (oscdimg.exe)..." -ForegroundColor Cyan
$oscdimgExe = Find-OscdimgExe

if (-not $oscdimgExe) {
    Write-Warn "Windows ADK (oscdimg.exe) is vereist maar niet gevonden."
    $installAnswer = Read-Host "Wil je de Windows ADK nu automatisch installeren via winget? (j/n)"

    if ($installAnswer -match '^(j|ja|y|yes)$') {
        if (-not (Install-WindowsAdk)) {
            exit 1
        }

        $oscdimgExe = Find-OscdimgExe
    }

    if (-not $oscdimgExe) {
        Write-Err "FOUT: Windows ADK (oscdimg.exe) is vereist maar niet gevonden na de installatiepoging."
        Write-Host "Installeer de 'Deployment Tools' van de Windows ADK om door te gaan." -ForegroundColor Gray
        exit 1
    }
}
Write-Success "oscdimg.exe gevonden: $oscdimgExe"

# -------------------------------------------------------------------------
# UITVOERING: ISO Bouwen
# -------------------------------------------------------------------------
$tempFolder = Join-Path $env:TEMP "Win11_Build_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

try {
    # 1. Mount ISO
    Write-Host "`n[3/5] Mounten van bron ISO..." -ForegroundColor Cyan
    $mountedDisk = Mount-DiskImage -ImagePath $SourceIso -PassThru -ErrorAction Stop
    $driveLetter = ($mountedDisk | Get-Volume).DriveLetter + ":"
    Write-Success "ISO gemount op $driveLetter"

    # 2. Kopieer naar tijdelijke map
    Write-Host "`n[4/5] Bestanden kopiëren naar bouwmap: $tempFolder" -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $tempFolder -Force | Out-Null
    
    Write-Host "    Bezig met kopiëren van ISO inhoud (even geduld)..." -ForegroundColor Gray
    & robocopy.exe "$driveLetter\" "$tempFolder" /E /R:1 /W:1 /NDL /NFL /NJH /NJS | Out-Null

    # Dismount ISO direct na kopiëren
    Dismount-DiskImage -ImagePath $SourceIso | Out-Null
    Write-Success "Inhoud gekopieerd en bron ISO gedemonteerd."

    # 3. Injecteer custom bestanden
    Write-Host "    Toevoegen van autounattend.xml en debloat scripts..." -ForegroundColor Gray
    Copy-Item -Path $unattendXmlPath -Destination (Join-Path $tempFolder "autounattend.xml") -Force
    
    $targetSourcesOem = Join-Path $tempFolder 'sources\$OEM$'
    if (-not (Test-Path $targetSourcesOem)) {
        New-Item -ItemType Directory -Path $targetSourcesOem -Force | Out-Null
    }
    Copy-Item -Path (Join-Path $scriptRoot 'sources\$OEM$\*') -Destination $targetSourcesOem -Recurse -Force
    Write-Success "Custom bestanden geïnjecteerd."

    # 4. Bouwen van de nieuwe ISO
    Write-Host "`n[5/5] Genereren van nieuwe ISO: $OutputIso" -ForegroundColor Cyan
    
    $etfsboot = Join-Path $tempFolder "boot\etfsboot.com"
    $efisys = Join-Path $tempFolder "efi\microsoft\boot\efisys.bin"
    $fullOutputPath = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot $OutputIso))

    # Oscdimg parameters voor UEFI/BIOS bootable ISO
    $oscdimgArgs = @(
        "-m",
        "-o",
        "-u2",
        "-udfver102",
        "-bootdata:2#p0,e,b`"$etfsboot`"#pEF,e,b`"$efisys`"",
        "`"$tempFolder`"",
        "`"$fullOutputPath`""
    )

    $process = Start-Process -FilePath $oscdimgExe -ArgumentList ($oscdimgArgs -join " ") -Wait -NoNewWindow -PassThru
    
    if ($process.ExitCode -eq 0 -and (Test-Path $fullOutputPath)) {
        Write-Header 'ISO SUCCESVOL GEBOUWD!'
        Write-Success "Locatie: $fullOutputPath"
    } else {
        Write-Err "Fout bij genereren van ISO. ExitCode: $($process.ExitCode)"
        exit 1
    }

} catch {
    Write-Err "Er is een kritieke fout opgetreden: $_"
    exit 1
} finally {
    # 5. Opruimen
    if (Test-Path $tempFolder) {
        Write-Host "`nSchoonmaken van tijdelijke bouwmap..." -ForegroundColor Gray
        Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}
