//
//  EnvironmentProbeDatasetStore.swift
//  AR-Lighting-Study
//
//  Persists raw Environment Probe faces together with their capture metadata.
//  It also recreates Metal textures when datasets are loaded or imported.

import Foundation
import Metal
import simd

struct EnvironmentProbeDatasetMetadata: Codable {
    let width: Int
    let height: Int
    let sliceCount: Int
    let bytesPerPixel: Int
    let bytesPerRow: Int
    let bytesPerImage: Int
    let pixelFormatRawValue: UInt
    let textureTypeRawValue: UInt
    let cameraScaleReference: Float
    let originFromAnchorTransform: [Float]
    let createdAt: Date
}

enum EnvironmentProbeDatasetStoreError: LocalizedError {
    case documentsDirectoryUnavailable
    case unsupportedPixelFormat(MTLPixelFormat)
    case missingMetadata
    case invalidPixelFormat(UInt)
    case textureCreationFailed
    case missingFaceData(Int)
    case invalidOriginTransform
    case commandQueueCreationFailed
    case commandBufferCreationFailed
    case blitEncoderCreationFailed
    case gpuCopyFailed
    case importSourceMissing
    case incompleteImportedDataset
    case noRecordedDatasetFound

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return "Documents-Ordner konnte nicht gefunden werden."
        case .unsupportedPixelFormat(let format):
            return "Pixel-Format wird noch nicht als Dataset unterstuetzt: \(format.rawValue)"
        case .missingMetadata:
            return "Probe-Dataset-Metadaten fehlen."
        case .invalidPixelFormat(let rawValue):
            return "Unbekanntes Pixel-Format im Dataset: \(rawValue)"
        case .textureCreationFailed:
            return "MTLTexture fuer das gespeicherte Probe-Dataset konnte nicht erzeugt werden."
        case .missingFaceData(let face):
            return "Gespeicherte Face-Daten fehlen fuer Slice \(face)."
        case .invalidOriginTransform:
            return "Gespeicherte Transform-Matrix ist unvollstaendig."
        case .commandQueueCreationFailed:
            return "Metal Command Queue konnte nicht erstellt werden."
        case .commandBufferCreationFailed:
            return "Metal Command Buffer konnte nicht erstellt werden."
        case .blitEncoderCreationFailed:
            return "Metal Blit Encoder konnte nicht erstellt werden."
        case .gpuCopyFailed:
            return "Metal GPU-Kopie der Probe ist fehlgeschlagen."
        case .importSourceMissing:
            return "Ausgewaehlter Dataset-Ordner oder Dateien fehlen."
        case .incompleteImportedDataset:
            return "Ausgewaehlte Dataset-Dateien sind unvollstaendig. Es werden mindestens probe-metadata.json und die probe-face-*.bin Dateien benoetigt."
        case .noRecordedDatasetFound:
            return "Kein gueltiges gespeichertes Probe-Dataset gefunden."
        }
    }
}

struct LoadedEnvironmentProbeDataset {
    let texture: any MTLTexture
    let metadata: EnvironmentProbeDatasetMetadata
    let folderURL: URL

    var originFromAnchorTransform: simd_float4x4? {
        guard metadata.originFromAnchorTransform.count == 16 else {
            return nil
        }

        return simd_float4x4(columns: (
            SIMD4<Float>(
                metadata.originFromAnchorTransform[0],
                metadata.originFromAnchorTransform[1],
                metadata.originFromAnchorTransform[2],
                metadata.originFromAnchorTransform[3]
            ),
            SIMD4<Float>(
                metadata.originFromAnchorTransform[4],
                metadata.originFromAnchorTransform[5],
                metadata.originFromAnchorTransform[6],
                metadata.originFromAnchorTransform[7]
            ),
            SIMD4<Float>(
                metadata.originFromAnchorTransform[8],
                metadata.originFromAnchorTransform[9],
                metadata.originFromAnchorTransform[10],
                metadata.originFromAnchorTransform[11]
            ),
            SIMD4<Float>(
                metadata.originFromAnchorTransform[12],
                metadata.originFromAnchorTransform[13],
                metadata.originFromAnchorTransform[14],
                metadata.originFromAnchorTransform[15]
            )
        ))
    }
}

