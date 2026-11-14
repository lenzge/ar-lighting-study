//
//  AppModel.swift
//  AR-Lighting-Study
//
//  Owns the observable state shared by views, AR services, and experiments.
//  It also applies presets and coordinates the user-test and performance-test workflows.

import SwiftUI
import Foundation
import simd

struct StackingQuestionnaire {
    static let questions = [
        "Ich habe mich in der Umgebung wohl gefühlt.",
        "Ich kam mit der Aufgabe gut zurecht.",
        "Die virtuellen Objekte verhielten sich so, wie ich es erwartet habe.",
        "Die virtuelle Szene fügte sich glaubwürdig in den realen Raum ein.",
        "Die Szene war visuell ansprechend.",
        "Während des Spiels habe ich störende Auffälligkeiten bemerkt."
    ]
}

struct StackingQuestionnaireAnswer: Codable {
    let questionIndex: Int
    let question: String
    let rating: Int?
}

struct StackingQuestionnaireResponse: Codable {
    let responseKind: String
    let recordedAt: Date
    let presetID: String
    let presetTitle: String
    let isExtraLevel: Bool
    let answers: [StackingQuestionnaireAnswer]
}

struct StackingQuestionnaireSession: Codable {
    let sessionID: String
    let sessionStartedAt: Date
    let responses: [StackingQuestionnaireResponse]
}

struct BrightRegionPlaneHitDebugSample: Identifiable, Equatable {
    let id: String
    let regionIndex: Int
    let regionDisplayIndex: Int
    let sampleIndex: Int
    let face: Int
    let direction: SIMD3<Float>
    let luminance: Float
}

struct BrightRegionEstimatedLightState: Identifiable, Equatable {
    let id: Int
    let sourceRegionIndex: Int
    let sourceRegionStableID: Int
    let direction: SIMD3<Float>
    let position: SIMD3<Float>
    let isPlacementResolved: Bool
    let color: SIMD3<Float>
    let intensity: Float
    let heightMultiplier: Float
    let sourceSizePixels: Float
    let shadowSoftness: Float
}

struct StableLightRejectedPositionDebugSample: Identifiable, Equatable {
    let id: String
    let stableID: Int
    let sampleIndex: Int
    let position: SIMD3<Float>
}

struct BrightRegionPositionEvaluation: Equatable {
    let placementRequestID: Int
    let stableID: Int
    let rawPosition: SIMD3<Float>
    let candidatePosition: SIMD3<Float>
    let outputPosition: SIMD3<Float>
    let wasSuppressed: Bool
}

enum BrightRegionDominanceScoreMode: String, CaseIterable, Identifiable {
    case totalLuminance
    case balancedArea
    case averageLuminance

    var id: Self { self }

    var title: String {
        switch self {
        case .totalLuminance: "Score 1: Total"
        case .balancedArea: "Score 2: Balanced"
        case .averageLuminance: "Score 3: Average"
        }
    }
}

enum BrightRegionDistanceScoreMode: String, CaseIterable, Identifiable {
    case off
    case squared
    case cubed

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "Aus"
        case .squared: "hoch2"
        case .cubed: "hoch3"
        }
    }
}

enum BrightRegionDirectionMode: String, CaseIterable, Identifiable {
    case unweighted
    case luminanceWeighted

    var id: Self { self }

    var title: String {
        switch self {
        case .unweighted: "Baseline"
        case .luminanceWeighted: "M1 gewichtet"
        }
    }
}

enum BrightRegionColorMode: String, CaseIterable, Identifiable {
    case average
    case luminanceWeighted
    case brightestPixel

    var id: Self { self }

    var title: String {
        switch self {
        case .average: "Average"
        case .luminanceWeighted: "Helligkeit"
        case .brightestPixel: "Hellster Pixel"
        }
    }
}

enum BrightRegionShadowSoftnessMode: String, CaseIterable, Identifiable {
    case size
    case peakAverage
    case both
    case orthographicScale

    var id: Self { self }

    var title: String {
        switch self {
        case .size: "Pixel"
        case .peakAverage: "Peak/Avg"
        case .both: "Both"
        case .orthographicScale: "Regler"
        }
    }
}

enum BrightRegionLightSourceOriginMode: String, CaseIterable, Identifiable {
    case geometryHitOrSceneProbe
    case sceneProbePosition
    case environmentProbePosition

    var id: Self { self }

    var title: String {
        switch self {
        case .geometryHitOrSceneProbe: "Auto"
        case .sceneProbePosition: "Lila Kugel"
        case .environmentProbePosition: "Blaue Kugel"
        }
    }
}

enum BrightRegionShadowProjectionMode: String, CaseIterable, Identifiable {
    case automatic
    case fixed

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .fixed: "Fixed"
        }
    }
}

enum BrightRegionEstimatedLightType: String, CaseIterable, Identifiable {
    case directional
    case spot

    var id: Self { self }

    var title: String {
        switch self {
        case .directional: "Directional"
        case .spot: "Spot"
        }
    }
}

enum BrightRegionSpotLightIntensityDistributionMode: String, CaseIterable, Identifiable {
    case full
    case dividedByLightCount
    case dominantWithReducedSecondary

    var id: Self { self }

    var title: String {
        switch self {
        case .full: "Voll"
        case .dividedByLightCount: "/ Anzahl"
        case .dominantWithReducedSecondary: "Haupt + Fill"
        }
    }
}

enum PerformanceStressScenario: String, CaseIterable, Identifiable {
    case environmentAndGrounding
    case oneDirectionalOneShadow
    case threeDirectionalsOneShadow
    case threeDirectionalsThreeShadows

    var id: Self { self }

    var title: String {
        switch self {
        case .environmentAndGrounding: "Environment + Grounding"
        case .oneDirectionalOneShadow: "1 Directional, 1 Schatten"
        case .threeDirectionalsOneShadow: "3 Directionals, 1 Schatten"
        case .threeDirectionalsThreeShadows: "3 Directionals, 3 Schatten"
        }
    }

    var filenameComponent: String { rawValue }

    var directionalLightCount: Int {
        switch self {
        case .environmentAndGrounding: 0
        case .oneDirectionalOneShadow: 1
        case .threeDirectionalsOneShadow, .threeDirectionalsThreeShadows: 3
        }
    }

    var dynamicShadowCount: Int {
        switch self {
        case .environmentAndGrounding: 0
        case .oneDirectionalOneShadow, .threeDirectionalsOneShadow: 1
        case .threeDirectionalsThreeShadows: 3
        }
    }
}

enum FPSStressTestPhase {
    case idle
    case warmingUp
    case measuring
}

enum TemporalStabilityTestMode: String, CaseIterable, Identifiable {
    case raw
    case stabilized

    var id: Self { self }

    var title: String {
        switch self {
        case .raw: "Ohne Stabilisierung"
        case .stabilized: "Mit Stabilisierung"
        }
    }

    var filenameComponent: String { rawValue }
}

struct BrightRegionTestPreset: Identifiable {
    let id: String
    let title: String
    let dominanceScoreMode: BrightRegionDominanceScoreMode
    let distanceScoreMode: BrightRegionDistanceScoreMode
    let directionMode: BrightRegionDirectionMode
    let colorMode: BrightRegionColorMode
    let whiteMix: Float
    let lightSourceOriginMode: BrightRegionLightSourceOriginMode
    let ignoresGeometry: Bool
    let isHeightPriorEnabled: Bool
    let shadowSoftnessMode: BrightRegionShadowSoftnessMode
    let estimatedLightType: BrightRegionEstimatedLightType
    let spotLightCount: Int
    let spotIntensityDistributionMode: BrightRegionSpotLightIntensityDistributionMode
    let castsOnlyDominantSpotShadow: Bool
    let isEstimatedEnvironmentLightRenderingEnabled: Bool
    let areGroundingShadowsEnabled: Bool
    let isEnvironmentLightingEnabled: Bool
    let environmentLightingWeight: Float
    let areEstimatedDirectionalLightShadowsEnabled: Bool
    let areEstimatedSpotLightShadowsEnabled: Bool
    let fixedDirectionalShadowOrthographicScale: Float?

