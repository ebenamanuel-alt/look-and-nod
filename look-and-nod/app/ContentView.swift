//  Look and Nod
//  Face a light, hold Control + Option, and nod to switch it on or shake to switch it off.
//  Hold Control + Option to nod or shake, or turn on Always listening.
//  Control + Option + Up/Down, or Control + Option + a volume swipe on your AirPods, changes brightness.
//  Pick the light by looking at it, or choose lights to control from your desk.

import SwiftUI
import CoreMotion
import Combine
import AppKit
import CoreAudio
import AudioToolbox

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

// MARK: - AirPods volume swipe
// While Control + Option are held, a volume change (a swipe on AirPods Pro, or the
// Digital Crown on AirPods Max) is turned into a brightness step and the volume is put back.

@MainActor
final class VolumeWatcher {
    var onSwipe: ((Int) -> Void)?
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var baseline: Float32?
    private var original: Float32?
    private var lastStep = Date.distantPast
    private var watched: [AudioObjectPropertyAddress] = []
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.changed() }
    }
    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.attach() }
    }

    func start() {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, deviceListener)
        attach()
    }

    private func defaultDevice() -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        return id
    }

    private func attach() {
        for var a in watched { AudioObjectRemovePropertyListenerBlock(device, &a, .main, listener) }
        watched = []
        baseline = nil; original = nil
        device = defaultDevice()
        guard device != kAudioObjectUnknown else { return }
        let candidates: [AudioObjectPropertyAddress] = [
            AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                       mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                       mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                       mScope: kAudioDevicePropertyScopeOutput, mElement: 1),
        ]
        for c in candidates {
            var a = c
            guard AudioObjectHasProperty(device, &a) else { continue }
            if AudioObjectAddPropertyListenerBlock(device, &a, .main, listener) == noErr { watched.append(c) }
        }
    }

    private var volumeAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                            mScope: kAudioDevicePropertyScopeOutput,
                                                            mElement: kAudioObjectPropertyElementMain)

    private func volume() -> Float32? {
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var a = volumeAddress
        return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    private func setVolume(_ value: Float32) {
        var v = value
        var a = volumeAddress
        AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    /// Called when Control + Option go down or up.
    func arm(_ on: Bool) {
        if on {
            guard baseline == nil, let v = volume() else { return }
            original = v
            // Keep a little room either side so a swipe always changes something
            let b = min(max(v, 0.1), 0.9)
            if b != v { setVolume(b) }
            baseline = b
        } else {
            guard baseline != nil else { return }
            baseline = nil
            if let o = original { setVolume(o) }
            original = nil
        }
    }

    private func changed() {
        guard let base = baseline, let v = volume() else { return }
        let d = v - base
        guard abs(d) > 0.004 else { return }
        if Date().timeIntervalSince(lastStep) > 0.12 {
            lastStep = Date()
            onSwipe?(d > 0 ? 1 : -1)
        }
        setVolume(base)
    }
}

// MARK: - On screen pop up
// A small panel near the bottom of the screen, like the Mac's own volume pop up.
// It shows over every app, never takes focus and ignores the mouse.

struct HUDInfo: Equatable {
    var symbol: String      // big icon
    var title: String       // e.g. "Desk lamp"
    var detail: String      // e.g. "On" or "Brightness"
    var level: Int?         // shows a bar when set
    var source: String      // e.g. "Nod", "⌃ ⌥ ↑", "AirPods swipe"
    var sourceSymbol: String
    var lit: Bool
    var kind: HUDKind = .plain   // which animation to play
    var worked = true
    var stamp = UUID()          // a new one replays the animation
}

/// What the person just did, so the pop up can act it out.
enum HUDKind: Equatable {
    case plain, nod, shake
    case airpods(up: Bool)
    case keyboard(up: Bool)
}

@MainActor
final class HUD: ObservableObject {
    static let shared = HUD()
    @Published var info: HUDInfo?
    var enabled = true
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private let size = NSSize(width: 390, height: 116)

    func show(_ i: HUDInfo) {
        guard enabled else { return }
        info = i
        let p = panel ?? makePanel()
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 110))
        }
        if !p.isVisible || p.alphaValue < 1 {
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self, let p = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 }, completionHandler: {
                MainActor.assumeIsolated { if p.alphaValue == 0 { p.orderOut(nil) } }
            })
        }
    }

    /// Updates the level if the pop up is still showing that light.
    func update(title: String, level: Int) {
        guard var i = info, i.title == title, i.level != nil, panel?.isVisible == true else { return }
        i.level = level
        info = i
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.alphaValue = 0
        // Real frosted glass: blur whatever is behind the panel, with rounded corners
        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        let r: CGFloat = 22
        glass.maskImage = NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill(); return true
        }
        let host = NSHostingView(rootView: HUDView(hud: self))
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)
        p.contentView = glass
        panel = p
        return p
    }
}

private struct HUDView: View {
    @ObservedObject var hud: HUD
    var body: some View {
        ZStack {
            if let i = hud.info {
                HStack(spacing: 16) {
                    if i.kind == .plain {
                        Image(systemName: i.symbol)
                            .font(.system(size: 28, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(i.lit ? Color.yellow : Color.primary)
                            .frame(width: 84, height: 84)
                    } else {
                        InputIllustration(kind: i.kind, stamp: i.stamp, worked: i.worked)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(i.title).font(.headline).lineLimit(1)
                            Spacer(minLength: 8)
                            Label(i.source, systemImage: i.sourceSymbol)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        if let level = i.level {
                            HStack(spacing: 8) {
                                Image(systemName: i.symbol)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.yellow)
                                    .contentTransition(.symbolEffect(.replace))
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.primary.opacity(0.15))
                                        Capsule().fill(Color.primary.opacity(0.9))
                                            .frame(width: max(6, g.size.width * Double(level) / 100))
                                    }
                                }
                                .frame(height: 6)
                                Text("\(level)%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .trailing)
                            }
                            .animation(.easeOut(duration: 0.15), value: level)
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: i.symbol)
                                    .foregroundStyle(i.lit ? Color.yellow : (i.worked ? Color.secondary : Color.orange))
                                Text(i.detail).foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .frame(width: 390, height: 116)
            }
        }
        .frame(width: 390, height: 116)
    }
}

/// A small animation that acts out what you just did.
private struct InputIllustration: View {
    let kind: HUDKind
    let stamp: UUID
    let worked: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.07))
            switch kind {
            case .nod:
                HeadMotion(shake: false, stamp: stamp, worked: worked)
            case .shake:
                HeadMotion(shake: true, stamp: stamp, worked: worked)
            case .airpods(let up):
                AirPodSwipe(up: up, stamp: stamp)
            case .keyboard(let up):
                KeyPress(up: up, stamp: stamp)
            case .plain:
                EmptyView()
            }
        }
        .frame(width: 84, height: 84)
    }
}

