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
    # Microsoft.XboxGameCallableUI bewust NIET in deze lijst: dat is een NonRemovable SystemApp
    # onder C:\Windows\SystemApps. Hij faalde gegarandeerd bij elke run met 0x80070032.
    "Microsoft.WindowsAppRuntime.Main"
)

# De inventarissen EEN keer ophalen. Voorheen stonden deze twee Get-* calls binnen de lus,
# terwijl geen van beide $app als argument neemt: dat waren ruim 100 volledige enumeraties
# van alle AppX-pakketten, op een trage schijf minutenlang pure overhead op het
# "Just a moment"-scherm zonder dat er iets gebeurde.
$allProvisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
$allInstalled   = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
Write-Log "Inventory: $($allProvisioned.Count) provisioned, $($allInstalled.Count) installed packages"

foreach ($app in $appsToRemove) {
    foreach ($pkg in ($allProvisioned | Where-Object { $_.DisplayName -like "*$app*" })) {
        try {
            # -ErrorAction Stop is nodig omdat deze cmdlets non-terminating errors gooien:
            # zonder dit vuurde de catch nooit en werd er ALTIJD "Removed ..." gelogd, ook
            # na een mislukking. Daardoor las de terugkerende 0x80070032 als ruis.
            Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -AllUsers -ErrorAction Stop | Out-Null
            Write-Log "Removed provisioned package: $($pkg.DisplayName)"
        } catch {
            Write-Log "WARN: provisioned removal failed for $($pkg.DisplayName) - $($_.Exception.Message)"
        }
    }

    foreach ($pkg in ($allInstalled | Where-Object { $_.Name -like "*$app*" })) {
        # SystemApps onder C:\Windows\SystemApps zijn met geen enkele ondersteunde methode
        # te verwijderen. Ze meenemen levert alleen een gegarandeerde fout per run op.
        if ($pkg.NonRemovable -or $pkg.SignatureKind -eq 'System') {
            Write-Log "Skipped (system app, not removable): $($pkg.Name)"
            continue
        }
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop | Out-Null
            Write-Log "Removed installed package: $($pkg.Name)"
        } catch {
            Write-Log "WARN: installed removal failed for $($pkg.Name) - $($_.Exception.Message)"
        }
    }
}

# 2) Remove OneDrive completely and prevent automatic installation
Write-Log "Step 2: removing OneDrive"
Stop-Process -Name "OneDrive", "OneDriveSetup" -Force -ErrorAction SilentlyContinue

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

# Active Setup register keys verwijderen om herinstallatie bij nieuwe gebruikers te stoppen
$activeSetupKeys = @(
    "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{8C33162D-F511-4432-8A7A-277D4E0E59F2}",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Active Setup\Installed Components\{8C33162D-F511-4432-8A7A-277D4E0E59F2}"
)
foreach ($key in $activeSetupKeys) {
    if (Test-Path $key) { Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue }
}

# Run keys opschonen
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "OneDriveSetup" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run" -Name "OneDriveSetup" -ErrorAction SilentlyContinue

Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableLibrariesDefaultSaveToOneDrive" 1

# Installation executables opruimen
foreach ($installer in $oneDriveInstallers) {
    if (Test-Path $installer) { Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue }
}

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

# Disable Bing Web Search in Start Menu
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" "DisableSearchBoxSuggestions" 1

# Disable Start Menu Ads, Sponsored Apps & Consumer Recommendations
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableThirdPartySuggestions" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsSpotlightFeatures" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableTailoredExperiencesWithWindows" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" "DisableLocation" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableCloudOptimizedContent" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableSoftLanding" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds" "EnableFeeds" 0
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" "DODownloadMode" 99
Set-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\wlidsvc" "Start" 4
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" "Disabled" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "HideSecurityQuestionsFromLocalUsers" 1
Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" "DisableOOBEUpdate" 1

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

