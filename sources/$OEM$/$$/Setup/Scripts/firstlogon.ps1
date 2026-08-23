$logPath = "$env:USERPROFILE\debloat-firstlogon.log"
"$(Get-Date) First-logon script started" | Out-File $logPath -Append

# -----------------------------------------------------------------------------
# Instellingen
# -----------------------------------------------------------------------------
# Hoe lang dit script maximaal op internet wacht voordat het de netwerk-stappen
# overslaat. Tot 2026-08-22 stond hier 90 seconden. Dat is genoeg voor een bekabelde
# machine, maar niet voor een laptop: die heeft na de eerste inlog nog geen wifi en de
# gebruiker moet eerst zelf een netwerk kiezen. De 90 seconden waren dan al voorbij.
# Ruimer wachten kost niets op een bekabelde machine - de lus stopt zodra er verbinding is.
$NetworkWaitSeconds = 600

# Na hoeveel seconden zonder verbinding we de gebruiker een venster tonen met de vraag om
# wifi aan te zetten. Kort genoeg om niet te laat te komen, lang genoeg om op een normale
# bekabelde machine helemaal nooit te verschijnen.
$NetworkPromptAfterSeconds = 20

# Hoe vaak we opnieuw testen terwijl we wachten.
$NetworkPollSeconds = 5

# Hoe vaak dit script in totaal mag draaien als de netwerk-stappen niet lukten. Mislukken ze,
# dan blijft de scheduled task staan zodat de volgende inlog het opnieuw probeert; deze teller
# voorkomt dat dat eeuwig doorgaat op een machine die structureel geen internet krijgt.
$MaxFirstLogonRuns = 3

# -----------------------------------------------------------------------------
# Helper: explorer herstarten (gebruikt door stap 7)
# -----------------------------------------------------------------------------
# GESCHIEDENIS - niet opnieuw "verbeteren" zonder dit te lezen.
#
# Op 2026-08-12 heb ik dit eerst vervangen door een nette afsluiting via
# WM_USER+436 naar Shell_TrayWnd, om de Winlogon 1002 "shell stopped
# unexpectedly" uit het event log te houden. Dat was een verkeerde ruil en het
# brak de herstart: het afsluiten lukte, maar de shell kwam niet meer terug.
#
#   17:56:26  Shell closed gracefully via WM_USER+436
#   17:57:13  WARN: shell did not reappear within 45s
#
# Oorzaak: na WM_USER+436 herstart Windows de shell NIET zelf, en de guard die
# hem dan handmatig moest starten eiste dat er geen enkel explorer.exe-proces
# meer draaide. Open Verkenner-vensters (en het afbouwende shell-proces) maken
# die voorwaarde vrijwel altijd onwaar, dus de start werd overgeslagen en de
# gebruiker moest via Taakbeheer ingrijpen.
#
# Stop-Process -Force werkt wel: dat triggert AutoRestartShell (standaard aan),
# waarna Winlogon de shell zelf terugbrengt. De prijs is een cosmetische regel
# in het event log. Dat is het waard.
function Restart-ShellCleanly {
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [int]$StartupTimeoutSeconds = 45
    )

    # P/Invoke alleen nog om te KUNNEN CONTROLEREN of de taakbalk terug is.
    # De type-guard voorkomt een fout als deze functie twee keer wordt aangeroepen.
    if (-not ('Win11Debloat.ShellControl' -as [type])) {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Win11Debloat {
    public static class ShellControl {
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    }
}
'@
    }

    function Get-TrayHandle { [Win11Debloat.ShellControl]::FindWindow('Shell_TrayWnd', $null) }

    Stop-Process -Name "explorer" -Force -ErrorAction SilentlyContinue
    "$(Get-Date) Shell killed, waiting for AutoRestartShell to bring it back..." | Out-File $LogPath -Append

    # Wachten tot de taakbalk er weer staat, zodat de rest van het script niet
    # doorloopt terwijl de gebruiker naar een leeg bureaublad kijkt.
    $waited = 0
    while ($waited -lt $StartupTimeoutSeconds) {
        if ((Get-TrayHandle) -ne [IntPtr]::Zero) {
            "$(Get-Date) Shell is back after ${waited}s" | Out-File $LogPath -Append
            return $true
        }
        Start-Sleep -Milliseconds 500
        $waited += 0.5
    }

    # Laatste redmiddel. Komt AutoRestartShell om welke reden dan ook niet opdagen,
    # dan is een handmatige start beter dan de gebruiker met een leeg scherm laten
    # zitten. Dit is precies de vangnet-stap die op 2026-08-12 ontbrak.
    "$(Get-Date) WARN: shell did not return within ${StartupTimeoutSeconds}s, starting explorer.exe manually" | Out-File $LogPath -Append
    Start-Process -FilePath "$env:WINDIR\explorer.exe" -ErrorAction SilentlyContinue

    $waited = 0
    while ($waited -lt 20) {
        if ((Get-TrayHandle) -ne [IntPtr]::Zero) {
            "$(Get-Date) Shell is back after manual start" | Out-File $LogPath -Append
            return $true
        }
        Start-Sleep -Milliseconds 500
        $waited += 0.5
    }

    "$(Get-Date) ERROR: shell could not be restored - user may need to start explorer.exe from Task Manager" | Out-File $LogPath -Append
    return $false
}

