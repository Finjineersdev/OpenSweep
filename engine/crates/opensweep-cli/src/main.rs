//! `opensweep` command-line interface.
//!
//! Every command that changes anything is a dry run unless `--execute` is
//! given. Cleaning moves folders into a quarantine; nothing is deleted until a
//! run is purged. The exception is `pin` and `unpin`, which change only
//! OpenSweep's own config file, never a project.
//!
//! With `--json`, every command prints one JSON document (`scan` prints JSON
//! Lines) in the shapes documented in `docs/CLI-JSON.md`.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};

use clap::{Args, Parser, Subcommand};
use opensweep_core::activity::{self, Activity, Config, Processes, Verdict as Busy};
use opensweep_core::caches::{self, Found};
use opensweep_core::discover::{self, Event, Options, Skip};
use opensweep_core::guard::Guard;
use opensweep_core::quarantine::{self, Manifest, State, Store};
use opensweep_core::rules::{self, Candidate, Class, RuleFile};
use serde_json::{json, Value};

/// Version of every JSON shape this binary prints.
const SCHEMA_VERSION: u32 = 1;

/// The app's version when built inside it (the Xcode build passes
/// `MARKETING_VERSION`, which a release takes from its tag); the crate's own
/// version for a plain `cargo build`.
const VERSION: &str = match option_env!("OPENSWEEP_VERSION") {
    Some(v) => v,
    None => env!("CARGO_PKG_VERSION"),
};

#[derive(Parser)]
#[command(
    name = "opensweep",
    version = VERSION,
    about = "Reclaim disk space from developer projects, safely"
)]
struct Cli {
    /// Print JSON instead of text (scan prints JSON Lines)
    #[arg(long, global = true)]
    json: bool,
    #[command(subcommand)]
    command: Cmd,
}

#[derive(Args)]
struct StoreArg {
    /// Quarantine folder [default: the platform data folder]
    #[arg(long, value_name = "DIR")]
    store: Option<PathBuf>,
}

#[derive(Subcommand)]
enum Cmd {
    /// Validate a directory of rule files
    RulesCheck {
        /// Directory containing *.toml rule files
        dir: PathBuf,
    },
    /// Find projects and what each could free (read-only)
    Scan {
        /// Folders to scan [default: the home folder]
        roots: Vec<PathBuf>,
        /// Directory of *.toml rule files [default: the built-in catalogue]
        #[arg(long, value_name = "DIR")]
        rules: Option<PathBuf>,
        /// Also list projects with nothing to clean (always on with --json)
        #[arg(long)]
        all: bool,
        /// Scan every folder on this computer's own disk where projects can
        /// live (on macOS: /Users, /Applications, /Library, /opt, /usr/local,
        /// /private/tmp), plus any folders given
        #[arg(long)]
        whole_disk: bool,
        /// Also scan other local drives (external SSDs, USB drives); never
        /// network drives, read-only disk images or Time Machine backups
        #[arg(long)]
        other_drives: bool,
        #[command(flatten)]
        store: StoreArg,
    },
    /// Show what the rules and the safety guard would allow in one project (read-only)
    Plan {
        /// Directory of *.toml rule files [default: the built-in catalogue]
        #[arg(long, value_name = "DIR")]
        rules: Option<PathBuf>,
        /// Project root
        project: PathBuf,
    },
    /// Move rebuildable folders into quarantine (dry run unless --execute)
    Clean {
        /// Directory of *.toml rule files [default: the built-in catalogue]
        #[arg(long, value_name = "DIR")]
        rules: Option<PathBuf>,
        /// Also move Caution folders, which need a reinstall (node_modules, .venv)
        #[arg(long)]
        include_caution: bool,
        /// Also clean projects that are in use (recent edits or commits, or a
        /// tool running inside). Pinned projects are never cleaned.
        #[arg(long)]
        include_active: bool,
        /// Only these folders (absolute paths, repeatable). Each must be one
        /// the rules offer in the given projects; it still passes every check.
        #[arg(long, value_name = "PATH")]
        only: Vec<PathBuf>,
        /// Actually move the folders
        #[arg(long)]
        execute: bool,
        #[command(flatten)]
        store: StoreArg,
        /// Project roots
        #[arg(required = true)]
        projects: Vec<PathBuf>,
    },
    /// Never clean this folder or anything inside it; with no folder, list pins
    Pin {
        folder: Option<PathBuf>,
        /// Only for this many days; then the project is judged as usual
        #[arg(long, value_name = "N", conflicts_with = "remote")]
        days: Option<u64>,
        /// Pin the folder's git repository (its origin remote) wherever it
        /// is cloned, instead of this path
        #[arg(long)]
        remote: bool,
    },
    /// Remove a pin
    Unpin { folder: PathBuf },
    /// Show the settings, or change them. Changes only OpenSweep's config.
    Config {
        /// Projects changed within this many days are Active
        #[arg(long, value_name = "DAYS")]
        idle_days: Option<u64>,
        /// Projects unchanged for this many days are Dormant
        #[arg(long, value_name = "DAYS")]
        dormant_days: Option<u64>,
        /// Folder for scan to skip (repeatable)
        #[arg(long, value_name = "FOLDER")]
        exclude: Vec<PathBuf>,
        /// Stop skipping a folder (repeatable)
        #[arg(long, value_name = "FOLDER")]
        include: Vec<PathBuf>,
    },
    /// List global tool caches and their sizes (read-only)
    Caches,
    /// Clear global caches with each tool's own command (dry run unless --execute).
    /// Not undoable: the tool downloads again what it needs.
    CleanCache {
        /// Cache ids, as shown by `caches`
        #[arg(required = true)]
        ids: Vec<String>,
        /// Actually run the tools' commands
        #[arg(long)]
        execute: bool,
    },
    /// List clean runs, newest first
    History {
        #[command(flatten)]
        store: StoreArg,
    },
    /// Move a run's folders back where they came from
    Restore {
        /// Run id, as shown by `history`
        run: String,
        /// Restore only this item number
        #[arg(long)]
        item: Option<usize>,
        #[command(flatten)]
        store: StoreArg,
    },
    /// Permanently delete quarantined folders to free the space (dry run unless --execute)
    Purge {
        /// Run id, as shown by `history`
        #[arg(
            required_unless_present = "older_than_days",
            conflicts_with = "older_than_days"
        )]
        run: Option<String>,
        /// Purge every run at least this many days old
        #[arg(long, value_name = "DAYS")]
        older_than_days: Option<u64>,
        /// Actually delete
        #[arg(long)]
        execute: bool,
        #[command(flatten)]
        store: StoreArg,
    },
}

