//
//  EnvironmentProbeRegionMetricsReader.swift
//  AR-Lighting-Study
//

//  Measures luminance, color, and dominance values for each merged bright region.
//  These metrics provide the input for light selection and estimation.
import Foundation
import Metal
import simd

struct RegionLuminanceSample {
    let face: Int
    let x: Int
    let y: Int
    let luminance: Float
}

struct RegionLuminanceMetrics {
    let average: Float
    let total: Float
    let max: Float
    let luminanceSamples: [RegionLuminanceSample]
}

struct RegionColorMetrics {
    let average: SIMD3<Float>
    let luminanceWeightedAverage: SIMD3<Float>
    let brightestPixel: SIMD3<Float>
    let total: SIMD3<Float>
}

struct MeasuredBrightRegion {
    let index: Int
    let region: MergedBrightRegion
    let luminance: RegionLuminanceMetrics
    let color: RegionColorMetrics

    var pixelCount: Int {
        region.pixelCount
    }

    var faces: Set<Int> {
        region.faces
    }

    var dominanceScore: Float {
        luminance.total
    }

    var dominanceScore2: Float {
        luminance.average * sqrt(Float(pixelCount))
    }

    var dominanceScore3: Float {
        luminance.average
    }

    var sourceSizePixels: Float {
        Float(pixelCount)
    }

    var shadowSoftness: Float {
        min(max((sourceSizePixels - 1) / 7, 0), 1)
    }

    func dominanceScore(for mode: BrightRegionDominanceScoreMode) -> Float {
        switch mode {
        case .totalLuminance:
            dominanceScore
        case .balancedArea:
            dominanceScore2
        case .averageLuminance:
            dominanceScore3
        }
    }
}

struct EnvironmentProbeRegionMetricsReader {
    func measuredRegions(
        from regions: [MergedBrightRegion],
        luminanceTexture: any MTLTexture,
        colorTexture: any MTLTexture
    ) -> [MeasuredBrightRegion] {
        regions.enumerated().map { index, region in
            MeasuredBrightRegion(
                index: index,
                region: region,
                luminance: getRegionLuminance(
                    from: region,
                    luminanceTexture: luminanceTexture
                ),
                color: getRegionColor(
                    from: region,
                    luminanceTexture: luminanceTexture,
                    colorTexture: colorTexture
                )
            )
        }
    }

    func dominantRegion(
        from measuredRegions: [MeasuredBrightRegion],
        mode: BrightRegionDominanceScoreMode
    ) -> MeasuredBrightRegion? {
        measuredRegions.max { lhs, rhs in
            lhs.dominanceScore(for: mode) < rhs.dominanceScore(for: mode)
        }
    }

    func getRegionColor(
        from region: MergedBrightRegion,
        luminanceTexture: any MTLTexture,
        colorTexture: any MTLTexture
    ) -> RegionColorMetrics {
        var totalColor = SIMD3<Float>(repeating: 0)
        var averageColor = SIMD3<Float>(repeating: 0)
        var weightedTotalColor = SIMD3<Float>(repeating: 0)
        var brightestPixelColor = SIMD3<Float>(repeating: 0)
        var brightestPixelLuminance: Float = -.infinity
        var luminanceWeightSum: Float = 0
        var pixelCount = 0

        for part in region.parts {
            let face = part.face
            let pixels = part.pixels

            guard
                let faceTexture = colorTexture.makeTextureView(
                    pixelFormat: colorTexture.pixelFormat,
                    textureType: .type2D,
                    levels: 0..<1,
                    slices: face..<(face + 1)
                ),
                let facePixels = readRGBPixels(from: faceTexture),
                let luminanceFaceTexture = luminanceTexture.makeTextureView(
                    pixelFormat: luminanceTexture.pixelFormat,
                    textureType: .type2D,
                    levels: 0..<1,
                    slices: face..<(face + 1)
                ),
                let luminancePixels = readLuminancePixels(from: luminanceFaceTexture)
            else {
                continue
            }

            for pixel in pixels {
                let color = facePixels[pixel.y * faceTexture.width + pixel.x]
                let luminance = max(luminancePixels[pixel.y * luminanceFaceTexture.width + pixel.x], 0)
                totalColor += color
                weightedTotalColor += color * luminance
                luminanceWeightSum += luminance
                if luminance > brightestPixelLuminance {
                    brightestPixelLuminance = luminance
                    brightestPixelColor = color
                }
                pixelCount += 1
            }
        }

        guard pixelCount > 0 else {
            return RegionColorMetrics(
                average: averageColor,
                luminanceWeightedAverage: averageColor,
                brightestPixel: averageColor,
                total: totalColor
            )
        }

        averageColor = totalColor / Float(pixelCount)
        let luminanceWeightedAverage = luminanceWeightSum > 0
            ? weightedTotalColor / luminanceWeightSum
            : averageColor
        return RegionColorMetrics(
            average: averageColor,
            luminanceWeightedAverage: luminanceWeightedAverage,
            brightestPixel: brightestPixelColor,
            total: totalColor
        )
    }

