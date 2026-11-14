class_name WorldShader
extends RefCounted

# The two shaders that draw an office area pixel-exact, generated at run time so they can name
# palette entries (Pal.shader_consts) the way the mockup's Python does.
#
# FACADE runs on everything drawn in the world pass. Plain polygons pass through (UV.x < 4000),
# sprites read palette indices from the atlas (4000 <= UV.x < 8000). A wall is a quad whose vertex data carries the facade "shader" of the mockup:
#   COLOR.r = style | k << 4 | fade << 6 | door << 7, COLOR.g = ramp | variant << 5,
#   COLOR.b = h (rows above the base, 0..255), COLOR.a = n (columns, for doors),
#   UV.x = 16384 + seed * 1024 + i (column from the wall's first corner),
#   UV.y = the wall's base line minus y, so base + this pixel's y gives the column's base line.
# Each pixel finds its column i and row r above the base exactly as gen_battlegrounds.py's
# wall_pixels does, picks a palette index, and (when fade is set) maps it through the fade table.
#
# GROUND reads the ground pass (palette indices in red) and the shadow mask, adds the per-pixel
# texture of the mockup (pavement tiles, asphalt and grass speckle, kerbs), then shades what lies
# in a cast shadow and dims what lies outside the active radius.

# sprite quads carry atlas pixel coordinates in UV, shifted by this
const ATLAS_UV := 4096.0
const STYLE_INK := 1
const STYLE_APT := 2
const STYLE_OFFICE := 3
const STYLE_HOUSE := 4
const STYLE_TOWER := 5
const STYLE_SKY := 6
const STYLE_PLAIN := 7
const STYLE_SKELETON := 8
const STYLE_SCAFFOLD := 9
const STYLE_SLAB := 10
const STYLE_CAB := 11
const STYLE_SHED := 12

const _COMMON := """
uint hsh(uint x) {
	x ^= x >> 16u; x *= 0x7feb352du; x ^= x >> 15u; x *= 0x846ca68bu; x ^= x >> 16u;
	return x;
}
float h01(int a, int b, int c, int d) {
	uint x = hsh(uint(a + 40000) * 0x9E3779B1u ^ hsh(uint(b + 40000) + 0x85EBCA6Bu
		^ hsh(uint(c + 40000) * 0xC2B2AE35u ^ hsh(uint(d + 40000) + 7u))));
	return float(x & 0xFFFFu) / 65536.0;
}
int pal_at(int x, int row) {
	return int(round(texelFetch(lut, ivec2(x, row), 0).r * 255.0));
}
"""

