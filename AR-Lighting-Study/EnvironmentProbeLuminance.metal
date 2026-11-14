// Computes partial luminance sums for one Cubemap face and reads a reference pixel.
// These kernels back EnvironmentProbeLuminanceAnalyzer's GPU work.
#include <metal_stdlib>
using namespace metal;

kernel void reduceFaceLuminance(
    texture2d<float, access::read> faceTexture [[texture(0)]], // FaceTexture als Eingabe, 2D textur, Werte als float, nur lesezugriff, TextureSlot 0
    device float *partialSums [[buffer(0)]], // Zeiger auf den Buffer
    uint2 gid [[thread_position_in_grid]], // Pixelpunkt pro GPU-Thread im Gesamtgitter
    uint2 tid [[thread_position_in_threadgroup]], // lokale Position in der 8x8 Threadgruppe
    uint2 groupID [[threadgroup_position_in_grid]], // Blockkordinate, nicht Pixelkoordinate
    uint linearIndex [[thread_index_in_threadgroup]] // Index eines Threads innerhalb der 8x8 Gruppe
) {
    threadgroup float localSums[64]; // gemeinsamer Speicher für alle Threadgroups

    float luminance = 0.0f;
    
    //Nur innerhalb vom Bild lesen, auch wenn außen noch Threads laufen
    if (gid.x < faceTexture.get_width() && gid.y < faceTexture.get_height()) {
        const float3 rgb = faceTexture.read(gid).rgb; // jeden pixel lesen
        luminance = dot(rgb, float3(0.2126f, 0.7152f, 0.0722f)); // bekannte Luminanzformel durch Skalarprodukt
    }
    
    // Wert in den gemeinsamen Gruppenspeicher
    localSums[linearIndex] = luminance;
    // Synchronisation: Warten bis alle Threads der Gruppe ihre local summe reingeschrieben haben
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Reduction: immer einen Wert mit einem von der anderen Hälfte addieren. Das wiederholen bis alles 1 ist
    // stride startet bei 32 und halbiert sich dann
    for (uint stride = 32; stride > 0; stride >>= 1) {
        // imer nur ein teil der Threads arbeitet mit
        if (linearIndex < stride) {
            localSums[linearIndex] += localSums[linearIndex + stride];
        }
        // warten
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    
    // Nur ein Thread schreibt das Ergebnis
    if (linearIndex == 0) {
        // Wieviele Threadgruppen pro Zeile (7 für aufrunden)
        const uint groupsPerRow = (faceTexture.get_width() + 7) / 8;
        // 2D Block zu linearen Array
        const uint partialIndex = groupID.y * groupsPerRow + groupID.x;
        // Summe in den AusgabeBuffer schreiben
        partialSums[partialIndex] = localSums[0];
    }
}

kernel void readSinglePixelRGBA(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    device float4 *outputColor [[buffer(0)]]
) {
    outputColor[0] = inputTexture.read(uint2(0, 0));
}