type CliResult = Result<ExitCode, String>;

static JSON: AtomicBool = AtomicBool::new(false);

fn json_mode() -> bool {
    JSON.load(Ordering::Relaxed)
}

/// Prints one line to stdout. If the reader has gone (`opensweep scan |
/// head`), exits quietly instead of panicking like `println!`.
macro_rules! say {
    ($($arg:tt)*) => { emit(format_args!($($arg)*)) };
}

fn emit(line: std::fmt::Arguments) {
    use std::io::Write;
    if let Err(e) = writeln!(std::io::stdout().lock(), "{line}") {
        if e.kind() == std::io::ErrorKind::BrokenPipe {
            std::process::exit(0);
        }
        eprintln!("error: cannot write output: {e}");
        std::process::exit(1);
    }
}

/// Prints `fields` as one JSON object tagged with the schema version and
/// `key` (`"command"` for documents, `"type"` for scan lines).
fn put(key: &str, name: &str, fields: Value) {
    let mut doc = json!({ "schema_version": SCHEMA_VERSION, key: name });
    if let (Value::Object(doc), Value::Object(fields)) = (&mut doc, fields) {
        doc.extend(fields);
    }
    say!("{doc}");
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    JSON.store(cli.json, Ordering::Relaxed);
    let result = match cli.command {
        Cmd::RulesCheck { dir } => rules_check(&dir),
        Cmd::Scan {
            roots,
            rules,
            all,
            whole_disk,
            other_drives,
            store,
        } => scan(
            roots,
            rules.as_deref(),
            all,
            whole_disk,
            other_drives,
            &store,
        ),
        Cmd::Plan { rules, project } => plan(rules.as_deref(), &absolute(&project)),
        Cmd::Clean {
            rules,
            include_caution,
            include_active,
            only,
            execute,
            store,
            projects,
        } => clean(
            rules.as_deref(),
            &projects.iter().map(|p| absolute(p)).collect::<Vec<_>>(),
            Flags {
                caution: include_caution,
                active: include_active,
                execute,
            },
            &only,
            &store,
        ),
        Cmd::Pin {
            folder,
            days,
            remote,
        } => pin(folder.as_deref(), days, remote),
        Cmd::Unpin { folder } => unpin(&folder),
        Cmd::Config {
            idle_days,
            dormant_days,
            exclude,
            include,
        } => config(idle_days, dormant_days, &exclude, &include),
        Cmd::Caches => caches(),
        Cmd::CleanCache { ids, execute } => clean_cache(&ids, execute),
        Cmd::History { store } => history(&store),
        Cmd::Restore { run, item, store } => restore(&run, item, &store),
        Cmd::Purge {
            run,
            older_than_days,
            execute,
            store,
        } => purge(run.as_deref(), older_than_days, execute, &store),
    };
    result.unwrap_or_else(|e| {
        if json_mode() {
            say!(
                "{}",
                json!({ "schema_version": SCHEMA_VERSION, "error": e })
            );
        } else {
            eprintln!("error: {e}");
        }
        ExitCode::FAILURE
    })
}

/// A project path typed relative to the working folder (`plan .`), made
/// absolute: the guard refuses every relative candidate. Absolute paths and
/// folders that do not exist are left as given.
fn absolute(project: &Path) -> PathBuf {
    if project.is_absolute() {
        return project.to_path_buf();
    }
    std::fs::canonicalize(project).unwrap_or_else(|_| project.to_path_buf())
}

fn load_rules(dir: Option<&Path>) -> Result<Vec<RuleFile>, String> {
    match dir {
        Some(d) => rules::load_dir(d),
        // The catalogue plus the user's own rules beside config.toml (P8).
        None => rules::bundled().and_then(|base| match user_rules_dir() {
            Some(u) => rules::with_user(base, &u),
            None => Ok(base),
        }),
    }
    .map_err(|e| e.to_string())
}

