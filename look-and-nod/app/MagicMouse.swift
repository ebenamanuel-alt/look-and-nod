//  Look and Nod: Magic Mouse controls
//  Everything here only works while Control + Option are held.
//
//  Slide a finger up or down   brightness of the light you're facing
//  Swipe left or right         previous or next colour
//  Click                       switch the light on or off
//  Not facing a saved light    the same gestures control every light at once
//
//  Add this file to the Xcode project next to ContentView.swift.

import AppKit

// MARK: - System wide mouse tap

enum MouseTap {
    nonisolated(unsafe) static var port: CFMachPort?
    nonisolated(unsafe) static var onScroll: (@MainActor (Double, Double) -> Void)?
    nonisolated(unsafe) static var onClick: (@MainActor () -> Void)?
    nonisolated(unsafe) static var swallowingClick = false

    nonisolated static func armed(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskControl) && flags.contains(.maskAlternate)
    }
}

/// What happened, so the app can show its pop up and add it to the activity list.
enum MouseEvent {
    case brightness(label: String, level: Int, up: Bool)
    case colour(label: String, name: String, next: Bool)
    case toggled(label: String, on: Bool)
    case problem(String)
}

private struct MouseReply: Decodable {
    let level: Int?
    let levels: [String: Int]?
    let preset: String?
    let action: String?
    let error: String?
}

// MARK: - Controller

@MainActor
final class MouseControl {
    // Tuning. Change these if it feels too fast, too slow or backwards.
    let pointsPerPercent = 6.0   // smaller number = brightness changes faster
    let swipeDistance = 45.0     // how far a sideways swipe must go to change colour
    let flipVertical = false     // true if sliding up makes it dimmer
    let flipSwipe = false        // true if swiping right goes to the previous colour

    private let bridge = URL(string: "http://127.0.0.1:8765")!
    private let target: () -> (device: String, label: String)?
    private let report: (MouseEvent) -> Void
    private let levelChanged: (String, Int) -> Void
    private let online: (Bool) -> Void

    private var verticalPoints = 0.0
    private var swipePoints = 0.0
    private var lastScroll = Date.distantPast
    private var swipeLockedUntil = Date.distantPast
    private var pendingStep = 0
    private var stepping = false
    private var changingColour = false
    private var toggling = false

    init(target: @escaping () -> (device: String, label: String)?,
         report: @escaping (MouseEvent) -> Void,
         levelChanged: @escaping (String, Int) -> Void,
         online: @escaping (Bool) -> Void) {
        self.target = target
        self.report = report
        self.levelChanged = levelChanged
        self.online = online
    }

