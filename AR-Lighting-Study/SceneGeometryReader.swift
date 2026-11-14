//
//  SceneGeometryReader.swift
//  AR-Lighting-Study
//

//  Reads ARKit planes and meshes to place estimated lights against the real environment.
//  It also manages geometry diagnostics, occlusion, and position stabilization.
import ARKit
import RealityKit
import simd
import UIKit

@MainActor
final class SceneGeometryReader {
    private struct PlaneHit {
        let position: SIMD3<Float>
        let distance: Float
        let classification: SurfaceClassification
    }

    private struct LightPlacementSample {
        let position: SIMD3<Float>
        let distance: Float
        let classification: SurfaceClassification?
    }

    private struct PlaneHitDebugSummary {
        var totalCount = 0
        var missCount = 0
        var hitCounts: [String: Int] = [:]
        var totalDistance: Float = 0
        var distanceSampleCount = 0

        var description: String {
            var parts = hitCounts
                .sorted { lhs, rhs in
                    if lhs.value == rhs.value {
                        return lhs.key < rhs.key
                    }
                    return lhs.value > rhs.value
                }
                .map { "\($0.key) \($0.value)/\(totalCount)" }

            if missCount > 0 {
                parts.append("none \(missCount)/\(totalCount)")
            }

            if distanceSampleCount > 0 {
                parts.append("avgDist \(String(format: "%.2f", totalDistance / Float(distanceSampleCount)))m")
            }

            return parts.isEmpty ? "none 0/\(totalCount)" : parts.joined(separator: ", ")
        }
    }

    private struct StableLightPositionHistory {
        var positions: [SIMD3<Float>] = []
        var outputPosition: SIMD3<Float>?
        var rejectedPositions: [SIMD3<Float>] = []
    }

    private struct StabilizedLightPositionResult {
        let candidatePosition: SIMD3<Float>
        let outputPosition: SIMD3<Float>
        let wasSuppressed: Bool
    }

    private var session: ARKitSession?
    private var planeDetection: PlaneDetectionProvider?
    private var sceneReconstruction: SceneReconstructionProvider?

    private var sessionTask: Task<Void, Never>?
    private var planeUpdatesTask: Task<Void, Never>?
    private var meshUpdatesTask: Task<Void, Never>?
    private weak var debugRoot: Entity?
    private weak var planeClassificationRoot: Entity?
    private weak var occlusionRoot: Entity?
    private var isVisualizationEnabled = false
    private var isPlaneClassificationVisualizationEnabled = false
    private var isOcclusionEnabled = false
    private var planeClassificationEntities: [UUID: Entity] = [:]
    private var planeHitMarkerEntities: [String: Entity] = [:]
    private var meshDebugEntities: [UUID: Entity] = [:]
    private var occlusionEntities: [UUID: Entity] = [:]
    private var latestPlaneHitSamples: [BrightRegionPlaneHitDebugSample] = []
    private var latestPlaneHitRayOrigin = SIMD3<Float>(repeating: 0)
    private var latestPlacementRequestID = 0
    private var appliedPlacementRequestID = 0
    private weak var latestAppModel: AppModel?
    private weak var scenePlacementAppModel: AppModel?
    private let noHitDistanceFallback: Float = 4.0
    private let stableLightPositionHistoryLimit = 10
    private let stableLightRejectedPositionDebugLimit = 5
    private var stableLightPositionHistoriesByStableID: [Int: StableLightPositionHistory] = [:]

    private(set) var planeAnchors: [UUID: PlaneAnchor] = [:]
    private(set) var meshAnchors: [UUID: MeshAnchor] = [:]
    private(set) var status = "Scene Geometry Reader nicht gestartet"

    var planeCount: Int { planeAnchors.count }
    var meshAnchorCount: Int { meshAnchors.count }

