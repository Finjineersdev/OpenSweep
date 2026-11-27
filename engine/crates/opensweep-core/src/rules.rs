//! The rule catalogue: one TOML file per ecosystem.
//!
//! A rule file says how to recognise a project and which paths under its root
//! are rebuildable. Rules are data, reviewed like code, and linted here so a
//! bad rule fails CI instead of deleting someone's work.
//! The format is specified in `docs/RULE-SCHEMA.md`.

use std::collections::BTreeSet;
use std::path::{Component, Path, PathBuf};

use serde::Deserialize;

use crate::deny::{protected_component, protected_target};

/// Newest schema. Schema 1 files still load; the schema 2 fields are
/// rejected in them.
pub const SCHEMA_VERSION: u32 = 2;

/// Evidence files read for `requires.json` larger than this are ignored.
const MAX_EVIDENCE_BYTES: u64 = 1_000_000;

/// Entries of a project root looked at when matching globs.
// ponytail: fixed cap; a root with more entries than this never matches a glob.
const MAX_ROOT_ENTRIES: usize = 10_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Class {
    /// Recreated by the next build with no user action.
    Safe,
    /// Needs a reinstall or download before the project works again.
    Caution,
}

/// How a project is recognised. The root matches if it holds any one marker
/// and no `exclude_if` condition holds.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Detect {
    /// Plain file names, e.g. `package.json`.
    #[serde(default)]
    pub any_files: Vec<String>,
    /// Schema 2: names with one `*`, e.g. `*.csproj`; matches files or folders.
    #[serde(default)]
    pub any_glob: Vec<String>,
    /// Schema 2: plain folder names.
    #[serde(default)]
    pub any_dirs: Vec<String>,
    /// Schema 2: conditions that make the root part of another project.
    #[serde(default)]
    pub exclude_if: Option<ExcludeIf>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExcludeIf {
    /// Not a project of its own if the parent folder holds one of these files
    /// (Flutter's `android/` beside `pubspec.yaml`).
    #[serde(default)]
    pub parent_any_files: Vec<String>,
}