/// A head that nods or shakes, with the AirPods motion arrow beside it.
private struct HeadMotion: View {
    let shake: Bool
    let stamp: UUID
    let worked: Bool

    private var axis: (x: CGFloat, y: CGFloat, z: CGFloat) { shake ? (0, 1, 0) : (1, 0, 0) }

    var body: some View {
        ZStack {
            Image(systemName: "face.smiling")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.primary)
                .phaseAnimator(shake ? [0.0, -1.0, 1.0, -0.8, 0.8, 0.0] : [0.0, 1.0, -0.2, 0.9, 0.0], trigger: stamp) { content, phase in
                    content
                        .rotation3DEffect(.degrees(phase * (shake ? 34 : 30)), axis: axis, perspective: 0.5)
                        .offset(y: shake ? 0 : phase * 3)
                } animation: { _ in Animation.easeInOut(duration: shake ? 0.13 : 0.17) }
            Image(systemName: shake ? "arrow.left.and.right" : "arrow.up.and.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(worked ? Color.accentColor : Color.orange)
                .offset(x: shake ? 0 : 31, y: shake ? 31 : 0)
        }
    }
}

/// An AirPod with a fingertip sliding along the stem.
private struct AirPodSwipe: View {
    let up: Bool
    let stamp: UUID

    var body: some View {
        ZStack {
            Image(systemName: "airpodpro.right")
                .font(.system(size: 50, weight: .light))
                .foregroundStyle(.primary)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 12, height: 12)
                .shadow(color: Color.accentColor.opacity(0.9), radius: 6)
                // 0 ready, 1 touch, 2 slide, 3 lift. Played twice.
                .phaseAnimator([0, 1, 2, 3, 0, 1, 2, 3, 0], trigger: stamp) { content, phase in
                    content
                        .offset(x: 6, y: (phase >= 2 ? -1.0 : 1.0) * (up ? 15.0 : -15.0))
                        .opacity(phase == 1 || phase == 2 ? 1 : 0)
                        .scaleEffect(phase == 1 ? 1.25 : 1)
                } animation: { phase in
                    phase == 2 ? Animation.easeInOut(duration: 0.3) : Animation.easeOut(duration: 0.09)
                }
            Image(systemName: up ? "chevron.up" : "chevron.down")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(Color.accentColor)
                .offset(x: 30)
                .phaseAnimator([0.0, 1.0, 0.0, 1.0, 0.0], trigger: stamp) { content, phase in
                    content.offset(y: phase * (up ? -5 : 5)).opacity(0.5 + phase * 0.5)
                } animation: { _ in Animation.easeInOut(duration: 0.2) }
        }
    }
}

/// Control and Option held, and the arrow key pressed.
private struct KeyPress: View {
    let up: Bool
    let stamp: UUID

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                cap("⌃", held: true)
                cap("⌥", held: true)
            }
            cap(up ? "↑" : "↓", held: false)
                .phaseAnimator([false, true, false], trigger: stamp) { content, pressed in
                    content
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.accentColor.opacity(pressed ? 0.55 : 0)))
                        .scaleEffect(pressed ? 0.84 : 1)
                        .offset(y: pressed ? 2 : 0)
                } animation: { _ in Animation.easeOut(duration: 0.12) }
        }
    }

    private func cap(_ t: String, held: Bool) -> some View {
        Text(t)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .frame(width: 30, height: 26)
            .foregroundStyle(held ? Color.white : Color.primary)
            .background(held ? Color.accentColor : Color.primary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
    }
}

// MARK: - Controller

/// Where you're facing. Kept separate so only the room plan redraws as your head moves.
@MainActor
final class Pose: ObservableObject {
    @Published var yaw = 0.0
    struct Sample { let t: Double; let nod: Double; let shake: Double }
    struct Mark { let t: Double; let nod: Bool; let worked: Bool }
    /// The last few seconds of head movement, for the live graph. Not published: the graph redraws on its own clock.
    var trail: [Sample] = []
    var marks: [Mark] = []
}

/// One line in the activity list.
struct Activity: Identifiable, Equatable {
    let id = UUID()
    var time = Date()
    var symbol: String
    var title: String
    var detail: String
    var ms: Int? = nil
    var ok = true
    var key: String? = nil
}

/// The journey of one command, from your head to the bulb, for the pipeline view.
struct Flow: Equatable {
    var id = UUID()
    var stage = 0               // 0 idle, 1 input, 2 understood, 3 sent to bridge, 4 bulb answered
    var input = "AirPods"
    var inputSymbol = "airpodspro"
    var action = "Gesture"
    var light = "Light"
    var ms: Int? = nil
    var failed = false
    var started = Date()
}

