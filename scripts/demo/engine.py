#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""A stand-in `opensweep` engine with made-up data, for README media only.

It answers the app's JSON commands (docs/CLI-JSON.md) about a fictional
2 TB Mac holding about 1.25 TB of rebuildable project folders. Nothing on
disk is read, moved or deleted: a clean only updates a state file. Debug
builds take it through OPENSWEEP_BIN (see QA-CHECKLIST.md, "README media").

State: $OPENSWEEP_DEMO_STATE (default $HOME/.opensweep-demo.json).
"""
import json
import os
import random
import sys
import time

HOME = os.environ.get("HOME", "/tmp")
STATE = os.environ.get("OPENSWEEP_DEMO_STATE", os.path.join(HOME, ".opensweep-demo.json"))
GB, MB = 1_000_000_000, 1_000_000

# Template: (rule, names, [(path, class, min, max)], target total bytes)
TEMPLATES = {
    "python-ml": ("python", ["churn-model", "llm-finetune", "vision-detector", "rag-pipeline", "forecast-lab",
                             "recsys-train", "speech-to-text", "embeddings-api", "sentiment-bert", "gan-playground",
                             "fraud-detect", "ocr-invoices", "agent-evals", "diffusion-tests"],
                  [(".venv", "caution", 3 * GB, 9 * GB), ("__pycache__", "safe", 20 * MB, 300 * MB),
                   (".pytest_cache", "safe", 5 * MB, 80 * MB), (".mypy_cache", "safe", 50 * MB, 600 * MB)], 300 * GB),
    "python-web": ("python", ["django-crm", "fastapi-orders", "flask-blog", "celery-workers", "airflow-dags",
                              "scraper-bot", "invoice-api", "auth-service", "billing-worker", "pdf-reports"],
                   [(".venv", "caution", 400 * MB, 1600 * MB), ("__pycache__", "safe", 10 * MB, 120 * MB),
                    (".tox", "safe", 300 * MB, 2 * GB), (".ruff_cache", "safe", 5 * MB, 40 * MB)], 130 * GB),
    "mern": ("node", ["mern-shop", "mern-chat", "admin-dashboard", "booking-app", "social-feed", "kanban-board",
                      "lms-platform", "food-delivery", "job-board", "crm-frontend", "realtime-polls", "expense-tracker"],
             [("client/node_modules", "caution", 500 * MB, 1800 * MB), ("server/node_modules", "caution", 200 * MB, 900 * MB),
              ("client/build", "safe", 80 * MB, 900 * MB), ("server/dist", "safe", 20 * MB, 300 * MB)], 260 * GB),
    "next": ("node", ["next-saas", "marketing-site", "docs-portal", "store-front", "ai-chat-ui", "portfolio-v3",
                      "turbo-monorepo", "design-system"],
             [("node_modules", "caution", 600 * MB, 2500 * MB), (".next", "safe", 400 * MB, 3500 * MB),
              (".turbo", "safe", 500 * MB, 8 * GB)], 180 * GB),
    "go": ("go", ["go-gateway", "k8s-operator", "grpc-billing", "metrics-agent", "url-shortener", "event-router",
                  "terraform-provider", "log-shipper", "rate-limiter"],
           [("vendor", "caution", 200 * MB, 1400 * MB)], 95 * GB),
    "rust": ("rust", ["tauri-notes", "wasm-image", "actix-api", "ray-tracer", "embedded-fw", "cli-search"],
             [("target", "safe", 2 * GB, 28 * GB)], 160 * GB),
    "java": ("java", ["spring-payments", "ktor-api", "kafka-streams", "batch-etl"],
             [("build", "safe", 300 * MB, 2500 * MB), (".gradle", "caution", 200 * MB, 1 * GB)], 45 * GB),
    "flutter": ("flutter", ["flutter-wallet", "fitness-app", "delivery-rider"],
                [("build", "safe", 1 * GB, 4 * GB), (".dart_tool", "safe", 200 * MB, 800 * MB),
                 ("ios/Pods", "caution", 400 * MB, 1200 * MB)], 50 * GB),
    "android": ("android", ["android-pos", "android-scanner"],
                [("app/build", "safe", 1 * GB, 5 * GB), ("app/.cxx", "safe", 200 * MB, 2 * GB)], 35 * GB),
    "swift": ("swiftpm", ["swift-markdown-kit", "vapor-api"], [(".build", "safe", 500 * MB, 6 * GB)], 20 * GB),
}
# How many copies of each template (clients, rewrites, old clones).
COUNTS = {"python-ml": 40, "python-web": 70, "mern": 110, "next": 50, "go": 70, "rust": 22, "java": 20,
          "flutter": 12, "android": 8, "swift": 10}
FOLDERS = ["code", "code/clients/acme", "code/clients/northwind", "work", "Projects", "code/experiments",
           "Desktop/old-projects", "code/hackathons", "code/oss"]
SUFFIXES = ["", "-v2", "-old", "-backup", "-2023", "-fork", "-api", "-web", "-next", "-copy"]


def build_projects():
    rng = random.Random(7)
    projects, used = [], set()
    for key, n in COUNTS.items():
        rule, names, items, target = TEMPLATES[key]
        made = []
        for i in range(n):
            while True:
                root = "%s/%s/%s%s" % (HOME, rng.choice(FOLDERS), rng.choice(names), rng.choice(SUFFIXES))
                if root not in used:
                    used.add(root)
                    break
            r = rng.random()
            if r < 0.03:
                verdict, pinned, reason = "idle", True, "pinned; edited %d days ago" % rng.randint(20, 80)
            elif r < 0.13:
                verdict, pinned = "active", False
                reason = rng.choice(["edited today", "edited 1 day ago", "last commit %d days ago" % rng.randint(2, 12)])
            elif r < 0.36:
                verdict, pinned, reason = "idle", False, "%s %d days ago" % (rng.choice(["edited", "last commit"]), rng.randint(15, 89))
            else:
                verdict, pinned, reason = "dormant", False, "%s %d days ago" % (rng.choice(["edited", "last commit"]), rng.randint(95, 900))
            sizes = [(p, c, rng.randint(lo, hi)) for p, c, lo, hi in items if rng.random() < 0.9 or c == "caution"]
            made.append({"root": root, "verdict": verdict, "pinned": pinned, "reason": reason,
                         "items": [{"path": p, "rule": rule, "class": c, "bytes": b, "refused": None, "shared": False}
                                   for p, c, b in sizes]})
        raw = sum(i["bytes"] for p in made for i in p["items"]) or 1
        for p in made:
            for i in p["items"]:
                i["bytes"] = int(i["bytes"] * target / raw)
        projects += made
    rng.shuffle(projects)
    return projects


CACHES = [
    ("huggingface", "Hugging Face", "Hugging Face models and datasets", ".cache/huggingface", 142 * GB, [],
     "Downloaded models can be large and slow to fetch again. hf cache scan lists them; remove ones you no longer use."),
    ("xcode-derived-data", "Xcode", "Xcode DerivedData", "Library/Developer/Xcode/DerivedData", 64 * GB, [],
     "Build output of every Xcode project. Xcode has no command for it; clean each project from its folder."),
    ("ollama-models", "Ollama", "Ollama models", ".ollama/models", 58 * GB, [],
     "Your local models. ollama list shows them and ollama rm removes one."),
    ("go-build", "Go", "Go build cache", "Library/Caches/go-build", 22 * GB, ["go", "clean", "-cache"],
     "The next build compiles from scratch."),
    ("docker-desktop", "Docker", "Docker Desktop disk", "Library/Containers/com.docker.docker/Data/vms", 48 * GB, [],
     "Prune images and volumes with docker system prune; the disk file shrinks when Docker compacts it."),
    ("npm", "npm", "npm package cache", ".npm/_cacache", 18 * GB, ["npm", "cache", "clean", "--force"],
     "Packages download again on the next install."),
    ("gradle", "Gradle", "Gradle caches", ".gradle/caches", 17 * GB, [],
     "Gradle removes entries it has not used for 30 days by itself."),
    ("go-mod", "Go", "Go module cache", "go/pkg/mod", 14 * GB, ["go", "clean", "-modcache"],
     "Modules download again on the next build."),
    ("pip", "pip", "pip cache", "Library/Caches/pip", 11 * GB, ["python3", "-m", "pip", "cache", "purge"],
     "Wheels download or build again on the next install."),
    ("cargo-registry", "Cargo", "Cargo registry", ".cargo/registry", 9 * GB, [],
     "Cargo has no stable command to clear it."),
    ("yarn", "Yarn", "Yarn cache", "Library/Caches/Yarn", 7 * GB, ["yarn", "cache", "clean"],
     "Packages download again on the next install."),
    ("uv", "uv", "uv cache", ".cache/uv", 6 * GB, ["uv", "cache", "clean"], "Packages download again on the next install."),
    ("playwright-browsers", "Playwright", "Playwright browsers", "Library/Caches/ms-playwright", 4 * GB, [],
     "Browsers for every Playwright version. npx playwright uninstall --all in a project removes them; npx playwright install brings them back."),
    ("simulator-devices", "Xcode", "Simulators", "Library/Developer/CoreSimulator/Devices", 31 * GB,
     ["xcrun", "simctl", "delete", "unavailable"],
     "Removes only simulators for iOS versions no longer installed; they cannot run anyway. Other simulators and their apps stay."),
]


def initial_state():
    now = int(time.time())
    projects = build_projects()
    # Past runs, already purged, so History and the freed-so-far totals look lived in.
    runs = []
    for age, count in ((52, 9), (31, 14), (12, 6)):
        rng = random.Random(age)
        entries = []
        for n in range(count):
            root = "%s/code/archive/%s" % (HOME, rng.choice(["old-landing", "react-todo", "py-scripts", "go-cli", "vue-admin", "hack-bot"]) + str(n))
            entries.append({"original": root + "/node_modules", "project_root": root, "stored": "%04d" % n,
                            "rule_id": "node", "class": "safe", "bytes": rng.randint(800 * MB, 6 * GB),
                            "state": "purged", "volume": None, "note": None})
        runs.append({"run_id": "demo-%d" % age, "format": 1, "created_unix": now - age * 86400, "entries": entries})
    return {"projects": projects, "runs": runs, "idle_days": 14, "dormant_days": 90, "cleared": [], "exclude": []}


def load():
    try:
        with open(STATE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return initial_state()


def save(st):
    with open(STATE, "w") as f:
        json.dump(st, f)


def out(doc, command):
    doc.update({"command": command, "schema_version": 1})
    print(json.dumps(doc))


def summary(projects):
    s = {"projects": len(projects), "ready": [0, 0], "caution": [0, 0], "active": [0, 0]}
    for p in projects:
        if p["pinned"]:
            continue
        for i in p["items"]:
            key = "active" if p["verdict"] == "active" else ("ready" if i["class"] == "safe" else "caution")
            s[key][0] += 1
            s[key][1] += i["bytes"]
    return {"type": "summary", "projects": s["projects"],
            **{k: {"folders": s[k][0], "bytes": s[k][1]} for k in ("ready", "caution", "active")}}


def split(args):
    """Flags (with --only and --store values) and the positional arguments."""
    flags, only, rest, i = set(), [], [], 0
    while i < len(args):
        a = args[i]
        if a == "--":
            rest += args[i + 1:]
            break
        if a in ("--only", "--store", "--days", "--older-than-days", "--item", "--idle-days", "--dormant-days",
                 "--exclude", "--include"):
            if a == "--only":
                only.append(args[i + 1])
            flags.add((a, args[i + 1]))
            i += 2
            continue
        if a.startswith("--"):
            flags.add(a)
        else:
            rest.append(a)
        i += 1
    return flags, only, rest


def value(flags, name):
    return next((v for f in flags if isinstance(f, tuple) and f[0] == name for v in [f[1]]), None)


def main():
    args = [a for a in sys.argv[1:] if a != "--json"]
    if not args or args[0] in ("--version", "-V"):
        print("opensweep 0.2.0")
        return 0
    cmd, (flags, only, rest) = args[0], split(args[1:])
    st = load()
    by_root = {p["root"]: p for p in st["projects"]}

    if cmd == "scan":
        # Streams like the real walk; a full Mac takes a few seconds.
        delay = float(os.environ.get("OPENSWEEP_DEMO_SCAN_SECONDS", "6")) / max(len(st["projects"]), 1)
        for p in st["projects"]:
            print(json.dumps({"type": "project", "schema_version": 1, **p}), flush=True)
            time.sleep(delay)
        print(json.dumps({**summary(st["projects"]), "schema_version": 1}), flush=True)
        save(st)
        return 0
    if cmd == "plan":
        p = by_root.get(rest[0]) if rest else None
        if not p:
            print(json.dumps({"error": "not a project: %s" % (rest[0] if rest else "")}))
            return 1
        out({"project": p}, "plan")
        return 0
    if cmd == "clean":
        caution, active, execute = "--include-caution" in flags, "--include-active" in flags, "--execute" in flags
        projects, total, folders, held, entries = [], 0, 0, 0, []
        for root in rest:
            p = by_root.get(root)
            if not p:
                continue
            items, keep = [], []
            for i in p["items"]:
                full = root + "/" + i["path"]
                if only and full not in only:
                    keep.append(i)
                    continue
                why = None
                if p["pinned"]:
                    why = "pinned"
                elif p["verdict"] == "active" and not active:
                    why = "Active: pass --include-active to move it"
                elif i["class"] == "caution" and not caution:
                    why = "Caution: pass --include-caution to move it"
                    held += 1
                items.append({"path": i["path"], "rule": i["rule"], "class": i["class"],
                              "action": "keep" if why else "move", "bytes": None if why else i["bytes"], "reason": why})
                if why:
                    keep.append(i)
                else:
                    folders += 1
                    total += i["bytes"]
                    entries.append({"original": full, "project_root": root, "stored": "%04d" % len(entries),
                                    "rule_id": i["rule"], "class": i["class"], "bytes": i["bytes"], "state": "moved",
                                    "volume": None, "note": None})
            projects.append({k: p[k] for k in ("root", "verdict", "pinned", "reason")} | {"items": items})
            if execute:
                p["items"] = keep
        run = None
        if execute and entries:
            run = {"run_id": time.strftime("%Y%m%d-%H%M%S"), "format": 1, "created_unix": int(time.time()), "entries": entries}
            st["runs"].append(run)
            save(st)
        out({"execute": execute, "projects": projects, "folders": folders, "bytes": total,
             "held_caution": held, "run": run}, "clean")
        return 0
    if cmd == "history":
        out({"runs": sorted(st["runs"], key=lambda r: -r["created_unix"])}, "history")
        return 0
    if cmd == "restore":
        run = next((r for r in st["runs"] if r["run_id"] == (rest[0] if rest else "")), None)
        if not run:
            print(json.dumps({"error": "no such run"}))
            return 1
        item = value(flags, "--item")
        for n, e in enumerate(run["entries"]):
            if e["state"] == "moved" and (item is None or int(item) == n):
                e["state"] = "restored"
                p = by_root.get(e["project_root"])
                if p is not None:
                    p["items"].append({"path": e["original"][len(e["project_root"]) + 1:], "rule": e["rule_id"],
                                       "class": e["class"], "bytes": e["bytes"], "refused": None, "shared": False})
        save(st)
        out({"run": run}, "restore")
        return 0
    if cmd == "purge":
        execute, days = "--execute" in flags, value(flags, "--older-than-days")
        now = int(time.time())
        chosen = [r for r in st["runs"] if (rest and r["run_id"] == rest[0]) or
                  (days is not None and now - r["created_unix"] >= int(days) * 86400)]
        held = sum(e["bytes"] for r in chosen for e in r["entries"] if e["state"] == "moved")
        if execute:
            for r in chosen:
                for e in r["entries"]:
                    if e["state"] == "moved":
                        e["state"] = "purged"
            save(st)
        out({"execute": execute, "bytes": held, "freed": held if execute else 0, "runs": chosen}, "purge")
        return 0
    if cmd in ("pin", "unpin"):
        pinned = [p["root"] for p in st["projects"] if p["pinned"]]
        out({"pinned": pinned, "remotes": [], "until": {}}, "pin")
        return 0
    if cmd == "config":
        for key, flag in (("idle_days", "--idle-days"), ("dormant_days", "--dormant-days")):
            if value(flags, flag):
                st[key] = int(value(flags, flag))
        save(st)
        out({"path": HOME + "/.config/opensweep/config.toml", "idle_days": st["idle_days"],
             "dormant_days": st["dormant_days"], "pinned": [p["root"] for p in st["projects"] if p["pinned"]],
             "exclude": st["exclude"], "pinned_until": {}, "pinned_remotes": []}, "config")
        return 0
    if cmd in ("caches", "clean-cache"):
        execute = "--execute" in flags
        rows = []
        for cid, tool, name, path, b, command, note in CACHES:
            if cid in st["cleared"] and cmd == "caches":
                continue
            if cmd == "clean-cache" and cid not in rest:
                continue
            row = {"id": cid, "tool": tool, "name": name, "path": HOME + "/" + path, "bytes": b,
                   "command": command, "installed": True, "note": note, "unreadable": 0}
            if cmd == "clean-cache" and execute:
                row |= {"status": 0, "bytes_after": 0, "freed": b}
                st["cleared"].append(cid)
            rows.append(row)
        save(st)
        out({"caches": rows} | ({"execute": execute} if cmd == "clean-cache" else {}), cmd)
        return 0
    print(json.dumps({"error": "the demo engine does not know %s" % cmd}))
    return 1


if __name__ == "__main__":
    sys.exit(main())