/// Schema 2: evidence an artifact needs before it is a candidate. Every
/// condition given must hold; within a list, one match is enough.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Requires {
    /// Files relative to the project root.
    #[serde(default)]
    pub any_files: Vec<String>,
    /// One-`*` names matched in the project root.
    #[serde(default)]
    pub any_glob: Vec<String>,
    /// Plain file names inside the artifact folder (`pyvenv.cfg` in `venv`).
    #[serde(default)]
    pub inside: Vec<String>,
    /// A JSON file in the project whose dotted key must exist.
    #[serde(default)]
    pub json: Option<JsonKey>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JsonKey {
    /// Path relative to the project root, e.g. `package.json`.
    pub file: String,
    /// Dotted object path, e.g. `scripts.build`.
    pub key: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Artifact {
    /// Path relative to the project root.
    pub path: String,
    pub class: Class,
    /// Shown to the user: what this is and why removing it is recoverable.
    pub reason: String,
    /// Shown to the user: how to get it back.
    pub restore: String,
    /// Schema 2: evidence that must exist for this path to be a candidate.
    #[serde(default)]
    pub requires: Option<Requires>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RuleFile {
    pub schema: u32,
    pub id: String,
    pub name: String,
    pub detect: Detect,
    #[serde(rename = "artifact")]
    pub artifacts: Vec<Artifact>,
}

/// A path a rule says may be rebuildable in one project. The only way to
/// obtain one is from a linted [`RuleFile`] whose marker file is present, and
/// the safety guard accepts nothing else: there is no free-form delete.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    rule_id: String,
    rel: PathBuf,
    class: Class,
}

impl Candidate {
    pub fn rule_id(&self) -> &str {
        &self.rule_id
    }

    /// Path relative to the project root.
    pub fn rel(&self) -> &Path {
        &self.rel
    }

    pub fn class(&self) -> Class {
        self.class
    }

    #[cfg(test)]
    pub(crate) fn unchecked(rel: &str) -> Self {
        Self {
            rule_id: "test".to_owned(),
            rel: PathBuf::from(rel),
            class: Class::Safe,
        }
    }
}

impl RuleFile {
    /// True if `project_root` holds one of this rule's markers and is not
    /// excluded. Markers are never followed through symbolic links.
    pub fn detects(&self, project_root: &Path) -> bool {
        self.marked(project_root) && !self.excluded(project_root)
    }

    /// True if `dir` holds a marker but `exclude_if` makes it part of the
    /// parent's project (Flutter's `android/`). Discovery does not enter it.
    pub fn defers_to_parent(&self, dir: &Path) -> bool {
        self.marked(dir) && self.excluded(dir)
    }

    fn marked(&self, dir: &Path) -> bool {
        let d = &self.detect;
        d.any_files.iter().any(|m| is_file(&dir.join(m)))
            || d.any_dirs.iter().any(|m| is_dir(&dir.join(m)))
            || glob_matches(dir, &d.any_glob)
    }

    fn excluded(&self, dir: &Path) -> bool {
        self.detect.exclude_if.as_ref().is_some_and(|x| {
            dir.parent()
                .is_some_and(|parent| x.parent_any_files.iter().any(|m| is_file(&parent.join(m))))
        })
    }

    /// Candidates for `project_root`: artifacts that exist and whose evidence
    /// holds, or none if the rule does not detect the project. A candidate is
    /// a claim by a rule, not permission: the guard decides.
    pub fn candidates(&self, project_root: &Path) -> Vec<Candidate> {
        if !self.detects(project_root) {
            return Vec::new();
        }
        self.artifacts
            .iter()
            .filter(|a| std::fs::symlink_metadata(project_root.join(&a.path)).is_ok())
            .filter(|a| {
                a.requires
                    .as_ref()
                    .map_or(true, |r| evidence_holds(project_root, &a.path, r))
            })
            .map(|a| Candidate {
                rule_id: self.id.clone(),
                rel: PathBuf::from(&a.path),
                class: a.class,
            })
            .collect()
    }
}

fn is_file(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok_and(|m| m.is_file())
}

fn is_dir(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok_and(|m| m.is_dir())
}

/// `name` matches a one-`*` pattern such as `*.csproj`. The linter
/// guarantees the `*`; a pattern without one matches nothing.
fn glob_match(pattern: &str, name: &str) -> bool {
    let Some((pre, post)) = pattern.split_once('*') else {
        return false;
    };
    name.len() >= pre.len() + post.len() && name.starts_with(pre) && name.ends_with(post)
}

/// True if a real file or folder (not a link) directly in `dir` matches one
/// of `patterns`. Any read error, or too many entries, is no match.
fn glob_matches(dir: &Path, patterns: &[String]) -> bool {
    if patterns.is_empty() {
        return false;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return false;
    };
    for entry in entries.take(MAX_ROOT_ENTRIES) {
        let Ok(entry) = entry else { return false };
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        if kind.is_symlink() {
            continue;
        }
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if patterns.iter().any(|p| glob_match(p, name)) {
            return true;
        }
    }
    false
}

/// A regular file at `rel` below `root` whose real location is inside the
/// project: a linked file or a linked folder on the way does not count.
fn evidence_file(root: &Path, rel: &str) -> Option<PathBuf> {
    let path = root.join(rel);
    if !is_file(&path) {
        return None;
    }
    let real = std::fs::canonicalize(&path).ok()?;
    let real_root = std::fs::canonicalize(root).ok()?;
    (real.starts_with(&real_root) && real.ends_with(rel)).then_some(path)
}

fn evidence_holds(root: &Path, artifact: &str, r: &Requires) -> bool {
    let files =
        r.any_files.is_empty() || r.any_files.iter().any(|f| evidence_file(root, f).is_some());
    let globs = r.any_glob.is_empty() || glob_matches(root, &r.any_glob);
    let inside = r.inside.is_empty()
        || r.inside
            .iter()
            .any(|f| evidence_file(root, &format!("{artifact}/{f}")).is_some());
    let json = r.json.as_ref().map_or(true, |j| json_has_key(root, j));
    files && globs && inside && json
}

/// Reads at most [`MAX_EVIDENCE_BYTES`] of a project JSON file and checks
/// that the dotted key exists. Anything unreadable is "no".
fn json_has_key(root: &Path, j: &JsonKey) -> bool {
    let Some(path) = evidence_file(root, &j.file) else {
        return false;
    };
    let Ok(meta) = std::fs::metadata(&path) else {
        return false;
    };
    if meta.len() > MAX_EVIDENCE_BYTES {
        return false;
    }
    let Ok(text) = std::fs::read_to_string(&path) else {
        return false;
    };
    let Ok(mut value) = serde_json::from_str::<serde_json::Value>(&text) else {
        return false;
    };
    for part in j.key.split('.') {
        match value.get_mut(part) {
            Some(v) => value = v.take(),
            None => return false,
        }
    }
    true
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum RuleError {
    #[error("{file}: {message}")]
    Parse { file: String, message: String },
    #[error("{file}: unsupported schema {found}, expected 1 to {SCHEMA_VERSION}")]
    Schema { file: String, found: u32 },
    #[error("{file}: {message}")]
    Lint { file: String, message: String },
    #[error("{file}: cannot read: {message}")]
    Io { file: String, message: String },
}

/// Parses and lints one rule file. `file` is used in messages only.
pub fn parse(file: &str, text: &str) -> Result<RuleFile, RuleError> {
    let rule: RuleFile = toml::from_str(text).map_err(|e| RuleError::Parse {
        file: file.to_owned(),
        message: e.message().to_owned(),
    })?;
    if !(1..=SCHEMA_VERSION).contains(&rule.schema) {
        return Err(RuleError::Schema {
            file: file.to_owned(),
            found: rule.schema,
        });
    }
    lint(file, &rule)?;
    Ok(rule)
}

fn lint_err(file: &str, message: String) -> RuleError {
    RuleError::Lint {
        file: file.to_owned(),
        message,
    }
}

fn lint(file: &str, rule: &RuleFile) -> Result<(), RuleError> {
    let id_ok = !rule.id.is_empty()
        && rule
            .id
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-');
    if !id_ok {
        return Err(lint_err(
            file,
            format!("id {:?} must be lowercase letters, digits and '-'", rule.id),
        ));
    }
    if rule.name.trim().is_empty() {
        return Err(lint_err(file, "name is empty".to_owned()));
    }
    let d = &rule.detect;
    if rule.schema == 1 {
        let v2_detect = !d.any_glob.is_empty() || !d.any_dirs.is_empty() || d.exclude_if.is_some();
        if v2_detect || rule.artifacts.iter().any(|a| a.requires.is_some()) {
            return Err(lint_err(
                file,
                "any_glob, any_dirs, exclude_if and requires need schema = 2".to_owned(),
            ));
        }
    }
    if d.any_files.is_empty() && d.any_glob.is_empty() && d.any_dirs.is_empty() {
        return Err(lint_err(
            file,
            "detect has no markers: a rule must require a marker".to_owned(),
        ));
    }
    for marker in d.any_files.iter().chain(&d.any_dirs) {
        lint_name(file, "marker", marker)?;
    }
    for pattern in &d.any_glob {
        lint_glob(file, pattern)?;
    }
    if let Some(x) = &d.exclude_if {
        if x.parent_any_files.is_empty() {
            return Err(lint_err(file, "exclude_if has no conditions".to_owned()));
        }
        for marker in &x.parent_any_files {
            lint_name(file, "exclude_if marker", marker)?;
        }
    }
    if rule.artifacts.is_empty() {
        return Err(lint_err(file, "no [[artifact]] entries".to_owned()));
    }
    let mut seen = BTreeSet::new();
    for a in &rule.artifacts {
        lint_artifact_path(file, &a.path)?;
        if !seen.insert(a.path.to_lowercase()) {
            return Err(lint_err(
                file,
                format!("artifact {:?} listed twice", a.path),
            ));
        }
        if a.reason.trim().is_empty() || a.restore.trim().is_empty() {
            return Err(lint_err(
                file,
                format!("artifact {:?} needs a reason and a restore hint", a.path),
            ));
        }
        if let Some(r) = &a.requires {
            lint_requires(file, r)?;
        }
    }
    Ok(())
}

/// A plain name: one component, no wildcards, not `.` or `..`.
fn lint_name(file: &str, what: &str, name: &str) -> Result<(), RuleError> {
    let plain = !name.is_empty()
        && name != "."
        && name != ".."
        && name.trim() == name
        && !name.contains(['/', '\\', '\0', '*', '?', '[', ']', '{', '}', '~', '$']);
    if plain {
        Ok(())
    } else {
        Err(lint_err(
            file,
            format!("{what} {name:?} must be a plain name"),
        ))
    }
}

/// A one-component pattern with exactly one `*` and some literal text.
fn lint_glob(file: &str, pattern: &str) -> Result<(), RuleError> {
    let bad = |why: &str| Err(lint_err(file, format!("glob {pattern:?}: {why}")));
    if pattern.matches('*').count() != 1 {
        return bad("must contain exactly one '*'");
    }
    if pattern == "*" {
        return bad("matches everything");
    }
    if pattern.contains(['/', '\\']) {
        return bad("must not contain a path separator");
    }
    lint_name(file, "glob", &pattern.replace('*', "x"))
}

/// An evidence path: plain, relative, inside the project, and not a file we
/// refuse to read (keys, env files, lockfiles, history).
fn lint_evidence(file: &str, path: &str) -> Result<(), RuleError> {
    let bad = |why: &str| Err(lint_err(file, format!("evidence {path:?}: {why}")));
    if path.trim() != path {
        return bad("padded with whitespace");
    }
    if path.contains(['\\', '\0', '*', '?', '[', ']', '{', '}', '~', '$']) {
        return bad("contains a backslash, NUL, wildcard or expansion");
    }
    // Also catches "" and a trailing '/'. `Path::components` would silently
    // drop interior `.` segments.
    if path.split('/').any(|seg| seg == "." || seg.is_empty()) {
        return bad("has an empty or '.' segment");
    }
    let mut count = 0usize;
    for c in Path::new(path).components() {
        let Component::Normal(os) = c else {
            return bad("must be relative with no '.', '..' or root components");
        };
        let Some(name) = os.to_str() else {
            return bad("not valid UTF-8");
        };
        if let Some(why) = protected_component(name) {
            return bad(&format!("component {name:?} is protected ({why})"));
        }
        count += 1;
    }
    if count > 4 {
        return bad("deeper than 4 components");
    }
    Ok(())
}

fn lint_requires(file: &str, r: &Requires) -> Result<(), RuleError> {
    if r.any_files.is_empty() && r.any_glob.is_empty() && r.inside.is_empty() && r.json.is_none() {
        return Err(lint_err(file, "requires has no conditions".to_owned()));
    }
    for f in &r.any_files {
        lint_evidence(file, f)?;
    }
    for g in &r.any_glob {
        lint_glob(file, g)?;
    }
    for f in &r.inside {
        lint_name(file, "requires.inside", f)?;
        lint_evidence(file, f)?;
    }
    if let Some(j) = &r.json {
        lint_evidence(file, &j.file)?;
        if j.key.is_empty() || j.key.split('.').any(str::is_empty) {
            return Err(lint_err(
                file,
                format!("requires.json key {:?} must be dotted names", j.key),
            ));
        }
    }
    Ok(())
}

/// An artifact path must be a plain relative path that cannot reach outside
/// the project or name anything protected.
fn lint_artifact_path(file: &str, path: &str) -> Result<(), RuleError> {
    let bad = |why: &str| Err(lint_err(file, format!("artifact {path:?}: {why}")));
    if path.is_empty() || path.trim() != path {
        return bad("empty or padded with whitespace");
    }
    if path.contains('\\') || path.contains('\0') {
        return bad("contains a backslash or NUL");
    }
    if path
        .chars()
        .any(|c| matches!(c, '*' | '?' | '[' | ']' | '{' | '}' | '~' | '$'))
    {
        return bad("wildcards and expansions are not allowed");
    }
    if path.ends_with('/') {
        return bad("must not end with '/'");
    }
    // `Path::components` silently drops interior `.` segments.
    if path.split('/').any(|seg| seg == "." || seg.is_empty()) {
        return bad("has an empty or '.' segment");
    }
    let p = Path::new(path);
    let last = p.file_name();
    let mut count = 0usize;
    for c in p.components() {
        match c {
            Component::Normal(os) => {
                let Some(name) = os.to_str() else {
                    return bad("not valid UTF-8");
                };
                let verdict = if Some(os) == last {
                    protected_target(name)
                } else {
                    protected_component(name)
                };
                if let Some(why) = verdict {
                    return Err(lint_err(
                        file,
                        format!("artifact {path:?}: component {name:?} is protected ({why})"),
                    ));
                }
                count += 1;
            }
            _ => return bad("must be relative with no '.', '..' or root components"),
        }
    }
    if count == 0 {
        return bad("names the project root itself");
    }
    if count > 4 {
        return bad("deeper than 4 components");
    }
    Ok(())
}

/// Loads every `*.toml` file in `dir`, in name order, and checks ids are unique.
pub fn load_dir(dir: &Path) -> Result<Vec<RuleFile>, RuleError> {
    let io = |e: std::io::Error| RuleError::Io {
        file: dir.display().to_string(),
        message: e.to_string(),
    };
    let mut files: Vec<_> = std::fs::read_dir(dir)
        .map_err(io)?
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "toml"))
        .collect();
    files.sort();
    let mut texts = Vec::with_capacity(files.len());
    for path in files {
        let label = path.display().to_string();
        let text = std::fs::read_to_string(&path).map_err(|e| RuleError::Io {
            file: label.clone(),
            message: e.to_string(),
        })?;
        texts.push((label, text));
    }
    load_texts(texts.iter().map(|(l, t)| (l.as_str(), t.as_str())))
}

