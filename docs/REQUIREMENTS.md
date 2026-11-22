# Requirements

OpenSweep reclaims disk space from developer projects on macOS, with a
command-line engine that also runs on Linux. This document says what v1 must
do, what it will not do, and how each requirement is accepted.

Decisions recorded 19 Nov 2026: name OpenSweep; start from Zouuabi/CleanMyDev (MIT);
Rust engine with a SwiftUI app; MIT for new work (Apache-2.0 up to v0.2.0); developer-only scope;
local stats and an original character, no public leaderboard; Developer ID
with notarization and a Homebrew cask.

## Principles

1. Nothing leaves the machine. The update check is the only network call and
   can be turned off.
2. Every verdict is explained: why a project is idle, which rule matched.
3. Reversible by default: quarantine with a manifest, restore by run.
4. Refuse when unsure.
5. One engine behind every front end; only the engine deletes.
6. Rules are data.

## Functional requirements

| ID | Requirement | Milestone | Accepted when |
| --- | --- | --- | --- |
| F1 | Validate rule files | M0 (done) | `rules-check` passes bundled rules and rejects every case in the linter tests |
| F2 | Report what the guard would allow in a project | M0 (done) | `plan` lists matches with allow or refuse and a reason; changes nothing |
| F3 | Clean to quarantine with a manifest; restore a run or an item; purge to free space | M1 (done) | Round-trip test restores byte-identical trees; restore never overwrites |
| F4 | Dry run is the default; a clean needs an explicit flag | M1 (done) | No path changes without the flag, proven by test |
| F5 | Discover projects under chosen roots, streaming results | M2 | Finds every fixture project, including nested workspaces; reports skipped and unreadable folders |
| F6 | Rule catalogue for Node.js, Rust, Python, Xcode, Android, Flutter, PHP, Go, .NET, Java, Swift packages | M2 | Each rule has must-match and must-not-match fixtures |
| F7 | Idle or active verdict with reasons: last commit, last source edit, processes with a working directory in the project | M2 | Reasons shown for every project; pinned projects never offered |
| F8 | Accurate sizes: shared blocks counted once, estimates labelled | M2 | Hard-link and clone fixtures report expected totals |
| F9 | JSON output for every command | M2 | Schema documented (`docs/CLI-JSON.md`); snapshot tests |
| F10 | Mac app drives the Rust engine for scan, plan, clean, restore | M3 | No Swift code path moves or deletes; enforced by a CI check |
| F11 | Remove out-of-scope inherited modules: malware list, uninstaller, fan and sensor control, speed test, system junk | M3 | Modules and their UI are gone; app builds |
| F12 | Run on macOS 14 or later | M3 | App launches and passes UI tests on macOS 14 |
| F13 | Overview, Projects, Project detail, Review sheet, History, Settings, menu bar | M3–M4 | Usability pass with five developers |
| F14 | Per-folder selection; Caution never pre-selected | M3 | UI test |
| F15 | Global caches cleaned through each tool's own command; installed toolchains listed separately and review-only | M4 | Cellar, nvm and global packages never appear as cache |
| F16 | Signed, notarized, self-updating build; Homebrew cask | M4 | Clean install on a fresh Mac |
| F17 | Scheduled automatic clean under a policy | M5 | Safe class only; size cap; notification with undo |
| F18 | Docker, simulators and local model stores as review-only categories | M5 | Never pre-selected |
| F19 | Local stats, milestones and an original character; can be turned off | M5 | No network use; Reduce Motion respected |
| F20 | User rules and a per-repository config file | M5 | User rules pass the same linter |

## Non-functional requirements

| ID | Requirement |
| --- | --- |
| N1 | Safety invariants in `SAFETY-SPEC.md` hold on every code path |
| N2 | No network code outside the updater; CI fails if a new network dependency appears in the engine |
| N3 | Engine: no `unsafe`, no `unwrap`/`expect`/`panic` outside tests; clippy clean |
| N4 | First results within 2 seconds of starting a scan (target, to validate) |
| N5 | Full keyboard navigation and VoiceOver labels; colour is never the only signal |
| N6 | Works without Full Disk Access; says what it could not read |
| N7 | Reproducible release builds with an SBOM and build attestation |

## Non-goals for v1

General system cleaning, malware scanning, app uninstalling, hardware
monitoring, accounts, cloud sync, a public leaderboard, a Windows app, and
permanent deletion as a default.

## Open items

- Bundle identifier: `com.finjineers.opensweep` (done).
- App icon: done (owner supplied, `docs/assets/icon-source.png`). Character
  art: the Open Peeps stay.
- Trademark and name check for "OpenSweep" before launch.