/// `rules/` beside `config.toml`.
fn user_rules_dir() -> Option<PathBuf> {
    activity::default_config_path().and_then(|p| p.parent().map(|d| d.join("rules")))
}

fn open_store(arg: &StoreArg) -> Result<Store, String> {
    let root = match &arg.store {
        Some(p) => p.clone(),
        None => quarantine::default_location()
            .ok_or("cannot find a home folder for the quarantine; pass --store")?,
    };
    Store::open(&root).map_err(|e| e.to_string())
}

fn config_path() -> Result<PathBuf, String> {
    activity::default_config_path()
        .ok_or_else(|| "cannot find a home folder for the config".to_owned())
}

/// A broken config stops the command: it may hold pins.
fn load_config() -> Result<Config, String> {
    match activity::default_config_path() {
        Some(path) => Config::load(&path),
        None => Ok(Config::default()),
    }
}

fn lossy(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

fn print_pins(cfg: &Config) {
    if json_mode() {
        let pins: Vec<String> = cfg.pinned.iter().map(|p| lossy(p)).collect();
        let until: serde_json::Map<String, Value> = cfg
            .pinned_until
            .iter()
            .map(|(p, t)| (lossy(p), json!(t)))
            .collect();
        put(
            "command",
            "pin",
            json!({ "pinned": pins, "until": until, "remotes": cfg.pinned_remotes }),
        );
    }
}

fn pin(folder: Option<&Path>, days: Option<u64>, remote: bool) -> CliResult {
    let path = config_path()?;
    let mut cfg = Config::load(&path)?;
    let Some(folder) = folder else {
        print_pins(&cfg);
        if !json_mode() {
            if cfg.pinned.is_empty() && cfg.pinned_remotes.is_empty() {
                say!("Nothing is pinned.");
            }
            for p in &cfg.pinned {
                match cfg.pinned_until.get(p) {
                    Some(t) => say!("{}  (until {})", p.display(), day(*t)),
                    None => say!("{}", p.display()),
                }
            }
            cfg.pinned_remotes
                .iter()
                .for_each(|r| say!("{r}  (repository, any folder)"));
        }
        return Ok(ExitCode::SUCCESS);
    };
    let folder = std::fs::canonicalize(folder).map_err(|e| format!("{}: {e}", folder.display()))?;
    if !folder.is_dir() {
        return Err(format!("{} is not a folder", folder.display()));
    }
    if remote {
        let r = activity::git_remote(&folder)
            .ok_or_else(|| format!("{} has no origin remote to pin", folder.display()))?;
        if !cfg.pinned_remotes.contains(&r) {
            cfg.pinned_remotes.push(r.clone());
        }
        cfg.save(&path)?;
        print_pins(&cfg);
        if !json_mode() {
            say!("Pinned {r}: no clone of it will be cleaned, wherever it is.");
        }
        return Ok(ExitCode::SUCCESS);
    }
    if !cfg.pinned.contains(&folder) {
        cfg.pinned.push(folder.clone());
    }
    match days {
        Some(d) => {
            cfg.pinned_until.insert(
                folder.clone(),
                now_unix().saturating_add(d.saturating_mul(86_400)),
            );
        }
        None => {
            cfg.pinned_until.remove(&folder);
        }
    }
    cfg.save(&path)?;
    print_pins(&cfg);
    if !json_mode() {
        match days {
            Some(d) => say!("Pinned {} for {d} days.", folder.display()),
            None => say!("Pinned {}: it will never be cleaned.", folder.display()),
        }
    }
    Ok(ExitCode::SUCCESS)
}

fn unpin(folder: &Path) -> CliResult {
    let path = config_path()?;
    let mut cfg = Config::load(&path)?;
    let canon = std::fs::canonicalize(folder).unwrap_or_else(|_| folder.to_path_buf());
    let before = cfg.pinned.len() + cfg.pinned_remotes.len();
    cfg.pinned.retain(|p| p != folder && p != &canon);
    cfg.pinned_until.retain(|p, _| p != folder && p != &canon);
    if let Some(r) = activity::git_remote(&canon) {
        cfg.pinned_remotes
            .retain(|p| activity::normalise_remote(p).as_deref() != Some(r.as_str()));
    }
    if cfg.pinned.len() + cfg.pinned_remotes.len() == before {
        return Err(format!("{} is not pinned", folder.display()));
    }
    cfg.save(&path)?;
    print_pins(&cfg);
    if !json_mode() {
        say!("Unpinned {}.", folder.display());
    }
    Ok(ExitCode::SUCCESS)
}

fn config(
    idle: Option<u64>,
    dormant: Option<u64>,
    exclude: &[PathBuf],
    include: &[PathBuf],
) -> CliResult {
    let path = config_path()?;
    let mut cfg = Config::load(&path)?;
    let before = cfg.clone();
    cfg.idle_days = idle.unwrap_or(cfg.idle_days);
    cfg.dormant_days = dormant.unwrap_or(cfg.dormant_days);
    if cfg.idle_days > cfg.dormant_days {
        return Err(format!(
            "idle days ({}) cannot be more than dormant days ({})",
            cfg.idle_days, cfg.dormant_days
        ));
    }
    for folder in exclude {
        let folder =
            std::fs::canonicalize(folder).map_err(|e| format!("{}: {e}", folder.display()))?;
        if !cfg.exclude.contains(&folder) {
            cfg.exclude.push(folder);
        }
    }
    for folder in include {
        let canon = std::fs::canonicalize(folder).unwrap_or_else(|_| folder.clone());
        cfg.exclude.retain(|p| p != folder && p != &canon);
    }
    if cfg != before {
        cfg.save(&path)?;
    }
    let list = |v: &[PathBuf]| v.iter().map(|p| lossy(p)).collect::<Vec<_>>();
    if json_mode() {
        put(
            "command",
            "config",
            json!({
                "path": lossy(&path),
                "idle_days": cfg.idle_days,
                "dormant_days": cfg.dormant_days,
                "pinned": list(&cfg.pinned),
                "exclude": list(&cfg.exclude),
                "pinned_until": cfg.pinned_until.iter().map(|(p, t)| (lossy(p), json!(t))).collect::<serde_json::Map<_, _>>(),
                "pinned_remotes": cfg.pinned_remotes,
            }),
        );
    } else {
        say!("config      {}", path.display());
        say!("idle after  {} days", cfg.idle_days);
        say!("dormant     {} days", cfg.dormant_days);
        cfg.pinned
            .iter()
            .for_each(|p| say!("pinned      {}", p.display()));
        cfg.exclude
            .iter()
            .for_each(|p| say!("excluded    {}", p.display()));
    }
    Ok(ExitCode::SUCCESS)
}

fn rules_check(dir: &Path) -> CliResult {
    let loaded = load_rules(Some(dir))?;
    let artifacts: usize = loaded.iter().map(|r| r.artifacts.len()).sum();
    if json_mode() {
        put(
            "command",
            "rules-check",
            json!({ "rule_files": loaded.len(), "artifacts": artifacts }),
        );
    } else {
        say!("{} rule files, {} artifacts: ok", loaded.len(), artifacts);
    }
    Ok(ExitCode::SUCCESS)
}

/// What `scan`, `plan` and `clean` need to judge projects.
struct Context {
    rules: Vec<RuleFile>,
    config: Config,
    processes: Option<Processes>,
}

impl Context {
    fn load(rules: Option<&Path>) -> Result<Self, String> {
        Ok(Self {
            rules: load_rules(rules)?,
            config: load_config()?,
            processes: Processes::snapshot(),
        })
    }

    fn activity(&self, project: &Path) -> Activity {
        activity::assess(
            project,
            &self.rules,
            &self.config,
            self.processes.as_ref(),
            std::time::SystemTime::now(),
        )
    }

    /// One project's verdict and each candidate's outcome, with sizes of the
    /// ones the guard allows. Activity does not refuse here: the verdict says
    /// whether `clean` would need --include-active.
    fn report(&self, project: &Path, candidates: Vec<Candidate>) -> ProjectReport {
        let activity = self.activity(project);
        let guard = Guard::from_env().allow_active();
        let items = candidates
            .into_iter()
            .map(|c| {
                let (bytes, shared, refused) = match guard.check(&activity, &c) {
                    Ok(ok) => {
                        let u = opensweep_core::size::usage(ok.path());
                        (Some(u.bytes), u.shared, None)
                    }
                    Err(why) => (None, false, Some(why.to_string())),
                };
                ItemReport {
                    path: c.rel().to_path_buf(),
                    rule: c.rule_id().to_owned(),
                    class: c.class(),
                    bytes,
                    shared,
                    refused,
                }
            })
            .collect();
        ProjectReport {
            root: project.to_path_buf(),
            verdict: activity.verdict(),
            pinned: activity.pinned(),
            reason: activity.reason().to_owned(),
            items,
        }
    }
}

/// Every rule's candidates in one project, once each: two rules can claim
/// one folder (Cargo and Maven both use target).
fn candidates(rules: &[RuleFile], project: &Path) -> Vec<Candidate> {
    let mut seen = HashSet::new();
    rules
        .iter()
        .flat_map(|r| r.candidates(project))
        .filter(|c| seen.insert(c.rel().to_path_buf()))
        .collect()
}

fn verdict_name(v: Busy) -> &'static str {
    match v {
        Busy::Active => "active",
        Busy::Idle => "idle",
        Busy::Dormant => "dormant",
    }
}

