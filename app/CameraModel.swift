// CameraModel.swift — estado observable para la UI

import Foundation
import SwiftUI

struct ControlState: Identifiable {
    let control: Control
    var id: String { control.name }
    var cur: Int
    let min: Int
    let max: Int
    let def: Int
}

// Control manual -> (control auto, valor que significa "manual")
let autoPairs: [String: (auto: String, manual: Int)] = [
    "exposure": ("exposure-auto", 1),
    "focus": ("focus-auto", 0),
    "white-balance": ("white-balance-auto", 0),
]

@MainActor
final class CameraModel: ObservableObject {
    @Published var cameras: [Camera] = []
    @Published var selected: Int = 0 { didSet { load() } }
    @Published var states: [String: ControlState] = [:]
    @Published var error: String?
    @Published var profileNames: [String] = []

    var camera: Camera? { cameras.indices.contains(selected) ? cameras[selected] : nil }
    var supportedControls: [ControlState] {
        controls.compactMap { states[$0.name] }
    }

    init() { rescan() }

    func rescan() {
        cameras.forEach { $0.close() }
        cameras = findCameras()
        selected = 0
        load()
    }

    func load() {
        states = [:]
        error = nil
        guard let cam = camera else { return }
        do {
            try cam.open()
            for c in controls where cam.supported(c) {
                let cur = try cam.get(.getCur, c)
                let mn = (try? cam.get(.getMin, c)) ?? 0
                let mx = (try? cam.get(.getMax, c)) ?? 0
                let df = (try? cam.get(.getDef, c)) ?? cur
                states[c.name] = ControlState(control: c, cur: cur, min: mn, max: mx, def: df)
            }
        } catch {
            self.error = "\(error)"
        }
        profileNames = loadProfiles().keys.sorted()
        applyProfile(named: "__auto__")
    }

    func has(_ name: String) -> Bool { states[name] != nil }
    func value(_ name: String) -> Int { states[name]?.cur ?? 0 }
    func isAuto(_ name: String) -> Bool {
        guard let pair = autoPairs[name] else { return false }
        return value(pair.auto) != pair.manual
    }

    func set(_ name: String, _ v: Int) {
        guard let cam = camera, let st = states[name] else { return }
        // Al mover un slider manual, salir del modo auto primero.
        if let pair = autoPairs[name], isAuto(name) {
            setRaw(pair.auto, pair.manual)
        }
        let clamped = Swift.min(Swift.max(v, st.min), st.max)
        do {
            try cam.set(st.control, clamped)
            states[name]?.cur = clamped
        } catch { self.error = "\(error)" }
    }

    // Escribe sin tocar modos auto (para toggles y perfiles).
    // Si el control está bajo modo auto, la cámara rechaza la escritura (stall): se omite.
    func setRaw(_ name: String, _ v: Int) {
        guard let cam = camera, let st = states[name] else { return }
        if autoPairs[name] != nil, isAuto(name) { return }
        do {
            try cam.set(st.control, v)
            states[name]?.cur = v
            error = nil
        } catch { self.error = "\(error)" }
    }

    /// Aplica un conjunto de valores respetando el orden que exige UVC:
    /// autos -> manual, valores manuales, y al final los modos auto deseados.
    private func apply(_ values: [String: Int]) {
        for (_, pair) in autoPairs where states[pair.auto] != nil { setRaw(pair.auto, pair.manual) }
        for (k, v) in values where !k.hasSuffix("-auto") { setRaw(k, v) }
        for (k, v) in values where k.hasSuffix("-auto") { setRaw(k, v) }
    }

    func setAuto(_ name: String, _ on: Bool) {
        guard let pair = autoPairs[name], let autoSt = states[pair.auto] else { return }
        // Para exposure-auto, "auto" = prioridad de apertura (8) o auto (2); usa el default o el máximo válido.
        let autoVal = pair.auto == "exposure-auto" ? (autoSt.def != pair.manual ? autoSt.def : 8) : 1
        setRaw(pair.auto, on ? autoVal : pair.manual)
        // Al volver a manual, refrescar el valor actual que dejó el auto.
        if !on, let cam = camera, let st = states[name], let cur = try? cam.get(.getCur, st.control) {
            states[name]?.cur = cur
        }
    }

    func resetDefaults() {
        apply(Dictionary(uniqueKeysWithValues: supportedControls.map { ($0.id, $0.def) }))
    }

    func binding(_ name: String) -> Binding<Double> {
        Binding(get: { Double(self.value(name)) }, set: { self.set(name, Int($0.rounded())) })
    }

    /// Slider logarítmico (para exposición: 1–5000).
    func logBinding(_ name: String) -> Binding<Double> {
        Binding(get: { log(Double(Swift.max(self.value(name), 1))) },
                set: { self.set(name, Int(exp($0).rounded())) })
    }

    // MARK: Perfiles (UserDefaults, por VID:PID). "__auto__" se aplica al conectar.

    private var profileKey: String {
        guard let cam = camera else { return "profiles" }
        return String(format: "profiles-%04x:%04x", cam.vid, cam.pid)
    }

    private func loadProfiles() -> [String: [String: Int]] {
        UserDefaults.standard.dictionary(forKey: profileKey) as? [String: [String: Int]] ?? [:]
    }

    func saveProfile(named name: String) {
        var p = loadProfiles()
        p[name] = Dictionary(uniqueKeysWithValues: supportedControls.map { ($0.id, $0.cur) })
        UserDefaults.standard.set(p, forKey: profileKey)
        profileNames = p.keys.sorted()
    }

    func deleteProfile(named name: String) {
        var p = loadProfiles()
        p[name] = nil
        UserDefaults.standard.set(p, forKey: profileKey)
        profileNames = p.keys.sorted()
    }

    func applyProfile(named name: String) {
        guard let p = loadProfiles()[name] else { return }
        apply(p)
    }
}
