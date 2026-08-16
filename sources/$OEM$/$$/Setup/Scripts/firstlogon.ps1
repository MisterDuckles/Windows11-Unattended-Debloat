$logPath = "$env:USERPROFILE\debloat-firstlogon.log"
"$(Get-Date) First-logon script started" | Out-File $logPath -Append

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

# 0) Windows Update-blokkade METEEN opheffen.
#
# Dit stond vroeger als stap 8 helemaal onderaan, achter de netwerk-wait, winget en de
# SetupToolbox-download. Bleef een van die stappen hangen, dan werd dit nooit bereikt en
# ging de machine de deur uit met een dode WSUS en dus permanent kapotte Windows Update.
# Er is geen enkele reden om te wachten: OOBE is voorbij tegen de tijd dat dit script
# draait, dus de blokkade heeft zijn werk al gedaan. Bijkomend voordeel: winget en de
# Store hebben de un-gate nodig, want de loopback-WSUS blokkeert ook Store-acquisities.
Remove-WindowsUpdateGate -LogPath $logPath | Out-Null

# 1) Wachten tot de netwerkverbinding EN DNS-resolutie volledig actief zijn (max 90 sec)
# Let op: pingen naar een letterlijk IP (1.1.1.1) bewijst alleen IP-bereikbaarheid, niet dat de
# DNS-client al klaar is. Vlak na de allereerste inlog loopt DNS vaak een paar seconden achter op
# de rest van de netwerkstack, waardoor github.com niet resolvet terwijl "de netwerk-check" al slaagde.
try {
    "$(Get-Date) Waiting for active network connection + DNS resolution..." | Out-File $logPath -Append
    $maxWait = 90
    $waited = 0
    $networkReady = $false
    $dnsReady = $false
    while ($waited -lt $maxWait) {
        if (-not $networkReady) {
            $networkReady = [bool](Test-Connection -ComputerName "1.1.1.1" -Count 1 -Quiet -ErrorAction SilentlyContinue)
        }
        if ($networkReady -and -not $dnsReady) {
            try {
                if (Resolve-DnsName -Name "github.com" -ErrorAction Stop) { $dnsReady = $true }
            } catch { $dnsReady = $false }
        }
        if ($networkReady -and $dnsReady) { break }
        Start-Sleep -Seconds 3
        $waited += 3
    }
    "$(Get-Date) Network ready: $networkReady, DNS ready: $dnsReady (waited ${waited}s)" | Out-File $logPath -Append
} catch {
    "$(Get-Date) Network check warning: $($_.Exception.Message)" | Out-File $logPath -Append
}

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
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
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
        throw "Download van SetupToolbox mislukt (geen staged installer en alle netwerk-pogingen faalden)."
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
    Remove-ItemProperty -Path $explorerPolicyKey -Name "LockedStartLayout" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $explorerPolicyKey -Name "StartLayoutFile" -ErrorAction SilentlyContinue

    # Legacy safety net: harmless no-op on modern Windows 11, but cheap insurance on older/LTSC builds
    # that still read the pre-Win11 Quick Launch taskbar pin folder.
    $taskbarPath = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    Get-ChildItem -Path $taskbarPath -Filter "*Store*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $taskbarPath -Filter "*Edge*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    # Explorer moet herstarten voordat het opheffen van de lock zichtbaar wordt.
    # Zie de uitgebreide toelichting bij Restart-ShellCleanly bovenaan dit script -
    # de "nette" WM_USER+436 route is geprobeerd en bleek de shell niet terug te
    # brengen. Force-kill + AutoRestartShell werkt wel.
    Restart-ShellCleanly -LogPath $logPath | Out-Null

    "$(Get-Date) Layout policy lock released, taskbar remains Edge/Store-free and is now user-editable" | Out-File $logPath -Append
} catch {
    "$(Get-Date) Releasing layout policy lock failed: $($_.Exception.Message)" | Out-File $logPath -Append
}

# 8) Windows Update blokkade opheffen - TWEEDE PASSAGE
# De eerste passage staat helemaal bovenaan (stap 0). Deze herhaling is puur een vangnet
# voor het geval de policies tussentijds opnieuw zijn toegepast (bv. door een Group Policy
# refresh). De functie is idempotent, dus twee keer draaien kost niets.
Remove-WindowsUpdateGate -LogPath $logPath | Out-Null

Unregister-ScheduledTask -TaskName "Debloat-FirstLogon" -Confirm:$false -ErrorAction SilentlyContinue
"$(Get-Date) First-logon task removed" | Out-File $logPath -Append
"$(Get-Date) === First-logon script finished ===" | Out-File $logPath -Append