    var displayID: String {
        guard let index = Self.all.firstIndex(where: { $0.id == id }) else {
            return id
        }

        return String(format: "L%02d", index + 1)
    }

    init(
        id: String,
        title: String,
        dominanceScoreMode: BrightRegionDominanceScoreMode,
        distanceScoreMode: BrightRegionDistanceScoreMode,
        directionMode: BrightRegionDirectionMode,
        colorMode: BrightRegionColorMode,
        whiteMix: Float,
        lightSourceOriginMode: BrightRegionLightSourceOriginMode,
        ignoresGeometry: Bool,
        isHeightPriorEnabled: Bool,
        shadowSoftnessMode: BrightRegionShadowSoftnessMode,
        estimatedLightType: BrightRegionEstimatedLightType,
        spotLightCount: Int,
        spotIntensityDistributionMode: BrightRegionSpotLightIntensityDistributionMode,
        castsOnlyDominantSpotShadow: Bool,
        isEstimatedEnvironmentLightRenderingEnabled: Bool = true,
        areGroundingShadowsEnabled: Bool = false,
        isEnvironmentLightingEnabled: Bool = true,
        environmentLightingWeight: Float = 1.0,
        areEstimatedDirectionalLightShadowsEnabled: Bool = true,
        areEstimatedSpotLightShadowsEnabled: Bool = true,
        fixedDirectionalShadowOrthographicScale: Float? = nil
    ) {
        self.id = id
        self.title = title
        self.dominanceScoreMode = dominanceScoreMode
        self.distanceScoreMode = distanceScoreMode
        self.directionMode = directionMode
        self.colorMode = colorMode
        self.whiteMix = whiteMix
        self.lightSourceOriginMode = lightSourceOriginMode
        self.ignoresGeometry = ignoresGeometry
        self.isHeightPriorEnabled = isHeightPriorEnabled
        self.shadowSoftnessMode = shadowSoftnessMode
        self.estimatedLightType = estimatedLightType
        self.spotLightCount = spotLightCount
        self.spotIntensityDistributionMode = spotIntensityDistributionMode
        self.castsOnlyDominantSpotShadow = castsOnlyDominantSpotShadow
        self.isEstimatedEnvironmentLightRenderingEnabled = isEstimatedEnvironmentLightRenderingEnabled
        self.areGroundingShadowsEnabled = areGroundingShadowsEnabled
        self.isEnvironmentLightingEnabled = isEnvironmentLightingEnabled
        self.environmentLightingWeight = environmentLightingWeight
        self.areEstimatedDirectionalLightShadowsEnabled = areEstimatedDirectionalLightShadowsEnabled
        self.areEstimatedSpotLightShadowsEnabled = areEstimatedSpotLightShadowsEnabled
        self.fixedDirectionalShadowOrthographicScale = fixedDirectionalShadowOrthographicScale
    }

    var lightSummary: String {
        guard isEstimatedEnvironmentLightRenderingEnabled else {
            return areGroundingShadowsEnabled ? "Kein Licht | Grounding Shadows" : "Kein Licht"
        }

        return "\(estimatedLightType.title) x\(spotLightCount)"
    }

    static let all: [BrightRegionTestPreset] = [
        BrightRegionTestPreset(
            id: "grounding-shadows-only",
            title: "Grounding Shadows",
            dominanceScoreMode: .totalLuminance,
            distanceScoreMode: .off,
            directionMode: .luminanceWeighted,
            colorMode: .average,
            whiteMix: 0.7,
            lightSourceOriginMode: .sceneProbePosition,
            ignoresGeometry: false,
            isHeightPriorEnabled: false,
            shadowSoftnessMode: .both,
            estimatedLightType: .directional,
            spotLightCount: 1,
            spotIntensityDistributionMode: .full,
            castsOnlyDominantSpotShadow: true,
            isEstimatedEnvironmentLightRenderingEnabled: false,
            areGroundingShadowsEnabled: true,
            environmentLightingWeight: 1.5
        ),
        BrightRegionTestPreset(
            id: "environment-light-only",
            title: "No shadows",
            dominanceScoreMode: .totalLuminance,
            distanceScoreMode: .off,
            directionMode: .luminanceWeighted,
            colorMode: .average,
            whiteMix: 0.7,
            lightSourceOriginMode: .sceneProbePosition,
            ignoresGeometry: false,
            isHeightPriorEnabled: false,
            shadowSoftnessMode: .both,
            estimatedLightType: .directional,
            spotLightCount: 1,
            spotIntensityDistributionMode: .full,
            castsOnlyDominantSpotShadow: true,
            isEstimatedEnvironmentLightRenderingEnabled: false,
            environmentLightingWeight: 1.5
        ),
        BrightRegionTestPreset(
            id: "baseline-dominant",
            title: "Baseline - eine dominante Lichtquelle",
            dominanceScoreMode: .totalLuminance,
            distanceScoreMode: .off,
            directionMode: .luminanceWeighted,
            colorMode: .average,
            whiteMix: 0.7,
            lightSourceOriginMode: .sceneProbePosition,
            ignoresGeometry: false,
            isHeightPriorEnabled: false,
            shadowSoftnessMode: .both,
            estimatedLightType: .directional,
            spotLightCount: 1,
            spotIntensityDistributionMode: .full,
            castsOnlyDominantSpotShadow: true
        ),
        BrightRegionTestPreset(
            id: "multilight-color-true",
            title: "Multi-Light ohne Geometrie",
            dominanceScoreMode: .balancedArea,
            distanceScoreMode: .off,
            directionMode: .luminanceWeighted,
            colorMode: .average,
            whiteMix: 0.7,
            lightSourceOriginMode: .sceneProbePosition,
            ignoresGeometry: true,
            isHeightPriorEnabled: false,
            shadowSoftnessMode: .both,
            estimatedLightType: .directional,
            spotLightCount: 3,
            spotIntensityDistributionMode: .dividedByLightCount,
            castsOnlyDominantSpotShadow: false
        ),
        BrightRegionTestPreset(
            id: "multilight-color-true-geometry",
            title: "Multi-Light mit Geometrie",
            dominanceScoreMode: .balancedArea,
            distanceScoreMode: .squared,
            directionMode: .luminanceWeighted,
            colorMode: .average,
            whiteMix: 0.7,
            lightSourceOriginMode: .sceneProbePosition,
            ignoresGeometry: false,
            isHeightPriorEnabled: true,
            shadowSoftnessMode: .both,
            estimatedLightType: .directional,
            spotLightCount: 3,
            spotIntensityDistributionMode: .dividedByLightCount,
            castsOnlyDominantSpotShadow: false
        ),
        BrightRegionTestPreset(
            id: "directional-geometry-no-shadows",
            title: "Multi-Light + Grounding Shadows",
            dominanceScoreMode: .balancedArea,
            distanceScoreMode: .squared,
            directionMode: .luminanceWeighted,
            colorMode: .average,
            whiteMix: 0.7,
            lightSourceOriginMode: .sceneProbePosition,
            ignoresGeometry: false,
            isHeightPriorEnabled: true,
            shadowSoftnessMode: .both,
            estimatedLightType: .directional,
            spotLightCount: 3,
            spotIntensityDistributionMode: .dividedByLightCount,
            castsOnlyDominantSpotShadow: false,
            areGroundingShadowsEnabled: true,
            areEstimatedDirectionalLightShadowsEnabled: false,
            areEstimatedSpotLightShadowsEnabled: false
        ),
        BrightRegionTestPreset(
            id: "multilight-color-true-geometry-key-fill",
            title: "Multi-Light Single Shadow",
            dominanceScoreMode: .balancedArea,
            distanceScoreMode: .squared,
            directionMode: .luminanceWeighted,
            colorMode: .average,
            whiteMix: 0.7,
            lightSourceOriginMode: .sceneProbePosition,
            ignoresGeometry: false,
            isHeightPriorEnabled: true,
            shadowSoftnessMode: .both,
            estimatedLightType: .directional,
            spotLightCount: 3,
            spotIntensityDistributionMode: .dominantWithReducedSecondary,
            castsOnlyDominantSpotShadow: true
        ),
        BrightRegionTestPreset(
            id: "multilight-single-hard-shadow",
            title: "Multi-Light Single Hard Shadow",
            dominanceScoreMode: .balancedArea,
            distanceScoreMode: .squared,
            directionMode: .luminanceWeighted,
            colorMode: .average,
            whiteMix: 0.7,
            lightSourceOriginMode: .sceneProbePosition,
            ignoresGeometry: false,
            isHeightPriorEnabled: true,
            shadowSoftnessMode: .both,
            estimatedLightType: .directional,
            spotLightCount: 3,
            spotIntensityDistributionMode: .dominantWithReducedSecondary,
            castsOnlyDominantSpotShadow: true,
            fixedDirectionalShadowOrthographicScale: 4
        ),
        BrightRegionTestPreset(
            id: "multilight-live-updates",
            title: "Multi-Light Live Updates",
            dominanceScoreMode: .balancedArea,
            distanceScoreMode: .squared,
            directionMode: .luminanceWeighted,
            colorMode: .average,
            whiteMix: 0.7,
            lightSourceOriginMode: .sceneProbePosition,
            ignoresGeometry: false,
            isHeightPriorEnabled: true,
            shadowSoftnessMode: .both,
            estimatedLightType: .directional,
            spotLightCount: 3,
            spotIntensityDistributionMode: .dividedByLightCount,
            castsOnlyDominantSpotShadow: false
        )
    ]

