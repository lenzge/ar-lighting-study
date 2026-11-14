//
//  EnvironmentProbeRegionAnalyzer.swift
//  AR-Lighting-Study
//

//  Finds connected bright pixels and merges regions that meet across Cubemap edges.
//  It returns geometry-only regions for later color and luminance measurements.
import Foundation
import Metal
import simd

struct BrightRegion {
    let face: Int
    let pixels: [(x: Int, y: Int)]
    let edgePixels: [CubeEdge: [(x: Int, y: Int)]]
}

struct MergedBrightRegion {
    let parts: [BrightRegion]

    var pixelCount: Int {
        parts.reduce(0) { total, part in
            total + part.pixels.count
        }
    }

    var faces: Set<Int> {
        Set(parts.map(\.face))
    }

    var spansMultipleFaces: Bool {
        faces.count > 1
    }
}

enum CubeFace: Int {
    case positiveX = 0
    case negativeX = 1
    case positiveY = 2
    case negativeY = 3
    case positiveZ = 4
    case negativeZ = 5
}

enum CubeEdge {
    case left
    case right
    case top
    case bottom
}

private struct EdgeMapping {
    let face: CubeFace
    let edge: CubeEdge
    let flipped: Bool
}

struct EnvironmentProbeRegionAnalyzer {
    private let edgeMappings: [CubeFace: [CubeEdge: EdgeMapping]] = [
        .positiveX: [
            .left: EdgeMapping(face: .positiveZ, edge: .right, flipped: false),
            .right: EdgeMapping(face: .negativeZ, edge: .left, flipped: false),
            .top: EdgeMapping(face: .positiveY, edge: .right, flipped: true),
            .bottom: EdgeMapping(face: .negativeY, edge: .right, flipped: false)
        ],
        .negativeX: [
            .left: EdgeMapping(face: .negativeZ, edge: .right, flipped: false),
            .right: EdgeMapping(face: .positiveZ, edge: .left, flipped: false),
            .top: EdgeMapping(face: .positiveY, edge: .left, flipped: false),
            .bottom: EdgeMapping(face: .negativeY, edge: .left, flipped: true)
        ],
        .positiveY: [
            .left: EdgeMapping(face: .negativeX, edge: .top, flipped: false),
            .right: EdgeMapping(face: .positiveX, edge: .top, flipped: true),
            .top: EdgeMapping(face: .negativeZ, edge: .top, flipped: true),
            .bottom: EdgeMapping(face: .positiveZ, edge: .top, flipped: false)
        ],
        .negativeY: [
            .left: EdgeMapping(face: .negativeX, edge: .bottom, flipped: true),
            .right: EdgeMapping(face: .positiveX, edge: .bottom, flipped: false),
            .top: EdgeMapping(face: .positiveZ, edge: .bottom, flipped: false),
            .bottom: EdgeMapping(face: .negativeZ, edge: .bottom, flipped: true)
        ],
        .positiveZ: [
            .left: EdgeMapping(face: .negativeX, edge: .right, flipped: false),
            .right: EdgeMapping(face: .positiveX, edge: .left, flipped: false),
            .top: EdgeMapping(face: .positiveY, edge: .bottom, flipped: false),
            .bottom: EdgeMapping(face: .negativeY, edge: .top, flipped: false)
        ],
        .negativeZ: [
            .left: EdgeMapping(face: .positiveX, edge: .right, flipped: false),
            .right: EdgeMapping(face: .negativeX, edge: .left, flipped: false),
            .top: EdgeMapping(face: .positiveY, edge: .top, flipped: true),
            .bottom: EdgeMapping(face: .negativeY, edge: .bottom, flipped: true)
        ]
    ]

