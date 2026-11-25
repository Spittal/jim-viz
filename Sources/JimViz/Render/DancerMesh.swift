import simd

/// A Dancer body: a skeleton of 22 joints (SMPL's body joints, the ones motion capture is
/// retargeted onto, see scripts/bake-motion.py) standing in a T-pose, and a faceted shard for
/// each joint's bone. Front is +x, up +y, the dancer's right +z; the hips' joint is the origin.
/// A clip turns each joint; the body brings its own proportions, so one clip dances them all.
struct DancerModel {
    static let jointCount = 22
    /// Each joint's parent, parents first.
    static let parents = [-1, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 9, 9, 12, 13, 14, 16, 17, 18, 19]
    enum Joint {
        static let pelvis = 0, hipL = 1, hipR = 2, spine1 = 3, kneeL = 4, kneeR = 5, spine2 = 6, ankleL = 7, ankleR = 8
        static let spine3 = 9, toesL = 10, toesR = 11, neck = 12, collarL = 13, collarR = 14, head = 15
        static let shoulderL = 16, shoulderR = 17, elbowL = 18, elbowR = 19, wristL = 20, wristR = 21
    }
    /// A bone for each joint, then Shrek's ears and nose and the ponytail's two segments.
    static let boneCount = jointCount + 5
    enum Bone { static let ear = 22, nose = 24, hair = 25 }
    /// The arm and leg joints `limbLength` stretches the bones to.
    static let limbJoints: Set<Int> = [Joint.kneeL, Joint.kneeR, Joint.ankleL, Joint.ankleR,
                                       Joint.elbowL, Joint.elbowR, Joint.wristL, Joint.wristR]
    /// Whether clothes (a top, trousers and shoes; Shrek's vest, trousers and boots) cover a bone.
    static func clothed(_ bone: Int) -> Bool { [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11].contains(bone) }

    /// Each joint's place from its parent, at rest.
    let offsets: [SIMD3<Float>]
    /// Each bone, at rest: the way it runs from its joint and which way is sideways on it, its
    /// length, and its rings along it: (t along the bone, half-width sideways, half-depth,
    /// how far the ring sits forward). No rings for a bone the body doesn't have.
    let directions: [SIMD3<Float>], sides: [SIMD3<Float>], lengths: [Float], profiles: [[SIMD4<Float>]]
    /// How high the ankle joint is off the floor, standing, and the ball of the foot's.
    let ankleHeight: Float, ballHeight: Float
    /// The old head's whole length, which the ears, nose and hair are placed along.
    let headLength: Float, neckLength: Float

    /// Male, Female, Shrek: the `model` knob's steps.
    static let all = [male, female, shrek]

    /// What a body is cut from: the old thirteen-bone figure's measurements and profiles.
    private struct Plan {
        var hipWidth: Float, shoulderWidth: Float, shoulderHeight: Float, neckHeight: Float, ankleHeight: Float
        var pelvis: (Float, [SIMD4<Float>]), chest: (Float, [SIMD4<Float>]), head: (Float, [SIMD4<Float>])
        var upperArm: (Float, [SIMD4<Float>]), forearm: (Float, [SIMD4<Float>])
        var thigh: (Float, [SIMD4<Float>]), shin: (Float, [SIMD4<Float>]), foot: (Float, [SIMD4<Float>])
        var collar: Float
        var ear: (Float, [SIMD4<Float>]) = (0, []), nose: (Float, [SIMD4<Float>]) = (0, [])
        var hair: [(Float, [SIMD4<Float>])] = [(0, []), (0, [])]
    }

    /// The stretch of a profile from distance `a` to `b` along its bone (nil: to its own end), as
    /// a bone of `length` starting at `a`. A cut end gets a ring there and closes to a point just
    /// past it, so neighbouring shards overlap at the joint.
    private static func cut(_ profile: [(d: Float, ring: SIMD3<Float>)], from a: Float?, to b: Float?, length: Float) -> [SIMD4<Float>] {
        func at(_ d: Float) -> SIMD3<Float> {
            guard let i = profile.firstIndex(where: { $0.d >= d }), i > 0 else { return profile[d < profile[0].d ? 0 : profile.count - 1].ring }
            let p = profile[i - 1], q = profile[i]
            return p.ring + (q.ring - p.ring) * ((d - p.d) / max(q.d - p.d, 1e-6))
        }
        let start = a ?? 0, pad = 0.035 * max(length, 0.08) / 0.2
        var rings: [SIMD4<Float>] = []
        func add(_ d: Float, _ r: SIMD3<Float>) { rings.append(SIMD4((d - start) / length, r.x, r.y, r.z)) }
        if let a { add(a - pad, [0, 0, at(a).z]); add(a, at(a)) }
        for p in profile where p.d > (a ?? -.infinity) + 1e-4 && p.d < (b ?? .infinity) - 1e-4 { add(p.d, p.ring) }
        if let b { add(b, at(b)); add(b + pad, [0, 0, at(b).z]) }
        return rings
    }

