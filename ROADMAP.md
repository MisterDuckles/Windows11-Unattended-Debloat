# Roadmap: Windows 11 Unattended, Debloat & SetupToolbox

## Fase 1: Basis & Generieke Unattend (Huidige Focus)
- [x] Base Unattend XML opzetten (Nederlands, Disk 0 Wipe, EULA acceptatie)
- [x] Basic AppX Debloat (Copilot, Xbox, Consumentenapps)
- [ ] **Generieke XML:** Hardcoded gebruiker ('Daan') verwijderen, `<HideLocalAccountScreen>false</HideLocalAccountScreen>` behouden voor lokaal account.

## Fase 2: Post-Install & Software Automation
- [x] **Winget Firefox:** Automatische achtergrondinstallatie van Firefox bij de eerste inlog via `firstlogon.ps1`.
- [x] **SetupToolbox & MAS Integration:** Snelkoppelingen naar SetupToolbox en MAS op het `Public` bureaublad plaatsen.
- [ ] **OneDrive Cleanup:** Per-user OneDrive installer definitief uitschakelen bij logon.

## Fase 3: Windows Tweaks & Register (In-depth Fine-tuning)
- [ ] **Bing Search & Startmenu:** Web-zoekresultaten in het Startmenu uitschakelen via het register.
- [ ] **Contextmenu:** Klassiek Windows 10 contextmenu herstellen in Windows 11 (optioneel).
- [ ] **Power & Space:** Hibernation (Sluimerstand) uitschakelen (`powercfg /h off`) om gigabytes aan schijfruimte te besparen.
- [ ] **Reclame uitschakelen:** "Aanbevolen" en gesponsorde apps in het Startmenu blokkeren.

## Fase 4: ISO Creatie & VMware Testing
- [x] **ISO Build Helper:** Volledig geautomatiseerd script (`build-helper.ps1`) voor ISO generatie.
- [ ] Testen van de complete ISO in VMware Workstation Pro.