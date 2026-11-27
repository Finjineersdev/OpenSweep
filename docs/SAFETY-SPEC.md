# Safety specification

The one failure OpenSweep cannot recover its reputation from is removing
something that cannot be rebuilt. This document states the invariants that
prevent it. Each invariant names the code that enforces it and the test that
proves it. A change that weakens an invariant needs an ADR.

Status: **I1–I15c and I18–I22 are implemented and tested** in `engine/crates/opensweep-core`.
I16 and I17 are specified and not implemented yet.

## Model

```
rule file ──lint──▶ RuleFile ──marker present──▶ Candidate ──Guard::check──▶ Approved ──reverify──▶ move
```

`Candidate` and `Approved` have private fields. Outside the engine crate there
is no way to construct either, so code that moves a path must have gone
through a linted rule and the guard. There is no free-form delete.

## Invariants in force

| # | Invariant | Enforced by | Refusal |
| --- | --- | --- | --- |
| I1 | A path is a candidate only if a linted rule names it, it exists, the rule's marker (file, folder or one-`*` name, never through a link) is directly in the project root, no `exclude_if` condition holds, and the artifact's `requires` evidence holds | `RuleFile::detects`, `RuleFile::candidates` | (no candidate) |
| I2 | Rule paths are plain relative paths: no `.`, `..`, root, wildcard, expansion, or more than 4 components | `rules::lint_artifact_path` | lint error |
| I2a | Rule markers are plain names and globs have exactly one `*` in a single component. Evidence paths obey I2 and never name a protected file. Evidence counts only as a regular file whose real path is the written path inside the project, read at most 1 MB; anything unreadable is no evidence | `rules::lint_name`, `lint_glob`, `lint_evidence`, `evidence_file` | lint error, or (no candidate) |
| I3 | The candidate, joined to the root, resolves strictly inside the root and is not the root | `Guard::check` | `OutsideProject`, `IsProjectRoot` |
| I4 | The target is a real directory: not a symlink, not a file | `Guard::check` | `Symlink`, `NotADirectory` |
| I5 | No symlink sits between the root and the target, even one pointing inside the project | `Guard::check` | `SymlinkInPath` |
| I6 | The project root is not `/`, a top-level folder, the home folder, or an ancestor of the home folder | `Guard::check` | `ProjectRootTooBroad` |
| I7 | No component is a VCS directory, credential store, env file, key or signing file, or lockfile | `deny::protected_component` | `Protected` |
| I8 | The final component is not a conventional source name (`src`, `lib`, `app`, `tests`, …) | `deny::protected_target` | `Protected` |
| I9 | The target is on the same volume as the project root | `Guard::check` | `CrossDevice` |
| I10 | The target does not contain its own repository | `Guard::check` | `ContainsRepository` |
| I11 | Git tracks nothing under the target; if the project is a repository and git cannot answer, refuse | `guard::check_untracked` | `ContainsTrackedFiles`, `VcsCheckFailed` |
| I12 | Immediately before a move, the directory is the same one that was approved (device, inode, creation time, canonical path). The move itself opens the parent once, checks the entry under that handle is still the approved device and inode, and renames from that handle without replacing anything, so a folder on the way swapped for a link after the check cannot redirect it | `Approved::reverify`, `Approved::move_into` | `ChangedSinceApproval`, `a_swap_after_reverify_cannot_redirect_the_move` |

### Notes on I11

The repository being inspected is untrusted input. A repository's own
configuration can name programs for git to run, so the guard calls git with
`core.fsmonitor=false` and `core.hooksPath=/dev/null`, clears `GIT_DIR` and
`GIT_WORK_TREE`, and never passes a path through a shell. A partial clone
would fetch missing objects from a remote the repository names, over a
transport it chooses (`ext::` runs a command), so git also runs with
`GIT_NO_LAZY_FETCH=1` (git 2.45 and later) and an empty `GIT_ALLOW_PROTOCOL`,
which allows no transport and overrides the repository's own
`protocol.<name>.allow`.
`git_check_does_not_run_repository_programs` proves the fsmonitor case.
git itself, and the tools that clear caches, are found only through absolute
`PATH` folders: an empty or `.` entry would find a repository's own `git` when
OpenSweep runs from inside it (`relative_path_entries_are_ignored`).

### Known limits

- I12 relies on creation time to tell a recreated directory from the original
  when the inode number is reused. On a file system that records no creation
  time, a delete-and-recreate between check and move is not detected. The M1
  move is a rename into quarantine, so the cost of that race is a restorable
  quarantine entry, not data loss.
- Matching is by name. A user who keeps real work in a folder called
  `node_modules` outside version control is not protected by I7–I11. Quarantine
  and restore (I13, I14) are the backstop.
- Only git is checked for tracked files. Mercurial, Jujutsu and Subversion
  checkouts are refused only at the directory level (I7).
- Between the handle check and the rename, only something with write access
  to the project folder itself could swap the entry, and it could delete the
  folder anyway. Handles come from `rustix`, a safe wrapper, because the
  engine forbids `unsafe`.

## Quarantine (M1)