/// The rule files built into the binary, so the CLI works without the
/// source tree. `bundled_rules_match_the_rules_folder` keeps this list whole.
const BUNDLED: &[(&str, &str)] = &[
    ("android.toml", include_str!("../../../rules/android.toml")),
    ("dotnet.toml", include_str!("../../../rules/dotnet.toml")),
    ("elixir.toml", include_str!("../../../rules/elixir.toml")),
    ("flutter.toml", include_str!("../../../rules/flutter.toml")),
    ("go.toml", include_str!("../../../rules/go.toml")),
    ("java.toml", include_str!("../../../rules/java.toml")),
    ("node.toml", include_str!("../../../rules/node.toml")),
    ("php.toml", include_str!("../../../rules/php.toml")),
    ("python.toml", include_str!("../../../rules/python.toml")),
    ("rust.toml", include_str!("../../../rules/rust.toml")),
    ("swiftpm.toml", include_str!("../../../rules/swiftpm.toml")),
    ("xcode.toml", include_str!("../../../rules/xcode.toml")),
];

/// The catalogue plus the user's own rule files in `dir` (P8), linted the
/// same way. A missing folder adds nothing; a user rule may not reuse a
/// built-in id, so it can add to the catalogue but never change it.
pub fn with_user(mut base: Vec<RuleFile>, dir: &Path) -> Result<Vec<RuleFile>, RuleError> {
    if !dir.is_dir() {
        return Ok(base);
    }
    let user = load_dir(dir)?;
    for rule in user {
        if base.iter().any(|b| b.id == rule.id) {
            return Err(lint_err(
                &dir.display().to_string(),
                format!(
                    "rule id {:?} is built in; give your rule another id",
                    rule.id
                ),
            ));
        }
        base.push(rule);
    }
    Ok(base)
}

