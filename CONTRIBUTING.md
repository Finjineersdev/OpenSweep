# Contributing to OpenSweep

Thanks for looking under the hood. This is a tool that deletes files, so the bar for changes that touch scanning or cleaning is higher than for UI work. Read the safety section before anything else.

## Ground rules

- **Only the Rust engine moves or deletes files** (ADR 0002). The app runs the
  bundled `opensweep` binary and reads its `--json` output (ADR 0005).
  `scripts/check-swift-never-deletes.sh` fails CI if app code calls a file
  removal or move API.
- **Quarantine, never delete, at clean time.** Space comes back on purge.
- **Never hardcode a user's paths.** Projects are found by the engine's rule
  files; tools in Dev Stack are found from their own conventions.
- **Caution is never pre-selected.** Safe folders in projects not in use are
  the only ones ticked for the user.
- **Honest sizes.** Allocated blocks, hard links counted once.

## Setup

```bash
git clone https://github.com/Finjineersdev/OpenSweep.git
cd OpenSweep
(cd engine && cargo build)            # the Swift end-to-end tests use this binary
(cd CleanCore && swift test)
xcodebuild -project OpenSweep.xcodeproj -scheme OpenSweep -configuration Debug \
  -derivedDataPath build/dd build CODE_SIGN_IDENTITY=-   # builds and embeds the engine
```

Xcode 16 or later; macOS 14 or later to run. The app finds its engine at
`Contents/Helpers/opensweep`; in Debug builds, set `OPENSWEEP_BIN` to use another binary
while developing.

## Layout

```
engine/                Rust workspace: rules, safety guard, quarantine, CLI (the only deleter)
CleanCore/
  Sources/AgentEngine  Swift client for the engine CLI, selection rules
  Sources/CleanCore    Read-only Dev Stack inventory
OpenSweep/            SwiftUI app: AppModel, Overview, Projects, History, Dev Stack, Settings
OpenSweepUITests/     XCUITest suite against throwaway projects
```

## Pull requests

- One focused change per PR. For anything that changes what can be cleaned,
  explain why that is safe.
- Engine checks (below), `cd CleanCore && swift test` and
  `scripts/check-swift-never-deletes.sh` must pass. Run the relevant rows of
  `QA-CHECKLIST.md` and say which ones.
- Screenshots for UI changes.

## Reporting a bug that moved something it shouldn't have

Use private vulnerability reporting (see `SECURITY.md`) with the output of
`opensweep history --json` for the run. Restore it first:
`opensweep restore <run>`, or History in the app.

## Engine (Rust)

The engine in `engine/` is the only code allowed to move or delete files. Read
`docs/SAFETY-SPEC.md` before changing `guard.rs`, `deny.rs` or `rules.rs`; a
change there needs a test that fails without it.

```bash
cd engine
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
cargo test
cargo run -p opensweep-cli -- rules-check rules
```

The `engine-nightly` workflow also runs two slower checks. Before you merge a
change to `guard.rs`, `deny.rs`, `quarantine.rs` or `rules.rs`, run them locally.
Mutation testing must report no surviving ("missed") mutants:

```bash
cargo install --locked cargo-mutants cargo-fuzz
cd engine
cargo mutants -p opensweep-core --test-workspace=true \
  -f crates/opensweep-core/src/guard.rs \
  -f crates/opensweep-core/src/deny.rs \
  -f crates/opensweep-core/src/quarantine.rs \
  -f crates/opensweep-core/src/rules.rs \
  -f crates/opensweep-core/src/discover.rs \
  -f crates/opensweep-core/src/activity.rs
```

Fuzzing needs the nightly toolchain (`rustup toolchain install nightly`). The
targets are `rules_parse` and `manifest_load`:

```bash
cd engine/fuzz
cargo +nightly fuzz run rules_parse corpus/rules_parse seeds/rules_parse -- -max_total_time=600
```

Rule files are covered by `docs/RULE-SCHEMA.md`. New work is contributed under
the MIT License.
