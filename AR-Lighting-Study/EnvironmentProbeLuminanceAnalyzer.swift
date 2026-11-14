//
//  EnvironmentProbeLuminanceAnalyzer.swift
//  AR-Lighting-Study
//  Configures the Metal pipeline for average luminance measurements across a Cubemap.
//  It dispatches one face at a time and combines GPU partial sums on the CPU.

import Foundation
import Metal

struct MetalSRGBReadConversionDiagnostic {
    let encodedValue: Float
    let expectedLinearValue: Float
    let srgbShaderValue: Float
    let unormShaderValue: Float

    var confirmsAutomaticConversion: Bool {
        abs(srgbShaderValue - expectedLinearValue) < 0.005
            && abs(unormShaderValue - encodedValue) < 0.005
    }

    var summary: String {
        "Metal sRGB-Read: \(confirmsAutomaticConversion ? "linearisiert" : "unklar") | sRGB \(String(format: "%.4f", srgbShaderValue)) vs erwartet \(String(format: "%.4f", expectedLinearValue)) | unorm \(String(format: "%.4f", unormShaderValue))"
    }
}

@MainActor
final class EnvironmentProbeLuminanceAnalyzer {
    private let device: MTLDevice // Zugang zur GPU
    private let commandQueue: MTLCommandQueue // Warteschlange für GPU
    private let pipelineState: MTLComputePipelineState // Shader
    private let singlePixelReadPipelineState: MTLComputePipelineState
    private let threadgroupSize = MTLSize(width: 8, height: 8, depth: 1) // Thread Gruppen für die GPU