fn class_name(c: Class) -> &'static str {
    match c {
        Class::Safe => "safe",
        Class::Caution => "caution",
    }
}

/// The text label for a project: its verdict, or Pinned.
fn label(verdict: Busy, pinned: bool) -> String {
    if pinned {
        "Pinned".to_owned()
    } else {
        format!("{verdict:?}")
    }
}

/// One project as `scan` and `plan` report it.
struct ProjectReport {
    root: PathBuf,
    verdict: Busy,
    pinned: bool,
    reason: String,
    items: Vec<ItemReport>,
}

/// One candidate folder: its size if the guard allows it, or why not.
struct ItemReport {
    path: PathBuf,
    rule: String,
    class: Class,
    bytes: Option<u64>,
    /// The folder shares space with files elsewhere; `bytes` is an upper estimate.
    shared: bool,
    refused: Option<String>,
}

impl ProjectReport {
    fn json(&self) -> Value {
        let items: Vec<Value> = self
            .items
            .iter()
            .map(|i| {
                json!({
                    "path": lossy(&i.path),
                    "rule": i.rule,
                    "class": class_name(i.class),
                    "bytes": i.bytes,
                    "shared": i.shared,
                    "refused": i.refused,
                })
            })
            .collect();
        json!({
            "root": lossy(&self.root),
            "verdict": verdict_name(self.verdict),
            "pinned": self.pinned,
            "reason": self.reason,
            "items": items,
        })
    }
}

