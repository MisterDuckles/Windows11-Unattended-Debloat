#Requires -RunAsAdministrator
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
    Standaard: C:\Users\Gebruiker\Downloads\Win11_Custom.iso

.PARAMETER RefreshScripts
    Haalt de nieuwste versie van de payload-scripts van GitHub op VOORDAT de ISO wordt
    gebouwd, en schrijft ze naar sources\$OEM$\$$\Setup\Scripts\.

    Dit vervangt de oude remote-fetch in launcher.ps1, die tijdens de INSTALLATIE code van
    internet haalde en als SYSTEM uitvoerde zonder verificatie. Het ophalen hoort hier thuis:
    het gebeurt op jouw machine, je ziet in git-diff wat er verandert, en je kunt de ISO
    testen voordat je hem uitrolt. De gedeployde machine draait altijd een bekende kopie.

    Zonder deze switch worden de scripts gebruikt zoals ze in de repo staan.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$SourceIso = "C:\Users\Gebruiker\Downloads\Win11_25H2_EnglishInternational_x64_v2.iso",

    [Parameter(Mandatory = $false)]
    [string]$OutputIso = "C:\Users\Gebruiker\Downloads\Win11_Custom.iso",

    [Parameter(Mandatory = $false)]
    [switch]$RefreshScripts,

    [Parameter(Mandatory = $false)]
    [string]$ScriptsBaseUrl = "https://raw.githubusercontent.com/MisterDuckles/Windows11-Unattended-Debloat/master/sources/%24OEM%24/%24%24/Setup/Scripts"
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
$scriptsDir = Join-Path $scriptRoot 'sources\$OEM$\$$\Setup\Scripts'

# Elk van deze bestanden is nodig. Voorheen werden alleen autounattend.xml en debloat.ps1
# gecontroleerd, waardoor een ontbrekende firstlogon.ps1 een ISO opleverde die "SUCCESVOL
# GEBOUWD" meldde maar een machine achterliet met permanent kapotte Windows Update.
$requiredScripts = @('SetupComplete.cmd', 'launcher.ps1', 'debloat.ps1', 'firstlogon.ps1')

Write-Host "`n[1/5] Controleren van vereiste bestanden..." -ForegroundColor Cyan

$allValid = $true
if (-not (Test-Path $unattendXmlPath)) {
    Write-Err "ONTBREEKT: autounattend.xml niet gevonden op $unattendXmlPath"
    $allValid = $false
}
foreach ($s in $requiredScripts) {
    if (-not (Test-Path (Join-Path $scriptsDir $s))) {
        Write-Err "ONTBREEKT: $s niet gevonden in $scriptsDir"
        $allValid = $false
    }
}
if (-not (Test-Path $SourceIso)) {
    Write-Err "ONTBREEKT: Bron ISO niet gevonden op $SourceIso"
    $allValid = $false
}

# autounattend.xml moet parsebaar zijn - een ISO bouwen met kapotte XML kost je een
# complete installatiecyclus voordat je erachter komt.
if ($allValid) {
    try {
        [void][xml](Get-Content $unattendXmlPath -Raw)
        Write-Success "autounattend.xml is geldige XML."
    } catch {
        Write-Err "autounattend.xml is GEEN geldige XML: $($_.Exception.Message)"
        $allValid = $false
    }
}

if (-not $allValid) {
    Write-Err "Afgebroken: Niet alle vereiste bestanden zijn aanwezig."
    exit 1
}

