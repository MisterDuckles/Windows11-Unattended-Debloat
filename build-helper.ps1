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

.PARAMETER DriversDir
    Map met uitgepakte driverpakketten (.inf/.sys/.cat, submappen mogen) die tijdens setup
    beschikbaar moeten zijn. Standaard: de map "drivers" naast dit script.

    Waarom dit bestaat: Windows Setup draait in WinPE, en WinPE heeft alleen wat er in boot.wim
    zit. Een moderne precisie-touchpad hangt aan de I2C-bus, dus je hebt de GPIO- en I2C-
    controllerdrivers van het platform nodig. Op 25H2 zijn die in-box alleen aanwezig voor AMD en
    voor Intel t/m Coffee Lake/Gemini Lake - voor Tiger Lake en nieuwer (2021+) niet. Op zulke
    laptops werkt het touchpad tijdens setup dus niet en moet je met Tab door het partitiescherm.

    Wat er met de inhoud gebeurt (allebei, met dezelfde bestanden):
      1. injectie in boot.wim (het Setup-image) via DISM - dit laat het touchpad werken op het
         partitiescherm, want WinPE laadt die drivers bij het opstarten;
      2. kopie naar $WinPEDriver$ in de ISO-root - Setup zet ze daarmee ook klaar voor het
         geinstalleerde Windows.
    Bewust dezelfde bestanden: KB2686316 waarschuwt dat twee VERSCHILLENDE versies van dezelfde
    driver via die twee routes ervoor zorgen dat de verliezer als "bad driver" wordt gemarkeerd.

    Zie drivers\README.md voor waar je die pakketten vandaan haalt.

.PARAMETER HarvestInputDrivers
    Exporteert de I2C-, GPIO-, HID-, muis- en toetsenborddrivers van de BUILDMACHINE en neemt die
    mee in de ISO. Handig als je de ISO bouwt op een machine van dezelfde generatie als de doel-
    laptop; nutteloos als de hardware niet lijkt (een AMD-buildmachine levert geen Intel Serial
    IO-driver op). Komt bovenop wat er in -DriversDir staat.

.PARAMETER TouchpadDrivers
    Ask (standaard) | Download | Skip.
    De Intel Serial IO-drivers (I2C + GPIO, de laag waar een modern touchpad aan hangt) per
    generatie ophalen van de Microsoft Update Catalog en in drivers\IntelSerialIO\ zetten, waarna
    ze de gewone driverroute volgen (boot.wim + $WinPEDriver$). Dekt Ice Lake (2019) t/m Panther
    Lake (2026); oudere generaties en AMD zitten al in boot.wim.
      Ask      - vraagt het in de terminal (Enter = ja). Geschikt voor handmatig bouwen.
      Download - zonder vraag ophalen. Voor scripts/CI.
      Skip     - zonder vraag overslaan. Eerder gedownloade pakketten in drivers\ gaan WEL mee;
                 wil je die kwijt, verwijder dan drivers\IntelSerialIO\.
    Al opgehaalde versies worden hergebruikt; een nieuwere versie vervangt de oude, zodat er
    nooit twee versies van hetzelfde pakket in de ISO belanden.
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
    [string]$ScriptsBaseUrl = "https://raw.githubusercontent.com/MisterDuckles/Windows11-Unattended-Debloat/master/sources/%24OEM%24/%24%24/Setup/Scripts",

    [Parameter(Mandatory = $false)]
    [string]$DriversDir,

    [Parameter(Mandatory = $false)]
    [switch]$HarvestInputDrivers,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Ask', 'Download', 'Skip')]
    [string]$TouchpadDrivers = 'Ask'
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

# -------------------------------------------------------------------------
# DRIVERS: helpers
# -------------------------------------------------------------------------
# Zie de .PARAMETER-tekst bij DriversDir voor het waarom. Kort: WinPE heeft alleen de drivers
# die in boot.wim zitten, en de I2C/GPIO-controllers waar een modern touchpad aan hangt zitten
# daar op 25H2 alleen in voor AMD en voor Intel t/m Coffee Lake / Gemini Lake.

function Get-InfCount {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return 0 }
    return @(Get-ChildItem -Path $Path -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue).Count
}

