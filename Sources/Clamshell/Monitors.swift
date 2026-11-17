import AppKit
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import ClamshellCore

/// iokit_family_msg(sub_iokit_powermanagement, 0x100): IOPMrootDomain sends it
/// to general-interest clients when the lid opens or closes.
let kIOPMMessageClamshellStateChange: UInt32 = 0xE003_4100

/// Lid open/closed, from IOPMrootDomain interest notifications. No polling:
/// the property is read once at start and again only when a message arrives.
@MainActor
final class LidMonitor {
    private let root: io_service_t
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    }

    /// AppleClamshellState: true when the lid is closed.
    var isClosed: Bool {
        guard root != 0,
              let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        else { return false }
        return (value.takeRetainedValue() as? Bool) ?? false
    }

    func start() {
        guard root != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            NSLog("Clamshell: IOPMrootDomain not found; lid changes will not be seen")
            return
        }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let status = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { refcon, _, messageType, _ in
            guard messageType == kIOPMMessageClamshellStateChange, let refcon else { return }
            let monitor = Unmanaged<LidMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.changed() }
        }, refcon, &notifier)
        if status != KERN_SUCCESS { NSLog("Clamshell: interest notification failed: \(status)") }
    }

    /// Also called on wake and on screen changes (the built-in display goes
    /// away when the lid closes), as a second event source.
    func changed() {
        onChange(isClosed)
    }
}

/// Power source and battery level, from IOPS notifications.
@MainActor
final class PowerMonitor {
    struct Reading: Equatable {
        var onBattery: Bool
        var percent: Int?
    }

    private let onChange: (Reading) -> Void
    private var source: CFRunLoopSource?

    init(onChange: @escaping (Reading) -> Void) {
        self.onChange = onChange
    }

    static func read() -> Reading {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var reading = Reading(onBattery: type == kIOPSBatteryPowerValue, percent: nil)
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            reading.percent = current * 100 / max
        }
        return reading
    }

    func start() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.onChange(PowerMonitor.read()) }
        }, refcon)?.takeRetainedValue() else {
            NSLog("Clamshell: power source notifications unavailable")
            return
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
}

extension ProcessInfo.ThermalState {
    var level: LidGuard.Thermal {
        switch self {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical
        }
    }
}
