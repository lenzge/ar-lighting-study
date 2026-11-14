//
//  ImmersiveView.swift
//  AR-Lighting-Study
//

//  Builds and updates the immersive RealityKit scene, including lights, interactions, and debug entities.
//  It is the rendering-side consumer of state produced by the AR and analysis services.
import SwiftUI
import ARKit
import RealityKit
import RealityKitContent
import ImageIO
import os
import QuartzCore
import UIKit

struct ImmersiveView: View {
    @Environment(AppModel.self) private var appModel
    @State private var sceneGeometryReader = SceneGeometryReader()
    @State private var probeFaceDebugRenderer = EnvironmentProbeFaceDebugRenderer()
    @State private var handStrikeTracker = HandStrikeTracker()
    @State private var handStrikeImpulseState = HandStrikeImpulseState()
    @State private var heldCubeCollisionState = HeldCubeCollisionState()
    @State private var manipulationSubscriptions: [EventSubscription] = []
    @State private var sceneUpdateSubscriptions: [EventSubscription] = []
    @State private var performanceFrameSubscription: EventSubscription?
    @State private var initialCubeTransforms: [ObjectIdentifier: Transform] = [:]
    @State private var cubeSceneEntity: Entity?
    @State private var cardSpriteEntity: Entity?

    private let planeVisualizationEntityName = "PlaneVisualization"
    private let tableSceneEntityName = "TableSceneVisualization"
    private let tableCardEntityName = "TableCard"
    private let cardSpriteEntityName = "CardSprite"
    private let sceneReconstructionDebugRootName = "SceneReconstructionDebugRoot"
    private let planeClassificationDebugRootName = "PlaneClassificationDebugRoot"
    private let occlusionRootName = "RealWorldOcclusionRoot"
    private let probeFaceDebugRootName = "ProbeFaceDebugRoot"
    private let customImageBasedLightEntityName = "CustomImageBasedLight"
    private let estimatedLightDebugSphereNamePrefix = "EstimatedLightDebugSphere"
    private let rejectedEstimatedLightPositionDebugSphereNamePrefix = "RejectedEstimatedLightPositionDebugSphere"
    private let probePositionDebugSphereName = "ProbePositionDebugSphere"
    private let sceneProbePositionDebugSphereName = "SceneProbePositionDebugSphere"
    private let estimatedDirectionalLightNamePrefix = "EstimatedDirectionalLight"
    private let estimatedSpotLightNamePrefix = "EstimatedSpotLight"
    private let stackingControlsAttachmentID = "StackingControlsAttachment"
    private let immersiveBasePosition = SIMD3<Float>(0, 0, -0.85)
    private var stackingControlsPosition: SIMD3<Float> {
        immersiveBasePosition + [0.70, 0.89, 0.15]
    }
    private let stackingControlsYawDegrees: Float = -50
    private let stackingControlsPitchDegrees: Float = -25
    private let isHandStrikeEnabled = false
    private var sceneBasePosition: SIMD3<Float> {
        guard !appModel.isStackingControlsVisible, let floorHeight = appModel.detectedFloorHeight else {
            return immersiveBasePosition
        }

        return SIMD3<Float>(immersiveBasePosition.x, floorHeight, immersiveBasePosition.z)
    }
    private var areTableSceneGroundingShadowsEnabled: Bool {
        appModel.isStackingControlsVisible || appModel.areGroundingShadowsEnabled
    }
    private var tableCardPosition: SIMD3<Float> {
        sceneBasePosition + [0.4, 0.61, 0.10]
    }
    private let isPhysicalCardModelVisible = false
    private let cardSpriteSize = SIMD2<Float>(0.17, 0.106)
    private let cardSpriteSurfaceOffset = SIMD2<Float>(0,0)
    private let cardSpriteLift: Float = 0.001
    private let cardSpritePitchDegrees: Float = 0
    private let environmentProbeOverrideHeight: Float = 1.8
    
    private let customImageBasedLightName = "sky"
    private let customImageBasedLightIntensityExponent: Float = 0.0
    private let performanceLog = OSLog(subsystem: "AR-Lighting-Study", category: "Performance")

