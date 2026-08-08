#include <metal_stdlib>
using namespace metal;

/* The native forward pass, deliberately close to what the web build's
   MeshStandardMaterial + FogExp2 + flashlight produce — the point of the port
   is that it looks like the game people already played. The VHS post chain
   sits on top of this and is ported separately.

   Every uniform is a float4. MSL aligns float3 to 16 bytes, so mixing float3
   and float in a struct produces padding that is easy to get subtly wrong on
   the Swift side; packing companion scalars into .w makes the layout
   unambiguous and keeps Swift/MSL in lockstep. */

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
};

struct VertexOut {
    float4 position [[position]];
    float3 worldPos;
    float3 normal;
    float2 uv;
};

#define MAX_POINT_LIGHTS 8

/* xyz = world position, w = range */
/* xyz = colour,         w = intensity */
struct PointLightU {
    float4 positionRange;
    float4 colorIntensity;
};

struct SceneUniforms {
    float4x4 viewProjection;
    float4 cameraPos;        // xyz
    float4 cameraForward;    // xyz
    float4 ambient;          // rgb, w = intensity
    float4 hemiSky;          // rgb, w = hemisphere intensity
    float4 hemiGround;       // rgb, w = fog density
    float4 fogColor;         // rgb, w = wall height
    float4 flash;            // rgb, w = intensity (0 = lamp off)
    float4 flashParams;      // cosInner, cosOuter, range, exposure
    float4 misc;             // x = point light count
    PointLightU pointLights[MAX_POINT_LIGHTS];
};

vertex VertexOut level_vertex(VertexIn in [[stage_in]],
                              constant SceneUniforms &u [[buffer(1)]]) {
    VertexOut out;
    out.worldPos = in.position;              // level meshes are authored in world space
    out.position = u.viewProjection * float4(in.position, 1.0);
    out.normal   = in.normal;
    out.uv       = in.uv;
    return out;
}

/* Contact shadowing that mirrors the web build's wall gradient: surfaces
   darken toward the floor and the ceiling junction, which is what makes
   corners read as a real room instead of flat geometry. */
static inline float contactAO(float worldY, float wallHeight) {
    float ao = 1.0
             - 0.30 * exp(-worldY * 2.4)
             - 0.22 * exp(-(wallHeight - worldY) * 2.0);
    return clamp(ao, 0.35, 1.0);
}

/* Tangent frame, derived rather than stored.

   Every level surface is axis-aligned and its UVs come straight from world
   coordinates (see `LevelGeometry.faceX/faceZ` and `InterleavedMesh.groundPlane`):
   walls take u from the horizontal axis and v from world Y, floors and ceilings
   take u,v from x,z. So dP/du and dP/dv are known exactly from the face normal,
   and shipping per-vertex tangents would just be storing a constant. */
static inline float3x3 tangentFrame(float3 N) {
    float3 T, B;
    if (abs(N.y) > 0.5) {          // floor or ceiling: u = x, v = z
        T = float3(1, 0, 0);
        B = float3(0, 0, 1);
    } else if (abs(N.z) > 0.5) {   // wall facing ±Z: u = x, v = y
        T = float3(1, 0, 0);
        B = float3(0, 1, 0);
    } else {                       // wall facing ±X: u = z, v = y
        T = float3(0, 0, 1);
        B = float3(0, 1, 0);
    }
    return float3x3(T, B, N);
}

/* The filmic curve the web renderer tone-maps with (the Narkowicz ACES fit).
   It lived inline at the end of `level_fragment`; it is a function now because
   the composite pass needs the same curve, and two copies of a tone-map that
   drift apart is the kind of bug nobody sees until the screenshots disagree. */
static inline float3 acesFilm(float3 x) {
    x = max(x, 0.0);
    float3 mapped = (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);
    return clamp(mapped, 0.0, 1.0);
}