const _FACADE_BODY := """
const int ST_INK = 1;
const int ST_APT = 2;
const int ST_OFFICE = 3;
const int ST_HOUSE = 4;
const int ST_TOWER = 5;
const int ST_SKY = 6;
const int ST_PLAIN = 7;
const int ST_SKEL = 8;
const int ST_SCAF = 9;
const int ST_SLAB = 10;
const int ST_CAB = 11;
const int ST_SHED = 12;

int rp(int ramp, int s) { return pal_at(ramp * 4 + clamp(s, 0, 3), 4); }

int gls(int s) { return rp(R_GLS, s); }

int win_glass(int k, bool top, bool lit) {
	if (lit) return top ? GOLD : GOLD_M;
	if (k == 1) return top ? SL4 : SL2;
	return (top && k == 2) ? SL3 : SL1;
}

int gold_lit(int k) {
	if (k <= 1) return GOLD;
	return k == 2 ? GOLD_M : GOLD_D;
}

int apartment(int i, int r, int h, int k, int ramp, int seed) {
	int wall = rp(ramp, k);
	int dk = rp(ramp, k + 1);
	int ground = 6;
	if (r >= h - 1) return rp(ramp, k - 1);
	if (r == h - 2) return dk;
	if (r < ground) {
		int b = (i + 1) % 6;
		if (r == ground - 1) return dk;
		if (b >= 1 && b <= 4) {
			if (r == ground - 2) {
				int a = int(h01(seed, 7, 0, 0) * 4.0);
				if (k == 1) return a == 0 ? RED : (a == 1 ? CYAN_M : (a == 2 ? GRASS_D : GOLD_M));
				return a == 0 ? AWD0 : (a == 1 ? AWD1 : (a == 2 ? AWD2 : AWD3));
			}
			if (r == 0) return SL1;
			return (r == ground - 3 && b == 1 && k == 1) ? SL3 : SL2;
		}
		return wall;
	}
	int fr = (r - ground) % 4;
	int fl = (r - ground) / 4;
	int b = (i + 1) % 4;
	if (b == 1 || b == 2) {
		if (fr == 0) return k > 1 ? INK : SL2;
		if (fr == 1 || fr == 2) {
			float hh = h01(seed, k, fl, i / 4);
			if (hh < 0.22 && fr == 2) return k == 1 ? GRASS_D : GRASS_DD;
			return win_glass(k, fr == 2 && b == 1, hh > 0.93);
		}
	}
	if (fr == 0 && (b == 0 || b == 3)) return dk;
	return wall;
}

int office(int i, int r, int h, int k, int ramp, int seed) {
	int wall = rp(ramp, k);
	int dk = rp(ramp, k + 1);
	if (r >= h - 1) return rp(ramp, 0);
	if (r == h - 2) return dk;
	if (r < 7) {
		if (r == 6) return (i / 2) % 2 == 0 ? CREAM : CYAN_M;
		if (r == 5) return (i / 2) % 2 == 1 ? CYAN_D : CRM3;
		int b = i % 5;
		if (b == 0) return dk;
		if (r == 0) return CYAN_DD;
		if ((r == 4 && b == 1) || (b + r) % 7 == 0) return CYAN;
		return k == 1 ? CYAN_M : CYAN_D;
	}
	int fr = (r - 7) % 5;
	int b = i % 4;
	if ((b == 1 || b == 2) && fr >= 1 && fr <= 3)
		return win_glass(k, fr == 3, h01(seed, i / 4, (r - 7) / 5, 3) > 0.8);
	if (fr == 0 && (b == 1 || b == 2)) return k == 1 ? rp(ramp, 0) : rp(ramp, k - 1);
	return wall;
}

int house(int i, int r, int n, int k, int ramp, bool door) {
	int wall = rp(ramp, k);
	if (r == 0) return rp(ramp, k + 1);
	int fr = r % 5;
	int fl = r / 5;
	int b = (i + 2) % 5;
	if (fl == 0 && door && i == n / 2 && r >= 1 && r <= 3) return WOOD;
	if ((fr == 2 || fr == 3) && (b == 2 || b == 3)) return win_glass(k, fr == 3 && b == 2, false);
	if ((fr == 2 || fr == 3) && (b == 1 || b == 4)) return k == 1 ? GRASS_D : GRASS_DD;
	return wall;
}

int tower(int i, int r, int h, int k, int ramp, int ground) {
	int con = rp(ramp, k);
	if (r >= h - 2) return rp(ramp, k - 1);
	if (r < ground) {
		if (r == ground - 1) return con;
		if (i % 5 == 0) return rp(ramp, k + 1);
		if (r == 0) return SL1;
		if (r == 3) return k == 1 ? GLS1 : GLS2;
		return k == 1 ? GLS2 : GLS3;
	}
	int fr = (r - ground) % 3;
	if (fr == 0) return con;
	if (i % 5 == 0) return rp(ramp, k + 1);
	bool refl = (i + r) % 13 < 2;
	int g = refl ? gls(k - 1) : gls(k);
	if (fr == 2 && k == 1 && !refl) return GLS1;
	if (fr == 2) return g;
	return refl ? g : gls(k + 1);
}

int sky(int i, int r, int h, int k, int ground, int crown) {
	if (crown > 0 && r >= h - crown) {
		if (r == h - 1 || r == h - crown) return gold_lit(k);
		return k <= 1 ? GOLD_M : (k == 2 ? GOLD_D : INK);
	}
	if (r < ground) {
		if (r == ground - 1) return gold_lit(k);
		if (i % 6 == 0) return k == 1 ? CON2 : CON3;
		if (r == 0) return SL1;
		if (k == 1 && r == ground - 2) return GLS1;
		return k == 3 ? GLS3 : GLS2;
	}
	int rr = r - ground;
	bool refl = ((i * 2 + rr) % 29) < 4;
	int g = refl ? gls(k - 1) : gls(k);
	if (i % 3 == 0 || rr % 3 == 0) return refl ? gls(k) : gls(k + 1);
	return g;
}

int plain(int i, int r, int n, int h, int k, int ramp, bool door) {
	if (r >= h) return rp(ramp, k - 1);
	if (door && i == n / 2 && r <= 2) return SL2;
	return rp(ramp, k);
}

int skeleton(int i, int r, int n, int h, int k) {
	if (r >= h) return -1;
	if (r % 4 == 0) return rp(R_CON, k);
	if (i % 5 == 0 || i == n - 1) return rp(R_CON, k + 1);
	return -1;
}

int scaffold(int i, int r, int h, int k) {
	if (r > h) return -1;
	if (i % 6 == 0) return k == 1 ? GOLD_M : WOOD;
	if (r % 6 == 0) return k == 1 ? GOLD : GOLD_M;
	return -1;
}

// the earth cut under the floating slab: pavement lip, dirt with a few cobbles, an ink foot
int slab(int i, int r, int h, int k, int seed) {
	int rr = h - r + 1;
	bool lit = k == 1;
	if (rr == 1) return lit ? PAVE_L : PAVE_D;
	if (rr == 2) return lit ? PAVE_D : PAVE_S;
	if (r == 0) return INK;
	if (r == 1) return lit ? DIRT_D : TRUNK;
	float st = h01(seed, i / 3, (r + (i / 3) % 2) / 3, 11);
	if (st < 0.16 && rr > 3 && rr < h - 2) return lit ? DIRT_L : DIRT;
	if (rr == 3) return lit ? DIRT_D : TRUNK;
	return lit ? DIRT : DIRT_D;
}

// a low warehouse: roller doors with slats at the bottom, a strip of high windows
int shed(int i, int r, int h, int k, int ramp) {
	int wall = rp(ramp, k);
	int dk = rp(ramp, k + 1);
	if (r >= h - 1) return rp(ramp, k - 1);
	if (r == h - 2) return dk;
	if (r < 7) {
		int b = i % 9;
		if (b >= 2 && b <= 7) {
			if (r == 6) return dk;
			if (r % 2 == 0) return k == 1 ? SL3 : SL2;
			return k == 1 ? SL4 : SL3;
		}
		return wall;
	}
	if (r == h - 4 && i % 3 != 0) return k == 1 ? SL4 : SL2;
	return wall;
}

int paint(int style, int i, int r, int n, int h, int k, int ramp, int variant, int seed, bool door) {
	if (style == ST_INK) return INK;
	if (style == ST_APT) return apartment(i, r, h, k, ramp, seed);
	if (style == ST_OFFICE) return office(i, r, h, k, ramp, seed);
	if (style == ST_HOUSE) return house(i, r, n, k, ramp, door);
	if (style == ST_TOWER) return tower(i, r, h, k, ramp, variant == 1 ? 0 : 5);
	if (style == ST_SKY) {
		int crown = (variant >> 1) == 1 ? 3 : ((variant >> 1) == 2 ? 4 : 0);
		return sky(i, r, h, k, (variant & 1) == 1 ? 6 : 0, crown);
	}
	if (style == ST_PLAIN) return plain(i, r, n, h, k, ramp, door);
	if (style == ST_SKEL) return skeleton(i, r, n, h, k);
	if (style == ST_SCAF) return scaffold(i, r, h, k);
	if (style == ST_SLAB) return slab(i, r, h, k, seed);
	if (style == ST_CAB) return k == 1 ? SL4 : SL2;
	if (style == ST_SHED) return shed(i, r, h, k, ramp);
	return rp(ramp, k);
}

void vertex() {
	lp = VERTEX;
}

void fragment() {
	if (UV.x >= 4000.0 && UV.x < 8000.0) {
		// a sprite: palette indices from the atlas; COLOR.r = 1 colour, 2 faded, 3 ink
		vec4 t = texelFetch(sprites, ivec2(floor(UV - vec2(4096.0, 0.0))), 0);
		if (t.a < 0.5) discard;
		int idx = int(round(t.r * 255.0));
		int how = int(round(COLOR.r * 255.0));
		if (how == 2) idx = pal_at(idx, 3);
		if (how == 3) idx = INK;
		COLOR = vec4(texelFetch(lut, ivec2(idx, 0), 0).rgb, 1.0);
	} else if (UV.x < 4000.0) {
		COLOR = vec4(COLOR.rgb, 1.0);
	} else {
		int pr = int(round(COLOR.r * 255.0));
		int pg = int(round(COLOR.g * 255.0));
		int h = int(round(COLOR.b * 255.0));
		int n = int(round(COLOR.a * 255.0));
		int style = pr & 15;
		int k = (pr >> 4) & 3;
		bool fade = ((pr >> 6) & 1) == 1;
		bool door = ((pr >> 7) & 1) == 1;
		int ramp = pg & 31;
		int variant = (pg >> 5) & 7;
		int code = int(floor(UV.x)) - 16384;
		int i = code & 1023;
		int seed = code >> 10;
		float base = lp.y + UV.y;
		int r = int(floor(base + 0.5 + 0.001)) - int(floor(lp.y));
		if (r < 0 || r > h) discard;
		int idx = paint(style, i, r, n, h, k, ramp, variant, seed, door);
		if (idx < 0) discard;
		if (fade && style != ST_INK) idx = pal_at(idx, 3);
		COLOR = vec4(texelFetch(lut, ivec2(idx, 0), 0).rgb, 1.0);
	}
}
"""