# -------------------------------------------------------------------------
# OPTIONEEL: scripts verversen vanaf GitHub (buildtijd, niet installatietijd)
# -------------------------------------------------------------------------
if ($RefreshScripts) {
    Write-Host "`n[1b/5] Scripts verversen vanaf GitHub..." -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    foreach ($s in $requiredScripts) {
        $url = "$ScriptsBaseUrl/$s"
        $dest = Join-Path $scriptsDir $s
        $backup = "$dest.bak"
        try {
            Copy-Item -Path $dest -Destination $backup -Force -ErrorAction Stop
            Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop

            # Een lege of piepkleine download is bijna zeker een foutpagina, geen script.
            if ((Get-Item $dest).Length -lt 200) {
                throw "gedownload bestand is verdacht klein ($((Get-Item $dest).Length) bytes)"
            }
            # PowerShell-bestanden moeten parsen; anders bak je een kapot script in de ISO.
            if ($s -like '*.ps1') {
                $parseErrors = $null
                [void][System.Management.Automation.Language.Parser]::ParseFile($dest, [ref]$null, [ref]$parseErrors)
                if ($parseErrors -and $parseErrors.Count -gt 0) {
                    throw "gedownload script bevat $($parseErrors.Count) syntaxfout(en)"
                }
            }
            Remove-Item $backup -Force -ErrorAction SilentlyContinue
            Write-Success "Ververst: $s"
        } catch {
            Write-Warn "Verversen van $s mislukt ($($_.Exception.Message)) - lokale versie behouden."
            if (Test-Path $backup) { Move-Item -Path $backup -Destination $dest -Force -ErrorAction SilentlyContinue }
        }
    }
    Write-Warn "Controleer 'git diff' voordat je deze ISO uitrolt."
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
$isoMounted = $false   # gelezen door het finally-blok, moet dus voor de try bestaan

try {
    # 1. Mount ISO
    Write-Host "`n[3/5] Mounten van bron ISO..." -ForegroundColor Cyan
    $mountedDisk = Mount-DiskImage -ImagePath $SourceIso -PassThru -ErrorAction Stop
    $isoMounted = $true

    # De driveletter is niet altijd meteen beschikbaar op het object dat Mount-DiskImage
    # teruggeeft (zeker niet met automount uit of op een trage mount). Zonder retry werd
    # $null + ":" stilletjes ":" en kopieerde robocopy vervolgens vanaf niets.
    $driveLetter = $null
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $vol = Get-DiskImage -ImagePath $SourceIso -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue
        if ($vol -and $vol.DriveLetter) { $driveLetter = "$($vol.DriveLetter):"; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $driveLetter) {
        throw "ISO is gemount maar kreeg geen driveletter toegewezen. Staat automount uit? (mountvol /E)"
    }
    Write-Success "ISO gemount op $driveLetter"

    # 2. Kopieer naar tijdelijke map
    Write-Host "`n[4/5] Bestanden kopieren naar bouwmap: $tempFolder" -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $tempFolder -Force | Out-Null
    
    Write-Host "    Bezig met kopieren van ISO inhoud (even geduld)..." -ForegroundColor Gray
    & robocopy.exe "$driveLetter\" "$tempFolder" /E /R:1 /W:1 /NDL /NFL /NJH /NJS | Out-Null

    # Robocopy gebruikt bitflags: 0-7 is succes, 8 en hoger betekent dat er bestanden zijn
    # MISLUKT. Die exitcode ging voorheen naar Out-Null, dus een volle schijf of een
    # AV-lock leverde een onvolledige kopie op die daarna gewoon als ISO werd verpakt.
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy faalde met exitcode $LASTEXITCODE - de kopie van de ISO-inhoud is onvolledig. Genoeg vrije ruimte op $env:TEMP?"
    }

    # Dismount ISO direct na kopieren
    Dismount-DiskImage -ImagePath $SourceIso | Out-Null
    $isoMounted = $false
    Write-Success "Inhoud gekopieerd en bron ISO gedemonteerd."

    # De bron-ISO moet daadwerkelijk een Windows-image bevatten.
    if (-not (Test-Path (Join-Path $tempFolder 'sources\install.wim')) -and
        -not (Test-Path (Join-Path $tempFolder 'sources\install.esd'))) {
        throw "Noch sources\install.wim noch sources\install.esd aangetroffen in de kopie - dit is geen bruikbare Windows-ISO."
    }

    # 3. Injecteer custom bestanden
    Write-Host "    Toevoegen van autounattend.xml en debloat scripts..." -ForegroundColor Gray
    Copy-Item -Path $unattendXmlPath -Destination (Join-Path $tempFolder "autounattend.xml") -Force -ErrorAction Stop

    $targetSourcesOem = Join-Path $tempFolder 'sources\$OEM$'
    if (-not (Test-Path $targetSourcesOem)) {
        New-Item -ItemType Directory -Path $targetSourcesOem -Force | Out-Null
    }
    Copy-Item -Path (Join-Path $scriptRoot 'sources\$OEM$\*') -Destination $targetSourcesOem -Recurse -Force -ErrorAction Stop

    # Terugcontroleren in de bouwmap, niet alleen in de repo. Een geslaagde Copy-Item is
    # geen garantie dat alles op de juiste plek staat.
    $stagedScriptsDir = Join-Path $tempFolder 'sources\$OEM$\$$\Setup\Scripts'
    $missing = @()
    if (-not (Test-Path (Join-Path $tempFolder 'autounattend.xml'))) { $missing += 'autounattend.xml' }
    foreach ($s in $requiredScripts) {
        if (-not (Test-Path (Join-Path $stagedScriptsDir $s))) { $missing += "sources\`$OEM`$\...\$s" }
    }
    if ($missing.Count -gt 0) {
        throw "Na injectie ontbreken in de bouwmap: $($missing -join ', ')"
    }
    Write-Success "Custom bestanden geinjecteerd en geverifieerd ($($requiredScripts.Count + 1) bestanden)."

    # 4. Bouwen van de nieuwe ISO
    Write-Host "`n[5/5] Genereren van nieuwe ISO: $OutputIso" -ForegroundColor Cyan
    
    $etfsboot = Join-Path $tempFolder "boot\etfsboot.com"
    $efisys = Join-Path $tempFolder "efi\microsoft\boot\efisys.bin"

    # Zonder deze twee bestanden bouwt oscdimg een ISO die nergens van boot. Hij klaagt daar
    # niet altijd over, dus zelf controleren.
    if (-not (Test-Path $etfsboot)) { throw "Bootbestand ontbreekt: $etfsboot (BIOS-boot onmogelijk)" }
    if (-not (Test-Path $efisys))   { throw "Bootbestand ontbreekt: $efisys (UEFI-boot onmogelijk)" }

    # Robuuste afhandeling van absolute vs relatieve paden
    $cleanOutputIso = $OutputIso.Trim('"').Trim("'")
    if ([System.IO.Path]::IsPathRooted($cleanOutputIso)) {
        $fullOutputPath = [System.IO.Path]::GetFullPath($cleanOutputIso)
    } else {
        $fullOutputPath = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot $cleanOutputIso))
    }

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
    
    if ($process.ExitCode -ne 0) {
        throw "oscdimg faalde met exitcode $($process.ExitCode)"
    }
    if (-not (Test-Path $fullOutputPath)) {
        throw "oscdimg meldde succes maar $fullOutputPath bestaat niet"
    }

    # Een ISO van een paar MB betekent dat de bouwmap grotendeels leeg was. Beter hier
    # klagen dan bij de installatie.
    $isoSizeGb = [math]::Round((Get-Item $fullOutputPath).Length / 1GB, 2)
    if ($isoSizeGb -lt 3) {
        throw "Gebouwde ISO is slechts $isoSizeGb GB - dat is te klein voor een Windows 11 image, de bouwmap was waarschijnlijk onvolledig"
    }

    Write-Header 'ISO SUCCESVOL GEBOUWD!'
    Write-Success "Locatie: $fullOutputPath ($isoSizeGb GB)"

} catch {
    Write-Err "Er is een kritieke fout opgetreden: $_"
    exit 1
} finally {
    # De dismount stond voorheen alleen in de try. Brak het script daarvoor af (of Ctrl-C
    # tijdens de meerdere GB's grote kopie), dan bleef de bron-ISO gemount en faalde de
    # volgende run met een nietszeggende fout.
    if ($isoMounted) {
        Write-Host "`nBron ISO demonteren..." -ForegroundColor Gray
        Dismount-DiskImage -ImagePath $SourceIso -ErrorAction SilentlyContinue | Out-Null
    }

    # 5. Opruimen
    if (Test-Path $tempFolder) {
        Write-Host "`nSchoonmaken van tijdelijke bouwmap..." -ForegroundColor Gray
        Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}