function Export-LocalInputDriver {
    <#
        Exporteert de driverpakketten van de BUILDMACHINE die met invoer te maken hebben.
        Twee selectiemethodes, allebei nodig:
          1) pakketten die horen bij apparaten die NU in deze machine zitten - dit vangt precies
             de touchpad/I2C-stack van dit model, ook als de bestandsnaam nergens op lijkt;
          2) een naamfilter over alle out-of-box pakketten - dit vangt controllers die op dit
             moment geen aangesloten apparaat hebben.
        Alleen out-of-box (oem*.inf) pakketten: in-box drivers zitten al in boot.wim.
    #>
    param([Parameter(Mandatory)][string]$Destination)

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    try {
        $devices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object {
            ($_.Class -eq 'HIDClass') -or ($_.Class -eq 'Mouse') -or ($_.Class -eq 'Keyboard') -or
            ($_.FriendlyName -match 'I2C|GPIO|Serial\s?IO|touch')
        })
        foreach ($d in $devices) {
            try {
                $inf = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction Stop).Data
                if ($inf -and ($inf -match '^oem\d+\.inf$')) { [void]$wanted.Add($inf) }
            } catch { }
        }
    } catch {
        Write-Warn "Kon de aanwezige invoerapparaten niet uitlezen: $($_.Exception.Message)"
    }

    try {
        foreach ($pkg in @(Get-WindowsDriver -Online -ErrorAction Stop)) {
            $orig = [IO.Path]::GetFileName([string]$pkg.OriginalFileName)
            if (($pkg.ClassName -eq 'HIDClass') -or ($pkg.ClassName -eq 'Mouse') -or ($pkg.ClassName -eq 'Keyboard') -or
                ($orig -match 'ialpss|amdi2c|amdgpio|hidi2c|hidspi|serialio|i2c|gpio|elan|syna|alps|touchpad')) {
                [void]$wanted.Add([string]$pkg.Driver)
            }
        }
    } catch {
        Write-Warn "Kon de driverstore van deze machine niet uitlezen: $($_.Exception.Message)"
    }

    $exported = 0
    foreach ($inf in $wanted) {
        $target = Join-Path $Destination ("harvested_" + [IO.Path]::GetFileNameWithoutExtension($inf))
        try {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            $null = & pnputil.exe /export-driver $inf "$target" 2>&1
            if ((Get-InfCount -Path $target) -gt 0) {
                $exported++
            } else {
                Remove-Item -Path $target -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Remove-Item -Path $target -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return $exported
}

function Add-DriverToWinPe {
    <#
        Injecteert de drivers in het Setup-image van boot.wim. Dit is de route die het touchpad
        op het partitiescherm laat werken: WinPE laadt zijn drivers bij het opstarten, dus ze
        moeten erin zitten voordat setup.exe start.
        Geeft het aantal out-of-box drivers in het image terug NA de injectie - teruggemeten in
        plaats van aangenomen, want een stille mislukking kost je een hele installatiecyclus.
    #>
    param(
        [Parameter(Mandatory)][string]$BootWim,
        [Parameter(Mandatory)][string]$DriverRoot,
        [Parameter(Mandatory)][string]$MountDir
    )

    # Bestanden die van een gemounte ISO zijn gekopieerd, zijn read-only. DISM kan een read-only
    # WIM niet mounten om naar te schrijven.
    $wimItem = Get-Item -Path $BootWim
    if ($wimItem.IsReadOnly) { $wimItem.IsReadOnly = $false }

    $images = @(Get-WindowsImage -ImagePath $BootWim -ErrorAction Stop)
    $setupImage = $images | Where-Object { $_.ImageName -match 'Setup' } | Select-Object -Last 1
    if (-not $setupImage) { $setupImage = $images | Select-Object -Last 1 }
    if (-not $setupImage) { throw "boot.wim bevat geen enkel image" }

    New-Item -ItemType Directory -Path $MountDir -Force | Out-Null
    Mount-WindowsImage -ImagePath $BootWim -Index $setupImage.ImageIndex -Path $MountDir -ErrorAction Stop | Out-Null

    $mounted = $true
    try {
        # Niet -ErrorAction Stop: DISM struikelt over een enkel onbruikbaar pakket (niet
        # ondertekend, verkeerde architectuur) en dan zou een kapotte map in drivers\ de hele
        # build afbreken terwijl de rest prima geinjecteerd is. We melden het en meten daarna
        # terug hoeveel er echt in het image zitten - dat is het antwoord dat telt.
        try {
            Add-WindowsDriver -Path $MountDir -Driver $DriverRoot -Recurse -ErrorAction Stop | Out-Null
        } catch {
            Write-Warn "DISM meldde een probleem bij het injecteren: $($_.Exception.Message)"
            Write-Warn "Meestal een niet-ondertekende of niet-amd64 driver. Controleer hieronder hoeveel er wel doorkwamen."
        }
        $inImage = @(Get-WindowsDriver -Path $MountDir -ErrorAction SilentlyContinue)
        Dismount-WindowsImage -Path $MountDir -Save -ErrorAction Stop | Out-Null
        $mounted = $false
        return $inImage.Count
    } finally {
        # Een blijvende mount blokkeert het opruimen van de bouwmap en de volgende run.
        # De discard zit in een eigen try: DISM gooit deze fout terminerend (langs
        # -ErrorAction heen) en die zou dan de echte oorzaak hierboven verdringen.
        if ($mounted) {
            try { Dismount-WindowsImage -Path $MountDir -Discard -ErrorAction Stop | Out-Null }
            catch { Write-Warn "Kon de boot.wim-mount $MountDir niet demonteren: $($_.Exception.Message)" }
        }
    }
}

# -------------------------------------------------------------------------
# DRIVERS: Intel Serial IO ophalen van de Microsoft Update Catalog
# -------------------------------------------------------------------------
# Waarom de catalog: Intel biedt Serial IO niet meer als losse download aan en OEM-sites zijn
# per laptopmodel. De Microsoft Update Catalog is de enige leverancier-neutrale bron die zich
# laat scripten - het is ook waar Windows Update ze zelf vandaan haalt.
#
# Hoe het werkt (nagemeten 2026-08-22):
#   1. Search.aspx?q=<hardware-ID>  -> HTML met een tabel; elke rij heeft het update-ID in
#      <tr id="<guid>_R<n>">. De rijen staan nieuwste-eerst, maar de titelvorm wisselt
#      ("Intel Corporation - System - 30.100.2129.8" naast "Intel Corporation System Driver
#      Update (30.100.2527.40)"), dus het versienummer wordt met een regex uit de titel gevist.
#   2. ScopedViewInline.aspx?updateid=<guid> -> detailpagina met "Driver Model" en de lijst
#      ondersteunde hardware-ID's. Daarop wordt gecontroleerd dat het echt de I2C-controller is:
#      bij DEV_7F78 (Arrow Lake-S) kwam de Integrated Sensor Hub-driver bovenaan te staan.
#   3. POST DownloadDialog.aspx met updateIDs=[{...}] -> JavaScript met de .cab-URL erin.
#   4. expand.exe -F:* pakt de .cab uit. Elke .cab bleek het COMPLETE Serial IO-pakket van die
#      generatie te bevatten (GPIO + I2C + SPI + UART, soms I3C), WHQL-ondertekend door
#      "Microsoft Windows Hardware Compatibility Publisher". Een download per generatie volstaat.
#
# Sorteren op de catalog-pagina (ASP.NET-postback met __VIEWSTATE) is bewust NIET gebruikt: dat
# gaf een foutpagina terug en is precies het soort mechaniek dat stuk gaat als Microsoft de
# site aanpast. Pagina 1 plus versienummer-in-titel is genoeg.

$CatalogBaseUrl = 'https://www.catalog.update.microsoft.com'

# Een representatieve I2C-controller per Intel-generatie zonder in-box driver in boot.wim.
# Het pakket dat eraan hangt dekt de hele familie (de TGL-INF bevat bv. ook alle TGL-H-ID's,
# de MTL-INF ook Arrow Lake-H). Generaties t/m Comet Lake staan hier niet: die zitten in-box.
# Desktop-chipsets (ADL-S/RPL-S) ook niet: geen touchpad, en hun I2C-pakket is hetzelfde als ADL.
$IntelSerialIoGenerations = @(
    @{ Key = 'IceLake';     Name = 'Ice Lake (10e gen mobiel, 2019-2020)';                   HwId = 'PCI\VEN_8086&DEV_34E8' },
    @{ Key = 'JasperLake';  Name = 'Jasper Lake (Celeron/Pentium N, 2021)';                   HwId = 'PCI\VEN_8086&DEV_4DE8' },
    @{ Key = 'TigerLake';   Name = 'Tiger Lake (11e gen, 2020-2021)';                          HwId = 'PCI\VEN_8086&DEV_A0E8' },
    @{ Key = 'AlderLake';   Name = 'Alder Lake / Raptor Lake (12e-14e gen, 2022-2024)';        HwId = 'PCI\VEN_8086&DEV_51E8' },
    @{ Key = 'AlderLakeN';  Name = 'Alder Lake-N (instapmodellen, 2023)';                      HwId = 'PCI\VEN_8086&DEV_54E8' },
    @{ Key = 'MeteorLake';  Name = 'Meteor Lake / Arrow Lake-H (Core Ultra serie 1 en 200H)';  HwId = 'PCI\VEN_8086&DEV_7E78' },
    @{ Key = 'LunarLake';   Name = 'Lunar Lake (Core Ultra 200V, 2024-2025)';                  HwId = 'PCI\VEN_8086&DEV_A878' },
    @{ Key = 'PantherLake'; Name = 'Panther Lake (Core Ultra serie 3, 2026)';                  HwId = 'PCI\VEN_8086&DEV_E478' }
)

function Invoke-CatalogRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Body,
        [string]$OutFile,
        [int]$TimeoutSec = 60
    )
    $params = @{ Uri = $Uri; UseBasicParsing = $true; TimeoutSec = $TimeoutSec; ErrorAction = 'Stop' }
    if ($Body)    { $params.Method = 'Post'; $params.Body = $Body }
    if ($OutFile) { $params.OutFile = $OutFile }
    return Invoke-WebRequest @params
}