# 5) Edge suppression & Desktop Shortcut Blocking
Write-Log "Step 5: applying Edge suppression and desktop shortcut policies"
$edgePolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
Set-RegValue $edgePolicy "HideFirstRunExperience" 1
Set-RegValue $edgePolicy "EdgeCopilotEnabled" 0
Set-RegValue $edgePolicy "Microsoft365CopilotChatIconEnabled" 0
Set-RegValue $edgePolicy "PersonalizationReportingEnabled" 0
Set-RegValue $edgePolicy "DiagnosticData" 0
Set-RegValue $edgePolicy "SearchSuggestEnabled" 0
Set-RegValue $edgePolicy "StartupBoostEnabled" 0
Set-RegValue $edgePolicy "BackgroundModeEnabled" 0
Set-RegValue $edgePolicy "CreateDesktopShortcutDefault" 0

Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate" "Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" 0
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate" "UpdateDefault" 0
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate" "CreateDesktopShortcutDefault" 0
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate" "RemoveDesktopShortcutDefault" 1

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

# Taskbar layout via de echte, policy-backed mechanism (HKLM StartLayoutFile/LockedStartLayout).
# LayoutModification.xml losjes in het Default-profiel plaatsen wordt door Windows 11 niet meer
# betrouwbaar gelezen (Microsoft: "Import-StartLayout is no longer supported in Windows 11" - hetzelfde
# geldt voor losse LayoutModification bestanden buiten policy-context). De GPO-instelling "Start Layout"
# (Computer Configuration > Administrative Templates > Start Menu and Taskbar > Start Layout) is intern
# gewoon HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer\StartLayoutFile + LockedStartLayout=1.
# Omdat dit een policy-registersleutel is (i.p.v. een los bestand dat Explorer toevallig oppikt), leest
# Explorer hem bij ELKE start, ook bij de allereerste inlog van een account dat nu nog niet bestaat.
# We zetten hem hier vast (SYSTEM, vóór OOBE) en maken hem in firstlogon.ps1 na de eerste toepassing weer
# los, zodat de gebruiker zijn taakbalk daarna gewoon weer vrij kan aanpassen.
Write-Log "Step 5b: registering machine-wide Start/Taskbar layout policy (Edge & Store removed)"
$layoutScriptDir = "$env:WINDIR\Setup\Scripts"
if (-not (Test-Path $layoutScriptDir)) { New-Item -Path $layoutScriptDir -ItemType Directory -Force | Out-Null }
$taskbarLayoutPath = "$layoutScriptDir\TaskbarLayout.xml"
$taskbarLayoutXml = @'
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate
    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"
    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"
    xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout"
    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"
    Version="1">
  <CustomTaskbarLayoutCollection PinListPlacement="Replace">
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList>
        <taskbar:DesktopApp DesktopApplicationID="Microsoft.Windows.Explorer" />
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
'@
Set-Content -Path $taskbarLayoutPath -Value $taskbarLayoutXml -Encoding UTF8 -Force

# Verify the file actually landed and is schema-sane BEFORE we ever trust it. This is here because
# the previous version of this XML was well-formed (parsed fine) but schema-invalid (missing the
# mandatory <taskbar:TaskbarPinList> wrapper around pin entries per the XSD at
# learn.microsoft.com/windows/configuration/taskbar/xsd) - Explorer silently discarded the whole
# override and fell back to default OS pins (Edge/Store) instead of erroring or partially applying.
# A plain [xml] parse check would NOT have caught that specific mistake (it's syntactically valid
# XML), so we additionally assert the wrapper element is actually present.
$layoutOk = $false
try {
    if (-not (Test-Path $taskbarLayoutPath)) {
        throw "TaskbarLayout.xml was not written to $taskbarLayoutPath"
    }
    $writtenXml = Get-Content -Path $taskbarLayoutPath -Raw
    [xml]$parsedXml = $writtenXml   # throws if not well-formed
    if ($writtenXml -notmatch '<taskbar:TaskbarPinList>') {
        throw "written XML is missing the required <taskbar:TaskbarPinList> wrapper - Explorer will silently ignore the whole override and fall back to default pins"
    }
    Write-Log "Taskbar layout XML verified: well-formed and contains TaskbarPinList wrapper ($($writtenXml.Length) bytes at $taskbarLayoutPath)"
    $layoutOk = $true
} catch {
    Write-Log "ERROR: TaskbarLayout.xml verification failed - $($_.Exception.Message)"
}

$explorerPolicyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"

