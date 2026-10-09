shader_type canvas_item;

// Draws a bar's fill straight onto its mask sprite: the sprite's texture is the
// bar shape (opaque where the fill may show), and up to three colored bands are
// layered over a background along the bar's axis.
//
// Replaces clip_children = CLIP_CHILDREN_ONLY, which Safari/WebKit ignores — the
// fill drew as one big unclipped rectangle over the castle.

// -- Axis --
// false: bands run along UV.x (left to right). true: along UV.y (top to bottom).
uniform bool vertical = false;

// -- Layers (drawn bottom to top) --
uniform vec4 background_color = vec4(0.0);
// Each band covers [x, y) in the mask's UV along the axis. x == y hides it.
uniform vec2 band0 = vec2(0.0);
uniform vec4 band0_color = vec4(0.0);
uniform vec2 band1 = vec2(0.0);
uniform vec4 band1_color = vec4(0.0);
uniform vec2 band2 = vec2(0.0);
uniform vec4 band2_color = vec4(0.0);

// Standard alpha "over": src drawn on top of dst, both straight alpha.
vec4 over(vec4 dst, vec4 src) {
	float a = src.a + dst.a * (1.0 - src.a);
	if (a <= 0.0) {
		return vec4(0.0);
	}
	return vec4((src.rgb * src.a + dst.rgb * dst.a * (1.0 - src.a)) / a, a);
}

vec4 layer(vec4 dst, float t, vec2 range, vec4 color) {
	return (t >= range.x && t < range.y) ? over(dst, color) : dst;
}

void fragment() {
	// Layers keep their alpha, so a translucent background lets the world show
	// through the empty part of the bar.
	float t = vertical ? UV.y : UV.x;
	vec4 c = background_color;
	c = layer(c, t, band0, band0_color);
	c = layer(c, t, band1, band1_color);
	c = layer(c, t, band2, band2_color);
	// COLOR arrives as modulate times the (white) mask texel, so its alpha is
	// already the mask shape.
	COLOR = vec4(c.rgb * COLOR.rgb, c.a * COLOR.a);
}