/// What `scan` found, by what `clean` would need to take it.
#[derive(Default)]
struct Totals {
    projects: usize,
    ready: (usize, u64),
    caution: (usize, u64),
    active: (usize, u64),
}

impl Totals {
    fn add(&mut self, p: &ProjectReport) {
        self.projects += 1;
        for item in &p.items {
            let Some(bytes) = item.bytes else { continue };
            let bucket = if p.verdict == Busy::Active {
                &mut self.active
            } else if item.class == Class::Caution {
                &mut self.caution
            } else {
                &mut self.ready
            };
            bucket.0 += 1;
            bucket.1 += bytes;
        }
    }
}

fn scan(
    mut roots: Vec<PathBuf>,
    rules: Option<&Path>,
    all: bool,
    whole_disk: bool,
    other_drives: bool,
    store: &StoreArg,
) -> CliResult {
    let ctx = Context::load(rules)?;
    let home = std::env::var_os("HOME").map(PathBuf::from);
    if whole_disk {
        roots.extend(discover::whole_disk_roots());
    }
    if other_drives {
        roots.extend(opensweep_core::volumes::other_drives());
    }
    let roots = match (roots.is_empty(), &home) {
        (false, _) => roots,
        (true, Some(h)) => vec![h.clone()],
        (true, None) => return Err("no home folder: give the folders to scan".to_owned()),
    };
    let mut opts = Options::new(roots);
    if whole_disk || other_drives {
        // A whole disk is deeper and larger than a home folder.
        opts.max_depth = 24;
        opts.max_entries = 20_000_000;
    }
    opts.home = home;
    opts.exclude = ctx.config.exclude.clone();
    opts.store = store.store.clone().or_else(quarantine::default_location);
    let mut totals = Totals::default();
    discover::discover(&ctx.rules, &opts, |event| match event {
        Event::Project {
            root, candidates, ..
        } => {
            let report = ctx.report(&root, candidates);
            totals.add(&report);
            if json_mode() {
                put("type", "project", report.json());
            } else if all || !report.items.is_empty() {
                print_project(&report);
            }
        }
        Event::Skipped { path, reason } => {
            if json_mode() {
                let (kind, detail) = skip_names(&reason);
                put(
                    "type",
                    "skipped",
                    json!({ "path": lossy(&path), "reason": kind, "detail": detail }),
                );
            } else {
                say!("skipped  {}  {}", path.display(), describe(&reason));
            }
        }
    });
    if json_mode() {
        let pair = |(n, b): (usize, u64)| json!({ "folders": n, "bytes": b });
        put(
            "type",
            "summary",
            json!({
                "projects": totals.projects,
                "ready": pair(totals.ready),
                "caution": pair(totals.caution),
                "active": pair(totals.active),
            }),
        );
        return Ok(ExitCode::SUCCESS);
    }
    let size = |(n, b): (usize, u64)| format!("{} in {}", human(b), count(n, "folder"));
    say!(
        "{}. Ready to clean: {} (Safe, in projects not in use).",
        count(totals.projects, "project"),
        size(totals.ready)
    );
    say!(
        "Also {} with --include-caution, and {} in active projects with --include-active.",
        size(totals.caution),
        size(totals.active)
    );
    Ok(ExitCode::SUCCESS)
}

fn print_project(p: &ProjectReport) {
    let total: u64 = p.items.iter().filter_map(|i| i.bytes).sum();
    say!(
        "{:<8} {:>9}  {}  ({})",
        label(p.verdict, p.pinned),
        human(total),
        p.root.display(),
        p.reason
    );
    for item in &p.items {
        match item.bytes {
            Some(b) => say!(
                "         {:>9}    {}  [{}]  {:?}{}",
                human(b),
                item.path.display(),
                item.rule,
                item.class,
                if item.shared {
                    "  (shares space with files elsewhere; may free less)"
                } else {
                    ""
                }
            ),
            None => say!(
                "         {:>9}    {}  [{}]  kept: {}",
                "",
                item.path.display(),
                item.rule,
                item.refused.as_deref().unwrap_or("")
            ),
        }
    }
}

/// A skip reason as a stable JSON name and a detail string.
fn skip_names(skip: &Skip) -> (&'static str, String) {
    let name = match skip {
        Skip::Unreadable(_) => "unreadable",
        Skip::Protected(_) => "protected",
        Skip::OtherVolume => "other_volume",
        Skip::DepthLimit => "depth_limit",
        Skip::EntryLimit => "entry_limit",
        Skip::Excluded => "excluded",
        Skip::Installed(_) => "installed",
    };
    (name, describe(skip))
}

