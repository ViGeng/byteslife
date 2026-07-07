import Foundation
import IOKit

/// Reads the machine's instantaneous power draw from IOKit, the permission-free primitive behind the
/// Energy Account. It exposes only a scalar wattage, never anything identifying.
///
/// Portables expose an `AppleSmartBattery` service whose `Amperage` (mA, signed) and `Voltage` (mV)
/// give the instantaneous battery power, `|amperage| * voltage`, whether charging or discharging. A
/// desktop with no battery has no such service and no wattage signal, so the reader returns nil and the
/// collector degrades to `sourceMissing` honestly rather than inventing a number.
public enum PowerSource {
    /// Instantaneous power in milliwatts, or nil when the machine exposes no battery power signal.
    public static func milliwatts() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"), &iterator
        ) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let amperage = (dictionary["Amperage"] as? NSNumber)?.int64Value,
                  let voltage = (dictionary["Voltage"] as? NSNumber)?.int64Value else {
                continue
            }
            // Amperage is signed (negative while discharging); the magnitude is the draw either way.
            // mA * mV = microwatts, so divide by 1,000 to reach milliwatts.
            return Double(abs(amperage)) * Double(voltage) / 1_000.0
        }
        return nil
    }
}