    private static func build(_ p: Plan) -> DancerModel {
        typealias J = Joint
        let (pelvisLen, chestLen) = (p.pelvis.0, p.chest.0)
        let neckLen = p.head.0 * 0.28, footDir = simd_normalize(SIMD3<Float>(0.12, -0.055, 0))
        let ball = p.foot.0 * 0.62
        // Heights up the spine from the hips.
        let s1 = pelvisLen * 0.6, s2 = pelvisLen + chestLen * 0.2, s3 = pelvisLen + chestLen * 0.42
        let neck = pelvisLen + chestLen * p.neckHeight, shoulder = pelvisLen + chestLen * p.shoulderHeight
        var o = [SIMD3<Float>](repeating: .zero, count: jointCount)
        o[J.spine1] = [0, s1, 0]; o[J.spine2] = [0, s2 - s1, 0]; o[J.spine3] = [0, s3 - s2, 0]
        o[J.neck] = [0, neck - s3, 0]; o[J.head] = [0, neckLen, 0]
        for (side, s) in [(0, Float(-1)), (1, 1)] {   // left, right
            o[J.hipL + side] = [0, 0, s * p.hipWidth]
            o[J.kneeL + side] = [0, -p.thigh.0, 0]
            o[J.ankleL + side] = [0, -p.shin.0, 0]
            o[J.toesL + side] = footDir * ball
            o[J.collarL + side] = [0, shoulder - chestLen * 0.08 - s3, s * p.shoulderWidth * 0.3]
            o[J.shoulderL + side] = [0, chestLen * 0.08, s * p.shoulderWidth * 0.7]
            o[J.elbowL + side] = [0, 0, s * p.upperArm.0]
            o[J.wristL + side] = [0, 0, s * p.forearm.0]
        }

        func spread(_ b: (Float, [SIMD4<Float>]), from: Float = 0) -> [(d: Float, ring: SIMD3<Float>)] {
            b.1.map { (from + $0.x * b.0, SIMD3($0.y, $0.z, $0.w)) }
        }
        // The torso as one silhouette up from the hips: the old pelvis, then the old chest.
        let torso = spread(p.pelvis).filter { $0.d <= pelvisLen } + spread(p.chest, from: pelvisLen).filter { $0.d > pelvisLen }
        let head = spread(p.head), forearm = spread(p.forearm), foot = spread(p.foot)
        let handLen = p.forearm.0 * 0.5, toeLen = p.foot.0 * 0.42, skull = p.head.0 - neckLen

        var dirs = [SIMD3<Float>](repeating: [0, 1, 0], count: boneCount), sides = [SIMD3<Float>](repeating: [0, 0, 1], count: boneCount)
        var lengths = [Float](repeating: 0, count: boneCount), profiles = [[SIMD4<Float>]](repeating: [], count: boneCount)
        func set(_ j: Int, dir: SIMD3<Float>, side: SIMD3<Float> = [0, 0, 1], _ length: Float, _ profile: [SIMD4<Float>]) {
            dirs[j] = dir; sides[j] = side; lengths[j] = length; profiles[j] = profile
        }
        set(J.pelvis, dir: [0, 1, 0], s1, cut(torso, from: nil, to: s1, length: s1))
        set(J.spine1, dir: [0, 1, 0], s2 - s1, cut(torso, from: s1, to: s2, length: s2 - s1))
        set(J.spine2, dir: [0, 1, 0], s3 - s2, cut(torso, from: s2, to: s3, length: s3 - s2))
        set(J.spine3, dir: [0, 1, 0], neck - s3, cut(torso, from: s3, to: nil, length: neck - s3))
        set(J.neck, dir: [0, 1, 0], neckLen, cut(head, from: nil, to: neckLen, length: neckLen))
        set(J.head, dir: [0, 1, 0], skull, cut(head, from: neckLen, to: nil, length: skull))
        for (side, s) in [(0, Float(-1)), (1, 1)] {
            let out = SIMD3<Float>(0, 0, s), up = SIMD3<Float>(0, 1, 0)
            let reach = o[J.shoulderL + side]
            let r = p.collar
            set(J.collarL + side, dir: simd_normalize(reach), side: [1, 0, 0], simd_length(reach),
                [[-0.25, 0, 0, 0], [0, r * 0.8, r * 0.8, 0], [1, r, r, 0], [1.3, 0, 0, 0]])
            set(J.shoulderL + side, dir: out, side: up, p.upperArm.0, p.upperArm.1)
            set(J.elbowL + side, dir: out, side: up, p.forearm.0, cut(forearm, from: nil, to: p.forearm.0, length: p.forearm.0))
            set(J.wristL + side, dir: out, side: up, handLen, cut(forearm, from: p.forearm.0, to: nil, length: handLen))
            set(J.hipL + side, dir: [0, -1, 0], p.thigh.0, p.thigh.1)
            set(J.kneeL + side, dir: [0, -1, 0], p.shin.0, p.shin.1)
            set(J.ankleL + side, dir: footDir, ball, cut(foot, from: nil, to: ball, length: ball))
            set(J.toesL + side, dir: [1, 0, 0], toeLen, cut(foot, from: ball, to: nil, length: toeLen))
            set(Bone.ear + side, dir: simd_normalize([0, 0.45, s]), side: [1, 0, 0], p.ear.0, p.ear.1)
        }
        set(Bone.nose, dir: [1, 0, 0], p.nose.0, p.nose.1)
        set(Bone.hair, dir: [0, -1, 0], p.hair[0].0, p.hair[0].1)
        set(Bone.hair + 1, dir: [0, -1, 0], p.hair[1].0, p.hair[1].1)
        return DancerModel(offsets: o, directions: dirs, sides: sides, lengths: lengths, profiles: profiles,
                           ankleHeight: p.ankleHeight, ballHeight: p.ankleHeight + (footDir * ball).y,
                           headLength: p.head.0, neckLength: neckLen)
    }

