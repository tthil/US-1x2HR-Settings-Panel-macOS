public enum LineOutSource: Int, CaseIterable, Sendable {
    case monitorMix, computerOut12, computerOut34

    public var label: String {
        switch self {
        case .monitorMix: return "Monitor Mix"
        case .computerOut12: return "Computer Out 1-2"
        case .computerOut34: return "Computer Out 3-4"
        }
    }

    fileprivate var source: Channel {
        switch self {
        case .monitorMix: return Channel(.directMonitorOut, 1)
        case .computerOut12: return Channel(.computerOut, 1)
        case .computerOut34: return Channel(.computerOut, 3)
        }
    }
}

/// Maps panel controls to the commands they send.
public enum PanelCommands {
    private static func mode(_ stereo: Bool) -> StereoMode { stereo ? .stereo : .mono }

    public static func directMonitor(stereo: Bool, pair: UInt8 = 1) -> [Command] {
        [.setStereo(Channel(.directMonitorOut, pair), mode(stereo))]
    }

    public static func monitorBalance(_ v: UInt8) -> [Command] {
        [.setFader(Channel(.directMonitorOut, 1), 127 - min(v, 127))]
    }

    public static func audioInput(_ n: UInt8, on: Bool) -> [Command] {
        [.setMute(Channel(.analogIn, n), on)]
    }

    public static func lineOut(_ s: LineOutSource) -> [Command] {
        let src = s.source
        return [
            .assign(source: src, destination: Channel(.lineOut, 1)),
            .assign(source: Channel(src.type, src.index + 1), destination: Channel(.lineOut, 2)),
        ]
    }

    public static func loopback(on: Bool) -> [Command] {
        [.setFader(Channel(.loopback, 0), on ? 1 : 0)]
    }

    public static func loopbackVolume(_ v: UInt8) -> [Command] {
        [.setFader(Channel(.loopback, 1), min(v, 127))]
    }

    public static func loopbackIn(stereo: Bool) -> [Command] {
        [.setStereo(Channel(.analogIn, 1), mode(stereo))]
    }

    public static func loopbackOut(stereo: Bool) -> [Command] {
        [.setStereo(Channel(.computerOut, 1), mode(stereo))]
    }

    public static func autoPowerSave(_ on: Bool) -> [Command] {
        [.setAutoPowerSave(on)]
    }

    /// Query groups for a full state read. The hardware answers only the last get of a
    /// multi-get message (observed), so each channel get is its own group.
    public static func readAll(for model: USHRModel) -> [[Command]] {
        var groups: [[Command]] = [
            [.getInfo],
            [.getSampleRate],
            [.getAutoPowerSave],
            [.getStereo(Channel(.directMonitorOut, 1))],
            [.getStereo(Channel(.analogIn, 1))],
            [.getStereo(Channel(.computerOut, 1))],
        ]
        groups += (1...UInt8(inputCount(for: model))).map { [.getMute(Channel(.analogIn, $0))] }
        groups += [[.getFader(Channel(.directMonitorOut, 1))], [.getAssign]]
        return groups
    }

    public static func inputCount(for model: USHRModel) -> Int {
        switch model {
        case .us1x2HR, .us2x2HR: return 2
        case .us4x4HR: return 4
        case .unknown: return 2
        }
    }
}