@MainActor
final class LookAndNod: NSObject, ObservableObject, CMHeadphoneMotionManagerDelegate {
    @Published var airpodsConnected = false
    @Published var motionDenied = false
    @Published var bridgeOnline = false
    @Published var devices: [BridgeDevice] = []
    @Published var targets: [Target] = [] { didSet { saveTargets() } }
    let pose = Pose()
    private(set) var yaw = 0.0          // degrees, relative to centre, updated every sample
    private var pitch = 0.0
    private var lastDraw = 0.0
    @Published var facing: Target?
    @Published var message = "Face your screen and press Recentre."
    @Published var flash: String?
    @Published var enabled = true
    @Published var levels: [String: Int] = [:]
    @Published var armed = false
    @Published var lampOn: [String: Bool] = [:]
    @Published var listening = false
    @Published var activity: [Activity] = []
    @Published var flow = Flow()
    @Published var lastMs: Int?
    @Published var hasRecentred = false
    private var slowPitch = 0.0
    private var slowYaw = 0.0
    private var brightFlow: [String: UUID] = [:]
    private var brightSource: [String: String] = [:]
    /// false: nod and shake only while Control + Option are held. true: always listening.
    @Published var alwaysOn = UserDefaults.standard.bool(forKey: "alwaysOn") { didSet { UserDefaults.standard.set(alwaysOn, forKey: "alwaysOn") } }
    /// true: the light you look at is the one that changes. false: control chosen lights from your desk.
    @Published var lookToPick = (UserDefaults.standard.object(forKey: "lookToPick") as? Bool) ?? true { didSet { UserDefaults.standard.set(lookToPick, forKey: "lookToPick") } }
    /// Show the on screen pop up for nods, shakes and brightness.
    @Published var showPopUps = (UserDefaults.standard.object(forKey: "showPopUps") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(showPopUps, forKey: "showPopUps"); HUD.shared.enabled = showPopUps }
    }
    /// Which lights desk mode controls: "all" or a light's name.
    @Published var deskChoice = UserDefaults.standard.string(forKey: "deskChoice") ?? "all" { didSet { UserDefaults.standard.set(deskChoice, forKey: "deskChoice") } }

    let tolerance = 22.0                // how close (degrees) you must face a light
    private let bridge = URL(string: "http://127.0.0.1:8765")!
    private let motion = CMHeadphoneMotionManager()
    private var detector = GestureDetector()
    private var rawYaw = 0.0
    private var centre = 0.0
    private var pollTimer: Timer?
    private var started = false
    private var lastDevice: String?
    private var pendingStep: [String: Int] = [:]
    private var stepping: Set<String> = []
    private var shownLevel: [String: Int] = [:]
    private var lastPredictedStep: [String: Int] = [:]
    private let volumeWatcher = VolumeWatcher()
    private var keyMonitors: [Any] = []
    private var mouse: MouseControl?
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
        startMouse()
        HUD.shared.enabled = showPopUps
        volumeWatcher.onSwipe = { [weak self] direction in self?.keyStep(direction, from: .airpods) }
        volumeWatcher.start()
        refreshDevices()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices(); self?.installKeyTap(); self?.mouse?.install() }
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
        // Redraw at most 30 times a second, and only when the head has actually moved
        if m.timestamp - lastDraw >= 1.0 / 30, abs(wrap(yaw - pose.yaw)) >= 0.5 {
            pose.yaw = yaw
            lastDraw = m.timestamp
        }
        pitch = m.attitude.pitch * 180 / .pi
        // Signal for the live graph: movement relative to a slow average, so it sits around zero
        slowPitch += (pitch - slowPitch) * 0.03
        slowYaw = wrap(slowYaw + wrap(yaw - slowYaw) * 0.03)
        pose.trail.append(.init(t: m.timestamp, nod: pitch - slowPitch, shake: wrap(yaw - slowYaw)))
        if let first = pose.trail.first, m.timestamp - first.t > 8 { pose.trail.removeAll { m.timestamp - $0.t > 7 } }
        let nowFacing = nearestTarget(to: yaw)
        if nowFacing?.device != facing?.device { facing = nowFacing }

        // Nod and shake only count while Control + Option are held down
        let held = KeyTap.armKeysHeld
        if held != armed { armed = held; volumeWatcher.arm(held) }
        let on = enabled && (alwaysOn || held)
        if on != listening { listening = on }
        guard on else { detector.reset(); return }
        guard let result = detector.feed(t: m.timestamp, pitch: pitch, yaw: yaw) else { return }
        let (gesture, heading) = result
        let action = gesture == .nod ? "on" : "off"
        let word = gesture == .nod ? "Nod" : "Shake"
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        if lookToPick {
            guard let target = nearestTarget(to: heading) else {
                markGesture(m.timestamp, gesture, worked: false)
                show(word, "Not facing a saved light.")
                gesturePopUp(gesture, title: "No light there", detail: "Look at a saved light, then \(word.lowercased()).", worked: false)
                failFlow(word: word, why: "No light in view")
                return
            }
            markGesture(m.timestamp, gesture, worked: true)
            show(word, "\(target.label): switching \(action)...")
            gesturePopUp(gesture, title: target.label, detail: action == "on" ? "On" : "Off", worked: true)
            let id = beginFlow(input: "AirPods", symbol: "airpodspro", action: word, light: target.label)
            send(target.device, action, label: target.label, source: word, flowID: id)
        } else {
            let chosen = deskLights
            guard !chosen.isEmpty else {
                markGesture(m.timestamp, gesture, worked: false)
                show(word, "Choose which lights to control from your desk.")
                gesturePopUp(gesture, title: "No lights chosen", detail: "Pick lights in Desk controls.", worked: false)
                failFlow(word: word, why: "No lights chosen")
                return
            }
            markGesture(m.timestamp, gesture, worked: true)
            let name = chosen.count == 1 ? chosen[0].label : "All lights"
            show(word, "\(name): switching \(action)...")
            gesturePopUp(gesture, title: name, detail: action == "on" ? "On" : "Off", worked: true)
            let id = beginFlow(input: "AirPods", symbol: "airpodspro", action: word, light: name)
            for d in chosen { send(d.name, action, label: chosen.count == 1 ? d.label : d.label, source: "\(word) from desk", flowID: id) }
        }
    }

    private func markGesture(_ t: Double, _ g: GestureDetector.Gesture, worked: Bool) {
        pose.marks.append(.init(t: t, nod: g == .nod, worked: worked))
        pose.marks.removeAll { t - $0.t > 8 }
    }

    // MARK: Pipeline and activity

    @discardableResult
    func beginFlow(input: String, symbol: String, action: String, light: String) -> UUID {
        var f = Flow()
        f.stage = 1; f.input = input; f.inputSymbol = symbol; f.action = action; f.light = light
        flow = f
        let id = f.id
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            if flow.id == id, flow.stage < 2 { flow.stage = 2 }
            try? await Task.sleep(for: .milliseconds(120))
            if flow.id == id, flow.stage < 3, !flow.failed { flow.stage = 3 }
        }
        return id
    }

    func finishFlow(_ id: UUID?, ms: Int?, failed: Bool) {
        guard let id, flow.id == id else { return }
        if let ms { lastMs = ms }
        // Let the earlier steps play out before the bulb lights up, even on a very fast reply
        let wait = max(0, 0.26 - Date().timeIntervalSince(flow.started))
        Task {
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
            guard flow.id == id else { return }
            flow.ms = ms
            flow.failed = failed
            flow.stage = failed ? 3 : 4
            try? await Task.sleep(for: .milliseconds(1800))
            if flow.id == id { flow.stage = 0 }
        }
    }

    private func failFlow(word: String, why: String) {
        var f = Flow()
        f.stage = 2; f.action = word; f.light = why; f.failed = true
        flow = f
        let id = f.id
        log(Activity(symbol: "questionmark.circle", title: "\(word), nothing changed", detail: why, ok: false))
        Task {
            try? await Task.sleep(for: .milliseconds(1800))
            if flow.id == id { flow.stage = 0 }
        }
    }

    func log(_ a: Activity) {
        if let k = a.key, let first = activity.first, first.key == k, Date().timeIntervalSince(first.time) < 3 {
            activity[0].title = a.title
            activity[0].detail = a.detail
            activity[0].ms = a.ms
            activity[0].ok = a.ok
            activity[0].time = Date()
            return
        }
        activity.insert(a, at: 0)
        if activity.count > 40 { activity.removeLast() }
    }

    // MARK: Magic Mouse (hold ⌃ ⌥, then slide, swipe or click)

    private func startMouse() {
        let m = MouseControl(
            target: { [weak self] in self?.facing.map { (device: $0.device, label: $0.label) } },
            report: { [weak self] event in self?.mouseEvent(event) },
            levelChanged: { [weak self] name, level in
                self?.levels[name] = level
                self?.shownLevel[name] = level
            },
            online: { [weak self] ok in
                if self?.bridgeOnline != ok { self?.bridgeOnline = ok }
            }
        )
        m.install()
        mouse = m
    }

    private func mouseEvent(_ event: MouseEvent) {
        switch event {
        case let .brightness(label, level, up):
            message = "\(label) brightness \(level)%"
            HUD.shared.show(HUDInfo(
                symbol: up ? "sun.max.fill" : "sun.min.fill",
                title: label, detail: "Brightness", level: level,
                source: "Magic Mouse", sourceSymbol: "magicmouse",
                lit: true))
            log(Activity(symbol: "magicmouse", title: "\(label) \(level)%", detail: "Magic Mouse slide",
                         key: "mouse-brightness-\(label)"))
        case let .colour(label, name, next):
            message = "\(label): \(name)"
            HUD.shared.show(HUDInfo(
                symbol: "paintpalette.fill",
                title: label, detail: name, level: nil,
                source: next ? "Magic Mouse swipe ›" : "‹ Magic Mouse swipe", sourceSymbol: "magicmouse",
                lit: true))
            log(Activity(symbol: "paintpalette", title: "\(label): \(name)", detail: "Magic Mouse swipe",
                         key: "mouse-colour-\(label)"))
        case let .toggled(label, on):
            message = "\(label) \(on ? "on" : "off")."
            HUD.shared.show(HUDInfo(
                symbol: on ? "lightbulb.max.fill" : "lightbulb.slash",
                title: label, detail: on ? "On" : "Off", level: nil,
                source: "Magic Mouse click", sourceSymbol: "cursorarrow.click",
                lit: on))
            log(Activity(symbol: on ? "lightbulb.max" : "lightbulb.slash", title: "\(label) \(on ? "on" : "off")",
                         detail: "Magic Mouse click"))
        case let .problem(text):
            message = text
            log(Activity(symbol: "exclamationmark.triangle", title: "Magic Mouse", detail: text, ok: false))
        }
    }

    private func gesturePopUp(_ g: GestureDetector.Gesture, title: String, detail: String, worked: Bool) {
        let nod = g == .nod
        HUD.shared.show(HUDInfo(
            symbol: worked ? (nod ? "lightbulb.max.fill" : "lightbulb.slash") : "questionmark",
            title: title, detail: detail, level: nil,
            source: nod ? "Nod" : "Shake",
            sourceSymbol: nod ? "arrow.up.and.down" : "arrow.left.and.right",
            lit: worked && nod,
            kind: nod ? .nod : .shake,
            worked: worked))
    }

    /// The lights desk mode controls.
    var deskLights: [BridgeDevice] {
        deskChoice == "all" ? devices : devices.filter { $0.name == deskChoice }
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
        pose.yaw = 0
        hasRecentred = true
        message = "Centred. Now look at a light and press Save direction next to it."
        log(Activity(symbol: "scope", title: "Recentred", detail: "Your screen is now 0°"))
    }

    func saveDirection(for device: BridgeDevice) {
        targets.removeAll { $0.device == device.name }
        targets.append(Target(device: device.name, label: device.label, yaw: yaw))
        message = "Saved \(device.label) at \(Int(yaw.rounded()))°. Face it and nod."
        log(Activity(symbol: "mappin.and.ellipse", title: "Saved \(device.label)", detail: "At \(Int(yaw.rounded()))° from your screen"))
    }

    func forget(_ device: BridgeDevice) {
        targets.removeAll { $0.device == device.name }
    }

    func send(_ device: String, _ action: String, label: String? = nil, source: String = "Dashboard", flowID: UUID? = nil) {
        lastDevice = device
        let name = label ?? device
        let id = flowID ?? beginFlow(input: "Dashboard", symbol: "cursorarrow.click.2", action: action == "on" ? "Switch on" : "Switch off", light: name)
        let url = bridge.appendingPathComponent(device).appendingPathComponent(action)
        let start = Date()
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                if !bridgeOnline { bridgeOnline = true }
                if ok && (action == "on" || action == "off") { lampOn[device] = action == "on" }
                message = ok ? "\(name) \(action)." : "The bulb didn't respond. Check it's powered on."
                log(Activity(symbol: ok ? (action == "on" ? "lightbulb.max.fill" : "lightbulb.slash") : "exclamationmark.triangle",
                             title: ok ? "\(name) \(action)" : "\(name) didn't respond", detail: source, ms: ms, ok: ok))
                finishFlow(id, ms: ms, failed: !ok)
            } catch {
                bridgeOnline = false
                message = "Can't reach the bulb bridge. Run Setup Look and Nod, or start bulb_server.py."
                log(Activity(symbol: "exclamationmark.triangle", title: "Bridge not reachable", detail: "Run Setup Look and Nod, or start bulb_server.py.", ok: false))
                finishFlow(id, ms: nil, failed: true)
            }
        }
    }

    /// Sets an exact brightness, used by the slider.
    func setBrightness(_ name: String, label: String, to pct: Int) {
        let level = max(5, min(100, pct))
        levels[name] = level
        lastDevice = name
        let url = bridge.appendingPathComponent(name).appendingPathComponent("brightness").appendingPathComponent(String(level))
        let id = beginFlow(input: "Dashboard", symbol: "slider.horizontal.3", action: "Brightness", light: label)
        let start = Date()
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                if let r = try? JSONDecoder().decode(LevelResponse.self, from: data) {
                    levels[name] = r.level
                    message = "\(label) brightness \(r.level)%"
                    log(Activity(symbol: "sun.max.fill", title: "\(label) \(r.level)%", detail: "Dashboard slider", ms: ms, key: "bright:\(name)"))
                }
                finishFlow(id, ms: ms, failed: false)
            } catch {
                finishFlow(id, ms: nil, failed: true)
                bridgeOnline = false
                message = "Can't reach the bulb bridge. Run Setup Look and Nod, or start bulb_server.py."
            }
        }
    }

    func refreshDevices() {
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: bridge.appendingPathComponent("devices"))
                let found = try JSONDecoder().decode(DevicesResponse.self, from: data).devices
                if found.map(\.name) != devices.map(\.name) { devices = found }
                if !bridgeOnline { bridgeOnline = true }
            } catch {
                if bridgeOnline { bridgeOnline = false }
            }
        }
    }

    // MARK: Brightness shortcut
    // A system-wide keyboard tap catches Control + Option + Up/Down in every app,
    // and swallows them so the browser or any other app doesn't also scroll.

    @Published var shortcutEverywhere = false

    private func startKeyMonitoring() {
        KeyTap.onKey = { [weak self] direction in self?.keyStep(direction, from: .keyboard) }
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
        guard KeyTap.port == nil else { if !shortcutEverywhere { shortcutEverywhere = true }; return }
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
            if shortcutEverywhere { shortcutEverywhere = false }
            return
        }
        KeyTap.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        shortcutEverywhere = true
    }

    enum StepSource { case keyboard, airpods }

    private func keyStep(_ direction: Int, from source: StepSource) {
        if !lookToPick, !deskLights.isEmpty {
            var shown: Int?
            let id = beginFlow(input: source == .keyboard ? "Keyboard" : "AirPods",
                               symbol: source == .keyboard ? "keyboard" : "airpodspro",
                               action: direction > 0 ? "Brighter" : "Dimmer",
                               light: deskLights.count == 1 ? deskLights[0].label : "All lights")
            for d in deskLights {
                brightFlow[d.name] = id
                brightSource[d.name] = source == .keyboard ? "⌃ ⌥ \(direction > 0 ? "↑" : "↓")" : "AirPods swipe"
                pendingStep[d.name, default: 0] += direction * stepSize
                let level = predictedLevel(d.name)
                if shown == nil { shown = level }
            }
            brightnessPopUp(title: deskLights.count == 1 ? deskLights[0].label : "All lights",
                            level: shown ?? 100, direction: direction, source: source)
            for d in deskLights { pumpBrightness(d.name, label: d.label) }
            return
        }
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
            message = "No light to adjust. Run Setup Look and Nod, or start bulb_server.py."
            return
        }
        let (name, label) = chosen
        lastDevice = name
        pendingStep[name, default: 0] += direction * stepSize
        brightnessPopUp(title: label, level: predictedLevel(name), direction: direction, source: source)
        brightFlow[name] = beginFlow(input: source == .keyboard ? "Keyboard" : "AirPods",
                                     symbol: source == .keyboard ? "keyboard" : "airpodspro",
                                     action: direction > 0 ? "Brighter" : "Dimmer", light: label)
        brightSource[name] = source == .keyboard ? "⌃ ⌥ \(direction > 0 ? "↑" : "↓")" : "AirPods swipe"
        pumpBrightness(name, label: label)
    }

    /// The level a light is about to reach, so the pop up moves straight away.
    private func predictedLevel(_ name: String) -> Int {
        let base = shownLevel[name] ?? levels[name] ?? 100
        let next = max(5, min(100, base + (pendingStep[name] ?? 0) - (lastPredictedStep[name] ?? 0)))
        lastPredictedStep[name] = pendingStep[name] ?? 0
        shownLevel[name] = next
        return next
    }

    private func brightnessPopUp(title: String, level: Int, direction: Int, source: StepSource) {
        let arrow = direction > 0 ? "↑" : "↓"
        HUD.shared.show(HUDInfo(
            symbol: direction > 0 ? "sun.max.fill" : "sun.min.fill",
            title: title, detail: "Brightness", level: level,
            source: source == .keyboard ? "⌃ ⌥ \(arrow)" : "AirPods \(arrow)",
            sourceSymbol: source == .keyboard ? "keyboard" : "airpodspro",
            lit: true,
            kind: source == .keyboard ? .keyboard(up: direction > 0) : .airpods(up: direction > 0)))
    }

    // Sends one change at a time and merges key presses that arrive meanwhile,
    // so holding a key never queues up a backlog of requests.
    private func pumpBrightness(_ name: String, label: String) {
        guard !stepping.contains(name), let step = pendingStep[name], step != 0 else { return }
        pendingStep[name] = 0
        lastPredictedStep[name] = 0
        stepping.insert(name)
        let url = bridge.appendingPathComponent(name).appendingPathComponent("step").appendingPathComponent(String(step))
        let start = Date()
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                if let r = try? JSONDecoder().decode(LevelResponse.self, from: data) {
                    levels[name] = r.level
                    log(Activity(symbol: "sun.max.fill", title: "\(label) \(r.level)%", detail: brightSource[name] ?? "Brightness", ms: ms, key: "bright:\(name)"))
                    finishFlow(brightFlow[name], ms: ms, failed: false)
                    if (pendingStep[name] ?? 0) == 0 {
                        shownLevel[name] = r.level
                        lastPredictedStep[name] = 0
                        HUD.shared.update(title: label, level: r.level)
                    }
                    message = "\(label) brightness \(r.level)%"
                    bridgeOnline = true
                } else {
                    message = "The bridge needs updating. Restart it with the new bulb_server.py."
                }
            } catch {
                bridgeOnline = false
                message = "Can't reach the bulb bridge. Run Setup Look and Nod, or start bulb_server.py."
                finishFlow(brightFlow[name], ms: nil, failed: true)
            }
            stepping.remove(name)
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

