# Windows 11 Unattended Debloat

An `autounattend.xml` + payload-script setup that builds a custom Windows 11 25H2 ISO:
unattended install, local account instead of a Microsoft account, a batch of built-in apps
removed before first logon, telemetry/ads locked down, and Firefox + a couple of desktop
shortcuts waiting the first time you sign in.

## Quick start

1. Get a Windows 11 25H2 ISO (this repo was built and tested against
   `Win11_25H2_EnglishInternational_x64_v2`).
2. Install the [Windows ADK](https://learn.microsoft.com/windows-hardware/get-started/adk-install)
   — Deployment Tools only is enough. `build-helper.ps1` will offer to install it via `winget`
   if it can't find `oscdimg.exe`.
3. From an **elevated** PowerShell prompt:

   ```powershell
   .\build-helper.ps1 -SourceIso "C:\path\to\Win11_25H2.iso" -OutputIso "C:\path\to\Output.iso"
   ```

   Both parameters have defaults pointing at `Downloads\`; run it with no arguments if that
   layout suits you. It asks one question — whether to fetch touchpad drivers for Setup from
   the Microsoft Update Catalog (Enter = yes; see
   [Touchpad drivers](#touchpad-drivers-for-setup--touchpaddrivers--harvestinputdrivers-drivers)).
4. Boot a VM (or real hardware) from the resulting ISO. No prompts — it installs, wipes the
   target disk, creates a local account, and lands on a debloated desktop.

Admin rights are required (`Mount-DiskImage` needs them); the script enforces this with
`#Requires -RunAsAdministrator`.

## What it actually does

Four scripts run in sequence, at three different points in the install:

```
autounattend.xml (windowsPE / specialize / oobeSystem passes)
        |
        v
SetupComplete.cmd  --SYSTEM, before OOBE---------------------+
        |                                                    |
        v                                                    |
launcher.ps1  -> debloat.ps1                                 |
        |         (AppX removal, telemetry/ads policies,     |
        |          registers a scheduled task)                |
        v                                                    |
      OOBE  (local account creation, "checking for           |
             updates" screens - see below)                   |
        |                                                    |
        v                                                    |
firstlogon.ps1  --user context, AtLogOn scheduled task--------+
  (Windows Update un-gate, security questions off, wait for
   internet, Firefox via winget, SetupToolbox, keyboard layout,
   taskbar unlock)
```

- **`autounattend.xml`** — disk wipe + partitioning, Windows 11 Pro image selection, regional
  settings (`nl-NL` locale, US-International keyboard, `en-GB` setup UI), OOBE screens
  suppressed except local account creation, and a set of registry writes in the `specialize`
  pass that make the OOBE "checking for updates" screen fail fast instead of actually
  downloading updates (see below).
- **`debloat.ps1`** (SYSTEM, pre-OOBE) — removes ~48 provisioned/installed AppX packages,
  disables telemetry/ads/Recall/Copilot policies, removes OneDrive, locks a Store/Edge-free
  taskbar layout, and registers the first-logon scheduled task.
- **`firstlogon.ps1`** (user context, runs once at first logon) — lifts the Windows Update
  block *first* (see [Windows Update gate](#the-windows-update-gate) below), disables security
  questions for local accounts (see
  [Security questions](#security-questions-on-the-oobe-account-screen) below), waits for a real
  internet connection (see [Waiting for the network](#waiting-for-the-network) below), installs
  Firefox via `winget`, installs SetupToolbox, forces a single US-International keyboard layout,
  unlocks the taskbar for editing, and unregisters its own scheduled task when done. Logs to
  `%USERPROFILE%\debloat-firstlogon.log`.
- **`launcher.ps1`** just runs the staged `debloat.ps1` — it used to fetch a copy from GitHub
  first; that's gone, see [Security notes](#security-notes).

## The Windows Update gate

This is the part most worth understanding before you touch anything here.

The VM used to develop this always has working internet — `debloat.ps1` and `firstlogon.ps1`
both need it. That means the OOBE "checking for updates" screen isn't stalling on a timeout;
it's doing a real scan against Microsoft's servers and would happily download updates during
setup if left alone. To stop that, `autounattend.xml`'s `specialize` pass points Windows
Update at a dead loopback address (`http://127.0.0.1:8530`). The connection is refused
instantly, so the scan fails in ~14 seconds instead of running a full catalog scan.

That redirect writes **persistent** `HKLM` policy values. If nothing removes them, the
installed machine never receives another Windows Update — every check fails with
`0x80240438` forever. So the antidote exists in three independent places, and if you ever
touch the Orders 8-11 registry writes in `autounattend.xml`, update all three:

1. **`autounattend.xml`** — a `<FirstLogonCommands>` block in the `oobeSystem` pass deletes
   the values. This one matters most: it travels inside the answer file itself, so it still
   runs even if someone hand-copies just `autounattend.xml` into a mounted ISO and forgets
   the `sources\$OEM$\` tree.
2. **`firstlogon.ps1`** — step 0, the very first thing the script does, before any network
   call that could stall. It also *verifies* the values are gone rather than assuming.
3. **`debloat.ps1`** — if scheduled-task registration fails (which would mean
   `firstlogon.ps1` never runs), it rolls the gate back inline before exiting.

To confirm on a live machine that the gate was actually lifted:

```powershell
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer
```

This should return "value not found". If it doesn't, Windows Update is still pointed at
nothing and every check will fail.

### The OOBE update screens themselves — not fixable

Two "checking for updates" screens appear during OOBE (before and after account creation).
This was investigated in depth on 2026-08-11/12 using decoded WU/USO ETL traces from a real
install, and the conclusion is that **neither screen can be suppressed** on 25H2:

- The first screen is the OOBE "Zero Day Patch" phase (`CallerId = OOBE ZDP`). No registry
  key hides the page itself — `DisableOOBEUpdate=1` lands in the registry and the scan runs
  anyway. The loopback redirect above just makes the underlying scan fail in 14 seconds
  instead of running a full download.
- The second screen has **no Windows Update activity behind it at all**. What fills that
  ~2 minutes was never identified.

Full writeup, including what was tried and disproved, is in `ROADMAP.md`.

## Waiting for the network

Firefox (`winget`) and SetupToolbox both need internet, and on a laptop there is none at first
logon: nobody has picked a Wi-Fi network yet. Step 1 of `firstlogon.ps1` therefore waits, and
the waiting is deliberately visible.

- **It waits up to 10 minutes** (`$NetworkWaitSeconds`) and continues the *instant* a
  connection appears, so a wired machine still only loses a few seconds. This replaces a flat
  90-second wait that was routinely over before the user had even reached the desktop.
- **"Ready" means DNS *and* reachability**, not just link state. Reachability is a ping to
  `1.1.1.1` with an HTTP fallback to Microsoft's NCSI endpoint, because plenty of guest and
  corporate networks drop ICMP — a ping-only check would sit out the full timeout on a network
  that works fine. `api.github.com` is deliberately not used as the probe: its 60-requests-per-hour
  anonymous limit is needed for the release lookup in step 4.
- **After 20 seconds without a connection** (`$NetworkPromptAfterSeconds`) the user gets a
  top-of-screen window explaining that setup is waiting for internet, with a live countdown,
  and the Windows network picker opens if the machine has a wireless adapter. The window runs
  in its own process and closes itself when a connection appears, when the countdown ends, or
  if the main script disappears — the script never depends on it.
- **If the wait runs out**, Firefox and SetupToolbox are skipped *and the scheduled task is
  kept*, so the next logon tries again — up to `$MaxFirstLogonRuns` (3) runs, after which it
  unregisters and logs that both need installing by hand. Every step is idempotent, so a repeat
  run is safe; the Explorer restart in step 7 is skipped on repeats so the desktop doesn't
  flash at every logon.

The Windows Update gate removal never waits for any of this — it is step 0 and runs first.

## Building the ISO

```powershell
.\build-helper.ps1 [-SourceIso <path>] [-OutputIso <path>] [-RefreshScripts]
                   [-TouchpadDrivers Ask|Download|Skip] [-DriversDir <path>] [-HarvestInputDrivers]
```

The script mounts the source ISO, copies its contents to a temp folder, injects
`autounattend.xml` and `sources\$OEM$\`, and repacks everything with `oscdimg.exe`. It
validates at every step rather than assuming success — an earlier version of this script
could print "ISO SUCCESVOL GEBOUWD!" for an ISO that was silently missing a required file.
It now checks:

- `autounattend.xml` parses as valid XML
- all four payload scripts (`SetupComplete.cmd`, `launcher.ps1`, `debloat.ps1`,
  `firstlogon.ps1`) exist, both in the repo and again after being copied into the build
  staging folder
- `robocopy`'s exit code (≥8 means files failed to copy — this used to be discarded)
- `sources\install.wim` or `.esd` is present in the copy
- both boot files (`boot\etfsboot.com`, `efi\microsoft\boot\efisys.bin`) exist before calling
  `oscdimg`
- the final ISO is at least 3 GB (catches a build that silently produced an near-empty image)

The source ISO is always dismounted in a `finally` block, even if the script throws midway,
so an interrupted run doesn't leave the next one failing on a mounted-but-inaccessible image.

### `-RefreshScripts`

Pulls the latest version of the four payload scripts from GitHub *before* building, with a
PowerShell parse check on each and automatic rollback to the previous local copy if a
download fails or comes back malformed. This exists so you can keep the payload scripts
up to date without ever running unverified remote code on a machine you're installing —
see [Security notes](#security-notes) for why that distinction matters.

```powershell
.\build-helper.ps1 -RefreshScripts
```

Always review `git diff` after using this flag before rolling out the resulting ISO.

### Touchpad drivers for Setup (`-TouchpadDrivers`, `-HarvestInputDrivers`, `drivers\`)

Windows Setup runs inside WinPE, and WinPE only has the drivers that are inside `boot.wim`.
A modern precision touchpad is not a PS/2 or USB device — it hangs off the motherboard's I2C
bus, so three layers have to be present before it works: the GPIO controller (interrupt line),
the I2C controller (the bus), and `hidi2c` (the HID device itself).

`hidi2c` is in the box. The controllers frequently are not. Measured against Windows 11 25H2
(build 26200), by looking up which hardware IDs have an in-box INF:

| Platform | In-box driver? |
| --- | --- |
| AMD (`ACPI\AMDI0010`, `ACPI\AMDI0030`) | yes — `amdi2c.inf`, `amdgpio2.inf` |
| Intel up to Comet Lake / Gemini Lake | yes — `iaLPSS2i_*_SKL/BXT_P/CNL/GLK.inf` |
| Intel Ice Lake (`DEV_34E8`) | **no** |
| Intel Tiger Lake (`DEV_A0E8`) | **no** |
| Intel Alder Lake (`DEV_51E8`, `DEV_7ACC`) | **no** |
| Intel Raptor Lake (`DEV_51E9`) | **no** |
| Intel Meteor Lake (`DEV_7E78`) | **no** |

So on any Intel laptop from roughly 2020 onwards the touchpad is dead during Setup — you get
to tab through the partition screen — unless the Intel Serial IO drivers ship with the media.
It works fine *after* installation because Windows Update delivers them, and there is no
Windows Update inside Setup.

#### The automatic route: the build asks

By default `build-helper.ps1` asks, right after the file checks and before the slow ISO copy:

```
[2b/5] Touchpad-drivers voor Windows Setup...
    Touchpad-drivers ophalen en meebakken? (J/n)
```

Enter (or `j`) fetches the Intel Serial IO package for each generation from the **Microsoft
Update Catalog** — the same place Windows Update gets them — into `drivers\IntelSerialIO\`, from
where they follow the normal driver route below. Eight packages, about 2 MB, roughly 30 seconds.
Covered: Ice Lake, Jasper Lake, Tiger Lake, Alder/Raptor Lake, Alder Lake-N, Meteor Lake /
Arrow Lake-H, Lunar Lake and Panther Lake. Everything older, and AMD, is already in `boot.wim`.

For scripted builds the question can be answered up front:

```powershell
.\build-helper.ps1 -TouchpadDrivers Download   # fetch without asking
.\build-helper.ps1 -TouchpadDrivers Skip       # don't fetch; previously fetched packages still ship
```

Fetched packages are cached by generation and version. A rebuild re-checks the catalog (a few
seconds), reuses what it has, and replaces a package only when a newer version exists — so two
versions of the same driver never end up side by side in the ISO. No internet is not an error:
the build warns and continues with whatever is already in `drivers\`.

How the catalog is driven, and why this is less fragile than it sounds: each generation is
looked up by one representative I2C controller hardware ID (e.g. `PCI\VEN_8086&DEV_A0E8` for
Tiger Lake). The result rows are parsed for the version number in the title, the best candidate
is confirmed on its details page to really be an AMD64 *Serial IO I2C* driver that lists that
hardware ID (searching for Arrow Lake-S's ID surfaced the Integrated Sensor Hub driver first —
that check exists because of it), the `.cab` is downloaded through `DownloadDialog.aspx`,
expanded with `expand.exe`, and every `.cat` is checked for a valid Authenticode signature.
Each `.cab` turned out to contain the *complete* Serial IO package for its generation — GPIO,
I2C, SPI, UART — so one download per generation does it. INFs for generations that are already
in-box (the Ice Lake package also carries Skylake INFs with identical hardware IDs) are removed
before the package is used, for the KB2686316 reason explained below. Sorting the catalog's
results server-side (an ASP.NET postback) is deliberately *not* used: it returned an error page,
and it is exactly the kind of mechanism that breaks when Microsoft touches the site.

#### The manual route: `drivers\`

Drop unpacked driver packages (folders containing `.inf`/`.sys`/`.cat`; not `.exe` installers)
into `drivers\` and `build-helper.ps1` puts them in two places, deliberately using the same
files for both:

1. **Injected into `boot.wim`** (the Setup image, via DISM). This is the one that makes the
   touchpad work on the partition screen, because WinPE loads its drivers at boot — before
   `setup.exe` even starts.
2. **Copied to `$WinPEDriver$` at the ISO root.** Setup scans that folder on every drive letter
   from C: upwards and also schedules those drivers into the Windows being installed.

Using the *same* files for both routes is not laziness. Microsoft's KB2686316 warns that if the
two routes carry *different versions* of the same driver, the one WinPE already has in memory
wins and the other gets flagged as a bad driver and ignored from then on — even when it is
newer. The same logic is why the catalog route strips INFs for in-box generations.

This is also where anything else Setup might need goes — Intel RST/VMD storage drivers when the
disk doesn't show up, a vendor touchpad driver for an exotic model.

If you're building the ISO on a machine of the same generation as the target laptop, there is a
third option:

```powershell
.\build-helper.ps1 -HarvestInputDrivers
```

That exports the build machine's own I2C, GPIO, HID, mouse and keyboard driver packages
(`pnputil /export-driver`, only out-of-box `oem*.inf` ones — in-box drivers are already in
`boot.wim`) and adds them to whatever is in `drivers\`. It only helps when the hardware is
comparable: an AMD build machine cannot produce an Intel Serial IO driver.

The build reports what it did. With no drivers present it warns rather than fails — on AMD and
older Intel the in-box stack is enough — but it says so on both the driver step and the final
summary line, so an ISO without drivers never looks the same as one with them. The summary
reports the number of packages *measured inside `boot.wim` after injection*, not the number
offered, so a package DISM rejected shows up as a lower count.

`drivers\` contents are gitignored; only its `README.md` is tracked.

## Security notes

`launcher.ps1` used to fetch `debloat.ps1` from `raw.githubusercontent.com` at install time
and prefer that copy over the tested local one. That's gone. Four reasons, any one of which
would have been enough on its own:

1. It ran code from the internet as SYSTEM, before OOBE, with no hash or signature check.
2. The URL pointed at the mutable `refs/heads/master` ref, which can drift out of sync with
   what was actually tested.
3. A GitHub token sat in cleartext in a file that ships to every deployed machine's
   `C:\Windows\Setup\Scripts`, readable by any local user, and was also echoed into the setup
   log.
4. It didn't even work — the token had expired, every fetch 404'd, and it silently fell back
   to the local copy anyway.

Refreshing scripts now happens at build time instead (`-RefreshScripts`, above), where it's
visible, diffable, and testable before anything is rolled out. A deployed machine only ever
runs the script that was staged into its own ISO.

## Security questions on the OOBE account screen

Create a local account during OOBE *with* a password and Windows demands three security
questions. Leave the password empty and it doesn't. As of 2026-08-22 this repo handles that as
follows — and the history matters, because the previous handling looked correct and did nothing.

`debloat.ps1` used to set:

```
HKLM\SOFTWARE\Policies\Microsoft\Windows\System  HideSecurityQuestionsFromLocalUsers = 1
```

**That value name does not exist in Windows.** Checked on 25H2 (build 26200): it appears in no
ADMX file and in no system DLL. The real policy is defined in `CredUI.admx` as

```
key:       Software\Policies\Microsoft\Windows\System
valueName: NoLocalPasswordResetQuestions
```

(Computer Configuration → Administrative Templates → Windows Components → Credential User
Interface → "Prevent the use of security questions for local accounts")

So the setting was a no-op and the questions kept appearing on every install.

**What happens now:** `firstlogon.ps1` step 0b sets the real value, verifies it, and deletes the
bogus one left behind by older ISOs. That means the finished machine never asks security
questions again — adding or changing a password in Settings afterwards goes straight through.

**Why it is not set before OOBE.** Setting this policy in the `specialize` pass (or via group
policy before sysprep) is widely reported to break the Windows 11 OOBE local-account page with
an `OOBELOCAL` error — the install dies on exactly the screen where you're trying to make an
account. Even when it does work, it doesn't remove the prompt: CloudExperienceHost's
`oobelocalaccount-main.html` renders a mandatory password *hint* panel whenever
`isLocalSecurityQuestionResetAllowed` is false. Three questions become one hint field. That
trade is not worth the risk of a dead OOBE, so the policy lands after OOBE instead.

**If you want the questions gone from OOBE itself**, there is exactly one reliable route: don't
use the OOBE account page at all. `autounattend.xml` carries a ready-to-enable, commented-out
`<UserAccounts><LocalAccounts>` block for that; set `HideLocalAccountScreen` to `true` alongside
it. The price is that the account name is baked into the ISO instead of typed during setup —
which is exactly why that block was removed back in commit f293b19, so it ships disabled.

The practical middle ground, and what the defaults give you: type the account name at OOBE,
leave the password blank (no questions), and set a password after first logon — where, thanks
to step 0b, nobody asks you anything.

## Known limitations

- **The two OOBE update screens cannot be suppressed** — see
  [above](#the-oobe-update-screens-themselves--not-fixable). This isn't a bug to keep
  chasing; it's a documented dead end.
- **`firstlogon.ps1` still needs internet eventually.** It now waits for it and retries at the
  next logon instead of silently skipping (see [Waiting for the network](#waiting-for-the-network)),
  but a machine that never gets a connection still ends up without Firefox and SetupToolbox.
  The log says so explicitly when that happens. The Windows Update gate removal (the part that
  actually matters for long-term machine health) does not depend on network and always runs first.
- **Security questions cannot be removed from the OOBE screen itself** without giving up
  interactive account creation — see [above](#security-questions-on-the-oobe-account-screen).
  They are gone everywhere else on the finished machine.
- **Setup drivers are not shipped in this repo; they are fetched at build time.** `drivers\` is
  empty in git — third-party driver binaries don't belong in a repo — and the build asks
  whether to pull the Intel Serial IO packages from the Microsoft Update Catalog (see
  [above](#touchpad-drivers-for-setup--touchpaddrivers--harvestinputdrivers-drivers)). Answer
  no, or build offline with nothing cached, and Intel laptops from 2020 onwards still have a
  dead touchpad during Setup. The build says so when that happens.
- **No automated test suite.** Every change here should be validated with a real install in a
  VM. `%USERPROFILE%\debloat-firstlogon.log` (user-context steps) and
  `%WINDIR%\Panther\debloat.log` (SYSTEM-context steps, captured by `SetupComplete.cmd`) are
  the two logs to check after a test run.
- **Region/locale is currently hardcoded** to `nl-NL` system/user locale with a US-International
  keyboard and `en-GB` setup UI. If you need a different region, edit the
  `Microsoft-Windows-International-Core*` components in `autounattend.xml` and the
  `New-WinUserLanguageList` call in `firstlogon.ps1` step 6 together — they need to agree.

## Repository layout

```
autounattend.xml                          Answer file: disk setup, OOBE config, WU gate
build-helper.ps1                          ISO builder (mount, inject, repack, validate)
drivers/                                  Drop setup drivers here (gitignored; see its README)
sources/$OEM$/$$/Setup/Scripts/
    SetupComplete.cmd                     Entry point, runs as SYSTEM before OOBE
    launcher.ps1                          Runs the staged debloat.ps1
    debloat.ps1                           AppX removal, policies, schedules firstlogon.ps1
    firstlogon.ps1                        Runs once at first logon (user context)
ROADMAP.md                                Phase-by-phase history + the OOBE investigation writeup
PROGRESS_REPORT.md                        Status log / fault log from past debugging rounds
```

## Further reading

`ROADMAP.md` has the full phase-by-phase history of this project, including the complete
OOBE update-screen investigation (with quoted evidence from decoded ETL traces) and a fault
log of what was found and fixed in the most recent robustness pass. Worth reading before
making changes to `autounattend.xml` or the Windows Update handling anywhere in this repo.
