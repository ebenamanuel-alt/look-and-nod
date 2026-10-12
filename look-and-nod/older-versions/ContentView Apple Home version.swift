//  Look and Nod Home
//  Face a light, hold Control + Option, and nod to switch it on or shake to switch it off.
//  Control + Option + Up/Down changes brightness.
//  Lights come from your Shortcuts app: make "Lamp On" and "Lamp Off" and Look and Nod
//  finds them. For dimming, add shortcuts like "Lamp 25%", "Lamp 50%" and "Lamp 100%".
//  Works with anything in Apple Home.

import SwiftUI
import CoreMotion
import Combine
import AppKit

// MARK: - Models

struct Light: Identifiable, Hashable {
    let name: String            // e.g. "Lamp", from shortcuts "Lamp On" / "Lamp Off"
    let levels: [Int]           // from shortcuts like "Lamp 25%", lowest first
    var hasBrightness: Bool { !levels.isEmpty }
    var levelList: String { levels.map { "\($0)%" }.joined(separator: ", ") }
    var id: String { name }
    var label: String { name }
}

struct Target: Codable, Identifiable {
    let device: String
    var label: String
    var yaw: Double
    var id: String { device }
}

private func wrap(_ d: Double) -> Double {
    var a = (d + 180).truncatingRemainder(dividingBy: 360)
    if a < 0 { a += 360 }
    return a - 180
}

// MARK: - Shortcuts
// Runs the macOS "shortcuts" command line tool, off the main thread.

enum ShortcutRunner {
    nonisolated static func list() async -> [String] {
        await Task.detached { () -> [String] in
            let out = Pipe()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["list"]
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return [] }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }.value
    }

    nonisolated static func run(_ name: String) async -> Bool {
        await Task.detached { () -> Bool in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["run", name]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }.value
    }

    /// Finds lights: any pair of shortcuts called "<Name> On" and "<Name> Off".
    /// Brightness levels come from shortcuts called "<Name> <number>%".
    static func lights(from names: [String]) -> [Light] {
        let set = Set(names)
        return names
            .filter { $0.hasSuffix(" On") }
            .map { String($0.dropLast(3)) }
            .filter { set.contains("\($0) Off") }
            .sorted()
            .map { light in
                let prefix = light + " "
                let levels = names.compactMap { n -> Int? in
                    guard n.hasPrefix(prefix), n.hasSuffix("%") else { return nil }
                    guard let v = Int(n.dropFirst(prefix.count).dropLast()), (1...100).contains(v) else { return nil }
                    return v
                }
                return Light(name: light, levels: Array(Set(levels)).sorted())
            }
    }
}

// MARK: - Keyboard shortcut matching
// Control + Option + Down/Up arrow. Returns -1 (dim) or +1 (brighten).
// Holding Control + Option on its own arms nod and shake.

enum KeyTap {
    nonisolated(unsafe) static var port: CFMachPort?
    nonisolated(unsafe) static var onKey: (@MainActor (Int) -> Void)?

    /// True while Control and Option are both held, in any app. Needs no permission.
    nonisolated static var armKeysHeld: Bool {
        let f = CGEventSource.flagsState(.combinedSessionState)
        return f.contains(.maskControl) && f.contains(.maskAlternate)
    }

    nonisolated static func direction(code: Int64, flags: CGEventFlags) -> Int? {
        let ctrl = flags.contains(.maskControl), opt = flags.contains(.maskAlternate)
        let cmd = flags.contains(.maskCommand), shift = flags.contains(.maskShift)
        if ctrl && opt && !cmd && !shift {
            if code == 125 { return -1 }   // Down arrow
            if code == 126 { return 1 }    // Up arrow
        }
        return nil
    }
}

// MARK: - Gesture detection
// Looks at the last second of head movement. A nod is a dip in pitch that comes back
// with little turning; a shake is at least two left/right swings that end near the start.

struct GestureDetector {
    enum Gesture { case nod, shake }
    private var samples: [(t: Double, pitch: Double, yaw: Double)] = []
    private var cooldownUntil = 0.0

    let window = 1.0
    let cooldown = 1.4
    let hysteresis = 6.0