    var body: some View {
        RealityView { content, attachments in
            do {
                let isSceneReconstructionVisible = appModel.isSceneReconstructionVisualizationEnabled
                    && !appModel.isPlaneClassificationVisualizationEnabled

                let sceneReconstructionDebugRoot = Entity()
                sceneReconstructionDebugRoot.name = sceneReconstructionDebugRootName
                sceneReconstructionDebugRoot.isEnabled = isSceneReconstructionVisible
                content.add(sceneReconstructionDebugRoot)

                let planeClassificationDebugRoot = Entity()
                planeClassificationDebugRoot.name = planeClassificationDebugRootName
                planeClassificationDebugRoot.isEnabled = appModel.isPlaneClassificationVisualizationEnabled
                content.add(planeClassificationDebugRoot)

                let occlusionRoot = Entity()
                occlusionRoot.name = occlusionRootName
                occlusionRoot.isEnabled = appModel.isRealWorldOcclusionEnabled
                content.add(occlusionRoot)

                let probeFaceDebugRoot = Entity()
                probeFaceDebugRoot.name = probeFaceDebugRootName
                probeFaceDebugRoot.isEnabled = appModel.isProbeFaceDebugEnabled
                content.add(probeFaceDebugRoot)

                sceneGeometryReader.setVisualizationEnabled(isSceneReconstructionVisible)
                sceneGeometryReader.setPlaneClassificationVisualizationEnabled(appModel.isPlaneClassificationVisualizationEnabled)
                sceneGeometryReader.setOcclusionEnabled(appModel.isRealWorldOcclusionEnabled)
                probeFaceDebugRenderer.start(root: probeFaceDebugRoot)
                try await probeFaceDebugRenderer.sync(appModel: appModel)
                sceneGeometryReader.start(
                    appModel: appModel,
                    debugRoot: sceneReconstructionDebugRoot,
                    planeClassificationRoot: planeClassificationDebugRoot,
                    occlusionRoot: occlusionRoot
                )

                let sceneEntities = try await addImmersiveScenes(
                    selectedScene: appModel.selectedImmersiveScene,
                    loadsOnlySelectedScene: appModel.isStackingControlsVisible,
                    basePosition: sceneBasePosition,
                    areGroundingShadowsEnabled: appModel.areGroundingShadowsEnabled,
                    to: content
                )
                manipulationSubscriptions.forEach { $0.cancel() }
                manipulationSubscriptions = subscribeToCubeManipulationEvents(
                    in: content,
                    heldCubeCollisionState: heldCubeCollisionState
                )
                sceneUpdateSubscriptions.forEach { $0.cancel() }
                if isHandStrikeEnabled {
                    sceneUpdateSubscriptions = subscribeToHandStrikeUpdates(
                        in: content,
                        handStrikeTracker: handStrikeTracker,
                        impulseState: handStrikeImpulseState
                    )
                } else {
                    sceneUpdateSubscriptions.removeAll()
                }
                performanceFrameSubscription?.cancel()
                performanceFrameSubscription = content.subscribe(to: SceneEvents.Update.self) { _ in
                    appModel.recordFPSStressTestFrame(at: CACurrentMediaTime())
                }
                if let cubeScene = sceneEntities.first(where: { $0.name == AppModel.ImmersiveScene.cube.entityName }) {
                    cubeSceneEntity = cubeScene
                    initialCubeTransforms = cubeTransforms(in: cubeScene)
                }
                guard let activeScene = sceneEntities.first(where: { $0.isEnabled }) else {
                    return
                }
                if let plane = try? await Entity(named: "Plane", in: realityKitContentBundle) {
                    plane.name = planeVisualizationEntityName
                    plane.position = sceneBasePosition
                    plane.isEnabled = appModel.isPlaneVisualizationEnabled
                    
                    configureStaticBoxPhysics(on: plane, colliderName: "PlaneCollider")
                    applyPlaneMaterial(to: plane)
                    setGroundingShadows(
                        appModel.areGroundingShadowsEnabled,
                        on: plane,
                        castsShadow: false,
                        receivesShadow: false
                    )
                    content.add(plane)
                }

                if let tableScene = try? await Entity(named: "TableScene", in: realityKitContentBundle) {
                    tableScene.name = tableSceneEntityName
                    tableScene.position = sceneBasePosition
                    tableScene.isEnabled = appModel.selectedImmersiveScene.includesTableScene
                    
                    configureStaticBoxPhysics(on: tableScene, colliderName: "TableCollider")
                    setGroundingShadows(
                        areTableSceneGroundingShadowsEnabled,
                        on: tableScene,
                        castsShadow: true,
                        receivesShadow: true
                    )
                    setDynamicLightShadows(true, on: tableScene)
                    setEnvironmentLighting(
                        appModel.isEnvironmentLightingEnabled,
                        on: tableScene,
                        weight: appModel.environmentLightingWeight
                    )
                    content.add(tableScene)
                }

                if let tableCard = try? await makeTableCard(
                    position: tableCardPosition,
                    spriteImageName: appModel.activeStackingCardSpriteImageName,
                    spriteSize: cardSpriteSize,
                    spriteSurfaceOffset: cardSpriteSurfaceOffset,
                    spriteLift: cardSpriteLift,
                    spritePitchDegrees: cardSpritePitchDegrees,
                    isPhysicalModelVisible: isPhysicalCardModelVisible,
                    cardEntityName: tableCardEntityName,
                    spriteEntityName: cardSpriteEntityName
                ) {
                    tableCard.isEnabled = appModel.selectedImmersiveScene.includesTableScene
                    setGroundingShadows(
                        appModel.areGroundingShadowsEnabled,
                        on: tableCard,
                        castsShadow: true,
                        receivesShadow: true
                    )
                    setDynamicLightShadows(true, on: tableCard)
                    setEnvironmentLighting(
                        appModel.isEnvironmentLightingEnabled,
                        on: tableCard,
                        weight: appModel.environmentLightingWeight
                    )
                    content.add(tableCard)
                    cardSpriteEntity = tableCard.findEntity(named: cardSpriteEntityName)
                }

                addEstimatedLightDebugSpheres(
                    appModel: appModel,
                    namePrefix: estimatedLightDebugSphereNamePrefix,
                    to: content
                )
                addRejectedEstimatedLightPositionDebugSpheres(
                    appModel: appModel,
                    namePrefix: rejectedEstimatedLightPositionDebugSphereNamePrefix,
                    to: content
                )
                addProbePositionDebugSphere(
                    appModel: appModel,
                    name: probePositionDebugSphereName,
                    to: content
                )
                addSceneProbePositionDebugSphere(
                    appModel: appModel,
                    name: sceneProbePositionDebugSphereName,
                    to: content
                )
                addEstimatedDirectionalLights(
                    appModel: appModel,
                    target: activeScene,
                    namePrefix: estimatedDirectionalLightNamePrefix,
                    to: content
                )
                addEstimatedSpotLights(
                    appModel: appModel,
                    target: activeScene,
                    namePrefix: estimatedSpotLightNamePrefix,
                    to: content
                )

                try await addCustomImageBasedLight(
                    named: customImageBasedLightName,
                    intensityExponent: customImageBasedLightIntensityExponent,
                    entityName: customImageBasedLightEntityName,
                    in: content
                )
                setCustomImageBasedLightReceiver(
                    appModel.isCustomImageBasedLightEnabled,
                    imageBasedLight: content.entities.first(where: { $0.name == customImageBasedLightEntityName }),
                    on: activeScene
                )
                if let tableScene = content.entities.first(where: { $0.name == tableSceneEntityName }) {
                    setCustomImageBasedLightReceiver(
                        appModel.isCustomImageBasedLightEnabled,
                        imageBasedLight: content.entities.first(where: { $0.name == customImageBasedLightEntityName }),
                        on: tableScene
                    )
                }
                setEnvironmentLighting(
                    appModel.isEnvironmentLightingEnabled,
                    on: activeScene,
                    weight: appModel.environmentLightingWeight
                )

                if let stackingControls = attachments.entity(for: stackingControlsAttachmentID) {
                    stackingControls.name = stackingControlsAttachmentID
                    stackingControls.position = stackingControlsPosition
                    stackingControls.orientation = stackingControlsOrientation(
                        yawDegrees: stackingControlsYawDegrees,
                        pitchDegrees: stackingControlsPitchDegrees
                    )
                    stackingControls.isEnabled = appModel.isStackingControlsVisible
                    content.add(stackingControls)
                }
            } catch {
                print("Fehler beim Laden der Immersive-Szene:", error)
            }
        } update: { content, attachments in
            let sceneEntities = immersiveSceneEntities(in: content)
            guard let activeScene = sceneEntities.first(where: { $0.name == appModel.selectedImmersiveScene.entityName }) else {
                return
            }

            setActiveImmersiveScene(appModel.selectedImmersiveScene, in: sceneEntities)

            for scene in sceneEntities {
                var transform = scene.transform
                transform.translation = sceneBasePosition
                scene.move(to: transform, relativeTo: scene.parent, duration: 0.18, timingFunction: .easeInOut)
            }

            if let plane = content.entities.first(where: { $0.name == planeVisualizationEntityName }) {
                var transform = plane.transform
                transform.translation = sceneBasePosition
                plane.move(to: transform, relativeTo: plane.parent, duration: 0.18, timingFunction: .easeInOut)
            }

            if let tableScene = content.entities.first(where: { $0.name == tableSceneEntityName }) {
                var transform = tableScene.transform
                transform.translation = sceneBasePosition
                tableScene.move(to: transform, relativeTo: tableScene.parent, duration: 0.18, timingFunction: .easeInOut)
                setGroundingShadows(
                    areTableSceneGroundingShadowsEnabled,
                    on: tableScene,
                    castsShadow: true,
                    receivesShadow: true
                )
                setDynamicLightShadows(
                    appModel.isEstimatedEnvironmentLightRenderingEnabled && appModel.hasBrightRegionEstimatedLight,
                    on: tableScene
                )
                setEnvironmentLighting(
                    appModel.isEnvironmentLightingEnabled,
                    on: tableScene,
                    weight: appModel.environmentLightingWeight
                )
                removeImageBasedLightReceiver(from: tableScene)
            }

            if let tableCard = content.entities.first(where: { $0.name == tableCardEntityName }) {
                var transform = tableCard.transform
                transform.translation = tableCardPosition
                tableCard.move(to: transform, relativeTo: tableCard.parent, duration: 0.18, timingFunction: .easeInOut)
                tableCard.isEnabled = appModel.selectedImmersiveScene.includesTableScene
                setGroundingShadows(
                    appModel.areGroundingShadowsEnabled,
                    on: tableCard,
                    castsShadow: true,
                    receivesShadow: true
                )
                setDynamicLightShadows(
                    appModel.isEstimatedEnvironmentLightRenderingEnabled && appModel.hasBrightRegionEstimatedLight,
                    on: tableCard
                )
                setEnvironmentLighting(
                    appModel.isEnvironmentLightingEnabled,
                    on: tableCard,
                    weight: appModel.environmentLightingWeight
                )
                removeImageBasedLightReceiver(from: tableCard)
            }

            setGroundingShadows(
                appModel.areGroundingShadowsEnabled,
                on: activeScene,
                castsShadow: true,
                receivesShadow: true
            )
            for scene in sceneEntities {
                setDynamicLightShadows(
                    appModel.isEstimatedEnvironmentLightRenderingEnabled && appModel.hasBrightRegionEstimatedLight,
                    on: scene
                )
                setEnvironmentLighting(
                    appModel.isEnvironmentLightingEnabled,
                    on: scene,
                    weight: appModel.environmentLightingWeight
                )
                removeImageBasedLightReceiver(from: scene)
            }
            updateEstimatedLightDebugSpheres(
                appModel: appModel,
                namePrefix: estimatedLightDebugSphereNamePrefix,
                in: content
            )
            updateRejectedEstimatedLightPositionDebugSpheres(
                appModel: appModel,
                namePrefix: rejectedEstimatedLightPositionDebugSphereNamePrefix,
                in: content
            )
            updateProbePositionDebugSphere(
                appModel: appModel,
                named: probePositionDebugSphereName,
                in: content
            )
            updateSceneProbePositionDebugSphere(
                appModel: appModel,
                named: sceneProbePositionDebugSphereName,
                in: content
            )
            let estimatedLightUpdateSignpostID = OSSignpostID(log: performanceLog)
            os_signpost(
                .begin,
                log: performanceLog,
                name: "RealityKitEstimatedLightUpdate",
                signpostID: estimatedLightUpdateSignpostID,
                "renderEnabled %d isSpot %d estimatedLights %d spotCount %d directionalCount %d",
                appModel.isEstimatedEnvironmentLightRenderingEnabled ? 1 : 0,
                appModel.brightRegionEstimatedLightType == .spot ? 1 : 0,
                appModel.brightRegionEstimatedLights.count,
                appModel.brightRegionEstimatedSpotLightCount,
                appModel.brightRegionEstimatedDirectionalLightCount
            )
            updateEstimatedDirectionalLights(
                appModel: appModel,
                target: activeScene,
                namePrefix: estimatedDirectionalLightNamePrefix,
                in: content
            )
            updateEstimatedSpotLights(
                appModel: appModel,
                target: activeScene,
                namePrefix: estimatedSpotLightNamePrefix,
                in: content
            )
            os_signpost(
                .end,
                log: performanceLog,
                name: "RealityKitEstimatedLightUpdate",
                signpostID: estimatedLightUpdateSignpostID
            )
            setEntity(appModel.isPlaneVisualizationEnabled, named: planeVisualizationEntityName, in: content)
            setEntity(
                appModel.selectedImmersiveScene.includesTableScene,
                named: tableSceneEntityName,
                in: content
            )
            let isSceneReconstructionVisible = appModel.isSceneReconstructionVisualizationEnabled
                && !appModel.isPlaneClassificationVisualizationEnabled
            sceneGeometryReader.setVisualizationEnabled(isSceneReconstructionVisible)
            sceneGeometryReader.setPlaneClassificationVisualizationEnabled(appModel.isPlaneClassificationVisualizationEnabled)
            sceneGeometryReader.setOcclusionEnabled(appModel.isRealWorldOcclusionEnabled)
            sceneGeometryReader.updateBrightRegionPlaneHitMarkers(
                samples: appModel.brightRegionPlaneHitDebugSamples,
                rayOrigin: appModel.environmentProbePositionOverride,
                placementRequestID: appModel.brightRegionLightPlacementRequestID,
                appModel: appModel
            )
            setEntity(appModel.isRealWorldOcclusionEnabled, named: occlusionRootName, in: content)
            setEntity(appModel.isProbeFaceDebugEnabled, named: probeFaceDebugRootName, in: content)
            setCustomImageBasedLightReceiver(
                appModel.isCustomImageBasedLightEnabled,
                imageBasedLight: content.entities.first(where: { $0.name == customImageBasedLightEntityName }),
                on: activeScene
            )
            if let tableScene = content.entities.first(where: { $0.name == tableSceneEntityName }) {
                setCustomImageBasedLightReceiver(
                    appModel.isCustomImageBasedLightEnabled,
                    imageBasedLight: content.entities.first(where: { $0.name == customImageBasedLightEntityName }),
                    on: tableScene
                )
            }
            setEnvironmentLighting(
                appModel.isEnvironmentLightingEnabled,
                on: activeScene,
                weight: appModel.environmentLightingWeight
            )

            if let stackingControls = attachments.entity(for: stackingControlsAttachmentID) {
                stackingControls.position = stackingControlsPosition
                stackingControls.orientation = stackingControlsOrientation(
                    yawDegrees: stackingControlsYawDegrees,
                    pitchDegrees: stackingControlsPitchDegrees
                )
                stackingControls.isEnabled = appModel.isStackingControlsVisible
                    && appModel.selectedImmersiveScene == .cube
                if stackingControls.parent == nil {
                    content.add(stackingControls)
                }
            }
        } attachments: {
            Attachment(id: stackingControlsAttachmentID) {
                StackingControlsView()
                    .environment(appModel)
                    .glassBackgroundEffect()
            }
        }
        .task {
            appModel.environmentProbePositionOverrideHeight = environmentProbeOverrideHeight
            appModel.environmentProbePositionOverride = immersiveBasePosition + [0, environmentProbeOverrideHeight, 0]
            if isHandStrikeEnabled {
                handStrikeTracker.start()
            } else {
                handStrikeTracker.stop()
            }
            appModel.deviceAnchorTracker.start(appModel: appModel)
            appModel.environmentProbeReader.start(appModel: appModel)
            appModel.environmentProbeReader.refreshDatasetStatus(appModel: appModel)
            try? await probeFaceDebugRenderer.sync(appModel: appModel)
        }
        .onChange(of: appModel.environmentProbeRefreshRequestID) { _, _ in
            appModel.environmentProbeReader.refreshEnvironmentProbeAnalysis(appModel: appModel)
        }
        .onChange(of: appModel.environmentProbeSaveDatasetRequestID) { _, _ in
            appModel.environmentProbeReader.saveCurrentDataset(appModel: appModel)
        }
        .onChange(of: appModel.environmentProbeLoadRecordedDatasetRequestID) { _, _ in
            appModel.environmentProbeReader.loadLatestRecordedDataset(appModel: appModel)
        }
        .onChange(of: appModel.environmentProbeImportDatasetRequestID) { _, _ in
            importEnvironmentProbeDataset(appModel: appModel)
        }
        .onChange(of: appModel.brightRegionMaskRefreshRequestID) { _, _ in
            appModel.environmentProbeReader.refreshEnvironmentProbeAnalysis(appModel: appModel)
        }
        .onChange(of: appModel.lightStabilityResetRequestID) { _, _ in
            sceneGeometryReader.resetLightStabilityHistory(appModel: appModel)
        }
        .onChange(of: appModel.environmentProbePreviewVersion) { _, _ in
            Task {
                try? await probeFaceDebugRenderer.sync(appModel: appModel)
            }
        }
        .onChange(of: appModel.isProbeFaceDebugEnabled) { _, _ in
            Task {
                try? await probeFaceDebugRenderer.sync(appModel: appModel)
            }
        }
        .onChange(of: appModel.stackingSceneReloadRequestID) { _, _ in
            guard let cubeSceneEntity else { return }
            resetCubeScene(
                cubeSceneEntity,
                to: initialCubeTransforms,
                heldCubeCollisionState: heldCubeCollisionState
            )
        }
        .onChange(of: appModel.activeStackingCardSpriteImageName) { _, imageName in
            guard let cardSpriteEntity else { return }
            Task {
                await updateCardSpriteImage(named: imageName, on: cardSpriteEntity)
            }
        }
        .onDisappear {
            appModel.cancelFPSStressTest()
            appModel.environmentProbeReader.stop(appModel: appModel)
            appModel.deviceAnchorTracker.stop(appModel: appModel)
            sceneGeometryReader.stop()
            probeFaceDebugRenderer.stop()
            manipulationSubscriptions.forEach { $0.cancel() }
            manipulationSubscriptions.removeAll()
            sceneUpdateSubscriptions.forEach { $0.cancel() }
            sceneUpdateSubscriptions.removeAll()
            performanceFrameSubscription?.cancel()
            performanceFrameSubscription = nil
            handStrikeTracker.stop()
            handStrikeImpulseState.reset()
            heldCubeCollisionState.reset()
            cubeSceneEntity = nil
            cardSpriteEntity = nil
            initialCubeTransforms.removeAll()
        }
    }
}

