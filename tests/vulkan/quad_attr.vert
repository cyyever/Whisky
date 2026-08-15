#version 450
/* Positions from a real vertex buffer -- the fetch path the push-constant
 * variant deliberately bypasses. The binding uses a D3D9-ish 28-byte stride
 * (XYZRHW + DIFFUSE + TEX1), so offset/stride handling is exercised too. */
layout(location = 0) in vec2 apos;
void main() { gl_Position = vec4(apos, 0.0, 1.0); }
