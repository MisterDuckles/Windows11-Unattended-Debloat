# =============================================================================
# launcher.ps1 — Debloat Bootstrap
# Loopt in de specialize-pass als SYSTEM, vóór OOBE.
# Probeert eerst het debloat-script van GitHub te downloaden.
# Valt terug op de lokale kopie als er geen internet is.
# =============================================================================

$LocalScript = "$env:WINDIR\Setup\Scripts\debloat.ps1"
$TempScript = "$env:ProgramData\debloat-remote.ps1"

# ── Pas deze URL aan naar jouw eigen GitHub raw URL ──────────────────────────
$RemoteUrl = "https://raw.githubusercontent.com/MisterDuckles/Windows11-Unattended-Debloat/refs/heads/master/sources/%24OEM%24/%24%24/Setup/Scripts/debloat.ps1?token=GHSAT0AAAAAADW4XDNWFOT2PJIV4SGZFCDE2NVIWGQ"
# ─────────────────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    # Schrijf alleen naar stdout; SetupComplete.cmd logt dit automatisch naar debloat.log
    Write-Host "$timestamp  $Message"
}

Write-Log "=== Debloat Launcher gestart ==="
Write-Log "Lokaal script: $LocalScript"
Write-Log "Remote URL:    $RemoteUrl"

$scriptPathToRun = $null

# ── Stap 1: Probeer remote script op te halen ─────────────────────────────
try {
    Write-Log "Verbinding maken met GitHub..."
    $response = Invoke-WebRequest -Uri $RemoteUrl -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    if ($response.StatusCode -eq 200 -and $response.Content.Length -gt 0) {
        $response.Content | Out-File -FilePath $TempScript -Encoding UTF8 -Force
        $scriptPathToRun = $TempScript
        Write-Log "Remote script succesvol opgehaald ($($response.Content.Length) bytes)."
        Write-Log "BRON: Remote (GitHub)"
    } else {
        Write-Log "Onverwachte HTTP response: $($response.StatusCode). Fallback naar lokaal."
    }
} catch {
    Write-Log "Remote ophalen mislukt: $($_.Exception.Message)"
    Write-Log "BRON: Fallback naar lokaal script."
}

# ── Stap 2: Fallback naar lokale kopie ────────────────────────────────────
if (-not $scriptPathToRun) {
    if (Test-Path $LocalScript) {
        $scriptPathToRun = $LocalScript
        $fileSize = (Get-Item -Path $LocalScript).Length
        Write-Log "Lokaal script gevonden ($fileSize bytes)."
        Write-Log "BRON: Lokaal ($LocalScript)"
    } else {
        Write-Log "FOUT: Lokaal script niet gevonden op $LocalScript. Launcher stopt."
        exit 1
    }
}

# ── Stap 3: Script uitvoeren ───────────────────────────────────────────────
Write-Log "Script uitvoering gestart: $scriptPathToRun"
try {
    # Omdat SetupComplete.cmd al stdout logt, hoeven we niet extra te redirecten
    & powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -File "$scriptPathToRun"
    if ($LASTEXITCODE -ne 0) {
        Write-Log "FOUT: script faalde met exitcode $LASTEXITCODE"
        exit $LASTEXITCODE
    }
    Write-Log "Script succesvol afgerond."
} catch {
    Write-Log "FOUT tijdens script uitvoering: $($_.Exception.Message)"
    exit 1
}

Write-Log "=== Debloat Launcher klaar ==="