fragment float4 level_fragment(VertexOut in [[stage_in]],
                               constant SceneUniforms &u [[buffer(1)]],
                               texture2d<float> albedo [[texture(0)]],
                               texture2d<float> normalTex [[texture(1)]],
                               texture2d<float> roughTex [[texture(2)]],
                               sampler samp [[sampler(0)]]) {
    float3 base = albedo.sample(samp, in.uv).rgb;
    float3 N = normalize(in.normal);

    // Perturb by the tangent-space normal map. The same buffer the web build
    // feeds MeshStandardMaterial, read with the same dP/du, dP/dv convention.
    float3 tn = normalTex.sample(samp, in.uv).xyz * 2.0 - 1.0;
    N = normalize(tangentFrame(N) * tn);

    // 0 = mirror, 1 = fully rough. Drives both the spec lobe and its strength,
    // so wet concrete and pool tile pick up highlights the carpet never does.
    float roughness = clamp(roughTex.sample(samp, in.uv).r, 0.04, 1.0);
    // Phong exponent from roughness, bounded: below ~4 the "highlight" is just
    // a wash over the whole surface, and above ~400 it is a subpixel glint that
    // only ever shows up as shimmer.
    float shininess = clamp(2.0 / (roughness * roughness * roughness * roughness), 4.0, 400.0);
    float specStrength = (1.0 - roughness) * (1.0 - roughness) * 0.6;
    float3 V = normalize(u.cameraPos.xyz - in.worldPos);
    float3 specular = float3(0.0);

    // Hemisphere ambient: sky above, bounce below. The flat fluorescent wash
    // of the Backrooms is mostly ambient, so this carries a lot of the look.
    float hemiMix = 0.5 + 0.5 * N.y;
    float3 light = u.ambient.rgb * u.ambient.w
                 + mix(u.hemiGround.rgb, u.hemiSky.rgb, hemiMix) * u.hemiSky.w;

    int lightCount = min(int(u.misc.x), MAX_POINT_LIGHTS);
    for (int i = 0; i < lightCount; ++i) {
        float3 toL = u.pointLights[i].positionRange.xyz - in.worldPos;
        float range = u.pointLights[i].positionRange.w;
        float dist = length(toL);
        if (dist > range) continue;
        float3 L = toL / max(dist, 1e-4);
        float atten = clamp(1.0 - dist / range, 0.0, 1.0);
        atten *= atten;                                   // quadratic-ish falloff
        float ndl = max(dot(N, L), 0.0);
        light += u.pointLights[i].colorIntensity.rgb
               * (u.pointLights[i].colorIntensity.w * ndl * atten);
        if (specStrength > 0.001 && ndl > 0.0) {
            float3 H = normalize(L + V);
            specular += u.pointLights[i].colorIntensity.rgb
                      * (u.pointLights[i].colorIntensity.w * atten * specStrength
                         * pow(max(dot(N, H), 0.0), shininess));
        }
    }

    // The camcorder lamp — a spot cone from the operator's eye.
    if (u.flash.w > 0.0) {
        float3 toC = u.cameraPos.xyz - in.worldPos;
        float dist = length(toC);
        float3 L = toC / max(dist, 1e-4);
        float spot = dot(-L, normalize(u.cameraForward.xyz));
        float cone = smoothstep(u.flashParams.y, u.flashParams.x, spot);
        float atten = clamp(1.0 - dist / u.flashParams.z, 0.0, 1.0);
        atten *= atten;
        float ndl = max(dot(N, L), 0.0);
        light += u.flash.rgb * (u.flash.w * ndl * cone * atten);
        if (specStrength > 0.001 && ndl > 0.0) {
            float3 H = normalize(L + V);
            specular += u.flash.rgb * (u.flash.w * cone * atten * specStrength
                                       * pow(max(dot(N, H), 0.0), shininess));
        }
    }

    float ao = contactAO(in.worldPos.y, u.fogColor.w);
    float3 color = (base * light + specular) * ao;

    // FogExp2, matching the web scene's falloff.
    float d = length(u.cameraPos.xyz - in.worldPos);
    float fd = u.hemiGround.w * d;
    color = mix(color, u.fogColor.rgb, clamp(1.0 - exp(-fd * fd), 0.0, 1.0));

    color *= u.flashParams.w;

    // Two exits. Rendering into the HDR target, the picture leaves here in
    // linear light and unclamped — the composite pass tone-maps it, and the
    // range above 1.0 is precisely what bloom and the volumetrics need to see.
    // Drawing straight to an 8-bit drawable (no tape pass, so no composite),
    // there is nobody downstream to do it, so the curve is applied here as it
    // always was.
    if (u.misc.y > 0.5) {
        return float4(acesFilm(color), 1.0);
    }
    return float4(max(color, 0.0), 1.0);
}