    /// Safe to call repeatedly. It only installs once Accessibility is allowed.
    func install() {
        MouseTap.onScroll = { [weak self] dx, dy in self?.scroll(dx: dx, dy: dy) }
        MouseTap.onClick = { [weak self] in self?.click() }
        guard MouseTap.port == nil else { return }

        let types: [CGEventType] = [.scrollWheel, .leftMouseDown, .leftMouseUp, .leftMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let port = MouseTap.port { CGEvent.tapEnable(tap: port, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                let armed = MouseTap.armed(event.flags)
                switch type {
                case .scrollWheel:
                    guard armed else { return Unmanaged.passUnretained(event) }
                    let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
                    let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
                    MainActor.assumeIsolated {
                        // Undo "natural scrolling" so sliding up always means brighter
                        let inverted = NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? false
                        MouseTap.onScroll?(inverted ? -dx : dx, inverted ? -dy : dy)
                    }
                    return nil   // swallow it, so the page behind doesn't scroll
                case .leftMouseDown:
                    guard armed else { return Unmanaged.passUnretained(event) }
                    MouseTap.swallowingClick = true
                    MainActor.assumeIsolated { MouseTap.onClick?() }
                    return nil
                case .leftMouseDragged:
                    return MouseTap.swallowingClick ? nil : Unmanaged.passUnretained(event)
                case .leftMouseUp:
                    if MouseTap.swallowingClick { MouseTap.swallowingClick = false; return nil }
                    return Unmanaged.passUnretained(event)
                default:
                    return Unmanaged.passUnretained(event)
                }
            },
            userInfo: nil
        ) else { return }

        MouseTap.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    // MARK: Gestures

    private func scroll(dx rawX: Double, dy rawY: Double) {
        let dx = flipSwipe ? -rawX : rawX
        let dy = flipVertical ? -rawY : rawY
        let now = Date()

        // A pause starts a fresh gesture
        if now.timeIntervalSince(lastScroll) > 0.3 { verticalPoints = 0; swipePoints = 0 }
        lastScroll = now
        guard now >= swipeLockedUntil else { return }

        if abs(dx) > abs(dy) * 1.5 {
            // Sideways swipe: one colour per swipe
            swipePoints += dx
            if abs(swipePoints) >= swipeDistance {
                let direction = swipePoints > 0 ? "next" : "prev"
                swipePoints = 0
                verticalPoints = 0
                swipeLockedUntil = now.addingTimeInterval(0.45)
                changeColour(direction)
            }
        } else if dy != 0 {
            // Up or down slide: brightness, includes the momentum glide after a flick
            verticalPoints += dy
            let whole = Int(verticalPoints / pointsPerPercent)
            if whole != 0 {
                verticalPoints -= Double(whole) * pointsPerPercent
                pendingStep += whole
                pumpBrightness()
            }
        }
    }

    private func click() {
        guard !toggling else { return }
        toggling = true
        let (device, label) = destination()
        request(device, "toggle") { [weak self] reply in
            guard let self else { return }
            self.toggling = false
            guard let reply else { return }
            self.report(.toggled(label: label, on: reply.action != "off"))
        }
    }

    private func changeColour(_ direction: String) {
        guard !changingColour else { return }
        changingColour = true
        let (device, label) = destination()
        request(device, "preset", direction) { [weak self] reply in
            guard let self else { return }
            self.changingColour = false
            guard let reply else { return }
            self.report(.colour(label: label, name: reply.preset ?? "New colour", next: direction == "next"))
        }
    }

    /// Only one brightness request at a time. Movement that arrives meanwhile is added up and sent next,
    /// so a fast flick never floods the bulb.
    private func pumpBrightness() {
        guard !stepping, pendingStep != 0 else { return }
        let step = max(-50, min(50, pendingStep))
        pendingStep = 0
        stepping = true
        let (device, label) = destination()
        request(device, "step", String(step)) { [weak self] reply in
            guard let self else { return }
            if let reply {
                if let levels = reply.levels {
                    for (name, level) in levels { self.levelChanged(name, level) }
                } else if let level = reply.level {
                    self.levelChanged(device, level)
                }
                if let level = reply.level { self.report(.brightness(label: label, level: level, up: step > 0)) }
            }
            self.stepping = false
            self.pumpBrightness()
        }
    }

    // MARK: Bridge

    private func destination() -> (String, String) {
        if let t = target() { return (t.device, t.label) }
        return ("all", "All lights")
    }

    private func request(_ device: String, _ action: String, _ arg: String? = nil,
                         done: @escaping @MainActor @Sendable (MouseReply?) -> Void) {
        var url = bridge.appendingPathComponent(device).appendingPathComponent(action)
        if let arg { url = url.appendingPathComponent(arg) }
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                online(true)
                let reply = try? JSONDecoder().decode(MouseReply.self, from: data)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    done(reply)
                } else if action == "preset", (response as? HTTPURLResponse)?.statusCode == 400 {
                    report(.problem("The bridge needs updating for colours. Restart it with the new bulb_server.py."))
                    done(nil)
                } else {
                    report(.problem(reply?.error ?? "The bulb didn't respond. Check it's powered on."))
                    done(nil)
                }
            } catch {
                online(false)
                report(.problem("Can't reach the bulb bridge. Is bulb_server.py running?"))
                done(nil)
            }
        }
    }
}
