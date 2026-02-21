struct Uniforms {
    time: f32,
    padding: f32,
    resolution: vec2<f32>,
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec3<f32>,
    @location(1) uv: vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) in_vertex_index: u32) -> VertexOutput {
    var out: VertexOutput;
    
    // Define the three positions of a normal triangle (centered)
    var pos = array<vec2<f32>, 3>(
        vec2<f32>( 0.0,  0.5), // top
        vec2<f32>(-0.5, -0.5), // bottom left
        vec2<f32>( 0.5, -0.5)  // bottom right
    );
    
    // Define three bright colors for the vertices
    var colors = array<vec3<f32>, 3>(
        vec3<f32>(1.0, 0.0, 0.0), // red
        vec3<f32>(0.0, 1.0, 0.0), // green
        vec3<f32>(0.0, 0.0, 1.0)  // blue
    );
    
    let p = pos[in_vertex_index];
    
    // Correct for aspect ratio to keep it a perfect triangle
    let aspect = uniforms.resolution.x / uniforms.resolution.y;
    
    out.position = vec4<f32>(p.x / aspect, p.y, 0.0, 1.0);
    out.color = colors[in_vertex_index];
    out.uv = p; // pass untransformed coordinates to fragment shader
    
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    return vec4<f32>(in.color, 1.0);
}

