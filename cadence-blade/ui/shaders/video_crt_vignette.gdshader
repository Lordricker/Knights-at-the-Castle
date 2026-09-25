shader_type canvas_item;

// -- Vignette --
uniform bool enable_vignette = true;
uniform float vignette_intensity : hint_range(0.0, 3.0) = 1.4;
uniform float vignette_opacity : hint_range(0.0, 1.0) = 0.75;

// -- CRT scanlines --
// scanline_count is the number of bright/dark cycles across the node's full
// height (sin() completes scanline_count/2 cycles over UV.y 0..1). Keep this
// well under the node's actual rendered pixel height or the lines alias into
// a flat gray — e.g. a ~200px-tall video wants roughly 40-100, not 240+.
uniform bool enable_scanlines = false;
uniform float scanline_count : hint_range(10.0, 300.0) = 80.0;
uniform float scanline_opacity : hint_range(0.0, 1.0) = 0.35;

// -- CRT screen curvature --
uniform bool enable_curvature = false;
uniform float curvature_amount : hint_range(0.0, 0.3) = 0.08;

vec2 curve_uv(vec2 uv) {
	uv = uv * 2.0 - 1.0;
	vec2 offset = abs(uv.yx) * curvature_amount;
	uv = uv + uv * offset * offset;
	uv = uv * 0.5 + 0.5;
	return uv;
}

void fragment() {
	vec2 uv = UV;
	if (enable_curvature) {
		uv = curve_uv(uv);
	}

	vec4 tex_color = vec4(0.0);
	if (uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0) {
		tex_color = texture(TEXTURE, uv);

		if (enable_scanlines) {
			float scanline = sin(uv.y * scanline_count * PI) * 0.5 + 0.5;
			tex_color.rgb *= mix(1.0, scanline, scanline_opacity);
		}

		if (enable_vignette) {
			vec2 centered = uv - vec2(0.5);
			float vig = 1.0 - dot(centered, centered) * vignette_intensity;
			vig = clamp(vig, 0.0, 1.0);
			tex_color.rgb *= mix(1.0, vig, vignette_opacity);
		}
	}

	COLOR = tex_color;
}