function Get-CatalogSearchRow {
    <# Parseert de resultatentabel van Search.aspx naar objecten met Id, Title en Version. #>
    param([Parameter(Mandatory)][string]$Html)

    foreach ($row in [regex]::Matches($Html, '(?s)<tr id="([0-9a-f-]{36})_R\d+".*?</tr>')) {
        $cells = @([regex]::Matches($row.Value, '(?s)<td[^>]*>(.*?)</td>') | ForEach-Object {
            ([regex]::Replace($_.Groups[1].Value, '<[^>]+>', '')).Trim() -replace '\s+', ' '
        })
        if ($cells.Count -lt 5) { continue }
        $title = [Net.WebUtility]::HtmlDecode($cells[1])
        $ver = [regex]::Match($title, '(\d+\.\d+\.\d+\.\d+)').Groups[1].Value
        if (-not $ver) { continue }
        [pscustomobject]@{
            Id      = $row.Groups[1].Value
            Title   = $title
            Date    = $cells[4]
            Version = [version]$ver
        }
    }
}

function Get-CatalogDriverDetail {
    <# Leest "Driver Model" en de lijst hardware-ID's van de detailpagina van een update. #>
    param([Parameter(Mandatory)][string]$UpdateId)

    $html = (Invoke-CatalogRequest -Uri "$CatalogBaseUrl/ScopedViewInline.aspx?updateid=$UpdateId").Content
    $text = [Net.WebUtility]::HtmlDecode([regex]::Replace($html, '<[^>]+>', "`n"))
    [pscustomobject]@{
        Model        = [regex]::Match($text, '(?s)Driver Model:\s*(.+?)\n').Groups[1].Value.Trim()
        Architecture = [regex]::Match($text, '(?s)Architecture:\s*(.+?)\n').Groups[1].Value.Trim()
        HardwareIds  = @([regex]::Matches($text, '(?im)^\s*((?:pci|acpi)\\[a-z0-9_&]+)\s*$') | ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() } | Sort-Object -Unique)
    }
}