/* =========================================================
   THE TAPE

   Port of the web build's VHS composite pass. See the GLSL for the reasoning;
   the short version is that VHS is defined by bandwidth, not breakage. Luma
   gets ~3MHz (about 240 lines across the picture), chroma is squeezed into a
   colour-under carrier below 700kHz (about 40 lines), so colour smears roughly
   eight times wider than brightness and lags it slightly to the right. That
   asymmetry is the signature; the rest is transport artifacts.

   Deliberately absent: per-pixel scanline stripes, barrel distortion, RGB
   channel splitting, roaming tears, datamosh. Those are digital or optical,
   and they are what makes fake VHS look fake.

   The GLSL works in y-up UVs. Metal textures are y-down, so all the maths
   below stays y-up and only the sample call flips.  */

struct VHSUniforms {
    float4 timeIntensity;   // time, intensity, glitch, dead
    float4 signal;          // ir, lowbatt, heat, dropout
    float4 frame;           // aspect43, saturation, resX, resY
};

struct PostOut {
    float4 position [[position]];
    float2 uv;              // y-up
};

vertex PostOut vhs_vertex(uint vid [[vertex_id]]) {
    // One oversized triangle; cheaper than a quad and no vertex buffer.
    const float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    PostOut out;
    out.position = float4(corners[vid], 0.0, 1.0);
    out.uv = corners[vid] * 0.5 + 0.5;
    return out;
}