const _GROUND_BODY := """
uniform sampler2D shade_mask : filter_nearest;
uniform sampler2D ground_tex : filter_nearest;
// where ground (0, 0) lands in the texture, low-res pixels per metre, the active radius (m)
uniform vec2 origin;
uniform float scale;
uniform float active;
// where this texture's pixel (0, 0) sits in the whole drawing (a lot redraw draws a piece)
uniform vec2 offset;

bool is_pave(int idx) { return idx == PAVE || idx == PAVE_D; }

int at(ivec2 p) {
	vec4 t = texelFetch(ground_tex, p, 0);
	return t.a < 0.5 ? -1 : int(round(t.r * 255.0));
}

void fragment() {
	ivec2 p = ivec2(floor(UV / TEXTURE_PIXEL_SIZE));
	int idx = at(p);
	if (idx < 0) discard;
	vec2 c = vec2(p) + 0.5 - origin;
	ivec2 q = p + ivec2(offset);
	float a = c.x / scale;
	float b = 2.0 * c.y / scale;
	float u = (a + b) * 0.5;
	float v = (b - a) * 0.5;
	float hn = h01(q.x, q.y, 5, 9);
	int was = idx;
	if (idx == PAVE) {
		bool odd = mod(floor(u / 3.0) + floor(v / 3.0), 2.0) < 0.5;
		if (odd && (mod(u, 3.0) < 0.55 || mod(v, 3.0) < 0.55)) idx = PAVE_D;
	} else if (idx == ASPH) {
		if (hn < 0.05) idx = ASPH_L;
		else if (hn > 0.97) idx = ASPH_S;
	} else if (idx == GRASS) {
		if (hn < 0.07) idx = GRASS_L;
		else if (hn > 0.92) idx = GRASS_D;
	} else if (idx == CYAN_D) {
		// water: short ripples along the iso axis
		if (h01(q.x / 3, q.y, 6, 2) < 0.06) idx = CYAN_M;
	}
	// kerbs: the pavement pixel just above the asphalt catches the light, the asphalt just below
	// the pavement is in its shade
	if (is_pave(was) && at(p + ivec2(0, 1)) == ASPH) idx = CREAM;
	if (was == ASPH && is_pave(at(p - ivec2(0, 1)))) idx = ASPH_S;
	if (was == CYAN_D && at(p - ivec2(0, 1)) != CYAN_D) idx = CYAN_DD;
	if (u * u + v * v > active * active) idx = pal_at(idx, 2);
	if (texelFetch(shade_mask, p, 0).r > 0.5) idx = pal_at(idx, 1);
	COLOR = vec4(texelFetch(lut, ivec2(idx, 0), 0).rgb, 1.0);
}
"""

