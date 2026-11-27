//! End-to-end tests of the `opensweep` binary.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const RULES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../rules");

struct Env {
    _tmp: tempfile::TempDir,
    home: PathBuf,
    project: PathBuf,
    store: PathBuf,
}

fn env() -> Env {
    let tmp = tempfile::tempdir().unwrap();
    let base = fs::canonicalize(tmp.path()).unwrap();
    let home = base.join("home");
    let project = base.join("work/site");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(project.join("node_modules/react")).unwrap();
    fs::create_dir_all(project.join(".next/cache")).unwrap();
    fs::create_dir_all(project.join("src")).unwrap();
    fs::write(project.join("package.json"), "{}").unwrap();
    fs::write(
        project.join("node_modules/react/index.js"),
        "x".repeat(5000),
    )
    .unwrap();
    fs::write(project.join(".next/cache/build.bin"), vec![0u8; 30_000]).unwrap();
    fs::write(project.join("src/page.tsx"), "export default 1").unwrap();
    age(&project);
    Env {
        store: base.join("store"),
        _tmp: tmp,
        home,
        project,
    }
}

/// Backdates every file below `dir` by 200 days, so the project is Dormant
/// rather than in use.
fn age(dir: &Path) {
    let then = std::time::SystemTime::now() - std::time::Duration::from_secs(200 * 86_400);
    for entry in fs::read_dir(dir).unwrap().flatten() {
        let path = entry.path();
        if entry.file_type().unwrap().is_dir() {
            age(&path);
        } else {
            let file = fs::File::options().write(true).open(&path).unwrap();
            file.set_modified(then).unwrap();
        }
    }
}

impl Env {
    fn run(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_opensweep"))
            .args(args)
            .env("HOME", &self.home)
            .env_remove("XDG_DATA_HOME")
            .env_remove("XDG_CONFIG_HOME")
            .output()
            .unwrap()
    }

    fn ok(&self, args: &[&str]) -> String {
        let out = self.run(args);
        let text = String::from_utf8(out.stdout).unwrap();
        assert!(
            out.status.success(),
            "{args:?}\n{text}\n{}",
            String::from_utf8_lossy(&out.stderr)
        );
        text
    }

    fn clean(&self, extra: &[&str]) -> String {
        let store = self.store.to_str().unwrap();
        let project = self.project.to_str().unwrap();
        let mut args = vec!["clean", "--rules", RULES, "--store", store];
        args.extend_from_slice(extra);
        args.push(project);
        self.ok(&args)
    }

    fn store_cmd(&self, cmd: &[&str]) -> String {
        let mut args = cmd.to_vec();
        args.extend_from_slice(&["--store", self.store.to_str().unwrap()]);
        self.ok(&args)
    }
}

fn run_id(output: &str) -> String {
    output
        .lines()
        .find_map(|l| l.strip_prefix("run: "))
        .unwrap_or_else(|| panic!("no run id in:\n{output}"))
        .to_owned()
}

fn exists(p: &Path, rel: &str) -> bool {
    p.join(rel).exists()
}

#[test]
fn clean_is_a_dry_run_by_default() {
    let e = env();
    let out = e.clean(&["--include-caution"]);
    assert!(out.contains("Dry run"), "{out}");
    assert!(exists(&e.project, "node_modules/react/index.js"));
    assert!(exists(&e.project, ".next/cache/build.bin"));
    assert!(
        !e.store.exists(),
        "a dry run must not even create the quarantine"
    );
}

#[test]
fn a_folder_two_rules_claim_is_offered_once() {
    let e = env();
    let p = &e.project;
    fs::write(p.join("Cargo.toml"), "[package]").unwrap();
    fs::write(p.join("pom.xml"), "<project/>").unwrap();
    fs::create_dir_all(p.join("target/debug")).unwrap();
    age(p);
    let out = e.clean(&[]);
    assert_eq!(out.matches("target").count(), 1, "{out}");
    assert!(out.contains("2 folders"), "{out}");
}