    static let stackingSequenceIDs = [
        "grounding-shadows-only",
        "baseline-dominant",
        "multilight-color-true-geometry",
        "directional-geometry-no-shadows",
        "multilight-single-hard-shadow"
    ]

    static var stackingSequence: [BrightRegionTestPreset] {
        stackingSequenceIDs.compactMap { id in
            all.first { $0.id == id }
        }
    }
}

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    static let environmentProbeWindowID = "EnvironmentProbePreviewWindow"
    static let environmentProbeMaskWindowID = "EnvironmentProbeMaskWindow"
    static let deviceAnchorWindowID = "DeviceAnchorTrackingWindow"
    static let lightTuningWindowID = "LightTuningWindow"
    static let temporalStabilityWindowID = "TemporalStabilityWindow"
    static let technicalTestsWindowID = "TechnicalTestsWindow"

    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }

    enum ImmersiveScene: String, CaseIterable, Identifiable {
        case table
        case floor
        case cube
        case kitchen2

        var id: Self { self }

        var title: String {
            switch self {
            case .table: "Table"
            case .floor: "Floor"
            case .cube: "Cubes"
            case .kitchen2: "Kitchen"
            }
        }

        var assetName: String {
            switch self {
            case .table: "SimpleTableScene"
            case .floor: "SimpleFloorScene"
            case .cube: "CubeScene"
            case .kitchen2: "kitchen2"
            }
        }

        var includesTableScene: Bool {
            switch self {
            case .table, .cube: true
            case .floor, .kitchen2: false
            }
        }

        var entityName: String {
            "Immersive\(assetName)"
        }
    }

    @ObservationIgnored let environmentProbeReader = EnvironmentProbeReader()
    @ObservationIgnored let deviceAnchorTracker = DeviceAnchorTracker()

    var immersiveSpaceState = ImmersiveSpaceState.closed
    var selectedImmersiveScene = ImmersiveScene.table
    var environmentProbePreviewURLs: [URL] = []
    var environmentProbeFaceURLs: [Int: URL] = [:]
    var environmentProbePreviewVersion = 0
    var environmentProbeRefreshRequestID = 0
    var brightRegionMaskPreviewURLs: [URL] = []
    var brightRegionMaskFaceURLs: [Int: URL] = [:]
    var brightRegionMaskPreviewVersion = 0
    var brightRegionMaskRefreshRequestID = 0
    var environmentProbeSaveDatasetRequestID = 0
    var environmentProbeLoadRecordedDatasetRequestID = 0
    var environmentProbeImportDatasetRequestID = 0
    var environmentProbeImportDatasetURL: URL?
    var canRefreshEnvironmentProbePreview = false
    var environmentProbeUpdateCount = 0
    var environmentProbeLastUpdateAt: Date?
    var environmentProbeDebugSummary = "Noch kein Probe-Update"
    var environmentProbeSessionStatus = "Probe-Reader nicht gestartet"
    var hasEnvironmentProbeTexture = false
    var environmentProbeAverageLuminance: Float?
    var environmentProbeCameraScaleReference: Float = 1
    var environmentProbeLuminanceStatus = "Noch nicht berechnet"
    var brightRegionMaskDebugSummary = "Noch keine Bright-Region-Maske"
    var brightRegionMaskStatus = "Noch nicht berechnet"
    var brightRegionMaskLastThreshold: Float = 0
    var brightRegionMaskLastPercentileThresholds: [Float] = []
    var canRecomputeBrightRegionLight = false
    var isSequentialLightUpdateRunning = false
    var sequentialLightUpdateStatus = "Sequenz: aus"
    var sequentialLightUpdateCount = 0
    var brightRegionRegionBaseDebugLines: [String] = []
    var brightRegionPlaneHitDebugSummaries: [Int: String] = [:]
    var brightRegionDistanceEstimates: [Int: Float] = [:]
    var brightRegionRegionDebugLines: [String] {
        brightRegionRegionBaseDebugLines.enumerated().map { index, line in
            var parts = [line]
            guard let hitSummary = brightRegionPlaneHitDebugSummaries[index + 1] else {
                if index == 0 {
                    parts.append(brightRegionEstimatedLightPlacementDebugLine)
                }
                return parts.joined(separator: " | ")
            }

            parts.append(hitSummary)
            if index == 0 {
                parts.append(brightRegionEstimatedLightPlacementDebugLine)
            }
            return parts.joined(separator: " | ")
        }
    }
    var brightRegionEstimatedLightDebugLine = "Noch keine dominante Lichtquelle geschaetzt"
    var brightRegionEstimatedLightPositionDebugLine = "Position: nicht verfuegbar"
    var brightRegionEstimatedLightPlacementDebugLine = "Placement: nicht verfuegbar"
    var brightRegionEstimatedLightTotalIntensityDebugLine = "Gesamthelligkeit: nicht verfuegbar"
    var brightRegionPlaneHitDebugSamples: [BrightRegionPlaneHitDebugSample] = []
    var brightRegionLightPlacementRequestID = 0
    var brightRegionCompletedLightPlacementRequestID = 0
    var brightRegionPositionEvaluationsByStableID: [Int: BrightRegionPositionEvaluation] = [:]
    var deviceAnchorTrackingStatus = "Device-Anchor-Tracking nicht gestartet"
    var deviceAnchorLastUpdateAt: Date?
    var deviceAnchorPosition = SIMD3<Float>(repeating: 0)
    var deviceAnchorRotationEulerDegrees = SIMD3<Float>(repeating: 0)
    var deviceAnchorTransform = simd_float4x4(1)
    var deviceAnchorStartPosition = SIMD3<Float>(repeating: 0)
    var deviceAnchorStartRotationEulerDegrees = SIMD3<Float>(repeating: 0)
    var hasDeviceAnchorPose = false
    var hasDeviceAnchorStartPose = false
    var worldReferenceAnchorStatus = "Noch kein WorldAnchor gesetzt"
    var worldReferenceAnchorTransform = simd_float4x4(1)
    var worldReferenceAnchorPosition = SIMD3<Float>(repeating: 0)
    var worldReferenceAnchorRotationEulerDegrees = SIMD3<Float>(repeating: 0)
    var worldReferenceAnchorID: UUID?
    var worldReferenceKnownAnchorCount = 0
    var worldReferenceTrackedAnchorCount = 0
    var worldReferenceActiveAnchorDebugID = "none"
    var worldReferenceTrackedAnchorDebugIDs = "none"
    var hasWorldReferenceAnchorPose = false
    var environmentProbeAnchorPosition = SIMD3<Float>(repeating: 0)
    var environmentProbeAnchorRotationEulerDegrees = SIMD3<Float>(repeating: 0)
    var environmentProbeAnchorStartPosition = SIMD3<Float>(repeating: 0)
    var environmentProbeAnchorStartRotationEulerDegrees = SIMD3<Float>(repeating: 0)
    var hasEnvironmentProbeAnchorPose = false
    var hasEnvironmentProbeAnchorStartPose = false
    var rotatedEnvironmentProbeDebugPosition = SIMD3<Float>(repeating: 0)
    var hasRotatedEnvironmentProbeDebugPosition = false
    var hasBrightRegionEstimatedLight = false
    var brightRegionEstimatedLightDirection = SIMD3<Float>(repeating: 0)
    var brightRegionEstimatedLightPosition = SIMD3<Float>(repeating: 0)
    var brightRegionEstimatedLightColor = SIMD3<Float>(repeating: 1)
    var brightRegionEstimatedLightIntensity: Float = 0
    var brightRegionEstimatedLightWhiteMix: Float = 0.7
    var brightRegionEstimatedDirectionalLightLuxMultiplier: Float = 1
    var brightRegionEstimatedLightType = BrightRegionEstimatedLightType.directional
    var isEstimatedEnvironmentLightRenderingEnabled = true
    var brightRegionEstimatedLights: [BrightRegionEstimatedLightState] = []
    var brightRegionRawEstimatedLights: [BrightRegionEstimatedLightState] = []
    var brightRegionFilteredCandidateLights: [BrightRegionEstimatedLightState] = []
    var brightRegionEstimatedDirectionalLightCount = 1
    var areEstimatedDirectionalLightShadowsEnabled = true
    var castsOnlyDominantEstimatedDirectionalLightShadow = true
    var brightRegionEstimatedLightShadowProjectionMode = BrightRegionShadowProjectionMode.fixed
    var brightRegionEstimatedLightShadowMaximumDistance: Float = 5
    var brightRegionEstimatedLightShadowDepthBias: Float = 0.8
    var brightRegionEstimatedLightShadowFixedZNear: Float = 0.1
    var brightRegionEstimatedLightShadowFixedZFar: Float = 8
    var brightRegionEstimatedLightShadowFixedOrthographicScale: Float = 4
    var usesFixedDirectionalShadowOrthographicScale = false
    var brightRegionEstimatedSpotLightInnerAngleInDegrees: Float = 35
    var brightRegionEstimatedSpotLightOuterAngleInDegrees: Float = 155
    var brightRegionEstimatedSpotLightAttenuationRadius: Float = 8
    var brightRegionEstimatedSpotLightAttenuationFalloffExponent: Float = 0.5
    var brightRegionEstimatedSpotLightDepthBias: Float = 0.8
    var brightRegionEstimatedSpotLightCount = 1
    var areEstimatedSpotLightShadowsEnabled = true
    var castsOnlyDominantEstimatedSpotLightShadow = true
    var brightRegionSpotLightIntensityDistributionMode = BrightRegionSpotLightIntensityDistributionMode.dividedByLightCount
    var isEstimatedSpotLightShadowPositionClampEnabled = true
    var estimatedSpotLightShadowPositionMaxDistance: Float = 2.5
    var areLightProbeDebugSpheresVisible = false
    var usesStableIDDebugColors = false
    var areRejectedLightPositionDebugSpheresVisible = true
    var isBrightRegionSelectionHysteresisEnabled = true
    var isStableLightPositionAverageEnabled = true
    var isStableLightDirectionAverageEnabled = true
    var isStableLightColorAverageEnabled = true
    var isStableLightIntensityAverageEnabled = true
    var isStableLightShadowSoftnessAverageEnabled = true
    var isStableLightPositionMinimumChangeEnabled = true
    var isStableLightAppearanceMinimumChangeEnabled = true
    var stableLightPositionMinimumChange: Float = 0.5
    var stableLightDirectionMinimumChangeDegrees: Float = 3
    var stableLightColorMinimumChange: Float = 0.1
    var stableLightIntensityMinimumRelativeChange: Float = 0.2
    var stableLightShadowSoftnessMinimumChange: Float = 0.15
    var freezesEstimatedLightAfterWarmup = false
    var estimatedLightWarmupFreezeStatus = "Licht-Freeze: aus"
    var stableLightRejectedPositionDebugSamples: [StableLightRejectedPositionDebugSample] = []
    var stableLightPositionDebugStatus = "Positions-Debug: noch keine Daten"
    var brightRegionProbePosition = SIMD3<Float>(repeating: 0)
    var environmentProbeDatasetStatus = "Noch kein Probe-Dataset gespeichert"
    var environmentProbeLatestDatasetFolderURL: URL?
    var environmentProbeLatestDatasetFileURLs: [URL] = []
    var environmentProbeExportStatus = "Noch kein Probe-Export"
    var environmentProbeLatestExportFolderURL: URL?
    var environmentProbeLatestExportFileURLs: [URL] = []
    var isEnvironmentProbeSequenceExportRunning = false
    var environmentProbeSequenceExportStatus = "Noch kein Sequenz-Export"
    var environmentProbeLatestSequenceExportFolderURL: URL?
    var environmentProbeLatestSequenceExportFileURLs: [URL] = []
    var selectedTemporalStabilityTestMode = TemporalStabilityTestMode.raw
    var temporalStabilityTestStartedAt: Date?
    var temporalStabilityTestDurationSeconds = 60
    var lightStabilityResetRequestID = 0
    var isRuntimeEvaluationRunning = false
    var runtimeEvaluationStatus = "Test 1: noch keine Messung"
    var runtimeEvaluationStartedAt: Date?
    var runtimeEvaluationDurationSeconds = 60
    var runtimeEvaluationLatestFolderURL: URL?
    var runtimeEvaluationLatestFileURLs: [URL] = []
    var isUsingRecordedEnvironmentProbe = false
    var environmentProbeOriginTransform = simd_float4x4(1)
    var environmentProbePositionOverride = SIMD3<Float>(0, 1.0, -1.2)
    var environmentProbePositionOverrideHeight: Float = 1.0
    var isProbeFaceDebugEnabled = false
    var brightRegionDominanceScoreMode = BrightRegionDominanceScoreMode.totalLuminance
    var brightRegionDistanceScoreMode = BrightRegionDistanceScoreMode.off
    var brightRegionDirectionMode = BrightRegionDirectionMode.luminanceWeighted
    var brightRegionColorMode = BrightRegionColorMode.average
    var brightRegionLightSourceOriginMode = BrightRegionLightSourceOriginMode.geometryHitOrSceneProbe
    var isBrightRegionGeometryIgnored = false
    var isBrightRegionHeightPriorEnabled = false
    var brightRegionShadowSoftnessMode = BrightRegionShadowSoftnessMode.both
    /// `nil` represents an individually tuned light configuration.
    var activeBrightRegionTestPresetID: String?
    var detectedFloorHeight: Float?
    var areGroundingShadowsEnabled = false
    var isRealWorldOcclusionEnabled = false
    var isEnvironmentLightingEnabled = true
    var environmentLightingWeight: Float = 1.0
    var isCustomImageBasedLightEnabled = false
    var isSceneReconstructionVisualizationEnabled = false
    var isPlaneClassificationVisualizationEnabled = false
    var isPlaneVisualizationEnabled = false
    var selectedPerformanceStressScenario = PerformanceStressScenario.environmentAndGrounding
    var performanceTraceStatus = "Performance-Trace: noch keine Messung"
    var performanceRenderStressStatus = "Render-Stress: Standard"
    @ObservationIgnored nonisolated let fpsStressTestRecorder = FPSStressTestRecorder()
    @ObservationIgnored private var fpsStressTestTask: Task<Void, Never>?
    var isFPSStressTestRunning = false
    var fpsStressTestPhase = FPSStressTestPhase.idle
    var fpsStressTestStatus = "Test 4: noch keine Messung"
    var fpsStressTestPhaseStartedAt: Date?
    var fpsStressTestPhaseDurationSeconds = 0
    var fpsStressTestLatestFolderURL: URL?
    var fpsStressTestLatestFileURLs: [URL] = []
    var fpsStressTestActiveDirectionalLightCount = 0
    var fpsStressTestActiveDynamicShadowCount = 0
    var stackingLightPresetIndex = 0
    var activeStackingCardSpriteImageName = "CardSprite_01"
    var stackingSceneReloadRequestID = 0
    var isStackingPresetExplorerActive = false
    var activeStackingExplorerPresetID: String?
    var questionnaireSaveStatus = "Fragebogen: noch nicht gespeichert"
    var isStackingControlsVisible = false
    private struct EstimatedLightWarmupAccumulator {
        var latest: BrightRegionEstimatedLightState
        var directionTotal: SIMD3<Float>
        var positionTotal: SIMD3<Float>
        var colorTotal: SIMD3<Float>
        var intensityTotal: Float
        var heightMultiplierTotal: Float
        var sourceSizePixelsTotal: Float
        var shadowSoftnessTotal: Float
        var sampleCount: Int

        init(light: BrightRegionEstimatedLightState) {
            latest = light
            directionTotal = light.direction
            positionTotal = light.position
            colorTotal = light.color
            intensityTotal = light.intensity
            heightMultiplierTotal = light.heightMultiplier
            sourceSizePixelsTotal = light.sourceSizePixels
            shadowSoftnessTotal = light.shadowSoftness
            sampleCount = 1
        }

        mutating func add(_ light: BrightRegionEstimatedLightState) {
            latest = light
            directionTotal += light.direction
            positionTotal += light.position
            colorTotal += light.color
            intensityTotal += light.intensity
            heightMultiplierTotal += light.heightMultiplier
            sourceSizePixelsTotal += light.sourceSizePixels
            shadowSoftnessTotal += light.shadowSoftness
            sampleCount += 1
        }

        var averagedLight: BrightRegionEstimatedLightState {
            let divisor = Float(max(sampleCount, 1))
            return BrightRegionEstimatedLightState(
                id: latest.id,
                sourceRegionIndex: latest.sourceRegionIndex,
                sourceRegionStableID: latest.sourceRegionStableID,
                direction: AppModel.normalized(directionTotal / divisor),
                position: positionTotal / divisor,
                isPlacementResolved: latest.isPlacementResolved,
                color: colorTotal / divisor,
                intensity: intensityTotal / divisor,
                heightMultiplier: heightMultiplierTotal / divisor,
                sourceSizePixels: sourceSizePixelsTotal / divisor,
                shadowSoftness: shadowSoftnessTotal / divisor
            )
        }
    }

    private let estimatedLightWarmupFreezeDuration: TimeInterval = 10
    private var estimatedLightWarmupStartedAt: Date?
    private var isEstimatedLightWarmupFrozen = false
    private var estimatedLightWarmupSampleCount = 0
    private var estimatedLightWarmupAccumulators: [Int: EstimatedLightWarmupAccumulator] = [:]
    private var stackingLightPresetSequence: [BrightRegionTestPreset] = BrightRegionTestPreset.stackingSequence
    private static let developmentDefaultLightPresetID = "multilight-color-true-geometry-key-fill"
    private static let userTestPresetsWithoutTemporalStabilization: Set<String> = [
        "multilight-live-updates"
    ]
    let stackingCardSpriteImageNames = [
        "CardSprite_01",
        "CardSprite_02",
        "CardSprite_03",
        "CardSprite_04",
        "CardSprite_05",
        "CardSprite_06",
        "CardSprite_07",
        "CardSprite_08"
    ]
    private var stackingCardSpriteDrawOrder: [String] = []
    private let questionnaireSessionID = UUID().uuidString
    private let questionnaireSessionStartedAt = Date()
    private var questionnaireResponses: [StackingQuestionnaireResponse] = []
    private var questionnaireSessionFileURL: URL?

    var isTemporalLightStabilizationEnabled: Bool {
        isBrightRegionSelectionHysteresisEnabled
            && isStableLightPositionAverageEnabled
            && isStableLightDirectionAverageEnabled
            && isStableLightColorAverageEnabled
            && isStableLightIntensityAverageEnabled
            && isStableLightShadowSoftnessAverageEnabled
            && isStableLightPositionMinimumChangeEnabled
            && isStableLightAppearanceMinimumChangeEnabled
    }

    func setTemporalLightStabilizationEnabled(_ isEnabled: Bool) {
        isBrightRegionSelectionHysteresisEnabled = isEnabled
        isStableLightPositionAverageEnabled = isEnabled
        isStableLightDirectionAverageEnabled = isEnabled
        isStableLightColorAverageEnabled = isEnabled
        isStableLightIntensityAverageEnabled = isEnabled
        isStableLightShadowSoftnessAverageEnabled = isEnabled
        isStableLightPositionMinimumChangeEnabled = isEnabled
        isStableLightAppearanceMinimumChangeEnabled = isEnabled
    }

    func setEstimatedLightWarmupFreezeEnabled(_ isEnabled: Bool) {
        freezesEstimatedLightAfterWarmup = isEnabled
        resetEstimatedLightWarmupFreeze()
        restartEstimatedLightWarmupUpdatesIfNeeded()
    }

    private func resetUserTestSettingsToDefaults() {
        brightRegionEstimatedDirectionalLightLuxMultiplier = 1
        brightRegionEstimatedLightShadowProjectionMode = .fixed
        brightRegionEstimatedLightShadowMaximumDistance = 5
        brightRegionEstimatedLightShadowDepthBias = 0.8
        brightRegionEstimatedLightShadowFixedZNear = 0.1
        brightRegionEstimatedLightShadowFixedZFar = 8
        brightRegionEstimatedLightShadowFixedOrthographicScale = 4
        usesFixedDirectionalShadowOrthographicScale = false

        brightRegionEstimatedSpotLightInnerAngleInDegrees = 35
        brightRegionEstimatedSpotLightOuterAngleInDegrees = 155
        brightRegionEstimatedSpotLightAttenuationRadius = 8
        brightRegionEstimatedSpotLightAttenuationFalloffExponent = 0.5
        brightRegionEstimatedSpotLightDepthBias = 0.8
        isEstimatedSpotLightShadowPositionClampEnabled = true
        estimatedSpotLightShadowPositionMaxDistance = 2.5

        stableLightPositionMinimumChange = 0.5
        stableLightDirectionMinimumChangeDegrees = 3
        stableLightColorMinimumChange = 0.1
        stableLightIntensityMinimumRelativeChange = 0.2
        stableLightShadowSoftnessMinimumChange = 0.15
        usesStableIDDebugColors = false
        activeBrightRegionTestPresetID = nil
        lightStabilityResetRequestID += 1
    }

    func configureStackingStartMode() {
        resetUserTestSettingsToDefaults()
        selectedImmersiveScene = .cube
        isPlaneVisualizationEnabled = true
        isSceneReconstructionVisualizationEnabled = false
        isPlaneClassificationVisualizationEnabled = false
        isRealWorldOcclusionEnabled = false
        isProbeFaceDebugEnabled = false
        areLightProbeDebugSpheresVisible = false
        areRejectedLightPositionDebugSpheresVisible = false
        isStackingControlsVisible = true
        stackingLightPresetIndex = 0
        resetStackingLightPresetSequence()
        resetStackingCardSpriteDrawOrder()
        isStackingPresetExplorerActive = false
        activeStackingExplorerPresetID = nil
        questionnaireSaveStatus = "Fragebogen: noch nicht gespeichert"
        applyCurrentStackingLightPreset()
    }

    func configureDevelopmentStartMode() {
        guard let preset = BrightRegionTestPreset.all.first(where: {
            $0.id == Self.developmentDefaultLightPresetID
        }) else {
            return
        }

        applyBrightRegionTestPreset(preset)
        setTemporalLightStabilizationEnabled(true)
        setEstimatedLightWarmupFreezeEnabled(false)

        if canRecomputeBrightRegionLight {
            environmentProbeReader.recomputeEstimatedLight(appModel: self)
        } else if hasEnvironmentProbeTexture {
            environmentProbeReader.refreshEnvironmentProbeAnalysis(appModel: self)
        }
    }

    var activeStackingLightPreset: BrightRegionTestPreset {
        if
            isStackingPresetExplorerActive,
            let activeStackingExplorerPresetID,
            let explorerPreset = BrightRegionTestPreset.all.first(where: { $0.id == activeStackingExplorerPresetID })
        {
            return explorerPreset
        }

        let sequence = stackingLightPresetSequence.isEmpty ? BrightRegionTestPreset.stackingSequence : stackingLightPresetSequence
        guard !sequence.isEmpty else {
            return BrightRegionTestPreset.all[0]
        }

        let index = min(max(stackingLightPresetIndex, 0), sequence.count - 1)
        return sequence[index]
    }

    var stackingLightPresetDebugLine: String {
        let preset = activeStackingLightPreset
        return preset.displayID
    }

    func advanceStackingLevel() {
        let sequenceCount = max(stackingLightPresetSequence.count, 1)
        if stackingLightPresetIndex >= sequenceCount - 1 {
            activeStackingExplorerPresetID = activeStackingLightPreset.id
            isStackingPresetExplorerActive = true
        } else {
            stackingLightPresetIndex += 1
        }

        drawNextStackingCardSprite()
        applyCurrentStackingLightPreset()
        reloadStackingCubeScene()
    }

    func restartStackingRotation() {
        stackingLightPresetIndex = 0
        resetStackingLightPresetSequence()
        resetStackingCardSpriteDrawOrder()
        isStackingPresetExplorerActive = false
        activeStackingExplorerPresetID = nil
        applyCurrentStackingLightPreset()
        reloadStackingCubeScene()
    }

    func applyStackingExplorerPreset(_ preset: BrightRegionTestPreset) {
        activeStackingExplorerPresetID = preset.id
        if let sequenceIndex = stackingLightPresetSequence.firstIndex(where: { $0.id == preset.id }) {
            stackingLightPresetIndex = sequenceIndex
        }
        applyCurrentStackingLightPreset()
    }

    private func resetStackingLightPresetSequence() {
        stackingLightPresetSequence = BrightRegionTestPreset.stackingSequence.shuffled()
    }

    private func resetStackingCardSpriteDrawOrder() {
        stackingCardSpriteDrawOrder = stackingCardSpriteImageNames.shuffled()
        activeStackingCardSpriteImageName = drawStackingCardSprite(excluding: nil)
    }

    private func drawNextStackingCardSprite() {
        activeStackingCardSpriteImageName = drawStackingCardSprite(excluding: activeStackingCardSpriteImageName)
    }

    private func drawStackingCardSprite(excluding excludedImageName: String?) -> String {
        if stackingCardSpriteDrawOrder.isEmpty {
            stackingCardSpriteDrawOrder = stackingCardSpriteImageNames.shuffled()

            if
                let excludedImageName,
                stackingCardSpriteDrawOrder.count > 1,
                stackingCardSpriteDrawOrder.first == excludedImageName,
                let replacementIndex = stackingCardSpriteDrawOrder.firstIndex(where: { $0 != excludedImageName })
            {
                stackingCardSpriteDrawOrder.swapAt(0, replacementIndex)
            }
        }

        return stackingCardSpriteDrawOrder.removeFirst()
    }

    func saveStackingQuestionnaireResponse(ratingsByQuestionIndex: [Int: Int]) {
        let preset = activeStackingLightPreset
        let response = StackingQuestionnaireResponse(
            responseKind: "questionnaire",
            recordedAt: Date(),
            presetID: preset.id,
            presetTitle: preset.title,
            isExtraLevel: isStackingPresetExplorerActive,
            answers: StackingQuestionnaire.questions.enumerated().map { index, question in
                StackingQuestionnaireAnswer(
                    questionIndex: index + 1,
                    question: question,
                    rating: ratingsByQuestionIndex[index]
                )
            }
        )

        questionnaireResponses.append(response)

        do {
            let savedFiles = try writeQuestionnaireSession()
            questionnaireSaveStatus = "Fragebogen gespeichert: \(savedFiles.joined(separator: ", "))"
        } catch {
            questionnaireSaveStatus = "Fragebogen konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
    }

    func saveStackingPresetSelectionResponse() {
        let preset = activeStackingLightPreset
        let response = StackingQuestionnaireResponse(
            responseKind: "presetSelection",
            recordedAt: Date(),
            presetID: preset.id,
            presetTitle: preset.title,
            isExtraLevel: isStackingPresetExplorerActive,
            answers: []
        )

        questionnaireResponses.append(response)

        do {
            let savedFiles = try writeQuestionnaireSession()
            questionnaireSaveStatus = "Auswahl gespeichert: \(savedFiles.joined(separator: ", "))"
        } catch {
            questionnaireSaveStatus = "Auswahl konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
    }

    private func writeQuestionnaireSession() throws -> [String] {
        let fileURL = try questionnaireSessionURL()
        let session = StackingQuestionnaireSession(
            sessionID: questionnaireSessionID,
            sessionStartedAt: questionnaireSessionStartedAt,
            responses: questionnaireResponses
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(session)
        var savedFiles: [String] = []
        try writeQuestionnaireData(data, to: fileURL, displayPath: "Documents/LighttestQuestionnaireSessions/\(fileURL.lastPathComponent)", savedFiles: &savedFiles)
        try writeQuestionnaireData(data, to: latestQuestionnaireSessionURL(), displayPath: "Documents/latest-questionnaire-session.json", savedFiles: &savedFiles)
        let environmentProbeDatasetsSessionURL = try environmentProbeDatasetsQuestionnaireSessionURL(filename: fileURL.lastPathComponent)
        try writeQuestionnaireData(data, to: environmentProbeDatasetsSessionURL, displayPath: "Documents/EnvironmentProbeDatasets/\(environmentProbeDatasetsSessionURL.lastPathComponent)", savedFiles: &savedFiles)
        try writeQuestionnaireData(data, to: environmentProbeDatasetsQuestionnaireSessionURL(), displayPath: "Documents/EnvironmentProbeDatasets/latest-questionnaire-session.json", savedFiles: &savedFiles)
        try writeQuestionnaireData(data, to: applicationSupportQuestionnaireSessionURL(), displayPath: "Library/Application Support/latest-questionnaire-session.json", savedFiles: &savedFiles)
        try writeQuestionnaireData(data, to: cachesQuestionnaireSessionURL(), displayPath: "Library/Caches/latest-questionnaire-session.json", savedFiles: &savedFiles)

        return savedFiles
    }

    private func writeQuestionnaireData(
        _ data: Data,
        to fileURL: URL,
        displayPath: String,
        savedFiles: inout [String]
    ) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        savedFiles.append(displayPath)
    }

    private func questionnaireSessionURL() throws -> URL {
        if let questionnaireSessionFileURL {
            return questionnaireSessionFileURL
        }

        let documentsURL = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folderURL = documentsURL.appendingPathComponent(
            "LighttestQuestionnaireSessions",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folderURL,
            withIntermediateDirectories: true
        )
        let filename = "questionnaire-session-\(Self.questionnaireFilenameDateFormatter.string(from: questionnaireSessionStartedAt)).json"
        let fileURL = folderURL.appendingPathComponent(filename)
        questionnaireSessionFileURL = fileURL
        return fileURL
    }

    private func latestQuestionnaireSessionURL() throws -> URL {
        let documentsURL = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return documentsURL.appendingPathComponent("latest-questionnaire-session.json")
    }

    private func environmentProbeDatasetsQuestionnaireSessionURL() throws -> URL {
        try environmentProbeDatasetsQuestionnaireSessionURL(filename: "latest-questionnaire-session.json")
    }

    private func environmentProbeDatasetsQuestionnaireSessionURL(filename: String) throws -> URL {
        let documentsURL = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return documentsURL
            .appendingPathComponent("EnvironmentProbeDatasets", isDirectory: true)
            .appendingPathComponent(filename)
    }

    private func applicationSupportQuestionnaireSessionURL() throws -> URL {
        let applicationSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupportURL.appendingPathComponent("latest-questionnaire-session.json")
    }

    private func cachesQuestionnaireSessionURL() throws -> URL {
        let cachesURL = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return cachesURL.appendingPathComponent("latest-questionnaire-session.json")
    }

    private static let questionnaireFilenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter
    }()

    func reloadStackingCubeScene() {
        stackingSceneReloadRequestID += 1
    }

    func applyCurrentStackingLightPreset() {
        let preset = activeStackingLightPreset
        applyBrightRegionTestPreset(preset)
        let usesTemporalStabilization = !Self.userTestPresetsWithoutTemporalStabilization.contains(preset.id)
        setTemporalLightStabilizationEnabled(usesTemporalStabilization)
        setEstimatedLightWarmupFreezeEnabled(usesTemporalStabilization)
        restartEstimatedLightWarmupUpdatesIfNeeded()

        if canRecomputeBrightRegionLight {
            environmentProbeReader.recomputeEstimatedLight(appModel: self)
        } else if hasEnvironmentProbeTexture {
            environmentProbeReader.refreshEnvironmentProbeAnalysis(appModel: self)
        }
    }

    var brightRegionEstimatedDirectionalLightLux: Float {
        min(max(brightRegionEstimatedLightIntensity * 125, 500), 20_000)
    }

    var brightRegionAdjustedDirectionalLightLux: Float {
        brightRegionEstimatedDirectionalLightLux * brightRegionEstimatedDirectionalLightLuxMultiplier
    }

    func applyBrightRegionTestPreset(_ preset: BrightRegionTestPreset) {
        brightRegionDominanceScoreMode = preset.dominanceScoreMode
        brightRegionDistanceScoreMode = preset.distanceScoreMode
        brightRegionDirectionMode = preset.directionMode
        brightRegionColorMode = preset.colorMode
        brightRegionEstimatedLightWhiteMix = preset.whiteMix
        brightRegionLightSourceOriginMode = preset.lightSourceOriginMode
        isBrightRegionGeometryIgnored = preset.ignoresGeometry
        isBrightRegionHeightPriorEnabled = preset.isHeightPriorEnabled
        brightRegionShadowSoftnessMode = preset.shadowSoftnessMode

        brightRegionEstimatedDirectionalLightLuxMultiplier = 1
        brightRegionEstimatedLightType = preset.estimatedLightType
        isEstimatedEnvironmentLightRenderingEnabled = preset.isEstimatedEnvironmentLightRenderingEnabled
        areGroundingShadowsEnabled = preset.areGroundingShadowsEnabled
        isEnvironmentLightingEnabled = preset.isEnvironmentLightingEnabled
        environmentLightingWeight = preset.environmentLightingWeight
        isCustomImageBasedLightEnabled = false
        brightRegionEstimatedDirectionalLightCount = min(max(preset.spotLightCount, 1), 4)
        areEstimatedDirectionalLightShadowsEnabled = preset.areEstimatedDirectionalLightShadowsEnabled
        castsOnlyDominantEstimatedDirectionalLightShadow = preset.castsOnlyDominantSpotShadow
        if let fixedDirectionalShadowOrthographicScale = preset.fixedDirectionalShadowOrthographicScale {
            brightRegionEstimatedLightShadowProjectionMode = .fixed
            brightRegionEstimatedLightShadowFixedOrthographicScale = fixedDirectionalShadowOrthographicScale
            usesFixedDirectionalShadowOrthographicScale = true
        } else {
            brightRegionEstimatedLightShadowFixedOrthographicScale = 4
            usesFixedDirectionalShadowOrthographicScale = false
        }
        brightRegionEstimatedSpotLightCount = min(max(preset.spotLightCount, 1), 4)
        brightRegionSpotLightIntensityDistributionMode = preset.spotIntensityDistributionMode
        areEstimatedSpotLightShadowsEnabled = preset.areEstimatedSpotLightShadowsEnabled
        castsOnlyDominantEstimatedSpotLightShadow = preset.castsOnlyDominantSpotShadow

        brightRegionEstimatedSpotLightInnerAngleInDegrees = 35
        brightRegionEstimatedSpotLightOuterAngleInDegrees = 155
        brightRegionEstimatedSpotLightAttenuationRadius = 8
        brightRegionEstimatedSpotLightAttenuationFalloffExponent = 0.5
        brightRegionEstimatedSpotLightDepthBias = 0.8
        activeBrightRegionTestPresetID = preset.id
    }

    func markBrightRegionTestPresetAsCustom() {
        activeBrightRegionTestPresetID = nil
    }

    func resetEstimatedLightWarmupFreeze() {
        estimatedLightWarmupStartedAt = nil
        isEstimatedLightWarmupFrozen = false
        estimatedLightWarmupSampleCount = 0
        estimatedLightWarmupAccumulators = [:]
        estimatedLightWarmupFreezeStatus = freezesEstimatedLightAfterWarmup
            ? "Licht-Freeze: sammelt noch nicht"
            : "Licht-Freeze: aus"
    }

    func restartEstimatedLightWarmupUpdatesIfNeeded() {
        guard freezesEstimatedLightAfterWarmup && isEstimatedEnvironmentLightRenderingEnabled else {
            return
        }

        environmentProbeReader.stopSequentialLightUpdates(appModel: self)
        environmentProbeReader.startSequentialLightUpdates(appModel: self, interval: .seconds(1))
    }

    var shouldSkipEstimatedLightAnalysisAfterFreeze: Bool {
        freezesEstimatedLightAfterWarmup
            && isEstimatedLightWarmupFrozen
            && !isEnvironmentProbeSequenceExportRunning
    }

    var shouldFreezeEstimatedLightOutput: Bool {
        freezesEstimatedLightAfterWarmup && isEstimatedLightWarmupFrozen
    }

    func applyEstimatedLightSnapshot(
        hasLight: Bool,
        direction: SIMD3<Float>,
        position: SIMD3<Float>,
        color: SIMD3<Float>,
        intensity: Float,
        lights: [BrightRegionEstimatedLightState]
    ) {
        guard freezesEstimatedLightAfterWarmup && isEstimatedEnvironmentLightRenderingEnabled else {
            hasBrightRegionEstimatedLight = hasLight
            brightRegionEstimatedLightDirection = direction
            brightRegionEstimatedLightPosition = position
            brightRegionEstimatedLightColor = color
            brightRegionEstimatedLightIntensity = intensity
            brightRegionEstimatedLights = lights
            estimatedLightWarmupFreezeStatus = freezesEstimatedLightAfterWarmup
                ? "Licht-Freeze: wartet auf aktives Licht"
                : "Licht-Freeze: aus"
            return
        }

        guard !isEstimatedLightWarmupFrozen else {
            return
        }

        let now = Date()
        if estimatedLightWarmupStartedAt == nil {
            estimatedLightWarmupStartedAt = now
            estimatedLightWarmupFreezeStatus = "Licht-Freeze: sammelt 0/10 s"
        }

        if hasLight {
            estimatedLightWarmupSampleCount += 1
            for light in lights {
                if var accumulator = estimatedLightWarmupAccumulators[light.id] {
                    accumulator.add(light)
                    estimatedLightWarmupAccumulators[light.id] = accumulator
                } else {
                    estimatedLightWarmupAccumulators[light.id] = EstimatedLightWarmupAccumulator(light: light)
                }
            }
        }

        let averagedLights = estimatedLightWarmupAccumulators
            .keys
            .sorted()
            .compactMap { estimatedLightWarmupAccumulators[$0]?.averagedLight }

        if let firstLight = averagedLights.first {
            hasBrightRegionEstimatedLight = true
            brightRegionEstimatedLightDirection = firstLight.direction
            brightRegionEstimatedLightPosition = firstLight.position
            brightRegionEstimatedLightColor = firstLight.color
            brightRegionEstimatedLightIntensity = firstLight.intensity
            brightRegionEstimatedLights = averagedLights
        } else {
            hasBrightRegionEstimatedLight = hasLight
            brightRegionEstimatedLightDirection = direction
            brightRegionEstimatedLightPosition = position
            brightRegionEstimatedLightColor = color
            brightRegionEstimatedLightIntensity = intensity
            brightRegionEstimatedLights = lights
        }

        let elapsed = now.timeIntervalSince(estimatedLightWarmupStartedAt ?? now)
        if elapsed >= estimatedLightWarmupFreezeDuration, estimatedLightWarmupSampleCount > 0 {
            isEstimatedLightWarmupFrozen = true
            estimatedLightWarmupFreezeStatus = "Licht-Freeze: fixiert nach \(estimatedLightWarmupSampleCount) Samples"
        } else {
            let displayedSeconds = min(Int(elapsed.rounded(.down)), Int(estimatedLightWarmupFreezeDuration))
            estimatedLightWarmupFreezeStatus = "Licht-Freeze: sammelt \(displayedSeconds)/10 s | Samples \(estimatedLightWarmupSampleCount)"
        }
    }

    private static func normalized(_ vector: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(vector)
        guard length > 0.0001, length.isFinite else {
            return vector
        }

        return vector / length
    }

    func applyPerformanceStressScenario(_ scenario: PerformanceStressScenario) {
        selectedPerformanceStressScenario = scenario
        brightRegionEstimatedLightType = .directional
        brightRegionEstimatedDirectionalLightCount = max(scenario.directionalLightCount, 1)
        isEstimatedEnvironmentLightRenderingEnabled = scenario.directionalLightCount > 0
        areEstimatedDirectionalLightShadowsEnabled = scenario.dynamicShadowCount > 0
        castsOnlyDominantEstimatedDirectionalLightShadow = scenario.dynamicShadowCount <= 1
        areEstimatedSpotLightShadowsEnabled = false
        castsOnlyDominantEstimatedSpotLightShadow = true
        brightRegionSpotLightIntensityDistributionMode = .dividedByLightCount
        isEnvironmentLightingEnabled = true
        environmentLightingWeight = 1
        isCustomImageBasedLightEnabled = false
        areGroundingShadowsEnabled = true
        markBrightRegionTestPresetAsCustom()

        performanceRenderStressStatus = "Render-Stress: \(scenario.title)"
    }

    var activePerformanceDirectionalLightCount: Int {
        guard isEstimatedEnvironmentLightRenderingEnabled,
              hasBrightRegionEstimatedLight,
              brightRegionEstimatedLightType == .directional else {
            return 0
        }

        return brightRegionEstimatedLights
            .prefix(brightRegionEstimatedDirectionalLightCount)
            .filter(\.isPlacementResolved)
            .count
    }

    var activePerformanceDynamicShadowCount: Int {
        guard areEstimatedDirectionalLightShadowsEnabled else { return 0 }
        return castsOnlyDominantEstimatedDirectionalLightShadow
            ? min(activePerformanceDirectionalLightCount, 1)
            : activePerformanceDirectionalLightCount
    }

    nonisolated func recordFPSStressTestFrame(at timestamp: TimeInterval) {
        fpsStressTestRecorder.recordFrame(at: timestamp)
    }

    func startFPSStressTest(
        scenario: PerformanceStressScenario,
        warmupSeconds: Int = 10,
        measurementSeconds: Int = 30
    ) {
        guard !isFPSStressTestRunning else { return }
        guard case .open = immersiveSpaceState else {
            fpsStressTestStatus = "Test 4 braucht einen geoeffneten Immersive Space."
            return
        }
        guard !isRuntimeEvaluationRunning else {
            fpsStressTestStatus = "Bitte zuerst Test 1 beenden."
            return
        }

        environmentProbeReader.pauseAnalysisForFPSStressTest(appModel: self)
        applyPerformanceStressScenario(scenario)

        let activeLightCount = activePerformanceDirectionalLightCount
        let activeShadowCount = activePerformanceDynamicShadowCount
        guard activeLightCount >= scenario.directionalLightCount else {
            fpsStressTestStatus = "Test 4: \(scenario.title) braucht \(scenario.directionalLightCount) aufgeloeste Lichter; aktiv sind \(activeLightCount)."
            return
        }
        guard activeShadowCount >= scenario.dynamicShadowCount else {
            fpsStressTestStatus = "Test 4: \(scenario.title) braucht \(scenario.dynamicShadowCount) aktive Schatten; aktiv sind \(activeShadowCount)."
            return
        }

        isProbeFaceDebugEnabled = false
        areLightProbeDebugSpheresVisible = false
        areRejectedLightPositionDebugSpheresVisible = false
        isSceneReconstructionVisualizationEnabled = false
        isPlaneClassificationVisualizationEnabled = false
        isPlaneVisualizationEnabled = false

        fpsStressTestRecorder.prepare(
            scenario: scenario,
            warmupSeconds: warmupSeconds,
            measurementSeconds: measurementSeconds,
            activeDirectionalLightCount: activeLightCount,
            activeDynamicShadowCount: activeShadowCount
        )
        fpsStressTestActiveDirectionalLightCount = activeLightCount
        fpsStressTestActiveDynamicShadowCount = activeShadowCount
        fpsStressTestLatestFolderURL = nil
        fpsStressTestLatestFileURLs = []
        fpsStressTestPhase = .warmingUp
        fpsStressTestPhaseStartedAt = .now
        fpsStressTestPhaseDurationSeconds = warmupSeconds
        fpsStressTestStatus = "Test 4: Warm-up fuer \(scenario.title)"
        isFPSStressTestRunning = true

        fpsStressTestTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(warmupSeconds))
            } catch {
                return
            }
            guard let self, self.isFPSStressTestRunning else { return }

            self.fpsStressTestRecorder.beginMeasurement()
            self.fpsStressTestPhase = .measuring
            self.fpsStressTestPhaseStartedAt = .now
            self.fpsStressTestPhaseDurationSeconds = measurementSeconds
            self.fpsStressTestStatus = "Test 4: misst \(scenario.title)"

            do {
                try await Task.sleep(for: .seconds(measurementSeconds))
            } catch {
                return
            }
            guard self.isFPSStressTestRunning else { return }
            self.finishFPSStressTest(wasCancelled: false)
        }
    }

    func cancelFPSStressTest() {
        guard isFPSStressTestRunning else { return }
        let hadStartedMeasuring = fpsStressTestPhase == .measuring
        fpsStressTestTask?.cancel()
        fpsStressTestTask = nil

        if hadStartedMeasuring {
            finishFPSStressTest(wasCancelled: true)
        } else {
            fpsStressTestRecorder.cancelWithoutExport()
            isFPSStressTestRunning = false
            fpsStressTestPhase = .idle
            fpsStressTestPhaseStartedAt = nil
            fpsStressTestStatus = "Test 4: im Warm-up abgebrochen (keine CSV)."
        }
    }

    func loadLatestFPSStressTest() {
        do {
            guard let session = try FPSStressTestRecorder.latestSession() else {
                fpsStressTestStatus = "Test 4: noch keine gespeicherte Messung gefunden."
                return
            }
            fpsStressTestLatestFolderURL = session.folderURL
            fpsStressTestLatestFileURLs = session.fileURLs
            fpsStressTestStatus = "Test 4: letzte Messung geladen."
        } catch {
            fpsStressTestStatus = "Test 4 konnte nicht geladen werden: \(error.localizedDescription)"
        }
    }

    private func finishFPSStressTest(wasCancelled: Bool) {
        fpsStressTestTask?.cancel()
        fpsStressTestTask = nil
        isFPSStressTestRunning = false
        fpsStressTestPhase = .idle
        fpsStressTestPhaseStartedAt = nil

        do {
            guard let session = try fpsStressTestRecorder.finish(wasCancelled: wasCancelled) else {
                fpsStressTestStatus = "Test 4: keine aktive Messung."
                return
            }
            fpsStressTestLatestFolderURL = session.folderURL
            fpsStressTestLatestFileURLs = session.fileURLs
            let completion = wasCancelled ? "vorzeitig beendet" : "abgeschlossen"
            let fps = session.averageFPS.map { String(format: "%.1f", $0) } ?? "–"
            let p95 = session.p95FrameTimeMilliseconds.map { String(format: "%.2f", $0) } ?? "–"
            fpsStressTestStatus = "Test 4 \(completion): Ø \(fps) FPS, p95 \(p95) ms."
        } catch {
            fpsStressTestStatus = "Test 4 konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
    }
}
