// UVC.swift — motor de control UVC vía IOKit (compartido con el CLI uvcctl)

import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

// MARK: - UUIDs de IOUSBLib (los macros no se importan a Swift)

let uuidPlugIn = CFUUIDGetConstantUUIDWithBytes(kCFAllocatorDefault,
    0xC2,0x44,0xE8,0x58,0x10,0x9C,0x11,0xD4,0x91,0xD4,0x00,0x50,0xE4,0xC6,0x42,0x6F)!
let uuidDeviceUserClient = CFUUIDGetConstantUUIDWithBytes(kCFAllocatorDefault,
    0x9d,0xc7,0xb7,0x80,0x9e,0xc0,0x11,0xD4,0xa5,0x4f,0x00,0x0a,0x27,0x05,0x28,0x61)!
let uuidDeviceInterface = CFUUIDGetConstantUUIDWithBytes(kCFAllocatorDefault,
    0x5c,0x81,0x87,0xd0,0x9e,0xf3,0x11,0xD4,0x8b,0x45,0x00,0x0a,0x27,0x05,0x28,0x61)!
let uuidInterfaceUserClient = CFUUIDGetConstantUUIDWithBytes(kCFAllocatorDefault,
    0x2d,0x97,0x86,0xc6,0x9e,0xf3,0x11,0xD4,0xad,0x51,0x00,0x0a,0x27,0x05,0x28,0x61)!
let uuidInterfaceInterface = CFUUIDGetConstantUUIDWithBytes(kCFAllocatorDefault,
    0x73,0xc9,0x7a,0xe8,0x9e,0xf3,0x11,0xD4,0xb1,0xd0,0x00,0x0a,0x27,0x05,0x28,0x61)!

typealias PlugIn = UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>
typealias DevIf  = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>
typealias IntfIf = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface>?>

func queryInterface<T>(_ plugin: PlugIn, _ id: CFUUID) -> UnsafeMutablePointer<UnsafeMutablePointer<T>?>? {
    var result: UnsafeMutablePointer<UnsafeMutablePointer<T>?>?
    let hr = withUnsafeMutablePointer(to: &result) {
        $0.withMemoryRebound(to: Optional<LPVOID>.self, capacity: 1) {
            plugin.pointee!.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(id), $0)
        }
    }
    return hr == 0 ? result : nil
}

func property<T>(_ service: io_service_t, _ key: String) -> T? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? T
}

// MARK: - Tabla de controles UVC

enum Unit { case camera, processing }

struct Control {
    let name: String
    let selector: UInt8
    let unit: Unit
    let length: Int
    let signed: Bool
    let bit: Int          // bit en bmControls del descriptor
    let help: String
}

let controls: [Control] = [
    // Camera Terminal
    Control(name: "exposure-auto", selector: 0x02, unit: .camera, length: 1, signed: false, bit: 1,
            help: "1=manual 2=auto 4=prioridad obturador 8=prioridad apertura"),
    Control(name: "exposure", selector: 0x04, unit: .camera, length: 4, signed: false, bit: 3,
            help: "tiempo de exposición, unidades de 100 µs"),
    Control(name: "focus", selector: 0x06, unit: .camera, length: 2, signed: false, bit: 5,
            help: "enfoque absoluto"),
    Control(name: "focus-auto", selector: 0x08, unit: .camera, length: 1, signed: false, bit: 17,
            help: "1=auto 0=manual"),
    Control(name: "zoom", selector: 0x0B, unit: .camera, length: 2, signed: false, bit: 9,
            help: "zoom absoluto"),
    // Processing Unit
    Control(name: "brightness", selector: 0x02, unit: .processing, length: 2, signed: true, bit: 0, help: "brillo"),
    Control(name: "contrast", selector: 0x03, unit: .processing, length: 2, signed: false, bit: 1, help: "contraste"),
    Control(name: "hue", selector: 0x06, unit: .processing, length: 2, signed: true, bit: 2, help: "matiz"),
    Control(name: "saturation", selector: 0x07, unit: .processing, length: 2, signed: false, bit: 3, help: "saturación"),
    Control(name: "sharpness", selector: 0x08, unit: .processing, length: 2, signed: false, bit: 4, help: "nitidez"),
    Control(name: "gamma", selector: 0x09, unit: .processing, length: 2, signed: false, bit: 5, help: "gamma"),
    Control(name: "white-balance", selector: 0x0A, unit: .processing, length: 2, signed: false, bit: 6, help: "temperatura de color (K)"),
    Control(name: "white-balance-auto", selector: 0x0B, unit: .processing, length: 1, signed: false, bit: 12, help: "1=auto 0=manual"),
    Control(name: "backlight", selector: 0x01, unit: .processing, length: 2, signed: false, bit: 8, help: "compensación contraluz"),
    Control(name: "gain", selector: 0x04, unit: .processing, length: 2, signed: false, bit: 9, help: "ganancia"),
    Control(name: "power-line", selector: 0x05, unit: .processing, length: 1, signed: false, bit: 10, help: "0=off 1=50Hz 2=60Hz"),
]

