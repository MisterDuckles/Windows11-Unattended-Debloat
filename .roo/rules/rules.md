# AGENTIC WORKFLOW & HANDOFF RULES

Je bent onderdeel van een hybride, staatloze Vibe-Coding keten. 
Jouw taak is het uitvoeren van code-aanpassingen, het draaien van tests en het beheren van de projectstatus via Markdown-bestanden.

## 📋 VASTE WERKWIJZE
1. LEES ALTIJD EERST: `ROADMAP.md`, `FEATURE_PLAN.md` en `PROGRESS_REPORT.md`.
2. Bepaal waar de vorige AI is gebleven op basis van `PROGRESS_REPORT.md`.
3. Voer de openstaande taak uit. Maak bestanden aan, pas code aan of run terminal-commando's indien nodig.

## ⚠️ DE 3-STRIKES REGEL (FOUTAFHANDELING)
- Je mag maximaal 3 pogingen doen om dezelfde foutmelding of bug te herstellen.
- Na 3 mislukte pogingen STOP je direct met code aanpassen.
- Schrijf een helder Handoff Report in `PROGRESS_REPORT.md` met:
  1. De exacte foutmelding.
  2. Wat je al hebt geprobeerd (en waarom het mislukte).
  3. Welke AI deze taak moet overnemen (bijv. "Escalatie naar Copilot/Antigravity").

## 🔄 HANDOFF & TERUGKEER-LOOP
- Ben jij een hogere-laag AI (Copilot / Antigravity) en heb je een bug succesvol opgelost?
- Update `PROGRESS_REPORT.md` met de oplossing en vermeld expliciet: 
  > "FIX VOLTOOID. Status overgedragen TERUG naar Lokale AI voor volgende taak."

## 📜 REGELS VOOR HET PLAN & DE USER
- Volg `FEATURE_PLAN.md`. Als je ziet dat een aanpak tot problemen leidt (bijv. WinUI memory leaks), MOGER JE AFWIJKEN van het plan.
- Verplicht bij afwijking: Leg in begrijpelijke mensentaal aan de gebruiker uit WAAROM je afwijkt en vraag om akkoord.
- Zodra een feature volledig is afgerond en alle acceptatiecriteria zijn gehaald:
  - Update `ROADMAP.md` (zet de feature op `[x] Voltooid`).
  - Update `FEATURE_PLAN.md` (werk de acceptatie criteria bij als deze zijn gehaald)
  - Schoon `PROGRESS_REPORT.md` op voor de volgende feature.