fn describe(skip: &Skip) -> String {
    match skip {
        Skip::Unreadable(why) => format!("could not be read: {why}"),
        Skip::Protected(why) => {
            format!("could not be read: {why}; macOS privacy protection, give OpenSweep Full Disk Access")
        }
        Skip::OtherVolume => "on another volume".to_owned(),
        Skip::DepthLimit => "deeper than the depth limit".to_owned(),
        Skip::EntryLimit => {
            "entry limit reached; the rest of this folder was not scanned".to_owned()
        }
        Skip::Excluded => "excluded".to_owned(),
        Skip::Installed(what) => format!("installed software ({what}), never cleaned"),
    }
}

fn plan(rules: Option<&Path>, project: &Path) -> CliResult {
    let ctx = Context::load(rules)?;
    let report = ctx.report(project, candidates(&ctx.rules, project));
    if json_mode() {
        put("command", "plan", json!({ "project": report.json() }));
        return Ok(ExitCode::SUCCESS);
    }
    say!(
        "{}: {}, {}",
        project.display(),
        label(report.verdict, report.pinned),
        report.reason
    );
    if report.items.is_empty() {
        say!("nothing matched: no rule detects this folder, or it is already clean");
    }
    for item in &report.items {
        match (item.bytes, &item.refused) {
            (Some(b), _) => say!(
                "allow   {}  [{}]  {:?}  {}",
                item.path.display(),
                item.rule,
                item.class,
                human(b)
            ),
            (None, why) => say!(
                "refuse  {}  [{}]  {}",
                item.path.display(),
                item.rule,
                why.as_deref().unwrap_or("")
            ),
        }
    }
    if report.verdict == Busy::Active && !report.pinned {
        say!("The project is in use: clean needs --include-active.");
    }
    Ok(ExitCode::SUCCESS)
}

struct Flags {
    caution: bool,
    active: bool,
    execute: bool,
}

/// One candidate's outcome in `clean`.
struct CleanItem {
    candidate: Candidate,
    bytes: Option<u64>,
    /// Why it stays, if it does.
    kept: Option<String>,
}

fn clean(
    rules: Option<&Path>,
    projects: &[PathBuf],
    flags: Flags,
    only: &[PathBuf],
    store: &StoreArg,
) -> CliResult {
    let Flags {
        caution,
        active,
        execute,
    } = flags;
    let ctx = Context::load(rules)?;
    let guard = if active {
        Guard::from_env().allow_active()
    } else {
        Guard::from_env()
    };
    // --only narrows the selection; it never adds a folder the rules and the
    // guard would not offer anyway.
    let picks: HashSet<PathBuf> = only
        .iter()
        .map(|p| std::fs::canonicalize(p).map_err(|e| format!("{}: {e}", p.display())))
        .collect::<Result<_, _>>()?;
    let mut picked = HashSet::new();
    let mut approved = Vec::new();
    let mut held = 0usize;
    let mut reports = Vec::new();
    for project in projects {
        let activity = ctx.activity(project);
        let canon = std::fs::canonicalize(project).unwrap_or_else(|_| project.clone());
        let mut items = Vec::new();
        for c in candidates(&ctx.rules, project) {
            if !picks.is_empty() {
                let abs = canon.join(c.rel());
                if !picks.contains(&abs) {
                    continue;
                }
                picked.insert(abs);
            }
            let (bytes, kept) = match guard.check(&activity, &c) {
                Err(why) => (None, Some(why.to_string())),
                Ok(_) if c.class() == Class::Caution && !caution => {
                    held += 1;
                    let why = "Caution: pass --include-caution to move it";
                    (None, Some(why.to_owned()))
                }
                Ok(ok) => {
                    let bytes = opensweep_core::size::usage(ok.path()).bytes;
                    approved.push(ok);
                    (Some(bytes), None)
                }
            };
            items.push(CleanItem {
                candidate: c,
                bytes,
                kept,
            });
        }
        reports.push((project, activity, items));
    }
    let mut missing: Vec<String> = picks.difference(&picked).map(|p| lossy(p)).collect();
    if !missing.is_empty() {
        missing.sort();
        return Err(format!(
            "not a folder the rules offer in the given projects: {}",
            missing.join(", ")
        ));
    }
    let moving = reports
        .iter()
        .flat_map(|(_, _, items)| items.iter().filter_map(|i| i.bytes));
    let (folders, total) = moving.fold((0usize, 0u64), |(n, t), b| (n + 1, t + b));

    if !json_mode() {
        for (project, activity, items) in &reports {
            say!(
                "{}: {}, {}",
                project.display(),
                label(activity.verdict(), activity.pinned()),
                activity.reason()
            );
            for i in items {
                let c = &i.candidate;
                let name = format!("{}  [{}]", c.rel().display(), c.rule_id());
                match i.bytes {
                    Some(b) => say!("  move    {name}  {}", human(b)),
                    None => say!("  keep    {name}  {}", i.kept.as_deref().unwrap_or("")),
                }
            }
        }
    }
    let run = if execute && !approved.is_empty() {
        let store = open_store(store)?;
        Some(store.clean(approved).map_err(|e| e.to_string())?)
    } else {
        None
    };
    let failed = run
        .as_ref()
        .is_some_and(|r| r.entries.iter().any(|e| e.state == State::Failed));

    if json_mode() {
        let projects: Vec<Value> = reports
            .iter()
            .map(|(project, activity, items)| {
                let items: Vec<Value> = items
                    .iter()
                    .map(|i| {
                        let c = &i.candidate;
                        json!({
                            "path": lossy(c.rel()),
                            "rule": c.rule_id(),
                            "class": class_name(c.class()),
                            "action": if i.bytes.is_some() { "move" } else { "keep" },
                            "bytes": i.bytes,
                            "reason": i.kept,
                        })
                    })
                    .collect();
                json!({
                    "root": lossy(project),
                    "verdict": verdict_name(activity.verdict()),
                    "pinned": activity.pinned(),
                    "reason": activity.reason(),
                    "items": items,
                })
            })
            .collect();
        put(
            "command",
            "clean",
            json!({
                "execute": execute,
                "projects": projects,
                "folders": folders,
                "bytes": total,
                "held_caution": held,
                "run": run,
            }),
        );
    } else if folders == 0 {
        say!("Nothing to clean.");
    } else if let Some(run) = &run {
        print_run(run);
        say!("run: {}", run.run_id);
        say!("Undo:        opensweep restore {}", run.run_id);
        say!("Free space:  opensweep purge {} --execute", run.run_id);
    } else {
        say!(
            "Dry run: {}, {} would move to quarantine. Nothing was changed. Add --execute to move them.",
            count(folders, "folder"),
            human(total)
        );
        if held > 0 {
            say!("{} left out (Caution).", count(held, "folder"));
        }
    }
    Ok(if failed {
        ExitCode::from(3)
    } else {
        ExitCode::SUCCESS
    })
}

