import NapCore
import SwiftUI

/// The Show me window: one table, power source by lid.
struct ShowMe: View {
    @ObservedObject var controller: Controller
    @State private var open: CellID?
    static let labelWidth: CGFloat = 84
    static let cellWidth: CGFloat = 200

    struct CellID: Hashable {
        var source: PowerSource
        var lidClosed: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Color.clear.frame(width: Self.labelWidth, height: 1)
                    Text("lid open").font(.headline).frame(width: Self.cellWidth, alignment: .leading)
                    Text("lid closed").font(.headline).frame(width: Self.cellWidth, alignment: .leading)
                }
                ForEach([PowerSource.ac, .battery], id: \.self) { source in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.label.lowercased()).font(.headline)
                            if controller.guardian.source == source {
                                Text("now").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: Self.labelWidth, alignment: .leading)
                        cell(CellID(source: source, lidClosed: false))
                        cell(CellID(source: source, lidClosed: true))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let bar = Table.bar(controller.guardian) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bar[0]).font(.body.weight(.semibold))
                    Text(bar[1]).font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
            }

            let awake = Table.awakeLines(controller.assertions)
            if !awake.isEmpty {
                Text("Keeping it awake right now: " + awake.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let message = controller.message {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(18)
        .frame(width: 560)
    }

    private func cell(_ id: CellID) -> some View {
        let c = id.lidClosed
            ? Table.closedCell(id.source, rule: controller.guardian.rule(id.source),
                               batteryFloor: controller.guardian.batteryFloor,
                               foreignDisableSleep: controller.foreignDisableSleep)
            : Table.openCell(id.source, settings: controller.settings, rule: controller.guardian.rule(id.source),
                             foreignDisableSleep: controller.foreignDisableSleep)
        return VStack(alignment: .leading, spacing: 3) {
            Text(c.text).fixedSize(horizontal: false, vertical: true)
            if let detail = c.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !c.isDefault {
                Text("not macOS default").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(8)
        .frame(width: Self.cellWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(c.isDefault ? Color.clear : Color.orange.opacity(0.6)))
        .contentShape(Rectangle())
        .onTapGesture { open = id }
        .popover(isPresented: Binding(get: { open == id }, set: { if !$0 { open = nil } })) {
            CellChoices(controller: controller, source: id.source, lidClosed: id.lidClosed) { open = nil }
                .padding(14)
                .frame(width: 340)
        }
    }
}

/// The choices for one cell.
struct CellChoices: View {
    @ObservedObject var controller: Controller
    let source: PowerSource
    let lidClosed: Bool
    var done: () -> Void = {}

    enum Choice: Hashable { case never, after, sleep, awakeFor, awakeAlways }
    @State private var choice: Choice
    @State private var minutes: Int

    init(controller: Controller, source: PowerSource, lidClosed: Bool,
         initial: LidRule? = nil, done: @escaping () -> Void = {}) {
        self.controller = controller
        self.source = source
        self.lidClosed = lidClosed
        self.done = done
        if lidClosed {
            switch initial ?? controller.guardian.rule(source) {
            case .sleep: _choice = State(initialValue: .sleep); _minutes = State(initialValue: 60)
            case .stayAwake(nil): _choice = State(initialValue: .awakeAlways); _minutes = State(initialValue: 60)
            case .stayAwake(let m?): _choice = State(initialValue: .awakeFor); _minutes = State(initialValue: m)
            }
        } else {
            let idle = controller.settings.sources[source].flatMap(Table.idleMinutes)
            _choice = State(initialValue: idle == nil ? .never : .after)
            _minutes = State(initialValue: idle ?? Table.defaultIdleMinutes(source))
        }
    }

    private var goal: Goal {
        Goal(source: source, kind: choice == .never ? .neverIdleSleep : .idleSleepAfter, minutes: minutes)
    }

    private var rule: LidRule {
        switch choice {
        case .awakeFor: .stayAwake(minutes: minutes)
        case .awakeAlways: .stayAwake(minutes: nil)
        default: .sleep
        }
    }

    private var needsPermission: Bool {
        lidClosed && rule.staysAwake && !controller.hasPermission
    }

    private var range: ClosedRange<Int> { lidClosed ? 1...720 : Goal.minuteRange }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(source.label), lid \(lidClosed ? "closed" : "open")").font(.headline)

            Picker("", selection: $choice) {
                if lidClosed {
                    Text("Sleep at once (macOS default)").tag(Choice.sleep)
                    Text("Stay awake N min, then sleep").tag(Choice.awakeFor)
                    if source == .ac { Text("Stay awake").tag(Choice.awakeAlways) }
                } else {
                    Text("Never sleep when idle").tag(Choice.never)
                    Text("Sleep after N min idle").tag(Choice.after)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if choice == .after || choice == .awakeFor {
                HStack(spacing: 4) {
                    Text("N =")
                    TextField("", value: $minutes, format: .number)
                        .frame(width: 48)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $minutes, in: range).labelsHidden()
                    Text("min")
                }
            }

            Text(commandText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if needsPermission {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Once: let Nap turn sleep off and on without asking for your password. It adds \(Sudoers.path), checked with visudo:")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(controller.sudoersContents)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1)))
                    Button("Allow…") { controller.allow() }
                }
            }

            HStack {
                Spacer()
                if lidClosed {
                    Button("Set") { controller.setRule(rule, for: source); done() }
                        .disabled(needsPermission || !range.contains(minutes))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Apply…") { controller.apply(goal); done() }
                        .disabled(!range.contains(minutes))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var commandText: String {
        if !lidClosed { return goal.command }
        if rule.staysAwake {
            return "Nap: sudo -n pmset -a disablesleep 1 now; at the end disablesleep 0, then pmset sleepnow"
        }
        return "No command: macOS does this when Nap holds nothing."
    }
}