    func start(
        appModel: AppModel,
        debugRoot: Entity? = nil,
        planeClassificationRoot: Entity? = nil,
        occlusionRoot: Entity? = nil
    ) {
        guard sessionTask == nil else { return }
        scenePlacementAppModel = appModel
        self.debugRoot = debugRoot
        self.planeClassificationRoot = planeClassificationRoot
        self.occlusionRoot = occlusionRoot
        debugRoot?.isEnabled = isVisualizationEnabled
        planeClassificationRoot?.isEnabled = isPlaneClassificationVisualizationEnabled
        occlusionRoot?.isEnabled = isOcclusionEnabled

        let session = ARKitSession()
        let planeDetection = PlaneDetectionProvider(alignments: [.horizontal, .vertical])
        let sceneReconstruction = SceneReconstructionProvider(modes: [.classification])
        self.session = session
        self.planeDetection = planeDetection
        self.sceneReconstruction = sceneReconstruction

        sessionTask = Task {
            do {
                guard PlaneDetectionProvider.isSupported else {
                    status = "PlaneDetectionProvider wird auf diesem Geraet nicht unterstuetzt."
                    return
                }

                guard SceneReconstructionProvider.isSupported else {
                    status = "SceneReconstructionProvider wird auf diesem Geraet nicht unterstuetzt."
                    return
                }

                let authorizationResult = await session.requestAuthorization(for: [.worldSensing])
                for (_, authorizationStatus) in authorizationResult where authorizationStatus == .denied {
                    status = "World-Sensing-Zugriff wurde abgelehnt."
                    return
                }

                planeUpdatesTask = Task { await handlePlaneUpdates(from: planeDetection) }
                meshUpdatesTask = Task { await handleMeshUpdates(from: sceneReconstruction) }

                try await session.run([planeDetection, sceneReconstruction])
                status = "Scene Geometry Reader laeuft"
            } catch {
                status = "Scene Geometry Reader Fehler: \(error.localizedDescription)"
                print(status)
            }
        }
    }

    func stop() {
        planeUpdatesTask?.cancel()
        meshUpdatesTask?.cancel()
        sessionTask?.cancel()

        planeUpdatesTask = nil
        meshUpdatesTask = nil
        sessionTask = nil

        session?.stop()
        session = nil
        planeDetection = nil
        sceneReconstruction = nil
        planeAnchors.removeAll()
        meshAnchors.removeAll()
        planeClassificationEntities.values.forEach { $0.removeFromParent() }
        planeHitMarkerEntities.values.forEach { $0.removeFromParent() }
        meshDebugEntities.values.forEach { $0.removeFromParent() }
        occlusionEntities.values.forEach { $0.removeFromParent() }
        planeClassificationEntities.removeAll()
        planeHitMarkerEntities.removeAll()
        meshDebugEntities.removeAll()
        occlusionEntities.removeAll()
        stableLightPositionHistoriesByStableID.removeAll()
        latestAppModel?.stableLightRejectedPositionDebugSamples = []
        latestAppModel?.stableLightPositionDebugStatus = "Positions-Debug: gestoppt"
        scenePlacementAppModel?.detectedFloorHeight = nil
        scenePlacementAppModel = nil
    }

    func setVisualizationEnabled(_ isEnabled: Bool) {
        isVisualizationEnabled = isEnabled
        debugRoot?.isEnabled = isEnabled

        for entity in meshDebugEntities.values {
            entity.isEnabled = isEnabled
        }
    }

    func setPlaneClassificationVisualizationEnabled(_ isEnabled: Bool) {
        isPlaneClassificationVisualizationEnabled = isEnabled
        planeClassificationRoot?.isEnabled = isEnabled

        for entity in planeClassificationEntities.values {
            entity.isEnabled = isEnabled
        }

        for entity in planeHitMarkerEntities.values {
            entity.isEnabled = isEnabled
        }
    }

    func updateBrightRegionPlaneHitMarkers(
        samples: [BrightRegionPlaneHitDebugSample],
        rayOrigin: SIMD3<Float>,
        placementRequestID: Int,
        appModel: AppModel
    ) {
        latestPlaneHitSamples = samples
        latestPlaneHitRayOrigin = rayOrigin
        latestPlacementRequestID = placementRequestID
        latestAppModel = appModel
        guard !appModel.isBrightRegionGeometryIgnored else {
            planeHitMarkerEntities.values.forEach { $0.removeFromParent() }
            planeHitMarkerEntities.removeAll()
            stableLightPositionHistoriesByStableID.removeAll()
            appModel.brightRegionPlaneHitDebugSummaries = [:]
            appModel.brightRegionDistanceEstimates = [:]
            appModel.stableLightRejectedPositionDebugSamples = []
            appModel.stableLightPositionDebugStatus = "Positions-Debug: Geometrie ignoriert"
            appliedPlacementRequestID = placementRequestID
            return
        }
        refreshPlaneHitMarkers()
    }