#[test]
fn caution_folders_need_an_explicit_flag() {
    let e = env();
    let out = e.clean(&["--execute"]);
    assert!(out.contains("--include-caution"), "{out}");
    assert!(!exists(&e.project, ".next"));
    assert!(exists(&e.project, "node_modules/react/index.js"));
}

#[test]
fn clean_history_restore_purge() {
    let e = env();
    let out = e.clean(&["--execute", "--include-caution"]);
    let id = run_id(&out);
    assert!(!exists(&e.project, ".next") && !exists(&e.project, "node_modules"));
    assert!(exists(&e.project, "src/page.tsx"));

    let hist = e.store_cmd(&["history"]);
    assert!(hist.contains(&id), "{hist}");

    e.store_cmd(&["restore", &id]);
    assert!(exists(&e.project, "node_modules/react/index.js"));
    assert!(exists(&e.project, ".next/cache/build.bin"));

    // Clean again, then purge: dry run first, then for real.
    let id = run_id(&e.clean(&["--execute", "--include-caution"]));
    let dry = e.store_cmd(&["purge", &id]);
    assert!(dry.contains("Dry run"), "{dry}");
    let items = e.store.join("runs").join(&id).join("items");
    assert!(exists(&items, "0000"));

    let done = e.store_cmd(&["purge", &id, "--execute"]);
    assert!(done.contains("Freed"), "{done}");
    assert!(!exists(&items, "0000") && !exists(&items, "0001"));
    assert!(exists(&e.project, "src/page.tsx"));
    assert!(
        !exists(&e.project, "node_modules"),
        "purge must not restore"
    );
}

#[test]
fn bad_run_ids_fail_cleanly() {
    let e = env();
    let out = e.run(&["restore", "../../etc", "--store", e.store.to_str().unwrap()]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("no run named"));
}

#[test]
fn source_folders_are_never_offered() {
    let e = env();
    let out = e.clean(&["--execute", "--include-caution"]);
    assert!(!out.contains("src"), "{out}");
    assert!(exists(&e.project, "src/page.tsx"));
}

#[test]
fn the_default_store_lives_in_the_home_folder() {
    let e = env();
    e.ok(&["history"]);
    let expected = if cfg!(target_os = "macos") {
        "Library/Application Support/OpenSweep/Quarantine/runs"
    } else {
        ".local/share/opensweep/quarantine/runs"
    };
    assert!(e.home.join(expected).is_dir(), "{expected}");
}

#[test]
fn projects_in_use_need_an_explicit_flag() {
    let e = env();
    fs::write(e.project.join("src/page.tsx"), "export default 2").unwrap();
    let out = e.clean(&[]);
    assert!(out.contains("Active, edited today"), "{out}");
    assert!(out.contains("the project is in use: edited today"), "{out}");
    assert!(out.contains("Nothing to clean."), "{out}");
    let out = e.clean(&["--include-active"]);
    assert!(out.contains("Dry run: 1 folder"), "{out}");
}

fn config_file(e: &Env) -> PathBuf {
    if cfg!(target_os = "macos") {
        e.home
            .join("Library/Application Support/OpenSweep/config.toml")
    } else {
        e.home.join(".config/opensweep/config.toml")
    }
}

#[test]
fn pinned_projects_are_never_cleaned() {
    let e = env();
    let project = e.project.to_str().unwrap();
    assert!(e.ok(&["pin"]).contains("Nothing is pinned."));
    assert!(e.ok(&["pin", project]).contains("never be cleaned"));
    e.ok(&["pin", project]); // pinning twice keeps one entry
    assert_eq!(e.ok(&["pin"]).trim(), project);
    assert!(config_file(&e).is_file());

    let out = e.clean(&["--include-active", "--include-caution", "--execute"]);
    assert!(out.contains("pinned; edited 200 days ago"), "{out}");
    assert!(out.contains("the project is pinned"), "{out}");
    assert!(out.contains("Nothing to clean."), "{out}");
    assert!(exists(&e.project, ".next/cache/build.bin"));

    e.ok(&["unpin", project]);
    assert!(e.ok(&["pin"]).contains("Nothing is pinned."));
    assert!(!e.run(&["unpin", project]).status.success());
    assert!(e.clean(&[]).contains("Dry run: 1 folder"));
}

