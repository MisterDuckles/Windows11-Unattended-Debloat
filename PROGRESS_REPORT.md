# PROGRESS_REPORT: Windows 11 Unattended Setup

## Huidige Status
- **Status:** Fase 3 updates doorgevoerd (OOBE Update Bypass, Toetsenbordtaal & Taskbar Debloat)
- **Laatst bijgewerkt:** 2026-08-05
- **Actieve Agent:** Roo Code (Lokale AI)

---

## Aanpassingen

- `autounattend.xml` aangepast voor US-English ISO met US-International layout (0409:00020409)
- OOBE stopt voor een handmatig lokaal account (SkipUserOOBE = false)
- HideSecurityQuestionsFromLocalUsers is geactiveerd in debloat.ps1
- `DisableOOBEUpdate = 1` ingesteld in `debloat.ps1` om de OOBE update check over te slaan
- `firstlogon.ps1` forceert nu de toetsenbordtaal naar enkel US-International (`0409:00020409`) en unpint de Microsoft Store van de taakbalk
- Bing Search in het Startmenu en reclame/gesponsorde suggesties definitief uitgeschakeld via `debloat.ps1`.
- Fase 3 afgerond (Hibernation behouden, Contextmenu overgeslagen).


---

## Takenoverzicht
- [x] Basis repository structuur (`autounattend.xml`, `debloat.ps1`, `launcher.ps1`)
- [x] Task 1.1: XML Generiek maken (User 'Daan' verwijderen)
- [x] Task 1.2: Winget Firefox & Public Desktop Snelkoppelingen
- [x] Task 1.3: ISO Build Helper script herschreven naar volautomatische builder

---

## Foutlogboek & Escalaties (3-Strikes Rule)
*Geen actieve fouten.*

---

## Handoff Notities voor Roo Code
> De ISO Builder (`build-helper.ps1`) is nu volledig geautomatiseerd. GUI-handleidingen zijn verwijderd. Het script controleert op `oscdimg.exe`, mount de bron ISO, kopieert de inhoud, injecteert `autounattend.xml` en `$OEM$` bestanden, en genereert de uiteindelijke ISO. Standaard paden zijn ingesteld voor Win11 25H2. Volgende stap: Uitvoeren van de build en testen in VMware.