    /// Lean and faceless, broad in the shoulders.
    static let male = build(Plan(
        hipWidth: 0.09, shoulderWidth: 0.23, shoulderHeight: 0.9, neckHeight: 0.98, ankleHeight: 0.07,
        pelvis: (0.2, [[-0.8, 0, 0, 0], [-0.3, 0.15, 0.105, 0], [0.35, 0.155, 0.105, 0], [1, 0.125, 0.085, 0], [1.4, 0, 0, 0]]),
        chest: (0.42, [[-0.2, 0, 0, 0], [0, 0.125, 0.085, 0], [0.45, 0.185, 0.115, 0], [0.8, 0.23, 0.12, 0],
                       [0.98, 0.2, 0.085, 0], [1.08, 0.07, 0.055, 0], [1.14, 0, 0, 0]]),
        head: (0.34, [[-0.05, 0, 0, 0], [0.02, 0.045, 0.05, 0], [0.26, 0.044, 0.05, 0], [0.36, 0.068, 0.085, 0],
                      [0.62, 0.092, 0.112, 0], [0.88, 0.082, 0.1, 0], [1.02, 0, 0, 0]]),
        upperArm: (0.33, [[-0.2, 0, 0, 0], [0, 0.064, 0.066, 0], [0.4, 0.054, 0.057, 0], [1, 0.038, 0.038, 0], [1.1, 0, 0, 0]]),
        forearm: (0.29, [[-0.1, 0, 0, 0], [0.05, 0.04, 0.04, 0], [0.35, 0.044, 0.042, 0], [1, 0.027, 0.025, 0],
                         [1.22, 0.02, 0.046, 0], [1.5, 0.016, 0.036, 0], [1.64, 0, 0, 0]]),
        thigh: (0.48, [[-0.16, 0, 0, 0], [0, 0.09, 0.092, 0], [0.4, 0.08, 0.088, 0], [1, 0.052, 0.054, 0], [1.08, 0, 0, 0]]),
        shin: (0.46, [[-0.07, 0, 0, 0], [0, 0.052, 0.054, 0], [0.3, 0.058, 0.066, 0], [1, 0.033, 0.034, 0], [1.07, 0, 0, 0]]),
        foot: (0.2, [[-0.35, 0, 0, 0], [-0.05, 0.036, 0.045, 0], [0.5, 0.044, 0.03, 0], [1, 0.038, 0.014, 0], [1.12, 0, 0, 0]]),
        collar: 0.07))

