# OpenSweep QA checklist

Always QA against throwaway projects with `HOME` pointed at a temporary
folder, so the engine uses a throwaway config and quarantine.

## Automated walkthrough (Debug builds)

```bash
Q=$(mktemp -d); mkdir -p $Q/home $Q/work
# make a few projects in $Q/work: one old Next.js app (package.json + .next +
# node_modules), one old Rust crate (Cargo.toml + target), one recently
# edited project, one pinned with: HOME=$Q/home opensweep pin $Q/work/<name>
HOME=$Q/home OPENSWEEP_QA=$Q/out \
  build/dd/Build/Products/Debug/OpenSweep.app/Contents/MacOS/OpenSweep \
  -scanRoots "(\"$Q/work\")"
cat $Q/out/report.txt      # every line must start with PASS
open $Q/out                # window snapshots of every screen
```

Run it twice, with `OPENSWEEP_QA_APPEARANCE=light` and `=dark`, to check both
palettes whatever the system uses.

For the Caches steps, also create `$Q/home/.npm/_cacache/blob`,
`$Q/home/.gradle/caches/x`, and a stand-in `$Q/bin/npm` that removes
`$HOME/.npm/_cacache`, and launch with `PATH=$Q/bin:/usr/bin:/bin` so the real
npm is never run.

The walkthrough expects projects named `shop-web` (dormant Next.js),
`live-api` (active) and `keep-me` (pinned); see `OpenSweep/App/QAWalkthrough.swift`.

## README media

Screenshots (`docs/assets/screens`) and `docs/assets/one-click.gif` come
from a scripted demo in the Debug app against a stand-in engine with made-up
data: a 2 TB Mac with 412 projects and 1.25 TB of build folders. Nothing on
disk is read or moved.

```bash
scripts/demo/record.sh /tmp/media-dark dark          # screenshots + demo.mp4 of the window
scripts/demo/record.sh /tmp/media-light light --no-video
```

The video needs Screen Recording permission for your terminal; the app hides the
pointer while it plays. `timeline.json` lists when and where each button was
pressed. Resize screenshots with `sips -Z 1600`.

## UI tests

`xcodebuild test -project OpenSweep.xcodeproj -scheme OpenSweep -destination 'platform=macOS'`.
On a developer Mac, enable automation mode once:
`sudo automationmodetool enable-automationmode-without-authentication`.
CI runs them on macOS 15 with Xcode 16.

## By hand

| Step | Do | Expect |
| --- | --- | --- |
| 1 | Settings: add your scan folders; Overview: **Scan** | Projects appear while scanning; then Ready, Caution and active totals |
| 2 | Click **Stop** during a scan | Scan stops within a second |
| 3 | Projects: open an idle project | Safe folders ticked, Caution folders not; each row says why it is safe or kept |
| 4 | Open an active project | Nothing ticked; Review stays disabled until "Clean anyway" is on |
| 5 | Review… | The dry run lists exactly the ticked folders; nothing has moved |
| 6 | Move | Folders gone from the project; Undo brings them back |
| 7 | Pin a project | Its folders cannot be ticked; it appears under Settings → Pinned |
| 8 | History: Purge… | A confirmation shows the bytes; cancel keeps everything |
| 9 | Dev Stack | Lists tools; copy a removal command; nothing runs |
| 10 | Caches | Nothing ticked; Clear… names the exact commands; afterwards each shows freed bytes or the tool's error |
| 11 | Menu bar | Shows the last scan's total; Open and Review Projects bring the window forward; it has no clean action |
| 13 | Overview: **Review all ready** | One sheet lists every idle project's Safe folders; Move, then Undo restores all of them in one step |
| 14 | Quit and reopen | The last scan shows at once; an hour later it rescans in the background (Settings → Rescan when OpenSweep opens) |
| 12 | VoiceOver (⌘F5) on Projects | Each folder checkbox reads its name, class and size |
| 15 | Projects, keyboard only | ↑/↓ choose a project; → enters its folders; ↑/↓ and Space tick them; ← goes back |