#[test]
fn a_pin_for_days_needs_a_folder_and_at_least_one_day() {
    let e = env();
    let project = e.project.to_str().unwrap();
    // A pin for 0 days would end the moment it was made.
    let zero = e.run(&["pin", project, "--days", "0"]);
    assert!(!zero.status.success());
    // Without a folder, pin only lists: --days would be dropped silently.
    assert!(!e.run(&["pin", "--days", "7"]).status.success());
    assert!(
        !config_file(&e).exists(),
        "a refused pin must not write config"
    );
    assert!(e
        .ok(&["pin", project, "--days", "1"])
        .contains("for 1 days"));
}

#[test]
fn a_broken_config_stops_cleaning() {
    let e = env();
    let path = config_file(&e);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, "pinned = [\"relative\"]").unwrap();
    let store = e.store.to_str().unwrap();
    let out = e.run(&[
        "clean",
        "--rules",
        RULES,
        "--store",
        store,
        e.project.to_str().unwrap(),
    ]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("not absolute"));
}

#[test]
fn scan_reports_projects_and_what_they_could_free() {
    let e = env();
    let work = e.project.parent().unwrap();
    fs::create_dir_all(work.join("notes/doc")).unwrap();
    fs::create_dir_all(work.join("empty-app")).unwrap();
    fs::write(work.join("empty-app/package.json"), "{}").unwrap();
    age(work);
    let out = e.ok(&["scan", work.to_str().unwrap()]);
    assert!(out.contains("Dormant"), "{out}");
    assert!(out.contains("work/site  (edited 200 days ago)"), "{out}");
    assert!(out.contains(".next  [node]  Safe"), "{out}");
    assert!(out.contains("node_modules  [node]  Caution"), "{out}");
    assert!(!out.contains("empty-app"), "{out}");
    assert!(out.contains("2 projects. Ready to clean: "), "{out}");
    assert!(out.contains(" in 1 folder (Safe"), "{out}");
    assert!(e
        .ok(&["scan", "--all", work.to_str().unwrap()])
        .contains("empty-app"));
    // Read-only: nothing moved, no quarantine.
    assert!(exists(&e.project, ".next/cache/build.bin"));
    assert!(!e.store.exists());
}

#[test]
fn scan_skips_excluded_folders() {
    let e = env();
    let work = e.project.parent().unwrap();
    let path = config_file(&e);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!("exclude = [{:?}]", e.project.to_str().unwrap()),
    )
    .unwrap();
    let out = e.ok(&["scan", work.to_str().unwrap()]);
    assert!(out.contains("skipped"), "{out}");
    assert!(out.contains("excluded"), "{out}");
    assert!(out.contains("0 projects"), "{out}");
}

#[test]
fn the_built_in_rules_are_the_default() {
    let e = env();
    let project = e.project.to_str().unwrap();
    let out = e.ok(&["plan", project]);
    assert!(out.contains("allow   .next  [node]"), "{out}");
    let out = e.ok(&["clean", "--store", e.store.to_str().unwrap(), project]);
    assert!(out.contains("Dry run: 1 folder"), "{out}");
}

#[test]
fn a_closed_pipe_ends_quietly() {
    use std::process::Stdio;
    let e = env();
    let work = e.project.parent().unwrap();
    // Far more output than a pipe buffers, so writing must hit the closed end.
    for i in 0..2000 {
        let p = work.join(format!("app-with-a-long-folder-name-{i:04}"));
        fs::create_dir_all(&p).unwrap();
        fs::write(p.join("package.json"), "{}").unwrap();
    }
    let mut child = Command::new(env!("CARGO_BIN_EXE_opensweep"))
        .args(["scan", "--all", work.to_str().unwrap()])
        .env("HOME", &e.home)
        .env_remove("XDG_CONFIG_HOME")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    drop(child.stdout.take());
    let out = child.wait_with_output().unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "{stderr}");
    assert!(!stderr.contains("panicked"), "{stderr}");
}

