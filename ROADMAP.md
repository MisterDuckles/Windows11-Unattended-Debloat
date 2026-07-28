# Roadmap: Windows 11 Unattended & Debloat

## Fase 1: Finetuning van de Huidige Basis
- [ ] **Review AppX Debloat:** Controleren welke apps momenteel verwijderd worden en deze lijst up-to-date maken (sommige Windows 11 versies hebben weer nieuwe bloatware).
- [ ] **Register Tweaks (Brainstorm):**
  - [ ] Telemetrie en dataverzameling uitzetten.
  - [ ] Web-zoekresultaten in het Startmenu uitschakelen (Bing search uitschakelen).
  - [ ] Klassieke contextmenu in Windows 11 herstellen (optioneel).
  - [ ] Reclame en "Aanbevolen" apps in Start uitschakelen.
  - [ ] Hibernation (Sluimerstand) uitschakelen om schijfruimte te besparen.
- [ ] **Unattend XML optimalisatie:** Controleren of we de OOBE (setup-schermen zoals privacy-vragen) direct 100% kunnen overslaan (AutoLogon instellen voor de gebruiker).

## Fase 2: OneDrive & User Logon Triggers
- [ ] **OneDrive definitief blokkeren/verwijderen:** OneDrive nestelt zich op gebruikersniveau (`per-user`). Aanpassen via de `debloat.ps1` door de zogenaamde "Default User" registry hive in te laden en de *OneDriveSetup* trigger daar uit te slopen. Zo installeert hij zichzelf nooit meer voor nieuwe gebruikers (of met paar minuten delay na logon).
- [ ] **Winget & Firefox:**
  - [ ] Testen en oplossen van Firefox installatie.
  - [ ] Automatische app-installaties triggeren via een `RunOnce` of Geplande Taak, zodat winget correct draait nádat de eerste gebruiker is ingelogd ("Post-Logon script").

## Fase 3: Externe Tools & Snelkoppelingen
- [ ] **Tweak & Winget App:** De bestaande tweak/winget app downloaden of vanuit de `$OEM$` map kopiëren, en hiervoor een snelkoppeling plaatsen in `C:\Users\Public\Desktop` zodat deze direct klaarstaat op het bureaublad.
- [ ] **Massgrave (MAS) Kopie:**
  - [ ] MAS script forken/clonen en zelf hosten.
  - [ ] Een klein activatie-script maken (bijv. "Windows Activeren.cmd") en als snelkoppeling/bestand op de `Public Desktop` plaatsen als keuzemogelijkheid.

## Brainstorm / Verder onderzoeken
- [ ] Controleren wat er op dit moment exact wordt uitgehaald.
- [ ] Onderzoeken of er nog andere nuttige tweaks/packages zijn die we direct kunnen integreren in de XML of het repository.