private func setPhysicsMode(_ mode: PhysicsBodyMode, on entity: Entity) {
    guard var physicsBody = entity.components[PhysicsBodyComponent.self] else {
        return
    }

    physicsBody.mode = mode
    entity.components.set(physicsBody)
}

private func subscribeToCubeManipulationEvents(
    in content: RealityViewContent,
    heldCubeCollisionState: HeldCubeCollisionState
) -> [EventSubscription] {
    [
        content.subscribe(
            to: ManipulationEvents.WillBegin.self,
            componentType: ManipulationComponent.self
        ) { event in
            guard isCubeEntity(event.entity) else { return }
            heldCubeCollisionState.disableCollision(on: event.entity)
            setPhysicsMode(.kinematic, on: event.entity)
        },
        content.subscribe(
            to: ManipulationEvents.WillEnd.self,
            componentType: ManipulationComponent.self
        ) { event in
            guard isCubeEntity(event.entity) else { return }
            heldCubeCollisionState.restoreCollision(on: event.entity)
            resetPhysicsMotion(on: event.entity)
            setPhysicsMode(.dynamic, on: event.entity)
        }
    ]
}

@MainActor
private final class HeldCubeCollisionState {
    private var storedCollisions: [ObjectIdentifier: CollisionComponent] = [:]