    /// Returns the gesture and the heading the user was facing when it started.
    mutating func feed(t: Double, pitch: Double, yaw: Double) -> (Gesture, Double)? {
        samples.append((t, pitch, yaw))
        samples.removeAll { t - $0.t > window }
        guard t >= cooldownUntil, samples.count >= 8, t - samples[0].t >= 0.25 else { return nil }

        let p0 = samples[0].pitch, y0 = samples[0].yaw
        let ps = samples.map { $0.pitch }
        let ys = samples.map { wrap($0.yaw - y0) }
        let pitchRange = (ps.max() ?? 0) - (ps.min() ?? 0)
        let yawRange = (ys.max() ?? 0) - (ys.min() ?? 0)
        let maxDip = ps.map { abs($0 - p0) }.max() ?? 0

        var found: Gesture?
        if reversals(ps) >= 1, maxDip >= 10, abs(ps.last! - p0) <= 5, yawRange <= 10 {
            found = .nod
        } else if reversals(ys) >= 2, yawRange >= 16, pitchRange <= 12, abs(ys.last!) <= 8 {
            found = .shake
        }
        guard let g = found else { return nil }
        cooldownUntil = t + cooldown
        samples.removeAll()
        return (g, y0)
    }

    mutating func reset() { samples.removeAll() }

    private func reversals(_ v: [Double]) -> Int {
        guard var ext = v.first else { return 0 }
        var dir = 0, count = 0
        for x in v.dropFirst() {
            switch dir {
            case 0:
                if x - ext > hysteresis { dir = 1; ext = x } else if ext - x > hysteresis { dir = -1; ext = x }
            case 1:
                if x > ext { ext = x } else if ext - x > hysteresis { dir = -1; ext = x; count += 1 }
            default:
                if x < ext { ext = x } else if x - ext > hysteresis { dir = 1; ext = x; count += 1 }
            }
        }
        return count
    }
}

// MARK: - Controller

@MainActor
final class LookAndNod: NSObject, ObservableObject, CMHeadphoneMotionManagerDelegate {
    @Published var airpodsConnected = false
    @Published var lights: [Light] = []
    @Published var targets: [Target] = [] { didSet { saveTargets() } }
    @Published var yaw = 0.0
    @Published var pitch = 0.0
    @Published var facing: Target?
    @Published var message = "Face your screen and press Recentre."
    @Published var flash: String?
    @Published var enabled = true
    @Published var levels: [String: Int] = [:]
    @Published var armed = false
    @Published var shortcutEverywhere = false
    @Published var scanned = false

    let tolerance = 22.0
    private let motion = CMHeadphoneMotionManager()
    private var detector = GestureDetector()
    private var rawYaw = 0.0
    private var centre = 0.0
    private var pollTimer: Timer?
    private var started = false
    private var lastDevice: String?
    private var busy: Set<String> = []          // lights with a brightness shortcut running
    private var pendingLevel: [String: Int] = [:]
    private var keyMonitors: [Any] = []

