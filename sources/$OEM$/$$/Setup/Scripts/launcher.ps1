# =============================================================================
# launcher.ps1 - Debloat Bootstrap
# Draait vanuit SetupComplete.cmd als SYSTEM, voor OOBE.
# Voert het gestagede debloat-script uit dat via sources\$OEM$\ is meegeleverd.
# =============================================================================
#
# WAAROM GEEN REMOTE FETCH MEER
#
# Tot 2026-08-12 haalde dit script debloat.ps1 eerst van raw.githubusercontent.com en gaf
# het die kopie voorrang boven de lokale. Dat is verwijderd, om vier redenen die elk op
# zichzelf al blokkerend waren:
#
#   1. Het draaide willekeurige code van internet als SYSTEM, voor OOBE, zonder enige
#      hash- of signature-verificatie. Wie de URL kon beinvloeden, bezat de machine.
#   2. De URL wees naar de MUTABLE ref refs/heads/master. Die branch loopt achter en bevat
#      een debloat.ps1 zonder WindowsUpdate-afhandeling - dus zodra de fetch weer zou
#      werken (repo public maken), kreeg elke installatie stil een payload die Windows
#      Update permanent kapot achterliet.
#   3. Er stond een GitHub-token in de URL, in cleartext, in een bestand dat op elke
#      gedeployde machine in C:\Windows\Setup\Scripts belandt - leesbaar voor Users. De
#      URL werd bovendien integraal naar debloat.log geschreven.
#   4. Het faalde toch al: de token was verlopen en gaf bij elke run een 404, waarna het
#      alsnog terugviel op de lokale kopie. De feature werkte in de praktijk nooit.
#
# HET ALTERNATIEF: build-helper.ps1 -RefreshScripts haalt de nieuwste scripts op tijdens
# het BOUWEN van de ISO. Daar is het veilig: het gebeurt op jouw machine, je ziet wat er
# binnenkomt, je kunt het testen voordat je uitrolt, en de gedeployde machine draait
# uitsluitend een bekende lokale kopie.
# =============================================================================

$LocalScript = "$env:WINDIR\Setup\Scripts\debloat.ps1"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    # Alleen naar stdout; SetupComplete.cmd logt dit door naar debloat.log
    Write-Host "$timestamp  $Message"
}

Write-Log "=== Debloat Launcher gestart ==="
Write-Log "Script: $LocalScript"

if (-not (Test-Path $LocalScript)) {
    Write-Log "FOUT: debloat.ps1 niet gevonden op $LocalScript."
    Write-Log "      De sources\`$OEM`$\ payload ontbreekt kennelijk op de installatiemedia."
    Write-Log "      De machine draait door zonder debloat; autounattend.xml FirstLogonCommands"
    Write-Log "      heft de Windows Update-blokkade alsnog op."
    exit 1
}

$fileSize = (Get-Item -Path $LocalScript).Length
Write-Log "Gevonden ($fileSize bytes). Uitvoering gestart."

try {
    & powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -File "$LocalScript"
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Write-Log "FOUT: debloat.ps1 faalde met exitcode $exitCode"
        exit $exitCode
    }
    Write-Log "Script succesvol afgerond."
} catch {
    Write-Log "FOUT tijdens script uitvoering: $($_.Exception.Message)"
    exit 1
}

Write-Log "=== Debloat Launcher klaar ==="