    func setOcclusionEnabled(_ isEnabled: Bool) {
        isOcclusionEnabled = isEnabled
        occlusionRoot?.isEnabled = isEnabled

        for entity in occlusionEntities.values {
            entity.isEnabled = isEnabled
        }
    }

    private func handlePlaneUpdates(from planeDetection: PlaneDetectionProvider) async {
        for await update in planeDetection.anchorUpdates {
            let anchor = update.anchor

            switch update.event {
            case .added, .updated:
                planeAnchors[anchor.id] = anchor
                updateDetectedFloorHeight()
                updatePlaneClassificationEntity(for: anchor)
                refreshPlaneHitMarkers()

            case .removed:
                planeAnchors.removeValue(forKey: anchor.id)
                updateDetectedFloorHeight()
                planeClassificationEntities.removeValue(forKey: anchor.id)?.removeFromParent()
                refreshPlaneHitMarkers()
            }
        }
    }

    private func updateDetectedFloorHeight() {
        let floorHeight = planeAnchors.values
            .filter { $0.surfaceClassification == .floor }
            .max { lhs, rhs in
                let lhsExtent = lhs.geometry.extent
                let rhsExtent = rhs.geometry.extent
                return lhsExtent.width * lhsExtent.height < rhsExtent.width * rhsExtent.height
            }
            .map { anchor in
                let worldFromExtent = anchor.originFromAnchorTransform
                    * anchor.geometry.extent.anchorFromExtentTransform
                return worldFromExtent.columns.3.y
            }

        guard scenePlacementAppModel?.detectedFloorHeight != floorHeight else { return }
        scenePlacementAppModel?.detectedFloorHeight = floorHeight
    }

    private func refreshPlaneHitMarkers() {
        var activeIDs = Set<String>()
        var summaries: [Int: PlaneHitDebugSummary] = [:]
        var distanceTotalsByRegion: [Int: Float] = [:]
        var distanceCountsByRegion: [Int: Int] = [:]
        var placementSamplesByRegion: [Int: [LightPlacementSample]] = [:]

        for sample in latestPlaneHitSamples {
            summaries[sample.regionDisplayIndex, default: PlaneHitDebugSummary()].totalCount += 1
            let rayDirection = lightPlacementRayDirection(for: sample)

            guard let hit = nearestPlaneHit(
                from: latestPlaneHitRayOrigin,
                direction: rayDirection
            ) else {
                summaries[sample.regionDisplayIndex, default: PlaneHitDebugSummary()].missCount += 1
                addPlacementSample(
                    LightPlacementSample(
                        position: latestPlaneHitRayOrigin + rayDirection * noHitDistanceFallback,
                        distance: noHitDistanceFallback,
                        classification: nil
                    ),
                    regionIndex: sample.regionIndex,
                    displayIndex: sample.regionDisplayIndex,
                    summaries: &summaries,
                    distanceTotalsByRegion: &distanceTotalsByRegion,
                    distanceCountsByRegion: &distanceCountsByRegion,
                    placementSamplesByRegion: &placementSamplesByRegion
                )
                continue
            }

            let classificationName = label(for: hit.classification)
            summaries[sample.regionDisplayIndex, default: PlaneHitDebugSummary()].hitCounts[classificationName, default: 0] += 1
            addPlacementSample(
                LightPlacementSample(
                    position: hit.position,
                    distance: hit.distance,
                    classification: hit.classification
                ),
                regionIndex: sample.regionIndex,
                displayIndex: sample.regionDisplayIndex,
                summaries: &summaries,
                distanceTotalsByRegion: &distanceTotalsByRegion,
                distanceCountsByRegion: &distanceCountsByRegion,
                placementSamplesByRegion: &placementSamplesByRegion
            )
            activeIDs.insert(sample.id)
            updatePlaneHitMarker(for: sample, hit: hit)
        }

        let staleIDs = planeHitMarkerEntities.keys.filter { !activeIDs.contains($0) }
        for id in staleIDs {
            planeHitMarkerEntities.removeValue(forKey: id)?.removeFromParent()
        }

        let hitSummaries = summaries.mapValues { summary in
            "planeHits: \(summary.description)"
        }
        if latestAppModel?.brightRegionPlaneHitDebugSummaries != hitSummaries {
            latestAppModel?.brightRegionPlaneHitDebugSummaries = hitSummaries
        }
        if latestPlacementRequestID != appliedPlacementRequestID {
            var distanceEstimates: [Int: Float] = [:]
            for (regionIndex, totalDistance) in distanceTotalsByRegion {
                guard let count = distanceCountsByRegion[regionIndex], count > 0 else {
                    continue
                }

                distanceEstimates[regionIndex] = totalDistance / Float(count)
            }
            updateRegionDistanceEstimates(distanceEstimates)
            updateEstimatedLightPlacement(with: placementSamplesByRegion)
            latestAppModel?.brightRegionCompletedLightPlacementRequestID = latestPlacementRequestID
            appliedPlacementRequestID = latestPlacementRequestID
        }
    }

