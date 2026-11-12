import Foundation
import simd

/// Where a camera puts the eye for one frame.
struct CameraPose {
    var eye: SIMD3<Float>
    var target: SIMD3<Float>
    /// Degrees around the view axis.
    var roll: Float
    /// Vertical field of view in degrees.
    var fov: Float
}

/// The camera tools. Each one has its own knobs and its own motion; they all end in a pose.
enum CameraRig: String, CaseIterable {
    case orbit
    case still = "static"
    case fly
    case cutter
    case lissajous

    var label: String {
        switch self {
        case .orbit: return "Orbit Camera"
        case .still: return "Static Camera"
        case .fly: return "Fly-through Camera"
        case .cutter: return "Cutter Camera"
        case .lissajous: return "Lissajous Camera"
        }
    }

    var icon: String {
        switch self {
        case .orbit: return "rotate.3d"
        case .still: return "camera"
        case .fly: return "airplane"
        case .cutter: return "scissors"
        case .lissajous: return "infinity"
        }
    }

    var defs: [ParamDef] {
        func p(_ name: String, _ d: Float, _ lo: Float, _ hi: Float, _ group: String, int: Bool = false) -> ParamDef {
            ParamDef(name: name, defaultValue: d, min: lo, max: hi, isInt: int, group: group)
        }
        let look = [p("lookX", 0, -10, 10, "Target"), p("lookY", 0, -10, 10, "Target"), p("lookZ", 0, -10, 10, "Target")]
        let wobble = [p("shake", 0, 0, 1, "Wobble"), p("shakeSpeed", 1, 0, 4, "Wobble")]
        switch self {
        case .orbit:
            return [
                // Where on the orbit: added to the integrated orbit, so it can be mapped or set by hand.
                p("angle", 0, -180, 180, "Position"),
                p("distance", 6, 0.5, 40, "Position"),
                p("height", 1, -15, 15, "Position"),
                // Tilts the orbit's circle, so the camera climbs over one side and dips under the other.
                p("tilt", 0, -90, 90, "Position"),
            ] + look + [
                p("orbitSpeed", 0.15, -3, 3, "Motion"),
                // 0 orbits all the way round; above 0 the camera swings back and forth this many
                // degrees either side of `angle` instead, for things meant to be seen face-on.
                p("swing", 0, 0, 180, "Motion"),
                // 0 moves smoothly; above that the camera jumps between this many positions round the orbit.
                p("snap", 0, 0, 16, "Motion", int: true),
                p("bob", 0, 0, 5, "Motion"),
                p("bobSpeed", 0.5, 0, 4, "Motion"),
                p("fov", 55, 10, 150, "Lens"),
                p("roll", 0, -180, 180, "Lens"),
                p("rollSpeed", 0, -2, 2, "Lens"),
                p("sway", 0.2, 0, 2, "Wobble"),
                p("swaySpeed", 1, 0, 4, "Wobble"),
            ] + wobble
        case .still:
            return [
                p("x", 6, -30, 30, "Position"),
                p("y", 1, -30, 30, "Position"),
                p("z", 0, -30, 30, "Position"),
            ] + look + [
                p("fov", 55, 10, 150, "Lens"),
                p("roll", 0, -180, 180, "Lens"),
            ]
        case .fly:
            return [
                // Units per second along -z; the path wraps every `length` units, centred on the origin.
                p("speed", 1, -10, 10, "Path"),
                p("length", 20, 2, 100, "Path"),
                p("height", 1, -10, 10, "Path"),
                p("lane", 0, -10, 10, "Path"),
                p("weave", 0.5, 0, 5, "Weave"),
                p("weaveSpeed", 0.5, 0, 4, "Weave"),
                // Rolls into the weave's turns, like a plane banking.
                p("bank", 0, 0, 1, "Weave"),
                p("pitch", 0, -89, 89, "Look"),
                p("yaw", 0, -180, 180, "Look"),
                p("fov", 70, 10, 150, "Look"),
            ] + wobble
        case .cutter:
            return [
                // Automatic cuts per second; 0 cuts only on its Cut trigger.
                p("rate", 0.5, 0, 8, "Cuts"),
                // Seconds to ease into the next shot; 0 is a hard cut.
                p("glide", 0, 0, 2, "Cuts"),
                p("minDistance", 3, 0.5, 40, "Shots"),
                p("maxDistance", 9, 0.5, 40, "Shots"),
                p("minHeight", -3, -15, 15, "Shots"),
                p("maxHeight", 5, -15, 15, "Shots"),
                p("minFov", 30, 10, 150, "Shots"),
                p("maxFov", 90, 10, 150, "Shots"),
                p("rollRange", 0, 0, 180, "Shots"),
                // How fast a held shot creeps round the target, in a random direction per shot.
                p("drift", 0.1, 0, 2, "Shots"),
            ] + look + wobble
        case .lissajous:
            return [
                p("speed", 0.05, -2, 2, "Path"),
                // Cycles of azimuth, elevation and distance per turn of the path.
                p("freqA", 1, 0, 8, "Path"),
                p("freqB", 2, 0, 8, "Path"),
                p("freqC", 3, 0, 8, "Path"),
                p("radius", 6, 0.5, 40, "Shape"),
                p("depth", 2, 0, 20, "Shape"),
                p("elevation", 45, 0, 89, "Shape"),
            ] + look + [
                // The target traces its own, smaller figure.
                p("wander", 0, 0, 5, "Target"),
                p("fov", 55, 10, 150, "Lens"),
                p("roll", 0, -180, 180, "Lens"),
            ] + wobble
        }
    }
}