    func disableCollision(on entity: Entity) {
        let entityID = ObjectIdentifier(entity)

        if storedCollisions[entityID] == nil,
           let collision = entity.components[CollisionComponent.self] {
            storedCollisions[entityID] = collision
        }

        entity.components.remove(CollisionComponent.self)
    }

    func restoreCollision(on entity: Entity) {
        let entityID = ObjectIdentifier(entity)
        guard let collision = storedCollisions.removeValue(forKey: entityID) else {
            return
        }

        entity.components.set(collision)
    }

    func reset() {
        storedCollisions.removeAll()
    }
}

private func subscribeToHandStrikeUpdates(
    in content: RealityViewContent,
    handStrikeTracker: HandStrikeTracker,
    impulseState: HandStrikeImpulseState
) -> [EventSubscription] {
    [
        content.subscribe(to: SceneEvents.Update.self) { _ in
            applyHandStrikeImpulses(
                in: content,
                handStrikeTracker: handStrikeTracker,
                impulseState: impulseState
            )
        }
    ]
}

@MainActor
private final class HandStrikeImpulseState {
    var lastImpactTimes: [ObjectIdentifier: TimeInterval] = [:]

    func reset() {
        lastImpactTimes.removeAll()
    }
}

private func applyHandStrikeImpulses(
    in content: RealityViewContent,
    handStrikeTracker: HandStrikeTracker,
    impulseState: HandStrikeImpulseState
) {
    let speedThreshold: Float = 1.5
    let hitRadius: Float = 0.18
    let maxImpulse: Float = 4.4
    let impulseMultiplier: Float = 2.8
    let cubeMass: Float = 1.5
    let hitCooldown: TimeInterval = 0.18
    let now = CACurrentMediaTime()

    let activeSamples = handStrikeTracker.handSamples.filter {
        simd_length($0.velocity) >= speedThreshold
    }
    guard !activeSamples.isEmpty else { return }

    for cube in cubeEntities(in: content) {
        guard cube.components[PhysicsBodyComponent.self]?.mode == .dynamic else { continue }

        let cubeID = ObjectIdentifier(cube)
        if let lastImpactTime = impulseState.lastImpactTimes[cubeID],
           now - lastImpactTime < hitCooldown {
            continue
        }

        let cubePosition = cube.position(relativeTo: nil)

        for sample in activeSamples {
            let handToCube = cubePosition - sample.position
            let distance = simd_length(handToCube)
            guard distance <= hitRadius else { continue }

            let speed = simd_length(sample.velocity)
            let direction = simd_normalize(sample.velocity)
            let falloff = max(0.2, 1.0 - distance / hitRadius)
            let impulseMagnitude = min(maxImpulse, speed * impulseMultiplier) * falloff
            let impulse = direction * impulseMagnitude + SIMD3<Float>(0, 0.08, 0)
            let angularImpulse = SIMD3<Float>(-direction.z, 0, direction.x) * impulseMagnitude * 0.16

            var motion = cube.components[PhysicsMotionComponent.self] ?? PhysicsMotionComponent()
            motion.linearVelocity += impulse / cubeMass
            motion.angularVelocity += angularImpulse
            cube.components.set(motion)
            impulseState.lastImpactTimes[cubeID] = now
            break
        }
    }
}

private func cubeEntities(in content: RealityViewContent) -> [Entity] {
    var cubes: [Entity] = []

    for entity in content.entities {
        if isCubeEntity(entity) {
            cubes.append(entity)
        }
        cubes.append(contentsOf: entity.childrenRecursive.filter(isCubeEntity))
    }

    return cubes
}

private func resetPhysicsMotion(on entity: Entity) {
    entity.components.set(PhysicsMotionComponent(
        linearVelocity: .zero,
        angularVelocity: .zero
    ))
}

private func isCubeEntity(_ entity: Entity) -> Bool {
    entity.name == "Cube" || entity.name.hasPrefix("Cube_")
}

private func cubeTransforms(in cubeScene: Entity) -> [ObjectIdentifier: Transform] {
    Dictionary(
        uniqueKeysWithValues: cubeScene.childrenRecursive
            .filter(isCubeEntity)
            .map { (ObjectIdentifier($0), $0.transform) }
    )
}

private func resetCubeScene(
    _ cubeScene: Entity,
    to transforms: [ObjectIdentifier: Transform],
    heldCubeCollisionState: HeldCubeCollisionState
) {
    for cube in cubeScene.childrenRecursive where isCubeEntity(cube) {
        guard let initialTransform = transforms[ObjectIdentifier(cube)] else { continue }

        cube.stopAllAnimations()
        cube.transform = initialTransform
        heldCubeCollisionState.restoreCollision(on: cube)
        resetPhysicsMotion(on: cube)
        setPhysicsMode(.dynamic, on: cube)
    }
}

private func makeTableCard(
    position: SIMD3<Float>,
    spriteImageName: String,
    spriteSize: SIMD2<Float>,
    spriteSurfaceOffset: SIMD2<Float>,
    spriteLift: Float,
    spritePitchDegrees: Float,
    isPhysicalModelVisible: Bool,
    cardEntityName: String,
    spriteEntityName: String
) async throws -> Entity {
    let cardRoot = Entity()
    cardRoot.name = cardEntityName
    cardRoot.position = position

    let card = try await Entity(named: "card", in: realityKitContentBundle)
    card.name = "\(cardEntityName)Model"
    card.isEnabled = isPhysicalModelVisible
    cardRoot.addChild(card)

    do {
        let sprite = try await makeCardSprite(
            imageName: spriteImageName,
            size: spriteSize,
            pitchDegrees: spritePitchDegrees,
            entityName: spriteEntityName
        )

        let bounds = card.visualBounds(relativeTo: cardRoot)
        sprite.position = [
            bounds.center.x + spriteSurfaceOffset.x,
            bounds.center.y + bounds.extents.y / 2 + spriteLift,
            bounds.center.z + spriteSurfaceOffset.y
        ]
        cardRoot.addChild(sprite)
        print("Card sprite geladen: \(spriteImageName)")
    } catch {
        print("Card sprite konnte nicht geladen werden: \(spriteImageName) - \(error.localizedDescription)")
    }

    return cardRoot
}

private func makeCardSprite(
    imageName: String,
    size: SIMD2<Float>,
    pitchDegrees: Float,
    entityName: String
) async throws -> Entity {
    let texture = try await TextureResource(named: imageName)
    let material = cardSpriteMaterial(texture: texture)

    let spriteRoot = Entity()
    spriteRoot.name = entityName
    spriteRoot.orientation = simd_quatf(angle: pitchDegrees * .pi / 180, axis: [1, 0, 0])

    let front = ModelEntity(
        mesh: .generatePlane(width: size.x, depth: size.y),
        materials: [material]
    )
    front.name = "\(entityName)Front"

    let back = ModelEntity(
        mesh: .generatePlane(width: size.x, depth: size.y),
        materials: [material]
    )
    back.name = "\(entityName)Back"
    back.orientation = simd_quatf(angle: .pi, axis: [1, 0, 0])

    spriteRoot.addChild(front)
    spriteRoot.addChild(back)
    return spriteRoot
}

@MainActor
private func updateCardSpriteImage(named imageName: String, on spriteRoot: Entity) async {
    do {
        let texture = try await TextureResource(named: imageName)
        let material = cardSpriteMaterial(texture: texture)
        setCardSpriteMaterial(material, on: spriteRoot)
        print("Card sprite gewechselt: \(imageName)")
    } catch {
        print("Card sprite konnte nicht gewechselt werden: \(imageName) - \(error.localizedDescription)")
    }
}

private func cardSpriteMaterial(texture: TextureResource) -> PhysicallyBasedMaterial {
    var material = PhysicallyBasedMaterial()
    material.baseColor = .init(texture: .init(texture))
    material.roughness = 0.85
    material.metallic = 0.0
    material.specular = 0.15
    material.blending = .transparent(opacity: 1.0)
    return material
}

private func setCardSpriteMaterial(_ material: PhysicallyBasedMaterial, on entity: Entity) {
    if var model = entity.components[ModelComponent.self] {
        model.materials = [material]
        entity.components.set(model)
    }

    for child in entity.children {
        setCardSpriteMaterial(material, on: child)
    }
}

