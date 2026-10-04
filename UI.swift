import SwiftUI
import ServiceManagement

// Shared state between the boost engine (LumosApp) and the SwiftUI controls.
@Observable final class Model {
    var enabled = true
    var boost = min(UserDefaults.standard.object(forKey: "boost") as? Double ?? 1.4, 1.8) {
        didSet { UserDefaults.standard.set(boost, forKey: "boost") }
    }
    var showIcon = !UserDefaults.standard.bool(forKey: "hideIcon") {
        didSet {
            UserDefaults.standard.set(!showIcon, forKey: "hideIcon")
            onShowIconChange?(showIcon)
        }
    }
    var openAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            let service = SMAppService.mainApp
            guard openAtLogin != (service.status == .enabled) else { return }
            do {
                if openAtLogin { try service.register() } else { try service.unregister() }
            } catch {
                NSLog("Lumos login item: \(error)")
            }
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            openAtLogin = service.status == .enabled
        }
    }

    // Live values, written by LumosApp.update().
    var brightness: Double = 0
    var currentBoost: Double = 1
    var isBoosting: Bool { enabled && currentBoost > 1.001 }
    var supported = true // false when no connected display has XDR headroom

    @ObservationIgnored var onShowIconChange: ((Bool) -> Void)?
    @ObservationIgnored var onQuit: (() -> Void)?
}

struct ControlsView: View {
    @Bindable var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.supported {
                intensityCard
                    .opacity(model.enabled ? 1 : 0.45)
                    .disabled(!model.enabled)
            } else {
                unsupportedCard
            }
            settingsCard
            footer
        }
        .padding(16)
        .frame(width: 310)
        .animation(.smooth(duration: 0.35), value: model.enabled)
        .animation(.smooth(duration: 0.35), value: model.isBoosting)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(model.isBoosting ? AnyShapeStyle(Color.yellow.gradient) : AnyShapeStyle(.quaternary))
                    .shadow(color: .yellow.opacity(model.isBoosting ? 0.55 : 0), radius: 10)
                Image(systemName: "wand.and.rays")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(model.isBoosting ? Color.black.opacity(0.75) : Color.secondary)
                    // One-shot, not a looping effect: a continuous animation kept the UI at ~20% CPU.
                    .symbolEffect(.bounce, value: model.isBoosting)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("Lumos").font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            Toggle("Attivo", isOn: $model.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!model.supported)
        }
    }

    private var statusText: String {
        if !model.supported { return "Display non supportato" }
        if !model.enabled { return "Disattivato" }
        if model.isBoosting { return String(format: "Luce extra attiva · %.2f×", model.currentBoost) }
        return "Si accende oltre il \(Int(LumosApp.boostStart * 100))% di luminosità"
    }

    private var unsupportedCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 22))
                .symbolRenderingMode(.multicolor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Nessun display XDR trovato").font(.subheadline.weight(.semibold))
                Text("Lumos sblocca la luminosità extra dei display Liquid Retina XDR (MacBook Pro 14\" e 16\" con M1 Pro o successivi) e del Pro Display XDR. Questo display è già al suo massimo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private var intensityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Intensità massima").font(.subheadline.weight(.medium))
                Spacer()
                Text(String(format: "%.2f×", model.boost))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: model.boost))
                    .animation(.snappy, value: model.boost)
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.min").foregroundStyle(.secondary)
                Slider(value: $model.boost, in: 1...1.8)
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(.yellow)
                    .symbolEffect(.bounce, value: model.boost >= 1.79)
            }
            BrightnessMeter(brightness: model.brightness, start: Double(LumosApp.boostStart), boosting: model.isBoosting)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private var settingsCard: some View {
        VStack(spacing: 10) {
            settingRow("Icona nella barra dei menu", symbol: "menubar.rectangle", isOn: $model.showIcon)
            Divider()
            settingRow("Apri al login", symbol: "power", isOn: $model.openAtLogin)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func settingRow(_ title: String, symbol: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Label(title, systemImage: symbol)
                .symbolRenderingMode(.hierarchical)
            Spacer()
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }

    private var footer: some View {
        HStack {
            Text("Lumos maxima").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("Esci") { model.onQuit?() }
                .keyboardShortcut("q")
                .buttonStyle(.glass)
        }
    }
}

// System brightness bar: the zone past `start` (where Lumos adds light) glows warm.
struct BrightnessMeter: View {
    var brightness: Double
    var start: Double
    var boosting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    // Boost zone hint
                    Capsule()
                        .fill(Color.orange.opacity(0.18))
                        .frame(width: w * (1 - start))
                        .offset(x: w * start)
                    Capsule()
                        .fill(LinearGradient(
                            stops: [.init(color: .gray.opacity(0.55), location: 0),
                                    .init(color: .gray.opacity(0.7), location: start),
                                    .init(color: .yellow, location: min(1, start + 0.15)),
                                    .init(color: .orange, location: 1)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: w)
                        .mask(alignment: .leading) { Capsule().frame(width: max(6, w * brightness)) }
                        .shadow(color: .orange.opacity(boosting ? 0.6 : 0), radius: 6)
                    Rectangle()
                        .fill(.secondary)
                        .frame(width: 1.5, height: 10)
                        .offset(x: w * start)
                }
            }
            .frame(height: 6)
            .animation(.smooth(duration: 0.4), value: brightness)

            HStack {
                Text("Luminosità di sistema")
                Spacer()
                Text("\(Int((brightness * 100).rounded()))%")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: brightness))
                    .animation(.snappy, value: brightness)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
