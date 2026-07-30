# debloat.ps1 - Windows 11 debloat script
# Runs as SYSTEM from launcher.ps1.

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "$timestamp  $Message"
}

function Set-RegValue {
    param(
        [string]$Path,
        [string]$Name,
        [object]$Value,
        [string]$Type = "DWord"
    )

    try {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }

        if ($null -eq (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue)) {
            New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        } else {
            Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force
        }
    } catch {
        Write-Log "WARN: failed to set registry value $Path\$Name - $($_.Exception.Message)"
    }
}

Write-Log ""
Write-Log "=== Debloat script started ==="

# 1) Remove provisioned and installed AppX packages
Write-Log "Step 1: removing AppX bloat packages"

$appsToRemove = @(
    "Microsoft.Copilot",
    "MSTeams",
    "MicrosoftTeams",
    "Microsoft.GamingApp",
    "Microsoft.XboxApp",
    "Microsoft.XboxGameOverlay",
    "Microsoft.XboxGamingOverlay",
    "Microsoft.XboxIdentityProvider",
    "Microsoft.XboxSpeechToTextOverlay",
    "Clipchamp.Clipchamp",
    "Microsoft.ZuneMusic",
    "Microsoft.ZuneVideo",
    "Microsoft.549981C3F5F10",
    "Microsoft.BingNews",
    "Microsoft.BingWeather",
    "microsoft.windowscommunicationsapps",
    "Microsoft.SkypeApp",
    "Microsoft.MicrosoftOfficeHub",
    "Microsoft.Office.OneNote",
    "Microsoft.WindowsMaps",
    "Microsoft.MicrosoftSolitaireCollection",
    "Microsoft.MicrosoftStickyNotes",
    "Microsoft.WindowsFeedbackHub",
    "Microsoft.GetHelp",
    "Microsoft.Getstarted",
    "Microsoft.People",
    "Microsoft.WindowsAlarms",
    "Microsoft.WindowsCamera",
    "Microsoft.windowsSoundRecorder",
    "Microsoft.YourPhone",
    "Microsoft.MixedReality.Portal",
    "Microsoft.Microsoft3DViewer",
    "MicrosoftCorporationII.MicrosoftFamily",
    "SpotifyAB.SpotifyMusic",
    "Disney.37853D22215B2",
    "king.com.CandyCrushSaga",
    "king.com.CandyCrushFriends",
    "Amazon.com.Amazon",
    "Facebook.Facebook",
    "Netflix.Netflix",
    "Microsoft.BingSearch",
    "Microsoft.Tips",
    "Microsoft.Todos",
    "Microsoft.OutlookForWindows",
    "Microsoft.Paint",
    "Microsoft.PowerAutomateDesktop",
    "MicrosoftCorporationII.QuickAssist",
    "Microsoft.StartExperiencesApp",
    "Microsoft.Xbox.TCUI",
    "Microsoft.XboxGameCallableUI",
    "Microsoft.WindowsAppRuntime.Main"
)

foreach ($app in $appsToRemove) {
    try {
        $provisioned = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like "*$app*" }
        foreach ($pkg in $provisioned) {
            Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -AllUsers | Out-Null
            Write-Log "Removed provisioned package: $($pkg.DisplayName)"
        }
    } catch {
        Write-Log "WARN: provisioned removal failed for $app - $($_.Exception.Message)"
    }

    try {
        $installed = Get-AppxPackage -AllUsers | Where-Object { $_.Name -like "*$app*" }
        foreach ($pkg in $installed) {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers | Out-Null
            Write-Log "Removed installed package: $($pkg.Name)"
        }
    } catch {
        Write-Log "WARN: installed removal failed for $app - $($_.Exception.Message)"
    }
}

# 2) Remove OneDrive
Write-Log "Step 2: removing OneDrive"
$oneDriveInstallers = @(
    "$env:SYSTEMROOT\SysWOW64\OneDriveSetup.exe",
    "$env:SYSTEMROOT\System32\OneDriveSetup.exe"
)

foreach ($installer in $oneDriveInstallers) {
    if (Test-Path $installer) {
        try {
            Start-Process -FilePath $installer -ArgumentList "/uninstall" -Wait -NoNewWindow
            Write-Log "OneDrive uninstall invoked via $installer"
        } catch {
            Write-Log "WARN: OneDrive uninstall failed via $installer - $($_.Exception.Message)"
        }
    }
}

Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableLibrariesDefaultSaveToOneDrive" 1

# 3) Privacy and telemetry hardening
Write-Log "Step 3: applying privacy and telemetry policies"
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 0
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "DoNotShowFeedbackNotifications" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "DisableOneSettingsDownloads" 1
Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" "AllowTelemetry" 0
Set-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\DiagTrack" "Start" 4
Set-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\dmwappushservice" "Start" 4
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo" "DisabledByGroupPolicy" 1
Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" 0
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableActivityFeed" 0
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "PublishUserActivities" 0
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "UploadUserActivities" 0
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "AllowCortana" 0
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "ConnectedSearchUseWeb" 0
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "DisableWebSearch" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" "DisableLocation" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableCloudOptimizedContent" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableSoftLanding" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds" "EnableFeeds" 0
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" "DODownloadMode" 99
Set-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\wlidsvc" "Start" 4
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" "Disabled" 1