/// The built-in catalogue, linted like any rule folder.
pub fn bundled() -> Result<Vec<RuleFile>, RuleError> {
    load_texts(BUNDLED.iter().copied())
}

fn load_texts<'a>(
    files: impl Iterator<Item = (&'a str, &'a str)>,
) -> Result<Vec<RuleFile>, RuleError> {
    let mut ids = BTreeSet::new();
    let mut out = Vec::new();
    for (label, text) in files {
        let rule = parse(label, text)?;
        if !ids.insert(rule.id.clone()) {
            return Err(lint_err(label, format!("duplicate rule id {:?}", rule.id)));
        }
        out.push(rule);
    }
    Ok(out)
}

#[cfg(test)]
#[allow(clippy::panic)]
mod tests {
    use super::*;

    fn rule_with(path: &str) -> String {
        format!(
            "schema = 1\nid = \"x\"\nname = \"X\"\n[detect]\nany_files = [\"x.json\"]\n\
             [[artifact]]\npath = {path:?}\nclass = \"safe\"\nreason = \"r\"\nrestore = \"s\"\n"
        )
    }

    #[test]
    fn accepts_plain_artifacts() {
        for p in [
            "node_modules",
            "target",
            "android/app/build",
            ".next",
            "a/b/c/out",
        ] {
            assert!(parse("t", &rule_with(p)).is_ok(), "{p}");
        }
    }