static inline float vhsHash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static inline float vhsNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = vhsHash(i), b = vhsHash(i + float2(1.0, 0.0));
    float c = vhsHash(i + float2(0.0, 1.0)), d = vhsHash(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

static inline float vhsLuma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

fragment float4 vhs_fragment(PostOut in [[stage_in]],
                             constant VHSUniforms &u [[buffer(0)]],
                             texture2d<float> scene [[texture(0)]],
                             sampler samp [[sampler(0)]]) {
    float time = u.timeIntensity.x;
    float V = clamp(u.timeIntensity.y, 0.0, 1.0);
    float glitch = u.timeIntensity.z;
    float dead = u.timeIntensity.w;
    float ir = u.signal.x, lowbatt = u.signal.y, heat = u.signal.z, dropout = u.signal.w;
    float aspect43 = u.frame.x, sat = u.frame.y;
    float2 res = float2(u.frame.z, u.frame.w);

    float tt = fmod(time, 600.0);
    float G = glitch + dead * 1.8;
    float px = 1.0 / max(res.x, 1.0);
    const float LINES = 486.0;                 // NTSC active lines
    float field = floor(tt * 59.94);

    // 4:3 pillarbox — framing, not an artifact.
    float2 sUv = in.uv;
    float scrAsp = res.x / max(1.0, res.y);
    float winW = mix(1.0, min(1.0, (4.0 / 3.0) / scrAsp), aspect43);
    float x0 = (1.0 - winW) * 0.5;
    float inWin = step(x0, sUv.x) * step(sUv.x, 1.0 - x0);
    sUv.x = (sUv.x - x0) / winW;
    float line = floor(sUv.y * LINES);

    // Time-base error. The slow term is correlated down the frame, which bows
    // long verticals gently; the fast term is per-line and stays sub-pixel.
    // Anything larger than this stops reading as tape and starts reading as
    // damage.
    float tbeSlow = vhsNoise(float2(line * 0.030, tt * 0.5)) - 0.5;
    float tbeFast = vhsHash(float2(line, field)) - 0.5;
    float tbe = (tbeSlow * 1.7 + tbeFast * 0.45) * (0.5 + 1.5 * V) * px;

    // Mistracking: a soft band drifting in and out, worth a couple of pixels.
    float bandY = fract(tt * 0.07 + 0.42);
    float band = smoothstep(0.10, 0.0, abs(sUv.y - bandY));
    float bandGate = smoothstep(0.70, 0.88, vhsNoise(float2(tt * 0.28, 4.0)));
    tbe += band * bandGate * (vhsNoise(float2(line * 0.5, tt * 9.0)) - 0.5) * 3.0 * px * (0.4 + V);

    // Head switching: the last lines before vertical blanking come off the
    // other head mid-rotation and never line up. Always present, always the
    // bottom, only a few lines tall.
    float hsw = smoothstep(11.0 / LINES, 0.0, sUv.y);
    float hswSkew = hsw * hsw * (0.55 + 0.45 * vhsNoise(float2(tt * 2.2, 9.0)));

    float2 uv = sUv;
    uv.x += tbe + sin(sUv.y * 70.0 + tt * 9.0) * 0.0016 * heat + hswSkew * 0.075
          + dead * (vhsNoise(float2(line * 0.2, tt * 14.0)) - 0.5) * 0.12;
    uv.y += sin(sUv.x * 50.0 - tt * 7.0) * 0.0010 * heat;

    // Sampling helper: flip to Metal's y-down texture space.
    #define TAP(c) scene.sample(samp, float2((c).x, 1.0 - (c).y)).rgb

    // LUMA: soft aperture, then the edge overshoot every consumer deck added
    // on playback — which is why tape looks soft and crunchy at once.
    float lw = (0.9 + 1.3 * V) * px;
    float Y = vhsLuma(TAP(uv)) * 0.44
            + vhsLuma(TAP(uv - float2(lw, 0.0))) * 0.28
            + vhsLuma(TAP(uv + float2(lw, 0.0))) * 0.28;
    float Yl = vhsLuma(TAP(uv - float2(lw * 3.0, 0.0)));
    float Yr = vhsLuma(TAP(uv + float2(lw * 3.0, 0.0)));
    Y += (Y - (Yl + Yr) * 0.5) * (0.30 + 0.55 * V);

    // CHROMA: colour-under bandwidth, delayed right. This wide tap is why a
    // red sign on tape bleeds a finger's width past its own edges.
    float cw = (4.0 + 14.0 * V) * px;
    float cd = (1.0 + 3.0 * V) * px;
    float2 cuv = uv - float2(cd, 0.0);
    float3 ca = TAP(cuv) * 0.24;
    ca += (TAP(cuv - float2(cw, 0.0)) + TAP(cuv + float2(cw, 0.0))) * 0.19;
    ca += (TAP(cuv - float2(cw * 2.0, 0.0)) + TAP(cuv + float2(cw * 2.0, 0.0))) * 0.115;
    ca += (TAP(cuv - float2(cw * 3.0, 0.0)) + TAP(cuv + float2(cw * 3.0, 0.0))) * 0.055;
    // Colour is averaged across adjacent lines too, just far less than sideways.
    float invH = 1.0 / max(res.y, 1.0);
    ca = mix(ca, (ca + TAP(cuv + float2(0.0, invH)) + TAP(cuv - float2(0.0, invH))) / 3.0, 0.55);

    float I = dot(ca, float3(0.596, -0.274, -0.322));
    float Q = dot(ca, float3(0.211, -0.523, 0.312));
    // Chroma noise is blotchy and slow — nothing like luma grain.
    float cn = vhsNoise(float2(uv.x * res.x * 0.05, uv.y * res.y * 0.10 + tt * 2.5)) - 0.5;
    I += cn * 0.055 * V;
    Q += cn * 0.045 * V;
    I *= sat;
    Q *= sat;

    float3 col = float3(Y + 0.956 * I + 0.621 * Q,
                        Y - 0.272 * I - 0.647 * Q,
                        Y - 1.106 * I + 1.703 * Q);

    // Composite levels: a 7.5 IRE pedestal lifts black off zero and the record
    // amplifier rolls highlights off. Tape gives you neither true black nor a
    // hard clip.
    col = col * (1.0 - 0.085 * V) + 0.020 * V;
    col = col / (1.0 + max(float3(0.0), col - 0.82) * 1.7);

    // Halation. The web build runs a separate bright-pass and blur; here a few
    // wide taps off the same texture buy most of the glow for one pass.
    float3 glow = float3(0.0);
    for (int i = 0; i < 6; ++i) {
        float a = 1.0472 * float(i);           // six directions, 60 degrees apart
        float2 o = float2(cos(a), sin(a)) * float2(px, invH) * 9.0;
        float3 s = TAP(uv + o);
        glow += max(float3(0.0), s - 0.62);
    }
    col += glow * (0.10 + 0.06 * V);

    // Warm tape cast and the desaturation of a fourth-generation dub.
    col *= mix(float3(1.0), float3(1.035, 1.0, 0.945), V);
    float lum = vhsLuma(col);
    col = mix(col, float3(lum), 0.10 * V);
    // AGC pumping: brightness breathes very slightly, about once a second.
    col *= 1.0 - V * 0.015 * (vhsNoise(float2(tt * 1.6, 3.0)) - 0.5);

    // Tape noise is a one-dimensional signal read along each line, so it
    // streaks horizontally. Per-pixel white noise is the tell of a filter
    // applied to an image rather than modelled on a signal.
    float ng = vhsHash(float2(floor(uv.x * res.x * 0.30), line + field * 7.0));
    float nf = vhsHash(float2(floor(uv.x * res.x), line * 3.0 + field * 11.0));
    float grain = (ng - 0.5) * 0.72 + (nf - 0.5) * 0.28;
    col += grain * (0.010 + 0.028 * V + ir * 0.045 + G * 0.05 + lowbatt * 0.030);

    // Dropouts: a shed oxide particle takes out one line for a few frames.
    // Rare, short, never rhythmic.
    float dLine = step(0.9990 - dropout * 0.020 - G * 0.004,
                       vhsHash(float2(line, floor(tt * 7.0))));
    float dSeg = step(0.78, vhsHash(float2(floor(uv.x * 26.0), line + floor(tt * 7.0))));
    col += dLine * dSeg * (0.30 + 0.30 * dropout);

    // The head-switch band is mostly torn noise, not picture.
    col = mix(col, float3(vhsHash(float2(uv.x * res.x * 0.6, line + field)) * 0.55 + 0.12),
              hsw * 0.92);

    // IR nightshot.
    col = mix(col, float3(0.20, 1.0, 0.28) * (lum * 1.7 + 0.05), ir);

    // A camcorder lens does fall off at the corners — gently.
    float2 cc = sUv - 0.5;
    col *= mix(1.0, smoothstep(1.20, 0.30, dot(cc, cc)), 0.22);

    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) col = float3(0.0);
    col *= (1.0 - dead * 0.25) * inWin;

    #undef TAP
    return float4(clamp(col, 0.0, 1.0), 1.0);
}

