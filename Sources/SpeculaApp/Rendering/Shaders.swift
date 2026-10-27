// Metal shader source, compiled at launch (SwiftPM does not build .metal files).
let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct RenderUniforms {
    float4x4 transform;      // quad pixel space -> NDC
    float4x4 planeToVolume;  // plane pixel (x, y, 0, 1) -> volume texture coordinate
    float4 slabStep;         // texture-space step along the plane normal
    float2 imageSize;
    float valueScale;
    float valueOffset;
    float slope;
    float intercept;
    float windowCenter;
    float windowWidth;
    int voiFunction;         // 0 linear, 1 linear exact, 2 sigmoid
    int invert;
    int isColor;
    int colorWindowing;
    int useColormap;
    int filter;
    int slabSamples;
    int slabMode;            // 0 single, 1 MIP, 2 MinIP, 3 average
    float opacity;
    int nearest;
    float colormapThreshold; // fusion: values below this window fraction are transparent
    int subtract;            // DSA: subtract mask texture
    float2 maskShift;        // DSA pixel shift (pixels)
    float maskScale;
    float maskOffset;
};

struct VertexOut {
    float4 position [[position]];
    float2 pixel;            // image pixel coordinates (edge based)
};

vertex VertexOut quadVertex(uint vid [[vertex_id]], constant RenderUniforms &u [[buffer(0)]]) {
    float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
    float2 p = corners[vid] * u.imageSize;
    VertexOut o;
    o.position = u.transform * float4(p, 0, 1);
    o.pixel = p;
    return o;
}

static float applyVOI(float mv, constant RenderUniforms &u) {
    float c = u.windowCenter, w = max(u.windowWidth, 1e-6);
    float y;
    if (u.voiFunction == 2) {
        y = 1.0 / (1.0 + exp(-4.0 * (mv - c) / w));
    } else if (u.voiFunction == 1) {
        y = (mv - c) / w + 0.5;
    } else {
        float w1 = max(w - 1.0, 1e-6);
        y = (mv - (c - 0.5)) / w1 + 0.5;
    }
    return clamp(y, 0.0, 1.0);
}

static float4 shade(float v, constant RenderUniforms &u, texture1d<float> colormap, sampler lin) {
    if (u.invert != 0) v = 1.0 - v;
    if (u.useColormap != 0) {
        float4 c = colormap.sample(lin, v);
        float a = u.opacity;
        if (u.colormapThreshold > 0 && v < u.colormapThreshold) a = 0;
        return float4(c.rgb, c.a * a);
    }
    return float4(v, v, v, u.opacity);
}

static float sampleStored(texture2d<float> tex, sampler s, float2 uv, constant RenderUniforms &u) {
    return tex.sample(s, uv).r * u.valueScale + u.valueOffset;
}

fragment float4 imageFragment(VertexOut in [[stage_in]],
                              constant RenderUniforms &u [[buffer(0)]],
                              texture2d<float> tex [[texture(0)]],
                              texture1d<float> colormap [[texture(1)]],
                              texture2d<float> mask [[texture(2)]]) {
    constexpr sampler lin(filter::linear, address::clamp_to_edge);
    constexpr sampler near(filter::nearest, address::clamp_to_edge);
    float2 uv = in.pixel / u.imageSize;
    if (uv.x < 0 || uv.y < 0 || uv.x > 1 || uv.y > 1) discard_fragment();
    float2 texel = 1.0 / u.imageSize;
    if (u.isColor != 0) {
        float4 c = u.nearest != 0 ? tex.sample(near, uv) : tex.sample(lin, uv);
        if (u.filter == 2 || u.filter == 3) {
            float k = u.filter == 2 ? 0.5 : 1.2;
            float4 nb = tex.sample(lin, uv + float2(texel.x, 0)) + tex.sample(lin, uv - float2(texel.x, 0)) +
                        tex.sample(lin, uv + float2(0, texel.y)) + tex.sample(lin, uv - float2(0, texel.y));
            c = c + k * (c - nb * 0.25);
        }
        float3 rgb = c.rgb;
        if (u.colorWindowing != 0) {
            float c0 = u.windowCenter / 255.0, w0 = max(u.windowWidth / 255.0, 1e-4);
            rgb = clamp((rgb - (c0 - 0.5 * w0)) / w0, 0.0, 1.0);
        }
        if (u.invert != 0) rgb = 1.0 - rgb;
        return float4(rgb, u.opacity);
    }
    float stored;
    if (u.filter == 0) {
        stored = u.nearest != 0 ? sampleStored(tex, near, uv, u) : sampleStored(tex, lin, uv, u);
    } else {
        sampler s = u.nearest != 0 ? near : lin;
        float c = sampleStored(tex, s, uv, u);
        float n = sampleStored(tex, s, uv + float2(0, -texel.y), u);
        float so = sampleStored(tex, s, uv + float2(0, texel.y), u);
        float e = sampleStored(tex, s, uv + float2(texel.x, 0), u);
        float w = sampleStored(tex, s, uv + float2(-texel.x, 0), u);
        float ne = sampleStored(tex, s, uv + float2(texel.x, -texel.y), u);
        float nw = sampleStored(tex, s, uv + float2(-texel.x, -texel.y), u);
        float se = sampleStored(tex, s, uv + float2(texel.x, texel.y), u);
        float sw = sampleStored(tex, s, uv + float2(-texel.x, texel.y), u);
        float blur = (4 * c + 2 * (n + so + e + w) + (ne + nw + se + sw)) / 16.0;
        if (u.filter == 1) stored = blur;                       // smooth
        else if (u.filter == 2) stored = c + 0.8 * (c - blur);  // sharpen
        else if (u.filter == 3) stored = c + 2.0 * (c - blur);  // sharpen strong
        else stored = c + 4.0 * (c - (n + so + e + w) * 0.25) * 0.25; // edge enhance
    }
    if (u.subtract != 0) {
        float2 muv = (in.pixel - u.maskShift) / u.imageSize;
        float m = mask.sample(lin, muv).r * u.maskScale + u.maskOffset;
        float mv = (stored - m) * u.slope;
        return shade(applyVOI(mv + u.windowCenter * 0.0, u), u, colormap, lin);
    }
    float mv = stored * u.slope + u.intercept;
    return shade(applyVOI(mv, u), u, colormap, lin);
}

