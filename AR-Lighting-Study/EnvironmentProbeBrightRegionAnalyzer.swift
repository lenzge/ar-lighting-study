//
//  EnvironmentProbeBrightRegionAnalyzer.swift
//  AR-Lighting-Study
//
//  Runs a Metal compute pass that produces luminance and Bright Region mask textures.
//  The resulting textures are consumed by the CPU-side region analysis.

import Foundation
import Metal

@MainActor
final class EnvironmentProbeBrightRegionAnalyzer {
    struct BrightRegionTextures {
        let mask: any MTLTexture
        let luminance: any MTLTexture
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private let threadgroupSize = MTLSize(width: 8, height: 8, depth: 1)

    init?(device: MTLDevice) {
        let library = device.makeDefaultLibrary() ?? (try? device.makeDefaultLibrary(bundle: .main))

        guard
            let commandQueue = device.makeCommandQueue(),
            let library,
            let function = library.makeFunction(name: "buildBrightRegionMask"),
            let pipelineState = try? device.makeComputePipelineState(function: function)
        else {
            print("EnvironmentProbeBrightRegionAnalyzer init fehlgeschlagen. Default library oder Funktion buildBrightRegionMask fehlt.")
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.pipelineState = pipelineState
    }

    func makeMaskTexture(
        for texture: any MTLTexture,
        thresholds: SIMD3<Float>,
        progress: (@MainActor @Sendable (String) -> Void)? = nil
    ) async -> BrightRegionTextures? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = texture.textureType == .typeCube ? .type2DArray : texture.textureType
        descriptor.width = texture.width
        descriptor.height = texture.height
        descriptor.depth = 1
        descriptor.arrayLength = texture.textureType == .typeCube ? 6 : max(texture.arrayLength, 1)
        descriptor.mipmapLevelCount = 1
        descriptor.pixelFormat = .r32Float
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared

        guard
            let maskTexture = device.makeTexture(descriptor: descriptor),
            let luminanceTexture = device.makeTexture(descriptor: descriptor)
        else {
            print("EnvironmentProbeBrightRegionAnalyzer: maskTexture oder luminanceTexture konnte nicht erstellt werden.")
            return nil
        }

        let sliceCount = descriptor.arrayLength
        let groupsPerGrid = MTLSize(
            width: (texture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (texture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )

        for slice in 0..<sliceCount {
            await progress?("Masken-Shader laeuft: Face \(slice + 1)/\(sliceCount)")

            guard
                let inputFace = texture.makeTextureView(
                    pixelFormat: texture.pixelFormat,
                    textureType: .type2D,
                    levels: 0..<1,
                    slices: slice..<(slice + 1)
                ),
                let maskFace = maskTexture.makeTextureView(
                    pixelFormat: maskTexture.pixelFormat,
                    textureType: .type2D,
                    levels: 0..<1,
                    slices: slice..<(slice + 1)
                ),
                let luminanceFace = luminanceTexture.makeTextureView(
                    pixelFormat: luminanceTexture.pixelFormat,
                    textureType: .type2D,
                    levels: 0..<1,
                    slices: slice..<(slice + 1)
                ),
                let commandBuffer = commandQueue.makeCommandBuffer(),
                let encoder = commandBuffer.makeComputeCommandEncoder()
            else {
                print("EnvironmentProbeBrightRegionAnalyzer: input/output textureView oder commandBuffer/encoder fuer Slice \(slice) konnte nicht erstellt werden. inputType=\(texture.textureType.rawValue) inputFormat=\(texture.pixelFormat.rawValue)")
                return nil
            }

            var thresholdValues = thresholds

            encoder.setComputePipelineState(pipelineState)
            encoder.setTexture(inputFace, index: 0)
            encoder.setTexture(maskFace, index: 1)
            encoder.setTexture(luminanceFace, index: 2)
            encoder.setBytes(
                &thresholdValues,
                length: MemoryLayout<SIMD3<Float>>.stride,
                index: 0
            )
            encoder.dispatchThreadgroups(groupsPerGrid, threadsPerThreadgroup: threadgroupSize)
            encoder.endEncoding()

            commandBuffer.commit()
            await commandBuffer.waitUntilCompletedAsync()

            if commandBuffer.status != .completed {
                print("EnvironmentProbeBrightRegionAnalyzer GPU-Fehler:", commandBuffer.error?.localizedDescription ?? "unbekannt")
                return nil
            }
        }

        return BrightRegionTextures(mask: maskTexture, luminance: luminanceTexture)
    }
}