    /// Slighter, with a narrow waist, wider hips and a ponytail.
    static let female = build(Plan(
        hipWidth: 0.1, shoulderWidth: 0.19, shoulderHeight: 0.9, neckHeight: 0.98, ankleHeight: 0.065,
        pelvis: (0.21, [[-0.8, 0, 0, 0], [-0.3, 0.175, 0.11, 0], [0.3, 0.185, 0.11, -0.01], [1, 0.115, 0.075, 0], [1.35, 0, 0, 0]]),
        chest: (0.38, [[-0.2, 0, 0, 0], [0, 0.11, 0.075, 0], [0.3, 0.12, 0.08, 0], [0.58, 0.165, 0.1, 0.02],
                       [0.78, 0.18, 0.1, 0.012], [0.97, 0.16, 0.07, 0], [1.07, 0.055, 0.045, 0], [1.13, 0, 0, 0]]),
        head: (0.32, [[-0.05, 0, 0, 0], [0.02, 0.036, 0.04, 0], [0.26, 0.036, 0.04, 0], [0.36, 0.06, 0.075, 0],
                      [0.62, 0.084, 0.106, -0.008], [0.88, 0.078, 0.098, -0.008], [1.02, 0, 0, 0]]),
        upperArm: (0.3, [[-0.2, 0, 0, 0], [0, 0.05, 0.052, 0], [0.4, 0.044, 0.046, 0], [1, 0.031, 0.031, 0], [1.1, 0, 0, 0]]),
        forearm: (0.27, [[-0.1, 0, 0, 0], [0.05, 0.032, 0.032, 0], [0.35, 0.035, 0.034, 0], [1, 0.022, 0.02, 0],
                         [1.22, 0.016, 0.038, 0], [1.5, 0.013, 0.03, 0], [1.66, 0, 0, 0]]),
        thigh: (0.47, [[-0.16, 0, 0, 0], [0, 0.092, 0.094, 0], [0.4, 0.076, 0.084, 0], [1, 0.046, 0.048, 0], [1.08, 0, 0, 0]]),
        shin: (0.44, [[-0.07, 0, 0, 0], [0, 0.046, 0.048, 0], [0.3, 0.052, 0.06, 0], [1, 0.028, 0.03, 0], [1.07, 0, 0, 0]]),
        foot: (0.18, [[-0.35, 0, 0, 0], [-0.05, 0.032, 0.04, 0], [0.5, 0.038, 0.026, 0], [1, 0.032, 0.012, 0], [1.12, 0, 0, 0]]),
        collar: 0.055,
        hair: [(0.15, [[-0.25, 0, 0, 0], [0, 0.045, 0.04, 0], [0.5, 0.058, 0.052, 0], [1, 0.05, 0.045, 0], [1.1, 0, 0, 0]]),
               (0.17, [[-0.1, 0, 0, 0], [0, 0.05, 0.045, 0], [0.45, 0.046, 0.04, 0], [1, 0.012, 0.012, 0], [1.06, 0, 0, 0]])]))

