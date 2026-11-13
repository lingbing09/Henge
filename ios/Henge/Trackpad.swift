import SwiftUI
import UIKit

/// What the Apple Pencil does when its tip moves along the screen (Settings > Apple Pencil):
/// scroll, as on iPad (the default), or drag, as a mouse does.
enum PencilDrag: Int {
    case scroll = 0, drag = 1
    static let key = "henge.pencil.dragMode"
    static var current: PencilDrag { PencilDrag(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .scroll }
}

/// Whether the whole Mac screen is a writable area: writing on it with the pencil
/// types into the Mac (Settings > Apple Pencil). Off, the pencil is purely a
/// pointer -- a tap clicks and moving scrolls or drags -- and never opens the
/// keyboard. Off by default, so Scribble only takes the pencil when asked; while
/// it is on, the whole screen is writable, so every pencil touch reads as a
/// stroke rather than a tap.
enum PencilScribble {
    static let key = "henge.pencil.scribble"
    static var current: Bool { UserDefaults.standard.bool(forKey: key) }
}

/// A surface that works like a Mac's trackpad — it is one: the engine presents it on
/// the Mac's USB bus as a Magic Trackpad 2, so the Mac's own multitouch engine sees
/// the fingers: two scroll, three swipe between Spaces and to Mission Control, four
/// show the session's hidden controls.
///
/// Clicking depends on the input mode (Settings > Trackpad):
///  - Touchscreen: the surface itself clicks. A quick tap is a left click, a quick
///    two-finger tap is a right click, and touching then holding presses the button
///    down so moving drags. These go out as mouse buttons alongside the pad's fingers.
///  - Volume buttons: the surface only points and gestures; the clicks live on the
///    volume keys (VolumeClicks), so a tap here does nothing.
/// Only fingers count: a real trackpad or mouse goes through HardwareMouse. The Apple
/// Pencil doesn't pretend to be a finger: it drives an absolute-position USB tablet the
/// Mac also sees, so the pointer lands where the tip touches, and a tap clicks. Moving
/// the tip along the glass scrolls as on iPad -- it rides the Magic Trackpad as a
/// two-finger gesture, so the Mac's own gesture engine scrolls, momentum and all --
/// or drags as a mouse does (PencilDrag). Writing on the screen types into the Mac
/// (Scribble; see IndirectScribble). While the pencil is active, fingers are ignored
/// (palm rejection), until half a second after it lifts.
struct Trackpad: UIViewRepresentable {
    /// Four fingers tapped together: the session shows its hidden controls.
    static let revealTap = Notification.Name("henge.trackpad.revealTap")
    /// A pencil started handwriting on the screen: the keyboard opens to take the text.
    static let scribbleFocus = Notification.Name("henge.trackpad.scribbleFocus")

    /// The Mac's display in this view's coordinates, for the pencil's absolute
    /// positioning; .zero where the surface isn't over the Mac's screen (the pencil
    /// does nothing there).
    var screen: CGRect = .zero

    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) { view.screen = screen }

    final class Surface: UIView, UIPointerInteractionDelegate {
        /// The emulated pad's sensor, in the Magic Trackpad 2's own units.
        private static let sensorW: Int32 = 8134
        private static let sensorH: Int32 = 5206
        private static let holdTime: TimeInterval = 0.4
        private static let tapTime: TimeInterval = 0.3
        private static let tapDistance: CGFloat = 8

        private struct Finger { var touch: UITouch; var id: Int32 }

        private var fingers: [Finger] = []
        private var freeIds = Set<Int32>(1...5) /* a touch screen reports five fingers at most */
        private var started = Date()
        private var travelled: CGFloat = 0
        private var mostFingers = 0
        private var touchesLogged = 0

        /* Touchscreen-mode clicking. */
        private var holding = false
        private var holdTimer: Timer?
        private let buzz = UIImpactFeedbackGenerator(style: .medium)
        private var tapsClick: Bool { VolumeClicks.inputMode == .touchscreen }

        /* The Apple Pencil (an absolute tablet to the Mac; see the type's doc). */
        var screen: CGRect = .zero
        private static let palmRest: TimeInterval = 0.5
        private var pencilActiveUntil = Date.distantPast
        private var pencilStarted = Date()
        private var pencilTravelled: CGFloat = 0
        /// While the pencil is on the glass (or just lifted), fingers are a resting palm.
        private var pencilActive: Bool { Date() < pencilActiveUntil }