private func stackingControlsOrientation(yawDegrees: Float, pitchDegrees: Float) -> simd_quatf {
    let yaw = simd_quatf(angle: yawDegrees * .pi / 180, axis: [0, 1, 0])
    let pitch = simd_quatf(angle: pitchDegrees * .pi / 180, axis: [1, 0, 0])
    return yaw * pitch
}

private extension Entity {
    var childrenRecursive: [Entity] {
        children + children.flatMap { $0.childrenRecursive }
    }
}

private func configureCubeScenePhysics(on cubeScene: Entity) {
    let cubeEntities = cubeScene.childrenRecursive.filter { entity in
        entity.name == "Cube" || entity.name.hasPrefix("Cube_")
    }

    let material = PhysicsMaterialResource.generate(
        friction: 1.2,
        restitution: 0.0
    )

    for cube in cubeEntities {
        let bounds = cube.visualBounds(relativeTo: cube)
        let shape = ShapeResource.generateBox(
            size: bounds.extents
        )

        var manipulation = ManipulationComponent()
        manipulation.releaseBehavior = .stay
        manipulation.audioConfiguration = .none
        manipulation.dynamics.translationBehavior = .unconstrained
        manipulation.dynamics.primaryRotationBehavior = .unconstrained
        manipulation.dynamics.secondaryRotationBehavior = .unconstrained
        manipulation.dynamics.scalingBehavior = .none
        manipulation.dynamics.inertia = .zero

        cube.components.set(CollisionComponent(shapes: [shape]))
        cube.components.set(PhysicsBodyComponent(
            massProperties: PhysicsMassProperties(shape: shape, mass: 5.0),
            material: material,
            mode: .dynamic
        ))
        cube.components.set(InputTargetComponent(allowedInputTypes: .direct))
        cube.components.set(manipulation)
    }
}

private func addImmersiveScenes(
    selectedScene: AppModel.ImmersiveScene,
    loadsOnlySelectedScene: Bool,
    basePosition: SIMD3<Float>,
    areGroundingShadowsEnabled: Bool,
    to content: RealityViewContent
) async throws -> [Entity] {
    var sceneEntities: [Entity] = []
    let scenesToLoad = loadsOnlySelectedScene ? [selectedScene] : AppModel.ImmersiveScene.allCases

    for scene in scenesToLoad {
        let entity = try await Entity(named: scene.assetName, in: realityKitContentBundle)
        entity.name = scene.entityName
        entity.position = basePosition
        entity.isEnabled = scene == selectedScene
        
        if scene == .cube {
            configureCubeScenePhysics(on: entity)
        }
        
        setGroundingShadows(
            areGroundingShadowsEnabled,
            on: entity,
            castsShadow: true,
            receivesShadow: true
        )
        setDynamicLightShadows(true, on: entity)
        content.add(entity)
        sceneEntities.append(entity)
    }

    return sceneEntities
}

private func immersiveSceneEntities(in content: RealityViewContent) -> [Entity] {
    AppModel.ImmersiveScene.allCases.compactMap { scene in
        content.entities.first(where: { $0.name == scene.entityName })
    }
}

private func setActiveImmersiveScene(
    _ selectedScene: AppModel.ImmersiveScene,
    in sceneEntities: [Entity]
) {
    for scene in AppModel.ImmersiveScene.allCases {
        sceneEntities.first(where: { $0.name == scene.entityName })?.isEnabled = scene == selectedScene
    }
}

@MainActor
private func importEnvironmentProbeDataset(appModel: AppModel) {
    guard let importURL = appModel.environmentProbeImportDatasetURL else { return }
    appModel.environmentProbeReader.importDataset(appModel: appModel, from: importURL)
}

private func setEntity(
    _ isEnabled: Bool,
    named name: String,
    in content: RealityViewContent
) {
    content.entities.first(where: { $0.name == name })?.isEnabled = isEnabled
}

private func addEstimatedLightDebugSpheres(
    appModel: AppModel,
    namePrefix: String,
    to content: RealityViewContent
) {
    for index in 0..<4 {
        let estimatedLight = appModel.brightRegionEstimatedLights[safe: index]
        let sphere = ModelEntity(
            mesh: .generateSphere(radius: index == 0 ? 0.14 : 0.1),
            materials: [estimatedLightDebugMaterial(color: estimatedLightDebugSphereColor(
                appModel: appModel,
                estimatedLight: estimatedLight
            ))]
        )
        sphere.name = "\(namePrefix)-\(index)"
        updateEstimatedLightDebugSphere(
            sphere,
            appModel: appModel,
            estimatedLight: estimatedLight,
            index: index
        )
        content.add(sphere)
    }
}

private func updateEstimatedLightDebugSpheres(
    appModel: AppModel,
    namePrefix: String,
    in content: RealityViewContent
) {
    for index in 0..<4 {
        guard let sphere = content.entities.first(where: { $0.name == "\(namePrefix)-\(index)" }) as? ModelEntity else {
            continue
        }

        updateEstimatedLightDebugSphere(
            sphere,
            appModel: appModel,
            estimatedLight: appModel.brightRegionEstimatedLights[safe: index],
            index: index
        )
    }
}

private func updateEstimatedLightDebugSphere(
    _ sphere: ModelEntity,
    appModel: AppModel,
    estimatedLight: BrightRegionEstimatedLightState?,
    index: Int
) {
    let position = estimatedLight?.position ?? appModel.brightRegionEstimatedLightPosition
    let displayPosition = estimatedLightDebugSpherePosition(
        from: position,
        appModel: appModel
    )
    let color = estimatedLightDebugSphereColor(appModel: appModel, estimatedLight: estimatedLight)

    sphere.isEnabled = isEstimatedLightDebugSphereEnabled(appModel: appModel, index: index)
    sphere.position = displayPosition
    sphere.model?.materials = [estimatedLightDebugMaterial(color: color)]
    sphere.components.set(DynamicLightShadowComponent(castsShadow: false))
    sphere.components.set(GroundingShadowComponent(castsShadow: false, receivesShadow: false))
}

private func estimatedLightDebugSpherePosition(
    from estimatedPosition: SIMD3<Float>,
    appModel: AppModel
) -> SIMD3<Float> {
    guard appModel.brightRegionEstimatedLightType == .spot else {
        return estimatedPosition
    }

    return spotLightRenderPosition(
        from: estimatedPosition,
        clampAnchor: appModel.environmentProbePositionOverride,
        appModel: appModel
    )
}

private func isEstimatedLightDebugSphereEnabled(appModel: AppModel, index: Int) -> Bool {
    guard appModel.areLightProbeDebugSpheresVisible else {
        return false
    }

    guard appModel.hasBrightRegionEstimatedLight else {
        return false
    }

    guard appModel.brightRegionEstimatedLights[safe: index]?.isPlacementResolved == true else {
        return false
    }

    switch appModel.brightRegionEstimatedLightType {
    case .directional:
        return index < appModel.brightRegionEstimatedDirectionalLightCount
            && index < appModel.brightRegionEstimatedLights.count
    case .spot:
        return index < appModel.brightRegionEstimatedSpotLightCount
            && index < appModel.brightRegionEstimatedLights.count
    }
}

private func addRejectedEstimatedLightPositionDebugSpheres(
    appModel: AppModel,
    namePrefix: String,
    to content: RealityViewContent
) {
    for index in 0..<20 {
        let sphere = ModelEntity(
            mesh: .generateSphere(radius: 0.08),
            materials: [estimatedLightDebugMaterial(color: stableIDDebugColor(for: 1))]
        )
        sphere.name = "\(namePrefix)-\(index)"
        sphere.isEnabled = false
        sphere.components.set(DynamicLightShadowComponent(castsShadow: false))
        sphere.components.set(GroundingShadowComponent(castsShadow: false, receivesShadow: false))
        content.add(sphere)
    }

    updateRejectedEstimatedLightPositionDebugSpheres(
        appModel: appModel,
        namePrefix: namePrefix,
        in: content
    )
}