/// Each JSON line of `out`, with the temporary folder replaced by `$TMP` and
/// the values that vary between runs and file systems masked.
fn normalized(e: &Env, out: &str) -> serde_json::Value {
    fn mask(v: &mut serde_json::Value, base: &str) {
        use serde_json::Value;
        match v {
            Value::String(s) => *s = s.replace(base, "$TMP"),
            Value::Array(a) => a.iter_mut().for_each(|v| mask(v, base)),
            Value::Object(m) => {
                for (k, v) in m.iter_mut() {
                    match k.as_str() {
                        "bytes" | "bytes_after" | "freed" | "created_unix" if v.is_u64() => {
                            *v = 0.into()
                        }
                        "run_id" => *v = "RUN".into(),
                        // The config file's place differs between macOS and Linux.
                        "path" if v.as_str().is_some_and(|p| p.ends_with("config.toml")) => {
                            *v = "CONFIG".into()
                        }
                        _ => mask(v, base),
                    }
                }
            }
            _ => {}
        }
    }
    let base = e.home.parent().unwrap().to_str().unwrap().to_owned();
    let mut lines: serde_json::Value = out
        .lines()
        .map(|l| serde_json::from_str(l).unwrap_or_else(|_| panic!("not JSON: {l}")))
        .collect::<Vec<serde_json::Value>>()
        .into();
    mask(&mut lines, &base);
    lines
}

/// Compares with `tests/snapshots/<name>.json`; UPDATE_SNAPSHOTS=1 rewrites it.
fn snapshot(name: &str, got: &serde_json::Value) {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("tests/snapshots/{name}.json"));
    let text = serde_json::to_string_pretty(got).unwrap() + "\n";
    if std::env::var_os("UPDATE_SNAPSHOTS").is_some() {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, &text).unwrap();
    }
    let want = fs::read_to_string(&path).unwrap_or_default();
    assert_eq!(text, want, "{name}: run with UPDATE_SNAPSHOTS=1 to accept");
}

#[test]
fn json_output_matches_the_snapshots() {
    let e = env();
    let project = e.project.to_str().unwrap();
    let work = e.project.parent().unwrap().to_str().unwrap();
    let store = e.store.to_str().unwrap();
    let json = |args: &[&str]| {
        let mut all = vec!["--json"];
        all.extend_from_slice(args);
        normalized(&e, &e.ok(&all))
    };
    snapshot("rules-check", &json(&["rules-check", RULES]));
    snapshot("scan", &json(&["scan", work]));
    snapshot("plan", &json(&["plan", project]));
    snapshot(
        "clean-dry-run",
        &json(&["clean", "--store", store, project]),
    );
    snapshot(
        "clean-execute",
        &json(&[
            "clean",
            "--store",
            store,
            "--execute",
            "--include-caution",
            project,
        ]),
    );
    let run = e.ok(&["--json", "history", "--store", store]);
    snapshot("history", &normalized(&e, &run));
    let id: serde_json::Value = serde_json::from_str(&run).unwrap();
    let id = id["runs"][0]["run_id"].as_str().unwrap().to_owned();
    snapshot("purge-dry-run", &json(&["purge", &id, "--store", store]));
    snapshot("restore", &json(&["restore", &id, "--store", store]));
    snapshot("pin", &json(&["pin", project]));
    snapshot(
        "config",
        &json(&["config", "--idle-days", "7", "--exclude", work]),
    );

    let out = e.run(&["--json", "restore", "nope", "--store", store]);
    assert!(!out.status.success());
    let text = String::from_utf8(out.stdout).unwrap();
    snapshot("error", &normalized(&e, &text));
}