# -----------------------------------------------------------------------------
# Helper: de Windows Update-blokkade uit autounattend.xml opheffen
# -----------------------------------------------------------------------------
function Remove-WindowsUpdateGate {
    param([Parameter(Mandatory)][string]$LogPath)

    try {
        $wu = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
        $au = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"

        # Loopback-WSUS uit autounattend.xml Orders 8-11. Blijven deze staan, dan faalt
        # elke update-check voorgoed met 0x80240438.
        foreach ($v in 'WUServer', 'WUStatusServer', 'UpdateServiceUrlAlternate') {
            Remove-ItemProperty -Path $wu -Name $v -ErrorAction SilentlyContinue
        }
        foreach ($v in 'UseWUServer', 'NoAutoUpdate') {
            Remove-ItemProperty -Path $au -Name $v -ErrorAction SilentlyContinue
        }

        # Vangnet voor machines die met een oudere ISO zijn uitgerold: deze key werd tot
        # 2026-08-12 gezet en brak de Microsoft Store (0x8024500C bij SLS-registratie).
        Remove-ItemProperty -Path $wu -Name "DoNotConnectToWindowsUpdateInternetLocations" -ErrorAction SilentlyContinue

        Restart-Service -Name wuauserv -Force -ErrorAction SilentlyContinue

        # Controleren in plaats van aannemen - dit is de enige stap waarvan stil falen
        # betekent dat de machine nooit meer een security-update krijgt.
        $leftover = @()
        foreach ($v in 'WUServer', 'WUStatusServer', 'UpdateServiceUrlAlternate') {
            if ($null -ne (Get-ItemProperty -Path $wu -Name $v -ErrorAction SilentlyContinue)) { $leftover += $v }
        }
        foreach ($v in 'UseWUServer', 'NoAutoUpdate') {
            if ($null -ne (Get-ItemProperty -Path $au -Name $v -ErrorAction SilentlyContinue)) { $leftover += $v }
        }

        if ($leftover.Count -gt 0) {
            "$(Get-Date) CRITICAL: Windows Update gate NOT fully removed, still present: $($leftover -join ', ')" | Out-File $LogPath -Append
            return $false
        }

        "$(Get-Date) Windows Update gate removed and verified clean" | Out-File $LogPath -Append
        return $true
    } catch {
        "$(Get-Date) CRITICAL: failed to remove Windows Update gate: $($_.Exception.Message)" | Out-File $LogPath -Append
        return $false
    }
}

# -----------------------------------------------------------------------------
# Helper: beveiligingsvragen voor lokale accounts uitzetten
# -----------------------------------------------------------------------------
# Toegevoegd 2026-08-22 na een installatie op een echte laptop: wie tijdens OOBE een wachtwoord
# koos, moest daarna alsnog drie beveiligingsvragen invullen.
#
# debloat.ps1 zette daarvoor "HideSecurityQuestionsFromLocalUsers". Die waardenaam bestaat niet -
# hij staat in geen enkele ADMX en in geen enkele systeem-DLL, dus die regel deed nooit iets.
# De echte policy heet NoLocalPasswordResetQuestions en staat in CredUI.admx:
#   Computer Configuration > Administrative Templates > Windows Components > Credential User
#   Interface > "Prevent the use of security questions for local accounts"
#   key: Software\Policies\Microsoft\Windows\System   value: NoLocalPasswordResetQuestions (DWORD 1)
#
# WAAROM HIER EN NIET IN debloat.ps1 (dat draait VOOR OOBE):
# de policy voor OOBE zetten is gerapporteerd als oorzaak van de OOBELOCAL-fout op de lokale-
# accountpagina van Windows 11 24H2 - dan loopt de installatie vast op precies het scherm waar je
# een account probeert te maken. Dat risico is deze winst niet waard. Na OOBE is de policy
# onschadelijk en doet hij wat we willen: wie later in Instellingen een wachtwoord toevoegt of
# wijzigt, krijgt geen vragenlijst meer.
#
# LET OP - dit haalt de vragen NIET weg uit het OOBE-scherm zelf. De enige betrouwbare manier om dat
# scherm over te slaan is het account door autounattend.xml laten aanmaken; zie het UserAccounts-
# blok in autounattend.xml en de README. Wie tijdens OOBE geen wachtwoord invult krijgt sowieso geen
# vragen, en kan er dankzij deze policy daarna zonder vragenlijst alsnog een instellen.
function Disable-LocalSecurityQuestions {
    param([Parameter(Mandatory)][string]$LogPath)

    try {
        $key = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name "NoLocalPasswordResetQuestions" -Value 1 -PropertyType DWord -Force | Out-Null

        # Opruimen: machines die met een ISO van voor 2026-08-22 zijn uitgerold hebben de
        # niet-bestaande waarde in het register staan. Hij doet niets, maar hij suggereert wel dat
        # dit geregeld is. Weg ermee, zodat het register vertelt wat er echt geldt.
        Remove-ItemProperty -Path $key -Name "HideSecurityQuestionsFromLocalUsers" -ErrorAction SilentlyContinue

        $check = Get-ItemProperty -Path $key -Name "NoLocalPasswordResetQuestions" -ErrorAction SilentlyContinue
        if ($null -eq $check -or [int]$check.NoLocalPasswordResetQuestions -ne 1) {
            "$(Get-Date) WARN: NoLocalPasswordResetQuestions could not be verified - security questions may still appear" | Out-File $LogPath -Append
            return $false
        }

        "$(Get-Date) Security questions for local accounts disabled (NoLocalPasswordResetQuestions=1, verified)" | Out-File $LogPath -Append
        return $true
    } catch {
        "$(Get-Date) WARN: could not disable local security questions: $($_.Exception.Message)" | Out-File $LogPath -Append
        return $false
    }
}

