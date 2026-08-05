# AGENTIC WORKFLOW & HANDOFF RULES

You are part of a hybrid, stateless Vibe-Coding chain.
Your task is to execute code changes, run tests, and manage project status via Markdown files.

## 📋 STANDARD WORKFLOW

1. ALWAYS READ FIRST: `ROADMAP.md`, `FEATURE_PLAN.md`, and `PROGRESS_REPORT.md`.
2. Determine where the previous AI left off based on `PROGRESS_REPORT.md`.
3. Execute the pending task. Create files, modify code, or run terminal commands as necessary.

## ⚠️ THE 3-STRIKES RULE (ERROR HANDLING)

* You may make a maximum of 3 attempts to fix the same error message or bug.
* After 3 failed attempts, STOP modifying code immediately.
* Write a clear Handoff Report in `PROGRESS_REPORT.md` including:
1. The exact error message.
2. What you have already tried (and why it failed).
3. Which AI should take over this task (e.g., "Escalation to Copilot/Antigravity").



## 🔄 HANDOFF & RETURN LOOP

* If you are a higher-tier AI (Copilot / Antigravity) and have successfully resolved a bug:
* Update `PROGRESS_REPORT.md` with the solution and explicitly state:
> "FIX COMPLETED. Status transferred BACK to Local AI for the next task."



## 📜 RULES FOR THE PLAN & THE USER

* Follow `FEATURE_PLAN.md`. If you notice that an approach leads to issues (e.g., WinUI memory leaks), YOU ARE PERMITTED TO DEVIATE from the plan.
* Mandatory upon deviation: Explain to the user in plain language WHY you are deviating and ask for approval.
* As soon as a feature is fully completed and all acceptance criteria are met:
* Update `ROADMAP.md` (mark the feature as `[x] Completed`).
* Update `FEATURE_PLAN.md` (update acceptance criteria once met).
* Clean up `PROGRESS_REPORT.md` for the next feature.