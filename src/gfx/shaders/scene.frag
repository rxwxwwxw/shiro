#version 450
layout(location = 0) in vec4 vColor;
layout(location = 1) in vec2 vUv;
layout(location = 0) out vec4 outColor;

layout(set = 2, binding = 0) uniform sampler2D tex;

void main() {
    outColor = vColor * texture(tex, vUv);
}