fn cache_env() -> Result<caches::Env, String> {
    caches::Env::current().ok_or_else(|| "cannot find a home folder".to_owned())
}

fn cache_json(f: &Found) -> Value {
    json!({
        "id": f.cache.id,
        "tool": f.cache.tool,
        "name": f.cache.name,
        "path": lossy(&f.cache.path),
        "bytes": f.bytes,
        "unreadable": f.unreadable,
        "command": (!f.cache.command.is_empty()).then_some(f.cache.command),
        "installed": f.program.is_some(),
        "note": f.cache.note,
    })
}

fn caches() -> CliResult {
    let found = caches::list(&cache_env()?);
    if json_mode() {
        let all: Vec<Value> = found.iter().map(cache_json).collect();
        put("command", "caches", json!({ "caches": all }));
        return Ok(ExitCode::SUCCESS);
    }
    if found.is_empty() {
        say!("No known tool caches found.");
    }
    for f in &found {
        let how = match (f.cache.command.is_empty(), f.program.is_some()) {
            (true, _) => "measure only".to_owned(),
            (false, true) => f.cache.command.join(" "),
            (false, false) => format!("{} not found", f.cache.tool),
        };
        say!(
            "{:<20} {:>10}  {}  [{how}]",
            f.cache.id,
            human(f.bytes),
            f.cache.path.display()
        );
    }
    Ok(ExitCode::SUCCESS)
}

fn clean_cache(ids: &[String], execute: bool) -> CliResult {
    let env = cache_env()?;
    let found = caches::list(&env);
    let mut picked = Vec::new();
    for id in ids {
        let f = found.iter().find(|f| f.cache.id == id).ok_or_else(|| {
            format!("no cache named {id} on this computer (see `opensweep caches`)")
        })?;
        if f.cache.command.is_empty() {
            return Err(format!("{id} has no command to clear it: {}", f.cache.note));
        }
        if f.program.is_none() {
            return Err(format!("{id}: {} is not installed", f.cache.tool));
        }
        picked.push(f);
    }
    let mut results = Vec::new();
    let mut failed = false;
    for f in picked {
        let mut r = cache_json(f);
        if execute {
            let ran = match caches::run(f, &env, caches::TIME_LIMIT) {
                Ok(ran) => ran,
                Err(e) => {
                    // Keep going: earlier caches are already cleared and must be reported.
                    failed = true;
                    if let Value::Object(m) = &mut r {
                        m.insert("status".into(), Value::Null);
                        m.insert("error".into(), json!(e));
                    }
                    if !json_mode() {
                        say!("{}: {e}", f.cache.id);
                    }
                    results.push(r);
                    continue;
                }
            };
            let after = caches::list(&env)
                .into_iter()
                .find(|g| g.cache.id == f.cache.id)
                .map_or(0, |g| g.bytes);
            let freed = f.bytes.saturating_sub(after);
            failed |= ran.status != Some(0);
            if let Value::Object(m) = &mut r {
                m.insert("status".into(), json!(ran.status));
                m.insert("bytes_after".into(), json!(after));
                m.insert("freed".into(), json!(freed));
                m.insert("stderr".into(), json!(ran.stderr));
            }
            if !json_mode() {
                match ran.status {
                    Some(0) => say!(
                        "{}: ran `{}`, freed {}",
                        f.cache.id,
                        f.cache.command.join(" "),
                        human(freed)
                    ),
                    Some(code) => say!(
                        "{}: `{}` failed (exit {code}): {}",
                        f.cache.id,
                        f.cache.command.join(" "),
                        ran.stderr
                    ),
                    None => say!(
                        "{}: `{}` was stopped",
                        f.cache.id,
                        f.cache.command.join(" ")
                    ),
                }
            }
        } else if !json_mode() {
            say!(
                "would run `{}` to clear {} ({})",
                f.cache.command.join(" "),
                f.cache.name,
                human(f.bytes)
            );
        }
        results.push(r);
    }
    if json_mode() {
        put(
            "command",
            "clean-cache",
            json!({ "execute": execute, "caches": results }),
        );
    } else if !execute {
        say!("Dry run: nothing was run. Add --execute. Not undoable: tools download again what they need.");
    }
    // 3, like a partial clean: the JSON is complete, some tools failed.
    Ok(if failed {
        ExitCode::from(3)
    } else {
        ExitCode::SUCCESS
    })
}