# -----------------------------------------------------------------------------
# Helper: extern proces starten met een harde tijdslimiet
# -----------------------------------------------------------------------------
# Start-Process -Wait heeft geen timeout. Een installer die op een dialoog wacht of
# vastloopt houdt daarmee het hele script tegen. Deze wrapper kapt af en geeft de
# exitcode terug, zodat de aanroeper kan zien of het echt gelukt is.
function Start-ProcessBounded {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 300,
        [Parameter(Mandatory)][string]$LogPath
    )

    # Geeft een object terug in plaats van een kaal getal. Reden: Start-Process -PassThru
    # levert in PowerShell 5.1 lang niet altijd een bruikbare ExitCode op - die kan $null
    # zijn terwijl het proces gewoon netjes klaar is. Een kale $null-return maakte
    # "afgekapt", "kon niet starten" en "klaar, code onbekend" ononderscheidbaar, en dat
    # leverde op 2026-08-12 een valse "installer timed out" op terwijl SetupToolbox
    # probleemloos was geinstalleerd.
    $result = [pscustomobject]@{ Started = $false; TimedOut = $false; ExitCode = $null }

    try {
        $params = @{ FilePath = $FilePath; PassThru = $true; NoNewWindow = $true }
        if ($ArgumentList.Count -gt 0) { $params.ArgumentList = $ArgumentList }
        $proc = Start-Process @params -ErrorAction Stop
        $result.Started = $true

        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            "$(Get-Date) WARN: $FilePath exceeded ${TimeoutSeconds}s, terminating" | Out-File $LogPath -Append
            try { $proc.Kill() } catch { }
            $result.TimedOut = $true
            return $result
        }

        try { $result.ExitCode = $proc.ExitCode } catch { }
        return $result
    } catch {
        "$(Get-Date) WARN: could not start $FilePath - $($_.Exception.Message)" | Out-File $LogPath -Append
        return $result
    }
}

# -----------------------------------------------------------------------------
# Helper: is er echt bruikbaar internet?
# -----------------------------------------------------------------------------
# Wat de rest van dit script nodig heeft is geen "link up", maar naamresolutie plus een
# werkende verbinding naar buiten. Daarom testen we precies dat, en DNS als eerste: zonder
# netwerk faalt die meteen, dus dat is de goedkoopste manier om "nog niets" vast te stellen.
#
# ICMP is bewust NIET de enige test. Veel bedrijfs- en gastnetwerken blokkeren ping. Met alleen
# een ping-check zou dit script op zo'n netwerk de volledige wachttijd uitzitten en daarna
# Firefox en SetupToolbox overslaan, terwijl er gewoon internet was.
function Test-InternetReady {
    # 1) Naamresolutie. Resolve-DnsName zit in de DnsClient-module; is die om wat voor reden dan
    #    ook niet beschikbaar, val dan terug op de .NET-resolver in plaats van ten onrechte
    #    "geen internet" te concluderen.
    try {
        if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
            $null = Resolve-DnsName -Name "github.com" -ErrorAction Stop
        } else {
            $null = [System.Net.Dns]::GetHostEntry("github.com")
        }
    } catch {
        return $false
    }

    # 2) Bereikbaarheid. Ping is de snelle route...
    if (Test-Connection -ComputerName "1.1.1.1" -Count 1 -Quiet -ErrorAction SilentlyContinue) {
        return $true
    }

    # ...en als ping geblokkeerd is, de NCSI-endpoint die Windows zelf gebruikt om te bepalen of
    # er internet is. Bewust niet api.github.com: die staat op 60 anonieme requests per uur en dat
    # quotum hebben we in stap 4 nodig voor de release-lookup.
    try {
        $probe = Invoke-WebRequest -Uri "http://www.msftconnecttest.com/connecttest.txt" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        return ($probe.StatusCode -eq 200)
    } catch {
        return $false
    }
}

# -----------------------------------------------------------------------------
# Helper: wachtvenster voor de gebruiker
# -----------------------------------------------------------------------------
# Dit script draait als scheduled task met -WindowStyle Hidden. Zonder dit venster ziet iemand op
# een laptop zonder kabel dus helemaal niets: geen melding, geen voortgang, alleen een bureaublad
# waar niets gebeurt - en achteraf ontbreken Firefox en SetupToolbox zonder dat duidelijk is
# waarom. Wachten op wifi heeft alleen zin als de gebruiker weet dat er gewacht wordt.
#
# Het venster draait in een APART proces, niet in een runspace binnen dit script. Reden: zo kan een
# fout in de UI dit script nooit meesleuren, en is afsluiten een simpele kill. Het kind sluit
# zichzelf ook af zodra de deadline verstrijkt of dit script wegvalt (het bewaakt de parent-PID),
# zodat er nooit een weesvenster op het bureaublad achterblijft.
function Show-NetworkPrompt {
    param(
        [Parameter(Mandatory)][datetime]$Deadline,
        [Parameter(Mandatory)][string]$LogPath
    )

    # Letterlijke here-string met placeholders in plaats van een interpolerende: in een
    # interpolerende here-string zou elke $-variabele van het kindscript hier al worden ingevuld,
    # en dat is precies het soort fout dat je pas in een VM ontdekt.
    $template = @'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$parentPid = __PARENTPID__
$deadline  = [datetime]::FromFileTime(__DEADLINE__)

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = "Windows wordt nog ingericht"
$form.ClientSize      = New-Object System.Drawing.Size(560, 200)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox     = $false
$form.MinimizeBox     = $false
$form.TopMost         = $true
$form.StartPosition   = [System.Windows.Forms.FormStartPosition]::Manual

# Bewust bovenaan het scherm en niet gecentreerd: de wifi-flyout van Windows opent rechtsonder en
# dit venster staat altijd bovenop. Ze mogen elkaar niet in de weg zitten.
$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point([int](($area.Width - $form.Width) / 2), 60)

$label           = New-Object System.Windows.Forms.Label
$label.Dock      = [System.Windows.Forms.DockStyle]::Fill
$label.Padding   = New-Object System.Windows.Forms.Padding(18)
$label.Font      = New-Object System.Drawing.Font("Segoe UI", 10)
$label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$form.Controls.Add($label)

function Set-PromptText {
    $left = $deadline - (Get-Date)
    $mins = 0
    $secs = 0
    if ($left.TotalSeconds -gt 0) {
        $mins = [int][math]::Floor($left.TotalMinutes)
        $secs = $left.Seconds
    }
    $nl = [Environment]::NewLine
    $label.Text = "De installatie wacht op een internetverbinding." + $nl + $nl +
        "Sluit een netwerkkabel aan of maak verbinding met wifi." + $nl +
        "Zodra er verbinding is gaat de installatie automatisch verder" + $nl +
        "en sluit dit venster vanzelf." + $nl + $nl +
        ("Nog {0} min {1:00} sec te gaan." -f $mins, $secs)
}

$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    if ((Get-Date) -ge $deadline) { $timer.Stop(); $form.Close(); return }
    # Vangnet: valt het hoofdscript weg, dan verdwijnt dit venster mee. Anders blijft er een
    # dialoog staan die nergens meer bij hoort.
    if (-not (Get-Process -Id $parentPid -ErrorAction SilentlyContinue)) { $timer.Stop(); $form.Close(); return }
    Set-PromptText
})

