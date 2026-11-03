import Foundation

/// Remembers write-only values the device cannot report (fallback for loopback state).
public final class LastSetStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func enabledKey(_ k: String) -> String { "device.\(k).loopbackEnabled" }
    private func volumeKey(_ k: String) -> String { "device.\(k).loopbackVolume" }

    public func loopbackEnabled(_ key: String) -> Bool? {
        defaults.object(forKey: enabledKey(key)) as? Bool
    }

    public func setLoopbackEnabled(_ v: Bool, _ key: String) {
        defaults.set(v, forKey: enabledKey(key))
    }

    public func loopbackVolume(_ key: String) -> UInt8? {
        (defaults.object(forKey: volumeKey(key)) as? Int).map { UInt8(clamping: $0) }
    }

    public func setLoopbackVolume(_ v: UInt8, _ key: String) {
        defaults.set(Int(v), forKey: volumeKey(key))
    }
}