    private func addPlacementSample(
        _ placementSample: LightPlacementSample,
        regionIndex: Int,
        displayIndex: Int,
        summaries: inout [Int: PlaneHitDebugSummary],
        distanceTotalsByRegion: inout [Int: Float],
        distanceCountsByRegion: inout [Int: Int],
        placementSamplesByRegion: inout [Int: [LightPlacementSample]]
    ) {
        summaries[displayIndex, default: PlaneHitDebugSummary()].totalDistance += placementSample.distance
        summaries[displayIndex, default: PlaneHitDebugSummary()].distanceSampleCount += 1
        distanceTotalsByRegion[regionIndex, default: 0] += placementSample.distance
        distanceCountsByRegion[regionIndex, default: 0] += 1
        placementSamplesByRegion[regionIndex, default: []].append(placementSample)
    }

    private func updateRegionDistanceEstimates(_ distanceEstimates: [Int: Float]) {
        guard let appModel = latestAppModel else { return }
        guard !appModel.shouldFreezeEstimatedLightOutput else { return }

        let previousEstimates = appModel.brightRegionDistanceEstimates
        let hasMeaningfulChange = distanceEstimates.count != previousEstimates.count
            || distanceEstimates.contains { element in
                let (regionIndex, distance) = element
                guard let previousDistance = previousEstimates[regionIndex] else {
                    return true
                }

                return abs(previousDistance - distance) > 0.05
            }

        guard hasMeaningfulChange else { return }

        appModel.brightRegionDistanceEstimates = distanceEstimates
    }