Set-PromptText
$timer.Start()
[void]$form.ShowDialog()
'@

    try {
        $childScript = $template.Replace('__PARENTPID__', [string]$PID).Replace('__DEADLINE__', [string]$Deadline.ToFileTime())

        # -EncodedCommand in plaats van een tijdelijk .ps1-bestand: geen rommel op schijf en geen
        # afhankelijkheid van het execution policy-gedrag voor bestanden. EncodedCommand verwacht
        # UTF-16LE, vandaar [Text.Encoding]::Unicode.
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))

        $startArgs = @{
            FilePath     = "powershell.exe"
            ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encoded)
            WindowStyle  = "Hidden"
            PassThru     = $true
            ErrorAction  = "Stop"
        }
        $proc = Start-Process @startArgs
        "$(Get-Date) Network prompt shown to the user (PID $($proc.Id))" | Out-File $LogPath -Append
        return $proc
    } catch {
        # Het venster is een hulpmiddel, geen voorwaarde. Lukt het niet, dan wachten we stil door.
        "$(Get-Date) WARN: could not show the network prompt: $($_.Exception.Message)" | Out-File $LogPath -Append
        return $null
    }
}

function Close-NetworkPrompt {
    param($Process)

    if (-not $Process) { return }
    try {
        if (-not $Process.HasExited) { $Process.Kill() }
    } catch { }
}

# -----------------------------------------------------------------------------
# Helper: de netwerkkiezer van Windows openen
# -----------------------------------------------------------------------------
# Scheelt de gebruiker het zoeken naar het juiste icoontje. Alleen zinvol als er ook echt een
# draadloze adapter in de machine zit; op een desktop met alleen een losgekoppelde kabel is de
# netwerkkiezer openen misleidend.
function Open-WirelessPicker {
    param([Parameter(Mandatory)][string]$LogPath)

    try {
        $wireless = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
            $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11' -or $_.PhysicalMediaType -match '802\.11'
        })
        if ($wireless.Count -eq 0) {
            "$(Get-Date) No wireless adapter present, not opening the network picker" | Out-File $LogPath -Append
            return
        }

        # Via explorer.exe starten: deze taak draait met verhoogde rechten en een URI-handler laat
        # zich vanuit een elevated proces niet betrouwbaar activeren. explorer geeft het door aan de
        # gewone gebruikerssessie.
        Start-Process -FilePath "explorer.exe" -ArgumentList "ms-availablenetworks:" -ErrorAction Stop
        "$(Get-Date) Opened the Windows network picker" | Out-File $LogPath -Append
    } catch {
        "$(Get-Date) Could not open the network picker: $($_.Exception.Message)" | Out-File $LogPath -Append
    }
}

# -----------------------------------------------------------------------------
# Helper: wachten tot er internet is
# -----------------------------------------------------------------------------
# Geeft $true zodra er verbinding is, $false als de deadline verstrijkt. Op een bekabelde machine
# kost dit een paar seconden; op een laptop krijgt de gebruiker na $PromptAfterSeconds een venster
# te zien en daarna alle tijd om wifi aan te zetten.
function Wait-ForInternet {
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [int]$TimeoutSeconds = 600,
        [int]$PromptAfterSeconds = 20,
        [int]$PollSeconds = 5
    )

    $start       = Get-Date
    $deadline    = $start.AddSeconds($TimeoutSeconds)
    $promptAt    = $start.AddSeconds($PromptAfterSeconds)
    $prompt      = $null
    $promptTried = $false

    "$(Get-Date) Waiting for internet (DNS + reachability), max ${TimeoutSeconds}s..." | Out-File $LogPath -Append

    try {
        while ($true) {
            if (Test-InternetReady) {
                $waited = [int]((Get-Date) - $start).TotalSeconds
                "$(Get-Date) Internet available after ${waited}s" | Out-File $LogPath -Append
                Close-NetworkPrompt -Process $prompt
                return $true
            }

            if ((Get-Date) -ge $deadline) { break }

            # Het venster eerst, de netwerkkiezer daarna: het venster pakt bij het openen de focus
            # en zou de flyout anders meteen weer dichtklappen.
            if ((-not $promptTried) -and ((Get-Date) -ge $promptAt)) {
                $promptTried = $true
                "$(Get-Date) Still no internet, asking the user to connect..." | Out-File $LogPath -Append
                $prompt = Show-NetworkPrompt -Deadline $deadline -LogPath $LogPath
                Open-WirelessPicker -LogPath $LogPath
            }

            Start-Sleep -Seconds $PollSeconds
        }
    } catch {
        "$(Get-Date) WARN: network wait aborted: $($_.Exception.Message)" | Out-File $LogPath -Append
    }

    Close-NetworkPrompt -Process $prompt
    $waited = [int]((Get-Date) - $start).TotalSeconds
    "$(Get-Date) WARN: still no internet after ${waited}s" | Out-File $LogPath -Append
    return $false
}

