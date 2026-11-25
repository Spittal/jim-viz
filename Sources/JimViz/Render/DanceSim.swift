import Metal
import simd

typealias V3 = SIMD3<Float>

/// The Dancer: plays its style's motion-capture performances on its body's skeleton, on the
/// CPU, and writes each bone for dancer.metal to place its mesh on.
///
/// A performance is danced to the beat, not the clock: its beats land on the dance's (`tempo`'s
/// phase, which follows Audio In · Sync when that's mapped in), however fast those come, so it
/// speeds up and slows down with the music. Each is picked from the style's for a tempo near the
/// music's (on the beat; half or double time only when that's much nearer), plays its whole
/// bars, and hands over to the next on a bar line. The next starts where the dancer is, facing
/// the way it faces, and eases back to its own place and facing over a few bars, too slowly to
/// see as more than the dance drifting; the rest of the difference between the two poses, and
/// their speeds, dies away in a fraction of a second (inertialization), so there's no pop.
///
/// The clip turns the joints; the body supplies the bone lengths, and the hips ride at the
/// clip's height in the body's own hip heights, so short legs take short steps. A foot the
/// body's proportions would push through the floor is lifted back onto it by bending its knee.
/// The ponytail swings on springs of its own, and the belly jiggles as the hips bounce.
///
/// Writes, each step, into the next of four buffers, three float4s per bone (`DancerModel` order):
/// (start, length), (direction, width), (sideways, 1 where clothed). Must match dancer.metal.
final class DanceSim: GeoSim {
    static let floorY: Float = -1
    /// How far from its own tempo a performance is happily played, in octaves: about a fifth
    /// faster or slower. Further is fine when the style has nothing nearer.
    private static let stretch: Float = 0.28
    /// What dancing at half or double time costs against dancing on the beat, in octaves: it
    /// reads as floaty or frantic, so only when it's much nearer.
    private static let foldCost: Float = 0.35
    /// Over how many beats a new performance eases from where the last left the dancer to its own place.
    private static let settle = 32.0
    /// How long a handover's difference takes to halve, seconds: longer the further apart the
    /// two poses are, so a big change of shape is eased into rather than snapped.
    private static func halfLife(_ angle: Float) -> Float { min(max(0.15 + 0.12 * angle, 0.15), 0.45) }
    /// The most speed a handover carries over from the last performance, radians a second a joint.
    private static let carry: Float = 5
    private static let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    /// With no clip to dance, it stands with its arms down.
    private static let standing: MotionPose = {
        var p = MotionPose()
        p.rotations[DancerModel.Joint.shoulderL] = simd_quatf(from: [0, 0, -1], to: simd_normalize([0, -1, -0.22]))
        p.rotations[DancerModel.Joint.shoulderR] = simd_quatf(from: [0, 0, 1], to: simd_normalize([0, -1, 0.22]))
        return p
    }()

    private let buffers: [MTLBuffer]
    private var index = 0
    var current: MTLBuffer { buffers[index] }
    private var out = [SIMD4<Float>](repeating: .zero, count: DancerModel.boneCount * 3)

    // Playback.
    private var started = false
    private var lastBeat = 0.0, lastDt: Float = 1.0 / 60
    /// The music's tempo as the beat shows it, before the tempo knob.
    private var liveBPM: Float = 120
    private var style = -1
    private(set) var clip: MotionClip?
    /// The dance beat the clip's first beat fell on, and how many of the clip's beats pass a dance beat.
    private(set) var startBeat = 0.0, fold = 1.0
    private var rng = SplitMix(seed: 0xDA2CE)
    /// The performances it last danced, oldest overwritten first.
    private var recent = [String](repeating: "", count: 4), recentIndex = 0
    /// The turn (about up) and shift (over the floor, hip heights) that put the performance where
    /// the last one left the dancer, at its start; they ease off over `settle` beats.
    private var alignYaw: Float = 0, alignShift = SIMD2<Float>.zero
    /// The clip's pose now and a moment ago; the pose shown, and the one shown before it.
    private var sample = MotionPose(), earlier = MotionPose()
    private(set) var pose = MotionPose()
    private var before = MotionPose()

