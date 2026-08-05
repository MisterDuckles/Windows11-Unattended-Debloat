# PROGRESS_REPORT: Windows 11 Unattended Setup

## Huidige Status
- **Status:** ISO Builder geautomatiseerd
- **Laatst bijgewerkt:** 2026-07-30
- **Actieve Agent:** Roo Code (Lokale AI)

---

## Aanpassingen

- `autounattend.xml` aangepast voor US-English ISO met US-International layout (0409:00020409)
- OOBE stopt voor een handmatig lokaal account (SkipUserOOBE = false)
- HideSecurityQuestionsFromLocalUsers is geactiveerd in debloat.ps1

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