# 0) Windows Update-blokkade METEEN opheffen.
#
# Dit stond vroeger als stap 8 helemaal onderaan, achter de netwerk-wait, winget en de
# SetupToolbox-download. Bleef een van die stappen hangen, dan werd dit nooit bereikt en
# ging de machine de deur uit met een dode WSUS en dus permanent kapotte Windows Update.
# Er is geen enkele reden om te wachten: OOBE is voorbij tegen de tijd dat dit script
# draait, dus de blokkade heeft zijn werk al gedaan. Bijkomend voordeel: winget en de
# Store hebben de un-gate nodig, want de loopback-WSUS blokkeert ook Store-acquisities.
Remove-WindowsUpdateGate -LogPath $logPath | Out-Null

# 0b) Beveiligingsvragen voor lokale accounts uitzetten.
#
# Staat vlak achter stap 0 en ver voor alles wat netwerk nodig heeft: het is een enkele
# registerwaarde, hij kan niet blijven hangen, en hij moet ook gezet zijn op een machine waar de
# rest van dit script later alsnog strandt op een ontbrekende internetverbinding.
Disable-LocalSecurityQuestions -LogPath $logPath | Out-Null

# 1) Wachten tot er echt internet is
#
# GESCHIEDENIS - hier stond tot 2026-08-22 een vaste wachttijd van 90 seconden.
#
# Dat werkt op een bekabelde machine, maar niet op een laptop. Die heeft na de eerste inlog nog
# helemaal geen netwerk: de gebruiker moet eerst zelf wifi aanzetten en een netwerk kiezen. Tegen
# de tijd dat dat gebeurd was, waren de 90 seconden voorbij en had het script Firefox en
# SetupToolbox al stilletjes overgeslagen. De machine leek af en was het niet.
#
# Nu wachten we tot er verbinding is (standaard maximaal 10 minuten, zie $NetworkWaitSeconds) en
# krijgt de gebruiker na 20 seconden een venster met de vraag om wifi aan te zetten. De lus stopt
# zodra er verbinding is, dus op een bekabelde machine kost dit nog steeds maar enkele seconden.
$internetReady = Wait-ForInternet -LogPath $logPath `
                                  -TimeoutSeconds $NetworkWaitSeconds `
                                  -PromptAfterSeconds $NetworkPromptAfterSeconds `
                                  -PollSeconds $NetworkPollSeconds

# Wordt $true zodra iets dat internet nodig had niet gelukt is. Het slot van dit script laat de
# scheduled task dan staan, zodat de volgende inlog het opnieuw probeert - dan waarschijnlijk wel
# met verbinding.
$retryNeeded = -not $internetReady

# 2) Remove OneDrive completely per-user
try {
    Stop-Process -Name "OneDrive", "OneDriveSetup" -Force -ErrorAction SilentlyContinue
    
    $oneDrivePaths = @(
        "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDriveSetup.exe",
        "$env:ProgramFiles\Microsoft OneDrive\OneDriveSetup.exe",
        "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDriveSetup.exe",
        "$env:SYSTEMROOT\System32\OneDriveSetup.exe"
    )

    foreach ($odSetup in $oneDrivePaths) {
        if (Test-Path $odSetup) {
            Start-ProcessBounded -FilePath $odSetup -ArgumentList @("/uninstall") -TimeoutSeconds 120 -LogPath $logPath | Out-Null
            "$(Get-Date) OneDrive uninstalled via $odSetup" | Out-File $logPath -Append
        }
    }

    # Verwijder per-gebruiker autorun registersleutel
    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "OneDriveSetup" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "OneDrive" -ErrorAction SilentlyContinue
} catch {
    "$(Get-Date) OneDrive removal failed: $($_.Exception.Message)" | Out-File $logPath -Append
}

# 3) Install Firefox via Winget
try {
    # winget bestaat niet gegarandeerd bij eerste inlog: de App Installer-alias kan nog niet
    # geregistreerd zijn, of het pakket is uit de image gehaald. Zonder deze check draait de
    # regel eronder in een CommandNotFoundException die als "installation failed" wordt gelogd
    # zonder te zeggen dat winget zelf ontbrak.
    if (-not $internetReady) {
        "$(Get-Date) SKIP: no internet, Firefox will be retried at the next logon" | Out-File $logPath -Append
    } elseif (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        "$(Get-Date) WARN: winget not available at first logon, skipping Firefox" | Out-File $logPath -Append
    } else {
        "$(Get-Date) Installing Firefox via Winget..." | Out-File $logPath -Append
        $wingetResult = winget install --id Mozilla.Firefox -e --silent --accept-source-agreements --accept-package-agreements 2>&1
        $wingetExit = $LASTEXITCODE

        # 0 = geslaagd. 0x8A15002B = APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE, oftewel
        # al geinstalleerd; dat is voor ons ook goed. Al het andere is een echte fout, en die
        # werd voorheen weggeschreven als "installation finished".
        if ($wingetExit -eq 0 -or $wingetExit -eq 0x8A15002B) {
            "$(Get-Date) Firefox installed (winget exit 0x$('{0:X}' -f $wingetExit))" | Out-File $logPath -Append
        } else {
            "$(Get-Date) WARN: Firefox install failed, winget exit 0x$('{0:X}' -f $wingetExit): $wingetResult" | Out-File $logPath -Append
        }
    }
} catch {
    "$(Get-Date) Firefox installation failed: $($_.Exception.Message)" | Out-File $logPath -Append
}

# 4) Install SetupToolbox: staged copy first (no network dependency), GitHub API resolution + resilient
#    download chain as fallback for when it wasn't baked into the ISO.
try {
    $installerPath = "$env:TEMP\SetupToolbox.exe"
    # If SetupToolbox.exe is placed in the same $OEM$ source folder as this script, it lands at
    # C:\Windows\Setup\Scripts\SetupToolbox.exe automatically - no network round-trip required at all.
    $stagedInstaller = "$env:WINDIR\Setup\Scripts\SetupToolbox.exe"
    $downloadSuccess = $false

    if (Test-Path $stagedInstaller) {
        "$(Get-Date) Found staged SetupToolbox.exe, skipping network download" | Out-File $logPath -Append
        Copy-Item -Path $stagedInstaller -Destination $installerPath -Force
        $downloadSuccess = $true
    } elseif (-not $internetReady) {
        # Vijf downloadpogingen doen die per definitie moeten mislukken heeft geen zin. De task
        # blijft staan, dus de volgende inlog probeert het opnieuw - dan hopelijk met verbinding.
        "$(Get-Date) SKIP: no internet and no staged installer, SetupToolbox download not attempted" | Out-File $logPath -Append
    } else {
        "$(Get-Date) No staged installer found, resolving latest release via GitHub API..." | Out-File $logPath -Append
        [Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13

        $apiHeaders = @{
            "User-Agent" = "SetupToolbox-Deployer"   # GitHub API returns 403 without a User-Agent header
            "Accept"     = "application/vnd.github+json"
        }
        $downloadUrl = $null
        for ($i = 1; $i -le 3; $i++) {
            try {
                $release = Invoke-RestMethod -Uri "https://api.github.com/repos/MisterDuckles/SetupToolbox/releases/latest" -Headers $apiHeaders -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
                # Assets are named "SetupToolbox-vX.Y.Z.exe" - match that pattern specifically so a future
                # release with extra .exe assets (updater, uninstaller, etc.) can't be picked up by accident.
                $asset = $release.assets | Where-Object { $_.name -match '^SetupToolbox-v[\d\.]+\.exe$' } | Select-Object -First 1
                if (-not $asset) {
                    # Fall back to "any single .exe" only if the naming convention ever changes
                    $asset = $release.assets | Where-Object { $_.name -like "*.exe" } | Select-Object -First 1
                }
                if ($asset) { $downloadUrl = $asset.browser_download_url; break }
            } catch {
                "$(Get-Date) GitHub API lookup poging $i mislukt: $($_.Exception.Message)" | Out-File $logPath -Append
                Start-Sleep -Seconds 3
            }
        }
        # Fall back to the convenience redirect URL if the API lookup itself couldn't be reached
        if (-not $downloadUrl) {
            $downloadUrl = "https://github.com/MisterDuckles/SetupToolbox/releases/latest/download/SetupToolbox.exe"
        }
        "$(Get-Date) Resolved download URL: $downloadUrl" | Out-File $logPath -Append

        for ($i = 1; $i -le 5; $i++) {
            # Restant van een vorige poging of van een afgebroken eerdere run weggooien.
            # Anders kan een afgekapte download de 100 KB-drempel hieronder halen en wordt
            # een kapot bestand als geslaagd beschouwd en uitgevoerd.
            Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
            try {
                "$(Get-Date) Download poging $i (BITS)..." | Out-File $logPath -Append
                # -RetryTimeout begrenst hoe lang BITS een haperende verbinding blijft proberen.
                # Zonder deze parameter kan een captive portal of half-open TCP-sessie het script
                # onbeperkt laten hangen.
                Start-BitsTransfer -Source $downloadUrl -Destination $installerPath -RetryTimeout 60 -ErrorAction Stop
            } catch {
                "$(Get-Date) BITS poging $i mislukt: $($_.Exception.Message)" | Out-File $logPath -Append
                try {
                    if (Get-Command "curl.exe" -ErrorAction SilentlyContinue) {
                        # --fail: een 404/403 mag geen HTML-foutpagina naar het .exe-pad schrijven.
                        # --max-time: harde bovengrens, anders hangt curl net zo lang als BITS deed.
                        & curl.exe -sSL --fail --max-time 120 --connect-timeout 15 -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)" "$downloadUrl" -o "$installerPath"
                    } else {
                        Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -UseBasicParsing -ErrorAction Stop
                    }
                } catch {
                    "$(Get-Date) Fallback download poging $i mislukt: $($_.Exception.Message)" | Out-File $logPath -Append
                }
            }
            if ((Test-Path $installerPath) -and ((Get-Item $installerPath).Length -gt 100000)) {
                $downloadSuccess = $true
                break
            }
            Start-Sleep -Seconds 5
        }
    }

    if (-not $downloadSuccess) {
        if ($internetReady) {
            throw "Download van SetupToolbox mislukt (geen staged installer en alle netwerk-pogingen faalden)."
        }
        throw "SetupToolbox overgeslagen: geen gestagede installer en geen internetverbinding."
    }

    "$(Get-Date) Executing SetupToolbox installer..." | Out-File $logPath -Append
    $installExit = Start-ProcessBounded -FilePath $installerPath -ArgumentList @("/silent") -TimeoutSeconds 300 -LogPath $logPath
    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue

    # Niet blind "installed successfully" loggen, maar ook geen valse alarmen: een
    # ontbrekende exitcode is geen mislukking. Stap 4b hieronder zoekt de geinstalleerde
    # .exe op en is de echte bevestiging.
    if (-not $installExit.Started) {
        "$(Get-Date) WARN: SetupToolbox installer could not be started" | Out-File $logPath -Append
    } elseif ($installExit.TimedOut) {
        "$(Get-Date) WARN: SetupToolbox installer timed out after 300s and was terminated" | Out-File $logPath -Append
    } elseif ($null -eq $installExit.ExitCode) {
        "$(Get-Date) SetupToolbox installer finished (exit code not reported by Windows)" | Out-File $logPath -Append
    } elseif ($installExit.ExitCode -eq 0) {
        "$(Get-Date) SetupToolbox installed successfully (exit 0)" | Out-File $logPath -Append
    } else {
        "$(Get-Date) WARN: SetupToolbox installer returned exit code $($installExit.ExitCode)" | Out-File $logPath -Append
    }

    # 4b) Create a Public Desktop shortcut - /silent clearly skips whatever normally creates one.
    # We don't know the installer's internal layout, so instead of hardcoding a guessed path we look
    # it up the same way Windows itself would: via the Uninstall registry key the installer registers
    # (present regardless of installer framework - Inno/NSIS/MSI/WiX all write one), then fall back to
    # scanning common Program Files locations if that key isn't there for some reason.
    try {
        "$(Get-Date) Locating installed SetupToolbox.exe for desktop shortcut..." | Out-File $logPath -Append
        $exePath = $null
        $installLocation = $null

        $uninstallRoots = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        $uninstallEntry = Get-ItemProperty -Path $uninstallRoots -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*SetupToolbox*" } | Select-Object -First 1

        if ($uninstallEntry) {
            "$(Get-Date) Found uninstall registry entry: $($uninstallEntry.DisplayName)" | Out-File $logPath -Append
            if ($uninstallEntry.InstallLocation) { $installLocation = $uninstallEntry.InstallLocation }
            elseif ($uninstallEntry.DisplayIcon) { $installLocation = Split-Path -Path ($uninstallEntry.DisplayIcon -replace ',-?\d+$','') -Parent }
        } else {
            "$(Get-Date) No uninstall registry entry found for SetupToolbox" | Out-File $logPath -Append
        }

        if (-not $installLocation) {
            $fallbackRoots = @("$env:ProgramFiles", "${env:ProgramFiles(x86)}", "$env:LOCALAPPDATA\Programs")
            foreach ($root in $fallbackRoots) {
                if (Test-Path $root) {
                    $match = Get-ChildItem -Path $root -Directory -Filter "*SetupToolbox*" -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($match) { $installLocation = $match.FullName; break }
                }
            }
        }

        if ($installLocation -and (Test-Path $installLocation)) {
            $exeCandidate = Get-ChildItem -Path $installLocation -Filter "SetupToolbox.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $exeCandidate) {
                $exeCandidate = Get-ChildItem -Path $installLocation -Filter "*.exe" -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notmatch "unins" } | Select-Object -First 1
            }
            if ($exeCandidate) { $exePath = $exeCandidate.FullName }
        }

        if ($exePath) {
            $wshShell = New-Object -ComObject WScript.Shell
            $shortcut = $wshShell.CreateShortcut("$env:PUBLIC\Desktop\SetupToolbox.lnk")
            $shortcut.TargetPath = $exePath
            $shortcut.WorkingDirectory = Split-Path -Path $exePath -Parent
            $shortcut.IconLocation = $exePath
            $shortcut.Save()
            "$(Get-Date) SetupToolbox desktop shortcut created -> $exePath" | Out-File $logPath -Append
        } else {
            "$(Get-Date) WARN: could not locate SetupToolbox.exe on disk (checked uninstall registry + Program Files/AppData) - no shortcut created" | Out-File $logPath -Append
        }
    } catch {
        "$(Get-Date) SetupToolbox shortcut creation failed: $($_.Exception.Message)" | Out-File $logPath -Append
    }
} catch {
    "$(Get-Date) SetupToolbox download/installation failed: $($_.Exception.Message)" | Out-File $logPath -Append
    # SetupToolbox is de reden dat deze machines worden uitgerold; ontbreekt hij, dan is de
    # installatie niet af. Volgende inlog opnieuw proberen - zie het slot van dit script.
    $retryNeeded = $true
}

# 5) Create Public Desktop Shortcuts & Clean Up Edge Desktop Icons
try {
    "$(Get-Date) Creating Public Desktop shortcuts & cleaning Edge..." | Out-File $logPath -Append
    $publicDesktop = "$env:PUBLIC\Desktop"
    
    # Windows Activeren (MAS).cmd
    $masShortcutPath = "$publicDesktop\Windows Activeren (MAS).cmd"
    $masContent = "@echo off`r`npowershell -Command `"irm https://get.activated.win | iex`""
    Set-Content -Path $masShortcutPath -Value $masContent -Encoding ASCII
    "$(Get-Date) Windows Activeren (MAS).cmd created" | Out-File $logPath -Append

    # Verwijder Edge snelkoppelingen op alle relevante bureaubladen
    Get-ChildItem -Path "$env:PUBLIC\Desktop", "$env:USERPROFILE\Desktop", "C:\Users\Default\Desktop" -Filter "*Edge*.lnk" -ErrorAction SilentlyContinue | Remove-Item -Force
    "$(Get-Date) Edge desktop shortcuts removed" | Out-File $logPath -Append
} catch {
    "$(Get-Date) Creating shortcuts failed: $($_.Exception.Message)" | Out-File $logPath -Append
}

