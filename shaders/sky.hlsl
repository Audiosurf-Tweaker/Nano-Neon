// Nano Neon - an electronic/neon sky in the spirit of Audiosurf 2's "the grid" skin, rebuilt for a
// direction-only ps_3_0 fullsky layer.
//
// Why every constant is what it is:  design/nano-neon-architecture.md
// Constant contract and the traps:   Docs/skyboxes/shaders.md
// Music registers:                   Docs/skyboxes/music.md
//
// Everything is in one file on purpose: hot reload is documented for shaders, Lua, textures and the
// manifest - not for included headers, and edit/save/see is the whole authoring loop.
//
// Three coordinate systems, and every feature picks one (see the design doc, section 5):
//   * PLANE   - p = d.xz / |d.y|. An infinite horizontal plane at unit height. Gives real
//               perspective for free: cells shrink toward the horizon, lines converge on a point.
//   * BAND    - |d.y| as an angle. Everything that lives near the horizon: glow, towers.
//   * CUBE    - the dominant axis of d gives a square domain with no poles and no infinities.
//               For anything that must be equally dense in every direction: particles.
//
// REGISTER MAP (c0-c5 come from sky_common.hlsli, c208-c223 belong to the engine)
//   c6  g_pal_a          rgb = calm colour,            a = chroma restore
//   c7  g_pal_b          rgb = hot colour,             a = void depth
//   c8  g_pal_drive      x = window, y = gain, z = curve, w = floor
//   c9  g_glow        x = height (deg), y = strength, z = below
//   c10 g_towers         x = max height (deg), z = music gain, w = brightness   (y unused)
//   c11 g_floor          x = pitch, y = line width, z = brightness, w = scroll
//   c13 g_mosaic         x = density, y = pitch, z = brightness, w = second layer
//   c15 g_particles      x = density, y = size, z = brightness, w = speed
//   c16 g_particles_drive x = window, y = gain, z = punch, w = spectrum mix
//   c29 g_ceiling        x = density, y = pitch, z = brightness, w = second layer
//   c21 g_master         x = brightness, y = grain, z = haze, w = spectrum drive
//   c22 g_debug          x = mode
//   c23 g_band_mix       x..w = weights of the four g_music_eq bands
//
// Nothing else is declared. fxc drops a uniform the shader never reads, and the plugin uploads only
// the registers that survive - so a knob for a variable this file does not touch is a knob that
// silently does nothing (manifest.md, "The trap worth reading twice").

#include "sky_common.hlsli"

// ---------------------------------------------------------------------------------------------
// switches
//
// NANO_DEBUG  1 turns on debug modes 1-4 (coordinate systems drawn raw). They are the most
//             expensive thing in the file and are only useful for a minute at a time, so they are
//             compiled out by default: ps_3_0 cards may report as few as 512 instruction slots and
//             this file wants to stay under that.
// NANO_USE_VPOS 1 declares a ps_3_0 VPOS input, which the manual never mentions. It compiles
//             (verified with fxc, `dcl vPos.xy` is emitted) and buys a real screen-space
//             coordinate for the dither. Left at 0 for the first run so a shader that fails to
//             compile cannot be mistaken for a sky that does not draw.
#ifndef NANO_DEBUG
#define NANO_DEBUG 1
#endif
#ifndef NANO_USE_VPOS
#define NANO_USE_VPOS 0
#endif

// ---------------------------------------------------------------------------------------------
// knobs

float4 g_pal_a           : register(c6);
float4 g_pal_b           : register(c7);
float4 g_pal_drive       : register(c8);
float4 g_glow            : register(c9);
float4 g_towers          : register(c10);
float4 g_floor           : register(c11);
float4 g_pal_path        : register(c12);   // x = hue path: 0 = shortest arc, 1 = the other way
float4 g_mosaic          : register(c13);
float4 g_extra           : register(c14);   // x = void depth, y = saturation
float4 g_particles       : register(c15);
float4 g_particles_drive : register(c16);
float4 g_eq_extra        : register(c24);   // x = smoothing, y = floor (deg), z = bar width, w = wrap count
float4 g_eq_rand         : register(c25);   // x = random low, y = random high (height multiplier)
float4 g_particles_extra : register(c26);   // x = speed from music, y = surge rate, z = pole bias
float4 g_particles_layers : register(c27);  // x/y/z = near/mid/far angular rate, w = per-particle swing
float4 g_particles_fx     : register(c28);  // x = tumble, y = streak, z = vertical drift
float4 g_ceiling          : register(c29);  // x = density, y = pitch, z = brightness, w = mix
float4 g_master          : register(c21);
float4 g_debug           : register(c22);
float4 g_band_mix        : register(c23);