fn history(store: &StoreArg) -> CliResult {
    let store = open_store(store)?;
    let runs = store.runs().map_err(|e| e.to_string())?;
    if json_mode() {
        put("command", "history", json!({ "runs": runs }));
        return Ok(ExitCode::SUCCESS);
    }
    if runs.is_empty() {
        say!("No clean runs yet.");
    }
    for run in runs {
        say!(
            "{}  {}  cleaned {}  held in quarantine {}",
            run.run_id,
            count(run.entries.len(), "item"),
            human(run.bytes_cleaned()),
            human(run.bytes_held())
        );
    }
    Ok(ExitCode::SUCCESS)
}

fn restore(run: &str, item: Option<usize>, store: &StoreArg) -> CliResult {
    let store = open_store(store)?;
    let manifest = store.restore(run, item).map_err(|e| e.to_string())?;
    if json_mode() {
        put("command", "restore", json!({ "run": manifest }));
    } else {
        print_run(&manifest);
    }
    let stuck = match item {
        Some(i) => manifest
            .entries
            .get(i)
            .is_some_and(|e| e.state == State::Moved),
        None => manifest.entries.iter().any(|e| e.state == State::Moved),
    };
    Ok(if stuck {
        ExitCode::from(3)
    } else {
        ExitCode::SUCCESS
    })
}

fn purge(run: Option<&str>, days: Option<u64>, execute: bool, store: &StoreArg) -> CliResult {
    let store = open_store(store)?;
    let targets: Vec<Manifest> = match (run, days) {
        (Some(id), _) => vec![store.load(id).map_err(|e| e.to_string())?],
        (None, Some(d)) => {
            let cutoff = now_unix().saturating_sub(d.saturating_mul(86_400));
            let runs = store.runs().map_err(|e| e.to_string())?;
            runs.into_iter()
                .filter(|r| r.created_unix <= cutoff && r.bytes_held() > 0)
                .collect()
        }
        (None, None) => return Err("give a run id or --older-than-days".to_owned()),
    };
    let total: u64 = targets.iter().map(Manifest::bytes_held).sum();
    let mut after = Vec::new();
    let mut freed = 0u64;
    if execute && total > 0 {
        for r in &targets {
            let done = store.purge(&r.run_id).map_err(|e| e.to_string())?;
            freed += r.bytes_held().saturating_sub(done.bytes_held());
            after.push(done);
        }
    }
    if json_mode() {
        let runs = if execute && total > 0 {
            &after
        } else {
            &targets
        };
        put(
            "command",
            "purge",
            json!({ "execute": execute, "bytes": total, "freed": freed, "runs": runs }),
        );
        return Ok(ExitCode::SUCCESS);
    }
    if total == 0 {
        say!("Nothing held in quarantine for that selection.");
    } else if !execute {
        for r in &targets {
            say!("{}  {}", r.run_id, human(r.bytes_held()));
        }
        say!(
            "Dry run: {} would be permanently deleted from quarantine. This cannot be undone. Add --execute to delete.",
            human(total)
        );
    } else {
        after.iter().for_each(print_run);
        say!("Freed {}.", human(freed));
    }
    Ok(ExitCode::SUCCESS)
}

fn print_run(run: &Manifest) {
    for (i, e) in run.entries.iter().enumerate() {
        let state = format!("{:?}", e.state).to_lowercase();
        let note = e
            .note
            .as_deref()
            .map(|n| format!("  ({n})"))
            .unwrap_or_default();
        say!(
            "  {i:>3}  {state:<8}  {}  {}{note}",
            e.original.display(),
            human(e.bytes)
        );
    }
}

use opensweep_core::quarantine::now_unix;

fn count(n: usize, noun: &str) -> String {
    if n == 1 {
        format!("1 {noun}")
    } else {
        format!("{n} {noun}s")
    }
}

/// Decimal units, as Finder reports sizes.
fn human(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1000.0 && unit < UNITS.len() - 1 {
        value /= 1000.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

/// A Unix time as a UTC date, `YYYY-MM-DD`.
fn day(unix: u64) -> String {
    let (y, m, d) = opensweep_core::quarantine::civil_from_days(unix / 86_400);
    format!("{y:04}-{m:02}-{d:02}")
}

#[cfg(test)]
mod day_tests {
    #[test]
    fn dates_are_utc_calendar_days() {
        assert_eq!(super::day(0), "1970-01-01");
        assert_eq!(super::day(951_782_400), "2000-02-29");
        assert_eq!(super::day(1_795_651_200), "2026-11-26");
    }
}
