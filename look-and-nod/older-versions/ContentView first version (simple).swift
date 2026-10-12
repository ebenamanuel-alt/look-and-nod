//  Look and Nod
//  Face a light, hold Control + Option, and nod to switch it on or shake to switch it off.
//  Hold Control + Option to nod or shake. Control + Option + Up/Down changes brightness.

import SwiftUI
import CoreMotion
import Combine
import AppKit

// MARK: - Models

struct BridgeDevice: Decodable, Identifiable {
    let name: String
    let label: String
    var id: String { name }
}

private struct DevicesResponse: Decodable { let devices: [BridgeDevice] }
private struct LevelResponse: Decodable { let level: Int }

struct Target: Codable, Identifiable {
    let device: String      // name used by the bridge, e.g. "bulb-rgbw"
    var label: String
    var yaw: Double         // saved direction in degrees, relative to centre
    var id: String { device }
}

private func wrap(_ d: Double) -> Double {
    var a = (d + 180).truncatingRemainder(dividingBy: 360)
    if a < 0 { a += 360 }
    return a - 180
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
    @Published var motionDenied = false
    @Published var bridgeOnline = false
    @Published var devices: [BridgeDevice] = []
    @Published var targets: [Target] = [] { didSet { saveTargets() } }
    @Published var yaw = 0.0            // degrees, relative to centre
    @Published var pitch = 0.0
    @Published var facing: Target?
    @Published var message = "Face your screen and press Recentre."
    @Published var flash: String?
    @Published var enabled = true
    @Published var levels: [String: Int] = [:]
    @Published var armed = false

    let tolerance = 22.0                // how close (degrees) you must face a light
    private let bridge = URL(string: "http://127.0.0.1:8765")!
    private let motion = CMHeadphoneMotionManager()
    private var detector = GestureDetector()
    private var rawYaw = 0.0
    private var centre = 0.0
    private var pollTimer: Timer?
    private var started = false
    private var lastDevice: String?
    private var pendingStep = 0
    private var stepping = false
    private var keyMonitors: [Any] = []
    let stepSize = 10

    func start() {
        guard !started else { return }
        started = true
        loadTargets()
        motion.delegate = self
        if CMHeadphoneMotionManager.authorizationStatus() == .denied {
            motionDenied = true
            message = "Motion access is off. Allow it in System Settings, Privacy & Security, Motion & Fitness."
        }
        guard motion.isDeviceMotionAvailable else {
            message = "This Mac can't read headphone motion. It needs macOS 14 or later."
            return
        }
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            MainActor.assumeIsolated { self.handle(data) }
        }
        startKeyMonitoring()
        refreshDevices()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices(); self?.installKeyTap() }
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

        // Nod and shake only count while Control + Option are held down
        let held = KeyTap.armKeysHeld
        if held != armed { armed = held }
        guard enabled, held else { detector.reset(); return }
        guard let result = detector.feed(t: m.timestamp, pitch: pitch, yaw: yaw) else { return }
        let (gesture, heading) = result
        guard let target = nearestTarget(to: heading) else {
            show(gesture == .nod ? "Nod" : "Shake", "Not facing a saved light.")
            return
        }
        let action = gesture == .nod ? "on" : "off"
        show(gesture == .nod ? "Nod" : "Shake", "\(target.label): switching \(action)...")
        send(target.device, action, label: target.label)
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

    func saveDirection(for device: BridgeDevice) {
        targets.removeAll { $0.device == device.name }
        targets.append(Target(device: device.name, label: device.label, yaw: yaw))
        message = "Saved \(device.label) at \(Int(yaw.rounded()))°. Face it and nod."
    }

    func forget(_ device: BridgeDevice) {
        targets.removeAll { $0.device == device.name }
    }

    func send(_ device: String, _ action: String, label: String? = nil) {
        lastDevice = device
        let url = bridge.appendingPathComponent(device).appendingPathComponent(action)
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                bridgeOnline = true
                message = ok ? "\(label ?? device) \(action)." : "The bulb didn't respond. Check it's powered on."
            } catch {
                bridgeOnline = false
                message = "Can't reach the bulb bridge. Is bulb_server.py running?"
            }
        }
    }

    func refreshDevices() {
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: bridge.appendingPathComponent("devices"))
                devices = try JSONDecoder().decode(DevicesResponse.self, from: data).devices
                bridgeOnline = true
            } catch {
                bridgeOnline = false
            }
        }
    }

    // MARK: Brightness shortcut
    // A system-wide keyboard tap catches Control + Option + Up/Down in every app,
    // and swallows them so the browser or any other app doesn't also scroll.

    @Published var shortcutEverywhere = false

    private func startKeyMonitoring() {
        KeyTap.onKey = { [weak self] direction in self?.keyStep(direction) }
        // Works inside this window even before Accessibility is allowed
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

    /// Called at start and every few seconds until macOS allows it.
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
                return nil   // swallow it so the app in front doesn't scroll
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
        let pick: (String, String)?
        if let f = facing {
            pick = (f.device, f.label)
        } else if let n = lastDevice, let d = devices.first(where: { $0.name == n }) {
            pick = (d.name, d.label)
        } else if let d = devices.first {
            pick = (d.name, d.label)
        } else {
            pick = nil
        }
        guard let chosen = pick else {
            message = "No light to adjust. Is bulb_server.py running?"
            return
        }
        let (name, label) = chosen
        lastDevice = name
        pendingStep += direction * stepSize
        pumpBrightness(name, label: label)
    }

    // Sends one change at a time and merges key presses that arrive meanwhile,
    // so holding a key never queues up a backlog of requests.
    private func pumpBrightness(_ name: String, label: String) {
        guard !stepping, pendingStep != 0 else { return }
        let step = pendingStep
        pendingStep = 0
        stepping = true
        let url = bridge.appendingPathComponent(name).appendingPathComponent("step").appendingPathComponent(String(step))
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let r = try? JSONDecoder().decode(LevelResponse.self, from: data) {
                    levels[name] = r.level
                    message = "\(label) brightness \(r.level)%"
                    bridgeOnline = true
                } else {
                    message = "The bridge needs updating for brightness. Restart it with the new bulb_server.py."
                }
            } catch {
                bridgeOnline = false
                message = "Can't reach the bulb bridge. Is bulb_server.py running?"
            }
            stepping = false
            pumpBrightness(name, label: label)
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
            Text("Look and Nod").font(.largeTitle.bold())
            HStack(spacing: 16) {
                pill(app.airpodsConnected ? "AirPods connected" : "AirPods not connected", ok: app.airpodsConnected)
                pill(app.bridgeOnline ? "Bulb bridge online" : "Bulb bridge offline", ok: app.bridgeOnline)
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
            if app.devices.isEmpty {
                Text("No lights yet. Start bulb_server.py in Terminal, then press Refresh.")
                    .foregroundStyle(.secondary)
            }
            ForEach(app.devices) { d in
                let saved = app.targets.first { $0.device == d.name }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.label).font(.body.weight(.semibold))
                        Text((saved.map { "Saved at \(Int($0.yaw.rounded()))°" } ?? "No direction saved")
                             + (app.levels[d.name].map { "  ·  Brightness \($0)%" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                        if let level = app.levels[d.name] {
                            ProgressView(value: Double(level), total: 100)
                                .frame(width: 140)
                                .tint(.orange)
                        }
                    }
                    Spacer()
                    Button("On") { app.send(d.name, "on", label: d.label) }
                    Button("Off") { app.send(d.name, "off", label: d.label) }
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
            Button("Refresh lights") { app.refreshDevices() }
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