    init?(device: MTLDevice) {
        let library = device.makeDefaultLibrary() ?? (try? device.makeDefaultLibrary(bundle: .main))

        guard
            let commandQueue = device.makeCommandQueue(), //Queue erzeugen
            let library, // Shader aus dem App bundle laden
            let function = library.makeFunction(name: "reduceFaceLuminance"), // nach der bestimmten Funktion suchen
            let pipelineState = try? device.makeComputePipelineState(function: function), // Shader vorbereiten
            let readFunction = library.makeFunction(name: "readSinglePixelRGBA"),
            let singlePixelReadPipelineState = try? device.makeComputePipelineState(function: readFunction)
        else {
            print("EnvironmentProbeLuminanceAnalyzer init fehlgeschlagen. Default library, reduceFaceLuminance oder readSinglePixelRGBA fehlt.")
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.pipelineState = pipelineState
        self.singlePixelReadPipelineState = singlePixelReadPipelineState
    }

    func verifySRGBReadConversion() async -> MetalSRGBReadConversionDiagnostic? {
        let encodedByte: UInt8 = 128
        let encodedValue = Float(encodedByte) / 255.0
        let expectedLinearValue = Self.srgbToLinear(encodedValue)

        guard
            let srgbRead = await readSinglePixelValue(
                pixelFormat: .rgba8Unorm_srgb,
                rgba: [encodedByte, encodedByte, encodedByte, 255]
            ),
            let unormRead = await readSinglePixelValue(
                pixelFormat: .rgba8Unorm,
                rgba: [encodedByte, encodedByte, encodedByte, 255]
            )
        else {
            print("EnvironmentProbeLuminanceAnalyzer: Metal-sRGB-Read-Diagnostic konnte nicht ausgefuehrt werden.")
            return nil
        }

        return MetalSRGBReadConversionDiagnostic(
            encodedValue: encodedValue,
            expectedLinearValue: expectedLinearValue,
            srgbShaderValue: srgbRead.x,
            unormShaderValue: unormRead.x
        )
    }

    func averageLuminance(
        for texture: any MTLTexture,
        progress: (@MainActor @Sendable (String) -> Void)? = nil
    ) async -> Float? {
        // Bei cubemap 6 Texturen, sonst array length verarbeiten
        let sliceCount = texture.textureType == .typeCube ? 6 : max(texture.arrayLength, 1)
        guard sliceCount > 0 else {
            print("EnvironmentProbeLuminanceAnalyzer: sliceCount ist 0.")
            return nil
        }

        // Auf ganze Blöcke nach oben Runden (weiviel Gruppen wenn 8er Gruppen)
        let groupsPerGrid = MTLSize(
            width: (texture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (texture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        // Jeder Thread schreibt eine Teilsumme. Also soviele Faces wie Threads.
        let partialCountPerFace = groupsPerGrid.width * groupsPerGrid.height
        guard partialCountPerFace > 0 else {
            print("EnvironmentProbeLuminanceAnalyzer: partialCountPerFace ist 0.")
            return nil
        }

        // 4 Byte pro Face/Teilsumme
        let partialBufferLength = partialCountPerFace * MemoryLayout<Float>.stride
        // Metal Buffer erstellen, wo die Werte reingeschrieben werden können
        // storageModeShared: Für CPU und GPU sichtbar
        guard let partialBuffer = device.makeBuffer(length: partialBufferLength, options: .storageModeShared) else {
            print("EnvironmentProbeLuminanceAnalyzer: partialBuffer konnte nicht erstellt werden.")
            return nil
        }

        var luminanceSum: Float = 0

        // Jedes Slide der Cubetexture einzeln betrachten
        for slice in 0..<sliceCount {
            await progress?("Metal-Shader laeuft: Face \(slice + 1)/\(sliceCount)")

            guard let faceTexture = texture.makeTextureView(
                pixelFormat: texture.pixelFormat, // vorhandenes Pixel-Format verwenden
                textureType: .type2D, // als 2D Bild behandeln
                levels: 0..<1, // erstes mipmap level
                slices: slice..<(slice + 1)  
            ) else {
                print("EnvironmentProbeLuminanceAnalyzer: textureView fuer Slice \(slice) konnte nicht erstellt werden. textureType=\(texture.textureType.rawValue) pixelFormat=\(texture.pixelFormat.rawValue)")
                continue
            }
            
            // Buffer zurücksetzen: contents gibt die Speicheradresse. Mit 0en auffüllen
            partialBuffer.contents().initializeMemory(as: UInt8.self, repeating: 0, count: partialBufferLength)

            guard
                let commandBuffer = commandQueue.makeCommandBuffer(), // CommandBuffer als einzelnes GPU-Arbeitspaket
                let encoder = commandBuffer.makeComputeCommandEncoder() // Damit werden konkrete Compute-Befehle in das Paket geschrieben
            else {
                print("EnvironmentProbeLuminanceAnalyzer: commandBuffer oder encoder konnte nicht erstellt werden.")
                return nil
            }

            encoder.setComputePipelineState(pipelineState) // vorbereiteten Shader setzen
            encoder.setTexture(faceTexture, index: 0) // Textur an index 0 an den Shader übergeben
            encoder.setBuffer(partialBuffer, offset: 0, index: 0) // Buffer mitgeben wo reingeschrieben wird
            encoder.dispatchThreadgroups(groupsPerGrid, threadsPerThreadgroup: threadgroupSize) // GPU Arbeit starten, wieviele Blöcke und wie groß jeweils
            encoder.endEncoding() // Compute Befehl ist fertig

            commandBuffer.commit() // Arbeitsbefehl an GPU
            await commandBuffer.waitUntilCompletedAsync() // Warten auf fertige Bearbeitung

            if commandBuffer.status != .completed {
                print("EnvironmentProbeLuminanceAnalyzer GPU-Fehler:", commandBuffer.error?.localizedDescription ?? "unbekannt")
                return nil
            }
            
            // Als array interpretieren.
            let partials = partialBuffer.contents().bindMemory(to: Float.self, capacity: partialCountPerFace)
            // Alle Teilsummen aufaddieren
            for index in 0..<partialCountPerFace {
                luminanceSum += partials[index]
            }
        }

        // ALle Pixel der gesamten Textur
        let pixelCount = Float(texture.width * texture.height * sliceCount)
        guard pixelCount > 0 else {
            print("EnvironmentProbeLuminanceAnalyzer: pixelCount ist 0.")
            return nil
        }
        // Durchschnittliche Helligkeit
        return luminanceSum / pixelCount
    }

    private func readSinglePixelValue(
        pixelFormat: MTLPixelFormat,
        rgba: [UInt8]
    ) async -> SIMD4<Float>? {
        guard rgba.count == 4 else {
            return nil
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard
            let texture = device.makeTexture(descriptor: descriptor),
            let outputBuffer = device.makeBuffer(
                length: MemoryLayout<SIMD4<Float>>.stride,
                options: .storageModeShared
            ),
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return nil
        }

        let pixel = rgba
        pixel.withUnsafeBytes { buffer in
            texture.replace(
                region: MTLRegionMake2D(0, 0, 1, 1),
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: 4
            )
        }

        outputBuffer.contents().initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: MemoryLayout<SIMD4<Float>>.stride
        )

        encoder.setComputePipelineState(singlePixelReadPipelineState)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
        )
        encoder.endEncoding()

        commandBuffer.commit()
        await commandBuffer.waitUntilCompletedAsync()

        guard commandBuffer.status == .completed else {
            print("EnvironmentProbeLuminanceAnalyzer sRGB-Diagnostic GPU-Fehler:", commandBuffer.error?.localizedDescription ?? "unbekannt")
            return nil
        }

        return outputBuffer.contents()
            .bindMemory(to: SIMD4<Float>.self, capacity: 1)
            .pointee
    }

    private static func srgbToLinear(_ value: Float) -> Float {
        if value <= 0.04045 {
            return value / 12.92
        }

        return powf((value + 0.055) / 1.055, 2.4)
    }
}
