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

fragment float4 level_fragment(VertexOut in [[stage_in]],
                               constant SceneUniforms &u [[buffer(1)]],
                               texture2d<float> albedo [[texture(0)]],
                               sampler samp [[sampler(0)]]) {
    float3 base = albedo.sample(samp, in.uv).rgb;
    float3 N = normalize(in.normal);

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
        light += u.pointLights[i].colorIntensity.rgb
               * (u.pointLights[i].colorIntensity.w * max(dot(N, L), 0.0) * atten);
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
        light += u.flash.rgb * (u.flash.w * max(dot(N, L), 0.0) * cone * atten);
    }

    float3 color = base * light * contactAO(in.worldPos.y, u.fogColor.w);

    // FogExp2, matching the web scene's falloff.
    float d = length(u.cameraPos.xyz - in.worldPos);
    float fd = u.hemiGround.w * d;
    color = mix(color, u.fogColor.rgb, clamp(1.0 - exp(-fd * fd), 0.0, 1.0));

    // Filmic curve, the same shape the web renderer tone-maps with.
    color *= u.flashParams.w;
    color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
    return float4(clamp(color, 0.0, 1.0), 1.0);
}