        /* Scrolling with the tip is a two-finger gesture on the emulated pad, so the
           Mac's own gesture engine scrolls with momentum, as on iPad. The pair uses
           finger IDs a hand never gets. */
        private static let pencilFingerA: Int32 = 6
        private static let pencilFingerB: Int32 = 7
        private var pencilFingersDown = false

        /* Scribble: the screen is a writable area, so writing on it with the pencil
           types into the Mac. While a stroke is being read as handwriting it must not
           also drive the Mac's pointer. */
        var scribbleWriting = false
        private let scribble = IndirectScribble()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
            addInteraction(UIPointerInteraction(delegate: self))
            scribble.surface = self
            addInteraction(UIIndirectScribbleInteraction(delegate: scribble))
        }

        /// Over the Mac there is only the Mac's pointer, if iPadOS hasn't locked its own away.
        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? { .hidden() }

        required init?(coder: NSCoder) { fatalError("made in code") }

        /// Where the finger is on the pad's sensor, in its units.
        private func sensor(_ t: UITouch) -> (Int32, Int32) {
            let p = t.location(in: self)
            // One scale for both axes. The view and the pad's sensor are different
            // shapes, so stretching the view to fill the sensor would make a finger
            // move the pointer further on one axis than the other. Map the view to a
            // centred part of the sensor at a single scale instead.
            let w = max(Double(bounds.width), 1), h = max(Double(bounds.height), 1)
            let scale = min(Double(Self.sensorW) / w, Double(Self.sensorH) / h)
            let x = (Double(p.x) - w / 2) * scale + Double(Self.sensorW) / 2
            let y = (Double(p.y) - h / 2) * scale + Double(Self.sensorH) / 2
            return (Int32(min(max(x, 0), Double(Self.sensorW))),
                    Int32(min(max(y, 0), Double(Self.sensorH))))
        }

