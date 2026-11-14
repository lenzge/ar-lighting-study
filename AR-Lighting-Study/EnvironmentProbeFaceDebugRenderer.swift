//
//  EnvironmentProbeFaceDebugRenderer.swift
//  AR-Lighting-Study
//
//  Renders saved Environment Probe faces as textured debug planes in RealityKit.
//  It refreshes those planes when the preview image set changes.

import Foundation
import RealityKit
import simd

@MainActor
final class EnvironmentProbeFaceDebugRenderer {
    private weak var root: Entity?
    private var textureCache: [URL: TextureResource] = [:]
    private var loadedPreviewVersion: Int?

    private enum Face: Int, CaseIterable {
        case positiveX = 0
        case negativeX = 1
        case positiveY = 2
        case negativeY = 3
        case positiveZ = 4
        case negativeZ = 5

        var entityName: String {
            switch self {
            case .positiveX: "ProbeFacePositiveX"
            case .negativeX: "ProbeFaceNegativeX"
            case .positiveY: "ProbeFacePositiveY"
            case .negativeY: "ProbeFaceNegativeY"
            case .positiveZ: "ProbeFacePositiveZ"
            case .negativeZ: "ProbeFaceNegativeZ"
            }
        }

        var offset: SIMD3<Float> {
            switch self {
            case .positiveX: [1.0, 0, 0]
            case .negativeX: [-1.0, 0, 0]
            case .positiveY: [0, 1.0, 0]
            case .negativeY: [0, -1.0, 0]
            case .positiveZ: [0, 0, -1.0]
            case .negativeZ: [0, 0, 1.0]
            }
        }

        var imageUp: SIMD3<Float> {
            switch self {
            case .positiveX: [0, 1, 0]
            case .negativeX: [0, 1, 0]
            case .positiveY: [0, 0, 1]
            case .negativeY: [0, 0, -1]
            case .positiveZ: [0, 1, 0]
            case .negativeZ: [0, 1, 0]
            }
        }

        var displayScale: SIMD3<Float> {
            SIMD3<Float>(1, 1, 1)
        }
    }

    func start(root: Entity) {
        self.root = root
    }

    func stop() {
        root?.children.forEach { $0.removeFromParent() }
        root = nil
        textureCache.removeAll()
        loadedPreviewVersion = nil
    }

    func sync(appModel: AppModel, probeTransform overrideProbeTransform: simd_float4x4? = nil) async throws {
        guard let root else { return }
        root.isEnabled = appModel.isProbeFaceDebugEnabled

        guard appModel.isProbeFaceDebugEnabled else { return }

        if loadedPreviewVersion != appModel.environmentProbePreviewVersion {
            textureCache.removeAll()
            loadedPreviewVersion = appModel.environmentProbePreviewVersion
        }

        let probeTransform = overrideProbeTransform ?? appModel.environmentProbeOriginTransform

        for face in Face.allCases {
            guard let url = appModel.environmentProbeFaceURLs[face.rawValue] else {
                continue
            }

            let texture = try texture(for: url)
            let entity = entity(for: face, under: root)
            entity.transform = worldTransform(for: face, probeTransform: probeTransform)

            var material = UnlitMaterial(texture: texture)
            material.faceCulling = .none
            entity.components.set(ModelComponent(
                mesh: .generatePlane(width: 0.48, depth: 0.48),
                materials: [material]
            ))
        }
    }

    private func texture(for url: URL) throws -> TextureResource {
        if let cached = textureCache[url] {
            return cached
        }

        let texture = try TextureResource.load(contentsOf: url)
        textureCache[url] = texture
        return texture
    }

    private func entity(for face: Face, under root: Entity) -> Entity {
        if let existing = root.children.first(where: { $0.name == face.entityName }) {
            return existing
        }

        let entity = Entity()
        entity.name = face.entityName
        root.addChild(entity)
        return entity
    }

    private func worldTransform(
        for face: Face,
        probeTransform: simd_float4x4
    ) -> Transform {
        let probePosition = SIMD3<Float>(
            probeTransform.columns.3.x,
            probeTransform.columns.3.y,
            probeTransform.columns.3.z
        )
        let worldPosition4 = probeTransform * SIMD4<Float>(face.offset, 1)
        let worldPosition = SIMD3<Float>(worldPosition4.x, worldPosition4.y, worldPosition4.z)
        let normal = simd_normalize(probePosition - worldPosition)

        let worldUp4 = probeTransform * SIMD4<Float>(face.imageUp, 0)
        let up = simd_normalize(SIMD3<Float>(worldUp4.x, worldUp4.y, worldUp4.z))
        let right = simd_normalize(simd_cross(up, normal))
        let correctedUp = simd_normalize(simd_cross(normal, right))

        let rotationMatrix = simd_float3x3(columns: (
            right,
            normal,
            -correctedUp
        ))

        return Transform(
            scale: face.displayScale,
            rotation: simd_quatf(rotationMatrix),
            translation: worldPosition
        )
    }
}