# 6) Force single language list with US-International layout only
try {
    "$(Get-Date) Setting single US-International keyboard layout..." | Out-File $logPath -Append
    $langList = New-WinUserLanguageList -Language "en-US"
    $langList[0].InputMethodTips.Clear()
    $langList[0].InputMethodTips.Add("0409:00020409")
    Set-WinUserLanguageList -LanguageList $langList -Force
    "$(Get-Date) Keyboard layout updated to US-International only" | Out-File $logPath -Append
} catch {
    "$(Get-Date) Keyboard layout update failed: $($_.Exception.Message)" | Out-File $logPath -Append
}

# 7) Release the taskbar layout policy lock
#
# The actual unpinning already happened before this script ever ran: debloat.ps1 set
# HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer\StartLayoutFile + LockedStartLayout=1 while still
# SYSTEM, before OOBE created this account - so THIS session's very first explorer.exe start already
# read the Edge/Store-free layout. (The old Shell.Application "Unpin from taskbar" COM verb and a loose
# LayoutModification.json in %LocalAppData% are both no-ops on modern Windows 11 - Store/Edge don't expose
# that verb anymore, and Windows 11's Start no longer reads a bare LayoutModification.json outside of
# policy - which is exactly why the old script logged "success" while nothing actually changed.)
#
# All that's left is to remove the lock so the user isn't permanently frozen out of customizing their
# own taskbar/Start from this point on.
try {
    "$(Get-Date) Releasing Start/Taskbar layout policy lock..." | Out-File $logPath -Append

    $explorerPolicyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"
    # Eerst kijken of de lock er uberhaupt nog staat. Bij een herhaalde run - de task blijft staan
    # zolang de netwerk-stappen niet gelukt zijn - is hij al weg, en dan hoeft explorer verderop
    # ook niet opnieuw herstart te worden. Anders knippert het bureaublad bij elke inlog opnieuw.
    $lockWasPresent = $false
    foreach ($v in 'LockedStartLayout', 'StartLayoutFile') {
        if ($null -ne (Get-ItemProperty -Path $explorerPolicyKey -Name $v -ErrorAction SilentlyContinue)) {
            $lockWasPresent = $true
        }
        Remove-ItemProperty -Path $explorerPolicyKey -Name $v -ErrorAction SilentlyContinue
    }

    # Legacy safety net: harmless no-op on modern Windows 11, but cheap insurance on older/LTSC builds
    # that still read the pre-Win11 Quick Launch taskbar pin folder.
    $taskbarPath = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    Get-ChildItem -Path $taskbarPath -Filter "*Store*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $taskbarPath -Filter "*Edge*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    # Explorer moet herstarten voordat het opheffen van de lock zichtbaar wordt.
    # Zie de uitgebreide toelichting bij Restart-ShellCleanly bovenaan dit script -
    # de "nette" WM_USER+436 route is geprobeerd en bleek de shell niet terug te
    # brengen. Force-kill + AutoRestartShell werkt wel.
    if ($lockWasPresent) {
        Restart-ShellCleanly -LogPath $logPath | Out-Null
    } else {
        "$(Get-Date) Layout policy lock was already gone, not restarting explorer" | Out-File $logPath -Append
    }

    "$(Get-Date) Layout policy lock released, taskbar remains Edge/Store-free and is now user-editable" | Out-File $logPath -Append
} catch {
    "$(Get-Date) Releasing layout policy lock failed: $($_.Exception.Message)" | Out-File $logPath -Append
}

