import Foundation
import IOKit.ps

/// Battery and Low Power Mode, for the indexing mode's power policy (IndexingMode.effective).
/// `onChange` runs on the main thread when either changes.
@MainActor
final class PowerState {
    var onChange: (() -> Void)?
    private var source: CFRunLoopSource?
    private var observer: NSObjectProtocol?

    var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    var lowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    func start() {
        observer = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        // Power source changes (plugged in, unplugged): a C callback with this object as context.
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let state = Unmanaged<PowerState>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { state.onChange?() }
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }
}