function Get-CatalogDownloadUrl {
    param([Parameter(Mandatory)][string]$UpdateId)

    $body = @{
        updateIDs                 = '[{"size":0,"updateID":"' + $UpdateId + '","uidInfo":"' + $UpdateId + '"}]'
        updateIDsBlockedForImport = ''
        wsusApiPresent            = ''
        contentImport             = ''
        sku                       = ''
        serverName                = ''
        ssl                       = ''
        portNumber                = ''
        version                   = ''
    }
    $html = (Invoke-CatalogRequest -Uri "$CatalogBaseUrl/DownloadDialog.aspx" -Body $body).Content
    $urls = @([regex]::Matches($html, 'https?://[^''"\s]+\.cab') | ForEach-Object { $_.Value } | Sort-Object -Unique)
    if ($urls.Count -eq 0) { throw "DownloadDialog.aspx gaf geen .cab-URL terug" }
    return $urls[0]
}

function Test-DriverPackageSigned {
    <# Elke .cat in de map moet een geldige Authenticode-handtekening hebben. DISM weigert
       ongesigneerde drivers toch al, maar liever hier meteen weten waar we aan toe zijn. #>
    param([Parameter(Mandatory)][string]$Path)

    $cats = @(Get-ChildItem -Path $Path -Filter *.cat -Recurse -File -ErrorAction SilentlyContinue)
    if ($cats.Count -eq 0) { return $false }
    foreach ($cat in $cats) {
        if ((Get-AuthenticodeSignature -FilePath $cat.FullName).Status -ne 'Valid') { return $false }
    }
    return $true
}

