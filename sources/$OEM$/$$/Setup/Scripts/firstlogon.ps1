$logPath = "$env:USERPROFILE\debloat-firstlogon.log"
"$(Get-Date) First-logon script started" | Out-File $logPath -Append

# 1) Wachten tot de netwerkverbinding volledig actief is (max 60 sec)
try {
    "$(Get-Date) Waiting for active network connection..." | Out-File $logPath -Append
    $maxWait = 60
    $waited = 0
    while ($waited -lt $maxWait) {
        if (Test-Connection -ComputerName "1.1.1.1" -Count 1 -Quiet -ErrorAction SilentlyContinue) { break }
        Start-Sleep -Seconds 3
        $waited += 3
    }
    "$(Get-Date) Network ready (waited ${waited}s)" | Out-File $logPath -Append
} catch {
    "$(Get-Date) Network check warning: $($_.Exception.Message)" | Out-File $logPath -Append
}

# 2) Remove OneDrive per-user
try {
    $odSetup = "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDriveSetup.exe"
    if (Test-Path $odSetup) {
        Start-Process -FilePath $odSetup -ArgumentList "/uninstall" -Wait -NoNewWindow
        "$(Get-Date) OneDrive uninstalled" | Out-File $logPath -Append
    } else {
        "$(Get-Date) OneDrive not found, skipping" | Out-File $logPath -Append
    }
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

# 4) Download and install SetupToolbox executable (Robuust met TLS 1.2/1.3, retries & curl.exe)
try {
    "$(Get-Date) Downloading SetupToolbox installer from GitHub..." | Out-File $logPath -Append
    $installerPath = "$env:TEMP\SetupToolbox.exe"
    $downloadUrl = "https://github.com/MisterDuckles/SetupToolbox/releases/latest/download/SetupToolbox.exe"

    # Forceer TLS 1.2 en TLS 1.3 protocollen
    [Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13

    $downloadSuccess = $false
    for ($i = 1; $i -le 5; $i++) {
        try {
            if (Get-Command "curl.exe" -ErrorAction SilentlyContinue) {
                & curl.exe -sSL "$downloadUrl" -o "$installerPath"
            } else {
                Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath -UseBasicParsing -ErrorAction Stop
            }

            if ((Test-Path $installerPath) -and ((Get-Item $installerPath).Length -gt 100000)) {
                $downloadSuccess = $true
                break
            }
        } catch {
            "$(Get-Date) Download attempt $i failed: $($_.Exception.Message)" | Out-File $logPath -Append
        }
        Start-Sleep -Seconds 5
    }

    if (-not $downloadSuccess) {
        throw "Download van SetupToolbox mislukt na 5 pogingen."
    }

    "$(Get-Date) Executing SetupToolbox installer..." | Out-File $logPath -Append
    Start-Process -FilePath $installerPath -ArgumentList "/silent" -Wait -NoNewWindow
    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
    "$(Get-Date) SetupToolbox installed successfully" | Out-File $logPath -Append
} catch {
    "$(Get-Date) SetupToolbox download/installation failed: $($_.Exception.Message)" | Out-File $logPath -Append
}

# 5) Create Public Desktop Shortcuts
try {
    "$(Get-Date) Creating Public Desktop shortcuts..." | Out-File $logPath -Append
    $publicDesktop = "$env:PUBLIC\Desktop"

    # Windows Activeren (MAS).cmd
    $masShortcutPath = "$publicDesktop\Windows Activeren (MAS).cmd"
    $masContent = "@echo off`r`npowershell -Command `"irm https://get.activated.win | iex`""
    Set-Content -Path $masShortcutPath -Value $masContent -Encoding ASCII
    "$(Get-Date) Windows Activeren (MAS).cmd created" | Out-File $logPath -Append
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

# 7) Remove pinned Microsoft Store shortcut from taskbar & refresh layout (Optie B)
try {
    "$(Get-Date) Unpinning Microsoft Store from taskbar..." | Out-File $logPath -Append

    # Oude .lnk bestanden opruimen
    $taskbarPath = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    Get-ChildItem -Path $taskbarPath -Filter "*Store*" -ErrorAction SilentlyContinue | Remove-Item -Force

    # LayoutModification instellen voor huidige gebruiker
    $userLayoutDir = "$env:LOCALAPPDATA\Microsoft\Windows\Shell"
    if (-not (Test-Path $userLayoutDir)) { New-Item -Path $userLayoutDir -ItemType Directory -Force | Out-Null }
    $userLayoutPath = "$userLayoutDir\LayoutModification.json"
    $layoutContent = '{"primaryOOBEConfig":{"optOut":true},"defaultLayoutOverride":{"taskbar":{"iconList":[{"desktopAppId":"Microsoft.Windows.Explorer"}]}}}'
    Set-Content -Path $userLayoutPath -Value $layoutContent -Encoding UTF8 -Force

    # Cached taakbalk-indeling in register wissen
    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskbar" -Name "TaskbarWin11" -ErrorAction SilentlyContinue

    # Explorer herstarten om de schone taakbalk direct te laden
    Stop-Process -Name "explorer" -Force -ErrorAction SilentlyContinue

    "$(Get-Date) Microsoft Store unpinned and taskbar refreshed" | Out-File $logPath -Append
} catch {
    "$(Get-Date) Unpinning MS Store failed: $($_.Exception.Message)" | Out-File $logPath -Append
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