/* =========================================================
   HDR COMPOSITE — bright pass, separable blur, tone-map

   The scene now lands in an `rgba16Float` target in linear light, so values
   above 1.0 survive instead of clipping to white. That is the whole point:
   a fluorescent tube reading 4.0 blooms, and the same tube clamped to 1.0 is
   indistinguishable from a sheet of paper.

   Bloom runs at quarter resolution. At full res it is four times the cost for
   a result that is then deliberately blurred, and the tape pass grains over
   the difference anyway.
   ========================================================= */

/* x = threshold, y = intensity, z = texel width, w = texel height. */

fragment float4 bloom_bright_fragment(PostOut in [[stage_in]],
                                      constant float4 &p [[buffer(0)]],
                                      texture2d<float> src [[texture(0)]],
                                      sampler samp [[sampler(0)]]) {
    float3 c = src.sample(samp, in.uv).rgb;
    // Soft knee rather than a hard cut: a hard threshold makes the bloom
    // boundary crawl as the camera moves and anything hovering at the
    // threshold flickers on and off between frames.
    float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
    float knee = max(p.x * 0.5, 1e-4);
    float contribution = clamp((luma - p.x + knee) / (2.0 * knee), 0.0, 1.0);
    contribution *= contribution;
    return float4(c * contribution, 1.0);
}

