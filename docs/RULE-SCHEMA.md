# Rule schema (version 2)

One TOML file per ecosystem in `engine/rules/`. Rules are written from each
tool's own documentation. A rule is a claim that a path is rebuildable; the
safety guard still decides whether a given directory may be cleaned.

```toml
schema = 2
id = "node"                 # lowercase letters, digits, '-'; unique
name = "Node.js"            # shown to the user

[detect]                    # the project root needs at least one marker
any_files = ["package.json"]   # plain file names
any_glob  = []                 # names with one '*': "*.csproj", "*.xcodeproj"
any_dirs  = []                 # plain folder names
# Not a project of its own when the parent folder holds one of these files,
# e.g. Flutter's android/ beside pubspec.yaml:
# exclude_if = { parent_any_files = ["pubspec.yaml"] }

[[artifact]]
path = "node_modules"       # relative to the project root
class = "caution"           # "safe" or "caution"
reason = "Installed dependencies. Reinstall from the lockfile."
restore = "npm install (or pnpm install / yarn install)"

[[artifact]]
path = "dist"
class = "safe"
reason = "Build output written by the project's build script."
restore = "npm run build"
# Evidence this path needs before it is a candidate:
requires = { json = { file = "package.json", key = "scripts.build" } }
```

## Detection

A folder is a project for a rule when it directly holds any one marker: a
file named in `any_files`, a folder named in `any_dirs`, or a file or folder
matching an `any_glob` pattern. Markers are never followed through symbolic
links. If `exclude_if` is given and the parent folder holds one of its files,
the folder is not a project for that rule.

## Evidence (`requires`)

Generic names such as `build`, `dist`, `bin` and `vendor` are only safe in
the right stack. `requires` makes an artifact a candidate only when evidence
exists. Every condition given must hold; within a list, one match is enough.

| Field | Holds when |
| --- | --- |
| `any_files` | one of these paths, relative to the project root, is a regular file |
| `any_glob` | a file or folder directly in the project root matches one of these one-`*` names |
| `inside` | one of these plain file names is a regular file inside the artifact folder (`venv` with `pyvenv.cfg`) |
| `json` | `file` (relative to the project root) is valid JSON, at most 1 MB, and has the dotted `key` (`scripts.build`) |

Evidence files must be regular files whose real location is the path written
in the rule, inside the project: a linked file, or a linked folder on the way,
does not count. Anything unreadable counts as "no evidence".

A candidate is also only offered when its path exists, and only once when
two rules name the same folder.

## Classes

| Class | Meaning | Pre-selected in the app | Automatic clean |
| --- | --- | --- | --- |
| `safe` | The next build recreates it with no user action | Yes | Allowed |
| `caution` | Needs a reinstall or download first | No | Never |

There is no "forbidden" class in rule files: protected names are built into
the engine and a rule that names one does not load.

## What the linter rejects

- Unknown fields, or a `schema` other than 1 or 2.
- In a schema 1 file: `any_glob`, `any_dirs`, `exclude_if` or `requires`.
- A rule with no markers at all. A marker or `exclude_if` name that is empty,
  `.`, `..`, padded with spaces, or contains a separator, wildcard, `~` or `$`.
- A glob without exactly one `*`, a glob that is only `*`, or a glob with a
  path separator or any other wildcard.
- An artifact path that is empty, absolute, contains `.` or `..` (or an empty
  segment), a backslash, a wildcard (`* ? [ ] { }`), `~` or `$`, ends in `/`,
  or has more than four components.
- An artifact path with a protected component (`.git`, `.env*`, keys,
  lockfiles) or whose last component is a source name (`src`, `lib`, `app`).
- Evidence paths held to the same rules, and never naming a protected file:
  OpenSweep does not read keys, env files or lockfiles as evidence. A
  `requires` with no conditions, or a `json.key` with an empty segment.
- A duplicate artifact path in one file, or a duplicate `id` across files.
- A missing `reason` or `restore`.

## Fixtures

Every rule has small project trees under `engine/rules/fixtures/<id>/`:

- `match/<case>/`: a project the rule detects, with `expected.txt` listing the
  candidate paths it must produce, one per line, and nothing else.
- `nomatch/<case>/`: a tree where the rule must produce no candidates.

`rule_fixtures_produce_the_expected_candidates` fails if a rule has no
fixtures of either kind, or a fixture folder has no rule. Empty folders need a
`.keep` file so git keeps them; `fixtures/.gitignore` re-includes everything,
so files like `dist/` or `node_modules/` are never dropped by other ignore
rules.

## Contributing a rule

1. Add or edit a file in `engine/rules/`, with match and nomatch fixtures.
   A new file also goes in `BUNDLED` in `opensweep-core/src/rules.rs`, which
   builds the catalogue into the binary.
2. Run `cargo run -p opensweep-cli -- rules-check rules` and `cargo test`.
3. In the pull request, link the tool's documentation that says the path is
   generated. Rule changes need two reviewers.

Tool-native cleanup commands (`go clean`, `dotnet clean`) belong to global
caches in M4, not to this schema.

## Your own rules

Put rule files in `rules/` beside `config.toml`
(`~/Library/Application Support/OpenSweep/rules` on macOS,
`~/.config/opensweep/rules` elsewhere). They are linted exactly like the
catalogue and may add rules but not reuse a built-in `id`; a file that fails
the linter stops `scan`, `plan` and `clean` with the reason. Check them with
`opensweep rules-check <that folder>`. The safety guard still decides every
folder.

## A repository's own file

A project may carry `.opensweep.toml`, which can only take folders away:

```toml
pin = true                      # never clean this project
exclude = ["dist", "data/cache"] # never clean these folders (relative)
```

Scanned repositories are hostile input, so it cannot add folders, and a file
with any other key, an absolute or `..` path, or that is not a small plain
file pins the whole project.