    private func updateEstimatedLightPlacement(with placementSamplesByRegion: [Int: [LightPlacementSample]]) {
        guard let appModel = latestAppModel else { return }
        guard !appModel.shouldFreezeEstimatedLightOutput else { return }
        guard
            appModel.hasBrightRegionEstimatedLight,
            appModel.brightRegionLightSourceOriginMode == .geometryHitOrSceneProbe
        else {
            appModel.stableLightRejectedPositionDebugSamples = []
            appModel.stableLightPositionDebugStatus = "Positions-Debug: kein Geometrie-Placement"
            return
        }

        if !appModel.isStableLightPositionAverageEnabled
            && !appModel.isStableLightPositionMinimumChangeEnabled {
            stableLightPositionHistoriesByStableID.removeAll()
            appModel.stableLightRejectedPositionDebugSamples = []
            appModel.stableLightPositionDebugStatus = "Positions-Debug: Filter aus"
        }

        var positionEvaluationsByStableID: [Int: BrightRegionPositionEvaluation] = [:]
        for index in appModel.brightRegionEstimatedLights.indices {
            let light = appModel.brightRegionEstimatedLights[index]
            guard let placementSamples = placementSamplesByRegion[light.sourceRegionIndex], !placementSamples.isEmpty else {
                continue
            }

            let averagePosition = averagePlacementPosition(from: placementSamples)
            let positionResult = stabilizedLightPosition(
                averagePosition,
                stableID: light.sourceRegionStableID,
                isAverageEnabled: appModel.isStableLightPositionAverageEnabled,
                isMinimumChangeEnabled: appModel.isStableLightPositionMinimumChangeEnabled,
                minimumChange: appModel.stableLightPositionMinimumChange
            )
            positionEvaluationsByStableID[light.sourceRegionStableID] = BrightRegionPositionEvaluation(
                placementRequestID: latestPlacementRequestID,
                stableID: light.sourceRegionStableID,
                rawPosition: averagePosition,
                candidatePosition: positionResult.candidatePosition,
                outputPosition: positionResult.outputPosition,
                wasSuppressed: positionResult.wasSuppressed
            )
            appModel.brightRegionEstimatedLights[index] = BrightRegionEstimatedLightState(
                id: light.id,
                sourceRegionIndex: light.sourceRegionIndex,
                sourceRegionStableID: light.sourceRegionStableID,
                direction: light.direction,
                position: positionResult.outputPosition,
                isPlacementResolved: true,
                color: light.color,
                intensity: light.intensity,
                heightMultiplier: light.heightMultiplier,
                sourceSizePixels: light.sourceSizePixels,
                shadowSoftness: light.shadowSoftness
            )
        }

        guard let dominantLight = appModel.brightRegionEstimatedLights.first else { return }

        let dominantSamples = placementSamplesByRegion[dominantLight.sourceRegionIndex] ?? []
        let placementDescription: String
        if dominantSamples.isEmpty {
            let fallbackPosition = appModel.environmentProbePositionOverride
                + dominantLight.direction * 2.0
            let positionResult = stabilizedLightPosition(
                fallbackPosition,
                stableID: dominantLight.sourceRegionStableID,
                isAverageEnabled: appModel.isStableLightPositionAverageEnabled,
                isMinimumChangeEnabled: appModel.isStableLightPositionMinimumChangeEnabled,
                minimumChange: appModel.stableLightPositionMinimumChange
            )
            positionEvaluationsByStableID[dominantLight.sourceRegionStableID] = BrightRegionPositionEvaluation(
                placementRequestID: latestPlacementRequestID,
                stableID: dominantLight.sourceRegionStableID,
                rawPosition: fallbackPosition,
                candidatePosition: positionResult.candidatePosition,
                outputPosition: positionResult.outputPosition,
                wasSuppressed: positionResult.wasSuppressed
            )
            appModel.brightRegionEstimatedLights[0] = BrightRegionEstimatedLightState(
                id: dominantLight.id,
                sourceRegionIndex: dominantLight.sourceRegionIndex,
                sourceRegionStableID: dominantLight.sourceRegionStableID,
                direction: dominantLight.direction,
                position: positionResult.outputPosition,
                isPlacementResolved: true,
                color: dominantLight.color,
                intensity: dominantLight.intensity,
                heightMultiplier: dominantLight.heightMultiplier,
                sourceSizePixels: dominantLight.sourceSizePixels,
                shadowSoftness: dominantLight.shadowSoftness
            )
            placementDescription = "Placement: directional fallback von lila Kugel"
        } else {
            placementDescription = "Placement: lokal via Plane/Fallback (\(classificationSummary(for: dominantSamples)))"
        }

        let position = appModel.brightRegionEstimatedLights[0].position
        let positionDescription = "Position: (\(String(format: "%.3f", position.x)), \(String(format: "%.3f", position.y)), \(String(format: "%.3f", position.z)))"
        let debugLine = "\(positionDescription) | \(placementDescription)"

        if simd_distance(appModel.brightRegionEstimatedLightPosition, position) > 0.001 {
            appModel.brightRegionEstimatedLightPosition = position
        }
        if appModel.brightRegionEstimatedLightPlacementDebugLine != placementDescription {
            appModel.brightRegionEstimatedLightPlacementDebugLine = placementDescription
        }
        if appModel.brightRegionEstimatedLightPositionDebugLine != debugLine {
            appModel.brightRegionEstimatedLightPositionDebugLine = debugLine
        }
        appModel.brightRegionPositionEvaluationsByStableID = positionEvaluationsByStableID

        pruneStableLightPositionHistories(
            activeStableIDs: Set(appModel.brightRegionEstimatedLights.map(\.sourceRegionStableID))
        )
        updateStableLightRejectedPositionDebugSamples(appModel: appModel)
    }

    private func averagePlacementPosition(from samples: [LightPlacementSample]) -> SIMD3<Float> {
        let totalPosition = samples.reduce(SIMD3<Float>(repeating: 0)) { result, sample in
            result + sample.position
        }

        return totalPosition / Float(samples.count)
    }