private func updateRejectedEstimatedLightPositionDebugSpheres(
    appModel: AppModel,
    namePrefix: String,
    in content: RealityViewContent
) {
    let samples = appModel.areRejectedLightPositionDebugSpheresVisible
        && appModel.usesStableIDDebugColors
        ? appModel.stableLightRejectedPositionDebugSamples
        : []

    for index in 0..<20 {
        guard let sphere = content.entities.first(where: { $0.name == "\(namePrefix)-\(index)" }) as? ModelEntity else {
            continue
        }

        guard index < samples.count else {
            sphere.isEnabled = false
            continue
        }

        let sample = samples[index]
        sphere.isEnabled = appModel.isStableLightPositionMinimumChangeEnabled
            && appModel.areRejectedLightPositionDebugSpheresVisible
            && appModel.usesStableIDDebugColors
        sphere.position = sample.position
        sphere.model?.materials = [estimatedLightDebugMaterial(color: stableIDDebugColor(for: sample.stableID))]
    }
}

private func estimatedLightDebugSphereColor(
    appModel: AppModel,
    estimatedLight: BrightRegionEstimatedLightState?
) -> SIMD3<Float> {
    guard
        appModel.usesStableIDDebugColors,
        let stableID = estimatedLight?.sourceRegionStableID,
        stableID > 0
    else {
        return estimatedLight?.color ?? appModel.brightRegionEstimatedLightColor
    }

    return stableIDDebugColor(for: stableID)
}

private func stableIDDebugColor(for stableID: Int) -> SIMD3<Float> {
    let palette: [SIMD3<Float>] = [
        SIMD3<Float>(1.0, 0.12, 0.08),
        SIMD3<Float>(0.1, 0.38, 1.0),
        SIMD3<Float>(0.0, 0.78, 0.22),
        SIMD3<Float>(1.0, 0.72, 0.0),
        SIMD3<Float>(1.0, 0.18, 0.76),
        SIMD3<Float>(0.0, 0.8, 0.86),
        SIMD3<Float>(1.0, 0.42, 0.05),
        SIMD3<Float>(0.55, 0.3, 1.0)
    ]
    return palette[(stableID - 1) % palette.count]
}

private func addProbePositionDebugSphere(
    appModel: AppModel,
    name: String,
    to content: RealityViewContent
) {
    let sphere = ModelEntity(
        mesh: .generateSphere(radius: 0.06),
        materials: [probePositionDebugMaterial()]
    )
    sphere.name = name
    sphere.position = appModel.brightRegionProbePosition
    sphere.isEnabled = appModel.hasEnvironmentProbeTexture && appModel.areLightProbeDebugSpheresVisible
    sphere.components.set(DynamicLightShadowComponent(castsShadow: false))
    sphere.components.set(GroundingShadowComponent(castsShadow: false, receivesShadow: false))
    content.add(sphere)
}

private func updateProbePositionDebugSphere(
    appModel: AppModel,
    named name: String,
    in content: RealityViewContent
) {
    guard let sphere = content.entities.first(where: { $0.name == name }) as? ModelEntity else {
        return
    }

    sphere.isEnabled = appModel.hasEnvironmentProbeTexture && appModel.areLightProbeDebugSpheresVisible
    sphere.position = appModel.brightRegionProbePosition
    sphere.components.set(DynamicLightShadowComponent(castsShadow: false))
    sphere.components.set(GroundingShadowComponent(castsShadow: false, receivesShadow: false))
}

private func addSceneProbePositionDebugSphere(
    appModel: AppModel,
    name: String,
    to content: RealityViewContent
) {
    let sphere = ModelEntity(
        mesh: .generateSphere(radius: 0.045),
        materials: [sceneProbePositionDebugMaterial()]
    )
    sphere.name = name
    sphere.position = appModel.environmentProbePositionOverride
    sphere.isEnabled = appModel.hasEnvironmentProbeTexture && appModel.areLightProbeDebugSpheresVisible
    sphere.components.set(DynamicLightShadowComponent(castsShadow: false))
    sphere.components.set(GroundingShadowComponent(castsShadow: false, receivesShadow: false))
    content.add(sphere)
}

private func updateSceneProbePositionDebugSphere(
    appModel: AppModel,
    named name: String,
    in content: RealityViewContent
) {
    guard let sphere = content.entities.first(where: { $0.name == name }) as? ModelEntity else {
        return
    }

    sphere.isEnabled = appModel.hasEnvironmentProbeTexture && appModel.areLightProbeDebugSpheresVisible
    sphere.position = appModel.environmentProbePositionOverride
    sphere.components.set(DynamicLightShadowComponent(castsShadow: false))
    sphere.components.set(GroundingShadowComponent(castsShadow: false, receivesShadow: false))
}

private func addEstimatedDirectionalLights(
    appModel: AppModel,
    target: Entity,
    namePrefix: String,
    to content: RealityViewContent
) {
    for index in 0..<4 {
        let estimatedLight = appModel.brightRegionEstimatedLights[safe: index]
        let light = makeEstimatedDirectionalLight(
            appModel: appModel,
            estimatedLight: estimatedLight,
            target: target,
            index: index
        )
        light.name = "\(namePrefix)-\(index)"
        light.isEnabled = isEstimatedDirectionalLightEnabled(
            appModel: appModel,
            index: index
        )
        content.add(light)
    }
}

private func updateEstimatedDirectionalLights(
    appModel: AppModel,
    target: Entity,
    namePrefix: String,
    in content: RealityViewContent
) {
    var activeLightCount = 0
    var totalIntensity: Float = 0

    for index in 0..<4 {
        guard let light = content.entities.first(where: { $0.name == "\(namePrefix)-\(index)" }) as? DirectionalLight else {
            continue
        }

        let estimatedLight = appModel.brightRegionEstimatedLights[safe: index]
        updateEstimatedDirectionalLight(
            light,
            appModel: appModel,
            estimatedLight: estimatedLight,
            target: target,
            index: index
        )

        if light.isEnabled {
            activeLightCount += 1
            totalIntensity += light.light.intensity
        }
    }

    if appModel.brightRegionEstimatedLightType == .directional {
        appModel.brightRegionEstimatedLightTotalIntensityDebugLine = estimatedLightTotalIntensityDebugLine(
            lightTypeTitle: "Directional",
            activeLightCount: activeLightCount,
            totalIntensity: totalIntensity
        )
    }
}

private func makeEstimatedDirectionalLight(
    appModel: AppModel,
    estimatedLight: BrightRegionEstimatedLightState?,
    target: Entity,
    index: Int
) -> DirectionalLight {
    let light = DirectionalLight()
    updateEstimatedDirectionalLight(
        light,
        appModel: appModel,
        estimatedLight: estimatedLight,
        target: target,
        index: index
    )
    return light
}

private func updateEstimatedDirectionalLight(
    _ light: DirectionalLight,
    appModel: AppModel,
    estimatedLight: BrightRegionEstimatedLightState?,
    target: Entity,
    index: Int
) {
    let position = estimatedLight?.position ?? appModel.brightRegionEstimatedLightPosition
    let activeLightCount = max(1, min(
        appModel.brightRegionEstimatedDirectionalLightCount,
        appModel.brightRegionEstimatedLights.count
    ))
    let intensity = estimatedLight.map {
        estimatedDirectionalLightLux(
            from: $0.intensity,
            multiplier: appModel.brightRegionEstimatedDirectionalLightLuxMultiplier
        ) * $0.heightMultiplier * estimatedDirectionalLightIntensityMultiplier(
            appModel: appModel,
            index: index,
            activeLightCount: activeLightCount
        )
    } ?? appModel.brightRegionAdjustedDirectionalLightLux
    let color = estimatedLight?.color ?? appModel.brightRegionEstimatedLightColor

    light.isEnabled = isEstimatedDirectionalLightEnabled(appModel: appModel, index: index)
    light.position = position
    light.light.intensity = intensity
    light.light.color = estimatedLightUIColor(color: color)
    light.look(at: target.position, from: position, relativeTo: nil)
    if shouldEstimatedDirectionalLightCastShadow(appModel: appModel, index: index) {
        light.shadow = estimatedDirectionalLightShadow(
            appModel: appModel,
            estimatedLight: estimatedLight
        )
    } else {
        light.shadow = nil
    }
}

private func isEstimatedDirectionalLightEnabled(appModel: AppModel, index: Int) -> Bool {
    appModel.isEstimatedEnvironmentLightRenderingEnabled
        && appModel.hasBrightRegionEstimatedLight
        && appModel.brightRegionEstimatedLightType == .directional
        && index < appModel.brightRegionEstimatedDirectionalLightCount
        && index < appModel.brightRegionEstimatedLights.count
        && appModel.brightRegionEstimatedLights[safe: index]?.isPlacementResolved == true
}