#[test]
fn only_narrows_the_selection() {
    let e = env();
    let project = e.project.to_str().unwrap();
    let next = e.project.join(".next");
    let out = e.clean(&["--include-caution", "--only", next.to_str().unwrap()]);
    assert!(out.contains("Dry run: 1 folder"), "{out}");
    assert!(!out.contains("node_modules"), "{out}");

    // Not something the rules offer: refused before anything moves.
    for bad in [
        e.project.join("src"),
        e.project.join("missing"),
        e.home.clone(),
    ] {
        let store = e.store.to_str().unwrap();
        let out = e.run(&[
            "clean",
            "--store",
            store,
            "--execute",
            "--include-caution",
            "--only",
            next.to_str().unwrap(),
            "--only",
            bad.to_str().unwrap(),
            project,
        ]);
        assert!(!out.status.success(), "{bad:?}");
        assert!(exists(&e.project, ".next/cache/build.bin"));
        assert!(!e.store.exists());
    }
}

#[test]
fn config_changes_only_the_settings() {
    let e = env();
    let work = e.project.parent().unwrap().to_str().unwrap().to_owned();
    let out = e.ok(&[
        "config",
        "--idle-days",
        "3",
        "--dormant-days",
        "30",
        "--exclude",
        &work,
    ]);
    assert!(out.contains("idle after  3 days"), "{out}");
    let saved = fs::read_to_string(config_file(&e)).unwrap();
    assert!(
        saved.contains("idle_days = 3") && saved.contains(&work),
        "{saved}"
    );
    let base = e.home.parent().unwrap().to_str().unwrap().to_owned();
    let scan = e.ok(&["scan", &base]);
    assert!(scan.contains("excluded"), "{scan}");

    // Idle may not exceed dormant; nothing is saved.
    let bad = e.run(&["config", "--idle-days", "40"]);
    assert!(!bad.status.success());
    assert_eq!(fs::read_to_string(config_file(&e)).unwrap(), saved);

    e.ok(&["config", "--include", &work]);
    assert!(!fs::read_to_string(config_file(&e)).unwrap().contains(&work));
    assert!(exists(&e.project, ".next/cache/build.bin"));
}

/// F15: a global cache is cleared only by the tool's own command, and only
/// with --execute.
#[test]
fn caches_are_cleared_by_the_tools_own_command() {
    use std::os::unix::fs::PermissionsExt;
    let e = env();
    let cache = e.home.join(".npm/_cacache");
    fs::create_dir_all(&cache).unwrap();
    fs::write(cache.join("blob"), vec![1u8; 40_000]).unwrap();
    let bin = e.home.parent().unwrap().join("bin");
    fs::create_dir_all(&bin).unwrap();
    let npm = bin.join("npm");
    fs::write(
        &npm,
        "#!/bin/sh\necho \"$*\" >> \"$HOME/npm-ran\"\nrm -rf \"$HOME/.npm/_cacache\"\n",
    )
    .unwrap();
    fs::set_permissions(&npm, fs::Permissions::from_mode(0o755)).unwrap();
    let run = |args: &[&str]| {
        let out = Command::new(env!("CARGO_BIN_EXE_opensweep"))
            .args(args)
            .env("HOME", &e.home)
            .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
            .env_remove("XDG_CACHE_HOME")
            .env_remove("XDG_DATA_HOME")
            .env_remove("npm_config_cache")
            .env_remove("CARGO_HOME")
            .env_remove("GOPATH")
            .env_remove("GOMODCACHE")
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        normalized(&e, &String::from_utf8(out.stdout).unwrap())
    };

    snapshot("caches", &run(&["--json", "caches"]));
    snapshot(
        "clean-cache-dry-run",
        &run(&["--json", "clean-cache", "npm"]),
    );
    assert!(
        cache.exists() && !e.home.join("npm-ran").exists(),
        "dry run runs nothing"
    );
    let done = run(&["--json", "clean-cache", "npm", "--execute"]);
    snapshot("clean-cache-execute", &done);
    assert!(!cache.exists());
    assert_eq!(
        fs::read_to_string(e.home.join("npm-ran")).unwrap(),
        "cache clean --force\n"
    );

    let out = e.run(&["clean-cache", "gradle"]);
    assert!(
        !out.status.success(),
        "unknown or measure-only caches are refused"
    );
}