final class EnvironmentProbeDatasetStore {
    private let fileManager = FileManager.default

    func saveDataset(
        from texture: any MTLTexture,
        cameraScaleReference: Float,
        originFromAnchorTransform: simd_float4x4
    ) async throws -> URL {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw EnvironmentProbeDatasetStoreError.documentsDirectoryUnavailable
        }

        let bytesPerPixel = try bytesPerPixel(for: texture.pixelFormat)
        let bytesPerRow = texture.width * bytesPerPixel
        let bytesPerImage = bytesPerRow * texture.height
        let sliceCount = texture.textureType == .typeCube ? 6 : max(texture.arrayLength, 1)

        let datasetsRootURL = documentsURL.appending(path: "EnvironmentProbeDatasets", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: datasetsRootURL, withIntermediateDirectories: true)

        let datasetName = "probe-dataset-\(Self.timestampFormatter.string(from: .now))"
        let datasetFolderURL = datasetsRootURL.appending(path: datasetName, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: datasetFolderURL, withIntermediateDirectories: true)

        let metadata = EnvironmentProbeDatasetMetadata(
            width: texture.width,
            height: texture.height,
            sliceCount: sliceCount,
            bytesPerPixel: bytesPerPixel,
            bytesPerRow: bytesPerRow,
            bytesPerImage: bytesPerImage,
            pixelFormatRawValue: texture.pixelFormat.rawValue,
            textureTypeRawValue: texture.textureType.rawValue,
            cameraScaleReference: cameraScaleReference,
            originFromAnchorTransform: matrixArray(from: originFromAnchorTransform),
            createdAt: .now
        )

        let faceData = try await exportFaceData(from: texture, sliceCount: sliceCount, bytesPerRow: bytesPerRow, bytesPerImage: bytesPerImage)

        let metadataURL = datasetFolderURL.appending(path: "probe-metadata.json")
        let metadataData = try JSONEncoder.prettyPrinted.encode(metadata)
        try metadataData.write(to: metadataURL, options: .atomic)

        for slice in 0..<sliceCount {
            let faceURL = datasetFolderURL.appending(path: faceFilename(for: slice))
            try faceData[slice].write(to: faceURL, options: .atomic)
        }

        let latestURL = datasetsRootURL.appending(path: "latest", directoryHint: .notDirectory)
        try? fileManager.removeItem(at: latestURL)
        if let latestData = datasetName.data(using: .utf8) {
            try latestData.write(to: latestURL, options: .atomic)
        }