private let lampColor = Color.yellow
private let shakeColor = Color.teal

/// Makes the whole window frosted glass, like Apple's own apps.
private struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
        }
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

private extension View {
    func glassCard(_ radius: CGFloat = 22) -> some View {
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
            .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
    }
}

private struct CardTitle: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(title).font(.headline)
        }
    }
}

/// Where a heading sits in a box: you in the middle, your screen straight up.
private func point(_ c: CGPoint, _ r: Double, _ yaw: Double) -> CGPoint {
    let a = -yaw * .pi / 180
    return CGPoint(x: c.x + sin(a) * r, y: c.y - cos(a) * r)
}

private func roomGeometry(_ size: CGSize) -> (CGPoint, Double) {
    let r = min(size.width, size.height * 1.1) * 0.34
    return (CGPoint(x: size.width / 2, y: size.height / 2 + 14), r)
}

// MARK: Room

/// The room from above. It watches Pose, so turning your head redraws only this.
private struct RoomPlan: View {
    @ObservedObject var app: LookAndNod
    @ObservedObject var pose: Pose

    var body: some View {
        let yaw = pose.yaw
        let targets = app.targets
        let lampOn = app.lampOn
        let levels = app.levels
        let look = app.lookToPick
        let tol = app.tolerance
        let accent = Color.accentColor
        let ink = Color.primary

        return GeometryReader { geo in
            let geom = roomGeometry(geo.size)
            let c = geom.0
            let r = geom.1
            ZStack {
                // Light, rings, the facing cone and you, drawn in one fast pass
                Canvas { ctx, _ in
                    for t in targets where lampOn[t.device] == true {
                        let p = point(c, r, t.yaw)
                        let lv = Double(levels[t.device] ?? 100) / 100
                        let gr = r * (0.5 + 0.3 * lv)
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - gr, y: p.y - gr, width: gr * 2, height: gr * 2)),
                                 with: .radialGradient(Gradient(colors: [lampColor.opacity(0.18 + 0.4 * lv), lampColor.opacity(0)]),
                                                       center: p, startRadius: 0, endRadius: gr))
                    }
                    for k in [0.42, 0.72, 1.0] {
                        let rr = r * k
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                                   with: .color(ink.opacity(0.07)), lineWidth: 1)
                    }
                    if look {
                        let theta = -yaw - 90
                        var cone = Path()
                        cone.move(to: c)
                        cone.addArc(center: c, radius: r * 1.3, startAngle: .degrees(theta - tol), endAngle: .degrees(theta + tol), clockwise: false)
                        cone.closeSubpath()
                        ctx.fill(cone, with: .radialGradient(Gradient(colors: [accent.opacity(0.32), accent.opacity(0)]),
                                                             center: c, startRadius: 0, endRadius: r * 1.3))
                    }
                    // A compass of degrees around you, so saved directions mean something
                    let ring = r * 0.22
                    for d in stride(from: 0, to: 360, by: 10) {
                        let major = d % 90 == 0
                        var tick = Path()
                        tick.move(to: point(c, ring, Double(d)))
                        tick.addLine(to: point(c, ring + (major ? 9 : 5), Double(d)))
                        ctx.stroke(tick, with: .color(ink.opacity(major ? 0.45 : 0.18)), lineWidth: 1)
                        if major {
                            let label = d > 180 ? d - 360 : d
                            ctx.draw(Text("\(label)°").font(.system(size: 9, weight: .medium)).foregroundColor(.secondary),
                                     at: point(c, ring + 20, Double(d)))
                        }
                    }
                    var needle = Path()
                    needle.move(to: point(c, 14, yaw))
                    needle.addLine(to: point(c, r * 0.6, yaw))
                    ctx.stroke(needle, with: .color(accent), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 12, y: c.y - 12, width: 24, height: 24)), with: .color(accent), lineWidth: 3)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)), with: .color(ink))
                }

                VStack(spacing: 3) {
                    Image(systemName: "laptopcomputer").font(.system(size: 18))
                    Text("Screen").font(.caption2)
                }
                .foregroundStyle(.tertiary)
                .position(point(c, r + 40, 0))

                ForEach(targets) { t in
                    LampMarker(app: app, target: t).position(point(c, r, t.yaw))
                }

                if let g = app.flash {
                    Text(g)
                        .font(.title2.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.2)))
                        .position(x: c.x, y: c.y + r * 0.52)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(duration: 0.3), value: app.flash)
        .animation(.easeInOut(duration: 0.45), value: app.lampOn)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Room. Facing \(Int(yaw.rounded())) degrees.")
    }
}

