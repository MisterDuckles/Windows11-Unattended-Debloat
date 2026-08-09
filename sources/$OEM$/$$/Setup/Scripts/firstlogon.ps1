$logPath = "$env:USERPROFILE\debloat-firstlogon.log"
"$(Get-Date) First-logon script started" | Out-File $logPath -Append

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
            Start-Process -FilePath $odSetup -ArgumentList "/uninstall" -Wait -NoNewWindow
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
    "$(Get-Date) Installing Firefox via Winget..." | Out-File $logPath -Append
    $wingetResult = winget install --id Mozilla.Firefox -e --silent --accept-source-agreements --accept-package-agreements 2>&1
    "$(Get-Date) Firefox installation finished: $wingetResult" | Out-File $logPath -Append
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
                $release = Invoke-RestMethod -Uri "https://api.github.com/repos/MisterDuckles/SetupToolbox/releases/latest" -Headers $apiHeaders -UseBasicParsing -ErrorAction Stop
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
            try {
                "$(Get-Date) Download poging $i (BITS)..." | Out-File $logPath -Append
                Start-BitsTransfer -Source $downloadUrl -Destination $installerPath -ErrorAction Stop
            } catch {
                "$(Get-Date) BITS poging $i mislukt: $($_.Exception.Message)" | Out-File $logPath -Append
                try {
                    if (Get-Command "curl.exe" -ErrorAction SilentlyContinue) {
                        & curl.exe -sSL -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)" "$downloadUrl" -o "$installerPath"
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
    Start-Process -FilePath $installerPath -ArgumentList "/silent" -Wait -NoNewWindow
    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
    "$(Get-Date) SetupToolbox installed successfully" | Out-File $logPath -Append
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

    Stop-Process -Name "explorer" -Force -ErrorAction SilentlyContinue
    "$(Get-Date) Layout policy lock released, taskbar remains Edge/Store-free and is now user-editable" | Out-File $logPath -Append
} catch {
    "$(Get-Date) Releasing layout policy lock failed: $($_.Exception.Message)" | Out-File $logPath -Append
}

# 8) Windows Update blokkade opheffen na eerste inlog
try {
    "$(Get-Date) Removing Windows Update setup blocks..." | Out-File $logPath -Append
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "DoNotConnectToWindowsUpdateInternetLocations" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -ErrorAction SilentlyContinue
    "$(Get-Date) Windows Update blocks removed" | Out-File $logPath -Append
} catch {
    "$(Get-Date) Failed to remove Windows Update blocks: $($_.Exception.Message)" | Out-File $logPath -Append
}

Unregister-ScheduledTask -TaskName "Debloat-FirstLogon" -Confirm:$false -ErrorAction SilentlyContinue
"$(Get-Date) First-logon task removed" | Out-File $logPath -Append