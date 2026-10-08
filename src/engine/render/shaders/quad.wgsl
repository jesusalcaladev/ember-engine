// M0 quad shader. Uniform: column-major MVP (matches core.math.Mat4).
struct Uniforms {
    mvp: mat4x4<f32>,
}

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

struct VSOut {
    @builtin(position) pos: vec4f,
    @location(0) color: vec4f,
}

@vertex
fn vs_main(@location(0) pos: vec2f, @location(1) color: vec4f) -> VSOut {
    var out: VSOut;
    out.pos = uniforms.mvp * vec4f(pos, 0.0, 1.0);
    out.color = color;
    return out;
}

@fragment
fn fs_main(in: VSOut) -> @location(0) vec4f {
    return in.color;
}