/// A camera's integrated motion, so speed changes never jump. Each scene has its own, so two
/// scenes in a crossfade each move at their own speed. Render thread only, after init.
final class CameraMotion {
    let rig: CameraRig

    /// Orbit angle in radians (orbit), or path phase in turns (lissajous).
    var orbit: Float = 0
    /// Degrees of accumulated roll.
    var roll: Float = 0
    var sway: Float = 0
    var shake: Float = 0
    var bob: Float = 0
    var weave: Float = 0
    /// Fly-through distance travelled.
    var travel: Float = 0

    /// Cutter: the shot being left and the one being cut to, the glide between them, and the
    /// flash the `flash` output reads.
    struct Shot {
        /// Radians round the target.
        var angle: Float = 0
        /// 0...1 within the knobs' ranges, so turning a range knob reframes the shot live.
        var distance: Float = 0.5, height: Float = 0.5, fov: Float = 0.5
        /// -1...1 of `rollRange`.
        var roll: Float = 0
        /// -1 or 1: which way it drifts.
        var direction: Float = 1
    }
    var from = Shot()
    var to = Shot()
    var glide: Float = 1
    var sinceCut: Float = 0
    var cutFlash: Float = 0
    /// Cutter: set on the frame it cuts, for its On Cut output.
    private var didCut = false
    /// The Cutter's Cut input (`camera.cut`): each fire cuts to a new shot. Kept across
    /// rebuilds with the motion.
    let cutTrigger = TriggerInput("camera.cut", "Cut")
    private var rng: UInt64 = 0x9E37_79B9_7F4A_7C15

    /// Outputs, 0...1, set by `advance`.
    private(set) var phaseOutput: Float = 0

    /// Picks up where another scene's camera is, so switching scenes doesn't jump the orbit.
    init(_ rig: CameraRig, continuing old: CameraMotion? = nil) {
        self.rig = rig
        orbit = old?.rig == rig ? old!.orbit : 0
        roll = old?.roll ?? 0
        sway = old?.sway ?? 0
    }