    /// A stocky ogre: a barrel of a body, a wide head with no neck, trumpet ears and a nose. An
    /// ear's rim turns back in on itself, so it ends in a cup.
    static let shrek = build(Plan(
        hipWidth: 0.13, shoulderWidth: 0.3, shoulderHeight: 0.85, neckHeight: 0.92, ankleHeight: 0.08,
        pelvis: (0.22, [[-0.7, 0, 0, 0], [-0.3, 0.2, 0.16, 0], [0.4, 0.25, 0.2, 0.03], [1, 0.27, 0.22, 0.05], [1.3, 0, 0, 0.05]]),
        chest: (0.4, [[-0.2, 0, 0, 0.04], [0, 0.27, 0.22, 0.05], [0.3, 0.29, 0.25, 0.07], [0.7, 0.28, 0.2, 0.03],
                      [0.95, 0.24, 0.15, 0], [1.08, 0.1, 0.09, 0], [1.15, 0, 0, 0]]),
        head: (0.36, [[-0.1, 0, 0, 0], [0.05, 0.15, 0.14, 0.01], [0.3, 0.2, 0.17, 0.02], [0.6, 0.18, 0.16, 0.01],
                      [0.85, 0.13, 0.13, 0], [1, 0.06, 0.06, 0], [1.03, 0, 0, 0]]),
        upperArm: (0.3, [[-0.2, 0, 0, 0], [0, 0.085, 0.085, 0], [0.45, 0.08, 0.08, 0], [1, 0.062, 0.062, 0], [1.1, 0, 0, 0]]),
        forearm: (0.27, [[-0.1, 0, 0, 0], [0.05, 0.062, 0.062, 0], [0.4, 0.068, 0.066, 0], [1, 0.05, 0.048, 0],
                         [1.2, 0.06, 0.07, 0], [1.45, 0.05, 0.06, 0], [1.6, 0, 0, 0]]),
        thigh: (0.34, [[-0.16, 0, 0, 0], [0, 0.125, 0.125, 0], [0.5, 0.11, 0.115, 0], [1, 0.08, 0.082, 0], [1.08, 0, 0, 0]]),
        shin: (0.32, [[-0.07, 0, 0, 0], [0, 0.08, 0.082, 0], [0.35, 0.085, 0.09, 0], [1, 0.06, 0.06, 0], [1.07, 0, 0, 0]]),
        foot: (0.24, [[-0.4, 0, 0, 0], [-0.05, 0.06, 0.06, 0], [0.5, 0.075, 0.05, 0], [1, 0.065, 0.03, 0], [1.12, 0, 0, 0]]),
        collar: 0.1,
        ear: (0.17, [[0, 0, 0, 0], [0.08, 0.025, 0.025, 0], [0.6, 0.022, 0.022, 0], [0.85, 0.045, 0.05, 0],
                     [1, 0.06, 0.07, 0], [0.8, 0, 0, 0]]),
        nose: (0.09, [[-0.3, 0, 0, 0], [0.2, 0.045, 0.04, 0], [0.7, 0.05, 0.04, 0], [1, 0, 0, 0]])))
}

extension MeshBuilder {
    mutating func dancer(sides n: Int, model: Int) {
        let m = DancerModel.all[min(max(model, 0), DancerModel.all.count - 1)]
        figure(Array(zip(m.lengths, m.profiles)), sides: n)
    }

    /// A figure of rigid bones, each a `sides`-sided shard through its profile's rings: (t along
    /// the bone, half-width sideways, half-depth front to back, how far the ring sits forward).
    /// Each ring is turned half a side from the one before, so the faces between them are
    /// triangles that zigzag round the bone, like a cut crystal. A bone with no rings draws nothing.
    /// shape: x = the bone, y = t along it, zw = the vertex's offset across it (sideways,
    /// front to back). position and faceNormal are in the straight bone's own frame (along,
    /// sideways, front to back), so the shader can pose them.
    mutating func figure(_ bones: [(length: Float, profile: [SIMD4<Float>])], sides n: Int) {
        for (bone, (length, profile)) in bones.enumerated() where profile.count > 1 {
            func vert(_ ring: Int, _ k: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD4<Float>) {
                let r = profile[ring]
                // Starts at the front, so an odd-sided bone is still the same left and right.
                let a = .pi / 2 + (Float(k) + Float(ring % 2) * 0.5) / Float(n) * 2 * .pi
                let off = SIMD2<Float>(cos(a) * r.y, sin(a) * r.z + r.w)
                let normal: SIMD3<Float> = r.y == 0 ? [ring == 0 ? -1 : 1, 0, 0] : [0, cos(a), sin(a)]
                return ([r.x * length, off.x, off.y], normal, [Float(bone), r.x, off.x, off.y])
            }
            for i in 0..<profile.count - 1 {
                for k in 0..<n {
                    // The ring turned back by half a side leads; the other's vertex k sits past its vertex k.
                    let (lead, trail) = i % 2 == 0 ? (i, i + 1) : (i + 1, i)
                    let (a, na, sa) = vert(lead, k), (b, nb, sb) = vert(lead, k + 1)
                    let (c, nc, sc) = vert(trail, k), (d, nd, sd) = vert(trail, k + 1)
                    if profile[lead].y > 0 { tri(a, b, c, na, nb, nc, shape: (sa, sb, sc)) }
                    if profile[trail].y > 0 { tri(b, d, c, nb, nd, nc, shape: (sb, sd, sc)) }
                }
            }
        }
    }
}