enum Req: UInt8 {
    case setCur = 0x01, getCur = 0x81, getMin = 0x82, getMax = 0x83, getRes = 0x84, getInfo = 0x86, getDef = 0x87
}

struct UVCError: Error, CustomStringConvertible {
    let msg: String
    var description: String { msg }
}

func hex(_ r: IOReturn) -> String { String(format: "0x%08x", UInt32(bitPattern: r)) }

func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
    let fill = String(repeating: " ", count: max(0, w - s.count))
    return right ? fill + s : s + fill
}
func row(_ cols: [String]) -> String {
    pad(cols[0], 20) + cols[1...5].map { pad($0, 8, right: true) }.joined() + "  " + cols[6]
}

// MARK: - Cámara

final class Camera {
    let service: io_service_t
    let name: String
    let vid: Int
    let pid: Int

    private var plugin: PlugIn?
    private var dev: DevIf?
    private var intfPlugin: PlugIn?
    private var intf: IntfIf?
    private var opened = false

    private(set) var interfaceNumber: UInt8 = 0
    private(set) var cameraTerminalID: UInt8 = 0
    private(set) var processingUnitID: UInt8 = 0
    private(set) var ctControls: UInt64 = 0
    private(set) var puControls: UInt64 = 0
    private(set) var hasVideoControl = false

    init?(service: io_service_t) {
        self.service = service
        self.name = property(service, "USB Product Name") ?? "USB Device"
        self.vid = property(service, "idVendor") ?? 0
        self.pid = property(service, "idProduct") ?? 0

        var score: Int32 = 0
        var p: PlugIn?
        guard IOCreatePlugInInterfaceForService(service, uuidDeviceUserClient, uuidPlugIn, &p, &score) == kIOReturnSuccess,
              let plugin = p else { return nil }
        self.plugin = plugin
        guard let dev: DevIf = queryInterface(plugin, uuidDeviceInterface) else { return nil }
        self.dev = dev
        parseDescriptors()
        if !hasVideoControl { return nil }
    }

    deinit { close() }

    // Recorre el descriptor de configuración para encontrar la interfaz
    // VideoControl y los IDs del Camera Terminal y Processing Unit.
    private func parseDescriptors() {
        guard let dev = dev else { return }
        var descPtr: IOUSBConfigurationDescriptorPtr?
        guard dev.pointee!.pointee.GetConfigurationDescriptorPtr(dev, 0, &descPtr) == kIOReturnSuccess,
              let desc = descPtr else { return }
        let base = UnsafeRawPointer(desc).assumingMemoryBound(to: UInt8.self)
        let total = Int(UInt16(littleEndian: desc.pointee.wTotalLength))
        var off = 0
        var inVC = false
        while off + 2 <= total {
            let len = Int(base[off]); let type = base[off + 1]
            if len == 0 { break }
            if type == 0x04 { // INTERFACE
                inVC = base[off + 5] == 0x0E && base[off + 6] == 0x01
                if inVC { interfaceNumber = base[off + 2]; hasVideoControl = true }
            } else if inVC && type == 0x24 { // CS_INTERFACE
                let sub = base[off + 2]
                if sub == 0x02, len >= 16 { // VC_INPUT_TERMINAL
                    let ttype = UInt16(base[off + 4]) | (UInt16(base[off + 5]) << 8)
                    if ttype == 0x0201 { // ITT_CAMERA
                        cameraTerminalID = base[off + 3]
                        ctControls = readBitmap(base, off + 15, Int(base[off + 14]))
                    }
                } else if sub == 0x05, len >= 8 { // VC_PROCESSING_UNIT
                    processingUnitID = base[off + 3]
                    puControls = readBitmap(base, off + 8, Int(base[off + 7]))
                }
            }
            off += len
        }
    }

    private func readBitmap(_ p: UnsafePointer<UInt8>, _ start: Int, _ size: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<min(size, 8) { v |= UInt64(p[start + i]) << (8 * i) }
        return v
    }

    private enum Mode { case none, device, interface }
    private var mode: Mode = .none