        /* A touch sample's own clock, in ms. The guest derives finger speed from the
           timestamp deltas, so reports must carry the sample time, not the moment we
           process the event -- otherwise a burst of samples reads as one enormous flick
           and scroll inertia goes wild on release. */
        private static func ms(_ t: TimeInterval) -> UInt32 { UInt32(truncatingIfNeeded: Int(t * 1000)) }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches where t.type == .pencil { pencilBegan(t) }
            let touches = touches.filter { $0.type == .direct }
            guard !touches.isEmpty, !pencilActive else { return }
            if fingers.isEmpty {
                started = Date()
                travelled = 0
                mostFingers = 0
                if tapsClick { buzz.prepare() }
            }
            for t in touches {
                guard let id = freeIds.min() else { break }
                freeIds.remove(id)
                fingers.append(Finger(touch: t, id: id))
                let (x, y) = sensor(t)
                henge_vm_touch(id, 0, x, y, Self.ms(t.timestamp))
                if touchesLogged < 12 {
                    touchesLogged += 1
                    HengeLog.log("input", "trackpad: finger \(id) down at \(x),\(y)")
                }
            }
            mostFingers = max(mostFingers, fingers.count)
            guard tapsClick else { return }
            if fingers.count >= 2 {
                cancelHold()
                if holding { /* a drag becomes a multi-finger gesture */
                    holding = false
                    henge_vm_mouse_button(0, 0)
                }
            } else {
                armHold()
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches where t.type == .pencil { pencilMoved(t, event: event) }
            guard !pencilActive else { return }
            var moved = false
            let ts = Self.ms(event?.timestamp ?? touches.first?.timestamp ?? 0)
            for t in touches where t.type == .direct {
                guard let i = fingers.firstIndex(where: { $0.touch == t }) else { continue }
                let now = t.location(in: self), before = t.previousLocation(in: self)
                travelled += abs(now.x - before.x) + abs(now.y - before.y)
                let (x, y) = sensor(t)
                henge_vm_touch(fingers[i].id, 1, x, y, ts)
                moved = true
            }
            /* Moving means pointing or a gesture, not a tap or a press-to-drag. */
            if tapsClick && travelled >= Self.tapDistance && !holding { cancelHold() }
            /* One frame with every finger that moved, so the guest sees a gesture's
               fingers move together rather than one at a time. */
            if moved { henge_vm_touch_frame(ts) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches where t.type == .pencil { pencilEnded(t) }
            lift(touches) /* only fingers it is already tracking, so a palm never gets here */
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches where t.type == .pencil { pencilEnded(t) }
            lift(touches)
        }

        /* The tip on the glass is the tablet's left button down in drag mode, so a tap
           clicks and moving drags. In scroll mode the button stays up and the travel
           becomes a two-finger scroll on the pad; only a quick still tap clicks. A
           stroke being read as handwriting (Scribble) drives nothing. */
        private func pencilBegan(_ t: UITouch) {
            pencilActiveUntil = Date().addingTimeInterval(Self.palmRest)
            pencilStarted = Date()
            pencilTravelled = 0
            pencilFingersDown = false
            guard screen.width > 1, screen.height > 1, !scribbleWriting else { return }
            let (x, y) = pencilPoint(t)
            /* The pointer lands where the tip touches. The scroll gesture's fingers wait
               for real travel (pencilMoved): a tap must never reach the pad as a
               two-finger tap, which the Mac would read as a right click. */
            henge_vm_tablet(x, y, PencilDrag.current == .drag ? 1 : 0)
            HengeLog.log("input", "pencil: down at \(x),\(y) mode \(PencilDrag.current.rawValue)")
        }

        private func pencilMoved(_ t: UITouch, event: UIEvent?) {
            pencilActiveUntil = Date().addingTimeInterval(Self.palmRest)
            guard screen.width > 1, screen.height > 1, !scribbleWriting else { return }
            for s in event?.coalescedTouches(for: t) ?? [t] {
                let (x, y) = pencilPoint(s)
                let before = s.previousLocation(in: self), now = s.location(in: self)
                pencilTravelled += abs(now.x - before.x) + abs(now.y - before.y)
                if PencilDrag.current == .drag {
                    henge_vm_tablet(x, y, 1)
                } else {
                    henge_vm_tablet(x, y, 0)
                    if pencilFingersDown {
                        scrollGesture(with: s, phase: 1)
                    } else if pencilTravelled >= Self.tapDistance {
                        scrollGesture(with: s, phase: 0) /* the stroke is a scroll: the pair lands */
                    }
                }
            }
        }

        private func pencilEnded(_ t: UITouch) {
            pencilActiveUntil = Date().addingTimeInterval(Self.palmRest)
            if pencilFingersDown { /* lift the pair; the Mac's momentum takes it from here */
                scrollGesture(with: t, phase: 2)
            }
            guard screen.width > 1, screen.height > 1, !scribbleWriting else { return }
            let (x, y) = pencilPoint(t)
            let quick = Date().timeIntervalSince(pencilStarted) < Self.tapTime
            if PencilDrag.current == .scroll && quick && pencilTravelled < Self.tapDistance {
                henge_vm_tablet(x, y, 1) /* a tap is still a left click */
                buzz.impactOccurred()
            }
            henge_vm_tablet(x, y, 0)
            StickyKeys.shared.releaseAll()
        }

        /// The scroll gesture's two fingers straddle the tip and move as one with it:
        /// down, moved or lifted, a hand's width apart, clear of the sensor's edges.
        private func scrollGesture(with t: UITouch, phase: Int32) {
            let ts = Self.ms(t.timestamp)
            let (sx, sy) = sensor(t)
            let gap: Int32 = 500
            let ax = min(max(sx, gap), Self.sensorW - gap)
            let ay = min(max(sy, gap), Self.sensorH - gap)
            henge_vm_touch(Self.pencilFingerA, phase, ax - gap, ay, ts)
            henge_vm_touch(Self.pencilFingerB, phase, ax + gap, ay, ts)
            henge_vm_touch_frame(ts)
            pencilFingersDown = phase != 2
        }

        /// Where the tip is on the Mac's display, as the tablet's 0..32767 coordinates.
        private func pencilPoint(_ t: UITouch) -> (Int32, Int32) {
            let p = t.location(in: self)
            let nx = min(max((p.x - screen.minX) / screen.width, 0), 1)
            let ny = min(max((p.y - screen.minY) / screen.height, 0), 1)
            return (Int32(nx * 32767), Int32(ny * 32767))
        }

        private func lift(_ touches: Set<UITouch>) {
            var lifted: [Int32] = []
            fingers.removeAll { finger in
                guard touches.contains(finger.touch), finger.touch.type == .direct else { return false }
                freeIds.insert(finger.id)
                lifted.append(finger.id)
                return true
            }
            guard !lifted.isEmpty else { return }
            let ts = Self.ms(touches.map(\.timestamp).max() ?? 0)
            for id in lifted { henge_vm_touch(id, 2, 0, 0, ts) }
            guard fingers.isEmpty else { return } /* fingers still down: the gesture goes on */
            /* The whole gesture is over. */
            if tapsClick {
                cancelHold()
                let quick = Date().timeIntervalSince(started) < Self.tapTime
                let still = travelled < Self.tapDistance
                if holding {
                    holding = false
                    henge_vm_mouse_button(0, 0) /* let go of the drag */
                } else if quick && still {
                    if mostFingers == 1 { click(0) }      /* a tap is a left click */
                    else if mostFingers == 2 { click(1) } /* a two-finger tap is a right click */
                }
            }
            if mostFingers >= 4, travelled < Self.tapDistance * 3, Date().timeIntervalSince(started) < Self.tapTime * 2 {
                NotificationCenter.default.post(name: Trackpad.revealTap, object: nil)
            }
            StickyKeys.shared.releaseAll()
        }

        /// A brief press of a mouse button: down then up.
        private func click(_ button: Int32) {
            henge_vm_mouse_button(button, 1)
            henge_vm_mouse_button(button, 0)
            buzz.impactOccurred()
        }

        /// A finger that stays put presses the left button down, so moving it drags.
        private func armHold() {
            cancelHold()
            let timer = Timer(timeInterval: Self.holdTime, repeats: false) { [weak self] _ in
                guard let self, self.fingers.count == 1, self.travelled < Self.tapDistance else { return }
                self.holding = true
                henge_vm_mouse_button(0, 1)
                self.buzz.impactOccurred()
            }
            RunLoop.main.add(timer, forMode: .common)
            holdTimer = timer
        }

        private func cancelHold() {
            holdTimer?.invalidate()
            holdTimer = nil
        }
    }
}

