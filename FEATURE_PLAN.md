# FEATURE_PLAN: Afronding Fase 3 (Bing Search & Reclame Blocking)

**Doel:** De overgebleven relevante punten van Fase 3 (Bing Web Search in het Startmenu uitschakelen en Startmenu reclame/aanbevelingen blokkeren) geautomatiseerd toevoegen aan `debloat.ps1`. Het klassieke contextmenu is geschrapt en Hibernation (sluimerstand) blijft ingeschakeld.

---

## Component Analyse & XML Status

* **`autounattend.xml`:** Geen wijzigingen vereist. Partitionering, taalinstellingen en OOBE-bypasses zijn reeds volledig in orde. Registeraanpassingen behoren thuis in `debloat.ps1`.
* **Hibernation:** Blijft ongewijzigd actief (geen `powercfg /h off`).
* **Contextmenu:** Geen aanpassingen (Windows 11 standaard blijft behouden).

---

## Task 1: Bing Search in Startmenu Uitschakelen

* **Bestand:** `sources/$OEM$/$$/Setup/Scripts/debloat.ps1`
* **Target Mode:** `Code`
* **Target Provider Profile:** `Ollama - Heavy (30b)`
* **Fallback Rule:** Schakel bij een timeout of streamfout voor deze taak direct om naar `Gemini 3.1 Pro`.

### Sub-prompt voor Roo Code:

Lees het bestand `sources/$OEM$/$$/Setup/Scripts/debloat.ps1` via `read_file`.
Zoek het anker: `# 3) Privacy and telemetry hardening`
Voeg direct onder de al bestaande `Set-RegValue` regels rond regel 137 de volgende register-instellingen toe via `apply_diff`:

```powershell
# Disable Bing Web Search in Start Menu
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" "DisableSearchBoxSuggestions" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "DisableWebSearch" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "ConnectedSearchUseWeb" 0

```

Sla het bestand op.

**Acceptatiecriteria:**

* [ ] Registerwaarden voor het uitschakelen van Bing Search in de zoekbalk/Startmenu zijn toegevoegd onder sectie 3.

---

## Task 2: Reclame & Aanbevelingen in Startmenu Blokkeren

* **Bestand:** `sources/$OEM$/$$/Setup/Scripts/debloat.ps1`
* **Target Mode:** `Code`
* **Target Provider Profile:** `Ollama - Heavy (30b)`
* **Fallback Rule:** Schakel bij een timeout of streamfout voor deze taak direct om naar `Gemini 3.1 Pro`.

### Sub-prompt voor Roo Code:

Lees het bestand `sources/$OEM$/$$/Setup/Scripts/debloat.ps1` via `read_file`.
Zoek het anker: `# 3) Privacy and telemetry hardening`
Voeg direct onder de Bing Search register-instellingen die zojuist zijn toegevoegd de volgende code toe via `apply_diff`:

```powershell
# Disable Start Menu Ads, Sponsored Apps & Consumer Recommendations
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableThirdPartySuggestions" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsSpotlightFeatures" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableTailoredExperiencesWithWindows" 1

```

Sla het bestand op.

**Acceptatiecriteria:**

* [ ] Registerwaarden voor het uitschakelen van gesponsorde content en suggesties in het Startmenu zijn toegevoegd.

---

## Task 3: Voortgangsrapportage & Roadmap Bijwerken

* **Bestanden:** `PROGRESS_REPORT.md` en `ROADMAP.md`
* **Target Mode:** `Code`
* **Target Provider Profile:** `Ollama - Fast (9b)`
* **Fallback Rule:** Schakel bij een timeout of streamfout voor deze taak direct om naar `Gemini 3.1 Pro`.

### Sub-prompt voor Roo Code:

Lees en werk de bestanden `PROGRESS_REPORT.md` en `ROADMAP.md` bij via `read_file` en `apply_diff`.

1. In `PROGRESS_REPORT.md`:
* Noteer onder **Aanpassingen** dat Bing Search in het Startmenu en reclame/gesponsorde suggesties definitief zijn uitgeschakeld via `debloat.ps1`.
* Vermeld dat Fase 3 hiermee afgerond is (Hibernation behouden, Contextmenu overgeslagen).


2. In `ROADMAP.md`:
* Werk sectie **Fase 3: Windows Tweaks, OOBE Clean-up & Taskbar** bij:
* Zet `Bing Search & Startmenu` en `Reclame uitschakelen` op voltooid (`[x]`).
* Schrap de regels voor Contextmenu en Power & Space/Hibernation of markeer ze als overgeslagen/afgerond.





Sla beide bestanden op.

**Acceptatiecriteria:**

* [ ] `PROGRESS_REPORT.md` bevat de actuele status en afronding van Fase 3.
* [ ] `ROADMAP.md` is bijgewerkt en klaar voor Fase 4 (ISO Creatie & VMware Testing).