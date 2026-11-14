//
//  EnvironmentProbeRegions.metal
//  AR-Lighting-Study
//

// Generates luminance and a multi-level Bright Region mask for every source pixel.
// This kernel is dispatched by EnvironmentProbeBrightRegionAnalyzer.
#include <metal_stdlib>
using namespace metal;

// per pixel pass
kernel void buildBrightRegionMask(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> maskTexture [[texture(1)]], // output textur -> masken werte
    texture2d<float, access::write> luminanceTexture [[texture(2)]], // output textur 2 -> luminanz werte
    constant float3 &thresholds [[buffer(0)]], // drei Luminanz-Perzentil-Schwellen
    uint2 gid [[thread_position_in_grid]]
) {
    // nur innerhalb der Textur
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) {
        return;
    }

    const float3 rgb = inputTexture.read(gid).rgb;
    const float luminance = dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
    
    float maskValue = 0.0f;
    if (luminance >= thresholds.z) {
        maskValue = 1.0f;
    } else if (luminance >= thresholds.y) {
        maskValue = 0.66f;
    } else if (luminance >= thresholds.x) {
        maskValue = 0.33f;
    }

    luminanceTexture.write(luminance, gid);
    maskTexture.write(maskValue, gid);
}
