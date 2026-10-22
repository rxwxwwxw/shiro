#version 450
// Tile mesh vertex stage. World units to clip space come from one uniform; the foam pulse that the
// CPU path computed per vertex now runs here.
layout(location = 0) in vec2 inPos;
layout(location = 1) in vec4 inColor;
layout(location = 2) in vec2 inUv;

layout(location = 0) out vec4 vColor;
layout(location = 1) out vec2 vUv;

layout(set = 1, binding = 0) uniform Params {
    vec4 xform;  // clip.xy = world.xy * xform.xy + xform.zw
    vec4 misc;   // x: u shift, y: wave phase, z: 1 to pulse foam
};

void main() {
    gl_Position = vec4(inPos * xform.xy + xform.zw, 0.0, 1.0);
    vColor = inColor;
    if (misc.z > 0.5 && inColor.a > 0.6)
        vColor.a *= 0.62 + 0.38 * sin(misc.y + (inPos.x + inPos.y) * 1.7);
    vUv = inUv + vec2(misc.x, 0.0);
}