| # | Invariant | Enforced by | Test |
| --- | --- | --- | --- |
| I13 | Cleaning moves each approved folder by rename into a quarantine on its own drive: the main store, or `.opensweep-quarantine` at the top of another local drive (ADR 0004); nothing is copied or unlinked at clean time. A folder on a network drive, or a drive whose type is unknown, is skipped and recorded | `Store::clean`, `volumes::unusable` | `clean_then_restore_round_trips_exactly`, `folders_on_another_drive_use_that_drives_quarantine`, `only_known_local_drives_are_usable` |
| I14 | The manifest is written before the first move and rewritten atomically after each one; `reverify` runs immediately before each move | `Store::clean`, `write_manifest` | `changed_items_are_skipped_and_recorded`, `a_crash_after_a_move_is_recoverable` |
| I14a | Restore never overwrites and never recreates a missing project folder | `Store::restore` | `restore_never_overwrites`, `restore_refuses_when_the_project_is_gone` |
| I14b | Purge deletes only real directories at `items/<digits>` inside the store; run ids and item names from disk are validated; a malformed manifest stops the command | `Store::purge`, `parse_manifest` | `purge_deletes_only_quarantined_items`, `purge_removes_only_real_directories`, `tampered_manifests_are_refused`, `run_ids_cannot_escape_the_store` |
| I14d | Restore puts an item back only inside the project it came from: the manifest's original must be an absolute, normalized path strictly below its project root, and the parent folder's real path must still be the recorded one (no folder on the way replaced by a link), checked on the open handle the rename goes into. The rename never replaces anything, an empty folder included | `parse_manifest`, `Store::restore` | `manifests_cannot_send_items_outside_their_project`, `restore_does_not_follow_a_replaced_parent`, `a_restore_rename_never_replaces_or_follows` |
| I19 | The main store and its `runs` folder must be real folders owned by the owner of the home folder and writable by no one else; store, run and item folders are created owner-only (0700), and a run or its `items` folder that is a link is never followed. A drive quarantine is used only if each of its folders is a real folder owned by the main store's owner and writable by no one else, at the top of a local drive whose top folder others cannot change (or has the sticky bit), checked before every clean, restore and purge; a manifest's `volume` must be an absolute `.opensweep-quarantine` folder whose parent contains the item's original | `quarantine::trusted`, `items_of`, `parse_manifest` | `a_drive_quarantine_must_be_a_private_folder_of_the_owner`, `a_shared_drive_top_needs_the_sticky_bit`, `manifests_cannot_point_at_another_drives_quarantine`, `folders_on_another_drive_use_that_drives_quarantine`, `a_store_others_can_change_is_refused`, `a_linked_items_folder_is_not_followed` |
| I14c | Every changing CLI command is a dry run without `--execute`; Caution folders also need `--include-caution`. `pin` and `unpin` are the exception: they change only OpenSweep's config, and pinning only adds protection. `clean --only` can only narrow: a pick the rules do not offer is an error before anything moves, and every pick still passes the guard | `opensweep-cli` | `clean_is_a_dry_run_by_default`, `caution_folders_need_an_explicit_flag`, `only_narrows_the_selection` |

Space is freed only when a run is purged, because a rename on the same volume
moves no data. The CLI says so after every clean.

Known limits: a crash between a rename and the manifest update leaves the entry
`pending`; restore and purge treat it as moved if its item is present. Two cleans running at the same moment use separate run folders
but are not otherwise coordinated.

## Discovery (M2)

Discovery only reads; what it finds still passes I1–I12 before anything moves.

| # | Invariant | Enforced by | Test |
| --- | --- | --- | --- |
| I18 | The project walk never follows a link, never enters another volume, the quarantine store, a bundle, a hidden folder, an artifact folder of a project it found, installed software (I21), or a folder that belongs to its parent's project (Flutter's `android/`). A candidate is reported once, by the outermost project that claims it. A whole-disk scan is one walk per top folder of the data volume, and other drives are separate roots (local and writable only, never network or Time Machine), so it never crosses a volume either | `discover::discover`, `discover::whole_disk_roots`, `volumes::other_drives` | `links_are_never_followed`, `other_volumes_are_not_entered`, `the_quarantine_store_is_not_entered`, `bundles_and_hidden_folders_are_not_entered`, `finds_every_project_in_a_layout_like_the_owners`, `installed_software_is_not_walked`, `whole_disk_roots_are_the_top_folders_on_the_data_volume`, `other_drives_are_local_writable_and_not_backups` |

## Activity and pins (M2.5)

`Guard::check` takes an `Activity`, which only `activity::assess` can make, so
nothing is approved without an activity assessment.

