# PROGRESS_REPORT: Windows 11 Unattended Setup

## Huidige Status
- **Status:** OOBE-onderzoek afgesloten, robuustheidsronde doorgevoerd. Klaar om te testen.
- **Laatst bijgewerkt:** 2026-08-12

---

## Aanpassingen

- `autounattend.xml` aangepast voor US-English ISO met US-International layout (0409:00020409)
- OOBE stopt voor een handmatig lokaal account (SkipUserOOBE = false)
- HideSecurityQuestionsFromLocalUsers is geactiveerd in debloat.ps1
- ~~`DisableOOBEUpdate = 1` slaat de OOBE update check over~~ — **onjuist gebleken.** De key wordt op 25H2 niet gehonoreerd; de scan draait alsnog. Zie ROADMAP.md → "Onderzoek: OOBE update-schermen". De scan wordt nu afgekapt op 14 seconden via een loopback-WSUS-redirect.
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

**Opgelost op 2026-08-12** (audit van de volledige keten):

| # | Probleem | Gevolg |
|---|---|---|
| 1 | WU-blokkade werd alleen opgeheven aan het eind van `firstlogon.ps1`, achter onbegrensde netwerkcalls | Machine kon uitgeleverd worden met permanent kapotte Windows Update |
| 2 | Geen tegengif in `autounattend.xml` zelf | Handmatig kopiëren zonder `$OEM$` gaf gif zonder tegengif |
| 3 | `Register-ScheduledTask` faalde stil; `BUILTIN\Users` is gelokaliseerd | Op niet-Engelse image geen first-logon taak, log meldde tóch succes |
| 4 | `launcher.ps1` draaide ongeverifieerde remote code als SYSTEM, token in cleartext | Supply-chain risico zodra de repo public wordt |
| 5 | `build-helper.ps1` gooide robocopy's exitcode weg | Onvolledige ISO werd als "SUCCESVOL GEBOUWD" gemeld |
| 6 | 3,44 GB ISO in git-history | Elke push geweigerd door GitHub |

Kleinere zaken uit dezelfde ronde: `Remove-AppxPackage` logde altijd succes (non-terminating error), `winget`-exitcode werd nooit gelezen, SetupToolbox-download werd alleen op bytegrootte geaccepteerd, Start-menu kon vergrendeld worden tegen een niet-bestaande layout, en de AppX-inventaris werd 102× opnieuw opgehaald binnen de lus.

---

## Handoff Notities voor Roo Code
> De ISO Builder (`build-helper.ps1`) is nu volledig geautomatiseerd. GUI-handleidingen zijn verwijderd. Het script controleert op `oscdimg.exe`, mount de bron ISO, kopieert de inhoud, injecteert `autounattend.xml` en `$OEM$` bestanden, en genereert de uiteindelijke ISO. Standaard paden zijn ingesteld voor Win11 25H2. Volgende stap: Uitvoeren van de build en testen in VMware.