private struct LampMarker: View {
    @ObservedObject var app: LookAndNod
    let target: Target

    var body: some View {
        let on = app.lampOn[target.device] == true
        let active = app.lookToPick ? app.facing?.device == target.device : app.deskLights.contains { $0.name == target.device }
        return VStack(spacing: 6) {
            ZStack {
                Circle().fill(on ? lampColor : Color.primary.opacity(0.08))
                Image(systemName: on ? "lightbulb.max.fill" : "lightbulb")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(on ? Color.black.opacity(0.75) : Color.secondary)
                    .symbolEffect(.bounce, value: on)
            }
            .frame(width: 42, height: 42)
            .shadow(color: on ? lampColor.opacity(0.6) : .clear, radius: 12)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-6).opacity(active ? 1 : 0))
            .scaleEffect(active ? 1.08 : 1)
            Text(target.label).font(.caption.weight(.semibold)).fixedSize()
            if active && app.listening {
                Text(on ? "Shake to turn off" : "Nod to turn on")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .fixedSize()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Text(on ? "On · \(app.levels[target.device] ?? 100)%" : "\(Int(target.yaw.rounded()))°")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .offset(y: 22)
        .animation(.spring(duration: 0.3), value: active)
        .animation(.easeOut(duration: 0.2), value: app.listening)
    }
}

