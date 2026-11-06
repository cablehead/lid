import NapCore
import SwiftUI

/// The "Show me" window: what is set now, and how to change it.
struct ShowMe: View {
    @ObservedObject var controller: Controller
    @State private var goals = Goal.all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("What you have now") {
                    ForEach(Explain.sentences(controller.settings), id: \.self) { Text($0) }
                    DisclosureGroup("pmset -g custom") {
                        Text(controller.rawCustom)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }

                section("Keeping it awake right now") {
                    let lines = Explain.awake(controller.assertions)
                    if lines.isEmpty { Text("Nothing.").foregroundStyle(.secondary) }
                    ForEach(lines, id: \.self) { Text($0) }
                }

                section("Change it") {
                    ForEach($goals) { $goal in GoalRow(goal: $goal, controller: controller) }
                }

                section("Lid closed on battery") {
                    Text(controller.guardian.status(now: Date()))
                    HStack {
                        Text(controller.hasPermission ? "Permission: set up." : "Permission: not set up.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if controller.hasPermission {
                            Button("Remove Nap's Permission…") { controller.removePermission() }
                        } else {
                            Button("Allow Nap to Change Sleep…") { controller.allow() }
                        }
                    }
                }

                if let message = controller.message {
                    Text(message).foregroundStyle(.red).textSelection(.enabled)
                }

                HStack {
                    Spacer()
                    Button("Refresh") { controller.refresh() }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }
}

private struct GoalRow: View {
    @Binding var goal: Goal
    @ObservedObject var controller: Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                if goal.kind == .idleSleepAfter {
                    Text("\(goal.source.label): sleep after")
                    TextField("", value: $goal.minutes, format: .number)
                        .frame(width: 44)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $goal.minutes, in: Goal.minuteRange).labelsHidden()
                    Text("min idle")
                } else {
                    Text(goal.title)
                }
                Spacer()
                if goal.isMet(by: controller.settings) {
                    Text("Already set").foregroundStyle(.secondary)
                } else {
                    Button("Apply") { controller.apply(goal) }
                        .disabled(!Goal.minuteRange.contains(goal.minutes))
                }
            }
            Text("Changes " + goal.changes.map { "\($0.key) to \($0.value)" }.joined(separator: ", ")
                 + ":  " + goal.command)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let note = goal.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