    func getRegionLuminance(
        from region: MergedBrightRegion,
        luminanceTexture: any MTLTexture
    ) -> RegionLuminanceMetrics {
        var totalLuminance: Float = 0
        var maxLuminance: Float = 0
        var pixelCount = 0
        var luminanceSamples: [RegionLuminanceSample] = []

        for part in region.parts {
            let face = part.face
            let pixels = part.pixels

            guard
                let faceTexture = luminanceTexture.makeTextureView(
                    pixelFormat: luminanceTexture.pixelFormat,
                    textureType: .type2D,
                    levels: 0..<1,
                    slices: face..<(face + 1)
                )
            else {
                continue
            }

            for pixel in pixels {
                var pixelLuminance: Float = 0

                withUnsafeMutableBytes(of: &pixelLuminance) { buffer in
                    faceTexture.getBytes(
                        buffer.baseAddress!,
                        bytesPerRow: MemoryLayout<Float>.stride,
                        from: MTLRegionMake2D(pixel.x, pixel.y, 1, 1),
                        mipmapLevel: 0
                    )
                }

                totalLuminance += pixelLuminance
                maxLuminance = max(maxLuminance, pixelLuminance)
                pixelCount += 1
                luminanceSamples.append(RegionLuminanceSample(face: face, x: pixel.x, y: pixel.y, luminance: pixelLuminance))
            }
        }

        guard pixelCount > 0 else {
            return RegionLuminanceMetrics(average: 0, total: 0, max: 0, luminanceSamples: luminanceSamples)
        }

        let averageLuminance = totalLuminance / Float(pixelCount)
        return RegionLuminanceMetrics(
            average: averageLuminance,
            total: totalLuminance,
            max: maxLuminance,
            luminanceSamples: luminanceSamples
        )
    }