# ALLEEN vergrendelen als er ook echt een geldige layout ligt. Voorheen liep dit door na een
# mislukte verificatie, waardoor LockedStartLayout=1 werd gezet met StartLayoutFile wijzend
# naar een bestand dat niet bestond: pin/unpin uitgeschakeld en geen layout om te tonen.
# Een niet-aangepaste taakbalk is een veel beter faalscenario dan een vergrendelde lege.
if ($layoutOk) {
    Set-RegValue $explorerPolicyKey "StartLayoutFile" $taskbarLayoutPath "String"
    Set-RegValue $explorerPolicyKey "LockedStartLayout" 1 "DWord"
} else {
    Write-Log "WARN: skipping StartLayoutFile/LockedStartLayout - refusing to lock the Start menu against an invalid layout"
    Remove-ItemProperty -Path $explorerPolicyKey -Name "StartLayoutFile" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $explorerPolicyKey -Name "LockedStartLayout" -ErrorAction SilentlyContinue
}

# Read back what we just wrote instead of assuming the write succeeded - this was previously assumed,
# never confirmed.
if ($layoutOk) {
    try {
        $verifyStartLayoutFile = (Get-ItemProperty -Path $explorerPolicyKey -Name "StartLayoutFile" -ErrorAction Stop).StartLayoutFile
        $verifyLockedStartLayout = (Get-ItemProperty -Path $explorerPolicyKey -Name "LockedStartLayout" -ErrorAction Stop).LockedStartLayout
        Write-Log "Registry verified: StartLayoutFile='$verifyStartLayoutFile' LockedStartLayout=$verifyLockedStartLayout"
    } catch {
        Write-Log "ERROR: failed to read back StartLayoutFile/LockedStartLayout after writing - $($_.Exception.Message)"
    }
}

# 6) First-logon task
Write-Log "Step 6: creating first-logon task"
$firstLogonScriptPath = "$env:WINDIR\Setup\Scripts\firstlogon.ps1"
try {
    if (-not (Test-Path $firstLogonScriptPath)) {
        throw "first-logon script not found at $firstLogonScriptPath"
    }
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -NoProfile -NonInteractive -WindowStyle Hidden -File `"$firstLogonScriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    # S-1-5-32-545 in plaats van "BUILTIN\Users": die literal is GELOKALISEERD en resolvet
    # niet op een niet-Engelse image (op een Nederlandse build heet de groep "Gebruikers").
    # De SID is overal gelijk.
    $principal = New-ScheduledTaskPrincipal -GroupId "S-1-5-32-545" -RunLevel Highest

    # -ErrorAction Stop is noodzakelijk: Register-ScheduledTask is een CIM-cmdlet en meldt
    # fouten als ERROR_NONE_MAPPED non-terminating, waardoor de catch hieronder niet vuurde
    # en er alsnog "Created task" in het log belandde na een mislukte registratie.
    Register-ScheduledTask -TaskName "Debloat-FirstLogon" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null

    # Terugvragen in plaats van aannemen.
    if (-not (Get-ScheduledTask -TaskName "Debloat-FirstLogon" -ErrorAction SilentlyContinue)) {
        throw "task registered without error but cannot be read back"
    }
    Write-Log "Created task: Debloat-FirstLogon (verified)"
} catch {
    Write-Log "ERROR: failed creating first-logon task - $($_.Exception.Message)"

    # Zonder deze taak draait firstlogon.ps1 nooit, en dan blijft de machine achter met een
    # dode WSUS (permanent kapotte Windows Update) en een vergrendeld Startmenu. Liever hier
    # meteen terugdraaien dan een machine uitleveren die er heel uitziet en het niet is.
    Write-Log "ERROR: rolling back Windows Update gate and layout lock inline"
    try {
        $wu = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
        foreach ($v in 'WUServer', 'WUStatusServer', 'UpdateServiceUrlAlternate') {
            Remove-ItemProperty -Path $wu -Name $v -ErrorAction SilentlyContinue
        }
        foreach ($v in 'UseWUServer', 'NoAutoUpdate') {
            Remove-ItemProperty -Path "$wu\AU" -Name $v -ErrorAction SilentlyContinue
        }
        $explorerPolicyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"
        Remove-ItemProperty -Path $explorerPolicyKey -Name "LockedStartLayout" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $explorerPolicyKey -Name "StartLayoutFile" -ErrorAction SilentlyContinue
        Write-Log "Rollback done: WU gate and layout lock removed, taskbar customisation skipped"
    } catch {
        Write-Log "CRITICAL: rollback itself failed - $($_.Exception.Message)"
    }
}

Write-Log "=== Debloat script finished ==="