| # | Invariant | Enforced by | Test |
| --- | --- | --- | --- |
| I15 | A pinned project, or one inside a pinned folder, is refused with no override. A pin can carry an end time (`pinned_until`), after which the project is judged as usual; a pinned git remote (`pinned_remotes`) pins every clone of that repository, read from `.git/config` as text without running git, so a repository can only pin itself. A folder a repository keeps (`exclude`) also keeps any artifact that contains it, compared ignoring case. A commit time git reports that no clock can hold is an error, never a crash (`a_commit_time_out_of_range_does_not_crash`). An Active project (a process other than OpenSweep's own process family and pipeline runs inside it, or a file or commit is newer than `idle_days`) is refused unless the guard is built with `allow_active` (`--include-active`) | `Guard::check`, `activity::assess` | `active_and_pinned_projects_are_refused`, `pinned_projects_are_never_cleaned`, `a_pin_until_a_date_ends`, `a_repository_file_can_only_take_folders_away`, `folders_kept_by_the_repository_are_refused`, `user_rules_and_repository_files`, `user_rules_add_to_the_catalogue`, `a_pin_on_a_git_remote_follows_the_project`, `old_config_files_still_load`, `projects_in_use_need_an_explicit_flag`, `a_tool_running_inside_makes_it_active` |
| I15a | Dormant needs every signal checked in full: git answered, the edit walk finished within its limits, and processes were listed. Otherwise the verdict is at most Idle | `activity::decide` | `an_incomplete_check_is_never_dormant`, `too_many_files_is_never_dormant`, `a_broken_repository_is_never_dormant` |
| I15b | Reading the last commit runs git with the I11 settings plus `log.showSignature=false`, so a repository cannot make it run `gpg.program` or fetch from its own remote | `guard::hardened_git` | `reading_commits_does_not_run_repository_programs`, `reading_commits_does_not_fetch_from_the_repositorys_remote` |
| I15c | A config file that exists but cannot be read, has an unknown key, a relative pin, or `idle_days` above `dormant_days` stops `plan` and `clean`: pins are never silently dropped | `Config::load` | `config_is_read_strictly`, `a_broken_config_stops_cleaning` |

Known limit: activity is assessed once, before approval. A tool started in
the seconds between the plan and the move is not seen.

## Global caches (M4, ADR 0006)

| # | Invariant | Enforced in | Tests |
| --- | --- | --- | --- |
| I20 | A global cache is cleared only by its tool's own command, with a fixed argument list, no shell, stdin closed, the home folder as working folder and a time limit, and only with `--execute`. At the limit the tool's whole process group is stopped, so a helper it started cannot keep running or hold the engine. No cache path is inside or above a toolchain folder or the home folder | `caches::known`, `caches::allowed`, `caches::run` | `toolchains_never_appear_as_caches`, `the_home_folder_and_its_parents_are_never_a_cache`, `cleaning_runs_the_tools_own_command`, `a_failing_or_hanging_tool_is_reported`, `a_hanging_tool_is_stopped_with_its_helpers`, `caches_are_cleared_by_the_tools_own_command`, `xcode_archives_and_simulators_are_measured_only`, `simulators_are_cleared_only_of_unavailable_ones`, `editor_browser_docker_and_model_stores_are_measured_only` |
| I21 | A project inside installed software is never cleaned: its root has a `node_modules`, `site-packages`, `dist-packages` or `Cellar` folder above it, or lies under Homebrew, MacPorts, Nix, `/Applications`, `/Library`, `/System`, `/usr`, or a toolchain folder in the home folder (`.nvm`, `.rustup`, `.cargo`, `go/pkg`, `Library/Caches` and the like). Removing its folders breaks the tool; it does not rebuild | `guard::installed_software`, `Guard::check` | `installed_packages_are_never_cleaned`, `package_manager_and_toolchain_folders_are_installed_software` |

## Rename (November 2026)

| # | Invariant | Enforced in | Tests |
| --- | --- | --- | --- |
| I22 | The old `AgentClean` (or `agentclean`) data folder is adopted only by renaming it whole to `OpenSweep` (`opensweep`), only when the new folder does not exist, and never through a symbolic link; nothing is copied or merged. Manifests keep items relative to the store, so restore still works | `quarantine::adopt_legacy`, called by `default_location` and `default_config_path` | `the_agentclean_folder_is_adopted_once_and_never_merged` |

## Specified, not implemented

| # | Invariant |
| --- | --- |
| I16 | Automatic cleaning takes Safe-class candidates only, from projects idle past the threshold, under a per-run size cap |
| I17 | No `sudo`, no privileged helper; external tools run with fixed argument lists |

## Test obligations

- Every rule has match and nomatch fixtures (`docs/RULE-SCHEMA.md`);
  `rule_fixtures_produce_the_expected_candidates` checks them.

- Every invariant has at least one test that fails if the check is removed.
- `approval_implies_invariants` (property test) asserts I3, I4, I7 and I8 for
  arbitrary paths.
- Fuzz targets in `engine/fuzz/`: `rules_parse` asserts that any accepted rule
  satisfies I2, I2a and I8; `manifest_load` asserts that any accepted manifest
  satisfies I14b and I14d and survives a write and re-read unchanged. Both run
  nightly for 10 minutes each (`engine-nightly` workflow).
- `cargo mutants` on `guard.rs`, `deny.rs`, `quarantine.rs`, `rules.rs`, `discover.rs` and `activity.rs` must report no
  surviving mutants; it runs nightly and the command is in `CONTRIBUTING.md`.
  Code that only one platform compiles is kept inside a shared function, so
  the tests that run cover the code that ships.