fragment float4 bloom_blur_fragment(PostOut in [[stage_in]],
                                    constant float4 &p [[buffer(0)]],
                                    texture2d<float> src [[texture(0)]],
                                    sampler samp [[sampler(0)]]) {
    // Nine-tap Gaussian, separable — p.zw carries the axis this pass walks,
    // so one shader serves both the horizontal and the vertical half.
    const float weight[5] = { 0.2270270270, 0.1945945946, 0.1216216216,
                              0.0540540541, 0.0162162162 };
    float2 step = p.zw;
    float3 sum = src.sample(samp, in.uv).rgb * weight[0];
    for (int i = 1; i < 5; ++i) {
        float2 offset = step * float(i);
        sum += src.sample(samp, in.uv + offset).rgb * weight[i];
        sum += src.sample(samp, in.uv - offset).rgb * weight[i];
    }
    return float4(sum, 1.0);
}

/* x = bloom intensity, y = AO strength, z = volumetric intensity, w spare. */

fragment float4 composite_fragment(PostOut in [[stage_in]],
                                   constant float4 &p [[buffer(0)]],
                                   texture2d<float> sceneTex [[texture(0)]],
                                   texture2d<float> bloomTex [[texture(1)]],
                                   texture2d<float> aoTex [[texture(2)]],
                                   texture2d<float> volumeTex [[texture(3)]],
                                   sampler samp [[sampler(0)]]) {
    float3 color = sceneTex.sample(samp, in.uv).rgb;

    // Ambient occlusion multiplies before the tone-map, in linear light, which
    // is where occlusion physically belongs — applying it after the curve
    // crushes shadowed corners to mud instead of darkening them.
    float ao = aoTex.sample(samp, in.uv).r;
    ao = mix(1.0, ao, clamp(p.y, 0.0, 1.0));
    color *= ao;

    // Bloom and inscatter are both added after AO: they are light arriving at
    // the lens, not light leaving the surface, so occlusion has no business
    // dimming them. Both are sampled from half/quarter-res targets, and the
    // linear filter doing the upsample is also what softens them.
    color += bloomTex.sample(samp, in.uv).rgb * p.x;
    color += volumeTex.sample(samp, in.uv).rgb * p.z;

    return float4(acesFilm(color), 1.0);
}

/* =========================================================
   SCREEN SPACE — occlusion and volumetrics

   Both passes rebuild a world position from the depth buffer, so they share
   the same uniforms. Both run at half resolution and are sampled back with a
   linear filter, which is its own cheap blur — AO and god rays are both
   low-frequency, and the tape grain covers what the upsample softens.
   ========================================================= */

struct PostUniforms {
    float4x4 invViewProjection;
    float4x4 viewProjection;
    float4 params;
    float4 camera;
};

static inline float3 worldFromDepth(float2 uv, float depth, float4x4 invVP) {
    // Metal clip space: xy in [-1,1], z in [0,1]. `uv` is the y-up coordinate
    // the fullscreen triangle hands down, matching the tape pass.
    float4 ndc = float4(uv.x * 2.0 - 1.0, uv.y * 2.0 - 1.0, depth, 1.0);
    float4 world = invVP * ndc;
    return world.xyz / (abs(world.w) < 1e-6 ? 1e-6 : world.w);
}