    func connectedRegions(
        from maskTexture: any MTLTexture,
        includedLevels: Set<Int>,
        excludedDirections: [SIMD3<Float>] = [],
        minimumAngularSeparationDegrees: Float = 0
    ) -> [BrightRegion] {
        let sliceCount = maskTexture.textureType == .typeCube ? 6 : max(maskTexture.arrayLength, 1)
        guard sliceCount > 0, !includedLevels.isEmpty else {
            return []
        }

        var regions: [BrightRegion] = []

        for slice in 0..<sliceCount {
            guard
                let faceTexture = maskTexture.makeTextureView(
                    pixelFormat: maskTexture.pixelFormat,
                    textureType: .type2D,
                    levels: 0..<1,
                    slices: slice..<(slice + 1)
                )
            else {
                continue
            }

            let width = faceTexture.width
            let height = faceTexture.height
            let pixelCount = width * height
            var maskValues = [Float](repeating: 0, count: pixelCount)

            maskValues.withUnsafeMutableBytes { buffer in
                faceTexture.getBytes(
                    buffer.baseAddress!,
                    bytesPerRow: width * MemoryLayout<Float>.stride,
                    from: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0
                )
            }

            var visited = [Bool](repeating: false, count: pixelCount)
            let minimumAngularSeparationCosine = Float(cos(Double(minimumAngularSeparationDegrees) * Double.pi / 180))

            for y in 0..<height {
                for x in 0..<width {
                    let index = y * width + x
                    if visited[index] {
                        continue
                    }

                    let level = maskLevel(for: maskValues[index])
                    if !isIncludedPixel(
                        level: level,
                        face: slice,
                        x: x,
                        y: y,
                        faceSize: width,
                        includedLevels: includedLevels,
                        excludedDirections: excludedDirections,
                        minimumAngularSeparationCosine: minimumAngularSeparationCosine
                    ) {
                        continue
                    }

                    visited[index] = true
                    var pixelsToVisit: [(x: Int, y: Int)] = [(x, y)]
                    var regionPixels: [(x: Int, y: Int)] = []

                    while let current = pixelsToVisit.popLast() {
                        regionPixels.append(current)

                        let neighbours = [
                            (x: current.x - 1, y: current.y),
                            (x: current.x + 1, y: current.y),
                            (x: current.x, y: current.y - 1),
                            (x: current.x, y: current.y + 1),
                            (x: current.x - 1, y: current.y - 1),
                            (x: current.x + 1, y: current.y - 1),
                            (x: current.x - 1, y: current.y + 1),
                            (x: current.x + 1, y: current.y + 1)
                        ]

                        for neighbour in neighbours {
                            guard
                                (0..<width).contains(neighbour.x),
                                (0..<height).contains(neighbour.y)
                            else {
                                continue
                            }

                            let neighbourIndex = neighbour.y * width + neighbour.x
                            if visited[neighbourIndex] {
                                continue
                            }

                            let level = maskLevel(for: maskValues[neighbourIndex])
                            if !isIncludedPixel(
                                level: level,
                                face: slice,
                                x: neighbour.x,
                                y: neighbour.y,
                                faceSize: width,
                                includedLevels: includedLevels,
                                excludedDirections: excludedDirections,
                                minimumAngularSeparationCosine: minimumAngularSeparationCosine
                            ) {
                                continue
                            }

                            visited[neighbourIndex] = true
                            pixelsToVisit.append(neighbour)
                        }
                    }

                    guard !regionPixels.isEmpty else {
                        continue
                    }

                    regions.append(BrightRegion(
                        face: slice,
                        pixels: regionPixels,
                        edgePixels: edgePixels(from: regionPixels, width: width, height: height)
                    ))
                }
            }
        }

        return regions
    }

    func mergedRegionsAcrossCubeFaces(
        from regions: [BrightRegion],
        faceSize: Int
    ) -> [MergedBrightRegion] {
        guard !regions.isEmpty else {
            return []
        }

        var adjacency = Array(repeating: Set<Int>(), count: regions.count)

        for index in regions.indices {
            for candidateIndex in regions.indices where candidateIndex > index {
                if regionsTouchAcrossCubeFaces(
                    regions[index],
                    regions[candidateIndex],
                    faceSize: faceSize
                ) {
                    adjacency[index].insert(candidateIndex)
                    adjacency[candidateIndex].insert(index)
                }
            }
        }

        var visited = Array(repeating: false, count: regions.count)
        var mergedRegions: [MergedBrightRegion] = []

        for startIndex in regions.indices {
            if visited[startIndex] {
                continue
            }

            var stack = [startIndex]
            visited[startIndex] = true
            var componentParts: [BrightRegion] = []

            while let currentIndex = stack.popLast() {
                componentParts.append(regions[currentIndex])

                for neighbourIndex in adjacency[currentIndex] where !visited[neighbourIndex] {
                    visited[neighbourIndex] = true
                    stack.append(neighbourIndex)
                }
            }

            mergedRegions.append(MergedBrightRegion(parts: componentParts))
        }

        return mergedRegions
    }

