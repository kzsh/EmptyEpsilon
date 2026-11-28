[vertex]

// Program inputs
uniform mat4 u_projection;
uniform mat4 u_view;

// Per-vertex inputs
attribute vec3 a_position;
attribute vec2 a_texcoords;
attribute vec3 a_color;

// Per-vertex outputs
varying vec2 v_texcoords;
varying vec3 v_color;

void main()
{
    // Ribbons are built in world space; no model matrix.
    gl_Position = u_projection * u_view * vec4(a_position, 1.0);
    v_texcoords = a_texcoords;
    v_color = a_color;
}

[fragment]

// Program inputs
uniform sampler2D u_textureMap;

// Per-fragment inputs
varying vec2 v_texcoords;
varying vec3 v_color;

void main()
{
    // Additive blending: v_color fading toward black reads as fading out.
    gl_FragColor = texture2D(u_textureMap, v_texcoords.st) * vec4(v_color, 1.0);
}
