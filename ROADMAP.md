# Roadmap: Windows 11 Unattended, Debloat & SetupToolbox

## Fase 1: Basis & Generieke Unattend
- [x] Base Unattend XML opzetten (Nederlands, Disk 0 Wipe, EULA acceptatie)
- [x] Basic AppX Debloat (Copilot, Xbox, Consumentenapps)
- [x] **Generieke XML:** Hardcoded gebruiker ('Daan') verwijderen, `<HideLocalAccountScreen>false</HideLocalAccountScreen>` behouden voor lokaal account.
- [x] **OOBE Repair & US-International Layout:** ISO taal-mismatch opgelost en toetsenbord vastgezet op US-International (`0409:00020409`).

## Fase 2: Post-Install & Software Automation
- [x] **Winget Firefox:** Automatische achtergrondinstallatie van Firefox bij de eerste inlog via `firstlogon.ps1`.
- [x] **SetupToolbox & MAS Integration:** Snelkoppelingen naar SetupToolbox en MAS op het `Public` bureaublad plaatsen.
- [x] **OneDrive Cleanup:** Per-user OneDrive installer definitief uitschakelen bij logon.

## Fase 3: Windows Tweaks, OOBE Clean-up & Taskbar (In-depth Fine-tuning)
- [x] **OOBE Update Bypass:** OOBE Windows Update scherm ("Getting the latest features and security updates") uitschakelen via het register (`DisableOOBEUpdate`).
- [x] **Taal- & Toetsenbord Opschonen:** Dubbele toetsenbordtaal (ENG/NLD) op het bureaublad verwijderen en dwingen tot enkel US-International in `firstlogon.ps1`.
- [x] **Taskbar Debloat:** Microsoft Store icoon automatisch ontkoppelen van de taakbalk.
- [x] **Bing Search & Startmenu:** Web-zoekresultaten in het Startmenu uitgeschakeld via het register (`DisableSearchBoxSuggestions` + CloudContent settings) — toegepast in `debloat.ps1`.
- [x] **Reclame uitschakelen:** "Aanbevolen" en gesponsorde suggesties in het Startmenu geblokkeerd via CloudContent policies — toegepast in `debloat.ps1`.
- [ ] **Power & Space:** Hibernation behouden (overgeslagen) — geen `powercfg /h off` toegepast.
- [ ] **Contextmenu:** Aanpassingen overgeslagen.

## Fase 4: ISO Creatie & VMware Testing
- [x] **ISO Build Helper:** Volledig geautomatiseerd script (`build-helper.ps1`) voor ISO generatie.
- [ ] Testen van de complete ISO in VMware Workstation Pro.