private func shouldEstimatedDirectionalLightCastShadow(appModel: AppModel, index: Int) -> Bool {
    appModel.areEstimatedDirectionalLightShadowsEnabled
        && (!appModel.castsOnlyDominantEstimatedDirectionalLightShadow || index == 0)
}

private func estimatedDirectionalLightLux(from estimatedIntensity: Float, multiplier: Float) -> Float {
    min(max(estimatedIntensity * 125, 500), 20_000) * multiplier
}

private func estimatedDirectionalLightIntensityMultiplier(
    appModel: AppModel,
    index: Int,
    activeLightCount: Int
) -> Float {
    let sanitizedActiveLightCount = max(activeLightCount, 1)

    switch appModel.brightRegionSpotLightIntensityDistributionMode {
    case .full:
        return 1
    case .dividedByLightCount:
        return 1 / Float(sanitizedActiveLightCount)
    case .dominantWithReducedSecondary:
        guard sanitizedActiveLightCount > 1 else {
            return 1
        }

        return index == 0 ? 0.5 : 0.5 / Float(sanitizedActiveLightCount - 1)
    }
}

private func addEstimatedSpotLights(
    appModel: AppModel,
    target: Entity,
    namePrefix: String,
    to content: RealityViewContent
) {
    for index in 0..<4 {
        let estimatedLight = appModel.brightRegionEstimatedLights[safe: index]
        let light = makeEstimatedSpotLight(
            appModel: appModel,
            estimatedLight: estimatedLight,
            target: target,
            index: index
        )
        light.name = "\(namePrefix)-\(index)"
        light.isEnabled = isEstimatedSpotLightEnabled(appModel: appModel, index: index)
        content.add(light)
    }
}

private func updateEstimatedSpotLights(
    appModel: AppModel,
    target: Entity,
    namePrefix: String,
    in content: RealityViewContent
) {
    var activeLightCount = 0
    var totalIntensity: Float = 0

    for index in 0..<4 {
        guard let light = content.entities.first(where: { $0.name == "\(namePrefix)-\(index)" }) as? SpotLight else {
            continue
        }

        updateEstimatedSpotLight(
            light,
            appModel: appModel,
            estimatedLight: appModel.brightRegionEstimatedLights[safe: index],
            target: target,
            index: index
        )

        if light.isEnabled {
            activeLightCount += 1
            totalIntensity += light.light.intensity
        }
    }

    if appModel.brightRegionEstimatedLightType == .spot {
        appModel.brightRegionEstimatedLightTotalIntensityDebugLine = estimatedLightTotalIntensityDebugLine(
            lightTypeTitle: "Spot",
            activeLightCount: activeLightCount,
            totalIntensity: totalIntensity
        )
    }
}

private func estimatedLightTotalIntensityDebugLine(
    lightTypeTitle: String,
    activeLightCount: Int,
    totalIntensity: Float
) -> String {
    "Gesamthelligkeit \(lightTypeTitle): \(String(format: "%.0f", totalIntensity)) lux | aktiv: \(activeLightCount)"
}

private func makeEstimatedSpotLight(
    appModel: AppModel,
    estimatedLight: BrightRegionEstimatedLightState?,
    target: Entity,
    index: Int
) -> SpotLight {
    let light = SpotLight()
    updateEstimatedSpotLight(
        light,
        appModel: appModel,
        estimatedLight: estimatedLight,
        target: target,
        index: index
    )
    return light
}

private func updateEstimatedSpotLight(
    _ light: SpotLight,
    appModel: AppModel,
    estimatedLight: BrightRegionEstimatedLightState?,
    target: Entity,
    index: Int
) {
    let position = estimatedLight?.position ?? appModel.brightRegionEstimatedLightPosition
    let activeLightCount = max(1, min(
        appModel.brightRegionEstimatedSpotLightCount,
        appModel.brightRegionEstimatedLights.count
    ))
    let intensity = estimatedLight.map {
        min(max(estimatedSpotLightSourceLux(
            for: $0,
            appModel: appModel
        ), 500), 20_000) * estimatedSpotLightIntensityMultiplier(
            appModel: appModel,
            index: index,
            activeLightCount: activeLightCount
        )
    } ?? appModel.brightRegionAdjustedDirectionalLightLux
    let color = estimatedLight?.color ?? appModel.brightRegionEstimatedLightColor
    let renderPosition = spotLightRenderPosition(
        from: position,
        clampAnchor: appModel.environmentProbePositionOverride,
        appModel: appModel
    )

    light.isEnabled = isEstimatedSpotLightEnabled(appModel: appModel, index: index)
    light.position = renderPosition
    light.light.intensity = intensity
    light.light.color = estimatedLightUIColor(color: color)
    light.look(at: target.position, from: renderPosition, relativeTo: nil)
    let outerAngleInDegrees = estimatedSpotLightOuterAngleInDegrees(
        appModel: appModel,
        estimatedLight: estimatedLight
    )
    light.light.innerAngleInDegrees = min(
        appModel.brightRegionEstimatedSpotLightInnerAngleInDegrees,
        outerAngleInDegrees - 1
    )
    light.light.outerAngleInDegrees = outerAngleInDegrees
    light.light.attenuationRadius = appModel.brightRegionEstimatedSpotLightAttenuationRadius
    light.light.attenuationFalloffExponent = appModel.brightRegionEstimatedSpotLightAttenuationFalloffExponent
    if shouldEstimatedSpotLightCastShadow(appModel: appModel, index: index) {
        light.shadow = SpotLightComponent.Shadow()
        light.shadow?.depthBias = appModel.brightRegionEstimatedSpotLightDepthBias
    } else {
        light.shadow = nil
    }
}

private func spotLightRenderPosition(
    from estimatedPosition: SIMD3<Float>,
    clampAnchor: SIMD3<Float>,
    appModel: AppModel
) -> SIMD3<Float> {
    guard appModel.isEstimatedSpotLightShadowPositionClampEnabled else {
        return estimatedPosition
    }

    let offset = estimatedPosition - clampAnchor
    let distance = simd_length(offset)
    let maxDistance = max(appModel.estimatedSpotLightShadowPositionMaxDistance, 0.01)
    guard distance > maxDistance, distance > 0.0001 else {
        return estimatedPosition
    }

    return clampAnchor + simd_normalize(offset) * maxDistance
}

private func isEstimatedSpotLightEnabled(appModel: AppModel, index: Int) -> Bool {
    appModel.isEstimatedEnvironmentLightRenderingEnabled
        && appModel.hasBrightRegionEstimatedLight
        && appModel.brightRegionEstimatedLightType == .spot
        && index < appModel.brightRegionEstimatedSpotLightCount
        && index < appModel.brightRegionEstimatedLights.count
        && appModel.brightRegionEstimatedLights[safe: index]?.isPlacementResolved == true
}

private func shouldEstimatedSpotLightCastShadow(appModel: AppModel, index: Int) -> Bool {
    appModel.areEstimatedSpotLightShadowsEnabled
        && (!appModel.castsOnlyDominantEstimatedSpotLightShadow || index == 0)
}

private func estimatedSpotLightIntensityMultiplier(
    appModel: AppModel,
    index: Int,
    activeLightCount: Int
) -> Float {
    switch appModel.brightRegionSpotLightIntensityDistributionMode {
    case .full:
        1
    case .dividedByLightCount:
        1 / Float(max(activeLightCount, 1))
    case .dominantWithReducedSecondary:
        index == 0 ? 1 : 0.5
    }
}

private func estimatedSpotLightSourceLux(
    for estimatedLight: BrightRegionEstimatedLightState,
    appModel: AppModel
) -> Float {
    let noHitDistanceFallback: Float = 4.0
    let observedLux = estimatedLight.intensity
        * 500
        * appModel.brightRegionEstimatedDirectionalLightLuxMultiplier
    let distance = appModel.brightRegionDistanceEstimates[estimatedLight.sourceRegionIndex]
        ?? noHitDistanceFallback
    let clampedDistance = min(max(distance, 0.35), 6)

    return observedLux * clampedDistance * clampedDistance
        * estimatedLight.heightMultiplier
}

