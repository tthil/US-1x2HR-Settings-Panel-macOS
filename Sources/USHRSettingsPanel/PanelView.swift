import SwiftUI
import USHRPanelCore
import USHRProtocol

struct PanelView: View {
    let model: PanelModel

    private var isConnected: Bool { model.connection == .connected }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if case .error(let message) = model.connection {
                banner("Device error: \(message)", systemImage: "exclamationmark.octagon.fill", color: .red)
            }
            if let message = model.lastError {
                banner(message, systemImage: "exclamationmark.triangle.fill", color: .orange)
            }
            Group {
                directMonitor
                monitorBalance
                inputs
                lineOut
                loopback
                power
            }
            .disabled(!isConnected)
        }
        .padding(20)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.model?.displayName ?? "No Device")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(statusColor)
            }
            if model.model != nil {
                HStack(spacing: 16) {
                    if let fw = model.firmware { Text("Firmware \(fw)") }
                    if let rate = model.sampleRate { Text(Self.rateText(rate)) }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        switch model.connection {
        case .noDevice: return "No Device"
        case .reading: return "Reading\u{2026}"
        case .connected: return "Connected"
        case .error: return "Error"
        }
    }

    private var statusColor: Color {
        switch model.connection {
        case .connected: return .green
        case .error: return .red
        default: return .secondary
        }
    }

    static func rateText(_ hz: UInt32) -> String {
        let khz = Double(hz) / 1000
        let text = khz == khz.rounded() ? String(Int(khz)) : String(format: "%g", khz)
        return "\(text) kHz"
    }

    private func banner(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: sections

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private var directMonitor: some View {
        section("Direct Monitor") {
            Picker("Direct Monitor", selection: Binding(
                get: { model.directMonitorStereo },
                set: { model.setDirectMonitorStereo($0) })
            ) {
                Text("Mono").tag(false)
                Text("Stereo").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var monitorBalance: some View {
        section("Monitor Balance") {
            Slider(value: Binding(
                get: { model.monitorBalance },
                set: { model.setMonitorBalance($0) }),
                in: 0...127, step: 1
            ) {
                Text("Monitor Balance")
            } minimumValueLabel: {
                Text("Input")
            } maximumValueLabel: {
                Text("Computer")
            }
            .labelsHidden()
        }
    }

    private var inputs: some View {
        section("Inputs") {
            let count = PanelCommands.inputCount(for: model.model ?? .us1x2HR)
            ForEach(1...count, id: \.self) { n in
                Toggle("Audio Input \(n)", isOn: Binding(
                    get: { model.audioInputs.indices.contains(n - 1) ? model.audioInputs[n - 1] : false },
                    set: { model.setAudioInput(n, $0) })
                )
            }
        }
    }

    private var lineOut: some View {
        section("Line Out") {
            Picker("Line Out", selection: Binding(
                get: { model.lineOut },
                set: { model.setLineOut($0) })
            ) {
                ForEach(LineOutSource.allCases.filter { $0 != .computerOut34 || model.model == .us4x4HR },
                        id: \.self) { source in
                    Text(source.label).tag(source)
                }
            }
            .labelsHidden()
        }
    }

    private var loopback: some View {
        section("Loopback") {
            Toggle("Loopback", isOn: Binding(
                get: { model.loopbackEnabled ?? false },
                set: { model.setLoopback($0) })
            )
            if model.loopbackEnabled == nil {
                caption("not read from device")
            }
            if model.loopbackEnabled == true {
                VStack(alignment: .leading, spacing: 6) {
                    Slider(value: Binding(
                        get: { model.loopbackVolume ?? 0 },
                        set: { model.setLoopbackVolume($0) }),
                        in: 0...127, step: 1
                    ) {
                        Text("Loopback Volume")
                    }
                    if model.loopbackVolume == nil {
                        caption("volume not read from device")
                    }
                    Picker("Input", selection: Binding(
                        get: { model.loopbackInStereo },
                        set: { model.setLoopbackIn(stereo: $0) })
                    ) {
                        Text("Mono").tag(false)
                        Text("Stereo").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Picker("Output", selection: Binding(
                        get: { model.loopbackOutStereo },
                        set: { model.setLoopbackOut(stereo: $0) })
                    ) {
                        Text("Mono").tag(false)
                        Text("Stereo").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    private var power: some View {
        section("Power") {
            Toggle("Auto Power Save", isOn: Binding(
                get: { model.autoPowerSave },
                set: { model.setAutoPowerSave($0) })
            )
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
