//
//  EnvironmentProbeLightEstimator.swift
//  AR-Lighting-Study
//
//  Converts measured bright regions into world-space light direction, position, color, and intensity.
//  It is a pure estimation component used by the probe analysis pipeline.

import Foundation
import simd

struct EstimatedEnvironmentLight {
    let sourceRegion: MeasuredBrightRegion
    let direction: SIMD3<Float>
    let position: SIMD3<Float>
    let color: SIMD3<Float>
    let intensity: Float
}

struct EnvironmentProbeLightEstimator {
    func estimateLight(
        from region: MeasuredBrightRegion,
        probeTransform: simd_float4x4,
        faceSize: Int,
        sourcePosition: SIMD3<Float>,
        distance: Float,
        directionMode: BrightRegionDirectionMode,
        colorMode: BrightRegionColorMode,
        whiteMix: Float
    ) -> EstimatedEnvironmentLight? {
        guard
            let worldDirection = estimateWorldDirection(
                for: region,
                probeTransform: probeTransform,
                faceSize: faceSize,
                directionMode: directionMode
            )
        else { return nil }
        let lightPosition = sourcePosition + worldDirection * distance
        
        return EstimatedEnvironmentLight(
            sourceRegion: region,
            direction: worldDirection,
            position: lightPosition,
            color: estimatedLightColor(from: measuredColor(for: region, mode: colorMode), whiteMix: whiteMix),
            intensity: region.luminance.total
        )
    }

    func estimateWorldDirection(
        for region: MeasuredBrightRegion,
        probeTransform: simd_float4x4,
        faceSize: Int,
        directionMode: BrightRegionDirectionMode
    ) -> SIMD3<Float>? {
        guard
            let localLightDirection = localLightDirection(
                for: region,
                faceSize: faceSize,
                mode: directionMode
            )
        else { return nil }

        return worldDirection(from: localLightDirection, probeTransform: probeTransform)
    }

    func estimateWorldDirection(
        for sample: RegionLuminanceSample,
        probeTransform: simd_float4x4,
        faceSize: Int
    ) -> SIMD3<Float> {
        let localDirection = cubemapDirection(
            face: sample.face,
            x: sample.x,
            y: sample.y,
            faceSize: faceSize
        )

        return worldDirection(from: localDirection, probeTransform: probeTransform)
    }

    private func localLightDirection(
        for region: MeasuredBrightRegion,
        faceSize: Int,
        mode: BrightRegionDirectionMode
    ) -> SIMD3<Float>? {
        switch mode {
        case .unweighted:
            averageDirection(for: region, faceSize: faceSize)
        case .luminanceWeighted:
            weightedAverageDirection(for: region, faceSize: faceSize)
        }
    }
    
    private func cubemapDirection(
        face: Int,
        x: Int,
        y: Int,
        faceSize: Int
    ) -> SIMD3<Float>
    {
        var direction: SIMD3<Float> = .zero
        
        // x und y auf u und v mappen. u und v gehen jeweils von -1 bis 1
        let u = (Float(x) + 0.5) / Float(faceSize) * 2 - 1
        let v = (Float(y) + 0.5) / Float(faceSize) * 2 - 1
        
        switch CubeFace(rawValue: face) {
            case .positiveX:
                direction = SIMD3<Float>(1, -v, -u)
            case .negativeX:
                direction = SIMD3<Float>(-1, -v, u)
            case .positiveY:
                direction = SIMD3<Float>(u, 1, v)
            case .negativeY:
                direction = SIMD3<Float>(u, -1, -v)
            case .positiveZ:
                direction = SIMD3<Float>(u, -v, 1)
            case .negativeZ:
                direction = SIMD3<Float>(-u, -v, -1)
            case nil:
                return .zero
        }
        
        return simd_normalize(probeLocalDirection(fromCubemapDirection: direction))

    }

    // Metal's cube face labels describe cube-space directions. The probe debug view
    // treats +Z as the forward face, while RealityKit's scene forward is -Z.
    private func probeLocalDirection(
        fromCubemapDirection direction: SIMD3<Float>
    ) -> SIMD3<Float> {
        SIMD3<Float>(direction.x, direction.y, -direction.z)
    }

    // Gewichtet nach Luminanz
    private func weightedAverageDirection(
        for region: MeasuredBrightRegion,
        faceSize: Int
    ) -> SIMD3<Float>?
    {
        var directionSum: SIMD3<Float> = .zero
        var weightSum: Float = 0

        for sample in region.luminance.luminanceSamples {
            let direction = cubemapDirection(
                face: sample.face,
                x: sample.x,
                y: sample.y,
                faceSize: faceSize
            )

            let weight = max(sample.luminance, 0)
            directionSum += direction * weight
            weightSum += weight
        }

        guard weightSum > 0 else {
            return nil
        }

        return simd_normalize(directionSum / weightSum)
    }
    
    // Baseline
    private func averageDirection(
        for region: MeasuredBrightRegion,
        faceSize: Int
    ) -> SIMD3<Float>?
    {
        var directionSum : SIMD3<Float> = .zero
        var pixelCount : Int = 0
        
        for part in region.region.parts {
            
            for pixel in part.pixels {
                let direction = self.cubemapDirection(face: part.face, x: pixel.x, y: pixel.y, faceSize: faceSize)
                directionSum += direction
                pixelCount += 1
            }
        }
        
        guard pixelCount > 0 else {
            return nil
        }

        return simd_normalize(directionSum)
    }
    
    private func worldDirection(
        from localDirection: SIMD3<Float>,
        probeTransform: simd_float4x4
    ) -> SIMD3<Float> {
        
        // als richtungsvektor
        let localDirection4 = SIMD4<Float>(
            localDirection.x,
            localDirection.y,
            localDirection.z,
            0
        )

        let worldDirection4 = probeTransform * localDirection4

        return simd_normalize(SIMD3<Float>(
            worldDirection4.x,
            worldDirection4.y,
            worldDirection4.z
        ))
    }
    
    private func estimatedLightColor(
        from measuredColor: SIMD3<Float>,
        whiteMix: Float
    ) -> SIMD3<Float> {
        let clampedMeasuredColor = SIMD3<Float>(
            max(measuredColor.x, 0),
            max(measuredColor.y, 0),
            max(measuredColor.z, 0)
        )
        let maxChannel = max(
            clampedMeasuredColor.x,
            clampedMeasuredColor.y,
            clampedMeasuredColor.z,
            0.0001
        )
        let normalizedColor = clampedMeasuredColor / maxChannel
        let white = SIMD3<Float>(repeating: 1)
        let clampedWhiteMix = min(max(whiteMix, 0), 1)
        let linearMixedColor = normalizedColor * (1 - clampedWhiteMix) + white * clampedWhiteMix

        return linearToSRGB(linearMixedColor)
    }

    private func measuredColor(
        for region: MeasuredBrightRegion,
        mode: BrightRegionColorMode
    ) -> SIMD3<Float> {
        switch mode {
        case .average:
            region.color.average
        case .luminanceWeighted:
            region.color.luminanceWeightedAverage
        case .brightestPixel:
            region.color.brightestPixel
        }
    }

    private func linearToSRGB(_ color: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(
            linearToSRGB(color.x),
            linearToSRGB(color.y),
            linearToSRGB(color.z)
        )
    }

    private func linearToSRGB(_ value: Float) -> Float {
        let clampedValue = min(max(value, 0), 1)

        if clampedValue <= 0.0031308 {
            return clampedValue * 12.92
        }

        return 1.055 * pow(clampedValue, 1 / 2.4) - 0.055
    }

}