    /// Steps the motion by one frame and returns where the camera is.
    func advance(_ c: ParamBank, frame f: FrameUniforms) -> CameraPose {
        let dt = f.dt
        func v(_ name: String) -> Float { c.live(name) }
        shake += v("shakeSpeed") * dt
        let jitter = SIMD3<Float>(sin(shake * 31.7), sin(shake * 23.3 + 2), sin(shake * 27.1 + 4)) * v("shake") * 0.25
        let look = SIMD3<Float>(v("lookX"), v("lookY"), v("lookZ"))

        switch rig {
        case .orbit:
            orbit += v("orbitSpeed") * dt
            roll += v("rollSpeed") * 90 * dt
            sway += v("swaySpeed") * dt
            bob += v("bobSpeed") * dt
            let swing = v("swing")
            var angle = (swing > 0 ? sin(orbit) * swing * .pi / 180 : orbit) + v("angle") * .pi / 180
            let snap = v("snap")
            if snap >= 1 { let step = 2 * .pi / snap; angle = (angle / step).rounded() * step }
            phaseOutput = { let x = angle / (2 * .pi); return x - floor(x) }()
            let dist = v("distance"), tilt = v("tilt") * .pi / 180
            // The orbit circle, tilted about the x axis.
            let flat = SIMD3<Float>(cos(angle) * dist, 0, sin(angle) * dist)
            var eye = SIMD3<Float>(flat.x, flat.z * sin(tilt), flat.z * cos(tilt))
            eye.y += v("height") + sin(bob * 2 * .pi) * v("bob")
            eye += SIMD3(sin(sway * 0.37), cos(sway * 0.23) * 0.5, sin(sway * 0.29 + 1)) * v("sway")
            return CameraPose(eye: eye + jitter, target: look, roll: v("roll") + roll, fov: v("fov"))

        case .still:
            return CameraPose(eye: SIMD3(v("x"), v("y"), v("z")), target: look, roll: v("roll"), fov: v("fov"))

        case .fly:
            travel += v("speed") * dt
            weave += v("weaveSpeed") * dt
            let length = v("length")
            let progress = travel / length - floor(travel / length)
            phaseOutput = progress
            let w = weave * 2 * .pi, amount = v("weave")
            let eye = SIMD3<Float>(v("lane") + sin(w) * amount, v("height") + sin(w * 0.5 + 1) * amount * 0.4,
                                   length * 0.5 - progress * length)
            let yaw = v("yaw") * .pi / 180, pitch = v("pitch") * .pi / 180
            let forward = SIMD3<Float>(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
            // Bank against the weave's sideways velocity.
            let bank = -cos(w) * min(amount, 1) * v("bank") * 45
            return CameraPose(eye: eye + jitter, target: eye + forward, roll: bank, fov: v("fov"))

        case .cutter:
            sinceCut += dt
            cutFlash = max(cutFlash - dt * 4, 0)
            var cut = cutTrigger.take()
            let rate = v("rate")
            if rate > 0 && sinceCut >= 1 / rate { cut = true }
            if cut { cutTo(next: current) }
            let glideTime = v("glide")
            glide = glideTime > 0 ? min(glide + dt / glideTime, 1) : 1
            to.angle += to.direction * v("drift") * dt
            let shot = current
            func range(_ lo: String, _ hi: String, _ u: Float) -> Float { v(lo) + (v(hi) - v(lo)) * u }
            let dist = range("minDistance", "maxDistance", shot.distance)
            let eye = look + SIMD3(cos(shot.angle) * dist, range("minHeight", "maxHeight", shot.height), sin(shot.angle) * dist)
            return CameraPose(eye: eye + jitter, target: look, roll: shot.roll * v("rollRange"),
                              fov: range("minFov", "maxFov", shot.fov))

        case .lissajous:
            orbit += v("speed") * dt
            phaseOutput = orbit - floor(orbit)
            let t = orbit * 2 * .pi
            let az = t * v("freqA"), el = sin(t * v("freqB")) * v("elevation") * .pi / 180
            let dist = max(v("radius") + sin(t * v("freqC")) * v("depth"), 0.3)
            let wander = SIMD3<Float>(sin(t * 3 + 1), sin(t * 2), cos(t * 5)) * v("wander")
            let eye = look + SIMD3(cos(az) * cos(el), sin(el), sin(az) * cos(el)) * dist
            return CameraPose(eye: eye + jitter, target: look + wander, roll: v("roll"), fov: v("fov"))
        }
    }

    /// The cutter's shot right now, partway through any glide.
    private var current: Shot {
        guard glide < 1 else { return to }
        let k = glide * glide * (3 - 2 * glide)
        var delta = remainder(to.angle - from.angle, 2 * .pi)
        if !delta.isFinite { delta = 0 }
        return Shot(angle: from.angle + delta * k,
                    distance: from.distance + (to.distance - from.distance) * k,
                    height: from.height + (to.height - from.height) * k,
                    fov: from.fov + (to.fov - from.fov) * k,
                    roll: from.roll + (to.roll - from.roll) * k,
                    direction: to.direction)
    }

    private func cutTo(next start: Shot) {
        from = start
        to = Shot(angle: random() * 2 * .pi, distance: random(), height: random(), fov: random(),
                  roll: random() * 2 - 1, direction: random() < 0.5 ? -1 : 1)
        glide = 0
        sinceCut = 0
        cutFlash = 1
        didCut = true
    }

    /// 0..<1 from a xorshift, so cuts allocate nothing and never touch a global generator.
    private func random() -> Float {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Float(rng >> 40) / Float(1 << 24)
    }

    /// The camera's trigger inputs: the Cutter's Cut.
    var triggerInputs: [TriggerInput] { rig == .cutter ? [cutTrigger] : [] }

    /// The camera's value and trigger outputs.
    var outputs: [OutputSignal] {
        switch rig {
        case .orbit: return [OutputSignal("camera.angle", "Orbit Angle", device: "Camera") { _ in self.phaseOutput }]
        case .still: return []
        case .fly: return [OutputSignal("camera.progress", "Progress", device: "Camera") { _ in self.phaseOutput }]
        case .cutter: return [
            OutputSignal.trigger("camera.onCut", "On Cut", device: "Camera") { _ in
                defer { self.didCut = false }
                return self.didCut
            },
            OutputSignal("camera.flash", "Cut Flash", device: "Camera") { _ in self.cutFlash },
        ]
        case .lissajous: return [OutputSignal("camera.phase", "Phase", device: "Camera") { _ in self.phaseOutput }]
        }
    }
}