fragment float4 mprFragment(VertexOut in [[stage_in]],
                            constant RenderUniforms &u [[buffer(0)]],
                            texture3d<float> vol [[texture(0)]],
                            texture1d<float> colormap [[texture(1)]]) {
    constexpr sampler lin(filter::linear, address::clamp_to_zero);
    constexpr sampler near(filter::nearest, address::clamp_to_zero);
    constexpr sampler clin(filter::linear, address::clamp_to_edge);
    float2 px = in.pixel - 0.5;
    float3 p = (u.planeToVolume * float4(px, 0, 1)).xyz;
    int n = max(u.slabSamples, 1);
    float3 start = p - u.slabStep.xyz * float(n - 1) * 0.5;
    float acc = u.slabMode == 2 ? 1e30 : (u.slabMode == 1 ? -1e30 : 0);
    int inside = 0;
    for (int i = 0; i < n; i++) {
        float3 q = start + u.slabStep.xyz * float(i);
        if (any(q < 0.0) || any(q > 1.0)) continue;
        inside++;
        float v = (u.nearest != 0 ? vol.sample(near, q).r : vol.sample(lin, q).r) * u.valueScale + u.valueOffset;
        if (u.slabMode == 1) acc = max(acc, v);
        else if (u.slabMode == 2) acc = min(acc, v);
        else acc += v;
    }
    if (inside == 0) {
        if (u.useColormap != 0) discard_fragment();
        return float4(0, 0, 0, 1);
    }
    if (u.slabMode == 0 || u.slabMode == 3) acc /= float(inside);
    float mv = acc * u.slope + u.intercept;
    return shade(applyVOI(mv, u), u, colormap, clin);
}

// ---------------------------------------------------------------- Volume rendering

struct VRUniforms {
    float4x4 invViewProj;    // NDC -> object space (mm, volume centred at origin)
    float4x4 objectToTex;    // object mm -> texture coordinates
    float4 cameraPos;        // object space (for perspective) / view dir in w==0
    float4 lightDir;         // object space, normalised
    float4 extent;           // half extents in mm (xyz)
    float4 clipMin;          // texture space crop box
    float4 clipMax;
    float4 gradStep;         // texture-space central difference offsets
    float stepMM;
    float tfMin;
    float tfMax;
    int mode;                // 0 composite, 1 MIP, 2 MinIP
    float valueScale;
    float valueOffset;
    float slope;
    float intercept;
    float windowCenter;
    float windowWidth;
    int shading;
    float ambient;
    float diffuse;
    float specular;
    float shininess;
    int useMask;
    int invert;
    int orthographic;
    float opacityScale;
    float pad0;
};

struct VROut {
    float4 position [[position]];
    float2 ndc;
};

vertex VROut vrVertex(uint vid [[vertex_id]]) {
    float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    VROut o;
    o.position = float4(corners[vid], 0, 1);
    o.ndc = corners[vid];
    return o;
}

static bool intersectBox(float3 ro, float3 rd, float3 bmin, float3 bmax, thread float &t0, thread float &t1) {
    float3 inv = 1.0 / rd;
    float3 ta = (bmin - ro) * inv, tb = (bmax - ro) * inv;
    float3 tmin = min(ta, tb), tmax = max(ta, tb);
    t0 = max(max(tmin.x, tmin.y), tmin.z);
    t1 = min(min(tmax.x, tmax.y), tmax.z);
    return t1 > max(t0, 0.0);
}