    private func stabilizedLightPosition(
        _ position: SIMD3<Float>,
        stableID: Int,
        isAverageEnabled: Bool,
        isMinimumChangeEnabled: Bool,
        minimumChange: Float
    ) -> StabilizedLightPositionResult {
        guard stableID > 0 else {
            return StabilizedLightPositionResult(
                candidatePosition: position,
                outputPosition: position,
                wasSuppressed: false
            )
        }

        var history = stableLightPositionHistoriesByStableID[stableID] ?? StableLightPositionHistory()
        let candidatePosition: SIMD3<Float>
        if isAverageEnabled {
            history.positions.append(position)
            if history.positions.count > stableLightPositionHistoryLimit {
                history.positions.removeFirst(history.positions.count - stableLightPositionHistoryLimit)
            }
            candidatePosition = averagePosition(from: history.positions)
        } else {
            history.positions.removeAll()
            candidatePosition = position
        }

        guard isMinimumChangeEnabled, let outputPosition = history.outputPosition else {
            history.outputPosition = candidatePosition
            history.rejectedPositions.removeAll()
            stableLightPositionHistoriesByStableID[stableID] = history
            return StabilizedLightPositionResult(
                candidatePosition: candidatePosition,
                outputPosition: candidatePosition,
                wasSuppressed: false
            )
        }

        let wasSuppressed: Bool
        if simd_distance(candidatePosition, outputPosition) >= minimumChange {
            history.outputPosition = candidatePosition
            history.rejectedPositions.removeAll()
            wasSuppressed = false
        } else {
            history.rejectedPositions.append(candidatePosition)
            if history.rejectedPositions.count > stableLightRejectedPositionDebugLimit {
                history.rejectedPositions.removeFirst(history.rejectedPositions.count - stableLightRejectedPositionDebugLimit)
            }
            wasSuppressed = true
        }

        stableLightPositionHistoriesByStableID[stableID] = history
        return StabilizedLightPositionResult(
            candidatePosition: candidatePosition,
            outputPosition: history.outputPosition ?? candidatePosition,
            wasSuppressed: wasSuppressed
        )
    }

    private func averagePosition(from positions: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !positions.isEmpty else {
            return SIMD3<Float>(repeating: 0)
        }

        let totalPosition = positions.reduce(SIMD3<Float>(repeating: 0)) { result, position in
            result + position
        }
        return totalPosition / Float(positions.count)
    }

    private func pruneStableLightPositionHistories(activeStableIDs: Set<Int>) {
        stableLightPositionHistoriesByStableID = stableLightPositionHistoriesByStableID.filter { stableID, _ in
            activeStableIDs.contains(stableID)
        }
    }

    private func updateStableLightRejectedPositionDebugSamples(appModel: AppModel) {
        guard appModel.isStableLightPositionMinimumChangeEnabled else {
            appModel.stableLightRejectedPositionDebugSamples = []
            appModel.stableLightPositionDebugStatus = "Positions-Debug: Schwelle aus"
            return
        }

        let samples = stableLightPositionHistoriesByStableID
            .flatMap { stableID, history in
                history.rejectedPositions.enumerated().map { index, position in
                    StableLightRejectedPositionDebugSample(
                        id: "StableLightRejectedPosition-\(stableID)-\(index)",
                        stableID: stableID,
                        sampleIndex: index,
                        position: position
                    )
                }
            }
            .sorted { lhs, rhs in
                if lhs.stableID == rhs.stableID {
                    return lhs.sampleIndex < rhs.sampleIndex
                }
                return lhs.stableID < rhs.stableID
            }
        appModel.stableLightRejectedPositionDebugSamples = samples

        let stableIDs = Set(samples.map(\.stableID)).sorted()
        let stableIDDescription = stableIDs.isEmpty
            ? "-"
            : stableIDs.map(String.init).joined(separator: ",")
        appModel.stableLightPositionDebugStatus = "Rejected: \(samples.count) | IDs: \(stableIDDescription) | Schwelle: \(Int((appModel.stableLightPositionMinimumChange * 100).rounded()))cm"
    }

    private func classificationSummary(for samples: [LightPlacementSample]) -> String {
        Dictionary(grouping: samples, by: { sample in
            sample.classification.map { label(for: $0) } ?? "fallback"
        })
            .map { label, hits in "\(label) \(hits.count)" }
            .sorted()
            .joined(separator: ", ")
    }

