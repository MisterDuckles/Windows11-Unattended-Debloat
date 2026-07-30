# FEATURE_PLAN: Volledig Geautomatiseerde ISO Builder

**Doel:** Het `build-helper.ps1` script strippen van alle handmatige GUI-handleidingen en ombouwen tot een directe, volautomatische ISO generator. Het script pakt standaard de ISO uit `C:\Users\Gebruiker\Downloads\Win11_25H2_EnglishInternational_x64.iso`, injected de bestanden en genereert de nieuwe bootable ISO.

---

## Task 2.1: Refactor build-helper.ps1 naar Volautomatische ISO Generator
**Geschatte tijd:** 10 minuten  
**Aanbevolen Roo Mode:** `Code`  
**Aanbevolen Provider:** `Ollama - Heavy` (qwen3-coder:30b)

### Prompt voor Roo Code:
> Lees het bestand `build-helper.ps1`.
> Herschrijf het script zodat het een gestroomlijnde, volautomatische ISO builder wordt:
> 1. **Verwijder alle GUI-handleidingen** (de lappen tekst over AnyBurn/UltraISO in Stap 2).
> 2. **Standaard Instellingen:**
>    - `$SourceIso` standaard op: `C:\Users\Gebruiker\Downloads\Win11_25H2_EnglishInternational_x64.iso`
>    - `$OutputIso` standaard op: `.\Windows11_25H2_Unattended_Debloat.iso`
> 3. **Automatische Uitvoering:**
>    - Controleer of `autounattend.xml` en `sources\$OEM$\$$\Setup\Scripts\debloat.ps1` aanwezig zijn.
>    - Zoek naar `oscdimg.exe` (Windows ADK). Als deze ontbreekt, geef een heldere foutmelding dat Windows ADK vereist is.
>    - Mount de `$SourceIso`, kopieer de inhoud naar een tijdelijke bouwmap (`$env:TEMP`).
>    - Kopieer `autounattend.xml` naar de root van de tijdelijke bouwmap.
>    - Kopieer de inhoud van `sources\$OEM$` naar `sources\$OEM$` in de tijdelijke bouwmap.
>    - Genereer de nieuwe bootable ISO via `oscdimg.exe` en ruim de tijdelijke map op.
> 4. Update na succesvolle afronding `PROGRESS_REPORT.md` en `ROADMAP.md` (zet ISO Creatie op voltooid).

**Acceptatiecriteria:**
- [x] `build-helper.ps1` bevat geen tekstuele GUI-handleidingen meer.
- [x] `$SourceIso` heeft standaard het gewenste pad ingesteld.
- [x] Het script voert de mount, file-copy, `oscdimg` build en cleanup volledig geautomatiseerd uit.

---

> **Regel voor Roo Code:** Zorg dat paden met spaties en backslashes robuust worden afgehandeld.