private func estimatedSpotLightOuterAngleInDegrees(
    appModel: AppModel,
    estimatedLight: BrightRegionEstimatedLightState?
) -> Float {
    let maximumOuterAngle = appModel.brightRegionEstimatedSpotLightOuterAngleInDegrees
    if appModel.brightRegionShadowSoftnessMode == .orthographicScale {
        return maximumOuterAngle
    }

    guard let estimatedLight else {
        return maximumOuterAngle
    }

    let minimumOuterAngle = min(
        maximumOuterAngle,
        max(1, appModel.brightRegionEstimatedSpotLightInnerAngleInDegrees + 1)
    )
    return minimumOuterAngle + (maximumOuterAngle - minimumOuterAngle) * estimatedLight.shadowSoftness
}

private func estimatedDirectionalLightShadow(
    appModel: AppModel,
    estimatedLight: BrightRegionEstimatedLightState?
) -> DirectionalLightComponent.Shadow {
    let softness = min(max(estimatedLight?.shadowSoftness ?? 0, 0), 1)
    let projectionSoftnessMultiplier = 0.75 + softness * 0.75
    let usesOrthographicScaleSlider = appModel.usesFixedDirectionalShadowOrthographicScale
        || appModel.brightRegionShadowSoftnessMode == .orthographicScale
    let fixedOrthographicScale = usesOrthographicScaleSlider
        ? appModel.brightRegionEstimatedLightShadowFixedOrthographicScale
        : 4 + softness * 8
    let shadowProjectionMode: BrightRegionShadowProjectionMode = usesOrthographicScaleSlider
        ? .fixed
        : appModel.brightRegionEstimatedLightShadowProjectionMode

    switch shadowProjectionMode {
    case .automatic:
        return DirectionalLightComponent.Shadow(
            shadowProjection: .automatic(
                maximumDistance: appModel.brightRegionEstimatedLightShadowMaximumDistance
                    * projectionSoftnessMultiplier
            ),
            depthBias: appModel.brightRegionEstimatedLightShadowDepthBias
        )
    case .fixed:
        return DirectionalLightComponent.Shadow(
            shadowProjection: .fixed(
                zNear: appModel.brightRegionEstimatedLightShadowFixedZNear,
                zFar: appModel.brightRegionEstimatedLightShadowFixedZFar,
                orthographicScale: fixedOrthographicScale
            ),
            depthBias: appModel.brightRegionEstimatedLightShadowDepthBias
        )
    }
}

private func estimatedLightDebugMaterial(color: SIMD3<Float>) -> SimpleMaterial {
    SimpleMaterial(color: estimatedLightUIColor(color: color), roughness: 0.2, isMetallic: false)
}

private func probePositionDebugMaterial() -> SimpleMaterial {
    SimpleMaterial(color: UIColor.cyan, roughness: 0.2, isMetallic: false)
}

private func sceneProbePositionDebugMaterial() -> SimpleMaterial {
    SimpleMaterial(color: UIColor.magenta, roughness: 0.2, isMetallic: false)
}

private func estimatedLightUIColor(color: SIMD3<Float>) -> UIColor {
    let clampedColor = SIMD3<Float>(
        min(max(color.x, 0), 1),
        min(max(color.y, 0), 1),
        min(max(color.z, 0), 1)
    )
    return UIColor(
        red: CGFloat(clampedColor.x),
        green: CGFloat(clampedColor.y),
        blue: CGFloat(clampedColor.z),
        alpha: 1
    )
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private func makeGeneratedImageBasedLight(
    named imageName: String,
    intensityExponent: Float
) async throws -> Entity {
    let cgImage = try loadEXRImage(named: imageName)
    let environment = try await EnvironmentResource(
        equirectangular: cgImage,
        withName: "\(imageName)-generated-ibl"
    )

    let iblEntity = Entity()
    iblEntity.name = "\(imageName)-generated-ibl"
    iblEntity.components.set(ImageBasedLightComponent(
        source: .single(environment),
        intensityExponent: intensityExponent
    ))

    return iblEntity
}

private func addCustomImageBasedLight(
    named imageName: String,
    intensityExponent: Float = 0.0,
    entityName: String,
    in content: RealityViewContent
) async throws {
    let iblEntity = try await makeGeneratedImageBasedLight(
        named: imageName,
        intensityExponent: intensityExponent
    )
    iblEntity.name = entityName
    content.add(iblEntity)
}

private func loadEXRImage(named imageName: String) throws -> CGImage {
    guard let url = Bundle.main.url(forResource: imageName, withExtension: "exr") else {
        throw NSError(
            domain: "ARLightingStudy",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(imageName).exr wurde im App-Bundle nicht gefunden."]
        )
    }

    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else {
        throw NSError(
            domain: "ARLightingStudy",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) konnte nicht als HDR-Bild geladen werden."]
        )
    }

    return cgImage
}

private func applyImageBasedLightReceiver(_ imageBasedLight: Entity, to entity: Entity) {
    if entity.components[ModelComponent.self] != nil {
        entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: imageBasedLight))
        entity.components.set(EnvironmentLightingConfigurationComponent(environmentLightingWeight: 0.0))
    }

    for child in entity.children {
        applyImageBasedLightReceiver(imageBasedLight, to: child)
    }
}

private func removeImageBasedLightReceiver(from entity: Entity) {
    if entity.components[ModelComponent.self] != nil {
        entity.components.remove(ImageBasedLightReceiverComponent.self)
    }

    for child in entity.children {
        removeImageBasedLightReceiver(from: child)
    }
}

private func setCustomImageBasedLightReceiver(
    _ isEnabled: Bool,
    imageBasedLight: Entity?,
    on entity: Entity
) {
    guard isEnabled, let imageBasedLight else {
        removeImageBasedLightReceiver(from: entity)
        return
    }

    applyImageBasedLightReceiver(imageBasedLight, to: entity)
}

private func setEnvironmentLighting(
    _ isEnabled: Bool,
    on entity: Entity,
    weight: Float = 1.0
) {
    if entity.components[ModelComponent.self] != nil {
        entity.components.set(EnvironmentLightingConfigurationComponent(
            environmentLightingWeight: isEnabled ? weight : 0.0
        ))
    }

    for child in entity.children {
        setEnvironmentLighting(isEnabled, on: child, weight: weight)
    }
}

private func setGroundingShadows(
    _ isEnabled: Bool,
    on entity: Entity,
    castsShadow: Bool = true,
    receivesShadow: Bool = true
) {
    if entity.components[ModelComponent.self] != nil {
        entity.components.set(GroundingShadowComponent(
            castsShadow: isEnabled && castsShadow,
            receivesShadow: isEnabled && receivesShadow
        ))
    }

    for child in entity.children {
        setGroundingShadows(
            isEnabled,
            on: child,
            castsShadow: castsShadow,
            receivesShadow: receivesShadow
        )
    }
}

private func applyPlaneMaterial(to entity: Entity) {
    if var model = entity.components[ModelComponent.self] {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(white: 0.82, alpha: 0.0))
        material.roughness = 1.0
        material.metallic = 0.0
        material.specular = 0.0
        material.sheen = nil
        material.blending = .transparent(opacity: 0.0)
        model.materials = [material]
        entity.components.set(model)
    }

    for child in entity.children {
        applyPlaneMaterial(to: child)
    }
}

private func setDynamicLightShadows(
    _ isEnabled: Bool,
    on entity: Entity
) {
    if entity.components[ModelComponent.self] != nil {
        entity.components.set(DynamicLightShadowComponent(castsShadow: isEnabled))
    }

    for child in entity.children {
        setDynamicLightShadows(isEnabled, on: child)
    }
}

private func configureStaticBoxPhysics(on entity: Entity, colliderName: String) {
    let bounds = entity.visualBounds(relativeTo: entity)

    let colliderEntity = Entity()
    colliderEntity.name = colliderName
    colliderEntity.position = bounds.center

    let shape = ShapeResource.generateBox(size: bounds.extents)

    colliderEntity.components.set(CollisionComponent(shapes: [shape]))
    colliderEntity.components.set(PhysicsBodyComponent(
        massProperties: .default,
        material: .default,
        mode: .static
    ))

    entity.addChild(colliderEntity)
}

private func addColliderDebugBox(
    to parent: Entity,
    size: SIMD3<Float>,
    center: SIMD3<Float>,
    color: UIColor
) {
    let material = UnlitMaterial(color: color)

    let debugBox = ModelEntity(
        mesh: .generateBox(size: size),
        materials: [material]
    )

    debugBox.name = "\(parent.name)ColliderDebugBox"
    debugBox.position = center
    parent.addChild(debugBox)
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}