// ---------------------------------------------------------------------------------------------
// constants

static const float k_inv2pi = 0.15915494;   // 1 / (2*pi)
static const float k_deg    = 57.2957795;
static const float k_eps_y  = 0.0015;       // ~0.09 deg. Keeps the plane projection finite at the
                                            // horizon - without it the divide is a NaN, and a NaN
                                            // paints black with no error anywhere (limits.md).

// Block gains. With these, a brightness knob at 1.0 reads as "the reference frame" - the tonemap is
// 1 - exp(-scene), so a feature only reaches white at an energy of three or four, and a slider whose
// useful range is the first ten percent of its travel is a bad slider.
static const float k_gain_glow      = 2.2;
// Both layers saturate independently, and that is not a detail: a linear brightness knob on a bar
// that is meant to read as "60 % toward white" turns it into white the moment the player pushes the
// slider, and a white rectangle on a dark sky looks like a hole cut in the frame, not like a bar.
// The core tops out at an energy where the tone map still returns its own colour; only the halo,
// which is meant to glow, is allowed to blow out.
static const float k_eq_core_max     = 1.15;
static const float k_eq_core_rate    = 1.00;
static const float k_eq_halo_max     = 2.50;
static const float k_eq_halo_rate    = 0.60;
static const float k_gain_floor     = 1.6;
static const float k_gain_particles = 1.8;

// ---------------------------------------------------------------------------------------------
// helpers

// Two fracs and a dot, no sin. Large cell indices lose precision, but those cells are faded out by
// the footprint long before it shows.
float hash21(float2 p)
{
    p = frac(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return frac(p.x * p.y);
}


float hash11(float x)
{
    return hash21(float2(x, 7.0));
}

// Hue has to be interpolated on the circle. A straight RGB ramp between two opposed hues passes
// through grey - and it passes through it exactly at the middle of the music, which is where the
// sky is brightest. Cheap branchless conversions, standard form.
float3 rgb2hsv(float3 c)
{
    const float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    const float4 p = lerp(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    const float4 q = lerp(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    const float  d = q.x - min(q.w, q.y);
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + 1e-10)), d / (q.x + 1e-10), q.x);
}

