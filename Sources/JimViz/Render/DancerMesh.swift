import simd

/// Dancer: a lean, faceless figure of thirteen rigid bones, each a `sides`-sided tapered shard.
extension MeshBuilder {
    /// Each bone's length and its profile along it: (t along the bone, half-width sideways,
    /// half-depth front to back). A ring of no width is a point. t runs a little past 0 and 1
    /// so the bones overlap at the joints; a forearm runs on into its hand.
    /// Bones: pelvis, chest, head (with its neck), right upper arm, forearm, left upper arm,
    /// forearm, right thigh, shin, foot, left thigh, shin, foot.
    /// Lengths must match `boneLen` in Shaders/generators/lowpoly/dancer.metal.
    static let dancerBones: [(length: Float, profile: [SIMD3<Float>])] = {
        let pelvis: [SIMD3<Float>] = [[-0.8, 0, 0], [-0.3, 0.16, 0.105], [0.35, 0.165, 0.105], [1, 0.125, 0.085], [1.4, 0, 0]]
        let chest: [SIMD3<Float>] = [[-0.2, 0, 0], [0, 0.125, 0.085], [0.45, 0.18, 0.115], [0.8, 0.225, 0.12],
                                     [0.98, 0.21, 0.085], [1.08, 0.07, 0.055], [1.14, 0, 0]]
        let head: [SIMD3<Float>] = [[-0.05, 0, 0], [0.02, 0.045, 0.05], [0.26, 0.042, 0.048], [0.36, 0.068, 0.085],
                                    [0.62, 0.092, 0.112], [0.88, 0.082, 0.1], [1.02, 0, 0]]
        let upperArm: [SIMD3<Float>] = [[-0.2, 0, 0], [0, 0.062, 0.065], [0.4, 0.052, 0.056], [1, 0.038, 0.038], [1.1, 0, 0]]
        let forearm: [SIMD3<Float>] = [[-0.1, 0, 0], [0.05, 0.04, 0.04], [0.35, 0.044, 0.042], [1, 0.027, 0.025],
                                       [1.22, 0.02, 0.046], [1.5, 0.016, 0.036], [1.64, 0, 0]]
        let thigh: [SIMD3<Float>] = [[-0.16, 0, 0], [0, 0.09, 0.092], [0.4, 0.08, 0.088], [1, 0.052, 0.054], [1.08, 0, 0]]
        let shin: [SIMD3<Float>] = [[-0.07, 0, 0], [0, 0.052, 0.054], [0.3, 0.058, 0.066], [1, 0.033, 0.034], [1.07, 0, 0]]
        let foot: [SIMD3<Float>] = [[-0.35, 0, 0], [-0.05, 0.036, 0.045], [0.5, 0.044, 0.03], [1, 0.038, 0.014], [1.12, 0, 0]]
        return [(0.2, pelvis), (0.42, chest), (0.34, head), (0.33, upperArm), (0.29, forearm), (0.33, upperArm), (0.29, forearm),
                (0.48, thigh), (0.46, shin), (0.2, foot), (0.48, thigh), (0.46, shin), (0.2, foot)]
    }()

    /// Each ring is turned half a side from the one before, so the faces between them are
    /// triangles that zigzag round the bone, like a cut crystal.
    /// shape: x = bone 0...12, y = t along it, zw = the vertex's offset across it (sideways,
    /// front to back). position and faceNormal are in the straight bone's own frame (along,
    /// sideways, front to back), so the shader can pose them.
    mutating func dancer(sides n: Int) {
        for (bone, (length, profile)) in MeshBuilder.dancerBones.enumerated() {
            func vert(_ ring: Int, _ k: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD4<Float>) {
                let r = profile[ring]
                // Starts at the front, so an odd-sided bone is still the same left and right.
                let a = .pi / 2 + (Float(k) + Float(ring % 2) * 0.5) / Float(n) * 2 * .pi
                let off = SIMD2<Float>(cos(a) * r.y, sin(a) * r.z)
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
