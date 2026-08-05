# FEATURE_PLAN: Generieke OOBE Setup met US-International Layout & Geen Beveiligingsvragen

**Doel:** De Windows 11 installatie volledig geautomatiseerd laten verlopen (US-International toetsenbord, geen taalkeuzeschermen), waarna Setup stopt bij het lokale account-scherm zonder de verplichte 3 beveiligingsvragen af te dwingen bij het instellen van een wachtwoord.

---

## Task 1: Beveiligingsvragen Uitschakelen via Register
- **Bestand:** `sources/$OEM$/$$/Setup/Scripts/debloat.ps1`
- **Aanbevolen Roo Mode:** `Code`
- **Aanbevolen Provider:** `Ollama - Heavy (qwen3-coder:30b)`

### Sub-prompt voor Roo Code:
Lees het bestand `sources/$OEM$/$$/Setup/Scripts/debloat.ps1`.

Voeg in Stap 3 (privacy and telemetry hardening) de volgende registerinstelling toe met de Set-RegValue helper-functie om de verplichte 3 beveiligingsvragen bij het instellen van een lokaal account-wachtwoord uit te schakelen:

Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "HideSecurityQuestionsFromLocalUsers" 1

Sla het bestand op.

**Acceptatiecriteria:**
- [ ] De policy `HideSecurityQuestionsFromLocalUsers` is correct toegevoegd aan `debloat.ps1`.

---

## Task 2: XML Geen UserOOBE & US-International Layout
- **Bestand:** `autounattend.xml`
- **Aanbevolen Roo Mode:** `Code`
- **Aanbevolen Provider:** `Ollama - Heavy (qwen3-coder:30b)`

### Sub-prompt voor Roo Code:
Lees het bestand `autounattend.xml`.

Pas de XML aan om de WinPE-taal, toetsenbordindeling en OOBE-pauze correct in te stellen:

1. In de windowsPE pass (Microsoft-Windows-International-Core-WinPE):
   - Zet <UILanguage> en <SetupUILanguage><UILanguage> op en-US.
   - Voeg <WillShowUI>OnError</WillShowUI> toe binnen <SetupUILanguage>.
   - Zet <InputLocale> op 0409:00020409 (US-International).

2. In de oobeSystem pass (Microsoft-Windows-International-Core):
   - Zet <InputLocale> op 0409:00020409.
   - Zet <UILanguage> op en-US.

3. In de oobeSystem pass (Microsoft-Windows-Shell-Setup -> <OOBE>):
   - Zet <SkipUserOOBE>false</SkipUserOOBE> (zorgt dat Windows pauzeert voor een lokaal account).
   - Zet <HideLocalAccountScreen>false</HideLocalAccountScreen>.
   - Zet <HideOnlineAccountScreens>true</HideOnlineAccountScreens> (voorkomt de verplichting van een Microsoft Account).
   - Controleer dat er GEEN <UserAccounts> of <AutoLogon> secties aanwezig zijn.

Sla de wijzigingen op in autounattend.xml.

**Acceptatiecriteria:**
- [ ] Taalschermen verschijnen niet meer tijdens de WinPE-fase.
- [ ] `InputLocale` is in beide passes hardcoded ingesteld op `0409:00020409`.
- [ ] Setup stopt bij het aanmaken van een lokaal account zonder Microsoft Account-dwang.

---

## Task 3: Voortgangsrapportage & Roadmap Bijwerken
- **Bestanden:** `PROGRESS_REPORT.md` en `ROADMAP.md`
- **Aanbevolen Roo Mode:** `Code`
- **Aanbevolen Provider:** `Ollama - Fast (qwen3.5:9b)`

### Sub-prompt voor Roo Code:
Lees en werk de bestanden `PROGRESS_REPORT.md` en `ROADMAP.md` bij.

1. In PROGRESS_REPORT.md: Noteer dat autounattend.xml is aangepast voor de US-English ISO met US-International layout (0409:00020409). Vermeld dat OOBE stopt voor een handmatig lokaal account (SkipUserOOBE = false) en dat HideSecurityQuestionsFromLocalUsers is geactiveerd in debloat.ps1.
2. In ROADMAP.md: Vink de taak "Generieke XML / Lokaal account" af onder Fase 1 ([x]).

Sla beide bestanden op.

**Acceptatiecriteria:**
- [ ] `PROGRESS_REPORT.md` bevat de actuele status en genomen stappen.
- [ ] `ROADMAP.md` is bijgewerkt.