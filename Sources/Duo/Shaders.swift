/// Metal Shading Language source, compiled at launch with
/// `MTLDevice.makeLibrary(source:options:)` so the app builds without the
/// offline Metal toolchain.
///
/// The desktop is treated as a flat panel hinged along the bottom edge of the
/// screen, tilting away from a viewer who stays put — so it settles downward as
/// the lid comes down, leaving black above it. Frosting and dimming grow with
/// the gap between the panel and the screen, after the frosted-glass model of
/// elijah-semyonov/DuoLikeAnimation (MIT).
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 size;        // desktop and screen, in pixels
        float eye;          // eye to the screen plane, pixels
        float tilt;         // radians the panel has tilted away from the viewer
        float blurSpread;   // blur radius per pixel of panel-to-screen gap
        float darkening;    // light lost per pixel of blur radius
        float corner;       // radius of the panel's rounded top corners, pixels
        float maxLod;
    };

    struct VOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VOut foldVertex(uint vid [[vertex_id]])
    {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    static float grain(float2 p)
    {
        return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
    }

    /// Signed distance off the panel, measured in panel coordinates: x across it,
    /// y up from the hinge. Negative inside. The top corners are rounded like the
    /// display's own; the hinge edge stays square, as the panel does.
    static float panelEdge(float2 panel, float2 size, float r)
    {
        float2 q = float2(min(panel.x, size.x - panel.x), size.y - panel.y);
        float2 k = float2(r) - q;
        return length(max(k, 0.0)) + min(max(k.x, k.y), 0.0) - r;
    }

    fragment float4 foldFragment(VOut in [[stage_in]],
                                 texture2d<float> desktop [[texture(0)]],
                                 constant Uniforms &U [[buffer(0)]])
    {
        constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_zero);
        const float4 black = float4(0.0, 0.0, 0.0, 1.0);

        float2 p = in.uv * U.size;
        float3 eye = float3(U.size * 0.5, U.eye);
        float st = sin(U.tilt);
        float ct = cos(U.tilt);

        // Ray from the eye through this pixel of the screen, carried on until it
        // meets the panel: the plane hinged at y = size.y, z = 0 and tilted back.
        float denom = st * (p.y - eye.y) + ct * U.eye;
        if (denom <= 1e-4) return black;
        float t = (st * (U.size.y - eye.y) + ct * U.eye) / denom;
        if (t <= 0.0) return black;

        float2 xy = eye.xy + (p - eye.xy) * t;
        float gap = U.eye * (t - 1.0);                  // how far behind the screen it landed
        float s = ct > 1e-3 ? (U.size.y - xy.y) / ct : gap / max(st, 1e-3);
        float2 panel = float2(xy.x, s);                 // across the panel, and up from the hinge
        float2 uv = float2(panel.x, U.size.y - panel.y) / U.size;

        float dist = panelEdge(panel, U.size, U.corner);
        float mask = saturate(0.5 - dist / max(fwidth(dist), 1e-3));
        if (mask <= 0.0) return black;

        // Frosted glass: the farther the panel has fallen from the screen, the
        // wider it scatters and the more light it swallows.
        float radius = U.blurSpread * gap;
        float attenuation = max(1.0 - U.darkening * radius, 0.0);

        // Far end of the panel is minified as well; keep it off the texel grid.
        float2 texels = fwidth(uv) * U.size;
        float minLod = clamp(log2(max(max(texels.x, texels.y), 1.0)), 0.0, U.maxLod);

        if (radius < 0.5) {
            float3 c = desktop.sample(smp, uv, level(minLod)).rgb;
            return float4(c * attenuation * mask, 1.0);
        }

        // Vogel disk across the panel, rotated per pixel so banding turns into
        // frost grain. Each tap reads a mip level matched to the tap spacing,
        // which keeps a wide kernel smooth on a laptop-sized panel.
        int taps = clamp(int(radius), 6, 16);
        float lod = clamp(max(log2(radius / sqrt(float(taps))), minLod), 0.0, U.maxLod);
        float rotation = grain(p) * 6.28318530718;
        float3 sum = float3(0.0);
        for (int i = 0; i < taps; ++i) {
            float r = radius * sqrt((float(i) + 0.5) / float(taps));
            float a = float(i) * 2.39996322973 + rotation;
            float2 at = panel + r * float2(cos(a), sin(a));
            float2 tuv = float2(at.x, U.size.y - at.y) / U.size;
            sum += desktop.sample(smp, tuv, level(lod)).rgb * saturate(0.5 - panelEdge(at, U.size, U.corner));
        }
        return float4(sum / float(taps) * attenuation, 1.0);
    }
    """
}
