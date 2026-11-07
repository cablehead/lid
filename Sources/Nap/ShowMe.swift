import NapCore
import SwiftUI

/// The Show me window: one table, power source by lid.
struct ShowMe: View {
    @ObservedObject var controller: Controller
    @State private var open: CellID?
    /// Snapshot only: the cell whose choices open on appear, Details and all.
    var snapshotCell: CellID?
    @State private var hovered: CellID?
    static let labelWidth: CGFloat = 84
    static let cellWidth: CGFloat = 200

    struct CellID: Hashable {
        var source: PowerSource
        var lidClosed: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // What Nap is, and the question the table answers.
            VStack(alignment: .leading, spacing: 4) {
                Text("When does your Mac go to sleep?").font(.title3.weight(.semibold))
                Text("When you stop using it, your Mac turns the display off after a while, and only then goes to sleep, unless an app is keeping it awake. Being plugged in, and closing the lid, change what happens, so this table has a box for each case: plugged in or on battery, lid open or closed. Click Change in a box to choose what happens there.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: Self.labelWidth + 2 * Self.cellWidth + 20, alignment: .leading)

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
                VStack(alignment: .leading, spacing: 2) {
                    Text("Right now, these are keeping your Mac from sleeping, whatever the table says:")
                    ForEach(awake, id: \.self) { Text("· " + $0) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            if let message = controller.message {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(18)
        .frame(width: 560)
        .task {
            guard let c = snapshotCell else { return }
            try? await Task.sleep(for: .milliseconds(300))
            open = c
        }
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
            Spacer(minLength: 2)
            HStack(spacing: 4) {
                Text(c.isDefault ? "macOS default" : "not macOS default")
                    .font(.caption2)
                    .foregroundStyle(c.isDefault ? Color.secondary : Color.orange)
                Spacer()
                Text("Change")
                    .font(.caption)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Color.accentColor)
        }
        .padding(8)
        .frame(width: Self.cellWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(hovered == id || open == id ? 0.16 : 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(c.isDefault ? Color.secondary.opacity(0.25) : Color.orange.opacity(0.6)))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = id; NSCursor.pointingHand.push() } else { if hovered == id { hovered = nil }; NSCursor.pop() }
        }
        .onTapGesture { open = id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the choices for this cell")
        .popover(isPresented: Binding(get: { open == id }, set: { if !$0 { open = nil } })) {
            CellChoices(controller: controller, source: id.source, lidClosed: id.lidClosed,
                        openDetailsLater: snapshotCell == id) { open = nil }
                .padding(14)
                .frame(width: 360)
        }
    }
}

/// The choices for one cell.
struct CellChoices: View {
    @ObservedObject var controller: Controller
    let source: PowerSource
    let lidClosed: Bool
    var done: () -> Void = {}

    enum Choice: Hashable { case macDefault, never, after, sleep, awakeFor, awakeAlways }
    @State private var choice: Choice
    @State private var minutes: Int
    @State private var details: Bool
    /// Snapshot only: pick Stay awake, then open Details, as clicks would.
    var openDetailsLater = false

    init(controller: Controller, source: PowerSource, lidClosed: Bool,
         initial: LidRule? = nil, showDetails: Bool = false, openDetailsLater: Bool = false,
         done: @escaping () -> Void = {}) {
        self.openDetailsLater = openDetailsLater
        self.controller = controller
        self.source = source
        self.lidClosed = lidClosed
        self.done = done
        _details = State(initialValue: showDetails)
        if lidClosed {
            switch initial ?? controller.guardian.rule(source) {
            case .sleep: _choice = State(initialValue: .sleep); _minutes = State(initialValue: 60)
            case .stayAwake(nil): _choice = State(initialValue: .awakeAlways); _minutes = State(initialValue: 60)
            case .stayAwake(let m?): _choice = State(initialValue: .awakeFor); _minutes = State(initialValue: m)
            }
        } else {
            let current = controller.settings.sources[source]
            let idle = current.flatMap(Table.idleMinutes)
            let isDefault = current?.sleep == Table.defaultSleepMinutes
                && current?.displaySleep == Table.defaultIdleMinutes(source)
            _choice = State(initialValue: isDefault ? .macDefault : idle == nil ? .never : .after)
            _minutes = State(initialValue: idle ?? Table.defaultIdleMinutes(source))
        }
    }

    private var goal: Goal {
        let kind: Goal.Kind = switch choice {
        case .macDefault: .macDefault
        case .never: .neverIdleSleep
        default: .idleSleepAfter
        }
        return Goal(source: source, kind: kind, minutes: minutes)
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

    private var range: ClosedRange<Int> { lidClosed ? 1...(7 * 1440) : Goal.minuteRange }


    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(source.label), lid \(lidClosed ? "closed" : "open")").font(.headline)

            Picker("", selection: $choice) {
                if lidClosed {
                    Text("Sleep at once (macOS default)").tag(Choice.sleep)
                    Text("Stay awake for a while, then sleep").tag(Choice.awakeFor)
                    if source == .ac { Text("Stay awake").tag(Choice.awakeAlways) }
                } else {
                    Text("macOS default: \(Table.defaultOpenText(source))").tag(Choice.macDefault)
                    Text("Never sleep when idle").tag(Choice.never)
                    Text("Sleep after a while idle").tag(Choice.after)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if choice == .after || choice == .awakeFor {
                HStack(spacing: 6) {
                    Text(choice == .after ? "Idle for" : "For")
                    DurationField(minutes: $minutes, range: range)
                }
                .padding(.leading, 20)
            }

            if needsPermission {
                Text("Nap needs your password once, so it can turn sleep off and back on by itself.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                // Details opens beside the panel, so the panel never changes
                // size and its button stays where it was.
                Button("Details…") { details.toggle() }
                    .popover(isPresented: $details, arrowEdge: .trailing) { detailsText }
                Spacer()
                if lidClosed && needsPermission {
                    Button("Allow…") { controller.allow() }
                        .keyboardShortcut(.defaultAction)
                } else if lidClosed {
                    Button("Set") { controller.setRule(rule, for: source); done() }
                        .disabled(!range.contains(minutes))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Apply…") { controller.apply(goal); done() }
                        .disabled(!range.contains(minutes))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .task {
            guard openDetailsLater else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if lidClosed { choice = .awakeFor }
            try? await Task.sleep(for: .milliseconds(300))
            details = true
        }
    }

    /// What the buttons run, and the sudoers file Allow adds.
    private var detailsText: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(commandText)
            if needsPermission {
                Text("Allow adds \(Sudoers.path), checked with visudo:")
                Text(controller.sudoersContents)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 440, alignment: .leading)
        .padding(14)
    }

    private var commandText: String {
        if !lidClosed { return goal.command }
        if rule.staysAwake {
            return "Now: sudo -n pmset -a disablesleep 1\nAfter \(Table.minutes(minutes)): disablesleep 0, then pmset sleepnow"
        }
        if controller.guardian.rule(source).staysAwake {
            return "Nap stops holding sleep off \(source.label.lowercased()): sudo -n pmset -a disablesleep 0"
        }
        return "Nothing to run: macOS already does this."
    }
}

/// A span of time the way Calendar's custom alert asks for one: a number with
/// a stepper, and a unit menu. Eight hours is 8 and "hours", never 480.
struct DurationField: View {
    enum Unit: Int, CaseIterable, Identifiable {
        case minutes = 1, hours = 60, days = 1440
        var id: Int { rawValue }
        func name(_ n: Int) -> String {
            switch self {
            case .minutes: n == 1 ? "minute" : "minutes"
            case .hours: n == 1 ? "hour" : "hours"
            case .days: n == 1 ? "day" : "days"
            }
        }
    }

    @Binding var minutes: Int
    let range: ClosedRange<Int>
    @State private var amount: Int
    @State private var unit: Unit

    init(minutes: Binding<Int>, range: ClosedRange<Int>) {
        _minutes = minutes
        self.range = range
        let m = minutes.wrappedValue
        // The largest unit the span is a whole number of: 480 shows as 8 hours.
        let u = Unit.allCases.reversed().first { m >= $0.rawValue && m % $0.rawValue == 0 } ?? .minutes
        _amount = State(initialValue: m / u.rawValue)
        _unit = State(initialValue: u)
    }

    private var units: [Unit] { Unit.allCases.filter { $0.rawValue <= range.upperBound } }
    private var amounts: ClosedRange<Int> { 1...max(1, range.upperBound / unit.rawValue) }

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: $amount, format: .number)
                .frame(width: 44)
                .multilineTextAlignment(.trailing)
            Stepper("", value: $amount, in: amounts).labelsHidden()
            Picker("", selection: $unit) {
                ForEach(units) { Text($0.name(amount)).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .onChange(of: amount) { minutes = amount * unit.rawValue }
        .onChange(of: unit) {
            amount = min(amount, amounts.upperBound)
            minutes = amount * unit.rawValue
        }
    }
}
