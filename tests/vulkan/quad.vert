#version 450
/* Fullscreen quad, positions by gl_VertexIndex. base selects the layout:
 * 0..3  = 4-vertex TRIANGLE_STRIP order
 * 4..9  = 6-vertex TRIANGLE_LIST order, uniform winding
 * No vertex buffer, so the test isolates input assembly + rasterizer state. */
layout(push_constant) uniform P { int base; } p;

vec2 pos[10] = vec2[](
    /* strip: TL, BL, TR, BR */
    vec2(-1.0, -1.0), vec2(-1.0, 1.0), vec2(1.0, -1.0), vec2(1.0, 1.0),
    /* list: TL,BL,TR  TR,BL,BR  (same winding sign for both) */
    vec2(-1.0, -1.0), vec2(-1.0, 1.0), vec2(1.0, -1.0),
    vec2( 1.0, -1.0), vec2(-1.0, 1.0), vec2(1.0, 1.0)
);

void main() { gl_Position = vec4(pos[p.base + gl_VertexIndex], 0.0, 1.0); }
