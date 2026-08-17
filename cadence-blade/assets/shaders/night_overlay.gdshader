shader_type canvas_item;

// Screen-space night overlay — desaturates and tints the whole frame toward
// a darker blue as `intensity` rises from 0 (full day) to 1 (full night).
// Driven at runtime by night_overlay.gd, which reads EnemySpawner's
// get_night_intensity() so the fade tracks the night_periods timing array.
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform vec3 night_tint : source_color = vec3(0.12, 0.16, 0.35);
uniform float desaturation : hint_range(0.0, 1.0) = 0.6;
uniform float darken : hint_range(0.0, 1.0) = 0.45;

void fragment() {
	vec4 screen = texture(SCREEN_TEXTURE, SCREEN_UV);
	float grey = dot(screen.rgb, vec3(0.299, 0.587, 0.114));
	vec3 desaturated = mix(screen.rgb, vec3(grey), desaturation * intensity);
	vec3 tinted = mix(desaturated, desaturated * night_tint * 2.0, intensity);
	vec3 result = tinted * (1.0 - darken * intensity);
	COLOR = vec4(result, screen.a);
}