fragment float4 vrFragment(VROut in [[stage_in]],
                           constant VRUniforms &u [[buffer(0)]],
                           texture3d<float> vol [[texture(0)]],
                           texture1d<float> tf [[texture(1)]],
                           texture3d<float> mask [[texture(2)]]) {
    constexpr sampler lin(filter::linear, address::clamp_to_edge);
    float4 nearP = u.invViewProj * float4(in.ndc, 0, 1);
    float4 farP = u.invViewProj * float4(in.ndc, 1, 1);
    float3 ro = nearP.xyz / nearP.w;
    float3 rf = farP.xyz / farP.w;
    float3 rd = normalize(rf - ro);
    // crop box in object space
    float3 bmin = (float4(u.clipMin.xyz, 1) * 1.0).xyz;
    float3 bmax = u.clipMax.xyz;
    // convert tex-space crop to object space using extent
    bmin = (bmin - 0.5) * 2.0 * u.extent.xyz;
    bmax = (bmax - 0.5) * 2.0 * u.extent.xyz;
    float t0, t1;
    if (!intersectBox(ro, rd, bmin, bmax, t0, t1)) return float4(0, 0, 0, 0);
    t0 = max(t0, 0.0);
    float range = max(u.tfMax - u.tfMin, 1e-3);
    float4 acc = float4(0);
    float extreme = u.mode == 2 ? 1e30 : -1e30;
    float step = u.stepMM;
    int maxSteps = int(min((t1 - t0) / step, 4000.0));
    // jitter start to hide wood-grain artefacts
    float jitter = fract(sin(dot(in.position.xy, float2(12.9898, 78.233))) * 43758.5453);
    float t = t0 + jitter * step;
    for (int i = 0; i < maxSteps; i++, t += step) {
        float3 p = ro + rd * t;
        float3 q = (u.objectToTex * float4(p, 1)).xyz;
        if (u.useMask != 0 && mask.sample(lin, q).r < 0.5) continue;
        float v = vol.sample(lin, q).r * u.valueScale + u.valueOffset;
        float hu = v * u.slope + u.intercept;
        if (u.mode != 0) {
            extreme = u.mode == 1 ? max(extreme, hu) : min(extreme, hu);
            continue;
        }
        float4 c = tf.sample(lin, (hu - u.tfMin) / range);
        if (c.a <= 0.002) continue;
        float a = 1.0 - pow(1.0 - clamp(c.a * u.opacityScale, 0.0, 0.999), step);
        float3 col = c.rgb;
        if (u.shading != 0) {
            float3 g;
            g.x = vol.sample(lin, q + float3(u.gradStep.x, 0, 0)).r - vol.sample(lin, q - float3(u.gradStep.x, 0, 0)).r;
            g.y = vol.sample(lin, q + float3(0, u.gradStep.y, 0)).r - vol.sample(lin, q - float3(0, u.gradStep.y, 0)).r;
            g.z = vol.sample(lin, q + float3(0, 0, u.gradStep.z)).r - vol.sample(lin, q - float3(0, 0, u.gradStep.z)).r;
            // gradient from texture space to object space directions (axis aligned scaling)
            g = g / max(u.gradStep.xyz, 1e-6);
            float gl = length(g);
            if (gl > 1e-4) {
                float3 nrm = -g / gl;
                // object-space normal: texture axes map to object axes via objectToTex (orthogonal)
                float3 n = normalize((transpose(u.objectToTex) * float4(nrm, 0)).xyz);
                float3 l = u.lightDir.xyz;
                float ndl = abs(dot(n, l));
                float3 h = normalize(l - rd);
                float spec = pow(abs(dot(n, h)), u.shininess);
                col = col * (u.ambient + u.diffuse * ndl) + u.specular * spec;
            } else {
                col = col * (u.ambient + u.diffuse * 0.5);
            }
        }
        acc.rgb += (1.0 - acc.a) * a * col;
        acc.a += (1.0 - acc.a) * a;
        if (acc.a > 0.985) break;
    }
    if (u.mode != 0) {
        if (extreme < -1e29 || extreme > 1e29) return float4(0, 0, 0, 0);
        float c = u.windowCenter, w = max(u.windowWidth, 1e-3);
        float y = clamp((extreme - (c - 0.5)) / (w - 1.0) + 0.5, 0.0, 1.0);
        if (u.invert != 0) y = 1.0 - y;
        return float4(y, y, y, 1);
    }
    return acc;
}

// Scalpel: clears mask voxels whose screen projection falls inside (or outside) a polygon.
struct CutUniforms {
    float4x4 texToClip;      // texture coordinate -> clip space
    uint3 dims;
    int pointCount;
    int inside;              // 1 = cut inside polygon, 0 = cut outside
};

kernel void scalpelKernel(texture3d<float, access::read_write> mask [[texture(0)]],
                          constant CutUniforms &u [[buffer(0)]],
                          constant float2 *poly [[buffer(1)]],
                          uint3 gid [[thread_position_in_grid]]) {
    if (any(gid >= u.dims)) return;
    float3 q = (float3(gid) + 0.5) / float3(u.dims);
    float4 c = u.texToClip * float4(q, 1);
    float2 p = c.xy / c.w;
    bool in = false;
    for (int i = 0, j = u.pointCount - 1; i < u.pointCount; j = i++) {
        float2 a = poly[i], b = poly[j];
        if (((a.y > p.y) != (b.y > p.y)) && (p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y + 1e-12) + a.x)) in = !in;
    }
    if (in == (u.inside != 0)) mask.write(float4(0), gid);
}
"""#