    func start() {
        guard !started else { return }
        started = true
        loadTargets()
        motion.delegate = self
        if CMHeadphoneMotionManager.authorizationStatus() == .denied {
            message = "Motion access is off. Allow it in System Settings, Privacy & Security, Motion & Fitness."
        }
        if motion.isDeviceMotionAvailable {
            motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                MainActor.assumeIsolated { self.handle(data) }
            }
        } else {
            message = "This Mac can't read headphone motion. It needs macOS 14 or later."
        }
        startKeyMonitoring()
        refreshLights()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.installKeyTap() }
        }
    }

    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in self.airpodsConnected = true; self.message = "AirPods connected. Face your screen and press Recentre." }
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in self.airpodsConnected = false; self.message = "AirPods disconnected." }
    }

    private func handle(_ m: CMDeviceMotion) {
        if !airpodsConnected { airpodsConnected = true }
        rawYaw = m.attitude.yaw * 180 / .pi
        yaw = wrap(rawYaw - centre)
        pitch = m.attitude.pitch * 180 / .pi
        facing = nearestTarget(to: yaw)

        let held = KeyTap.armKeysHeld
        if held != armed { armed = held }
        guard enabled, held else { detector.reset(); return }
        guard let result = detector.feed(t: m.timestamp, pitch: pitch, yaw: yaw) else { return }
        let (gesture, heading) = result
        guard let target = nearestTarget(to: heading) else {
            show(gesture == .nod ? "Nod" : "Shake", "Not facing a saved light.")
            return
        }
        let on = gesture == .nod
        show(on ? "Nod" : "Shake", "\(target.label): switching \(on ? "on" : "off")...")
        switchLight(target.device, on: on)
    }

    private func nearestTarget(to heading: Double) -> Target? {
        targets
            .map { ($0, abs(wrap(heading - $0.yaw))) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?.0
    }

    private func show(_ gesture: String, _ text: String) {
        flash = gesture
        message = text
        Task { try? await Task.sleep(for: .milliseconds(700)); if flash == gesture { flash = nil } }
    }

    // MARK: Actions

    func recentre() {
        centre = rawYaw
        yaw = 0
        message = "Centred. Now look at a light and press Save direction next to it."
    }

    func saveDirection(for light: Light) {
        targets.removeAll { $0.device == light.name }
        targets.append(Target(device: light.name, label: light.label, yaw: yaw))
        message = "Saved \(light.label) at \(Int(yaw.rounded()))°. Hold Control + Option and nod."
    }

    func forget(_ light: Light) {
        targets.removeAll { $0.device == light.name }
    }

    func switchLight(_ name: String, on: Bool) {
        lastDevice = name
        let shortcut = "\(name) \(on ? "On" : "Off")"
        Task {
            let ok = await ShortcutRunner.run(shortcut)
            message = ok ? "\(name) \(on ? "on" : "off")." : "The shortcut \u{201C}\(shortcut)\u{201D} didn't run. Open it in Shortcuts and check it works."
        }
    }

    func refreshLights() {
        Task {
            let names = await ShortcutRunner.list()
            lights = ShortcutRunner.lights(from: names)
            scanned = true
            if lights.isEmpty {
                message = "No lights found. In the Shortcuts app, make two shortcuts called \u{201C}Lamp On\u{201D} and \u{201C}Lamp Off\u{201D}, then press Refresh."
            }
        }
    }

    // MARK: Brightness

    private func startKeyMonitoring() {
        KeyTap.onKey = { [weak self] direction in self?.keyStep(direction) }
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = Int64(event.keyCode)
            let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            guard let d = KeyTap.direction(code: code, flags: flags) else { return event }
            MainActor.assumeIsolated { KeyTap.onKey?(d) }
            return nil
        }
        keyMonitors = [local as Any]
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        installKeyTap()
    }

    func installKeyTap() {
        guard KeyTap.port == nil else { shortcutEverywhere = true; return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let port = KeyTap.port { CGEvent.tapEnable(tap: port, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown,
                      let d = KeyTap.direction(code: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
                else { return Unmanaged.passUnretained(event) }
                MainActor.assumeIsolated { KeyTap.onKey?(d) }
                return nil
            },
            userInfo: nil
        ) else {
            shortcutEverywhere = false
            return
        }
        KeyTap.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        shortcutEverywhere = true
    }

    private func keyStep(_ direction: Int) {
        let chosen: Light?
        if let f = facing {
            chosen = lights.first { $0.name == f.device }
        } else if let n = lastDevice {
            chosen = lights.first { $0.name == n }
        } else {
            chosen = lights.first
        }
        guard let light = chosen else {
            message = "No light to adjust. Look at a saved light first."
            return
        }
        guard light.hasBrightness else {
            message = "To dim \(light.name), make shortcuts like \u{201C}\(light.name) 25%\u{201D} and \u{201C}\(light.name) 100%\u{201D}."
            return
        }
        lastDevice = light.name
        let current = levels[light.name] ?? light.levels.last!
        let found = direction > 0 ? light.levels.first(where: { $0 > current }) : light.levels.last(where: { $0 < current })
        guard let next = found else {
            message = "\(light.name) is already at its \(direction > 0 ? "brightest" : "dimmest") setting."
            return
        }
        levels[light.name] = next
        message = "\(light.name) brightness \(next)%"
        pendingLevel[light.name] = next
        pumpBrightness(light.name)
    }

    // Only one brightness shortcut runs per light at a time; key presses in between
    // are merged so the light always ends on the latest level.
    private func pumpBrightness(_ name: String) {
        guard !busy.contains(name), let level = pendingLevel.removeValue(forKey: name) else { return }
        busy.insert(name)
        Task {
            let ok = await ShortcutRunner.run("\(name) \(level)%")
            if !ok { message = "The shortcut \u{201C}\(name) \(level)%\u{201D} didn't run. Open it in Shortcuts and check it works." }
            busy.remove(name)
            pumpBrightness(name)
        }
    }

    // MARK: Persistence

    private func saveTargets() {
        if let data = try? JSONEncoder().encode(targets) { UserDefaults.standard.set(data, forKey: "targets") }
    }

    private func loadTargets() {
        if let data = UserDefaults.standard.data(forKey: "targets"),
           let saved = try? JSONDecoder().decode([Target].self, from: data) { targets = saved }
    }
}

// MARK: - Interface

struct ContentView: View {
    @StateObject private var app = LookAndNod()

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            compass
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                lights
                Spacer(minLength: 0)
                footer
            }
        }
        .padding(28)
        .frame(minWidth: 820, minHeight: 480)
        .onAppear { app.start() }
    }

    // A top-down view of your head: the orange needle is where you're facing.
    private var compass: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.04))
            Circle().stroke(app.armed ? Color.orange : Color.primary.opacity(0.18), lineWidth: app.armed ? 4 : 2)
            Circle()
                .trim(from: 0, to: app.tolerance * 2 / 360)
                .stroke(Color.orange.opacity(0.25), lineWidth: 26)
                .rotationEffect(.degrees(-90 - app.yaw - app.tolerance))
                .padding(13)
            ForEach(app.targets) { t in targetDot(t) }
            Capsule()
                .fill(Color.orange)
                .frame(width: 6, height: 120)
                .offset(y: -60)
                .rotationEffect(.degrees(-app.yaw))
            Circle().fill(Color.primary).frame(width: 16, height: 16)
            if let g = app.flash {
                Text(g)
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 340, height: 340)
        .animation(.easeOut(duration: 0.12), value: app.yaw)
        .animation(.spring(duration: 0.25), value: app.flash)
        .accessibilityElement()
        .accessibilityLabel("Facing \(Int(app.yaw.rounded())) degrees")
    }

    private func targetDot(_ t: Target) -> some View {
        let a = -t.yaw * .pi / 180
        let isFacing = app.facing?.device == t.device
        return ZStack {
            Circle()
                .fill(isFacing ? Color.yellow : Color.secondary)
                .frame(width: isFacing ? 26 : 18, height: isFacing ? 26 : 18)
                .shadow(color: isFacing ? .yellow : .clear, radius: 10)
                .offset(x: sin(a) * 140, y: -cos(a) * 140)
            Text(t.label)
                .font(.caption.bold())
                .offset(x: sin(a) * 140, y: -cos(a) * 140 + 24)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Look and Nod Home").font(.largeTitle.bold())
            HStack(spacing: 16) {
                pill(app.airpodsConnected ? "AirPods connected" : "AirPods not connected", ok: app.airpodsConnected)
                pill(app.lights.isEmpty ? "No lights in Shortcuts" : "\(app.lights.count) light\(app.lights.count == 1 ? "" : "s") from Shortcuts", ok: !app.lights.isEmpty)
                pill(app.shortcutEverywhere ? "Shortcut works in every app" : "Shortcut: allow Accessibility", ok: app.shortcutEverywhere)
            }
            Text(app.armed
                 ? (app.facing.map { "Listening. Nod to switch \($0.label) on, shake for off." } ?? "Listening, but you're not facing a saved light.")
                 : (app.facing.map { "Facing \($0.label). Hold Control + Option, then nod or shake." } ?? "Not facing a saved light."))
                .font(.title3.weight(.semibold))
            Text(app.message).foregroundStyle(.secondary)
        }
    }

    private var lights: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your lights").font(.headline)
            if app.lights.isEmpty && app.scanned {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open the Shortcuts app and make two shortcuts for a light:")
                    Text("\u{201C}Lamp On\u{201D} and \u{201C}Lamp Off\u{201D}, each using the Home action. Then press Refresh.")
                    Text("Add \u{201C}Lamp 25%\u{201D}, \u{201C}Lamp 50%\u{201D} and \u{201C}Lamp 100%\u{201D} too if you want to dim it.").foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            ForEach(app.lights) { d in
                let saved = app.targets.first { $0.device == d.name }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.label).font(.body.weight(.semibold))
                        Text((saved.map { "Saved at \(Int($0.yaw.rounded()))°" } ?? "No direction saved")
                             + (d.hasBrightness ? (app.levels[d.name].map { "  ·  Brightness \($0)%" } ?? "  ·  Dimmable (\(d.levelList))") : "  ·  On and off only"))
                            .font(.caption).foregroundStyle(.secondary)
                        if let level = app.levels[d.name] {
                            ProgressView(value: Double(level), total: 100)
                                .frame(width: 140)
                                .tint(.orange)
                        }
                    }
                    Spacer()
                    Button("On") { app.switchLight(d.name, on: true) }
                    Button("Off") { app.switchLight(d.name, on: false) }
                    Button("Save direction") { app.saveDirection(for: d) }
                        .buttonStyle(.borderedProminent)
                    if saved != nil {
                        Button("Forget") { app.forget(d) }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Recentre") { app.recentre() }
                .keyboardShortcut("r", modifiers: [])
                .help("Face your screen, then press this. Do it each time you start the app.")
            Button("Refresh lights") { app.refreshLights() }
            Text("Hold Ctrl + Option: nod on, shake off, ↑ ↓ brightness").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Toggle("Gestures on", isOn: $app.enabled).toggleStyle(.switch)
        }
    }

    private func pill(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
            .font(.callout.weight(.medium))
            .foregroundStyle(ok ? Color.green : Color.secondary)
    }
}