    #[test]
    fn rejects_dangerous_artifacts() {
        for p in [
            "",
            ".",
            "..",
            "../x",
            "/etc",
            "a/../b",
            "src",
            "SRC",
            ".git",
            "x/.git/y",
            ".env",
            ".env.local",
            "*",
            "build*",
            "~/x",
            "$HOME",
            "a\\b",
            "x/",
            " x",
            "keys/prod.pem",
            "Cargo.lock",
            "a/b/c/d/e",
            "x/./target",
            "x//target",
        ] {
            assert!(
                matches!(parse("t", &rule_with(p)), Err(RuleError::Lint { .. })),
                "{p:?} was accepted"
            );
        }
    }

    #[test]
    fn rejects_unknown_fields_and_wrong_schema() {
        let extra = rule_with("target") + "delete_everything = true\n";
        assert!(matches!(parse("t", &extra), Err(RuleError::Parse { .. })));
        for found in [0, 3] {
            let other = rule_with("target").replace("schema = 1", &format!("schema = {found}"));
            assert_eq!(
                parse("t", &other).err(),
                Some(RuleError::Schema {
                    file: "t".into(),
                    found
                })
            );
        }
    }

    #[test]
    fn ids_and_texts_are_checked() {
        for id in ["", "Node", "a_b", "a b", "é"] {
            let text = rule_with("target").replace("id = \"x\"", &format!("id = {id:?}"));
            assert!(lint_fails(&text), "id {id:?} was accepted");
        }
        let fine = rule_with("target").replace("id = \"x\"", "id = \"dot-net2\"");
        assert!(parse("t", &fine).is_ok());
        for (from, to) in [
            ("reason = \"r\"", "reason = \" \""),
            ("restore = \"s\"", "restore = \"\""),
            ("name = \"X\"", "name = \" \""),
        ] {
            assert!(lint_fails(&rule_with("target").replace(from, to)), "{to}");
        }
    }

    #[test]
    fn rejects_rule_without_marker() {
        let none = rule_with("target").replace("[\"x.json\"]", "[]");
        assert!(matches!(parse("t", &none), Err(RuleError::Lint { .. })));
    }