function Get-IntelSerialIoDriver {
    <#
        Haalt per generatie uit $IntelSerialIoGenerations het nieuwste Serial IO-pakket op en zet
        het in $Destination\<Key>_<versie>\. Bestaat die map al met INF's erin, dan wordt niets
        gedownload. Een oudere map van dezelfde generatie wordt vervangen, zodat er nooit twee
        versies van hetzelfde pakket in de ISO komen (zie KB2686316 in de README).
        Geeft een overzicht terug; mislukkingen per generatie zijn waarschuwingen, geen fouten.

        TIJDSBUDGET: de catalog gaat na een paar dozijn zoekopdrachten vanaf hetzelfde adres
        throttlen - Search.aspx liep op 2026-08-22 ineens in 30+ seconden vast terwijl Home.aspx
        in 1 seconde antwoordde. Een build mag daar niet minutenlang op blijven hangen. Daarom:
        korte time-outs, en na twee time-outs op rij stopt het ophalen; generaties die al in de
        cache staan worden dan gebruikt zonder versiecheck.
    #>
    param([Parameter(Mandatory)][string]$Destination)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    function Get-CachedPackageDir {
        param([string]$Key)
        Get-ChildItem -Path $Destination -Directory -Filter "${Key}_*" -ErrorAction SilentlyContinue |
            Where-Object { (Get-InfCount -Path $_.FullName) -gt 0 } |
            Sort-Object Name -Descending | Select-Object -First 1
    }

    $fetched = 0; $cachedCount = 0; $failed = 0; $names = @()
    $catalogDown = $false
    $timeoutsInARow = 0

    # Een snelle bereikbaarheidstest, anders wacht elke generatie afzonderlijk op een timeout.
    try {
        $null = Invoke-CatalogRequest -Uri "$CatalogBaseUrl/Home.aspx" -TimeoutSec 20
    } catch {
        Write-Warn "Microsoft Update Catalog is niet bereikbaar ($($_.Exception.Message))."
        $catalogDown = $true
    }

    $tempRoot = Join-Path $env:TEMP "Win11_SerialIO_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    try {
        foreach ($gen in $IntelSerialIoGenerations) {
            $cachedDir = Get-CachedPackageDir -Key $gen.Key

            if ($catalogDown) {
                if ($cachedDir) {
                    Write-Host "    [cache] $($gen.Name): $($cachedDir.Name) (catalog niet bereikbaar, versie niet gecontroleerd)" -ForegroundColor Gray
                    $cachedCount++; $names += $cachedDir.Name
                } else {
                    Write-Warn "$($gen.Name): niet in cache en catalog niet bereikbaar - overgeslagen"
                    $failed++
                }
                continue
            }

            try {
                $searchUrl = "$CatalogBaseUrl/Search.aspx?q=" + [Uri]::EscapeDataString($gen.HwId)
                $rows = @(Get-CatalogSearchRow -Html (Invoke-CatalogRequest -Uri $searchUrl -TimeoutSec 30).Content |
                    Where-Object { $_.Title -match '^Intel' } | Sort-Object Version -Descending)
                if ($rows.Count -eq 0) { throw "geen Intel-treffers in de catalog voor $($gen.HwId)" }

                # De bovenste treffer is meestal raak, maar niet altijd de juiste driverklasse.
                # Daarom maximaal drie kandidaten langs de detailpagina halen.
                $chosen = $null
                foreach ($row in ($rows | Select-Object -First 3)) {
                    $detail = Get-CatalogDriverDetail -UpdateId $row.Id
                    if (($detail.Model -match 'Serial IO I2C') -and ($detail.Architecture -match 'AMD64') -and ($detail.HardwareIds -contains $gen.HwId.ToUpperInvariant())) {
                        $chosen = $row; break
                    }
                }
                if (-not $chosen) { throw "geen kandidaat op pagina 1 is een AMD64 Serial IO I2C-driver voor $($gen.HwId)" }
                $timeoutsInARow = 0

                $targetDir = Join-Path $Destination "$($gen.Key)_$($chosen.Version)"
                if ((Get-InfCount -Path $targetDir) -gt 0) {
                    Write-Host "    [cache] $($gen.Name): v$($chosen.Version) staat al klaar" -ForegroundColor Gray
                    $cachedCount++; $names += "$($gen.Key) v$($chosen.Version)"
                    continue
                }

                $cabUrl  = Get-CatalogDownloadUrl -UpdateId $chosen.Id
                $cabFile = Join-Path $tempRoot "$($gen.Key).cab"
                $workDir = Join-Path $tempRoot $gen.Key
                New-Item -ItemType Directory -Path $workDir -Force | Out-Null
                $null = Invoke-CatalogRequest -Uri $cabUrl -OutFile $cabFile -TimeoutSec 180
                if ((Get-Item $cabFile).Length -lt 10KB) { throw "gedownloade .cab is verdacht klein ($((Get-Item $cabFile).Length) bytes)" }

                $null = & expand.exe -F:* "$cabFile" "$workDir" 2>&1
                if ($LASTEXITCODE -ne 0) { throw "expand.exe faalde met exitcode $LASTEXITCODE" }

                # Inhoudelijke controle: het moet het Serial IO-pakket zijn, met I2C EN GPIO, en
                # elke catalogus moet een geldige handtekening hebben.
                $infNames = @(Get-ChildItem -Path $workDir -Filter *.inf -Recurse -File | ForEach-Object { $_.Name })
                if (-not ($infNames -match '^iaLPSS2_I2C_'))   { throw "uitgepakt pakket bevat geen iaLPSS2_I2C_*.inf (wel: $($infNames -join ', '))" }
                if (-not ($infNames -match '^iaLPSS2_GPIO2_')) { throw "uitgepakt pakket bevat geen iaLPSS2_GPIO2_*.inf (wel: $($infNames -join ', '))" }
                if (-not (Test-DriverPackageSigned -Path $workDir)) { throw "een of meer .cat-bestanden hebben geen geldige handtekening" }

                # Sommige pakketten bevatten ook INF's voor generaties die al IN-BOX in boot.wim
                # zitten: het Ice Lake-pakket levert bv. iaLPSS2_*_SKL.inf mee, met exact dezelfde
                # hardware-ID's als de in-box iaLPSS2i_*_SKL.inf (nagemeten 2026-08-22). Twee
                # versies van een driver voor hetzelfde apparaat is precies wat KB2686316 afraadt,
                # dus die INF's gaan eruit, samen met hun .cat. De .sys blijft staan: die wordt
                # gedeeld met de INF's die we wel houden.
                $inboxFamilies = 'SKL|BXT_P|BXT|APL|CNL|CML|GLK'
                foreach ($dup in (Get-ChildItem -Path $workDir -Filter *.inf -Recurse -File | Where-Object { $_.Name -match "^iaLPSS2_\w+?_($inboxFamilies)\.inf$" })) {
                    Remove-Item -Path $dup.FullName -Force -ErrorAction SilentlyContinue
                    Remove-Item -Path (Join-Path $dup.DirectoryName ($dup.BaseName + '.cat')) -Force -ErrorAction SilentlyContinue
                }
                $infNames = @(Get-ChildItem -Path $workDir -Filter *.inf -Recurse -File | ForEach-Object { $_.Name })
                if (-not ($infNames -match '^iaLPSS2_I2C_')) { throw "na het filteren van in-box generaties blijft er geen I2C-INF over" }

                # Oudere versie van dezelfde generatie opruimen VOOR de nieuwe erin gaat.
                Get-ChildItem -Path $Destination -Directory -Filter "$($gen.Key)_*" -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                Move-Item -Path $workDir -Destination $targetDir -Force -ErrorAction Stop
                Remove-Item -Path $cabFile -Force -ErrorAction SilentlyContinue

                Write-Success "$($gen.Name): v$($chosen.Version) opgehaald ($($infNames -join ', '))"
                $fetched++; $names += "$($gen.Key) v$($chosen.Version)"
            } catch {
                $msg = $_.Exception.Message
                if ($msg -match 'timed out|time-out|timeout') {
                    $timeoutsInARow++
                    if ($timeoutsInARow -ge 2) {
                        $catalogDown = $true
                        Write-Warn "Catalog reageert niet meer (2 time-outs op rij) - de overige generaties komen uit de cache of worden overgeslagen."
                    }
                }
                if ($cachedDir) {
                    Write-Host "    [cache] $($gen.Name): $($cachedDir.Name) (versiecheck mislukt: $msg)" -ForegroundColor Gray
                    $cachedCount++; $names += $cachedDir.Name
                } else {
                    Write-Warn "$($gen.Name): overgeslagen - $msg"
                    $failed++
                }
            }
        }
    } finally {
        Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{ Fetched = $fetched; Cached = $cachedCount; Failed = $failed; Names = $names }
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
# DRIVERS: waar ze vandaan komen, en de touchpad-drivers ophalen
# -------------------------------------------------------------------------
# Deze twee paden staan buiten het try-blok omdat het finally-blok ze leest: een achtergebleven
# WIM-mount blokkeert zowel het opruimen van de bouwmap als de volgende run.
$driversSource = $DriversDir
if (-not $driversSource) { $driversSource = Join-Path $scriptRoot 'drivers' }
$wimMountDir = Join-Path $env:TEMP "Win11_WimMount_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

# Dit gebeurt VOOR het mounten en kopieren van de ISO (dat duurt minuten), zodat de vraag
# meteen komt en je daarna weg kunt lopen. Geen internet is geen fout: dan bouwen we met wat
# er al in drivers\ staat.
Write-Host "`n[2b/5] Touchpad-drivers voor Windows Setup..." -ForegroundColor Cyan
$serialIoDir = Join-Path $driversSource 'IntelSerialIO'
$serialIoCached = @(Get-ChildItem -Path $serialIoDir -Directory -ErrorAction SilentlyContinue | Where-Object { (Get-InfCount -Path $_.FullName) -gt 0 }).Count

$fetchSerialIo = $false
switch ($TouchpadDrivers) {
    'Download' { $fetchSerialIo = $true }
    'Skip'     { $fetchSerialIo = $false }
    default {
        Write-Host "    Op Intel-laptops van 2020 of nieuwer werkt het touchpad tijdens setup NIET zonder de" -ForegroundColor Gray
        Write-Host "    Intel Serial IO-drivers (I2C/GPIO). Die zijn per generatie op te halen van de Microsoft" -ForegroundColor Gray
        Write-Host "    Update Catalog (8 pakketten, samen ~2 MB) en worden in boot.wim en `$WinPEDriver`$ gezet." -ForegroundColor Gray
        if ($serialIoCached -gt 0) {
            Write-Host "    Er staan al $serialIoCached pakket(ten) in $serialIoDir; 'j' controleert op nieuwere versies." -ForegroundColor Gray
        }
        $answer = Read-Host "    Touchpad-drivers ophalen en meebakken? (J/n)"
        $fetchSerialIo = ($answer -notmatch '^(n|nee|no)$')
    }
}

if ($fetchSerialIo) {
    $serialIoResult = Get-IntelSerialIoDriver -Destination $serialIoDir
    if (($serialIoResult.Fetched + $serialIoResult.Cached) -gt 0) {
        Write-Success "Intel Serial IO: $($serialIoResult.Fetched) opgehaald, $($serialIoResult.Cached) uit cache, $($serialIoResult.Failed) mislukt."
    } else {
        Write-Warn "Geen enkel Serial IO-pakket beschikbaar - touchpad werkt tijdens setup niet op nieuwere Intel-laptops."
    }
} elseif ($serialIoCached -gt 0) {
    Write-Host "    Niet opgehaald; de $serialIoCached eerder gedownloade pakket(ten) in drivers\IntelSerialIO gaan wel mee." -ForegroundColor Gray
} else {
    Write-Warn "Overgeslagen. Zonder deze drivers moet je op nieuwere Intel-laptops met Tab door het partitiescherm."
}

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

    # 3b. Drivers voor Windows Setup
    #
    # Zonder dit werkt op een moderne Intel-laptop het touchpad niet op het partitiescherm: de
    # I2C- en GPIO-controllers waar zo'n precisie-touchpad aan hangt hebben op 25H2 geen in-box
    # driver voor Tiger Lake en nieuwer (nagemeten: geen INF voor DEV_A0E8, DEV_51E8, DEV_7ACC,
    # DEV_51E9, DEV_7E78, INTC1055, INTC1085, INTC1083). Je moet dan met Tab door setup.
    Write-Host "`n[4b/5] Drivers voor Windows Setup verwerken..." -ForegroundColor Cyan

    $driverStaging = Join-Path $tempFolder '_driverstaging'
    New-Item -ItemType Directory -Path $driverStaging -Force | Out-Null

    if (Test-Path $driversSource) {
        $repoInfCount = Get-InfCount -Path $driversSource
        if ($repoInfCount -gt 0) {
            # -Exclude *.md houdt drivers\README.md uit de ISO; die map is verder van de gebruiker.
            Get-ChildItem -Path $driversSource -Exclude '*.md' |
                Copy-Item -Destination $driverStaging -Recurse -Force -ErrorAction Stop
            Write-Success "$repoInfCount driver(s) uit $driversSource overgenomen."
        }
    }

    if ($HarvestInputDrivers) {
        Write-Host "    Invoerdrivers van deze buildmachine exporteren..." -ForegroundColor Gray
        $harvested = Export-LocalInputDriver -Destination $driverStaging
        if ($harvested -gt 0) {
            Write-Success "$harvested driverpakket(ten) van deze machine geexporteerd."
        } else {
            Write-Warn "Geen exporteerbare invoerdrivers gevonden op deze machine (alles in-box?)."
        }
    }

    $stagedInfCount = Get-InfCount -Path $driverStaging
    if ($stagedInfCount -eq 0) {
        # Geen harde fout: op AMD-hardware en oudere Intel werkt het touchpad prima met de
        # in-box drivers. Wel expliciet melden, want anders lijkt een ISO zonder drivers
        # hetzelfde als een ISO met drivers - tot je op een laptop staat zonder muis.
        Write-Warn "Geen drivers gevonden in $driversSource - ISO wordt zonder extra drivers gebouwd."
        Write-Warn "Op Intel-laptops van 2021 of nieuwer werkt het touchpad dan NIET tijdens setup."
        Write-Warn "Zie drivers\README.md, of bouw met -HarvestInputDrivers op een vergelijkbare machine."
    } else {
        # Route 1: in boot.wim. Dit is wat het touchpad op het partitiescherm laat werken.
        $bootWim = Join-Path $tempFolder 'sources\boot.wim'
        if (-not (Test-Path $bootWim)) { throw "sources\boot.wim ontbreekt in de bouwmap - kan geen setup-drivers injecteren" }

        Write-Host "    $stagedInfCount driver(s) injecteren in boot.wim (dit duurt even)..." -ForegroundColor Gray
        $inImage = Add-DriverToWinPe -BootWim $bootWim -DriverRoot $driverStaging -MountDir $wimMountDir
        if ($inImage -lt 1) {
            throw "DISM meldde geen fout, maar boot.wim bevat na de injectie geen enkele out-of-box driver"
        }
        Write-Success "boot.wim bevat nu $inImage out-of-box driver(s)."

        # Route 2: $WinPEDriver$ in de ISO-root. Setup scant die map op elke schijfletter vanaf C:
        # en zet de drivers ook klaar voor het geinstalleerde Windows. Bewust dezelfde bestanden
        # als hierboven: KB2686316 waarschuwt dat twee verschillende VERSIES van dezelfde driver
        # via deze twee routes elkaar uitschakelen.
        $winPeDriverDir = Join-Path $tempFolder '$WinPEDriver$'
        New-Item -ItemType Directory -Path $winPeDriverDir -Force | Out-Null
        Copy-Item -Path (Join-Path $driverStaging '*') -Destination $winPeDriverDir -Recurse -Force -ErrorAction Stop
        $copiedInf = Get-InfCount -Path $winPeDriverDir
        if ($copiedInf -lt $stagedInfCount) {
            throw "kopie naar `$WinPEDriver`$ is onvolledig ($copiedInf van $stagedInfCount INF-bestanden)"
        }
        Write-Success "$copiedInf driver(s) klaargezet in `$WinPEDriver`$ voor het geinstalleerde Windows."
    }

    # De stagingmap hoeft niet mee de ISO in; hij staat in de bouwmap en zou anders als losse
    # map op de installatiemedia belanden.
    Remove-Item -Path $driverStaging -Recurse -Force -ErrorAction SilentlyContinue

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
    if ($stagedInfCount -gt 0) {
        # Het aantal uit boot.wim is TERUGGEMETEN na de injectie, niet het aantal dat we
        # aanboden: staat hier een lager getal dan $stagedInfCount, dan heeft DISM pakketten
        # geweigerd (meestal niet ondertekend) en is dat hierboven al gemeld.
        Write-Success "Setup-drivers: $inImage pakket(ten) in boot.wim, $copiedInf INF(s) in `$WinPEDriver`$ (aangeboden: $stagedInfCount)."
    } else {
        Write-Warn "Setup-drivers: GEEN. Op Intel-laptops van 2021+ werkt het touchpad niet tijdens setup (zie drivers\README.md)."
    }

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

    # Een achtergebleven WIM-mount houdt bestanden in de bouwmap open, waardoor het opruimen
    # hieronder stilletjes mislukt en de volgende run struikelt over een halve mount.
    # Alleen demonteren als DISM de map ook echt nog als mount kent. Na een geslaagde
    # -Save dismount blijft de (lege) map staan; -Discard daarop levert "The request is not
    # supported" op, en die COMException komt terminerend uit de cmdlet - -ErrorAction
    # SilentlyContinue onderdrukt hem niet, dus eindigde een geslaagde build in het rood.
    if (Test-Path $wimMountDir) {
        $stillMounted = $null
        try {
            $stillMounted = @(Get-WindowsImage -Mounted -ErrorAction Stop) |
                Where-Object { $_.Path -and $_.Path.TrimEnd('\') -ieq $wimMountDir.TrimEnd('\') }
        } catch {
            # Mountlijst niet op te vragen; dan maar blind proberen, dat is veiliger dan
            # een echte mount laten staan.
            $stillMounted = $true
        }
        if ($stillMounted) {
            try { Dismount-WindowsImage -Path $wimMountDir -Discard -ErrorAction Stop | Out-Null }
            catch { Write-Warn "Kon de WIM-mount $wimMountDir niet demonteren: $($_.Exception.Message)" }
        }
        Remove-Item -Path $wimMountDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 5. Opruimen
    if (Test-Path $tempFolder) {
        Write-Host "`nSchoonmaken van tijdelijke bouwmap..." -ForegroundColor Gray
        Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}