# 8) Windows Update blokkade opheffen - TWEEDE PASSAGE
# De eerste passage staat helemaal bovenaan (stap 0). Deze herhaling is puur een vangnet
# voor het geval de policies tussentijds opnieuw zijn toegepast (bv. door een Group Policy
# refresh). De functie is idempotent, dus twee keer draaien kost niets.
Remove-WindowsUpdateGate -LogPath $logPath | Out-Null

# 9) Afronden - of juist niet.
#
# De task afmelden mag alleen als alles wat internet nodig had ook echt gelukt is. Lukte dat niet
# (laptop waarop nooit wifi is aangezet, GitHub onbereikbaar), dan laten we de task juist staan:
# de trigger is AtLogOn, dus de volgende inlog probeert het opnieuw - dan waarschijnlijk wel met
# verbinding. Alle stappen hierboven zijn idempotent, dus een tweede run is veilig.
#
# De teller voorkomt dat een machine die structureel geen internet krijgt bij elke inlog opnieuw
# tien minuten staat te wachten met een venster in beeld.
$stateKey = "HKCU:\Software\Win11Debloat"

if (-not $retryNeeded) {
    Unregister-ScheduledTask -TaskName "Debloat-FirstLogon" -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -Path $stateKey -Recurse -Force -ErrorAction SilentlyContinue
    "$(Get-Date) First-logon task removed" | Out-File $logPath -Append
} else {
    # Teller in HKCU: deze taak draait in de context van de ingelogde gebruiker, dus daar is
    # schrijven altijd toegestaan - ook als dat account geen beheerder blijkt te zijn.
    $runCount  = $MaxFirstLogonRuns
    $counterOk = $false
    try {
        if (-not (Test-Path $stateKey)) { New-Item -Path $stateKey -Force | Out-Null }
        $previous = 0
        $existing = Get-ItemProperty -Path $stateKey -Name "FirstLogonRuns" -ErrorAction SilentlyContinue
        if ($existing) { $previous = [int]$existing.FirstLogonRuns }
        $runCount = $previous + 1
        Set-ItemProperty -Path $stateKey -Name "FirstLogonRuns" -Value $runCount -Type DWord -Force
        $counterOk = $true
    } catch {
        "$(Get-Date) WARN: could not persist the retry counter: $($_.Exception.Message)" | Out-File $logPath -Append
    }

    # Lukt het bijhouden niet, dan stoppen we ermee in plaats van te gokken. Een teller die niet
    # oploopt zou betekenen dat dit script bij ELKE inlog opnieuw tien minuten gaat staan wachten.
    if ((-not $counterOk) -or ($runCount -ge $MaxFirstLogonRuns)) {
        Unregister-ScheduledTask -TaskName "Debloat-FirstLogon" -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -Path $stateKey -Recurse -Force -ErrorAction SilentlyContinue
        "$(Get-Date) WARN: network steps still incomplete after $runCount run(s) - giving up, first-logon task removed" | Out-File $logPath -Append
        "$(Get-Date) WARN: install Firefox and SetupToolbox by hand on this machine" | Out-File $logPath -Append
    } else {
        "$(Get-Date) Network steps incomplete (run $runCount of $MaxFirstLogonRuns) - task kept, retrying at next logon" | Out-File $logPath -Append
    }
}
"$(Get-Date) === First-logon script finished ===" | Out-File $logPath -Append