/// A tool that cannot start is reported on its own cache; the caches already
/// cleared in the same command are still reported.
#[test]
fn a_tool_that_cannot_start_does_not_hide_the_other_results() {
    use std::os::unix::fs::PermissionsExt;
    let e = env();
    fs::create_dir_all(e.home.join(".npm/_cacache")).unwrap();
    fs::create_dir_all(e.home.join(".cache/uv")).unwrap();
    let bin = e.home.parent().unwrap().join("bin");
    fs::create_dir_all(&bin).unwrap();
    for (name, script) in [
        ("npm", "#!/bin/sh\nrm -rf \"$HOME/.npm/_cacache\"\n"),
        ("uv", "#!/no/such/shell\n"),
    ] {
        fs::write(bin.join(name), script).unwrap();
        fs::set_permissions(bin.join(name), fs::Permissions::from_mode(0o755)).unwrap();
    }
    let out = Command::new(env!("CARGO_BIN_EXE_opensweep"))
        .args(["--json", "clean-cache", "npm", "uv", "--execute"])
        .env("HOME", &e.home)
        .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
        .env_remove("XDG_CACHE_HOME")
        .env_remove("npm_config_cache")
        .output()
        .unwrap();
    assert_eq!(
        out.status.code(),
        Some(3),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    let caches = v["caches"].as_array().unwrap();
    assert_eq!(caches[0]["id"], "npm");
    assert_eq!(caches[0]["status"], 0);
    assert_eq!(caches[1]["id"], "uv");
    assert!(caches[1]["status"].is_null());
    assert!(caches[1]["error"].as_str().unwrap().contains("cannot run"));
    assert!(!e.home.join(".npm/_cacache").exists());
}

/// P8: rule files beside config.toml add to the catalogue; a repository's
/// `.opensweep.toml` only keeps folders.
#[test]
fn user_rules_and_repository_files() {
    let e = env();
    let project = e.project.to_str().unwrap();
    fs::create_dir_all(e.project.join("out/x")).unwrap();
    fs::write(e.project.join("out/x/a.bin"), vec![0u8; 9000]).unwrap();
    fs::write(e.project.join("site.json"), "{}").unwrap();
    age(&e.project);
    assert!(!e.ok(&["plan", project]).contains("out"));

    let rules = config_file(&e).parent().unwrap().join("rules");
    fs::create_dir_all(&rules).unwrap();
    fs::write(
        rules.join("mine.toml"),
        "schema = 1\nid = \"mine\"\nname = \"My generator\"\n[detect]\nany_files = [\"site.json\"]\n\
         [[artifact]]\npath = \"out\"\nclass = \"safe\"\nreason = \"My generator writes it\"\nrestore = \"Run the generator\"\n",
    )
    .unwrap();
    let plan = e.ok(&["plan", project]);
    assert!(plan.contains("out"), "{plan}");

    fs::write(
        e.project.join(".opensweep.toml"),
        "exclude = [\"out\", \".next\"]\n",
    )
    .unwrap();
    age(&e.project);
    let plan = e.ok(&["plan", project]);
    assert!(plan.contains(".opensweep.toml keeps this folder"), "{plan}");

    // A built-in id cannot be replaced: the command stops.
    fs::write(rules.join("mine.toml"), "schema = 1\nid = \"node\"\nname = \"N\"\n[detect]\nany_files = [\"x\"]\n[[artifact]]\npath = \"o\"\nclass = \"safe\"\nreason = \"r\"\nrestore = \"s\"\n").unwrap();
    assert!(!e.run(&["plan", project]).status.success());
}
