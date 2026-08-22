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
- [x] **First-logon scripting:** Los `firstlogon.ps1` script aangemaakt voor eerste-inlog automatisering en onderhoud.
- [x] **Wachten op netwerk (laptops zonder kabel):** `firstlogon.ps1` wacht tot 10 minuten op een echte internetverbinding (DNS + bereikbaarheid, ICMP-onafhankelijk), toont na 20 seconden een venster met aftelklok plus de Windows-netwerkkiezer, en gaat verder zodra er verbinding is. Lukt het niet binnen de wachttijd, dan blijven Firefox en SetupToolbox liggen en blijft de scheduled task staan voor een nieuwe poging bij de volgende inlog (max. 3 runs). Vervangt de vaste wachttijd van 90 seconden, die op een laptop altijd te vroeg afliep.

## Fase 3: Windows Tweaks, OOBE Clean-up & Taskbar (In-depth Fine-tuning)
- [~] **OOBE Update Bypass:** *Niet haalbaar gebleken — zie [Onderzoek: OOBE update-schermen](#onderzoek-oobe-update-schermen).* `DisableOOBEUpdate` wordt op 25H2 niet gehonoreerd. De scan is wél teruggebracht van een volledige download naar 14 seconden.
- [x] **Taal- & Toetsenbord Opschonen:** Dubbele toetsenbordtaal (ENG/NLD) op het bureaublad verwijderen en dwingen tot enkel US-International in `firstlogon.ps1`.
- [x] **Taskbar Debloat:** Microsoft Store icoon automatisch ontkoppelen van de taakbalk.
- [x] **Bing Search & Startmenu:** Web-zoekresultaten in het Startmenu uitgeschakeld via het register (`DisableSearchBoxSuggestions` + CloudContent settings) — toegepast in `debloat.ps1`.
- [x] **Reclame uitschakelen:** "Aanbevolen" en gesponsorde suggesties in het Startmenu geblokkeerd via CloudContent policies — toegepast in `debloat.ps1`.
- [x] **Fase 3 afronden:** Contextmenu en hibernation zijn bewust buiten scope gebleven.

## Fase 4: ISO Creatie & VMware Testing
- [x] **ISO Build Helper:** Volledig geautomatiseerd script (`build-helper.ps1`) voor ISO generatie.
- [x] **Build-validatie:** `build-helper.ps1` controleert nu de robocopy-exitcode, de aanwezigheid van alle vier payload-scripts (in de repo én in de bouwmap), `install.wim`/`install.esd`, beide bootbestanden en de uiteindelijke ISO-grootte. Vereist admin. De bron-ISO wordt altijd gedemonteerd, ook bij een afgebroken run.
- [x] **Scripts verversen op buildtijd:** `build-helper.ps1 -RefreshScripts` haalt de nieuwste payload-scripts van GitHub vóór het bouwen, met parse-check en automatische terugrol bij een mislukte download.
- [ ] Testen van de complete ISO in VMware Workstation Pro.

---

## Onderzoek: OOBE update-schermen

**Status: afgesloten, niet oplosbaar.** Uitgezocht op 2026-08-11/12 met gedecodeerde
WU- en USO-ETL-traces uit een echte installatie. Niet opnieuw beginnen zonder nieuw bewijs.

De twee "checking for updates"-schermen tijdens OOBE zijn niet te onderdrukken:

| Scherm | Duur | Oorzaak |
|---|---|---|
| Vóór accountaanmaak | ~81s | OOBE Zero Day Patch-fase. Bewijs: `* END * Finding updates CallerId = OOBE ZDP, Exit code = 0x80240438`. De scan zelf duurt 14s; de rest is CloudExperienceHost-UI. |
| Ná accountaanmaak | ~122s | **Geen** Windows Update. De WU-agent logt in dit hele venster alleen `Power status changed`. Wat de tijd vult is niet vastgesteld. |

Wat is geprobeerd en aantoonbaar niet werkt:

- `DisableOOBEUpdate=1` — landde in het register, scan draaide alsnog.
- `DisableCloudOptimizedContent=1` — geen effect op beide schermen.
- `DoNotConnectToWindowsUpdateInternetLocations=1` — **verwijderd**. Deed niets voor de OOBE-scan
  en blokkeerde de Service Locator Service, waardoor de Microsoft Store zich niet kon
  registreren (`0x8024500C WU_E_REDIRECTOR_CONNECT_POLICY`, gefaald in 2,3 ms zonder netwerk-I/O).

Wat wél werkt: de **loopback-WSUS-redirect** (Orders 8-11 in `autounattend.xml`). Die kapt de
OOBE-scan af op 14 seconden in plaats van een volledige catalogus-scan met download.

### Invariant

`autounattend.xml` Orders 8-11 schrijven **persistente** HKLM-policies. Blijven die staan, dan
krijgt de machine nooit meer een update. Het tegengif zit daarom op drie plaatsen en die horen
altijd samen gewijzigd te worden:

1. `autounattend.xml` → `<FirstLogonCommands>` in de oobeSystem-pass *(reist mee in de answer file zelf)*
2. `firstlogon.ps1` → stap 0, bovenaan het script *(vóór alle netwerkstappen)*
3. `debloat.ps1` → inline rollback als de scheduled-task-registratie faalt

## Bekende aandachtspunten

- **`0x80070032` bij AppX-verwijdering** was `Microsoft.XboxGameCallableUI`, een `NonRemovable`
  SystemApp. Uit de lijst gehaald; systeem-apps worden nu overgeslagen en gelogd.
- **`launcher.ps1` haalt geen scripts meer van internet.** De oude remote-fetch draaide
  ongeverifieerde code als SYSTEM vanaf een mutable branch, met een GitHub-token in cleartext in
  een bestand dat op elke gedeployde machine belandt. Vervangen door `-RefreshScripts` op buildtijd.
- **Klok springt +1 uur tijdens setup** (DST-correctie, UTC+1 → UTC+2). Lokale tijdstempels in
  `setupact.log` zijn daardoor misleidend rond dat moment; CSI-regels dragen hun eigen UTC-stempel.
- **De VM heeft altijd internet.** `debloat.ps1` en `firstlogon.ps1` downloaden software, dus het
  netwerk uitzetten is geen geldige testconditie.