foreach ($serviceName in @("DiagTrack", "dmwappushservice", "wlidsvc", "WerSvc")) {
    try {
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        Set-Service -Name $serviceName -StartupType Disabled -ErrorAction SilentlyContinue
    } catch {}
}

# 4) Disable AI and Recall features
Write-Log "Step 4: disabling AI and Recall features"
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "AllowRecallEnablement" 0
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableClickToDo" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableSettingsAgent" 1
Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint" "DisableCocreator" 1
Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint" "DisableGenerativeFill" 1
Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint" "DisableImageCreator" 1

# 5) Edge suppression and update blocking
Write-Log "Step 5: applying Edge suppression"
$edgePolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
Set-RegValue $edgePolicy "HideFirstRunExperience" 1
Set-RegValue $edgePolicy "EdgeCopilotEnabled" 0
Set-RegValue $edgePolicy "Microsoft365CopilotChatIconEnabled" 0
Set-RegValue $edgePolicy "PersonalizationReportingEnabled" 0
Set-RegValue $edgePolicy "DiagnosticData" 0
Set-RegValue $edgePolicy "SearchSuggestEnabled" 0
Set-RegValue $edgePolicy "StartupBoostEnabled" 0
Set-RegValue $edgePolicy "BackgroundModeEnabled" 0

Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate" "Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" 0
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate" "UpdateDefault" 0

$edgeTasks = @(
    "\Microsoft\EdgeUpdate\MicrosoftEdgeUpdateTaskMachineCore",
    "\Microsoft\EdgeUpdate\MicrosoftEdgeUpdateTaskMachineUA",
    "\Microsoft\MicrosoftEdge\BrowserUpdateCohortTask",
    "\Microsoft\MicrosoftEdge\BrowserUpdateReportingTask",
    "\Microsoft\MicrosoftEdge\BrowserUpdateInstallerTask"
)

foreach ($task in $edgeTasks) {
    try {
        Disable-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue | Out-Null
    } catch {}
}

# 6) First-logon task
Write-Log "Step 6: creating first-logon task"
$firstLogonScriptPath = "$env:WINDIR\Setup\Scripts\firstlogon.ps1"
$firstLogonScript = @'
$logPath = "$env:USERPROFILE\debloat-firstlogon.log"
"$(Get-Date) First-logon script started" | Out-File $logPath -Append

# Remove OneDrive per-user
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

# Install Firefox via Winget
try {
    "$(Get-Date) Installing Firefox via Winget..." | Out-File $logPath -Append
    $wingetResult = winget install --id Mozilla.Firefox -e --silent --accept-source-agreements --accept-package-agreements 2>&1
    "$(Get-Date) Firefox installation finished: $wingetResult" | Out-File $logPath -Append
} catch {
    "$(Get-Date) Firefox installation failed: $($_.Exception.Message)" | Out-File $logPath -Append
}

# Create Public Desktop Shortcuts
try {
    "$(Get-Date) Creating Public Desktop shortcuts..." | Out-File $logPath -Append
    $publicDesktop = "$env:PUBLIC\Desktop"

    # SetupToolbox.url
    $toolboxShortcutPath = "$publicDesktop\SetupToolbox.url"
    $toolboxContent = "[InternetShortcut]`r`nURL=https://github.com/MisterDuckles/SetupToolbox"
    Set-Content -Path $toolboxShortcutPath -Value $toolboxContent -Encoding UTF8
    "$(Get-Date) SetupToolbox.url created" | Out-File $logPath -Append

    # Windows Activeren (MAS).cmd
    $masShortcutPath = "$publicDesktop\Windows Activeren (MAS).cmd"
    $masContent = "@echo off`r`npowershell -Command `"irm https://get.activated.win | iex`""
    Set-Content -Path $masShortcutPath -Value $masContent -Encoding ASCII
    "$(Get-Date) Windows Activeren (MAS).cmd created" | Out-File $logPath -Append
} catch {
    "$(Get-Date) Creating shortcuts failed: $($_.Exception.Message)" | Out-File $logPath -Append
}

Unregister-ScheduledTask -TaskName "Debloat-FirstLogon" -Confirm:$false -ErrorAction SilentlyContinue
"$(Get-Date) First-logon task removed" | Out-File $logPath -Append
'@

$firstLogonScript | Out-File -FilePath $firstLogonScriptPath -Encoding UTF8 -Force

try {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -NoProfile -NonInteractive -WindowStyle Hidden -File `"$firstLogonScriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users" -RunLevel Highest

    Register-ScheduledTask -TaskName "Debloat-FirstLogon" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Write-Log "Created task: Debloat-FirstLogon"
} catch {
    Write-Log "WARN: failed creating first-logon task - $($_.Exception.Message)"
}

Write-Log "IMPORTANT: remove Edge manually in Settings > Apps > Installed apps > Microsoft Edge"
Write-Log "=== Debloat script finished ==="