    func averageDirection(
        for region: MergedBrightRegion,
        faceSize: Int
    ) -> SIMD3<Float>? {
        var directionSum = SIMD3<Float>(repeating: 0)
        var pixelCount = 0

        for part in region.parts {
            for pixel in part.pixels {
                directionSum += cubemapDirection(
                    face: part.face,
                    x: pixel.x,
                    y: pixel.y,
                    faceSize: faceSize
                )
                pixelCount += 1
            }
        }

        guard pixelCount > 0 else {
            return nil
        }

        return simd_normalize(directionSum)
    }

    private func regionsTouchAcrossCubeFaces(
        _ region: BrightRegion,
        _ candidateRegion: BrightRegion,
        faceSize: Int
    ) -> Bool {
        guard let cubeFace = CubeFace(rawValue: region.face) else {
            return false
        }

        for (edge, edgePixels) in region.edgePixels where !edgePixels.isEmpty {
            guard let mapping = edgeMappings[cubeFace]?[edge] else {
                continue
            }

            guard candidateRegion.face == mapping.face.rawValue else {
                continue
            }

            guard let candidateEdgePixels = candidateRegion.edgePixels[mapping.edge], !candidateEdgePixels.isEmpty else {
                continue
            }

            let candidateCoordinates = Set(
                candidateEdgePixels.map { edgeCoordinate(for: $0, edge: mapping.edge) }
            )

            for pixel in edgePixels {
                let coordinate = edgeCoordinate(for: pixel, edge: edge)
                let mappedCoordinate = mapping.flipped ? (faceSize - 1) - coordinate : coordinate

                if candidateCoordinates.contains(mappedCoordinate)
                    || candidateCoordinates.contains(mappedCoordinate + 1)
                    || candidateCoordinates.contains(mappedCoordinate - 1) {
                    return true
                }
            }
        }

        return false
    }

    private func isIncludedPixel(
        level: Int,
        face: Int,
        x: Int,
        y: Int,
        faceSize: Int,
        includedLevels: Set<Int>,
        excludedDirections: [SIMD3<Float>],
        minimumAngularSeparationCosine: Float
    ) -> Bool {
        guard includedLevels.contains(level) else {
            return false
        }

        guard !excludedDirections.isEmpty else {
            return true
        }

        let direction = cubemapDirection(face: face, x: x, y: y, faceSize: faceSize)
        return excludedDirections.allSatisfy { excludedDirection in
            simd_dot(direction, excludedDirection) < minimumAngularSeparationCosine
        }
    }

    private func cubemapDirection(
        face: Int,
        x: Int,
        y: Int,
        faceSize: Int
    ) -> SIMD3<Float> {
        let u = (Float(x) + 0.5) / Float(faceSize) * 2 - 1
        let v = (Float(y) + 0.5) / Float(faceSize) * 2 - 1

        let direction: SIMD3<Float>
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

        return simd_normalize(SIMD3<Float>(direction.x, direction.y, -direction.z))
    }

    private func edgePixels(
        from pixels: [(x: Int, y: Int)],
        width: Int,
        height: Int
    ) -> [CubeEdge: [(x: Int, y: Int)]] {
        var edgePixels: [CubeEdge: [(x: Int, y: Int)]] = [
            .left: [],
            .right: [],
            .top: [],
            .bottom: []
        ]

        for pixel in pixels {
            if pixel.x == 0 {
                edgePixels[.left]?.append(pixel)
            }
            if pixel.x == width - 1 {
                edgePixels[.right]?.append(pixel)
            }
            if pixel.y == 0 {
                edgePixels[.top]?.append(pixel)
            }
            if pixel.y == height - 1 {
                edgePixels[.bottom]?.append(pixel)
            }
        }

        return edgePixels
    }

    private func edgeCoordinate(
        for pixel: (x: Int, y: Int),
        edge: CubeEdge
    ) -> Int {
        switch edge {
        case .left, .right:
            return pixel.y
        case .top, .bottom:
            return pixel.x
        }
    }

    private func maskLevel(for value: Float) -> Int {
        if value >= 0.99 { return 3 }
        if value >= 0.65 { return 2 }
        if value >= 0.32 { return 1 }
        return 0
    }
}