private struct FacingText: View {
    @ObservedObject var pose: Pose
    var body: some View {
        Text("Facing \(Int(pose.yaw.rounded()))°").monospacedDigit()
    }
}

/// First run checklist. Disappears once everything is set up.
private struct SetupGuide: View {
    @ObservedObject var app: LookAndNod
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Get started").font(.headline)
            step(1, "Connect your AirPods", app.airpodsConnected)
            step(2, "Start the bulb bridge", app.bridgeOnline)
            step(3, "Face your screen, press Recentre", app.hasRecentred)
            step(4, "Look at a light, choose Save Direction", !app.targets.isEmpty)
        }
        .padding(14)
        .frame(width: 290, alignment: .leading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
    }

    private func step(_ n: Int, _ text: String, _ done: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(done ? Color.green : Color.primary.opacity(0.1))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(n)").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            Text(text).font(.callout).foregroundStyle(done ? Color.secondary : Color.primary)
        }
        .animation(.spring(duration: 0.3), value: done)
    }
}

// MARK: Head movement graph

/// A live trace of your head, like a heart monitor. Nods dip the blue line, shakes swing the teal one.
private struct HeadSignal: View {
    @ObservedObject var app: LookAndNod
    let pose: Pose
    private let window = 6.0
    private let range = 30.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let trail = pose.trail
            let marks = pose.marks
            let now = ProcessInfo.processInfo.systemUptime
            let live = app.listening
            let enabled = app.enabled
            let accent = Color.accentColor
            let ink = Color.primary
            Canvas { ctx, size in
                let w = size.width, h = size.height, mid = h / 2
                let sx: (Double) -> CGFloat = { t in w - CGFloat((now - t) / window) * w }
                let sy: (Double) -> CGFloat = { v in mid - CGFloat(max(-range, min(range, v)) / range) * (mid - 6) }

                // Guide lines: centre, and the 10° a nod has to reach
                for v in [-10.0, 10.0] {
                    var g = Path(); g.move(to: CGPoint(x: 0, y: sy(v))); g.addLine(to: CGPoint(x: w, y: sy(v)))
                    ctx.stroke(g, with: .color(ink.opacity(0.10)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
                var zero = Path(); zero.move(to: CGPoint(x: 0, y: mid)); zero.addLine(to: CGPoint(x: w, y: mid))
                ctx.stroke(zero, with: .color(ink.opacity(0.12)), lineWidth: 1)
                ctx.draw(Text("10°").font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: 14, y: sy(10) - 7))

                // Recognised gestures
                for m in marks where now - m.t < window {
                    let x = sx(m.t)
                    var line = Path(); line.move(to: CGPoint(x: x, y: 14)); line.addLine(to: CGPoint(x: x, y: h))
                    let col: Color = m.worked ? .green : .orange
                    ctx.stroke(line, with: .color(col.opacity(0.6)), style: StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                    ctx.draw(Text(m.nod ? "Nod" : "Shake").font(.system(size: 10, weight: .semibold)).foregroundColor(col),
                             at: CGPoint(x: x, y: 7))
                }

                // The two traces
                for isNod in [false, true] {
                    var path = Path()
                    var started = false
                    for s in trail where now - s.t <= window + 0.2 {
                        let p = CGPoint(x: sx(s.t), y: sy(isNod ? s.nod : s.shake))
                        if started { path.addLine(to: p) } else { path.move(to: p); started = true }
                    }
                    let color = isNod ? accent : shakeColor
                    ctx.stroke(path, with: .color(color.opacity(live ? 1 : 0.4)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }

                if !live {
                    ctx.draw(Text(enabled ? "Not listening. Hold ⌃ ⌥ to nod or shake." : "Gestures are off.")
                                .font(.system(size: 11, weight: .medium)).foregroundColor(.secondary),
                             at: CGPoint(x: w / 2, y: h - 10))
                }
            }
        }
    }
}

// MARK: Pipeline

/// Shows a command travelling from your head to the bulb, step by step, with the real reply time.
private struct Pipeline: View {
    @ObservedObject var app: LookAndNod

    var body: some View {
        let f = app.flow
        let idle = f.stage == 0
        HStack(spacing: 0) {
            node(0, symbol: idle ? "airpodspro" : f.inputSymbol, title: idle ? "AirPods" : f.input, caption: "Motion and swipes", f)
            link(f.stage >= 2, f)
            node(1, symbol: "waveform.path", title: idle ? "Gesture" : f.action, caption: "Recognised on your Mac", f)
            link(f.stage >= 3, f)
            node(2, symbol: "point.3.connected.trianglepath.dotted", title: "Bridge", caption: "Over your home WiFi", f)
            link(f.stage >= 4, f)
            node(3, symbol: "lightbulb.max", title: idle ? "Light" : f.light,
                 caption: f.stage == 4 ? "Replied in \(f.ms ?? 0) ms" : (app.lastMs.map { "Last reply \($0) ms" } ?? "Waiting"), f)
        }
        .animation(.easeOut(duration: 0.18), value: f)
    }

    private func node(_ i: Int, symbol: String, title: String, caption: String, _ f: Flow) -> some View {
        let lit = f.stage > i
        let failedHere = f.failed && f.stage == i + 1
        let tint: Color = failedHere ? .orange : (i == 3 && lit ? lampColor : Color.accentColor)
        return VStack(spacing: 6) {
            ZStack {
                Circle().fill(lit ? tint : Color.primary.opacity(0.07))
                Image(systemName: failedHere ? "xmark" : symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(lit ? (i == 3 && !failedHere ? Color.black.opacity(0.75) : Color.white) : Color.secondary)
            }
            .frame(width: 38, height: 38)
            .shadow(color: lit ? tint.opacity(0.5) : .clear, radius: 8)
            .scaleEffect(lit ? 1.06 : 1)
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func link(_ on: Bool, _ f: Flow) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.10))
            Capsule().fill(f.failed ? Color.orange : Color.accentColor)
                .scaleEffect(x: on ? 1 : 0, anchor: .leading)
        }
        .frame(width: 44, height: 3)
        .offset(y: -22)
    }
}

// MARK: Window

struct ContentView: View {
    @StateObject private var app = LookAndNod()

    private var setupDone: Bool {
        app.airpodsConnected && app.bridgeOnline && app.hasRecentred && !app.targets.isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    roomCard
                    signalCard
                    pipelineCard
                }
                .frame(minWidth: 580, maxWidth: .infinity)
                VStack(spacing: 16) {
                    lightsCard
                    activityCard
                }
                .frame(width: 360)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 34)
        .padding(.bottom, 22)
        .frame(minWidth: 1100, minHeight: 860)
        .background(WindowGlass().ignoresSafeArea())
        .onAppear { app.start() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [Color.yellow, Color.orange], startPoint: .top, endPoint: .bottom))
                Image(systemName: "lightbulb.max.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)
            .shadow(color: .orange.opacity(0.35), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Look and Nod").font(.system(size: 24, weight: .bold))
                Text(app.message).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 16)
            HStack(spacing: 16) {
                status("airpodspro", "AirPods", app.airpodsConnected,
                       help: app.airpodsConnected ? "AirPods connected" : "Connect your AirPods to this Mac")
                status("point.3.connected.trianglepath.dotted",
                       app.bridgeOnline ? "Bridge · \(app.devices.count)" : "Bridge", app.bridgeOnline,
                       help: app.bridgeOnline ? "Bulb bridge online with \(app.devices.count) lights" : "Run Setup Look and Nod to start the bulb bridge")
                status("keyboard", "Shortcut", app.shortcutEverywhere,
                       help: app.shortcutEverywhere ? "⌃ ⌥ works in every app" : "Allow Accessibility so ⌃ ⌥ works in every app")
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
            Menu {
                Toggle("Gestures", isOn: $app.enabled)
                Toggle("On Screen Pop Ups", isOn: $app.showPopUps)
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Gestures and pop ups")
            Button { app.recentre() } label: { Label("Recentre", systemImage: "scope") }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("r", modifiers: [])
                .help("Face your screen, then press this. Do it each time you start the app.")
        }
    }

    private func status(_ symbol: String, _ title: String, _ ok: Bool, help: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(title)
        }
        .font(.caption.weight(.medium))
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Room card

    private var roomCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                CardTitle(title: "Your room", symbol: "square.split.bottomrightquarter")
                Spacer()
                Picker("Listen", selection: $app.alwaysOn) {
                    Text("Hold ⌃ ⌥").tag(false)
                    Text("Always").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Listen for nods and shakes only while holding Control and Option, or all the time")
                Picker("Choose a light", selection: $app.lookToPick) {
                    Text("Look to pick").tag(true)
                    Text("From desk").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Pick a light by looking at it, or control chosen lights from your desk")
                if !app.lookToPick {
                    Picker("Desk controls", selection: $app.deskChoice) {
                        Text("All Lights").tag("all")
                        ForEach(app.devices) { d in Text(d.label).tag(d.name) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            .padding(16)

            ZStack(alignment: .bottomLeading) {
                RoomPlan(app: app, pose: app.pose)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !setupDone {
                    SetupGuide(app: app)
                        .padding(16)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(minHeight: 330, maxHeight: .infinity)
            .animation(.spring(duration: 0.4), value: setupDone)

            Divider().opacity(0.5)
            HStack(spacing: 12) {
                Text("⌃ ⌥")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .foregroundStyle(app.armed ? Color.white : Color.secondary)
                    .background(app.armed ? Color.accentColor : Color.primary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .scaleEffect(app.armed ? 0.96 : 1)
                    .animation(.easeOut(duration: 0.12), value: app.armed)
                HStack(spacing: 6) {
                    Circle().fill(app.listening ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                    Text(listeningText).lineLimit(1)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
                FacingText(pose: app.pose).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .glassCard()
    }

    private var listeningText: String {
        guard app.enabled else { return "Gestures are off" }
        if !app.listening { return "Hold ⌃ ⌥ to nod or shake" }
        if app.lookToPick {
            return app.facing.map { "Listening · \($0.label)" } ?? "Listening · look at a light"
        }
        let names = app.deskLights.map(\.label)
        return names.isEmpty ? "Listening · choose lights" : "Listening · \(names.count == 1 ? names[0] : "all lights")"
    }

    // MARK: Graph and pipeline cards

    private var signalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardTitle(title: "Head movement", symbol: "waveform.path.ecg")
                Spacer()
                legend(Color.accentColor, "Nod · up and down")
                legend(shakeColor, "Shake · side to side")
            }
            HeadSignal(app: app, pose: app.pose)
                .frame(height: 96)
        }
        .padding(16)
        .glassCard()
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 14, height: 3)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, 8)
    }

    private var pipelineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "From your head to the light", symbol: "arrow.triangle.branch")
            Pipeline(app: app)
        }
        .padding(16)
        .glassCard()
    }

    // MARK: Lights

    private var lightsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardTitle(title: "Lights", symbol: "lightbulb.2")
                Text("\(app.lampOn.values.filter { $0 }.count) on")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                Spacer()
                Button { app.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh lights")
            }
            if app.devices.isEmpty {
                ContentUnavailableView(app.bridgeOnline ? "No Lights Found" : "Bridge Offline",
                                       systemImage: app.bridgeOnline ? "lightbulb.slash" : "point.3.connected.trianglepath.dotted",
                                       description: Text(app.bridgeOnline ? "The bridge is running but found no bulbs." : "Run Setup Look and Nod to start it."))
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(app.devices) { d in lightRow(d) }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassCard()
    }

    private func lightRow(_ d: BridgeDevice) -> some View {
        let on = app.lampOn[d.name] == true
        let saved = app.targets.first { $0.device == d.name }
        let active = app.lookToPick ? app.facing?.device == d.name : app.deskLights.contains { $0.name == d.name }
        let subtitle: String = {
            if active { return app.lookToPick ? "You're looking at it" : "Controlled from your desk" }
            return saved.map { "Saved at \(Int($0.yaw.rounded()))°" } ?? "Direction not saved"
        }()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(on ? lampColor : Color.primary.opacity(0.08))
                    Image(systemName: on ? "lightbulb.max.fill" : "lightbulb")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(on ? Color.black.opacity(0.75) : Color.secondary)
                        .symbolEffect(.bounce, value: on)
                }
                .frame(width: 34, height: 34)
                .shadow(color: on ? lampColor.opacity(0.5) : .clear, radius: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.label).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(active ? Color.accentColor : Color.secondary)
                }
                Spacer()
                Toggle(d.label, isOn: Binding(
                    get: { app.lampOn[d.name] ?? false },
                    set: { app.send(d.name, $0 ? "on" : "off", label: d.label) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.min").foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(app.levels[d.name] ?? 100) },
                    set: { app.levels[d.name] = Int($0.rounded()) }),
                       in: 5...100,
                       onEditingChanged: { editing in
                           if !editing { app.setBrightness(d.name, label: d.label, to: app.levels[d.name] ?? 100) }
                       })
                    .controlSize(.small)
                    .tint(lampColor)
                Image(systemName: "sun.max").foregroundStyle(.secondary)
                Text("\(app.levels[d.name] ?? 100)%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            .font(.caption)
            HStack(spacing: 8) {
                Button(saved == nil ? "Save Direction" : "Update Direction") { app.saveDirection(for: d) }
                if saved != nil { Button("Forget") { app.forget(d) } }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(active ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(active ? Color.accentColor.opacity(0.5) : Color.clear))
        .animation(.easeOut(duration: 0.2), value: active)
    }

    // MARK: Activity

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "Activity", symbol: "clock.arrow.circlepath")
            if app.activity.isEmpty {
                Text("Nods, shakes and brightness changes appear here, with how fast each light replied.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(app.activity) { a in
                        HStack(spacing: 10) {
                            Image(systemName: a.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(a.ok ? (a.symbol.hasPrefix("lightbulb.max") || a.symbol.hasPrefix("sun") ? lampColor : Color.secondary) : Color.orange)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.title).font(.callout.weight(.medium)).lineLimit(1)
                                Text(a.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(a.time.formatted(date: .omitted, time: .standard))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                if let ms = a.ms {
                                    Text("\(ms) ms").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.spring(duration: 0.3), value: app.activity.first?.id)
            }
            .scrollIndicators(.never)
        }
        .padding(16)
        .frame(height: 260, alignment: .top)
        .glassCard()
    }
}