    // A handover: how far the pose shown was from the new clip's when it took over, as a turn
    // for each joint (axis × angle) and a shift of the hips, and how fast that was changing.
    private var blending = false, blendTime: Float = 0, blendHalfLife: Float = 0.15
    /// A performance's opening pose, to see how near it is to the dancer's.
    private var opening = MotionPose()
    private var turn = [V3](repeating: .zero, count: DancerModel.jointCount), turnRate = [V3](repeating: .zero, count: DancerModel.jointCount)
    private var shift = V3.zero, shiftRate = V3.zero

    /// Each joint, posed: its turn and place in the geo's space, before scale.
    private(set) var world = [simd_quatf](repeating: DanceSim.identity, count: DancerModel.jointCount)
    private(set) var position = [V3](repeating: .zero, count: DancerModel.jointCount)

    private var time: Float = 0
    /// The ponytail's two segment ends and their velocities.
    private var hair = [V3](repeating: .zero, count: 2), hairVelocity = [V3](repeating: .zero, count: 2)
    private var belly: Float = 0, bellyVelocity: Float = 0
    private var lastRootY: Float = 0, rootVelocity: Float = 0
    /// Which way each knee stuck out from the line of its leg, last frame.
    private var kneeSide = [V3](repeating: [1, 0, 0], count: 2)

    init(device: MTLDevice) {
        // Unpacks the clips now, while the scene is built, not on the render thread's first step.
        _ = MotionLibrary.clips
        let length = out.count * MemoryLayout<SIMD4<Float>>.stride
        buffers = (0..<4).map { _ in device.makeBuffer(length: length, options: .storageModeShared)! }
    }