    private func readRGBPixels(from texture: any MTLTexture) -> [SIMD3<Float>]? {
        let width = texture.width
        let height = texture.height
        let pixelCount = width * height

        switch texture.pixelFormat {
        case .rgba16Float:
            var values = [Float16](repeating: 0, count: pixelCount * 4)
            values.withUnsafeMutableBytes { buffer in
                texture.getBytes(
                    buffer.baseAddress!,
                    bytesPerRow: width * MemoryLayout<Float16>.stride * 4,
                    from: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0
                )
            }

            var pixels: [SIMD3<Float>] = []
            pixels.reserveCapacity(pixelCount)
            for index in stride(from: 0, to: values.count, by: 4) {
                pixels.append(SIMD3<Float>(
                    Float(values[index]),
                    Float(values[index + 1]),
                    Float(values[index + 2])
                ))
            }
            return pixels

        case .rgba32Float:
            var values = [Float](repeating: 0, count: pixelCount * 4)
            values.withUnsafeMutableBytes { buffer in
                texture.getBytes(
                    buffer.baseAddress!,
                    bytesPerRow: width * MemoryLayout<Float>.stride * 4,
                    from: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0
                )
            }

            var pixels: [SIMD3<Float>] = []
            pixels.reserveCapacity(pixelCount)
            for index in stride(from: 0, to: values.count, by: 4) {
                pixels.append(SIMD3<Float>(
                    values[index],
                    values[index + 1],
                    values[index + 2]
                ))
            }
            return pixels

        case .rgba8Unorm:
            var values = [UInt8](repeating: 0, count: pixelCount * 4)
            values.withUnsafeMutableBytes { buffer in
                texture.getBytes(
                    buffer.baseAddress!,
                    bytesPerRow: width * 4,
                    from: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0
                )
            }

            var pixels: [SIMD3<Float>] = []
            pixels.reserveCapacity(pixelCount)
            for index in stride(from: 0, to: values.count, by: 4) {
                pixels.append(SIMD3<Float>(
                    Float(values[index]) / 255.0,
                    Float(values[index + 1]) / 255.0,
                    Float(values[index + 2]) / 255.0
                ))
            }
            return pixels

        case .rgba8Unorm_srgb:
            var values = [UInt8](repeating: 0, count: pixelCount * 4)
            values.withUnsafeMutableBytes { buffer in
                texture.getBytes(
                    buffer.baseAddress!,
                    bytesPerRow: width * 4,
                    from: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0
                )
            }

            var pixels: [SIMD3<Float>] = []
            pixels.reserveCapacity(pixelCount)
            for index in stride(from: 0, to: values.count, by: 4) {
                pixels.append(SIMD3<Float>(
                    Self.srgbToLinear(Float(values[index]) / 255.0),
                    Self.srgbToLinear(Float(values[index + 1]) / 255.0),
                    Self.srgbToLinear(Float(values[index + 2]) / 255.0)
                ))
            }
            return pixels

        case .bgra8Unorm:
            var values = [UInt8](repeating: 0, count: pixelCount * 4)
            values.withUnsafeMutableBytes { buffer in
                texture.getBytes(
                    buffer.baseAddress!,
                    bytesPerRow: width * 4,
                    from: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0
                )
            }

            var pixels: [SIMD3<Float>] = []
            pixels.reserveCapacity(pixelCount)
            for index in stride(from: 0, to: values.count, by: 4) {
                pixels.append(SIMD3<Float>(
                    Float(values[index + 2]) / 255.0,
                    Float(values[index + 1]) / 255.0,
                    Float(values[index]) / 255.0
                ))
            }
            return pixels

        case .bgra8Unorm_srgb:
            var values = [UInt8](repeating: 0, count: pixelCount * 4)
            values.withUnsafeMutableBytes { buffer in
                texture.getBytes(
                    buffer.baseAddress!,
                    bytesPerRow: width * 4,
                    from: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0
                )
            }

            var pixels: [SIMD3<Float>] = []
            pixels.reserveCapacity(pixelCount)
            for index in stride(from: 0, to: values.count, by: 4) {
                pixels.append(SIMD3<Float>(
                    Self.srgbToLinear(Float(values[index + 2]) / 255.0),
                    Self.srgbToLinear(Float(values[index + 1]) / 255.0),
                    Self.srgbToLinear(Float(values[index]) / 255.0)
                ))
            }
            return pixels

        default:
            print("EnvironmentProbeRegionMetricsReader: Pixel-Format fuer readRGBPixels nicht unterstuetzt: \(texture.pixelFormat.rawValue)")
            return nil
        }
    }

    private static func srgbToLinear(_ value: Float) -> Float {
        if value <= 0.04045 {
            return value / 12.92
        }

        return powf((value + 0.055) / 1.055, 2.4)
    }

    private func readLuminancePixels(from texture: any MTLTexture) -> [Float]? {
        let width = texture.width
        let height = texture.height
        let pixelCount = width * height

        guard texture.pixelFormat == .r32Float else {
            print("EnvironmentProbeRegionMetricsReader: Pixel-Format fuer readLuminancePixels nicht unterstuetzt: \(texture.pixelFormat.rawValue)")
            return nil
        }

        var values = [Float](repeating: 0, count: pixelCount)
        values.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: width * MemoryLayout<Float>.stride,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }

        return values
    }
}