    private func updatePlaneHitMarker(
        for sample: BrightRegionPlaneHitDebugSample,
        hit: PlaneHit
    ) {
        guard let planeClassificationRoot else { return }

        let entity = planeHitMarkerEntities[sample.id] ?? {
            let entity = Entity()
            entity.name = "Bright Region Plane Hit \(sample.id)"
            planeClassificationRoot.addChild(entity)
            planeHitMarkerEntities[sample.id] = entity
            return entity
        }()

        entity.isEnabled = isPlaneClassificationVisualizationEnabled
        entity.position = hit.position
        entity.components.set(ModelComponent(
            mesh: .generateSphere(radius: 0.025),
            materials: [
                SimpleMaterial(
                    color: color(for: hit.classification).withAlphaComponent(0.95),
                    roughness: 0.2,
                    isMetallic: false
                )
            ]
        ))
    }

    private func nearestPlaneHit(
        from rayOrigin: SIMD3<Float>,
        direction: SIMD3<Float>
    ) -> PlaneHit? {
        let normalizedDirection = simd_normalize(direction)
        var nearestHit: PlaneHit?

        for anchor in planeAnchors.values {
            guard let hit = planeHit(
                anchor: anchor,
                rayOrigin: rayOrigin,
                direction: normalizedDirection
            ) else {
                continue
            }

            if nearestHit == nil || hit.distance < nearestHit!.distance {
                nearestHit = hit
            }
        }

        return nearestHit
    }

    private func lightPlacementRayDirection(for sample: BrightRegionPlaneHitDebugSample) -> SIMD3<Float> {
        let bottomCubemapFace = 3
        guard sample.face != bottomCubemapFace else {
            return sample.direction
        }

        let direction = sample.direction
        guard direction.y < 0 else {
            return direction
        }

        let flattenedDirection = SIMD3<Float>(direction.x, 0, direction.z)
        guard simd_length_squared(flattenedDirection) > 0.0001 else {
            return direction
        }

        return simd_normalize(flattenedDirection)
    }

    private func planeHit(
        anchor: PlaneAnchor,
        rayOrigin: SIMD3<Float>,
        direction: SIMD3<Float>
    ) -> PlaneHit? {
        let extent = anchor.geometry.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let worldFromExtent = anchor.originFromAnchorTransform * extent.anchorFromExtentTransform
        let extentFromWorld = worldFromExtent.inverse

        let localOrigin4 = extentFromWorld * SIMD4<Float>(rayOrigin.x, rayOrigin.y, rayOrigin.z, 1)
        let localDirection4 = extentFromWorld * SIMD4<Float>(direction.x, direction.y, direction.z, 0)
        let localOrigin = SIMD3<Float>(localOrigin4.x, localOrigin4.y, localOrigin4.z)
        let localDirection = SIMD3<Float>(localDirection4.x, localDirection4.y, localDirection4.z)

        guard abs(localDirection.z) > 0.0001 else { return nil }

        let t = -localOrigin.z / localDirection.z
        guard t > 0 else { return nil }

        let localHit = localOrigin + localDirection * t
        let halfWidth = extent.width * 0.5
        let halfHeight = extent.height * 0.5
        guard
            abs(localHit.x) <= halfWidth,
            abs(localHit.y) <= halfHeight
        else {
            return nil
        }

        let worldHit4 = worldFromExtent * SIMD4<Float>(localHit.x, localHit.y, localHit.z, 1)
        let worldHit = SIMD3<Float>(worldHit4.x, worldHit4.y, worldHit4.z)

        return PlaneHit(
            position: worldHit,
            distance: simd_distance(rayOrigin, worldHit),
            classification: anchor.surfaceClassification
        )
    }

    private func updatePlaneClassificationEntity(for anchor: PlaneAnchor) {
        guard let planeClassificationRoot else { return }

        let extent = anchor.geometry.extent
        guard extent.width > 0, extent.height > 0 else { return }

        let entity = planeClassificationEntities[anchor.id] ?? {
            let entity = Entity()
            entity.name = "Plane Classification \(anchor.id.uuidString)"
            entity.isEnabled = isPlaneClassificationVisualizationEnabled
            planeClassificationRoot.addChild(entity)
            planeClassificationEntities[anchor.id] = entity
            return entity
        }()

        let mesh = MeshResource.generatePlane(width: extent.width, height: extent.height)
        let material = SimpleMaterial(
            color: color(for: anchor.surfaceClassification).withAlphaComponent(0.48),
            isMetallic: false
        )

        entity.isEnabled = isPlaneClassificationVisualizationEnabled
        entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
        entity.setTransformMatrix(
            anchor.originFromAnchorTransform * extent.anchorFromExtentTransform,
            relativeTo: nil
        )
    }