float3 hsv2rgb(float3 c)
{
    const float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    const float3 p = abs(frac(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * lerp(K.xxx, saturate(p - K.xxx), c.y);
}

// The time axis: 0 = the fast body (marked USE THIS in sky_common), 1..4 = the g_music_slow ladder
// (0.5, 1.5, 4, 10 s). Fractional values interpolate, so the player lands between windows instead of
// having to pick one. Branchless: four lerps.
float time_axis(float k)
{
    k = saturate(k);
    float v = g_music.y;
    v = lerp(v, g_music_slow.x, saturate(k - 0.0));
    v = lerp(v, g_music_slow.y, saturate(k - 1.0));
    v = lerp(v, g_music_slow.z, saturate(k - 2.0));
    v = lerp(v, g_music_slow.w, saturate(k - 3.0));
    return v;
}

// The spectrum axis: the four bands the game's FFT can honestly support, weighted by the player.
// A zero weighting must not divide by zero - hence the max(). Returns 0 when everything is zeroed.
float eq_drive()
{
    return dot(g_music_eq, g_band_mix) / max(dot(g_band_mix, float4(1.0, 1.0, 1.0, 1.0)), 1e-3);
}

// One shell of the particle field, in the chart's cell units.
//
// The hardest constraint here is that a particle must FIT INSIDE ITS OWN CELL. The cell is the
// region this pixel belongs to, so anything larger is simply cut off at the boundary - which shows
// up as a square sliced along a straight line. Every motion below is therefore bounded so that
// half the width plus the swing never exceeds half a cell, and the streak squeezes the particle
// across the flow instead of stretching it along.
float quad_layer(float2 q, float2 fq, float pitch, float density, float seed, float wrap_x,
                 float aspect, float t, float swing, float tumble, float squash,
                 float bright, float blur)
{
    const float2 pn  = q / pitch;
    const float2 pi  = floor(pn);
    const float2 pf2 = frac(pn);

    // The azimuthal index wraps at the cell count, so the cell straddling +-180 hashes to the same
    // value on both sides. Without it the whole lattice jumps once per revolution.
    const float2 pw = float2(pi.x - wrap_x * floor(pi.x / wrap_x), pi.y);

    const float  h  = hash21(pw + seed);
    const float  on = step(1.0 - density, h);

    // One sincos per particle drives both of its own animations. Phase from the hash, so no two
    // particles move together - and crucially this motion has NO FIXED POINT, unlike any coherent
    // flow, which is obliged by the hairy ball theorem to have two dead spots on a sphere.
    float sp, cp;
    sincos(t * 1.4 + frac(h * 91.7) * 6.2832, sp, cp);

    // Size first, because the wander is bounded by it. Half-width + swing <= 0.5 of a cell or the
    // particle is cut at the boundary, which is exactly the wedge this file has already paid for.
    const float sx = 0.18 + 0.44 * frac(h * 13.71);
    const float sy = (0.18 + 0.44 * frac(h * 29.33)) * aspect;

    // Per-particle wander inside its cell, and it is allowed exactly as much room as the particle
    // itself leaves. That rule matters most at the poles: the chart squeezes the particle to a few
    // hundredths of a cell there, so it earns almost half a cell of travel and keeps moving where
    // the azimuthal drift is invisible - a rotation about the vertical axis barely moves anything
    // when you are looking straight up it.
    // The knob is a FRACTION of the room the particle leaves, not an absolute distance: an absolute
    // distance has to be clamped by the tightest case everywhere and then nothing moves at the pole,
    // where the room is largest and the need greatest.
    const float2 swn = max(float2(0.5 - sx * 0.5, 0.5 - sy * 0.5) * 0.92, 0.0)
                     * saturate(swing);
    const float2 rel = pf2 - 0.5 - float2(cp, sp) * swn;

    // Tumble: a square turning about its own vertical axis projects as width * |cos|. The floor of
    // 0.3 is deliberate - a particle that reaches zero width twice a second at ten pixels across
    // reads as a flicker, not as a rotation.
    const float wide = lerp(1.0, 0.30 + 0.70 * abs(cp), saturate(tumble));

    // Streak: squeeze ACROSS the flow. Stretching along it would leave the cell and get cut; the
    // eye reads a dash either way, and this one cannot clip.
    const float2 sz = float2(sx * wide, sy / (1.0 + max(squash, 0.0) * 0.7));

    // blur widens the anti-aliasing ramp, which reads as defocus on the far shells.
    const float2 fpn = min(fq / pitch, 0.42) * max(blur, 1.0);
    const float2 e   = saturate((sz * 0.5 - abs(rel)) / max(fpn, 1e-4));

    return e.x * e.y * on * (0.30 + 0.70 * frac(h * 51.17)) * bright;
}

// One lattice of rectangular "digital debris": the fine grain the reference floor is made of. The
// second call is rotated so the two lattices never line up - the same reason the noise octaves in
// the bundled sky are rotated (shaders.md, "Textures").
float mosaic_layer(float2 p, float2 fp, float pitch, float density, float seed)
{
    const float2 pn = p / pitch;
    const float2 pi = floor(pn);
    const float2 pf2 = frac(pn);

    const float  h  = hash21(pi + seed);
    const float  on = step(1.0 - density, h);
    const float2 sz = 0.15 + 0.70 * float2(frac(h * 13.71), frac(h * 29.33));
    const float2 fpn = min(fp / pitch, 0.55);

    const float2 e = saturate((sz * 0.5 - abs(pf2 - 0.5)) / max(fpn, 1e-4));
    const float  cell = e.x * e.y * on * (0.30 + 0.70 * frac(h * 51.17));

    // Analytic mip: as a cell goes sub-pixel the pattern must converge to its own average, not
    // dissolve into moire. Average = density * mean coverage * mean brightness, roughly.
    const float mean = density * 0.22 * 0.65;
    return lerp(mean, cell, saturate(1.0 - max(fpn.x, fpn.y)));
}

// ---------------------------------------------------------------------------------------------
// input
//
// The plugin hands a fullsky layer one interpolated direction. VPOS is ps_3_0-only and the manual
// never mentions it, so it is behind a switch: flip NANO_USE_VPOS to 1 to find out whether the
// plugin's compile path accepts it. It buys a real screen-space coordinate for dither and
// vignette; without it the grain rides on dir, which is stable and workable but not per-pixel.

#if NANO_USE_VPOS
struct ps_in
{
    float3 dir  : TEXCOORD0;
    float2 vpos : VPOS;
};
#else
struct ps_in
{
    float3 dir  : TEXCOORD0;
};
#endif

float2 screen_pos(ps_in i)
{
#if NANO_USE_VPOS
    return i.vpos;
#else
    return i.dir.xz * 641.0;
#endif
}

// ---------------------------------------------------------------------------------------------

float4 main(ps_in input) : COLOR0
{
    // ---------------------------------------------------------------------------- frame
    const float3 d = normalize(input.dir);

    // Angular size of a pixel, measured once at the top where the flow is still straight.
    // Derivatives are undefined inside dynamic flow control, and everything below branches.
    const float px = (fwidth(d.x) + fwidth(d.y) + fwidth(d.z)) * 0.35;

    const float ayd = max(-d.y, k_eps_y);   // > 0 below the horizon
    const float ayu = max( d.y, k_eps_y);   // > 0 above it

    // The two planes at unit height. p is the world point where this ray meets them.
    const float2 p_down = d.xz / ayd;
    const float2 p_up   = d.xz / ayu;

    // Pixel footprint in world units on the plane, per screen axis, perspective included. Clamped:
    // at the horizon it goes to infinity and so does fwidth, which is exactly where every pattern
    // has to converge to its own average instead of turning into moire.
    float2 fp = float2(fwidth(p_down.x), fwidth(p_down.y));
    fp = min(fp, 0.5);

    // The same footprint on the plane above the player. It has to be measured separately, not
    // reused: p_down collapses to the epsilon above the horizon, so its fwidth there is meaningless
    // - and p_up is the one that is well behaved exactly where the ceiling has to be drawn.
    float2 fpu = float2(fwidth(p_up.x), fwidth(p_up.y));
    fpu = min(fpu, 0.5);

    // Elevation in degrees and azimuth in radians. atan2 is used by the band features and by the
    // particle domain, and both are periodic in azimuth with an integer count, which is what makes
    // the +-180 degree seam disappear.
    const float elev = asin(clamp(d.y, -1.0, 1.0)) * k_deg;
    const float az   = atan2(d.x, d.z);

    // Particle domain: azimuth and sin(elevation), scaled so a cell is one unit.
    //
    // A 3D lattice sampled at the direction was tried here and is the wrong tool. It works for the
    // ODC sky's filament layer because that is a continuous noise field, and a field never reveals
    // the grid it is sampled from. Discrete points do: a cubic lattice cut by a sphere has latitude
    // rings in it, and a plane cutting a cell draws a polygon whose side count changes with
    // direction - so the squares came out as shards and the field showed its own rows. A chart,
    // with all its faults, is the right tool for points.
    //
    // Seamless because the azimuthal cell count is an INTEGER: q.x jumps by exactly `pcount` at
    // +-180 and the fractional part is continuous. Even, so q.x lands on an exact half-cell there
    // rather than a half-cell off it.
    const float pcount = max(2.0 * floor(0.5 * floor(1.0 / max(g_particles.y, 0.0004) + 0.5)), 8.0);
    const float2 q  = float2(az, d.y) * (k_inv2pi * pcount);
    // The chart stretches by 1/cos toward the poles. This is how much of that stretch to undo when
    // shaping the particle: 1.0 leaves it stretched (streaks when you look up), 2.0 makes a
    // screen-square but shrinks it toward the pole. The knob sets where between them to sit.
    const float ce  = sqrt(saturate(1.0 - d.y * d.y));
    const float ce2 = pow(ce, max(g_particles_extra.z, 0.5));
    const float2 fq = px * (k_inv2pi * pcount) * float2(1.0, ce2);

    const float dbg = g_debug.x;

#if NANO_DEBUG
    // Debug 1-4: show the coordinate systems raw, before any palette or tone mapping. Off by
    // default because they are the most expensive thing in the file and they are only useful for a
    // minute at a time; flip the define, save, and they are back. Modes 5-8 below are always in.
    [branch] if (dbg > 0.5 && dbg < 4.5)
    {
        if (dbg < 1.5)
        {
            // elevation in 10-degree bands, horizon in green
            const float b = floor(abs(elev) / 10.0) / 9.0;
            float3 col = float3(b, b * 0.75, b * 0.55);
            col = lerp(col, float3(0.0, 1.0, 0.2), saturate(1.0 - abs(elev) * 2.0));
            return float4(col, 1.0);
        }
        if (dbg < 2.5)
        {
            // plane coordinates: a checkerboard, so the perspective is visible as such
            const float2 pc = floor(p_down / 0.25);
            const float  ck = frac((pc.x + pc.y) * 0.5) * 2.0;
            const float2 gd = abs(frac(p_down / 0.25 + 0.5) - 0.5) * 0.25;
            const float  gl = 1.0 - smoothstep(0.0, max(0.004, fp.x), min(gd.x, gd.y));
            return float4(saturate(ck * 0.25 + gl), saturate(ck * 0.2), 0.0, 1.0);
        }
        if (dbg < 3.5)
        {
            // footprint: black near, white far. The bright ring is where detail has to disappear.
            const float t = saturate(log2(max(fp.x, 1e-6) / 0.001) / 9.0);
            return float4(t, t, t, 1.0);
        }
        // particle chart: a checkerboard in q. The latitude bands must not be obvious.
        const float2 pc = floor(q * 2.0);
        const float  ch = frac((pc.x + pc.y) * 0.5) * 2.0;
        return float4(saturate(ch * 0.55 + 0.15).xxx, 1.0);
    }

    // 10 = the pixel footprint px, 11 = |dy|, which is smooth on the sphere by construction.
    // These two were written to hunt a seam between cube faces and are kept because the same question
    // comes back for any domain: if the seam shows in 10 and not in 11 the footprint is the cause, and
    // if it shows in neither it is not in this shader at all.
    [branch] if (dbg > 9.5 && dbg < 10.5)
    {
        const float t = saturate(log2(max(px, 1e-9) / 0.00005) / 4.0);
        return float4(t, t, t, 1.0);
    }
    [branch] if (dbg > 10.5)
    {
        const float t = saturate(abs(d.y));
        return float4(t, t, t, 1.0);
    }
#endif

    // ---------------------------------------------------------------------------- palette
    // One colour drives the whole scene: the "hot" end is reached by music intensity on the time
    // axis, and the void is that same colour at 5-8 %, not a separate one - otherwise the emptiness
    // stays cyan while the neon goes red and the frame falls apart into two hues.
    const float pmw = time_axis(g_pal_drive.x);
    const float pb  = pow(saturate(g_pal_drive.w + pmw * g_pal_drive.y),
                          max(g_pal_drive.z, 0.1)) * g_music.w;

    const float3 hA = rgb2hsv(g_pal_a.rgb);
    const float3 hB = rgb2hsv(g_pal_b.rgb);
    float dh = hB.x - hA.x;
    dh -= floor(dh + 0.5);                                  // shortest way round the circle
    // Two opposed hues have no neutral middle: the short arc runs through the third hue next door.
    // Which third hue is a taste call, not a maths one, so it is a switch rather than a guess.
    dh -= sign(dh) * saturate(g_pal_path.x);

    // Saturation and void depth live in g_extra, NOT in the .a of the two colour registers.
    //
    // A colour param writes rgb. Whatever owns that float4 writes the whole thing, so .a arrives as
    // zero - and .a was the saturation multiplier, which is why the sky came out with no hue at all,
    // white core fading to white. Do not hang a knob on the alpha of a colour.
    const float3 neon_c = hsv2rgb(float3(frac(hA.x + dh * pb),
                                         saturate(lerp(hA.y, hB.y, pb) * g_extra.y),
                                         lerp(hA.z, hB.z, pb)));

    const float3 deep_c = neon_c * g_extra.x;

    // ---------------------------------------------------------------------------- void
    // Not black. 7-34 % of the reference frames sit below 0.02 luminance and the rest is a dim wash
    // of the same hue - a vacuum reads as dead.
    const float wide = exp(-abs(elev) * (1.0 / 38.0));
    float3 scene = deep_c * (0.55 + 0.95 * wide);

    const float grain = hash21(d.xz * 220.0 + d.y * 97.0) - 0.5;
    scene *= 1.0 + grain * g_master.y * 0.6;

    // ---------------------------------------------------------------------------- horizon
    // Mirrored about the horizon, and that is the whole point: the reference's band is one glowing
    // mass with a symmetric silhouette, not a line with a one-sided skirt. Measured off the frames
    // as 0.72 at the horizon falling to 0.06 at 12 % of frame height.
    float3 s_horizon = 0.0;
    [branch] if (g_glow.y > 0.001)
    {
        const float sig  = max(g_glow.x, 0.2);
        const float band = 0.72 * exp(-abs(elev) * (1.0 / sig))
                         + 0.05 * exp(-abs(elev) * (1.0 / max(sig * 5.0, 1.0)));
        // A brighter crest sitting on the horizon, inside the band. Narrow, but not a line: the band
        // still carries most of the energy, which is what keeps the horizon soft.
        const float crest = saturate(g_glow.z) * exp(-abs(elev) * (1.0 / max(sig * 0.22, 0.1)));
        s_horizon = neon_c * (band + crest) * g_glow.y * k_gain_glow;
    }

    // ---------------------------------------------------------------------------- equalizer
    // Two layers, and the split is the whole trick.
    //
    //   backlight - the same silhouette, wider and taller, soft, in the live palette colour
    //   bar       - straight sides, straight top, uniform brightness, nearly white
    //
    // One layer cannot do both jobs: it is either soft enough to glow (and then the height, which is
    // the entire signal, turns to mush) or hard enough to read (and then there is no glow at all).
    // The reference has both, so both are drawn, and the glow follows the shape instead of blurring
    // it.
    //
    // The shape is a palindrome, not a ramp. The four bands are walked out and back -
    // [x y z w w z y x] - and that eight-slot cell repeats around the ring. band = min(k, 7-k) with
    // k = i mod 8 gives exactly that, with no lookup table and no seam.
    float3 s_eq = 0.0;
    [branch] if (g_towers.w > 0.001 && g_towers.x > 0.001)
    {
        const float K  = max(floor(g_eq_extra.w + 0.5), 1.0);
        const float N  = 8.0 * K;
        const float uc = az * k_inv2pi * N;
        const float i  = floor(uc);
        const float f  = frac(uc);

        const float kk = i - 8.0 * floor(i * 0.125);
        const float b  = min(kk, 7.0 - kk);
        const float4 bm = float4(1.0 - abs(b - 0.0), 1.0 - abs(b - 1.0),
                                 1.0 - abs(b - 2.0), 1.0 - abs(b - 3.0));
        const float spec = dot(g_music_eq, bm);

        const float drive = lerp(spec, time_axis(3.0), saturate(g_eq_extra.x)) * g_music.w;

        // A per-cell multiplier, so the repeated palindrome does not read as one tile copied around
        // the ring. The cell index jumps by K at +-180, so it is wrapped before hashing. The range
        // is the player's: equal bounds switch the variation off entirely, and an upper bound above
        // 1 lets the loudest cycles overshoot Max Height.
        const float cell  = floor(i * 0.125);
        const float cw    = cell - K * floor(cell / K);
        const float crand = lerp(g_eq_rand.x, g_eq_rand.y, hash11(cw));

        const float h = max(g_eq_extra.y,
                            crand * g_towers.x * (1.0 - exp(-g_towers.z * drive)));

        const float wAuth = saturate(g_eq_extra.z);
        const float fpx   = max(px * k_inv2pi * N, 1e-6);
        const float pdeg  = max(px * k_deg, 0.01);
        const float ae    = abs(elev);

        // ---- layer 1: the backlight ----------------------------------------------------------
        const float haloW = saturate(wAuth * 2.0 + 0.25);
        const float haloH = max(h * 1.30, 1e-3);
        const float hx    = 1.0 - smoothstep(0.0, haloW, abs(f - 0.5));
        const float hy    = saturate(1.0 - ae / haloH);
        const float halo  = hx * hy * hy;

        // ---- layer 2: the bar ----------------------------------------------------------------
        // Uniform along its height. A gradient toward the top made every bar look the same length,
        // which is fatal when height is the only thing carrying the signal.
        const float coreW = max(wAuth, fpx);
        const float maskW = (1.0 - smoothstep(0.0, coreW, abs(f - 0.5))) * saturate(wAuth / coreW);
        // width 1.0 means a continuous wall, so the slot edges must not dip
        const float coreX = lerp(maskW, 1.0, step(0.999, wAuth));
        // straight top, one pixel of anti-aliasing and not one pixel more
        const float coreY = saturate((h - ae) / pdeg + 0.5);
        const float core  = coreX * coreY;

        // Nearly white: the analyser has to stay readable against its own backlight.
        const float3 core_c = lerp(neon_c, float3(1.0, 1.0, 1.0), 0.45);

        const float eHalo = k_eq_halo_max * (1.0 - exp(-k_eq_halo_rate * g_towers.w));
        const float eCore = k_eq_core_max * (1.0 - exp(-k_eq_core_rate * g_towers.w));

        // The core occludes its own backlight. Without this the two layers simply add, and at any
        // real brightness the sum blows the whole bar to white - the "hole cut in the frame" look.
        // A bar that is opaque in front of its glow is also what the reference shows.
        s_eq = neon_c * halo * (1.0 - 0.85 * core) * eHalo
             + core_c * core * eCore;
    }
    // ---------------------------------------------------------------------------- floor
    // The plan view: the same lattice the towers stand on, seen from above. Lines converge on the
    // vanishing point, and that - not any blur - is where the sense of speed comes from.
    float3 s_floor = 0.0;
    [branch] if (g_floor.z > 0.001)
    {
        const float pitch = max(g_floor.x, 0.02);
        // The one motion this shader cannot derive: the ship's speed. A knob instead of a lie, and
        // zero by default - the camera's own turning already supplies real motion.
        const float2 pn   = p_down / pitch + float2(g_runtime.x * g_floor.w, 0.0);
        const float2 gd   = abs(frac(pn + 0.5) - 0.5) * pitch;          // world units to a line
        const float2 wAuth = g_floor.y * pitch;
        const float2 gw    = max(wAuth.xx, fp);
        const float2 gl    = (1.0 - smoothstep(0.0, gw, gd)) * saturate(wAuth.xx / gw);
        float g = max(gl.x, gl.y);

        // the bass pumps the ground; the mix lives in g_master.w
        g *= lerp(1.0, 0.35 + 1.6 * saturate(g_music_eq.x * 1.4), saturate(g_master.w));

        s_floor = neon_c * g * g_floor.z * k_gain_floor;
    }

    // ---------------------------------------------------------------------------- mosaic
    // The floor's texture: not the grid, but the fine rectangular grain the references are made
    // of. Without it the plan reads as graph paper.
    float3 s_mosaic = 0.0;
    [branch] if (g_mosaic.z > 0.001 && g_mosaic.x > 0.001)
    {
        const float mp = max(g_mosaic.y, 0.005);
        const float m1 = mosaic_layer(p_down, fp, mp, g_mosaic.x, 0.0);

        // second lattice, rotated ~37 degrees so the two never beat against each other
        const float2 pr  = float2(p_down.x * 0.8 - p_down.y * 0.6, p_down.x * 0.6 + p_down.y * 0.8);
        const float2 fpr = float2(fp.x * 0.8 + fp.y * 0.6, fp.x * 0.6 + fp.y * 0.8);
        const float m2 = mosaic_layer(pr, fpr, mp * 2.7, g_mosaic.x * 0.8, 37.0);

        s_mosaic = neon_c * (m1 + m2 * saturate(g_mosaic.w)) * g_mosaic.z;
    }

    // ---------------------------------------------------------------------------- ceiling
    // The floor's grain, above the player instead of below.
    //
    // This is the plan view seen in a mirror: the same projection, p = xz/|y|, on the other side of
    // the horizon. It costs one more call to the lattice that already exists, and it fills the one
    // part of the sky that had nothing in it - looking straight up used to give bare particles and
    // haze.
    //
    // Deliberately NOT the same numbers as the floor: different pitch, different seeds, its own
    // brightness. A literal mirror image would read as a reflection, and a reflection of a floor is
    // a thing a room has, not a sky.
    float3 s_ceil = 0.0;
    [branch] if (g_ceiling.z > 0.001 && g_ceiling.x > 0.001)
    {
        const float cp = max(g_ceiling.y, 0.005);
        const float c1 = mosaic_layer(p_up, fpu, cp, g_ceiling.x, 91.0);

        // Rotated, like the floor's second lattice, so the two do not beat against each other.
        const float2 cr  = float2(p_up.x * 0.8 - p_up.y * 0.6, p_up.x * 0.6 + p_up.y * 0.8);
        const float2 fcr = float2(fpu.x * 0.8 + fpu.y * 0.6, fpu.x * 0.6 + fpu.y * 0.8);
        const float c2 = mosaic_layer(cr, fcr, cp * 2.7, g_ceiling.x * 0.8, 53.0);

        s_ceil = neon_c * (c1 + c2 * saturate(g_ceiling.w)) * g_ceiling.z;
    }

    // ---------------------------------------------------------------------------- particles
    // Flying quads in the cube domain. They are the anchor of a frame with no horizon in it - look
    // straight up a steep climb and this is what is there. They also translate, which no plane
    // dares do: a particle has no tie to the ground, so "the medium is moving" is not a lie about
    // a speed this shader cannot know.
    float3 s_particles = 0.0;
    [branch] if (g_particles.z > 0.001)
    {
        const float mw  = time_axis(g_particles_drive.x);
        const float eqt = eq_drive();
        const float mix = saturate(g_particles_drive.w);

        // 0.12 is the floor: in silence the sky must not go empty, just quiet
        const float drv = saturate(0.12
                                 + g_particles_drive.y * lerp(mw, eqt, mix)
                                 + g_particles_drive.z * g_music.z) * g_music.w;

        // The field slides through the lattice - an offset on the sample point, not a phase on a
        // chart, so there is nothing to wrap and nothing that can tear.
        //
        // Constant speed, never multiplied by a music term. `t * f(t)` is not a moving pattern, it
        // is a teleport: the onset pulse fires, the multiplier jumps, and the whole field lands
        // somewhere else in one frame. That is exactly the strobe this line used to cause.
        //
        // The music adds a surge, not a speed. A shader has no state and cannot integrate a varying
        // speed, so `t * music` is not "faster", it is a teleport. What is safe is an oscillation
        // whose AMPLITUDE follows the music: the instantaneous rate is base + amp*rate*mw*cos(...),
        // so the field visibly surges and settles back as the song swells, and nothing jumps.
        //
        // mw, not drv. drv carries the onset pulse, which is instantaneous by definition - using it
        // here would put a step of amp*punch into the offset on every kick, which is the same
        // teleport wearing a different hat. mw is the slow ladder the window knob selects.
        const float surge = g_particles_extra.x * 1.2 * mw * g_music.w
                          * sin(g_runtime.x * max(g_particles_extra.y, 0.05));
        // Differential shells. This is the whole of the depth illusion: the camera sits at the
        // centre of the sphere and cannot move, so nothing here can have real parallax - but three
        // shells turning at different rates shear against each other, and a far shell running
        // backwards is the strongest depth cue a direction-only shader has.
        //
        // It also gets real parallax for free the moment the player turns: the camera rotation is
        // shared, the layer rates are not, so the shells slide apart on every corner.
        const float t    = g_runtime.x;
        // Cells per second at Drift = 1. At 0.6 the whole field turned at about one degree a
        // second, which is why it read as static no matter how much detail was added on top.
        const float rate = g_particles.w * 5.0;
        const float3 spd = g_particles_layers.xyz;

        // Each shell also drifts in elevation, and that component is not decoration: a rotation
        // about the vertical axis moves nothing on screen when the player is looking straight up it,
        // and looking up is exactly when the particles are the whole sky. The elevation axis has the
        // opposite fault - its angular speed grows as 1/cos toward the pole - so it is kept to a
        // fraction of the azimuthal rate, enough to keep the field alive there without turning the
        // zenith into a jet.
        const float vd = saturate(g_particles_fx.z);

        const float2 q1 = q + float2(t * rate * spd.x + surge,       t * rate * spd.x * vd);
        const float2 q2 = q + float2(t * rate * spd.y + surge * 0.7, t * rate * spd.y * vd);
        const float2 q3 = q + float2(t * rate * spd.z + surge * 0.4, t * rate * spd.z * vd);

        // How much each shell smears, from its own speed plus the live musical surge.
        const float act = g_particles_extra.x * mw;
        const float str = g_particles_fx.y;
        const float sk1 = str * (abs(spd.x) + act);
        const float sk2 = str * (abs(spd.y) + act);
        const float sk3 = str * (abs(spd.z) + act);

        const float sw = g_particles_layers.w;
        const float tb = g_particles_fx.x;

        // Depth cues: near is bright, sharp and warmer toward white; far is dim, soft (a wide
        // anti-aliasing ramp reads as defocus) and sits back in the palette colour.
        const float3 tint_n = lerp(neon_c, float3(1.0, 1.0, 1.0), 0.30);

        const float3 quads =
              quad_layer(q1, fq, 1.0,  g_particles.x,        0.0,  pcount,     ce2, t, sw,       tb, sk1, 1.00, 1.0) * tint_n
            + quad_layer(q2, fq, 0.5,  g_particles.x * 0.90, 11.0, pcount * 2, ce2, t, sw * 0.9, tb, sk2, 0.85, 1.35) * neon_c
            + quad_layer(q3, fq, 0.25, g_particles.x * 0.72, 23.0, pcount * 4, ce2, t, sw * 0.8, tb, sk3, 0.65, 1.70) * neon_c * 0.85;

        s_particles = quads * g_particles.z * drv * k_gain_particles;
    }

    // ---------------------------------------------------------------------------- compose
    scene += s_horizon + s_eq + s_floor + s_mosaic + s_ceil + s_particles;

    [branch] if (dbg > 4.5)
    {
        // single-block views, so a knob can be zeroed and its cost measured on its own
        const float m5 = step(4.5, dbg) * step(dbg, 5.5);
        const float m6 = step(5.5, dbg) * step(dbg, 6.5);
        const float m7 = step(6.5, dbg) * step(dbg, 7.5);
        const float m8 = step(7.5, dbg) * step(dbg, 8.5);
        const float m9 = step(8.5, dbg);
        if (m5 + m6 + m7 + m8 + m9 > 0.5)
            scene = s_horizon * m5 + s_eq * m6 + s_floor * m7
                  + (s_mosaic + s_ceil) * m8 + s_particles * m9;
    }

    // Height haze. Additive, not a wash: lerping toward a bright colour lifts the blacks and the
    // whole frame turns grey, which is what the first draft of this did. Light scatters, it does
    // not replace. This is also what softens the grid converging on the horizon.
    const float haze = exp(-abs(elev) * (1.0 / 12.0)) * saturate(g_master.z);
    scene += neon_c * haze * 0.10;

    // ---------------------------------------------------------------------------- tone map
    // Per-channel, because that is what turns an overbright neon into white without ever painting
    // white: measured off the frames, saturation holds at 0.5-0.59 up to luminance 0.90 and drops
    // to 0.09 above 0.95. A separate white stop is not needed.
    float3 col = 1.0 - exp(-scene * max(g_master.x, 0.001));

    // Dither. Wide smooth gradients in 8 bits band - and they band visibly in the references too.
    const float dn = hash21(screen_pos(input)) - 0.5;
    col += dn * saturate(g_master.y) * (2.0 / 255.0);

    return float4(saturate(col), 1.0);
}