        return datasetFolderURL
    }

    func loadLatestDataset(device: MTLDevice) throws -> LoadedEnvironmentProbeDataset {
        let folderURL = try latestDatasetFolderURL()
        return try loadDataset(at: folderURL, device: device)
    }

    func importDataset(from sourceFolderURL: URL) throws -> URL {
        let accessed = sourceFolderURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceFolderURL.stopAccessingSecurityScopedResource()
            }
        }

        guard fileManager.fileExists(atPath: sourceFolderURL.path(percentEncoded: false)) else {
            throw EnvironmentProbeDatasetStoreError.importSourceMissing
        }

        let sourceFiles = try datasetFileURLs(at: sourceFolderURL)
        return try importDatasetFiles(from: sourceFiles, suggestedName: sourceFolderURL.lastPathComponent)
    }

    func importDatasetFiles(from sourceFileURLs: [URL], suggestedName: String = "imported-probe-dataset") throws -> URL {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw EnvironmentProbeDatasetStoreError.documentsDirectoryUnavailable
        }

        let accessedURLs = sourceFileURLs.filter { $0.startAccessingSecurityScopedResource() }
        defer {
            for url in accessedURLs {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let existingFiles = sourceFileURLs.filter {
            fileManager.fileExists(atPath: $0.path(percentEncoded: false)) && !$0.hasDirectoryPath
        }
        guard !existingFiles.isEmpty else {
            throw EnvironmentProbeDatasetStoreError.importSourceMissing
        }

        guard existingFiles.contains(where: { $0.lastPathComponent == "probe-metadata.json" }) else {
            throw EnvironmentProbeDatasetStoreError.incompleteImportedDataset
        }
        guard existingFiles.contains(where: { $0.lastPathComponent.hasPrefix("probe-face-") && $0.pathExtension == "bin" }) else {
            throw EnvironmentProbeDatasetStoreError.incompleteImportedDataset
        }

        let datasetsRootURL = documentsURL.appending(path: "EnvironmentProbeDatasets", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: datasetsRootURL, withIntermediateDirectories: true)

        let destinationFolderURL = uniqueDatasetFolderURL(baseName: suggestedName, under: datasetsRootURL)
        try fileManager.createDirectory(at: destinationFolderURL, withIntermediateDirectories: true)

        for fileURL in existingFiles {
            let destinationURL = destinationFolderURL.appending(path: fileURL.lastPathComponent, directoryHint: .notDirectory)
            if fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: fileURL, to: destinationURL)
        }

        let latestURL = datasetsRootURL.appending(path: "latest", directoryHint: .notDirectory)
        try? fileManager.removeItem(at: latestURL)
        if let latestData = destinationFolderURL.lastPathComponent.data(using: .utf8) {
            try latestData.write(to: latestURL, options: .atomic)
        }

        return destinationFolderURL
    }

    func datasetFileURLs(at folderURL: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { !$0.hasDirectoryPath }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func latestDatasetFolderURL() throws -> URL {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw EnvironmentProbeDatasetStoreError.documentsDirectoryUnavailable
        }

        let datasetsRootURL = documentsURL.appending(path: "EnvironmentProbeDatasets", directoryHint: .isDirectory)
        let latestURL = datasetsRootURL.appending(path: "latest", directoryHint: .notDirectory)

        if
            let datasetName = try? String(contentsOf: latestURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !datasetName.isEmpty
        {
            let candidateURL = datasetsRootURL.appending(path: datasetName, directoryHint: .isDirectory)
            let metadataURL = candidateURL.appending(path: "probe-metadata.json", directoryHint: .notDirectory)
            if fileManager.fileExists(atPath: metadataURL.path(percentEncoded: false)) {
                return candidateURL
            }
        }

        guard let latestFolder = try fileManager.contentsOfDirectory(
            at: datasetsRootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter({ url in
            guard url.hasDirectoryPath else { return false }
            let metadataURL = url.appending(path: "probe-metadata.json", directoryHint: .notDirectory)
            return fileManager.fileExists(atPath: metadataURL.path(percentEncoded: false))
        })
        .sorted(by: { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        })
        .first else {
            throw EnvironmentProbeDatasetStoreError.noRecordedDatasetFound
        }

        return latestFolder
    }

    private func loadDataset(at folderURL: URL, device: MTLDevice) throws -> LoadedEnvironmentProbeDataset {
        let metadataURL = folderURL.appending(path: "probe-metadata.json")
        guard fileManager.fileExists(atPath: metadataURL.path(percentEncoded: false)) else {
            throw EnvironmentProbeDatasetStoreError.missingMetadata
        }

        let metadataData = try Data(contentsOf: metadataURL)
        let metadata = try JSONDecoder.iso8601.decode(EnvironmentProbeDatasetMetadata.self, from: metadataData)
        guard let pixelFormat = MTLPixelFormat(rawValue: metadata.pixelFormatRawValue) else {
            throw EnvironmentProbeDatasetStoreError.invalidPixelFormat(metadata.pixelFormatRawValue)
        }

        let descriptor: MTLTextureDescriptor
        if metadata.sliceCount == 6 {
            descriptor = MTLTextureDescriptor.textureCubeDescriptor(
                pixelFormat: pixelFormat,
                size: metadata.width,
                mipmapped: false
            )
        } else {
            descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type2DArray
            descriptor.width = metadata.width
            descriptor.height = metadata.height
            descriptor.arrayLength = metadata.sliceCount
            descriptor.pixelFormat = pixelFormat
            descriptor.mipmapLevelCount = 1
        }

        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw EnvironmentProbeDatasetStoreError.textureCreationFailed
        }

        let region = MTLRegionMake2D(0, 0, metadata.width, metadata.height)
        for slice in 0..<metadata.sliceCount {
            let faceURL = folderURL.appending(path: faceFilename(for: slice))
            guard fileManager.fileExists(atPath: faceURL.path(percentEncoded: false)) else {
                throw EnvironmentProbeDatasetStoreError.missingFaceData(slice)
            }

            let data = try Data(contentsOf: faceURL)
            data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                texture.replace(
                    region: region,
                    mipmapLevel: 0,
                    slice: slice,
                    withBytes: baseAddress,
                    bytesPerRow: metadata.bytesPerRow,
                    bytesPerImage: metadata.bytesPerImage
                )
            }
        }

        return LoadedEnvironmentProbeDataset(texture: texture, metadata: metadata, folderURL: folderURL)
    }

    private func exportFaceData(
        from texture: any MTLTexture,
        sliceCount: Int,
        bytesPerRow: Int,
        bytesPerImage: Int
    ) async throws -> [Data] {
        guard let commandQueue = texture.device.makeCommandQueue() else {
            throw EnvironmentProbeDatasetStoreError.commandQueueCreationFailed
        }

        var buffers: [MTLBuffer] = []
        buffers.reserveCapacity(sliceCount)

        for _ in 0..<sliceCount {
            guard let buffer = texture.device.makeBuffer(length: bytesPerImage, options: .storageModeShared) else {
                throw EnvironmentProbeDatasetStoreError.textureCreationFailed
            }
            buffers.append(buffer)
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw EnvironmentProbeDatasetStoreError.commandBufferCreationFailed
        }
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw EnvironmentProbeDatasetStoreError.blitEncoderCreationFailed
        }

        let sourceSize = MTLSize(width: texture.width, height: texture.height, depth: 1)
        for slice in 0..<sliceCount {
            blitEncoder.copy(
                from: texture,
                sourceSlice: slice,
                sourceLevel: 0,
                sourceOrigin: .init(x: 0, y: 0, z: 0),
                sourceSize: sourceSize,
                to: buffers[slice],
                destinationOffset: 0,
                destinationBytesPerRow: bytesPerRow,
                destinationBytesPerImage: bytesPerImage
            )
        }

        blitEncoder.endEncoding()
        commandBuffer.commit()
        await commandBuffer.waitUntilCompletedAsync()

        guard commandBuffer.status == .completed else {
            throw EnvironmentProbeDatasetStoreError.gpuCopyFailed
        }

        return buffers.map { Data(bytes: $0.contents(), count: bytesPerImage) }
    }

    private func bytesPerPixel(for pixelFormat: MTLPixelFormat) throws -> Int {
        switch pixelFormat {
        case .rgba16Float:
            return 8
        case .rgba32Float:
            return 16
        case .rgba8Unorm, .rgba8Unorm_srgb, .bgra8Unorm, .bgra8Unorm_srgb:
            return 4
        default:
            throw EnvironmentProbeDatasetStoreError.unsupportedPixelFormat(pixelFormat)
        }
    }

    private func faceFilename(for slice: Int) -> String {
        "probe-face-\(slice).bin"
    }

    private func uniqueDatasetFolderURL(baseName: String, under rootURL: URL) -> URL {
        var candidate = rootURL.appending(path: baseName, directoryHint: .isDirectory)
        var suffix = 1

        while fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = rootURL.appending(path: "\(baseName)-\(suffix)", directoryHint: .isDirectory)
            suffix += 1
        }

        return candidate
    }

    private func matrixArray(from matrix: simd_float4x4) -> [Float] {
        [
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
            matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
            matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
            matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w
        ]
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