    private func color(for classification: SurfaceClassification) -> UIColor {
        switch classification {
        case .window:
            UIColor.systemYellow
        case .wall:
            UIColor.systemBlue
        case .floor:
            UIColor.systemGreen
        case .ceiling:
            UIColor.systemPurple
        case .table:
            UIColor.systemBrown
        case .seat:
            UIColor.systemOrange
        case .door:
            UIColor.systemRed
        case .tv:
            UIColor.systemPink
        case .bed:
            UIColor.systemTeal
        case .cabinet:
            UIColor.systemIndigo
        case .homeAppliance:
            UIColor.systemMint
        case .plant:
            UIColor.systemCyan
        case .stairs:
            UIColor.darkGray
        case .none:
            UIColor.lightGray
        @unknown default:
            UIColor.white
        }
    }

    private func label(for classification: SurfaceClassification) -> String {
        switch classification {
        case .window:
            "window"
        case .wall:
            "wall"
        case .floor:
            "floor"
        case .ceiling:
            "ceiling"
        case .table:
            "table"
        case .seat:
            "seat"
        case .door:
            "door"
        case .tv:
            "tv"
        case .bed:
            "bed"
        case .cabinet:
            "cabinet"
        case .homeAppliance:
            "homeAppliance"
        case .plant:
            "plant"
        case .stairs:
            "stairs"
        case .none:
            "unclassified"
        @unknown default:
            "unknown"
        }
    }

    private func handleMeshUpdates(from sceneReconstruction: SceneReconstructionProvider) async {
        for await update in sceneReconstruction.anchorUpdates {
            let anchor = update.anchor

            switch update.event {
            case .added, .updated:
                meshAnchors[anchor.id] = anchor
                await updateMeshDebugEntity(for: anchor)
                await updateOcclusionEntity(for: anchor)

            case .removed:
                meshAnchors.removeValue(forKey: anchor.id)
                meshDebugEntities.removeValue(forKey: anchor.id)?.removeFromParent()
                occlusionEntities.removeValue(forKey: anchor.id)?.removeFromParent()
            }
        }
    }

    private func updateMeshDebugEntity(for anchor: MeshAnchor) async {
        guard let debugRoot else { return }

        do {
            let mesh = try await MeshResource(from: anchor)
            let material = SimpleMaterial(color: UIColor.systemCyan.withAlphaComponent(0.45), isMetallic: false)

            let entity = meshDebugEntities[anchor.id] ?? {
                let entity = Entity()
                entity.name = "Scene Mesh Debug"
                entity.isEnabled = isVisualizationEnabled
                debugRoot.addChild(entity)
                meshDebugEntities[anchor.id] = entity
                return entity
            }()

            entity.isEnabled = isVisualizationEnabled
            entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
            entity.setTransformMatrix(anchor.originFromAnchorTransform, relativeTo: nil)
        } catch {
            print("Mesh visualization failed:", error.localizedDescription)
        }
    }

    func resetLightStabilityHistory(appModel: AppModel) {
        stableLightPositionHistoriesByStableID.removeAll()
        appModel.brightRegionPositionEvaluationsByStableID = [:]
        appModel.brightRegionCompletedLightPlacementRequestID = 0
        appModel.stableLightRejectedPositionDebugSamples = []
        appModel.stableLightPositionDebugStatus = "Positions-Debug: Historie zurueckgesetzt"
    }

    private func updateOcclusionEntity(for anchor: MeshAnchor) async {
        guard let occlusionRoot else { return }

        do {
            let mesh = try await MeshResource(from: anchor)
            let materials: [any Material] = [OcclusionMaterial()]

            let entity = occlusionEntities[anchor.id] ?? {
                let entity = Entity()
                entity.name = "Scene Mesh Occlusion"
                entity.isEnabled = isOcclusionEnabled
                occlusionRoot.addChild(entity)
                occlusionEntities[anchor.id] = entity
                return entity
            }()

            entity.isEnabled = isOcclusionEnabled
            entity.components.set(ModelComponent(mesh: mesh, materials: materials))
            entity.setTransformMatrix(anchor.originFromAnchorTransform, relativeTo: nil)
        } catch {
            print("Occlusion mesh update failed:", error.localizedDescription)
        }
    }
}
