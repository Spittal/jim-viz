import simd

extension simd_float4x4 {
    /// Right-handed perspective projection with Metal's 0...1 clip depth.
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, z, -1),
            SIMD4(0, 0, z * near, 0)
        ))
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (
            SIMD4(s.x, u.x, -f.x, 0),
            SIMD4(s.y, u.y, -f.y, 0),
            SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
        ))
    }
}

/// Layout must match `Frame` in Shaders/common.metal.
struct FrameUniforms {
    var resolution: SIMD2<Float> = .zero
    var time: Float = 0
    var dt: Float = 0
    /// Bit n is set when the shader's input at texture(n) is connected. Set per pass.
    var inputs: Float = 0
}

/// Layout must match `Camera` in Shaders/generators/*.metal.
struct CameraUniforms {
    var viewProj: simd_float4x4
    var position: SIMD4<Float>
}