static var _facade: Shader
static var _ground: Shader


static func _header() -> String:
	var out := "uniform sampler2D lut : filter_nearest;\n" + Pal.shader_consts()
	out += "const int R_GLS = %d;\nconst int R_CON = %d;\n" % [Pal.ramp_of("GLS"),
		Pal.ramp_of("CON")]
	# the awnings in shade: the mockup darkens them to 78% and the palette snaps them
	var awn: Array[String] = ["RED", "CYAN_M", "GRASS_D", "GOLD_M"]
	for k in awn.size():
		out += "const int AWD%d = %d;\n" % [k, Pal.darker(Pal.i(awn[k]), 0.78)]
	return out


static func facade_material(atlas: Texture2D) -> ShaderMaterial:
	if _facade == null:
		_facade = Shader.new()
		_facade.code = "shader_type canvas_item;\nrender_mode blend_disabled;\n" \
			+ "varying vec2 lp;\nuniform sampler2D sprites : filter_nearest;\n" + _header() \
			+ _COMMON + _FACADE_BODY
	var m := ShaderMaterial.new()
	m.shader = _facade
	m.set_shader_parameter("lut", Pal.lut())
	m.set_shader_parameter("sprites", atlas)
	return m


static func ground_material(ground: Texture2D, mask: Texture2D, origin: Vector2,
		scale: float, active: float, offset: Vector2i = Vector2i.ZERO) -> ShaderMaterial:
	if _ground == null:
		_ground = Shader.new()
		_ground.code = "shader_type canvas_item;\nrender_mode blend_disabled;\n" + _header() \
			+ _COMMON + _GROUND_BODY
	var m := ShaderMaterial.new()
	m.shader = _ground
	m.set_shader_parameter("lut", Pal.lut())
	m.set_shader_parameter("shade_mask", mask)
	m.set_shader_parameter("ground_tex", ground)
	m.set_shader_parameter("origin", origin)
	m.set_shader_parameter("scale", scale)
	m.set_shader_parameter("active", active if active > 0.0 else 1.0e9)
	m.set_shader_parameter("offset", Vector2(offset))
	return m
