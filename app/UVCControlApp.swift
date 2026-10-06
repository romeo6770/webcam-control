// UVCControlApp.swift — app SwiftUI para controlar webcams UVC en macOS

import SwiftUI
import AVFoundation

@main
struct UVCControlApp: App {
    @StateObject private var model = CameraModel()

    var body: some Scene {
        WindowGroup("Webcam Control") {
            ContentView().environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Vista principal

struct ContentView: View {
    @EnvironmentObject var model: CameraModel
    @State private var newProfileName = ""

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 8) {
                CameraPreview(vid: model.camera?.vid ?? 0, pid: model.camera?.pid ?? 0)
                    .frame(width: 480, height: 270)
                    .background(Color.black)
                    .cornerRadius(8)
                cameraPicker
                profilesBar
                if let e = model.error {
                    Text(e).font(.caption).foregroundColor(.red).lineLimit(3)
                }
            }
            .frame(width: 480)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    group("Exposición") {
                        autoRow("exposure", label: "Exposición", format: { String(format: "%.1f ms", Double($0) / 10) }, log: true)
                        row("gain", "Ganancia")
                        row("backlight", "Contraluz")
                        powerLine
                    }
                    group("Color") {
                        autoRow("white-balance", label: "Balance de blancos", format: { "\($0) K" })
                        row("hue", "Matiz")
                        row("saturation", "Saturación")
                    }
                    group("Imagen") {
                        row("brightness", "Brillo")
                        row("contrast", "Contraste")
                        row("gamma", "Gamma")
                        row("sharpness", "Nitidez")
                    }
                    group("Óptica") {
                        autoRow("focus", label: "Enfoque", format: { "\($0)" })
                        row("zoom", "Zoom")
                        if !model.has("focus") && !model.has("zoom") {
                            Text("Esta cámara no expone enfoque ni zoom.").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Button("Restaurar valores de fábrica") { model.resetDefaults() }
                }
                .padding(.trailing, 8)
            }
            .frame(width: 400)
        }
        .padding(16)
        .frame(minHeight: 520)
    }

    // MARK: Componentes

    private var cameraPicker: some View {
        HStack {
            Picker("Cámara", selection: $model.selected) {
                ForEach(Array(model.cameras.enumerated()), id: \.offset) { i, cam in
                    Text(cam.name).tag(i)
                }
            }
            Button("Reconectar") { model.rescan() }
        }
    }

    private var profilesBar: some View {
        HStack {
            Menu("Perfiles") {
                ForEach(model.profileNames.filter { $0 != "__auto__" }, id: \.self) { name in
                    Button(name) { model.applyProfile(named: name) }
                }
                if model.profileNames.contains("__auto__") {
                    Divider()
                    Button("Quitar perfil al conectar") { model.deleteProfile(named: "__auto__") }
                }
            }
            TextField("Nombre", text: $newProfileName).frame(width: 120)
            Button("Guardar") {
                guard !newProfileName.isEmpty else { return }
                model.saveProfile(named: newProfileName); newProfileName = ""
            }
            Button("Aplicar al conectar") { model.saveProfile(named: "__auto__") }
                .help("Guarda los valores actuales y los aplica cada vez que la app detecta esta cámara")
        }
    }

    @ViewBuilder
    private func group<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        }
    }

    @ViewBuilder
    private func row(_ name: String, _ label: String) -> some View {
        if let st = model.states[name] {
            HStack {
                Text(label).frame(width: 120, alignment: .leading)
                Slider(value: model.binding(name), in: Double(st.min)...Double(st.max))
                Text("\(st.cur)").frame(width: 56, alignment: .trailing).monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private func autoRow(_ name: String, label: String, format: @escaping (Int) -> String, log: Bool = false) -> some View {
        if let st = model.states[name] {
            let auto = model.isAuto(name)
            HStack {
                Text(label).frame(width: 120, alignment: .leading)
                if log {
                    Slider(value: model.logBinding(name),
                           in: Foundation.log(Double(max(st.min, 1)))...Foundation.log(Double(max(st.max, 1))))
                        .disabled(auto)
                } else {
                    Slider(value: model.binding(name), in: Double(st.min)...Double(st.max)).disabled(auto)
                }
                Text(format(st.cur)).frame(width: 64, alignment: .trailing).monospacedDigit()
                if autoPairs[name] != nil, model.has(autoPairs[name]!.auto) {
                    Toggle("Auto", isOn: Binding(get: { auto }, set: { model.setAuto(name, $0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }

    @ViewBuilder
    private var powerLine: some View {
        if model.has("power-line") {
            HStack {
                Text("Frecuencia de línea").frame(width: 120, alignment: .leading)
                Picker("", selection: Binding(get: { model.value("power-line") }, set: { model.setRaw("power-line", $0) })) {
                    Text("Apagado").tag(0); Text("50 Hz").tag(1); Text("60 Hz").tag(2)
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

// MARK: - Preview con AVFoundation (solo video; los ajustes van por UVC)

struct CameraPreview: NSViewRepresentable {
    let vid: Int
    let pid: Int

    func makeNSView(context: Context) -> PreviewView { PreviewView() }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.select(vid: vid, pid: pid)
    }

    final class PreviewView: NSView {
        private let session = AVCaptureSession()
        private var layerAdded = false
        private var currentKey = ""

        func select(vid: Int, pid: Int) {
            let key = "VendorID_\(vid) ProductID_\(pid)"
            guard key != currentKey else { return }
            currentKey = key
            if !layerAdded {
                wantsLayer = true
                let pl = AVCaptureVideoPreviewLayer(session: session)
                pl.videoGravity = .resizeAspect
                pl.frame = bounds
                pl.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                layer?.addSublayer(pl)
                layerAdded = true
            }
            AVCaptureDevice.requestAccess(for: .video) { granted in
                guard granted else { return }
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    session.beginConfiguration()
                    session.inputs.forEach { session.removeInput($0) }
                    let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera],
                                                                     mediaType: .video, position: .unspecified)
                    let device = discovery.devices.first { $0.modelID.contains(key) } ?? discovery.devices.first
                    if let d = device, let input = try? AVCaptureDeviceInput(device: d), session.canAddInput(input) {
                        session.addInput(input)
                    }
                    session.commitConfiguration()
                    if !session.isRunning { session.startRunning() }
                }
            }
        }
    }
}