static inline float postHash(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

/* Hemisphere SSAO. The normal comes from the derivatives of the reconstructed
   position rather than a G-buffer: this is a forward renderer with no normal
   target, and screen-space derivatives are exact enough for an effect that is
   then blurred by its own upsample. */
fragment float4 ssao_fragment(PostOut in [[stage_in]],
                              constant PostUniforms &u [[buffer(0)]],
                              depth2d<float> depthTex [[texture(0)]],
                              sampler samp [[sampler(0)]]) {
    float d = depthTex.sample(samp, in.uv);
    // Nothing was drawn here — the far plane is not occluded by anything.
    if (d >= 1.0) return float4(1.0, 1.0, 1.0, 1.0);

    float3 P = worldFromDepth(in.uv, d, u.invViewProjection);
    float3 N = normalize(cross(dfdx(P), dfdy(P)));

    float radius = max(u.params.x, 1e-3);
    float3 T = normalize(abs(N.y) < 0.9 ? cross(float3(0.0, 1.0, 0.0), N)
                                        : cross(float3(1.0, 0.0, 0.0), N));
    float3 B = cross(N, T);

    const int SAMPLES = 12;
    float angle = postHash(in.uv) * 6.2831853;
    float occlusion = 0.0;

    for (int i = 0; i < SAMPLES; ++i) {
        float t = (float(i) + 0.5) / float(SAMPLES);
        // Golden-angle spiral: even coverage without a noise texture, and the
        // per-pixel rotation turns the banding it would otherwise show into
        // dither that the upsample smooths out.
        float phi = 2.3999632 * float(i) + angle;
        float r = radius * sqrt(t);
        float3 samplePos = P + (T * cos(phi) + B * sin(phi)) * r
                             + N * (radius * 0.35 * t);

        float4 clip = u.viewProjection * float4(samplePos, 1.0);
        if (clip.w <= 0.0) continue;
        float2 sUv = (clip.xy / clip.w) * 0.5 + 0.5;
        if (sUv.x < 0.0 || sUv.x > 1.0 || sUv.y < 0.0 || sUv.y > 1.0) continue;

        float sampleDepth = depthTex.sample(samp, sUv);
        if (sampleDepth >= 1.0) continue;
        float3 occluder = worldFromDepth(sUv, sampleDepth, u.invViewProjection);

        float3 delta = occluder - P;
        float along = dot(delta, N);
        float dist = length(delta);
        // `along > bias` keeps a surface from occluding itself; the range check
        // stops a distant wall behind a doorway from darkening the doorway.
        if (along > 0.02 && dist < radius * 1.5) {
            occlusion += smoothstep(1.0, 0.0, dist / (radius * 1.5));
        }
    }

    float ao = 1.0 - (occlusion / float(SAMPLES)) * u.params.y;
    return float4(clamp(ao, 0.0, 1.0), 0.0, 0.0, 1.0);
}

/* Volumetric inscatter. Marches camera → surface accumulating light that
   reaches each step, which is what makes the air in a lit room visible and
   gives the camcorder lamp a beam instead of a pool on the far wall. */
fragment float4 volumetric_fragment(PostOut in [[stage_in]],
                                    constant PostUniforms &u [[buffer(0)]],
                                    constant SceneUniforms &s [[buffer(1)]],
                                    depth2d<float> depthTex [[texture(0)]],
                                    sampler samp [[sampler(0)]]) {
    float d = depthTex.sample(samp, in.uv);
    float3 P = worldFromDepth(in.uv, min(d, 0.99999), u.invViewProjection);
    float3 camera = u.camera.xyz;
    float3 ray = P - camera;
    float rayLength = length(ray);
    if (rayLength < 1e-3) return float4(0.0, 0.0, 0.0, 1.0);
    float3 dir = ray / rayLength;

    // Capped, because a corridor sightline can run the length of the floor and
    // the far half contributes almost nothing at this density.
    float marchLength = min(rayLength, u.params.z);
    const int STEPS = 16;
    float stepLength = marchLength / float(STEPS);
    // Jitter the start so the 16 steps do not band into visible shells.
    float jitter = postHash(in.uv * 3.7);

    float3 accum = float3(0.0);
    int lightCount = min(int(s.misc.x), 4);   // the four the ranker put first

    for (int i = 0; i < STEPS; ++i) {
        float3 sp = camera + dir * ((float(i) + jitter) * stepLength);

        if (s.flash.w > 0.0) {
            float3 toC = camera - sp;
            float dl = length(toC);
            float3 L = toC / max(dl, 1e-4);
            float spot = dot(-L, normalize(s.cameraForward.xyz));
            float cone = smoothstep(s.flashParams.y, s.flashParams.x, spot);
            float atten = clamp(1.0 - dl / s.flashParams.z, 0.0, 1.0);
            accum += s.flash.rgb * (s.flash.w * cone * atten * atten);
        }

        for (int j = 0; j < lightCount; ++j) {
            float3 toL = s.pointLights[j].positionRange.xyz - sp;
            float range = s.pointLights[j].positionRange.w;
            float dl = length(toL);
            if (dl > range) continue;
            float atten = clamp(1.0 - dl / range, 0.0, 1.0);
            accum += s.pointLights[j].colorIntensity.rgb
                   * (s.pointLights[j].colorIntensity.w * atten * atten);
        }
    }

    return float4(accum * stepLength * u.params.x, 1.0);
}