    func step(_ bank: ParamBank, dt rawDt: Float, spectrum: SpectrumTextures?) {
        let dt = min(max(rawDt, 0), 0.1)
        time += dt
        let model = DancerModel.all[min(max(Int(bank.live("model").rounded()), 0), DancerModel.all.count - 1)]
        let wanted = min(max(Int(bank.live("style").rounded()), 0), MotionLibrary.styles.count - 1)
        let clips = MotionLibrary.clips[wanted]
        // nudge moves the dance against the beat, to sit it on the music by eye.
        let beat = (bank["tempo"]?.phase ?? 0) * 2 + Double(bank.live("nudge"))
        // A jump of the beat (seeking, a First Beat tap) puts it straight into the pose there. A
        // long frame at a fast tempo is not one: it's as far as the beat should have got.
        let stride = beat - lastBeat, due = Double(liveBPM * max(bank.live("tempo"), 0) / 60 * max(rawDt, 0))
        let jumped = !started || stride < -0.45 || stride > max(0.45, due * 3)
        if !jumped, dt > 0, beat > lastBeat {
            let knob = max(bank.live("tempo"), 0.05)
            liveBPM += (Float(beat - lastBeat) / dt * 60 / knob - liveBPM) * min(1, dt * 2)
        }

        var handover = false
        if clips.isEmpty {
            handover = clip != nil && !jumped
            clip = nil
            copy(Self.standing, to: &sample)
            copy(Self.standing, to: &earlier)
        } else {
            if jumped || clip == nil || wanted != style {
                handover = started && !jumped
                cue(clips, at: (beat / 4).rounded(.down) * 4)
            }
            var into = (beat - startBeat) * fold
            while into >= span {
                let end = startBeat + span / fold
                handover = !jumped
                cue(clips, at: end)
                into = (beat - startBeat) * fold
            }
            let c = clip!
            let seconds = c.firstBeat + Float(into) * 60 / c.bpm
            c.sample(seconds, into: &sample)
            if handover {
                c.sample(seconds - Float(beat - lastBeat) * Float(fold) * 60 / c.bpm, into: &earlier)
                // Where the dancer is and which way it faces, against where the performance starts.
                alignYaw = Self.heading(pose.rotations[0]) - Self.heading(sample.rotations[0])
                alignYaw = atan2(sin(alignYaw), cos(alignYaw))
                let start = simd_quatf(angle: alignYaw, axis: [0, 1, 0]).act(sample.root)
                alignShift = SIMD2(pose.root.x - start.x, pose.root.z - start.z)
            } else if jumped {
                alignYaw = 0; alignShift = .zero
            }
            let settling = Float(1 - Self.smoothstep((beat - startBeat) / Self.settle))
            align(&sample, settling)
            if handover { align(&earlier, settling) }
        }
        style = wanted

        if jumped {
            blending = false
            copy(sample, to: &pose)
            copy(sample, to: &before)
        } else {
            if handover { startBlend(dt) }
            swap(&pose, &before)
            show(dt)
        }
        solve(model, bank, dt: dt, settle: jumped)
        lastBeat = beat
        if dt > 0 { lastDt = dt }
        started = true

        index = (index + 1) % buffers.count
        out.withUnsafeBytes { buffers[index].contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    }

    /// How far a performance's tempo is from the music's, in octaves, danced on the beat, or at
    /// half or double time where that's nearer by more than `foldCost`; and which that is, in its
    /// beats a dance beat.
    private func fit(_ c: MotionClip) -> (distance: Float, fold: Double) {
        var best: (Float, Double) = (abs(log2(liveBPM / c.bpm)), 1)
        let half = abs(log2(liveBPM * 0.5 / c.bpm)) + Self.foldCost, double = abs(log2(liveBPM * 2 / c.bpm)) + Self.foldCost
        if half < best.0 { best = (half, 0.5) }
        if double < best.0 { best = (double, 2) }
        return best
    }

    /// How many of the clip's beats it plays: its whole bars, and at double time only as many as
    /// end on one of the dance's bar lines, so the next starts on a bar line too.
    private var span: Double {
        let bar = 4 * max(fold, 1), beats = Double(clip!.beats)
        return max((beats / bar).rounded(.down) * bar, min(bar, beats))
    }

    /// Picks the style's next performance to start on dance beat `beat`: from those within a
    /// fifth or so of the music's tempo, or if that's fewer than four, the four nearest, and not
    /// danced in its last four (or last one, if that's all it can manage), three at random, and
    /// of those the one that opens nearest the dancer's pose now, so the handover is small.
    private func cue(_ clips: [MotionClip], at beat: Double) {
        var limit = Self.stretch, within = 0
        for c in clips where fit(c).distance <= limit { within += 1 }
        let pool = min(4, clips.count)
        if within < pool {
            // The pool-th nearest's distance.
            var below: Float = -1
            for _ in 0..<pool {
                var next = Float.infinity
                for c in clips { let d = fit(c).distance; if d > below && d < next { next = d } }
                below = next
            }
            limit = below
        }
        func fresh(_ c: MotionClip, _ back: Int) -> Bool {
            for k in 0..<back where recent[(recentIndex + recent.count - 1 - k) % recent.count] == c.name { return false }
            return true
        }
        for back in [recent.count, 1, 0] {
            var count = 0
            for c in clips where fit(c).distance <= limit && fresh(c, back) { count += 1 }
            guard count > 0 else { continue }
            var best = Float.infinity
            for _ in 0..<min(3, count) {
                var pick = min(Int(rng.nextFloat() * Float(count)), count - 1)
                for c in clips where fit(c).distance <= limit && fresh(c, back) {
                    if pick > 0 { pick -= 1; continue }
                    let gap = started ? distance(to: c) : 0
                    if gap < best { best = gap; clip = c; fold = fit(c).fold }
                    break
                }
            }
            break
        }
        recent[recentIndex] = clip!.name
        recentIndex = (recentIndex + 1) % recent.count
        startBeat = beat
    }

    /// How far a performance's opening pose is from the one shown: the joints' turns from their
    /// parents, in radians, added up (the hips' only for how they tip, not which way they face).
    private func distance(to c: MotionClip) -> Float {
        c.sample(c.firstBeat, into: &opening)
        var total: Float = 0
        for j in 1..<DancerModel.jointCount { total += simd_length(Self.log(pose.rotations[j] * opening.rotations[j].inverse)) }
        let up = V3(0, 1, 0)
        return total + acos(min(max(simd_dot(pose.rotations[0].act(up), opening.rotations[0].act(up)), -1), 1))
    }

    /// Which way a turn faces the hips, about up: 0 to the front, turning to its left.
    private static func heading(_ q: simd_quatf) -> Float {
        let f = q.act([1, 0, 0])
        return atan2(-f.z, f.x)
    }

    private static func smoothstep(_ x: Double) -> Double { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }

    /// Turns and shifts a pose by the handover's alignment, `amount` of it.
    private func align(_ p: inout MotionPose, _ amount: Float) {
        guard amount > 0, alignYaw != 0 || alignShift != .zero else { return }
        let turn = simd_quatf(angle: alignYaw * amount, axis: [0, 1, 0])
        p.rotations[0] = turn * p.rotations[0]
        let r = turn.act(p.root)
        p.root = SIMD3(r.x + alignShift.x * amount, r.y, r.z + alignShift.y * amount)
    }

    private func copy(_ a: MotionPose, to b: inout MotionPose) {
        b.root = a.root
        for j in 0..<DancerModel.jointCount { b.rotations[j] = a.rotations[j] }
    }

    /// A turn as axis × angle, the short way round.
    private static func log(_ q: simd_quatf) -> V3 {
        let v = q.imag, l = simd_length(v)
        guard l > 1e-6 else { return .zero }
        let sign: Float = q.real < 0 ? -1 : 1
        return v * (sign * 2 * atan2(l, abs(q.real)) / l)
    }

    private static func exp(_ v: V3) -> simd_quatf {
        let a = simd_length(v)
        return a > 1e-6 ? simd_quatf(angle: a, axis: v / a) : identity
    }

    /// A handover begins: `pose` and `before` are the last two shown, `sample` and `earlier`
    /// the new clip's now and a frame ago. Whatever was left of the last handover is in `pose`,
    /// so it carries on in this one.
    private func startBlend(_ dt: Float) {
        let was = 1 / lastDt, now = 1 / max(dt, 1e-4)
        var widest: Float = 0
        for j in 0..<DancerModel.jointCount {
            turn[j] = Self.log(pose.rotations[j] * sample.rotations[j].inverse)
            if j > 0 { widest = max(widest, simd_length(turn[j])) }
            let old = Self.log(pose.rotations[j] * before.rotations[j].inverse) * was
            let new = Self.log(sample.rotations[j] * earlier.rotations[j].inverse) * now
            var rate = old - new
            if simd_length(rate) > Self.carry { rate *= Self.carry / simd_length(rate) }
            turnRate[j] = rate
        }
        shift = pose.root - sample.root
        shiftRate = (pose.root - before.root) * was - (sample.root - earlier.root) * now
        blendHalfLife = Self.halfLife(widest)
        blending = true
        blendTime = 0
    }

    /// The pose to show: the clip's, plus what's left of the handover's difference. It decays as
    /// a critically damped spring let go with the difference and the speed it started with.
    private func show(_ dt: Float) {
        guard blending else { copy(sample, to: &pose); return }
        blendTime += dt
        let y = 2 * Float(M_LN2) / blendHalfLife, t = blendTime, e = expf(-y * t)
        for j in 0..<DancerModel.jointCount {
            pose.rotations[j] = Self.exp((turn[j] + (turnRate[j] + turn[j] * y) * t) * e) * sample.rotations[j]
        }
        pose.root = sample.root + (shift + (shiftRate + shift * y) * t) * e
        if t > blendHalfLife * 12 { blending = false }
    }

    // MARK: The body

    /// Two-bone IK: where the knee goes, reaching from `a` to `t` with bones `l1` and `l2`, bent toward `pole`.
    private static func bend(_ a: V3, _ t: V3, _ l1: Float, _ l2: Float, pole: V3) -> V3 {
        let d = t - a
        let length = simd_length(d)
        let dir = length > 1e-5 ? d / length : V3(0, -1, 0)
        guard l1 > 1e-4, l2 > 1e-4 else { return a + dir * l1 }
        let dist = min(max(length, abs(l1 - l2) + 1e-4), (l1 + l2) * 0.9999)
        let cosA = min(max((l1 * l1 + dist * dist - l2 * l2) / (2 * l1 * dist), -1), 1)
        var side = pole - simd_dot(pole, dir) * dir
        if simd_length(side) < 1e-4 { side = simd_cross(dir, V3(0, 0, 1)) }
        return a + dir * (l1 * cosA) + simd_normalize(side) * (l1 * (1 - cosA * cosA).squareRoot())
    }

    private func bone(_ i: Int, start: V3, dir: V3, side: V3, length: Float, width: Float) {
        out[i * 3] = SIMD4(start, length)
        out[i * 3 + 1] = SIMD4(dir, width)
        out[i * 3 + 2] = SIMD4(side, DancerModel.clothed(i) ? 1 : 0)
    }

    private func solve(_ m: DancerModel, _ bank: ParamBank, dt: Float, settle: Bool) {
        typealias J = DancerModel.Joint
        typealias B = DancerModel.Bone
        let limb = max(bank.live("limbLength"), 0), width = max(bank.live("limbWidth"), 0)
        let headSize = max(bank.live("headSize"), 0), fat = max(bank.live("belly"), 0)
        let jiggle = max(bank.live("jiggle"), 0), travel = max(bank.live("travel"), 0)
        let thigh = m.lengths[J.hipL] * limb, shin = m.lengths[J.kneeL] * limb
        let up = V3(0, 1, 0)

        // Forward kinematics: the hips at the clip's height in this body's hip heights, then
        // each joint out from its parent along this body's bones.
        let hipHeight = m.ankleHeight + thigh + shin
        world[0] = pose.rotations[0]
        position[0] = V3(pose.root.x * hipHeight * travel, Self.floorY + pose.root.y * hipHeight, pose.root.z * hipHeight * travel)
        for j in 1..<DancerModel.jointCount {
            let p = DancerModel.parents[j]
            world[j] = world[p] * pose.rotations[j]
            position[j] = position[p] + world[p].act(m.offsets[j] * (DancerModel.limbJoints.contains(j) ? limb : 1))
        }

        // A body whose proportions put a hand, its head or its back under the floor (a breaker on
        // the ground, danced by an ogre) rides higher by as much.
        var lowest = Float.infinity
        for j in 0..<DancerModel.jointCount where j != J.ankleL && j != J.ankleR && j != J.toesL && j != J.toesR {
            lowest = min(lowest, position[j].y)
        }
        let sunk = Self.floorY + 0.05 - lowest
        if sunk > 0 { for j in 0..<DancerModel.jointCount { position[j].y += sunk } }

        // A foot under the floor comes back up onto it, the knee bending out the way the dance's
        // does from the new line of the leg. That way only goes vague as the leg straightens, when
        // the knee is on the line anyway: then it keeps the way it last had.
        for side in 0..<2 {
            let hip = J.hipL + side, knee = J.kneeL + side, ankle = J.ankleL + side, toes = J.toesL + side
            let under = Self.floorY - min(position[ankle].y - m.ankleHeight * 0.8, position[toes].y - m.ballHeight)
            let target = position[ankle] + up * max(under, 0)
            let line = target - position[hip]
            let dir = simd_length(line) > 1e-5 ? simd_normalize(line) : -up
            let out = position[knee] - position[hip] - dir * simd_dot(position[knee] - position[hip], dir)
            let sure = min(simd_length(out) / max(0.2 * thigh, 1e-4), 1)
            var way = kneeSide[side] - dir * simd_dot(kneeSide[side], dir)
            way = simd_length(way) > 1e-5 ? simd_normalize(way) : (simd_length(out) > 1e-6 ? simd_normalize(out) : world[hip].act([1, 0, 0]))
            if simd_length(out) > 1e-6 { way = way * (1 - sure) + simd_normalize(out) * sure }
            if simd_length(way) > 1e-5 { kneeSide[side] = simd_normalize(way) }
            guard under > 0 else { continue }
            let bent = Self.bend(position[hip], target, thigh, shin, pole: kneeSide[side])
            let reach = target - bent
            let landed = bent + (simd_length(reach) > 1e-5 ? simd_normalize(reach) : -up) * shin
            position[toes] += landed - position[ankle]
            position[knee] = bent
            position[ankle] = landed
        }

        // The belly: kicked by the hips' bounce, springing back.
        let rootY = position[0].y
        let rv = settle || dt <= 0 ? 0 : (rootY - lastRootY) / dt
        if settle { belly = 0; bellyVelocity = 0 } else if dt > 0 {
            bellyVelocity += (-belly * 320 - bellyVelocity * 7 - (rv - rootVelocity) / dt * 0.5) * dt
            belly = min(max(belly + bellyVelocity * dt, -1), 1)
        }
        lastRootY = rootY; rootVelocity = rv
        let wobble = jiggle * (belly * 0.5 + 0.06 * sin(time * 13))

        for j in 0..<DancerModel.jointCount {
            var dir = world[j].act(m.directions[j]), length = m.lengths[j], w = width
            switch j {
            case J.hipL, J.hipR, J.kneeL, J.kneeR:
                // Along the leg as it was solved.
                let d = position[j + 3] - position[j]
                if simd_length(d) > 1e-5 { dir = simd_normalize(d) }
                length *= limb
            case J.shoulderL, J.shoulderR, J.elbowL, J.elbowR: length *= limb
            case J.pelvis, J.spine1: w *= fat * (1 + wobble)
            case J.spine2, J.spine3: w *= fat * (1 - wobble * 0.5)
            case J.head: length *= headSize; w *= headSize
            default: break
            }
            bone(j, start: position[j], dir: dir, side: world[j].act(m.sides[j]), length: length, width: w)
        }

        // Shrek's ears, out of the sides of the head and a little up, and his nose.
        let head = world[J.head], skull = position[J.head], headUp = head.act(up)
        let headLength = m.headLength * headSize, headWidth = width * headSize
        let earSize = max(bank.live("earSize"), 0)
        for side in 0..<2 {
            let s: Float = side == 0 ? -1 : 1, b = B.ear + side
            bone(b, start: skull + headUp * headLength * 0.44 + head.act([0, 0, s * 0.14 * headWidth]),
                 dir: head.act(m.directions[b]), side: head.act(m.sides[b]),
                 length: m.lengths[b] * headSize * earSize, width: headWidth * earSize)
        }
        bone(B.nose, start: skull + headUp * headLength * 0.22 + head.act([0.15 * headWidth, 0, 0]), dir: head.act([1, 0, 0]),
             side: head.act([0, 0, 1]), length: m.lengths[B.nose] * headSize, width: headWidth)

        // The ponytail: two segments from the back of the head, pulled toward hanging down and
        // back, flung about by the head's moves.
        let hairLength = max(bank.live("hair"), 0) * headSize
        let length0 = m.lengths[B.hair] * hairLength, length1 = m.lengths[B.hair + 1] * hairLength
        let anchor = skull + headUp * headLength * 0.52 + head.act([-0.085 * headWidth, 0, 0])
        let rest1 = simd_normalize(head.act([-0.8, -0.3, 0]) + V3(0, -0.7, 0))
        let rest2 = simd_normalize(head.act([-0.4, -0.5, 0]) + V3(0, -1.3, 0))
        if settle || dt <= 0 {
            hair[0] = anchor + rest1 * length0
            hair[1] = hair[0] + rest2 * length1
            hairVelocity[0] = .zero
            hairVelocity[1] = .zero
        } else {
            let steps = max(1, Int((dt * 240).rounded(.up)))
            let h = dt / Float(steps)
            for _ in 0..<steps {
                for k in 0..<2 {
                    let was = hair[k]
                    let target = k == 0 ? anchor + rest1 * length0 : hair[0] + rest2 * length1
                    hairVelocity[k] += ((target - hair[k]) * 110 - hairVelocity[k] * 5 + V3(0, -3, 0)) * h
                    hair[k] += hairVelocity[k] * h
                    // Held to its length, and kept behind the face.
                    let base = k == 0 ? anchor : hair[0]
                    var d = hair[k] - base
                    let front = simd_dot(d, head.act([1, 0, 0]))
                    if k == 0, front > 0 { d -= head.act([1, 0, 0]) * front }
                    let len = simd_length(d)
                    hair[k] = base + (len > 1e-5 ? d / len : -up) * (k == 0 ? length0 : length1)
                    hairVelocity[k] = (hair[k] - was) / h
                }
            }
        }
        let hairSide = head.act([0, 0, 1])
        var start = anchor
        for k in 0..<2 {
            let d = hair[k] - start
            bone(B.hair + k, start: start, dir: simd_length(d) > 1e-5 ? simd_normalize(d) : -up, side: hairSide,
                 length: k == 0 ? length0 : length1, width: headWidth)
            start = hair[k]
        }
    }
}