    #[test]
    fn candidates_need_the_marker_file() {
        let tmp = tempfile::tempdir().unwrap_or_else(|e| panic!("{e}"));
        let rule = parse("t", &rule_with("target")).unwrap_or_else(|e| panic!("{e}"));
        std::fs::create_dir(tmp.path().join("target")).unwrap_or_else(|e| panic!("{e}"));
        assert!(rule.candidates(tmp.path()).is_empty());
        std::fs::write(tmp.path().join("x.json"), "{}").unwrap_or_else(|e| panic!("{e}"));
        let found = rule.candidates(tmp.path());
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].rel(), Path::new("target"));
        assert_eq!(found[0].rule_id(), "x");
    }

    /// A schema 2 rule: `extra_detect` goes under `[detect]`, `extra_art` under
    /// the single `[[artifact]]` (path `out`).
    fn v2(extra_detect: &str, extra_art: &str) -> String {
        format!(
            "schema = 2\nid = \"x\"\nname = \"X\"\n[detect]\n{extra_detect}\n\
             [[artifact]]\npath = \"out\"\nclass = \"safe\"\nreason = \"r\"\nrestore = \"s\"\n\
             {extra_art}\n"
        )
    }

    /// P8: user rule files load beside the catalogue and are linted, but
    /// cannot replace a built-in rule.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn user_rules_add_to_the_catalogue() {
        let tmp = tempfile::tempdir().unwrap();
        let base = bundled().unwrap();
        let n = base.len();
        assert_eq!(
            with_user(base.clone(), &tmp.path().join("missing"))
                .unwrap()
                .len(),
            n
        );
        std::fs::write(tmp.path().join("x.toml"), rule_with("out")).unwrap();
        let all = with_user(base.clone(), tmp.path()).unwrap();
        assert_eq!(all.len(), n + 1);
        assert_eq!(all.last().map(|r| r.id.as_str()), Some("x"));
        std::fs::write(tmp.path().join("x.toml"), rule_with("../up")).unwrap();
        assert!(with_user(base.clone(), tmp.path()).is_err(), "linted");
        std::fs::write(
            tmp.path().join("x.toml"),
            rule_with("out").replace("id = \"x\"", "id = \"node\""),
        )
        .unwrap();
        assert!(with_user(base, tmp.path()).is_err(), "built-in id reused");
    }

    fn lint_fails(text: &str) -> bool {
        matches!(parse("t", text), Err(RuleError::Lint { .. }))
    }

    fn ok<T, E: std::fmt::Display>(r: Result<T, E>) -> T {
        r.unwrap_or_else(|e| panic!("{e}"))
    }

    #[test]
    fn schema_one_rejects_schema_two_fields() {
        let one = rule_with("target");
        for extra in [
            "any_glob = [\"*.csproj\"]\n",
            "any_dirs = [\"x.xcodeproj\"]\n",
            "exclude_if = { parent_any_files = [\"pubspec.yaml\"] }\n",
        ] {
            let text = one.replace("[detect]\n", &format!("[detect]\n{extra}"));
            assert!(lint_fails(&text), "{extra}");
        }
        let req = one + "requires = { any_files = [\"x.json\"] }\n";
        assert!(lint_fails(&req));
    }

    #[test]
    fn schema_two_accepts_globs_dirs_and_evidence() {
        for (d, a) in [
            ("any_glob = [\"*.csproj\", \"App.*\"]", ""),
            ("any_dirs = [\"ios\"]", ""),
            (
                "any_files = [\"build.gradle\"]\nexclude_if = { parent_any_files = [\"pubspec.yaml\"] }",
                "",
            ),
            (
                "any_files = [\"package.json\"]",
                "requires = { json = { file = \"package.json\", key = \"scripts.build\" } }",
            ),
            ("any_dirs = [\"x\"]", "requires = { inside = [\"pyvenv.cfg\"] }"),
            ("any_dirs = [\"x\"]", "requires = { any_files = [\"a/b.json\"], any_glob = [\"*.sln\"] }"),
            ("any_dirs = [\"x\"]", "requires = { any_files = [\"a/b/c/d.json\"] }"),
        ] {
            assert!(parse("t", &v2(d, a)).is_ok(), "{d} {a}");
        }
    }

    #[test]
    fn linter_rejects_bad_markers_globs_and_evidence() {
        let bad_detect = [
            "",
            "any_files = []",
            "any_files = [\".\"]",
            "any_dirs = [\"..\"]",
            "any_dirs = [\"a/b\"]",
            "any_files = [\"*.json\"]",
            "any_glob = [\"*\"]",
            "any_glob = [\"*.*\"]",
            "any_glob = [\"src/*.cs\"]",
            "any_glob = [\"*\\\\x\"]",
            "any_glob = [\"x.csproj\"]",
            "any_glob = [\"?.csproj\"]",
            "any_files = [\"x\"]\nexclude_if = {}",
            "any_files = [\"x\"]\nexclude_if = { parent_any_files = [\"../y\"] }",
        ];
        for d in bad_detect {
            assert!(lint_fails(&v2(d, "")), "detect {d:?} was accepted");
        }
        let bad_requires = [
            "requires = {}",
            "requires = { any_files = [\"../package.json\"] }",
            "requires = { any_files = [\"/etc/passwd\"] }",
            "requires = { any_files = [\"a/./b\"] }",
            "requires = { any_files = [\".env\"] }",
            "requires = { any_files = [\"keys/x.pem\"] }",
            "requires = { any_files = [\"a/b/c/d/e\"] }",
            "requires = { any_files = [\"\"] }",
            "requires = { any_files = [\"x/\"] }",
            "requires = { any_files = [\" package.json\"] }",
            "requires = { any_glob = [\"**.cs\"] }",
            "requires = { inside = [\"a/b\"] }",
            "requires = { inside = [\"..\"] }",
            "requires = { json = { file = \"../p.json\", key = \"a\" } }",
            "requires = { json = { file = \"p.json\", key = \"a..b\" } }",
            "requires = { json = { file = \"p.json\", key = \"\" } }",
        ];
        for a in bad_requires {
            let text = v2("any_files = [\"x\"]", a);
            assert!(lint_fails(&text), "{a:?} was accepted");
        }
    }

    #[test]
    fn globs_match_one_star() {
        assert!(glob_match("*.csproj", "App.csproj"));
        assert!(glob_match("App.*", "App.xcodeproj"));
        assert!(!glob_match("*.csproj", "App.csproj.user"));
        assert!(!glob_match("*.csproj", ".csprojx"));
        // Prefix and suffix may not overlap.
        assert!(!glob_match("ab*ba", "aba"));
        assert!(glob_match("ab*ba", "abba"));
        assert!(!glob_match("a*a", "a"));
        assert!(!glob_match("csproj", "csproj"), "no '*' matches nothing");
    }

    #[test]
    fn detection_uses_globs_dirs_and_exclusions() {
        let tmp = ok(tempfile::tempdir());
        let root = tmp.path().join("app/android");
        ok(std::fs::create_dir_all(root.join("out")));
        let rule = ok(parse(
            "t",
            &v2(
                "any_glob = [\"*.gradle\"]\nexclude_if = { parent_any_files = [\"pubspec.yaml\"] }",
                "",
            ),
        ));
        assert!(!rule.detects(&root));
        ok(std::fs::write(root.join("build.gradle"), ""));
        assert!(rule.detects(&root));
        assert_eq!(rule.candidates(&root).len(), 1);
        ok(std::fs::write(tmp.path().join("app/pubspec.yaml"), ""));
        assert!(!rule.detects(&root));

        let dirs = ok(parse("t", &v2("any_dirs = [\"App.xcodeproj\"]", "")));
        assert!(!dirs.detects(tmp.path()));
        ok(std::fs::write(tmp.path().join("App.xcodeproj"), ""));
        assert!(!dirs.detects(tmp.path()), "a file is not a folder marker");
    }

    #[cfg(unix)]
    #[test]
    fn markers_and_evidence_are_not_followed_through_links() {
        use std::os::unix::fs::symlink;
        let tmp = ok(tempfile::tempdir());
        let outside = tmp.path().join("outside");
        let root = tmp.path().join("proj");
        ok(std::fs::create_dir_all(&outside));
        ok(std::fs::create_dir_all(root.join("out")));
        ok(std::fs::write(outside.join("App.csproj"), ""));
        ok(std::fs::write(outside.join("p.json"), r#"{"a":{"b":1}}"#));

        let glob = ok(parse("t", &v2("any_glob = [\"*.csproj\"]", "")));
        ok(symlink(outside.join("App.csproj"), root.join("App.csproj")));
        assert!(!glob.detects(&root), "linked glob marker");

        let json = ok(parse(
            "t",
            &v2(
                "any_dirs = [\"out\"]",
                "requires = { json = { file = \"sub/p.json\", key = \"a.b\" } }",
            ),
        ));
        ok(symlink(&outside, root.join("sub")));
        assert!(
            json.candidates(&root).is_empty(),
            "evidence through a linked folder"
        );
        ok(std::fs::remove_file(root.join("sub")));
        ok(std::fs::create_dir(root.join("sub")));
        ok(symlink(outside.join("p.json"), root.join("sub/p.json")));
        assert!(json.candidates(&root).is_empty(), "linked evidence file");
        ok(std::fs::remove_file(root.join("sub/p.json")));
        ok(std::fs::write(root.join("sub/p.json"), r#"{"a":{"b":1}}"#));
        assert_eq!(json.candidates(&root).len(), 1);

        // A link to a folder inside the project does not count either: the
        // evidence must be at the path the rule names.
        ok(std::fs::remove_dir_all(root.join("sub")));
        ok(std::fs::create_dir(root.join("real")));
        ok(std::fs::write(root.join("real/p.json"), r#"{"a":{"b":1}}"#));
        ok(symlink(root.join("real"), root.join("sub")));
        assert!(
            json.candidates(&root).is_empty(),
            "evidence through an inner link"
        );
    }

    #[test]
    fn evidence_decides_each_artifact() {
        let tmp = ok(tempfile::tempdir());
        let root = tmp.path();
        ok(std::fs::create_dir_all(root.join("out")));
        let cands = |a: &str| {
            ok(parse("t", &v2("any_dirs = [\"out\"]", a)))
                .candidates(root)
                .len()
        };

        let json = "requires = { json = { file = \"package.json\", key = \"scripts.build\" } }";
        assert_eq!(cands(json), 0, "no package.json");
        ok(std::fs::write(
            root.join("package.json"),
            r#"{"scripts":{"test":"x"}}"#,
        ));
        assert_eq!(cands(json), 0, "no build script");
        ok(std::fs::write(root.join("package.json"), "not json"));
        assert_eq!(cands(json), 0, "unparseable");
        ok(std::fs::write(
            root.join("package.json"),
            r#"{"scripts":{"build":"tsc"}}"#,
        ));
        assert_eq!(cands(json), 1);
        let big = format!(r#"{{"scripts":{{"build":"{}"}}}}"#, "x".repeat(1_000_001));
        ok(std::fs::write(root.join("package.json"), big));
        assert_eq!(cands(json), 0, "over the size cap");
        let body = r#"{"scripts":{"build":""}}"#;
        let pad = " ".repeat(1_000_000 - body.len());
        ok(std::fs::write(
            root.join("package.json"),
            format!("{body}{pad}"),
        ));
        assert_eq!(cands(json), 1, "exactly at the size cap");

        let inside = "requires = { inside = [\"pyvenv.cfg\"] }";
        assert_eq!(cands(inside), 0);
        ok(std::fs::write(root.join("out/pyvenv.cfg"), ""));
        assert_eq!(cands(inside), 1);

        let both = "requires = { inside = [\"pyvenv.cfg\"], any_glob = [\"*.csproj\"] }";
        assert_eq!(cands(both), 0, "every condition must hold");
        ok(std::fs::write(root.join("A.csproj"), ""));
        assert_eq!(cands(both), 1);

        let files = "requires = { any_files = [\"nope\", \"A.csproj\"] }";
        assert_eq!(cands(files), 1, "one listed file is enough");
    }

    fn subdirs(dir: &Path) -> Vec<PathBuf> {
        let mut out: Vec<PathBuf> = ok(std::fs::read_dir(dir))
            .map(|e| ok(e).path())
            .filter(|p| p.is_dir())
            .collect();
        out.sort();
        out
    }

    /// Every rule has `fixtures/<id>/match/<case>` trees whose candidates are
    /// exactly `expected.txt`, and `nomatch/<case>` trees with none.
    #[test]
    fn rule_fixtures_produce_the_expected_candidates() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../rules");
        let rules = ok(load_dir(&dir));
        let fixtures = dir.join("fixtures");
        let ids: BTreeSet<String> = rules.iter().map(|r| r.id.clone()).collect();
        let dirs: BTreeSet<String> = subdirs(&fixtures)
            .iter()
            .filter_map(|p| p.file_name()?.to_str().map(str::to_owned))
            .collect();
        assert_eq!(ids, dirs, "fixture folders must match rule ids one to one");

        for rule in &rules {
            let base = fixtures.join(&rule.id);
            let matches = subdirs(&base.join("match"));
            let nomatches = subdirs(&base.join("nomatch"));
            assert!(!matches.is_empty(), "{}: no match fixtures", rule.id);
            assert!(!nomatches.is_empty(), "{}: no nomatch fixtures", rule.id);
            for case in matches {
                let want: BTreeSet<String> = ok(std::fs::read_to_string(case.join("expected.txt")))
                    .lines()
                    .filter(|l| !l.trim().is_empty())
                    .map(str::to_owned)
                    .collect();
                let got: BTreeSet<String> = rule
                    .candidates(&case)
                    .iter()
                    .map(|c| c.rel().display().to_string())
                    .collect();
                assert_eq!(got, want, "{}", case.display());
            }
            for case in nomatches {
                let got = rule.candidates(&case);
                assert!(got.is_empty(), "{}: {got:?}", case.display());
            }
        }
    }

    #[test]
    fn bundled_rules_are_valid() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../rules");
        let rules = load_dir(&dir);
        assert!(rules.is_ok(), "{rules:?}");
        assert!(rules.is_ok_and(|r| r.len() >= 11));
    }

    #[test]
    fn bundled_rules_match_the_rules_folder() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../rules");
        let mut on_disk: Vec<String> = ok(std::fs::read_dir(&dir))
            .filter_map(Result::ok)
            .filter_map(|e| e.file_name().into_string().ok())
            .filter(|n| n.ends_with(".toml"))
            .collect();
        on_disk.sort();
        let listed: Vec<&str> = BUNDLED.iter().map(|(n, _)| *n).collect();
        assert_eq!(on_disk, listed, "add new rule files to rules::BUNDLED");
        for (name, text) in BUNDLED {
            assert_eq!(ok(std::fs::read_to_string(dir.join(name))), *text);
        }
        let bundled = ok(bundled());
        let from_disk = ok(load_dir(&dir));
        let ids = |r: &[RuleFile]| r.iter().map(|r| r.id.clone()).collect::<Vec<_>>();
        assert_eq!(ids(&bundled), ids(&from_disk));
    }

    #[test]
    fn flutter_platform_folders_are_not_projects_of_their_own() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../rules");
        let rules = ok(load_dir(&dir));
        let app = dir.join("fixtures/flutter/match/app");
        for sub in ["android", "ios"] {
            for rule in &rules {
                let got = rule.candidates(&app.join(sub));
                assert!(got.is_empty(), "{} on {sub}: {got:?}", rule.id);
            }
        }
    }
}
