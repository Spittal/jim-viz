import simd

/// Shrek: a stocky ogre of sixteen rigid bones, built like the Dancer (`MeshBuilder.figure`):
/// a barrel of a body, a wide head with no neck, trumpet ears and a nose.
extension MeshBuilder {
    /// Each bone's length and its profile along it: (t along the bone, half-width sideways,
    /// half-depth front to back, how far the ring sits forward: the belly).
    /// Bones: pelvis, chest, head, right upper arm, forearm (with its fist), left upper arm,
    /// forearm, right thigh, shin, foot, left thigh, shin, foot, right ear, left ear, nose.
    /// An ear's rim turns back in on itself, so it ends in a cup.
    /// Lengths must match `boneLen` in Shaders/generators/lowpoly/shrek.metal.
    static let shrekBones: [(length: Float, profile: [SIMD4<Float>])] = {
        let pelvis: [SIMD4<Float>] = [[-0.7, 0, 0, 0], [-0.3, 0.2, 0.16, 0], [0.4, 0.25, 0.2, 0.03], [1, 0.27, 0.22, 0.05], [1.3, 0, 0, 0.05]]
        let chest: [SIMD4<Float>] = [[-0.2, 0, 0, 0.04], [0, 0.27, 0.22, 0.05], [0.3, 0.29, 0.25, 0.07], [0.7, 0.28, 0.2, 0.03],
                                     [0.95, 0.24, 0.15, 0], [1.08, 0.1, 0.09, 0], [1.15, 0, 0, 0]]
        let head: [SIMD4<Float>] = [[-0.1, 0, 0, 0], [0.05, 0.15, 0.14, 0.01], [0.3, 0.2, 0.17, 0.02], [0.6, 0.18, 0.16, 0.01],
                                    [0.85, 0.13, 0.13, 0], [1, 0.06, 0.06, 0], [1.03, 0, 0, 0]]
        let upperArm: [SIMD4<Float>] = [[-0.2, 0, 0, 0], [0, 0.085, 0.085, 0], [0.45, 0.08, 0.08, 0], [1, 0.062, 0.062, 0], [1.1, 0, 0, 0]]
        let forearm: [SIMD4<Float>] = [[-0.1, 0, 0, 0], [0.05, 0.062, 0.062, 0], [0.4, 0.068, 0.066, 0], [1, 0.05, 0.048, 0],
                                       [1.2, 0.06, 0.07, 0], [1.45, 0.05, 0.06, 0], [1.6, 0, 0, 0]]
        let thigh: [SIMD4<Float>] = [[-0.16, 0, 0, 0], [0, 0.125, 0.125, 0], [0.5, 0.11, 0.115, 0], [1, 0.08, 0.082, 0], [1.08, 0, 0, 0]]
        let shin: [SIMD4<Float>] = [[-0.07, 0, 0, 0], [0, 0.08, 0.082, 0], [0.35, 0.085, 0.09, 0], [1, 0.06, 0.06, 0], [1.07, 0, 0, 0]]
        let foot: [SIMD4<Float>] = [[-0.4, 0, 0, 0], [-0.05, 0.06, 0.06, 0], [0.5, 0.075, 0.05, 0], [1, 0.065, 0.03, 0], [1.12, 0, 0, 0]]
        let ear: [SIMD4<Float>] = [[0, 0, 0, 0], [0.08, 0.025, 0.025, 0], [0.6, 0.022, 0.022, 0], [0.85, 0.045, 0.05, 0],
                                   [1, 0.06, 0.07, 0], [0.8, 0, 0, 0]]
        let nose: [SIMD4<Float>] = [[-0.3, 0, 0, 0], [0.2, 0.045, 0.04, 0], [0.7, 0.05, 0.04, 0], [1, 0, 0, 0]]
        return [(0.22, pelvis), (0.4, chest), (0.36, head), (0.3, upperArm), (0.27, forearm), (0.3, upperArm), (0.27, forearm),
                (0.34, thigh), (0.32, shin), (0.24, foot), (0.34, thigh), (0.32, shin), (0.24, foot),
                (0.17, ear), (0.17, ear), (0.09, nose)]
    }()

    mutating func shrek(sides n: Int) { figure(MeshBuilder.shrekBones, sides: n) }
}
