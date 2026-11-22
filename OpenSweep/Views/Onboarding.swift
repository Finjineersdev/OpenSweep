// SPDX-License-Identifier: MIT

import SwiftUI

/// First run: what a scan does, why cleaning is safe, and the one permission.
struct Onboarding: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0

    private struct Step {
        let mood: Peep.Mood
        let title: String
        let line: String
        let points: [(String, String)]
    }

    private var steps: [Step] {
        let back = model.autoFreeDays > 0
            ? "After \(model.autoFreeDays) \(model.autoFreeDays == 1 ? "day" : "days") they are deleted for good and the space comes back. Change this in Settings."
            : "They stay until you purge them in History."
        return [
            Step(mood: .happy, title: "Find what your projects left behind",
                 line: "Hi! I look through your projects for folders that rebuild on their own.",
                 points: [("magnifyingglass", "A scan only reads. It measures build output, dependencies and caches, language by language."),
                          ("square.stack.3d.up", "Installed apps, Homebrew and toolchains are never offered for cleaning."),
                          ("bolt", "Projects you touched lately are left alone unless you say otherwise.")]),
            Step(mood: .calm, title: "Every clean can be undone",
                 line: "Nothing is deleted when you clean. Folders move to a quarantine first.",
                 points: [("arrow.uturn.backward", "Undo puts them back exactly where they were, from the review or from History."),
                          ("clock", back),
                          ("checkmark.shield", "You see every folder, with the reason it is safe, before anything moves.")]),
            Step(mood: model.fullDiskAccess ? .lol : .talk, title: "One permission for the whole Mac",
                 line: model.fullDiskAccess ? "All set. I can see every folder." : "macOS asks about Desktop, Documents and each drive separately. Full Disk Access answers once.",
                 points: [("lock.open", "Open Privacy Settings, turn on OpenSweep under Full Disk Access, then come back here."),
                          ("eye.slash", "OpenSweep has no network code besides updates; nothing it reads leaves your Mac."),
                          ("folder", "Rather not? Choose folders in Settings instead; macOS will ask for each one.")]),
        ]
    }

    var body: some View {
        let s = steps[step]
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 16) {
                Peep(mood: s.mood, size: 84)
                SpeechBubble(text: s.line).id(step)
            }
            Text(s.title).font(.system(size: 28, weight: .bold)).foregroundStyle(Brand.text)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(s.points.enumerated()), id: \.offset) { i, p in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: p.0).font(.system(size: 15, weight: .semibold)).foregroundStyle(Brand.teal)
                            .frame(width: 22).accessibilityHidden(true)
                        Text(p.1).foregroundStyle(Brand.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    .entrance(i)
                }
            }
            .id(step)
            if step == 2 { access }
            Spacer(minLength: 0)
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<steps.count, id: \.self) { i in
                        Capsule().fill(i == step ? Brand.teal : Brand.hairline).frame(width: i == step ? 18 : 6, height: 6)
                    }
                }
                .accessibilityElement().accessibilityLabel("Step \(step + 1) of \(steps.count)")
                .accessibilityAddTraits(.isStaticText)
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }.buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Skip") { finish(scan: false) }.buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("onboarding.skip")
                }
                if step < steps.count - 1 {
                    Button("Next") { step += 1 }.buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("onboarding.next")
                } else {
                    Button(model.wholeDisk ? "Scan my Mac" : "Scan my folders") { finish(scan: true) }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("onboarding.scan")
                }
            }
        }
        .padding(30)
        .frame(width: 620, height: 520)
        .background(Brand.canvas)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: step)
        .onAppear { model.recheckAccess() }
    }

    private var access: some View {
        HStack(spacing: 12) {
            if model.fullDiskAccess {
                StatusChip(text: "Full Disk Access is on", systemImage: "checkmark.circle.fill", tint: Brand.green)
            } else {
                StatusChip(text: "Full Disk Access is off", systemImage: "exclamationmark.circle.fill", tint: Brand.amber)
                Button("Open Privacy Settings…") { FullDiskAccess.openSettings() }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("onboarding.access")
            }
        }
    }

    private func finish(scan: Bool) {
        UserDefaults.standard.set(true, forKey: "onboarded")
        dismiss()
        if scan && !model.scanning { model.toggleScan() }
    }
}