    // 1) Abre el dispositivo y manda los requests por el endpoint 0 del device.
    //    El driver UVC de macOS reclama la interfaz, pero no el dispositivo.
    // 2) Si eso falla, intenta abrir la interfaz VideoControl directamente.
    func open() throws {
        if opened { return }
        guard let dev = dev else { throw UVCError(msg: "sin device interface") }

        var kr = dev.pointee!.pointee.USBDeviceOpen(dev)
        if kr != kIOReturnSuccess { kr = dev.pointee!.pointee.USBDeviceOpenSeize(dev) }
        if kr == kIOReturnSuccess {
            mode = .device; opened = true
            return
        }
        let devErr = hex(kr)

        var req = IOUSBFindInterfaceRequest(bInterfaceClass: 0x0E, bInterfaceSubClass: 0x01,
                                            bInterfaceProtocol: UInt16(kIOUSBFindInterfaceDontCare),
                                            bAlternateSetting: UInt16(kIOUSBFindInterfaceDontCare))
        var iter: io_iterator_t = 0
        guard dev.pointee!.pointee.CreateInterfaceIterator(dev, &req, &iter) == kIOReturnSuccess else {
            throw UVCError(msg: "no se pudo iterar interfaces")
        }
        defer { IOObjectRelease(iter) }
        let svc = IOIteratorNext(iter)
        guard svc != 0 else { throw UVCError(msg: "no se encontró interfaz VideoControl") }
        defer { IOObjectRelease(svc) }

        var score: Int32 = 0
        var p: PlugIn?
        guard IOCreatePlugInInterfaceForService(svc, uuidInterfaceUserClient, uuidPlugIn, &p, &score) == kIOReturnSuccess,
              let plugin = p else { throw UVCError(msg: "plugin de interfaz falló") }
        intfPlugin = plugin
        guard let intf: IntfIf = queryInterface(plugin, uuidInterfaceInterface) else {
            throw UVCError(msg: "QueryInterface (interfaz) falló")
        }
        self.intf = intf
        var num: UInt8 = 0
        _ = intf.pointee!.pointee.GetInterfaceNumber(intf, &num)
        interfaceNumber = num

        kr = intf.pointee!.pointee.USBInterfaceOpen(intf)
        if kr != kIOReturnSuccess { kr = intf.pointee!.pointee.USBInterfaceOpenSeize(intf) }
        if kr != kIOReturnSuccess {
            throw UVCError(msg: "no se pudo abrir la cámara: USBDeviceOpen \(devErr), USBInterfaceOpen \(hex(kr))")
        }
        mode = .interface; opened = true
    }

    func close() {
        if let intf = intf {
            if mode == .interface { _ = intf.pointee!.pointee.USBInterfaceClose(intf) }
            _ = intf.pointee!.pointee.Release(intf)
            self.intf = nil
        }
        if let p = intfPlugin { IODestroyPlugInInterface(p); intfPlugin = nil }
        if let dev = dev {
            if mode == .device { _ = dev.pointee!.pointee.USBDeviceClose(dev) }
            _ = dev.pointee!.pointee.Release(dev); self.dev = nil
        }
        if let p = plugin { IODestroyPlugInInterface(p); plugin = nil }
        opened = false; mode = .none
    }

    func unitID(_ c: Control) -> UInt8 {
        c.unit == .camera ? cameraTerminalID : processingUnitID
    }

    func supported(_ c: Control) -> Bool {
        let mask = c.unit == .camera ? ctControls : puControls
        return mask & (1 << UInt64(c.bit)) != 0
    }

    // Transferencia de control UVC sobre el endpoint 0
    private func request(_ r: Req, _ c: Control, data: inout [UInt8]) throws {
        try open()
        let isGet = r != .setCur
        var req = IOUSBDevRequest()
        req.bmRequestType = isGet ? 0xA1 : 0x21
        req.bRequest = r.rawValue
        req.wValue = UInt16(c.selector) << 8
        req.wIndex = (UInt16(unitID(c)) << 8) | UInt16(interfaceNumber)
        req.wLength = UInt16(data.count)
        let kr: IOReturn = data.withUnsafeMutableBytes { buf in
            req.pData = buf.baseAddress
            switch mode {
            case .device:    return dev!.pointee!.pointee.DeviceRequest(dev, &req)
            case .interface: return intf!.pointee!.pointee.ControlRequest(intf, 0, &req)
            case .none:      return IOReturn(bitPattern: 0xe00002cd) // kIOReturnNotOpen
            }
        }
        if kr != kIOReturnSuccess {
            throw UVCError(msg: "\(c.name): request \(String(format: "0x%02x", r.rawValue)) falló (\(hex(kr)))")
        }
    }

    func get(_ r: Req, _ c: Control) throws -> Int {
        var buf = [UInt8](repeating: 0, count: c.length)
        try request(r, c, data: &buf)
        var u: UInt32 = 0
        for (i, b) in buf.enumerated() { u |= UInt32(b) << (8 * UInt32(i)) }
        if c.signed {
            let bits = UInt32(c.length * 8)
            if bits < 32 && u & (1 << (bits - 1)) != 0 { return Int(Int32(bitPattern: u | (~0 << bits))) }
            return Int(Int32(bitPattern: u))
        }
        return Int(u)
    }

    func info(_ c: Control) throws -> UInt8 {
        var buf = [UInt8](repeating: 0, count: 1)
        try request(.getInfo, c, data: &buf)
        return buf[0]
    }

    func set(_ c: Control, _ value: Int) throws {
        let u = UInt32(truncatingIfNeeded: value)
        var buf = (0..<c.length).map { UInt8((u >> (8 * UInt32($0))) & 0xFF) }
        try request(.setCur, c, data: &buf)
    }
}

// MARK: - Descubrimiento

func findCameras() -> [Camera] {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBDevice"), &iter) == kIOReturnSuccess else {
        return []
    }
    defer { IOObjectRelease(iter) }
    var cams: [Camera] = []
    while true {
        let svc = IOIteratorNext(iter)
        if svc == 0 { break }
        if let cam = Camera(service: svc) { cams.append(cam) } else { IOObjectRelease(svc) }
    }
    return cams
}