/// Scribble's view of the surface: the whole Mac screen is one writable element.
/// Focusing it opens the session's keyboard, whose typing view (a UITextInput)
/// takes the recognized text and types it into the Mac.
private final class IndirectScribble: NSObject, UIIndirectScribbleInteractionDelegate {
    private static let element = "mac"
    weak var surface: Trackpad.Surface?

    func indirectScribbleInteraction(_ interaction: UIInteraction, requestElementsIn rect: CGRect, completion: @escaping ([String]) -> Void) {
        /* Handwriting only when the switch is on; otherwise the pencil is a plain
           pointer and no element is writable, so Scribble leaves it alone. */
        let writable = PencilScribble.current && (surface?.screen.width ?? 0) > 1
        completion(writable ? [Self.element] : [])
    }

    func indirectScribbleInteraction(_ interaction: UIInteraction, isElementFocused element: String) -> Bool {
        KeyboardCatcher.sharedTyper?.isFirstResponder ?? false
    }

    func indirectScribbleInteraction(_ interaction: UIInteraction, frameForElement element: String) -> CGRect {
        surface?.screen ?? .zero
    }

    func indirectScribbleInteraction(_ interaction: UIInteraction, focusElementIfNeeded element: String, referencePoint: CGPoint, completion: @escaping ((UIResponder & UITextInput)?) -> Void) {
        NotificationCenter.default.post(name: Trackpad.scribbleFocus, object: nil)
        /* Opening the keyboard goes through SwiftUI, so wait until the typing view is
           really the first responder before handing it over. */
        var tries = 0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            tries += 1
            guard tries <= 20 else {
                timer.invalidate()
                completion(KeyboardCatcher.sharedTyper)
                return
            }
            guard let typer = KeyboardCatcher.sharedTyper, typer.isFirstResponder else { return }
            timer.invalidate()
            completion(typer)
        }
    }

    func indirectScribbleInteraction(_ interaction: UIInteraction, willBeginWritingInElement element: String) {
        surface?.scribbleWriting = true
    }

    func indirectScribbleInteraction(_ interaction: UIInteraction, didFinishWritingInElement element: String) {
        surface?.scribbleWriting = false
    }
}

/// One mouse button you can hold: down when touched, up when let go.
struct MouseButton: View {
    let title: String
    let button: Int32
    @State private var down = false

    var body: some View {
        Text(title)
            .font(.system(size: 15))
            .foregroundStyle(down ? Desk.text : Desk.dim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(down ? Desk.raised : Color.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !down else { return }
                        down = true
                        henge_vm_mouse_button(button, 1)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .onEnded { _ in
                        down = false
                        henge_vm_mouse_button(button, 0)
                        StickyKeys.shared.releaseAll()
                    }
            )
            .accessibilityLabel(title)
    }
}