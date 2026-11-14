//
//  EnvironmentProbeReader.swift
//  AR-Lighting-Study
//

//  Orchestrates Environment Probe capture, analysis, export, and temporal stabilization.
//  It connects ARKit and Metal results to the light state consumed by AppModel and RealityKit.
import ARKit
import CoreImage
import CoreGraphics
import Foundation
import ImageIO
import Metal
import os
import QuartzCore
import simd
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class EnvironmentProbeReader {
    private struct BrightRegionAnalysisSnapshot {
        let measuredRegions: [MeasuredBrightRegion]
        let faceSize: Int
        let originTransform: simd_float4x4
        let thresholds: [Float]
        let environmentAverageLuminance: Float?
        let primaryMergedRegionCount: Int
        let connectedRegionCount: Int
        let mergedRegionCount: Int
    }

    private struct BrightRegionTrackDescriptor {
        let measuredRegion: MeasuredBrightRegion
        let direction: SIMD3<Float>
        let sourcePosition: SIMD3<Float>
        let score: Float
        let pixelCount: Int
        let color: SIMD3<Float>
    }

    private struct StableBrightRegionTrack {
        let stableID: Int
        var direction: SIMD3<Float>
        var sourcePosition: SIMD3<Float>
        var score: Float
        var pixelCount: Int
        var color: SIMD3<Float>
        var missedUpdates: Int
    }

    private struct StableLightAppearanceHistory {
        var directions: [SIMD3<Float>] = []
        var colors: [SIMD3<Float>] = []
        var intensities: [Float] = []
        var shadowSoftnesses: [Float] = []
        var outputDirection: SIMD3<Float>?
        var outputColor: SIMD3<Float>?
        var outputIntensity: Float?
        var outputShadowSoftness: Float?
    }

    private struct TemporalStabilitySettingsSnapshot {
        let selectionHysteresis: Bool
        let positionAverage: Bool
        let directionAverage: Bool
        let colorAverage: Bool
        let intensityAverage: Bool
        let softnessAverage: Bool
        let positionThreshold: Bool
        let appearanceThreshold: Bool
        let freeze: Bool
        let debugSpheres: Bool
        let stableColors: Bool
        let rejectedSpheres: Bool
        let lightType: BrightRegionEstimatedLightType
        let lightCount: Int
        let shadows: Bool
        let dominantShadowOnly: Bool
        let wasSequentialRunning: Bool
    }

    private struct TemporalStabilitySample {
        let step: String
        let index: Int
        let elapsedSeconds: TimeInterval
        let timestamp: Date
        let captureID: Int
        let lightSlot: Int
        let light: BrightRegionEstimatedLightState
        let rawLight: BrightRegionEstimatedLightState?
        let filteredCandidateLight: BrightRegionEstimatedLightState?
        let positionEvaluation: BrightRegionPositionEvaluation?
    }

    private struct TemporalChangeFlags {
        let direction: Bool
        let position: Bool
        let color: Bool
        let intensity: Bool
        let shadowSoftness: Bool

        var any: Bool { direction || position || color || intensity || shadowSoftness }
        var anyAppearance: Bool { direction || color || intensity || shadowSoftness }
    }

    private struct TemporalChangeEvent {
        let previous: TemporalStabilitySample
        let current: TemporalStabilitySample
        let sameStableID: Bool
        let rawChange: TemporalChangeFlags
        let outputChange: TemporalChangeFlags
        let gateOpportunity: TemporalChangeFlags
        let suppressedChange: TemporalChangeFlags
    }

    private enum CubemapFace: Int, CaseIterable {
        case positiveX = 0
        case negativeX = 1
        case positiveY = 2
        case negativeY = 3
        case positiveZ = 4
        case negativeZ = 5
        
        var filenameComponent: String {
            switch self {
            case .positiveX: "positiveX"
            case .negativeX: "negativeX"
            case .positiveY: "positiveY"
            case .negativeY: "negativeY"
            case .positiveZ: "positiveZ"
            case .negativeZ: "negativeZ"
            }
        }
        
        var crossPosition: (column: Int, row: Int) {
            switch self {
            case .positiveY: (1, 0)
            case .negativeX: (0, 1)
            case .positiveZ: (1, 1)
            case .positiveX: (2, 1)
            case .negativeZ: (3, 1)
            case .negativeY: (1, 2)
            }
        }
    }

    private var session: ARKitSession?
    private var lightEstimationProvider: EnvironmentLightEstimationProvider?
    private var worldTrackingProvider: WorldTrackingProvider?
    private let ciContext = CIContext()
    private let datasetStore = EnvironmentProbeDatasetStore()
    private let regionAnalyzer = EnvironmentProbeRegionAnalyzer()
    private let regionMetricsReader = EnvironmentProbeRegionMetricsReader()
    private let lightEstimator = EnvironmentProbeLightEstimator()
    private let fallbackMetalDevice = MTLCreateSystemDefaultDevice()
    private var luminanceAnalyzer: EnvironmentProbeLuminanceAnalyzer?
    private var brightRegionAnalyzer: EnvironmentProbeBrightRegionAnalyzer?
    private var didRunMetalSRGBReadConversionDiagnostic = false
    private var metalSRGBReadConversionDiagnosticSummary: String?
    private var environmentTextureRangeDiagnosticSummary: String?
    private var probeUpdatesTask: Task<Void, Never>?
    private var environmentProbeAnalysisTask: Task<Void, Never>?
    private var sequentialLightUpdateTask: Task<Void, Never>?
    private var environmentProbeSequenceExportTask: Task<Void, Never>?
    private var runtimeEvaluationStopTask: Task<Void, Never>?
    private var sequentialLightUpdateGeneration = 0
    private var environmentProbeSequenceExportGeneration = 0
    private var temporalStabilitySettingsSnapshot: TemporalStabilitySettingsSnapshot?
    private let technicalEvaluationRecorder = TechnicalEvaluationRecorder()
    private var suppressesAnalysisDebugExports = false
    private var didSavePreview = false
    private var isWaitingForFreshPreviewCapture = false
    private var latestBrightRegionAnalysis: BrightRegionAnalysisSnapshot?
    private var latestEnvironmentTextureCaptureID = 0
    private var nextStableBrightRegionID = 1
    private var stableBrightRegionTracks: [StableBrightRegionTrack] = []
    private let stableLightAppearanceHistoryLimit = 10
    private var stableLightAppearanceHistoriesByStableID: [Int: StableLightAppearanceHistory] = [:]
    private let brightRegionHysteresisCandidateLimit = 8
    private let brightRegionHysteresisActiveLimit = 4
    private let brightRegionHysteresisSwitchMargin: Float = 1.5
    private let brightRegionHysteresisRequiredConfirmations = 4
    private let stableBrightRegionMissedUpdateLimit = 10
    private let stableBrightRegionMaximumActiveAngleDegrees: Float = 42
    private let stableBrightRegionMaximumActivePositionDistance: Float = 1.2
    private let stableBrightRegionPositionCostMultiplier: Float = 35
    private let stableBrightRegionMissedUpdateCost: Float = 1.2
    private let stableBrightRegionActiveTrackCostBonus: Float = -3
    private let stableBrightRegionDescriptorBlend: Float = 0.16
    private var activeBrightRegionStableIDs: [Int] = []
    private var pendingBrightRegionSlotSwitches: [Int: (stableID: Int, count: Int)] = [:]
    private let performanceLog = OSLog(subsystem: "AR-Lighting-Study", category: "Performance")
    
    private(set) var latestEnvironmentTexture: (any MTLTexture)?
    private(set) var textureDescription = "Noch keine Environment Probe"
    private(set) var cameraScaleReference: Float = 1
    private(set) var originFromAnchorTransform = simd_float4x4(1)
    private var latestEnvironmentTextureOriginTransform = simd_float4x4(1)

    static let simulatorImportFolderName = "ProbeImport"
    static let simulatorExportFolderName = "ProbeExport"
    
    func start(appModel: AppModel) {
        guard probeUpdatesTask == nil else { return }
        appModel.environmentProbeSessionStatus = "Probe-Reader startet..."

        let session = ARKitSession()
        let lightEstimationProvider = EnvironmentLightEstimationProvider()
        let worldTrackingProvider = WorldTrackingProvider.isSupported
            ? WorldTrackingProvider()
            : nil
        self.session = session
        self.lightEstimationProvider = lightEstimationProvider
        self.worldTrackingProvider = worldTrackingProvider
        
        probeUpdatesTask = Task {
            do {
                guard EnvironmentLightEstimationProvider.isSupported else {
                    textureDescription = "Environment Light Estimation wird auf diesem Geraet nicht unterstuetzt."
                    appModel.canRefreshEnvironmentProbePreview = false
                    appModel.environmentProbeDebugSummary = textureDescription
                    appModel.environmentProbeSessionStatus = textureDescription
                    appModel.environmentProbeAverageLuminance = nil
                    appModel.environmentProbeLuminanceStatus = "Nicht verfuegbar: Environment Light Estimation wird nicht unterstuetzt."
                    return
                }

                let providers: [any DataProvider]
                if let worldTrackingProvider {
                    providers = [lightEstimationProvider, worldTrackingProvider]
                } else {
                    providers = [lightEstimationProvider]
                }
                
                let authorizationResult = await session.requestAuthorization(for: [.worldSensing])
                for (_, authorizationStatus) in authorizationResult where authorizationStatus == .denied {
                    textureDescription = "World-Sensing-Zugriff wurde abgelehnt."
                    appModel.canRefreshEnvironmentProbePreview = false
                    appModel.environmentProbeDebugSummary = textureDescription
                    appModel.environmentProbeSessionStatus = textureDescription
                    appModel.environmentProbeAverageLuminance = nil
                    appModel.environmentProbeLuminanceStatus = "Nicht verfuegbar: World-Sensing-Zugriff wurde abgelehnt."
                    return
                }
                
                try await session.run(providers)
                appModel.environmentProbeSessionStatus = "Probe-Reader aktiv, warte auf Environment Probe..."
                startSequentialLightUpdates(appModel: appModel, interval: .seconds(1))
                
                for await update in lightEstimationProvider.anchorUpdates {
                    let anchor = update.anchor
                    cameraScaleReference = anchor.cameraScaleReference
                    
                    if let texture = anchor.environmentTexture {
                        latestEnvironmentTextureCaptureID += 1
                        technicalEvaluationRecorder.recordProbeArrival(
                            captureID: latestEnvironmentTextureCaptureID
                        )
                        appModel.hasEnvironmentProbeTexture = true
                        appModel.environmentProbeSessionStatus = "Environment Probe empfangen"
                        appModel.isUsingRecordedEnvironmentProbe = false
                        updateSpatialPoseDebug(
                            texture: texture,
                            probeTransform: anchor.originFromAnchorTransform,
                            eventDescription: "\(update.event)",
                            appModel: appModel
                        )
                        await applyEnvironmentTexture(
                            texture,
                            cameraScaleReference: cameraScaleReference,
                            originTransform: anchor.originFromAnchorTransform,
                            appModel: appModel,
                            shouldExportPreview: !suppressesAnalysisDebugExports
                                && (!didSavePreview || isWaitingForFreshPreviewCapture),
                            shouldRecomputeLuminance: false,
                            shouldPublishProbeTransform: false
                        )
                        didSavePreview = true
                        isWaitingForFreshPreviewCapture = false
                    }
                }
            } catch {
                textureDescription = "Environment Probe Fehler: \(error.localizedDescription)"
                appModel.canRefreshEnvironmentProbePreview = false
                appModel.environmentProbeDebugSummary = textureDescription
                appModel.environmentProbeSessionStatus = textureDescription
                appModel.environmentProbeAverageLuminance = nil
                appModel.environmentProbeLuminanceStatus = "Fehlgeschlagen: \(error.localizedDescription)"
                print(textureDescription)
            }
        }
    }
    
    func stop(appModel: AppModel? = nil) {
        environmentProbeSequenceExportTask?.cancel()
        runtimeEvaluationStopTask?.cancel()
        runtimeEvaluationStopTask = nil
        if technicalEvaluationRecorder.isRecording {
            if let appModel {
                finishRuntimeEvaluation(appModel: appModel, wasCancelled: true)
            } else {
                _ = try? technicalEvaluationRecorder.finish()
                suppressesAnalysisDebugExports = false
            }
        }
        probeUpdatesTask?.cancel()
        probeUpdatesTask = nil
        environmentProbeAnalysisTask?.cancel()
        environmentProbeAnalysisTask = nil
        sequentialLightUpdateGeneration += 1
        sequentialLightUpdateTask?.cancel()
        sequentialLightUpdateTask = nil
        // Keep the visible UI state in sync when the immersive space closes.
        appModel?.isSequentialLightUpdateRunning = false
        appModel?.sequentialLightUpdateStatus = "Sequenz: gestoppt"
        session?.stop()
        session = nil
        lightEstimationProvider = nil
        worldTrackingProvider = nil
        stableLightAppearanceHistoriesByStableID.removeAll()
        activeBrightRegionStableIDs.removeAll()
        pendingBrightRegionSlotSwitches.removeAll()
    }
    
    func refreshEnvironmentProbeAnalysis(appModel: AppModel) {
        guard !appModel.isFPSStressTestRunning else {
            appModel.brightRegionMaskStatus = "FPS-Test aktiv: Probe-Analyse pausiert."
            return
        }
        guard !appModel.shouldSkipEstimatedLightAnalysisAfterFreeze else {
            appModel.brightRegionMaskStatus = "Licht-Freeze aktiv: Probe-Analyse gestoppt."
            return
        }

        environmentProbeAnalysisTask?.cancel()
        environmentProbeAnalysisTask = Task {
            _ = await analyzeLatestEnvironmentProbe(appModel: appModel)
        }
    }

    func startSequentialLightUpdates(appModel: AppModel, interval: Duration = .seconds(1)) {
        guard !appModel.isFPSStressTestRunning else {
            appModel.sequentialLightUpdateStatus = "Sequenz: fuer FPS-Test pausiert"
            return
        }
        guard sequentialLightUpdateTask == nil else { return }

        sequentialLightUpdateGeneration += 1
        let generation = sequentialLightUpdateGeneration
        appModel.isSequentialLightUpdateRunning = true
        appModel.sequentialLightUpdateCount = 0
        appModel.sequentialLightUpdateStatus = "Sequenz: startet..."

        sequentialLightUpdateTask = Task {
            defer {
                if generation == sequentialLightUpdateGeneration {
                    appModel.isSequentialLightUpdateRunning = false
                    if Task.isCancelled {
                        appModel.sequentialLightUpdateStatus = "Sequenz: gestoppt"
                    }
                    sequentialLightUpdateTask = nil
                }
            }

            var lastAnalyzedCaptureID: Int?
            while !Task.isCancelled {
                guard !appModel.shouldSkipEstimatedLightAnalysisAfterFreeze else {
                    appModel.sequentialLightUpdateStatus = "Sequenz: Licht-Freeze aktiv"
                    break
                }

                appModel.sequentialLightUpdateCount += 1
                let iteration = appModel.sequentialLightUpdateCount
                appModel.sequentialLightUpdateStatus = "Sequenz: Durchlauf \(iteration) laeuft..."

                let shouldReuseLatestAnalysis = lastAnalyzedCaptureID.map {
                    latestEnvironmentTextureCaptureID <= $0
                } == true && latestBrightRegionAnalysis != nil
                let analyzedCaptureID: Int?
                if shouldReuseLatestAnalysis {
                    analyzedCaptureID = reuseLatestBrightRegionAnalysis(appModel: appModel)
                } else {
                    analyzedCaptureID = await analyzeLatestEnvironmentProbe(appModel: appModel)
                }
                guard !Task.isCancelled else { break }
                lastAnalyzedCaptureID = analyzedCaptureID

                if analyzedCaptureID != nil {
                    appModel.sequentialLightUpdateStatus = shouldReuseLatestAnalysis
                        ? "Sequenz: Durchlauf \(iteration) mit letzter Probe wiederverwendet"
                        : "Sequenz: Durchlauf \(iteration) berechnet"
                } else {
                    appModel.sequentialLightUpdateStatus = "Sequenz: Durchlauf \(iteration) ohne Probe"
                }

                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopSequentialLightUpdates(appModel: AppModel) {
        sequentialLightUpdateGeneration += 1
        sequentialLightUpdateTask?.cancel()
        sequentialLightUpdateTask = nil
        appModel.isSequentialLightUpdateRunning = false
        appModel.sequentialLightUpdateStatus = "Sequenz: gestoppt"
    }

    func pauseAnalysisForFPSStressTest(appModel: AppModel) {
        environmentProbeAnalysisTask?.cancel()
        environmentProbeAnalysisTask = nil
        stopSequentialLightUpdates(appModel: appModel)
        appModel.brightRegionMaskStatus = "FPS-Test: Probe-Analyse pausiert."
    }

    func startRuntimeEvaluation(appModel: AppModel, durationSeconds: Int = 60) {
        guard !appModel.isRuntimeEvaluationRunning else { return }
        guard !appModel.isFPSStressTestRunning else {
            appModel.runtimeEvaluationStatus = "Bitte zuerst Test 4 beenden."
            return
        }
        guard latestEnvironmentTexture != nil else {
            appModel.runtimeEvaluationStatus = "Test 1 kann erst nach der ersten Environment Probe starten."
            return
        }
        guard appModel.hasWorldReferenceAnchorPose else {
            appModel.runtimeEvaluationStatus = "Test 1 wartet noch auf die World-Anchor-Pose."
            return
        }
        guard appModel.canRecomputeBrightRegionLight else {
            appModel.runtimeEvaluationStatus = "Bitte vor Test 1 mindestens eine vollstaendige Probe-Analyse abwarten."
            return
        }
        guard environmentProbeSequenceExportTask == nil else {
            appModel.runtimeEvaluationStatus = "Bitte zuerst den 60s-Sequenzexport stoppen."
            return
        }

        do {
            let folderURL = try technicalEvaluationRecorder.startRuntimeTest(
                durationSeconds: durationSeconds,
                analysisIntervalSeconds: 1
            )
            suppressesAnalysisDebugExports = true
            appModel.isRuntimeEvaluationRunning = true
            appModel.runtimeEvaluationStartedAt = .now
            appModel.runtimeEvaluationDurationSeconds = durationSeconds
            appModel.runtimeEvaluationLatestFolderURL = folderURL
            appModel.runtimeEvaluationLatestFileURLs = []
            appModel.runtimeEvaluationStatus = "Test 1 laeuft: \(durationSeconds) s, 1 s Analyseintervall, Debug-Exporte aus"

            appModel.freezesEstimatedLightAfterWarmup = false
            appModel.resetEstimatedLightWarmupFreeze()
            environmentProbeAnalysisTask?.cancel()
            environmentProbeAnalysisTask = nil
            stopSequentialLightUpdates(appModel: appModel)
            startSequentialLightUpdates(appModel: appModel, interval: .seconds(1))

            runtimeEvaluationStopTask?.cancel()
            runtimeEvaluationStopTask = Task {
                try? await Task.sleep(for: .seconds(durationSeconds))
                guard !Task.isCancelled else { return }
                finishRuntimeEvaluation(appModel: appModel, wasCancelled: false)
            }
        } catch {
            suppressesAnalysisDebugExports = false
            appModel.isRuntimeEvaluationRunning = false
            appModel.runtimeEvaluationStartedAt = nil
            appModel.runtimeEvaluationStatus = "Test 1 konnte nicht starten: \(error.localizedDescription)"
        }
    }

    func stopRuntimeEvaluation(appModel: AppModel) {
        guard appModel.isRuntimeEvaluationRunning || technicalEvaluationRecorder.isRecording else { return }
        runtimeEvaluationStopTask?.cancel()
        runtimeEvaluationStopTask = nil
        finishRuntimeEvaluation(appModel: appModel, wasCancelled: true)
    }

    func loadLatestRuntimeEvaluation(appModel: AppModel) {
        guard !appModel.isRuntimeEvaluationRunning else { return }

        do {
            guard let session = try TechnicalEvaluationRecorder.latestRuntimeTestSession() else {
                appModel.runtimeEvaluationStatus = "Test 1: noch keine gespeicherte Messung"
                appModel.runtimeEvaluationLatestFolderURL = nil
                appModel.runtimeEvaluationLatestFileURLs = []
                return
            }
            appModel.runtimeEvaluationLatestFolderURL = session.folderURL
            appModel.runtimeEvaluationLatestFileURLs = session.fileURLs
            appModel.runtimeEvaluationStatus = "Letzte Test-1-Messung geladen: \(session.folderURL.lastPathComponent)"
        } catch {
            appModel.runtimeEvaluationStatus = "Letzte Test-1-Messung konnte nicht geladen werden: \(error.localizedDescription)"
        }
    }

    private func finishRuntimeEvaluation(appModel: AppModel, wasCancelled: Bool) {
        runtimeEvaluationStopTask = nil
        stopSequentialLightUpdates(appModel: appModel)
        suppressesAnalysisDebugExports = false
        appModel.isRuntimeEvaluationRunning = false
        appModel.runtimeEvaluationStartedAt = nil

        do {
            guard let session = try technicalEvaluationRecorder.finish() else {
                appModel.runtimeEvaluationStatus = "Test 1: keine aktive Messung"
                return
            }
            appModel.runtimeEvaluationLatestFolderURL = session.folderURL
            appModel.runtimeEvaluationLatestFileURLs = session.fileURLs
            let completion = wasCancelled ? "vorzeitig beendet" : "abgeschlossen"
            appModel.runtimeEvaluationStatus = "Test 1 \(completion): \(session.probeArrivalCount) Probes, \(session.analysisCount) Analysen, \(String(format: "%.1f", session.durationSeconds)) s"
        } catch {
            appModel.runtimeEvaluationStatus = "Test 1 konnte nicht abgeschlossen werden: \(error.localizedDescription)"
        }
    }

    private func analyzeLatestEnvironmentProbe(appModel: AppModel) async -> Int? {
        guard !appModel.isFPSStressTestRunning else {
            appModel.brightRegionMaskStatus = "FPS-Test aktiv: Probe-Analyse pausiert."
            return nil
        }
        guard !appModel.shouldSkipEstimatedLightAnalysisAfterFreeze else {
            appModel.brightRegionMaskStatus = "Licht-Freeze aktiv: Probe-Analyse gestoppt."
            return nil
        }

        guard let texture = latestEnvironmentTexture else {
            textureDescription = "Noch keine Environment Probe"
            appModel.canRefreshEnvironmentProbePreview = false
            appModel.environmentProbeDebugSummary = textureDescription
            appModel.hasEnvironmentProbeTexture = false
            appModel.environmentProbeAverageLuminance = nil
            appModel.environmentProbeLuminanceStatus = "Noch nicht berechnet: keine Environment Probe vorhanden."
            appModel.brightRegionMaskStatus = "Noch nicht berechnet: keine Environment Probe vorhanden."
            appModel.brightRegionMaskDebugSummary = "Noch keine Environment Probe fuer die Bright-Region-Maske."
            appModel.hasBrightRegionEstimatedLight = false
            appModel.brightRegionEstimatedLightDirection = SIMD3<Float>(repeating: 0)
            appModel.brightRegionEstimatedLightIntensity = 0
            appModel.brightRegionEstimatedLights = []
            appModel.brightRegionRawEstimatedLights = []
            appModel.brightRegionFilteredCandidateLights = []
            appModel.brightRegionEstimatedLightPlacementDebugLine = "Placement: nicht verfuegbar"
            appModel.brightRegionEstimatedLightTotalIntensityDebugLine = "Gesamthelligkeit: nicht verfuegbar"
            appModel.canRecomputeBrightRegionLight = false
            appModel.brightRegionPlaneHitDebugSamples = []
            latestBrightRegionAnalysis = nil
            stableBrightRegionTracks = []
            stableLightAppearanceHistoriesByStableID.removeAll()
            activeBrightRegionStableIDs.removeAll()
            pendingBrightRegionSlotSwitches.removeAll()
            return nil
        }
        guard appModel.hasWorldReferenceAnchorPose else {
            appModel.environmentProbeDebugSummary = "Warte auf WorldAnchor-Korrektur vor Lichtanalyse."
            appModel.environmentProbeLuminanceStatus = "Warte auf WorldAnchor-Korrektur."
            appModel.brightRegionMaskStatus = "Warte auf WorldAnchor-Korrektur vor Lichtanalyse."
            appModel.canRecomputeBrightRegionLight = false
            return nil
        }
        let capturedTextureCaptureID = latestEnvironmentTextureCaptureID
        let analysisStartTime = CACurrentMediaTime()
        var analysisSucceeded = false
        let analysisSignpostID = OSSignpostID(log: performanceLog)
        os_signpost(
            .begin,
            log: performanceLog,
            name: "ProbeAnalysis",
            signpostID: analysisSignpostID,
            "captureID %d",
            capturedTextureCaptureID
        )
        defer {
            let totalMilliseconds = (CACurrentMediaTime() - analysisStartTime) * 1000
            os_signpost(
                .end,
                log: performanceLog,
                name: "ProbeAnalysis",
                signpostID: analysisSignpostID,
                "captureID %d totalMS %.2f lights %d regions %d",
                capturedTextureCaptureID,
                totalMilliseconds,
                appModel.brightRegionEstimatedLights.count,
                latestBrightRegionAnalysis?.measuredRegions.count ?? 0
            )
            appModel.performanceTraceStatus = "Trace: capture \(capturedTextureCaptureID) | total \(String(format: "%.1f", totalMilliseconds)) ms | lights \(appModel.brightRegionEstimatedLights.count) | regions \(latestBrightRegionAnalysis?.measuredRegions.count ?? 0)"
            technicalEvaluationRecorder.recordAnalysis(
                captureID: capturedTextureCaptureID,
                durationMilliseconds: totalMilliseconds,
                succeeded: analysisSucceeded,
                lightCount: appModel.brightRegionEstimatedLights.count,
                regionCount: latestBrightRegionAnalysis?.measuredRegions.count ?? 0
            )
        }
        let capturedCameraScaleReference = cameraScaleReference
        let capturedOriginTransform = latestEnvironmentTextureOriginTransform
        let analysisOriginTransform = environmentProbeAnalysisTransform(
            from: capturedOriginTransform,
            appModel: appModel
        )
        appModel.environmentProbeDebugSummary = "Neueste Probe wird vollstaendig ausgewertet..."
        appModel.environmentProbeLuminanceStatus = "Luminanzberechnung laeuft..."
        appModel.brightRegionMaskStatus = "Warte auf Luminanz, dann Maskenberechnung..."
        appModel.canRecomputeBrightRegionLight = false

        await applyEnvironmentTexture(
            texture,
            cameraScaleReference: capturedCameraScaleReference,
            originTransform: capturedOriginTransform,
            appModel: appModel,
            shouldExportPreview: !suppressesAnalysisDebugExports,
            shouldRecomputeLuminance: true,
            shouldPublishProbeTransform: true
        )
        guard !Task.isCancelled else { return nil }
        guard !appModel.shouldSkipEstimatedLightAnalysisAfterFreeze else {
            appModel.brightRegionMaskStatus = "Licht-Freeze aktiv: Probe-Analyse gestoppt."
            return nil
        }
        await updateBrightRegionMask(
            from: texture,
            originTransform: analysisOriginTransform,
            appModel: appModel,
            shouldExportPreview: !suppressesAnalysisDebugExports
        )
        analysisSucceeded = appModel.canRecomputeBrightRegionLight
        return analysisSucceeded ? capturedTextureCaptureID : nil
    }

    func recomputeEstimatedLight(appModel: AppModel) {
        guard !appModel.isFPSStressTestRunning else {
            appModel.brightRegionMaskStatus = "FPS-Test aktiv: Licht-Neuschaetzung pausiert."
            return
        }
        guard !appModel.shouldSkipEstimatedLightAnalysisAfterFreeze else {
            appModel.brightRegionMaskStatus = "Licht-Freeze aktiv: Licht-Neuschaetzung gestoppt."
            return
        }

        guard let latestBrightRegionAnalysis else {
            appModel.brightRegionMaskStatus = "Noch nicht moeglich: erst Probe und Maske aktualisieren."
            appModel.brightRegionMaskDebugSummary = "Keine gecachte Bright-Region-Maske fuer die Licht-Neuschaetzung vorhanden."
            appModel.hasBrightRegionEstimatedLight = false
            appModel.brightRegionEstimatedLightDirection = SIMD3<Float>(repeating: 0)
            appModel.brightRegionEstimatedLightIntensity = 0
            appModel.brightRegionEstimatedLights = []
            appModel.brightRegionRawEstimatedLights = []
            appModel.brightRegionFilteredCandidateLights = []
            stableLightAppearanceHistoriesByStableID.removeAll()
            activeBrightRegionStableIDs.removeAll()
            pendingBrightRegionSlotSwitches.removeAll()
            appModel.brightRegionEstimatedLightDebugLine = "Noch keine dominante Lichtquelle geschaetzt"
            appModel.brightRegionEstimatedLightPositionDebugLine = "Position: nicht verfuegbar"
            appModel.brightRegionEstimatedLightPlacementDebugLine = "Placement: nicht verfuegbar"
            appModel.brightRegionEstimatedLightTotalIntensityDebugLine = "Gesamthelligkeit: nicht verfuegbar"
            appModel.canRecomputeBrightRegionLight = false
            appModel.brightRegionRegionBaseDebugLines = []
            return
        }

        updateEstimatedLight(from: latestBrightRegionAnalysis, appModel: appModel)
        appModel.brightRegionMaskStatus = "Berechnet: Licht mit aktueller Maske neu geschaetzt."
    }

    private func reuseLatestBrightRegionAnalysis(appModel: AppModel) -> Int? {
        guard !appModel.shouldSkipEstimatedLightAnalysisAfterFreeze else {
            appModel.brightRegionMaskStatus = "Licht-Freeze aktiv: Wiederverwendung der letzten Probe gestoppt."
            return nil
        }

        guard appModel.hasWorldReferenceAnchorPose else {
            appModel.brightRegionMaskStatus = "Warte auf WorldAnchor-Korrektur vor Wiederverwendung der letzten Probe."
            return nil
        }

        guard latestBrightRegionAnalysis != nil else {
            return nil
        }

        appModel.brightRegionMaskStatus = "Berechnet: Letztes finales Lichtergebnis unveraendert wiederverwendet."
        return latestEnvironmentTextureCaptureID
    }

    private func updateSpatialPoseDebug(
        texture: any MTLTexture,
        probeTransform: simd_float4x4,
        eventDescription: String,
        appModel: AppModel
    ) {
        let timestamp = CACurrentMediaTime()
        let deviceTransform = worldTrackingProvider?
            .queryDeviceAnchor(atTimestamp: timestamp)?
            .originFromAnchorTransform
        let brightestFace = brightestCubemapFace(in: texture)
        let effectiveProbeTransform = environmentProbeAnalysisTransform(
            from: probeTransform,
            appModel: appModel
        )

        let rawProbeDescription = poseDebugDescription(
            label: "Probe raw",
            transform: probeTransform
        )
        let effectiveProbeDescription = poseDebugDescription(
            label: "Probe effective",
            transform: effectiveProbeTransform
        )
        let deviceDescription = deviceTransform.map {
            poseDebugDescription(label: "Device", transform: $0)
        } ?? "Device: nicht verfuegbar"
        let brightestFaceDescription = brightestFace.map { face in
            let localDirection = localCubemapDirection(for: face.face)
            let rawWorldDirection = worldDirection(from: localDirection, transform: probeTransform)
            let effectiveWorldDirection = worldDirection(from: localDirection, transform: effectiveProbeTransform)
            return "Brightest face: \(faceName(for: face.face)) avgLum \(String(format: "%.4f", face.averageLuminance)) | local \(formatDirection(localDirection)) | rawWorld \(formatDirection(rawWorldDirection)), yaw \(formatYaw(rawWorldDirection)) | effectiveWorld \(formatDirection(effectiveWorldDirection)), yaw \(formatYaw(effectiveWorldDirection))"
        } ?? "Brightest face: nicht verfuegbar"

        let debugLine = "SpatialDebug session \(appModel.environmentProbeUpdateCount) event \(eventDescription) | \(deviceDescription) | \(rawProbeDescription) | \(effectiveProbeDescription) | \(brightestFaceDescription)"
        print(debugLine)
    }
    
    func saveCurrentDataset(appModel: AppModel) {
        guard let texture = latestEnvironmentTexture else {
            appModel.environmentProbeDatasetStatus = "Kein aktuelles Probe-Texture zum Speichern vorhanden."
            return
        }
        
        Task {
            do {
                let folderURL = try await datasetStore.saveDataset(
                    from: texture,
                    cameraScaleReference: cameraScaleReference,
                    originFromAnchorTransform: originFromAnchorTransform
                )
                appModel.environmentProbeLatestDatasetFolderURL = folderURL
                appModel.environmentProbeLatestDatasetFileURLs = (try? datasetStore.datasetFileURLs(at: folderURL)) ?? []
                appModel.environmentProbeDatasetStatus = "Dataset gespeichert: \(folderURL.lastPathComponent)"
            } catch {
                appModel.environmentProbeDatasetStatus = "Dataset-Speichern fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }
    
    func loadLatestRecordedDataset(appModel: AppModel) {
        environmentProbeAnalysisTask?.cancel()
        environmentProbeAnalysisTask = Task {
            do {
                guard let device = latestEnvironmentTexture?.device ?? fallbackMetalDevice else {
                    appModel.environmentProbeDatasetStatus = "Kein Metal-Device zum Laden des Datasets verfuegbar."
                    return
                }
                
                let loadedDataset = try datasetStore.loadLatestDataset(device: device)
                guard let loadedTransform = loadedDataset.originFromAnchorTransform else {
                    appModel.environmentProbeDatasetStatus = "Dataset geladen, aber Transform-Matrix ist ungueltig."
                    appModel.canRecomputeBrightRegionLight = false
                    return
                }
                
                appModel.environmentProbeLatestDatasetFolderURL = loadedDataset.folderURL
                appModel.environmentProbeLatestDatasetFileURLs = (try? datasetStore.datasetFileURLs(at: loadedDataset.folderURL)) ?? []
                appModel.environmentProbeDatasetStatus = "Dataset geladen: \(loadedDataset.folderURL.lastPathComponent)"
                appModel.isUsingRecordedEnvironmentProbe = true
                appModel.hasEnvironmentProbeTexture = true
                appModel.environmentProbeSessionStatus = "Recorded Dataset geladen"
                appModel.canRecomputeBrightRegionLight = false
                latestEnvironmentTextureCaptureID += 1
                let analysisOriginTransform = environmentProbeAnalysisTransform(
                    from: loadedTransform,
                    appModel: appModel
                )
                updateSpatialPoseDebug(
                    texture: loadedDataset.texture,
                    probeTransform: loadedTransform,
                    eventDescription: "recorded-dataset",
                    appModel: appModel
                )
                
                await applyEnvironmentTexture(
                    loadedDataset.texture,
                    cameraScaleReference: loadedDataset.metadata.cameraScaleReference,
                    originTransform: loadedTransform,
                    appModel: appModel,
                    shouldExportPreview: true,
                    shouldRecomputeLuminance: true,
                    shouldPublishProbeTransform: true
                )
                guard !Task.isCancelled else { return }
                await updateBrightRegionMask(
                    from: loadedDataset.texture,
                    originTransform: analysisOriginTransform,
                    appModel: appModel
                )
            } catch {
                appModel.environmentProbeDatasetStatus = "Dataset-Laden fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }
    
    func importDataset(appModel: AppModel, from folderURL: URL) {
        Task {
            do {
                let importedFolderURL = try datasetStore.importDataset(from: folderURL)
                appModel.environmentProbeLatestDatasetFolderURL = importedFolderURL
                appModel.environmentProbeLatestDatasetFileURLs = (try? datasetStore.datasetFileURLs(at: importedFolderURL)) ?? []
                appModel.environmentProbeDatasetStatus = "Dataset importiert: \(importedFolderURL.lastPathComponent)"
                loadLatestRecordedDataset(appModel: appModel)
            } catch {
                appModel.environmentProbeDatasetStatus = "Dataset-Import fehlgeschlagen : \(error.localizedDescription)"
            }
        }
    }
    
    func importDatasetFiles(appModel: AppModel, from fileURLs: [URL]) {
        Task {
            do {
                let importedFolderURL = try datasetStore.importDatasetFiles(from: fileURLs)
                appModel.environmentProbeLatestDatasetFolderURL = importedFolderURL
                appModel.environmentProbeLatestDatasetFileURLs = (try? datasetStore.datasetFileURLs(at: importedFolderURL)) ?? []
                appModel.environmentProbeDatasetStatus = "Dataset-Dateien importiert: \(importedFolderURL.lastPathComponent)"
                loadLatestRecordedDataset(appModel: appModel)
            } catch {
                appModel.environmentProbeDatasetStatus = "Dataset-Import fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }
    
    func importDatasetFromSimulatorDownloads(appModel: AppModel) {
#if targetEnvironment(simulator)
        Task {
            do {
                let downloadsURL = simulatorImportFolderURL()
                
                let importedFolderURL = try datasetStore.importDataset(from: downloadsURL)
                appModel.environmentProbeLatestDatasetFolderURL = importedFolderURL
                appModel.environmentProbeLatestDatasetFileURLs = (try? datasetStore.datasetFileURLs(at: importedFolderURL)) ?? []
                appModel.environmentProbeDatasetStatus = "Simulator-Dataset importiert: \(importedFolderURL.lastPathComponent)"
                loadLatestRecordedDataset(appModel: appModel)
            } catch {
                let importPath = simulatorImportFolderURL().path(percentEncoded: false)
                appModel.environmentProbeDatasetStatus = "Simulator-Import fehlgeschlagen: \(error.localizedDescription) | erwartet unter \(importPath)"
            }
        }
#else
        appModel.environmentProbeDatasetStatus = "Direktimport aus Downloads ist nur im Simulator verfuegbar."
#endif
    }
    
    func exportCurrentProbePackage(appModel: AppModel) {
        guard let luminance = appModel.environmentProbeAverageLuminance else {
            appModel.environmentProbeExportStatus = "Export fehlgeschlagen: Bitte erst 'Probe komplett aktualisieren' ausfuehren."
            return
        }
        
        guard let probePreviewURL = preferredProbePreviewURL(from: appModel.environmentProbePreviewURLs) else {
            appModel.environmentProbeExportStatus = "Export fehlgeschlagen: Keine exportierte Probe-Cubemap vorhanden."
            return
        }
        let nearestProbePreviewURL = preferredNearestProbePreviewURL(from: appModel.environmentProbePreviewURLs)
        
        guard let maskPreviewURL = appModel.brightRegionMaskPreviewURLs.first else {
            appModel.environmentProbeExportStatus = "Export fehlgeschlagen: Bitte erst 'Probe komplett aktualisieren' ausfuehren."
            return
        }
        
        do {
            let package = try createProbeExportPackage(
                probePreviewURL: probePreviewURL,
                nearestProbePreviewURL: nearestProbePreviewURL,
                maskPreviewURL: maskPreviewURL,
                averageLuminance: luminance
            )
            
            appModel.environmentProbeLatestExportFolderURL = package.folderURL
            appModel.environmentProbeLatestExportFileURLs = package.fileURLs
            
#if targetEnvironment(simulator)
            let hostExportFolderURL = try copyProbeExportPackageToSimulatorDownloads(package)
            appModel.environmentProbeExportStatus = "Probe-Paket nach Mac exportiert: \(hostExportFolderURL.path(percentEncoded: false))"
#else
            appModel.environmentProbeExportStatus = "Probe-Paket bereit zum Teilen per AirDrop."
#endif
        } catch {
            appModel.environmentProbeExportStatus = "Export fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func startProbeSequenceExport(
        appModel: AppModel,
        mode: TemporalStabilityTestMode? = nil
    ) {
        guard environmentProbeSequenceExportTask == nil else { return }
        guard !appModel.isRuntimeEvaluationRunning, !appModel.isFPSStressTestRunning else {
            appModel.environmentProbeSequenceExportStatus = "Test 2 kann nicht parallel zu Test 1 oder Test 4 laufen."
            return
        }
        guard latestEnvironmentTexture != nil else {
            appModel.environmentProbeSequenceExportStatus = "Test 2 fehlgeschlagen: Noch keine Environment Probe."
            return
        }

        let selectedMode = mode ?? appModel.selectedTemporalStabilityTestMode
        temporalStabilitySettingsSnapshot = captureTemporalStabilitySettings(appModel: appModel)
        stopSequentialLightUpdates(appModel: appModel)
        configureTemporalStabilityTest(selectedMode, appModel: appModel)
        environmentProbeSequenceExportGeneration += 1
        let generation = environmentProbeSequenceExportGeneration
        appModel.isEnvironmentProbeSequenceExportRunning = true
        appModel.selectedTemporalStabilityTestMode = selectedMode
        appModel.temporalStabilityTestStartedAt = .now
        appModel.environmentProbeSequenceExportStatus = "Test 2 (\(selectedMode.title)) startet..."
        appModel.environmentProbeLatestSequenceExportFolderURL = nil
        appModel.environmentProbeLatestSequenceExportFileURLs = []

        environmentProbeSequenceExportTask = Task {
            defer {
                if generation == environmentProbeSequenceExportGeneration {
                    appModel.isEnvironmentProbeSequenceExportRunning = false
                    appModel.temporalStabilityTestStartedAt = nil
                    environmentProbeSequenceExportTask = nil
                    restoreTemporalStabilitySettings(appModel: appModel)
                }
            }

            do {
                let sequence = try makeProbeSequenceExportFolder(mode: selectedMode)
                let startedAt = Date()
                let durationSeconds = 60
                let intervalSeconds = 2
                let maxStepCount = Int(durationSeconds / intervalSeconds) + 1
                var lastExportedCaptureID: Int?
                var exportedFiles: [URL] = [
                    sequence.timelineURL,
                    sequence.lightParametersURL,
                    sequence.changeEventsURL,
                    sequence.summaryURL
                ]
                var samples: [TemporalStabilitySample] = []
                var timelineRows = [
                    "step,index,elapsed_seconds,timestamp,capture_id,status,average_luminance,light_count,dominant_stable_id,environment_file,nearest_file,mask_file"
                ]

                try sequenceInfoText(
                    startedAt: startedAt,
                    durationSeconds: durationSeconds,
                    intervalSeconds: intervalSeconds,
                    maxStepCount: maxStepCount,
                    mode: selectedMode
                ).write(to: sequence.infoURL, atomically: true, encoding: .utf8)
                exportedFiles.append(sequence.infoURL)

                try temporalLightParametersCSV(samples).write(
                    to: sequence.lightParametersURL,
                    atomically: true,
                    encoding: .utf8
                )
                try temporalChangeEventsCSV(samples).write(
                    to: sequence.changeEventsURL,
                    atomically: true,
                    encoding: .utf8
                )

                for index in 0..<maxStepCount {
                    guard !Task.isCancelled else { break }

                    let scheduledAt = startedAt.addingTimeInterval(TimeInterval(index * intervalSeconds))
                    let delay = scheduledAt.timeIntervalSinceNow
                    if delay > 0 {
                        try? await Task.sleep(for: .seconds(delay))
                    }
                    guard !Task.isCancelled else { break }

                    let stepName = String(format: "step-%03d", index)
                    appModel.environmentProbeSequenceExportStatus = "Sequenz-Export: wartet auf frische Probe fuer \(stepName)..."
                    guard let freshCaptureID = await waitForFreshEnvironmentProbeCapture(
                        after: lastExportedCaptureID,
                        timeoutSeconds: intervalSeconds
                    ) else {
                        let timestamp = Date()
                        let elapsedSeconds = timestamp.timeIntervalSince(startedAt)
                        timelineRows.append(sequenceTimelineRow(
                            stepName: stepName,
                            index: index,
                            elapsedSeconds: elapsedSeconds,
                            timestamp: timestamp,
                            captureID: nil,
                            status: "no_fresh_capture",
                            averageLuminance: nil,
                            lights: [],
                            hasFiles: false
                        ))
                        try timelineRows.joined(separator: "\n")
                            .appending("\n")
                            .write(to: sequence.timelineURL, atomically: true, encoding: .utf8)
                        appModel.environmentProbeSequenceExportStatus = "Sequenz-Export: \(stepName) uebersprungen, keine neue Probe"
                        continue
                    }

                    appModel.environmentProbeSequenceExportStatus = "Sequenz-Export: \(stepName) wird berechnet..."
                    let captureID = await analyzeLatestEnvironmentProbe(appModel: appModel)
                    let placementRequestID = appModel.brightRegionLightPlacementRequestID
                    let placementCompleted = await waitForLightPlacement(
                        requestID: placementRequestID,
                        appModel: appModel,
                        timeoutSeconds: 1.0
                    )
                    let timestamp = Date()
                    let elapsedSeconds = timestamp.timeIntervalSince(startedAt)
                    guard let captureID else {
                        timelineRows.append(sequenceTimelineRow(
                            stepName: stepName,
                            index: index,
                            elapsedSeconds: elapsedSeconds,
                            timestamp: timestamp,
                            captureID: captureID,
                            status: "analysis_failed",
                            averageLuminance: appModel.environmentProbeAverageLuminance,
                            lights: [],
                            hasFiles: false
                        ))
                        try timelineRows.joined(separator: "\n")
                            .appending("\n")
                            .write(to: sequence.timelineURL, atomically: true, encoding: .utf8)
                        appModel.environmentProbeSequenceExportStatus = "Sequenz-Export: \(stepName) ohne Export, Analyse fehlgeschlagen"
                        lastExportedCaptureID = freshCaptureID
                        continue
                    }

                    let stepFolderURL = sequence.folderURL.appending(path: stepName, directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: stepFolderURL, withIntermediateDirectories: true)

                    let step = try exportCurrentProbeSequenceStep(
                        to: stepFolderURL,
                        index: index,
                        stepName: stepName,
                        timestamp: timestamp,
                        elapsedSeconds: elapsedSeconds,
                        captureID: captureID,
                        mode: selectedMode,
                        appModel: appModel
                    )
                    exportedFiles.append(contentsOf: step.fileURLs)
                    timelineRows.append(step.timelineRow)
                    samples.append(contentsOf: appModel.brightRegionEstimatedLights.enumerated().map { slot, light in
                        let rawAppearanceLight = appModel.brightRegionRawEstimatedLights.first {
                            $0.sourceRegionStableID == light.sourceRegionStableID
                        } ?? (appModel.brightRegionRawEstimatedLights.indices.contains(slot)
                            ? appModel.brightRegionRawEstimatedLights[slot]
                            : nil)
                        let filteredAppearanceCandidate = appModel.brightRegionFilteredCandidateLights.first {
                            $0.sourceRegionStableID == light.sourceRegionStableID
                        } ?? (appModel.brightRegionFilteredCandidateLights.indices.contains(slot)
                            ? appModel.brightRegionFilteredCandidateLights[slot]
                            : nil)
                        let positionEvaluation = appModel.brightRegionPositionEvaluationsByStableID[light.sourceRegionStableID]
                            .flatMap { evaluation in
                                evaluation.placementRequestID == placementRequestID ? evaluation : nil
                            }
                        let outputLight = positionEvaluation.map {
                            Self.light(light, replacingPositionWith: $0.outputPosition)
                        } ?? light
                        let rawLight = positionEvaluation.flatMap { evaluation in
                            rawAppearanceLight.map {
                                Self.light($0, replacingPositionWith: evaluation.rawPosition)
                            }
                        } ?? rawAppearanceLight
                        let filteredCandidateLight = positionEvaluation.flatMap { evaluation in
                            filteredAppearanceCandidate.map {
                                Self.light($0, replacingPositionWith: evaluation.candidatePosition)
                            }
                        } ?? filteredAppearanceCandidate
                        return TemporalStabilitySample(
                            step: stepName,
                            index: index,
                            elapsedSeconds: elapsedSeconds,
                            timestamp: timestamp,
                            captureID: captureID,
                            lightSlot: slot,
                            light: outputLight,
                            rawLight: rawLight,
                            filteredCandidateLight: filteredCandidateLight,
                            positionEvaluation: positionEvaluation
                        )
                    })
                    try timelineRows.joined(separator: "\n")
                        .appending("\n")
                        .write(to: sequence.timelineURL, atomically: true, encoding: .utf8)
                    try temporalLightParametersCSV(samples).write(
                        to: sequence.lightParametersURL,
                        atomically: true,
                        encoding: .utf8
                    )
                    try temporalChangeEventsCSV(samples).write(
                        to: sequence.changeEventsURL,
                        atomically: true,
                        encoding: .utf8
                    )

                    lastExportedCaptureID = captureID
                    appModel.environmentProbeSequenceExportStatus = placementCompleted
                        ? "Sequenz-Export: \(stepName) gespeichert"
                        : "Sequenz-Export: \(stepName) gespeichert, Placement-Timeout"
                }

                try temporalStabilitySummaryCSV(
                    samples: samples,
                    mode: selectedMode,
                    startedAt: startedAt,
                    finishedAt: .now,
                    positionMinimumChange: appModel.stableLightPositionMinimumChange
                ).write(to: sequence.summaryURL, atomically: true, encoding: .utf8)

                appModel.environmentProbeLatestSequenceExportFolderURL = sequence.folderURL
                appModel.environmentProbeLatestSequenceExportFileURLs = exportedFiles

#if targetEnvironment(simulator)
                let hostExportFolderURL = try copyExportFolderToSimulatorDownloads(sequence.folderURL)
                appModel.environmentProbeSequenceExportStatus = Task.isCancelled
                    ? "Test 2 gestoppt: \(hostExportFolderURL.path(percentEncoded: false))"
                    : "Test 2 nach Mac exportiert: \(hostExportFolderURL.path(percentEncoded: false))"
#else
                appModel.environmentProbeSequenceExportStatus = Task.isCancelled
                    ? "Test 2 gestoppt; Teilergebnis ist verfuegbar."
                    : "Test 2 abgeschlossen und bereit zum Teilen per AirDrop."
#endif
            } catch {
                appModel.environmentProbeSequenceExportStatus = "Test 2 fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }

    func stopProbeSequenceExport(appModel: AppModel) {
        environmentProbeSequenceExportTask?.cancel()
        appModel.environmentProbeSequenceExportStatus = "Test 2 wird beendet und das Teilergebnis gespeichert..."
    }
    
#if targetEnvironment(simulator)
    private func simulatorImportFolderURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        let hostHomePath =
        environment["SIMULATOR_HOST_HOME"] ??
        environment["HOME"] ??
        "/Users/\(NSUserName())"
        
        return URL(fileURLWithPath: hostHomePath, isDirectory: true)
            .appending(path: "Downloads", directoryHint: .isDirectory)
            .appending(path: Self.simulatorImportFolderName, directoryHint: .isDirectory)
    }
    
    private func simulatorExportRootFolderURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        let hostHomePath =
        environment["SIMULATOR_HOST_HOME"] ??
        environment["HOME"] ??
        "/Users/\(NSUserName())"
        
        return URL(fileURLWithPath: hostHomePath, isDirectory: true)
            .appending(path: "Downloads", directoryHint: .isDirectory)
            .appending(path: Self.simulatorExportFolderName, directoryHint: .isDirectory)
    }
#endif
    
    func refreshDatasetStatus(appModel: AppModel) {
        do {
            let latestFolderURL = try datasetStore.latestDatasetFolderURL()
            appModel.environmentProbeLatestDatasetFolderURL = latestFolderURL
            appModel.environmentProbeLatestDatasetFileURLs = (try? datasetStore.datasetFileURLs(at: latestFolderURL)) ?? []
            appModel.environmentProbeDatasetStatus = "Letztes Dataset: \(latestFolderURL.lastPathComponent)"
        } catch {
            appModel.environmentProbeDatasetStatus = "Noch kein Probe-Dataset gespeichert"
            appModel.environmentProbeLatestDatasetFileURLs = []
        }
    }
    
    private func applyEnvironmentTexture(
        _ texture: any MTLTexture,
        cameraScaleReference: Float,
        originTransform: simd_float4x4,
        appModel: AppModel,
        shouldExportPreview: Bool,
        shouldRecomputeLuminance: Bool,
        shouldPublishProbeTransform: Bool
    ) async {
        let signpostID = OSSignpostID(log: performanceLog)
        os_signpost(
            .begin,
            log: performanceLog,
            name: "ApplyEnvironmentTexture",
            signpostID: signpostID,
            "luminance %d preview %d",
            shouldRecomputeLuminance ? 1 : 0,
            shouldExportPreview ? 1 : 0
        )
        defer {
            os_signpost(
                .end,
                log: performanceLog,
                name: "ApplyEnvironmentTexture",
                signpostID: signpostID
            )
        }

        latestEnvironmentTexture = texture
        self.cameraScaleReference = cameraScaleReference
        appModel.environmentProbeCameraScaleReference = cameraScaleReference
        originFromAnchorTransform = originTransform
        latestEnvironmentTextureOriginTransform = originTransform
        appModel.environmentProbeAnchorPosition = probePosition(from: originTransform)
        appModel.environmentProbeAnchorRotationEulerDegrees = eulerDegrees(from: simd_quatf(originTransform))
        if !appModel.hasEnvironmentProbeAnchorStartPose {
            appModel.environmentProbeAnchorStartPosition = appModel.environmentProbeAnchorPosition
            appModel.environmentProbeAnchorStartRotationEulerDegrees = appModel.environmentProbeAnchorRotationEulerDegrees
            appModel.hasEnvironmentProbeAnchorStartPose = true
        }
        appModel.hasEnvironmentProbeAnchorPose = true
        if shouldPublishProbeTransform {
            appModel.environmentProbeOriginTransform = environmentProbeAnalysisTransform(
                from: originTransform,
                appModel: appModel
            )
        }
        appModel.hasEnvironmentProbeTexture = true
        
        textureDescription = "\(texture.width)x\(texture.height), mipmaps: \(texture.mipmapLevelCount)"
        textureDescription += ", format: \(texture.pixelFormat.rawValue)"
        appModel.canRefreshEnvironmentProbePreview = true
        appModel.environmentProbeUpdateCount += 1
        appModel.environmentProbeLastUpdateAt = .now
        appModel.environmentProbeDebugSummary = textureDescription
        var averageLuminanceDescription = ""
        var luminanceInitializationFailed = false
        var luminanceComputationFailed = false
        
        guard shouldRecomputeLuminance else {
            appModel.environmentProbeAverageLuminance = nil
            appModel.environmentProbeLuminanceStatus = "Warte auf vollstaendige Probe-Aktualisierung."
            appModel.brightRegionMaskStatus = "Warte auf vollstaendige Probe-Aktualisierung."
            
            guard shouldExportPreview else { return }
            
            let savedImages = savePreviewImages(from: texture)
            appModel.environmentProbePreviewURLs = savedImages.crossURLs
            appModel.environmentProbeFaceURLs = savedImages.faceURLs
            appModel.environmentProbePreviewVersion += 1
            appModel.environmentProbeDebugSummary = "\(textureDescription) | frische Probe exportiert"
            return
        }
        
        appModel.environmentProbeAverageLuminance = nil
        appModel.environmentProbeLuminanceStatus = "Luminanzberechnung laeuft..."
        
        if luminanceAnalyzer == nil {
            luminanceAnalyzer = EnvironmentProbeLuminanceAnalyzer(device: texture.device)
            if luminanceAnalyzer == nil {
                luminanceInitializationFailed = true
                appModel.environmentProbeAverageLuminance = nil
                appModel.environmentProbeLuminanceStatus = "Fehlgeschlagen: Metal-Luminance-Analyzer konnte nicht initialisiert werden."
                appModel.environmentProbeDebugSummary = "\(textureDescription) | Luminance-Analyzer konnte nicht initialisiert werden"
            }
        }

        if
            !suppressesAnalysisDebugExports,
            let luminanceAnalyzer,
            !didRunMetalSRGBReadConversionDiagnostic
        {
            didRunMetalSRGBReadConversionDiagnostic = true
            if let diagnostic = await luminanceAnalyzer.verifySRGBReadConversion() {
                metalSRGBReadConversionDiagnosticSummary = diagnostic.summary
                print("Environment Probe \(diagnostic.summary)")
            } else {
                metalSRGBReadConversionDiagnosticSummary = "Metal sRGB-Read: Diagnostic fehlgeschlagen"
                print("Environment Probe Metal sRGB-Read: Diagnostic fehlgeschlagen")
            }
        }

        if !suppressesAnalysisDebugExports {
            if let rangeDiagnostic = environmentTextureRangeDiagnostic(for: texture) {
                environmentTextureRangeDiagnosticSummary = rangeDiagnostic
                print("Environment Probe \(rangeDiagnostic)")
            } else {
                environmentTextureRangeDiagnosticSummary = "Texture range: Diagnostic fehlgeschlagen"
                print("Environment Probe Texture range: Diagnostic fehlgeschlagen")
            }
        }
        
        let luminanceSignpostID = OSSignpostID(log: performanceLog)
        os_signpost(.begin, log: performanceLog, name: "LuminanceCompute", signpostID: luminanceSignpostID)
        let computedAverageLuminance = await luminanceAnalyzer?.averageLuminance(
            for: texture,
            progress: { status in
                appModel.environmentProbeLuminanceStatus = status
            }
        )
        os_signpost(.end, log: performanceLog, name: "LuminanceCompute", signpostID: luminanceSignpostID)

        if let averageLuminance = computedAverageLuminance {
            appModel.environmentProbeAverageLuminance = averageLuminance
            appModel.environmentProbeLuminanceStatus = "Berechnet: Metal-Shader erfolgreich ausgefuehrt."
            averageLuminanceDescription = " | avgLum: \(String(format: "%.4f", averageLuminance))"
            appModel.environmentProbeDebugSummary = "\(textureDescription)\(averageLuminanceDescription)\(environmentTextureDiagnosticsDebugSuffix)"
        } else if luminanceAnalyzer != nil {
            luminanceComputationFailed = true
            appModel.environmentProbeAverageLuminance = nil
            appModel.environmentProbeLuminanceStatus = "Fehlgeschlagen: GPU-Luminanzshader konnte keinen Wert berechnen."
            appModel.environmentProbeDebugSummary = "\(textureDescription) | Luminanzberechnung mit Metal fehlgeschlagen\(environmentTextureDiagnosticsDebugSuffix)"
        } else if !luminanceInitializationFailed {
            appModel.environmentProbeAverageLuminance = nil
            appModel.environmentProbeLuminanceStatus = "Fehlgeschlagen: kein Luminance-Analyzer verfuegbar."
        }
        
        guard shouldExportPreview else { return }
        
        let previewSignpostID = OSSignpostID(log: performanceLog)
        os_signpost(.begin, log: performanceLog, name: "ProbePreviewExport", signpostID: previewSignpostID)
        let savedImages = savePreviewImages(from: texture)
        os_signpost(.end, log: performanceLog, name: "ProbePreviewExport", signpostID: previewSignpostID)
        appModel.environmentProbePreviewURLs = savedImages.crossURLs
        appModel.environmentProbeFaceURLs = savedImages.faceURLs
        appModel.environmentProbePreviewVersion += 1
        let previewSuffix = " | frische Probe exportiert"
        if luminanceInitializationFailed {
            appModel.environmentProbeDebugSummary = "\(textureDescription) | Luminance-Analyzer konnte nicht initialisiert werden\(previewSuffix)"
        } else if luminanceComputationFailed {
            appModel.environmentProbeDebugSummary = "\(textureDescription) | Luminanzberechnung fehlgeschlagen\(environmentTextureDiagnosticsDebugSuffix)\(previewSuffix)"
        } else {
            appModel.environmentProbeDebugSummary = "\(textureDescription)\(averageLuminanceDescription)\(environmentTextureDiagnosticsDebugSuffix)\(previewSuffix)"
        }
    }

    private var environmentTextureDiagnosticsDebugSuffix: String {
        var parts: [String] = []
        if let environmentTextureRangeDiagnosticSummary {
            parts.append(environmentTextureRangeDiagnosticSummary)
        }
        if let metalSRGBReadConversionDiagnosticSummary {
            parts.append(metalSRGBReadConversionDiagnosticSummary)
        }

        guard !parts.isEmpty else { return "" }
        return " | \(parts.joined(separator: " | "))"
    }

    private func environmentTextureRangeDiagnostic(for texture: any MTLTexture) -> String? {
        let sliceCount = texture.textureType == .typeCube ? 6 : max(texture.arrayLength, 1)
        guard sliceCount > 0 else {
            return nil
        }

        var maxRGB: Float = 0
        var maxLuminance: Float = 0
        var pixelCount = 0

        for slice in 0..<sliceCount {
            guard
                let faceTexture = texture.makeTextureView(
                    pixelFormat: texture.pixelFormat,
                    textureType: .type2D,
                    levels: 0..<1,
                    slices: slice..<(slice + 1)
                ),
                let pixels = readRGBPixels(from: faceTexture)
            else {
                continue
            }

            for pixel in pixels {
                guard pixel.x.isFinite, pixel.y.isFinite, pixel.z.isFinite else {
                    continue
                }
                maxRGB = max(maxRGB, pixel.x, pixel.y, pixel.z)
                maxLuminance = max(
                    maxLuminance,
                    dot(pixel, SIMD3<Float>(0.2126, 0.7152, 0.0722))
                )
                pixelCount += 1
            }
        }

        guard pixelCount > 0 else {
            return nil
        }

        let isFloatFormat = texture.pixelFormat == .rgba16Float || texture.pixelFormat == .rgba32Float
        let hasExtendedValues = maxRGB > 1.0001 || maxLuminance > 1.0001
        let rangeDescription: String
        if hasExtendedValues {
            rangeDescription = "HDR/extended"
        } else if isFloatFormat {
            rangeDescription = "Float, aktuell <= 1"
        } else {
            rangeDescription = "LDR 0...1"
        }

        return "Texture range: \(rangeDescription) | format \(pixelFormatName(texture.pixelFormat)) | maxRGB \(String(format: "%.4f", maxRGB)) | maxLum \(String(format: "%.4f", maxLuminance))"
    }

    private func pixelFormatName(_ pixelFormat: MTLPixelFormat) -> String {
        switch pixelFormat {
        case .rgba16Float:
            return "rgba16Float"
        case .rgba32Float:
            return "rgba32Float"
        case .rgba8Unorm:
            return "rgba8Unorm"
        case .rgba8Unorm_srgb:
            return "rgba8Unorm_srgb"
        case .bgra8Unorm:
            return "bgra8Unorm"
        case .bgra8Unorm_srgb:
            return "bgra8Unorm_srgb"
        default:
            return "raw \(pixelFormat.rawValue)"
        }
    }
    
    private func preferredProbePreviewURL(from urls: [URL]) -> URL? {
        urls.first {
            $0.lastPathComponent.contains("probe-cross-raw")
                && !$0.lastPathComponent.contains("-nearest")
        } ?? urls.first { !$0.lastPathComponent.contains("-nearest") } ?? urls.first
    }

    private func preferredNearestProbePreviewURL(from urls: [URL]) -> URL? {
        urls.first(where: { $0.lastPathComponent.contains("probe-cross-raw-nearest") })
            ?? urls.first(where: { $0.lastPathComponent.contains("-nearest") })
    }
    
    private func createProbeExportPackage(
        probePreviewURL: URL,
        nearestProbePreviewURL: URL?,
        maskPreviewURL: URL,
        averageLuminance: Float
    ) throws -> (folderURL: URL, fileURLs: [URL]) {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        
        let exportRootURL = documentsURL.appending(path: "EnvironmentProbeExports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: exportRootURL, withIntermediateDirectories: true)
        
        let exportFolderURL = exportRootURL.appending(
            path: "probe-export-\(Self.exportTimestampFormatter.string(from: .now))",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: exportFolderURL, withIntermediateDirectories: true)
        
        let probeDestinationURL = exportFolderURL.appending(path: "environment-cubemap.png")
        let nearestProbeDestinationURL = exportFolderURL.appending(path: "environment-cubemap-nearest.png")
        let maskDestinationURL = exportFolderURL.appending(path: "bright-mask-cubemap.png")
        let luminanceDestinationURL = exportFolderURL.appending(path: "average-luminance.txt")
        
        if FileManager.default.fileExists(atPath: probeDestinationURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: probeDestinationURL)
        }
        if FileManager.default.fileExists(atPath: nearestProbeDestinationURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: nearestProbeDestinationURL)
        }
        if FileManager.default.fileExists(atPath: maskDestinationURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: maskDestinationURL)
        }
        
        try FileManager.default.copyItem(at: probePreviewURL, to: probeDestinationURL)
        var fileURLs = [probeDestinationURL]
        if let nearestProbePreviewURL {
            try FileManager.default.copyItem(at: nearestProbePreviewURL, to: nearestProbeDestinationURL)
            fileURLs.append(nearestProbeDestinationURL)
        }
        try FileManager.default.copyItem(at: maskPreviewURL, to: maskDestinationURL)
        fileURLs.append(maskDestinationURL)
        
        let luminanceText = """
        average_luminance=\(String(format: "%.6f", averageLuminance))
        """
        try luminanceText.write(to: luminanceDestinationURL, atomically: true, encoding: .utf8)
        fileURLs.append(luminanceDestinationURL)
        
        return (
            folderURL: exportFolderURL,
            fileURLs: fileURLs
        )
    }

    private func captureTemporalStabilitySettings(appModel: AppModel) -> TemporalStabilitySettingsSnapshot {
        TemporalStabilitySettingsSnapshot(
            selectionHysteresis: appModel.isBrightRegionSelectionHysteresisEnabled,
            positionAverage: appModel.isStableLightPositionAverageEnabled,
            directionAverage: appModel.isStableLightDirectionAverageEnabled,
            colorAverage: appModel.isStableLightColorAverageEnabled,
            intensityAverage: appModel.isStableLightIntensityAverageEnabled,
            softnessAverage: appModel.isStableLightShadowSoftnessAverageEnabled,
            positionThreshold: appModel.isStableLightPositionMinimumChangeEnabled,
            appearanceThreshold: appModel.isStableLightAppearanceMinimumChangeEnabled,
            freeze: appModel.freezesEstimatedLightAfterWarmup,
            debugSpheres: appModel.areLightProbeDebugSpheresVisible,
            stableColors: appModel.usesStableIDDebugColors,
            rejectedSpheres: appModel.areRejectedLightPositionDebugSpheresVisible,
            lightType: appModel.brightRegionEstimatedLightType,
            lightCount: appModel.brightRegionEstimatedDirectionalLightCount,
            shadows: appModel.areEstimatedDirectionalLightShadowsEnabled,
            dominantShadowOnly: appModel.castsOnlyDominantEstimatedDirectionalLightShadow,
            wasSequentialRunning: appModel.isSequentialLightUpdateRunning
        )
    }

    private func configureTemporalStabilityTest(
        _ mode: TemporalStabilityTestMode,
        appModel: AppModel
    ) {
        let enabled = mode == .stabilized
        appModel.isBrightRegionSelectionHysteresisEnabled = enabled
        appModel.isStableLightPositionAverageEnabled = enabled
        appModel.isStableLightDirectionAverageEnabled = enabled
        appModel.isStableLightColorAverageEnabled = enabled
        appModel.isStableLightIntensityAverageEnabled = enabled
        appModel.isStableLightShadowSoftnessAverageEnabled = enabled
        appModel.isStableLightPositionMinimumChangeEnabled = enabled
        appModel.isStableLightAppearanceMinimumChangeEnabled = enabled
        appModel.freezesEstimatedLightAfterWarmup = false
        appModel.areLightProbeDebugSpheresVisible = true
        appModel.usesStableIDDebugColors = true
        appModel.areRejectedLightPositionDebugSpheresVisible = false
        appModel.brightRegionEstimatedLightType = .directional
        appModel.brightRegionEstimatedDirectionalLightCount = 3
        appModel.areEstimatedDirectionalLightShadowsEnabled = true
        appModel.castsOnlyDominantEstimatedDirectionalLightShadow = true
        stableLightAppearanceHistoriesByStableID.removeAll()
        stableBrightRegionTracks.removeAll()
        activeBrightRegionStableIDs.removeAll()
        pendingBrightRegionSlotSwitches.removeAll()
        nextStableBrightRegionID = 1
        appModel.resetEstimatedLightWarmupFreeze()
        appModel.lightStabilityResetRequestID += 1
    }

    private func restoreTemporalStabilitySettings(appModel: AppModel) {
        guard let snapshot = temporalStabilitySettingsSnapshot else { return }
        temporalStabilitySettingsSnapshot = nil
        appModel.isBrightRegionSelectionHysteresisEnabled = snapshot.selectionHysteresis
        appModel.isStableLightPositionAverageEnabled = snapshot.positionAverage
        appModel.isStableLightDirectionAverageEnabled = snapshot.directionAverage
        appModel.isStableLightColorAverageEnabled = snapshot.colorAverage
        appModel.isStableLightIntensityAverageEnabled = snapshot.intensityAverage
        appModel.isStableLightShadowSoftnessAverageEnabled = snapshot.softnessAverage
        appModel.isStableLightPositionMinimumChangeEnabled = snapshot.positionThreshold
        appModel.isStableLightAppearanceMinimumChangeEnabled = snapshot.appearanceThreshold
        appModel.freezesEstimatedLightAfterWarmup = snapshot.freeze
        appModel.areLightProbeDebugSpheresVisible = snapshot.debugSpheres
        appModel.usesStableIDDebugColors = snapshot.stableColors
        appModel.areRejectedLightPositionDebugSpheresVisible = snapshot.rejectedSpheres
        appModel.brightRegionEstimatedLightType = snapshot.lightType
        appModel.brightRegionEstimatedDirectionalLightCount = snapshot.lightCount
        appModel.areEstimatedDirectionalLightShadowsEnabled = snapshot.shadows
        appModel.castsOnlyDominantEstimatedDirectionalLightShadow = snapshot.dominantShadowOnly
        appModel.resetEstimatedLightWarmupFreeze()
        appModel.lightStabilityResetRequestID += 1
        if snapshot.wasSequentialRunning {
            startSequentialLightUpdates(appModel: appModel, interval: .seconds(1))
        }
    }

    private func temporalLightParametersCSV(_ samples: [TemporalStabilitySample]) -> String {
        let valueColumns = "direction_x,direction_y,direction_z,position_x,position_y,position_z,color_r,color_g,color_b,intensity,source_size_pixels,shadow_softness"
        let rawColumns = valueColumns.split(separator: ",").map { "raw_\($0)" }.joined(separator: ",")
        let candidateColumns = valueColumns.split(separator: ",").map { "candidate_\($0)" }.joined(separator: ",")
        var rows = ["step,index,elapsed_seconds,timestamp,capture_id,light_slot,stable_id,region_index,placement_resolved,position_suppressed,\(valueColumns),\(rawColumns),\(candidateColumns)"]
        rows.append(contentsOf: samples.map { sample in
            let light = sample.light
            let fields = [
                sample.step, String(sample.index), String(format: "%.3f", sample.elapsedSeconds),
                Self.isoTimestampFormatter.string(from: sample.timestamp), String(sample.captureID),
                String(sample.lightSlot), String(light.sourceRegionStableID), String(light.sourceRegionIndex),
                light.isPlacementResolved ? "true" : "false",
                sample.positionEvaluation.map { Self.boolCSV($0.wasSuppressed) } ?? ""
            ] + Self.lightCSVFields(light) + Self.lightCSVFields(sample.rawLight)
                + Self.lightCSVFields(sample.filteredCandidateLight)
            return fields.map(Self.csvField).joined(separator: ",")
        })
        return rows.joined(separator: "\n") + "\n"
    }

    private static func lightCSVFields(_ light: BrightRegionEstimatedLightState?) -> [String] {
        guard let light else { return Array(repeating: "", count: 12) }
        return [
            floatCSV(light.direction.x), floatCSV(light.direction.y), floatCSV(light.direction.z),
            floatCSV(light.position.x), floatCSV(light.position.y), floatCSV(light.position.z),
            floatCSV(light.color.x), floatCSV(light.color.y), floatCSV(light.color.z),
            floatCSV(light.intensity), floatCSV(light.sourceSizePixels), floatCSV(light.shadowSoftness)
        ]
    }

    private static func light(
        _ light: BrightRegionEstimatedLightState,
        replacingPositionWith position: SIMD3<Float>
    ) -> BrightRegionEstimatedLightState {
        BrightRegionEstimatedLightState(
            id: light.id,
            sourceRegionIndex: light.sourceRegionIndex,
            sourceRegionStableID: light.sourceRegionStableID,
            direction: light.direction,
            position: position,
            isPlacementResolved: light.isPlacementResolved,
            color: light.color,
            intensity: light.intensity,
            heightMultiplier: light.heightMultiplier,
            sourceSizePixels: light.sourceSizePixels,
            shadowSoftness: light.shadowSoftness
        )
    }

    private func temporalChangeEvents(from samples: [TemporalStabilitySample]) -> [TemporalChangeEvent] {
        let dominant = samples.filter { $0.lightSlot == 0 }.sorted { $0.index < $1.index }
        return zip(dominant, dominant.dropFirst()).map { previous, current in
            let sameStableID = previous.light.sourceRegionStableID == current.light.sourceRegionStableID
            let rawChange = changeFlags(from: previous.rawLight, to: current.rawLight)
            let outputChange = changeFlags(from: previous.light, to: current.light)
            let gateOpportunity = sameStableID
                ? changeFlags(from: previous.light, to: current.filteredCandidateLight)
                : Self.noTemporalChanges
            let suppressedChange = TemporalChangeFlags(
                direction: gateOpportunity.direction && !outputChange.direction,
                position: gateOpportunity.position && (current.positionEvaluation?.wasSuppressed ?? !outputChange.position),
                color: gateOpportunity.color && !outputChange.color,
                intensity: gateOpportunity.intensity && !outputChange.intensity,
                shadowSoftness: gateOpportunity.shadowSoftness && !outputChange.shadowSoftness
            )
            return TemporalChangeEvent(
                previous: previous,
                current: current,
                sameStableID: sameStableID,
                rawChange: rawChange,
                outputChange: outputChange,
                gateOpportunity: gateOpportunity,
                suppressedChange: suppressedChange
            )
        }
    }

    private func temporalChangeEventsCSV(_ samples: [TemporalStabilitySample]) -> String {
        let events = temporalChangeEvents(from: samples)
        var rows = [
            "from_step,to_step,to_index,to_elapsed_seconds,to_capture_id,stable_id,same_stable_id,raw_direction_changed,raw_position_changed,raw_color_changed,raw_intensity_changed,raw_softness_changed,output_direction_changed,output_position_changed,output_color_changed,output_intensity_changed,output_softness_changed,any_output_changed,raw_position_delta_m,candidate_position_delta_m,output_position_delta_m,position_gate_opportunity,position_suppressed,direction_gate_opportunity,direction_suppressed,color_gate_opportunity,color_suppressed,intensity_gate_opportunity,intensity_suppressed,softness_gate_opportunity,softness_suppressed,any_appearance_change_suppressed"
        ]
        rows.append(contentsOf: events.map { event in
            let raw = event.rawChange
            let output = event.outputChange
            let gate = event.gateOpportunity
            let suppressed = event.suppressedChange
            return [
                event.previous.step, event.current.step, String(event.current.index),
                String(format: "%.3f", event.current.elapsedSeconds), String(event.current.captureID),
                String(event.current.light.sourceRegionStableID), Self.boolCSV(event.sameStableID),
                Self.boolCSV(raw.direction), Self.boolCSV(raw.position), Self.boolCSV(raw.color),
                Self.boolCSV(raw.intensity), Self.boolCSV(raw.shadowSoftness),
                Self.boolCSV(output.direction), Self.boolCSV(output.position), Self.boolCSV(output.color),
                Self.boolCSV(output.intensity), Self.boolCSV(output.shadowSoftness), Self.boolCSV(output.any),
                Self.optionalDistanceCSV(from: event.previous.light, to: event.current.rawLight, when: event.sameStableID),
                Self.optionalDistanceCSV(from: event.previous.light, to: event.current.filteredCandidateLight, when: event.sameStableID),
                event.sameStableID
                    ? Self.floatCSV(simd_distance(event.previous.light.position, event.current.light.position))
                    : "",
                Self.boolCSV(gate.position), Self.boolCSV(suppressed.position),
                Self.boolCSV(gate.direction), Self.boolCSV(suppressed.direction),
                Self.boolCSV(gate.color), Self.boolCSV(suppressed.color),
                Self.boolCSV(gate.intensity), Self.boolCSV(suppressed.intensity),
                Self.boolCSV(gate.shadowSoftness), Self.boolCSV(suppressed.shadowSoftness),
                Self.boolCSV(suppressed.anyAppearance)
            ].map(Self.csvField).joined(separator: ",")
        })
        return rows.joined(separator: "\n") + "\n"
    }

    private func changeFlags(
        from previous: BrightRegionEstimatedLightState?,
        to current: BrightRegionEstimatedLightState?,
        includesPosition: Bool = true
    ) -> TemporalChangeFlags {
        guard let previous, let current else { return Self.noTemporalChanges }
        return TemporalChangeFlags(
            direction: Self.directionAngleDegrees(previous.direction, current.direction) > 0.01,
            position: includesPosition && simd_distance(previous.position, current.position) > 0.001,
            color: simd_distance(previous.color, current.color) > 0.001,
            intensity: Self.relativeChange(previous.intensity, current.intensity) > 0.001,
            shadowSoftness: abs(previous.shadowSoftness - current.shadowSoftness) > 0.001
        )
    }

    private static let noTemporalChanges = TemporalChangeFlags(
        direction: false,
        position: false,
        color: false,
        intensity: false,
        shadowSoftness: false
    )

    private static func optionalDistanceCSV(
        from previous: BrightRegionEstimatedLightState,
        to current: BrightRegionEstimatedLightState?,
        when condition: Bool
    ) -> String {
        guard condition, let current else { return "" }
        return floatCSV(simd_distance(previous.position, current.position))
    }

    private func temporalStabilitySummaryCSV(
        samples: [TemporalStabilitySample],
        mode: TemporalStabilityTestMode,
        startedAt: Date,
        finishedAt: Date,
        positionMinimumChange: Float
    ) -> String {
        let dominant = samples.filter { $0.lightSlot == 0 }.sorted { $0.index < $1.index }
        let changeEvents = temporalChangeEvents(from: samples)
        let comparableEvents = changeEvents.filter(\.sameStableID)
        let rawPositionDeltasCM = comparableEvents.compactMap { event in
            event.current.rawLight.map { simd_distance(event.previous.light.position, $0.position) * 100 }
        }
        let candidatePositionDeltasCM = comparableEvents.compactMap { event in
            event.current.filteredCandidateLight.map { simd_distance(event.previous.light.position, $0.position) * 100 }
        }
        let outputPositionDeltasCM = comparableEvents.map {
            simd_distance($0.previous.light.position, $0.current.light.position) * 100
        }
        var directionChanges: [Float] = []
        var positionChangesCM: [Float] = []
        var intensityChangesPercent: [Float] = []
        var stableIDSwitches = 0
        for pair in zip(dominant, dominant.dropFirst()) {
            directionChanges.append(Self.directionAngleDegrees(pair.0.light.direction, pair.1.light.direction))
            positionChangesCM.append(simd_distance(pair.0.light.position, pair.1.light.position) * 100)
            let denominator = max(abs(pair.0.light.intensity), 0.0001)
            intensityChangesPercent.append(abs(pair.1.light.intensity - pair.0.light.intensity) / denominator * 100)
            if pair.0.light.sourceRegionStableID != pair.1.light.sourceRegionStableID { stableIDSwitches += 1 }
        }
        let afterSettling = dominant.filter { $0.elapsedSeconds >= 10 }
        let afterSettlingChangedSteps = zip(afterSettling, afterSettling.dropFirst()).filter { pair in
            simd_distance(pair.0.light.position, pair.1.light.position) > 0.001
                || simd_distance(pair.0.light.direction, pair.1.light.direction) > 0.001
                || abs(pair.0.light.intensity - pair.1.light.intensity) > 0.001
        }.count
        var rows: [(String, String)] = [
            ("test", "Test 2 - Zeitliche Stabilitaet"), ("mode", mode.rawValue),
            ("started_at", Self.isoTimestampFormatter.string(from: startedAt)),
            ("duration_seconds", String(format: "%.3f", finishedAt.timeIntervalSince(startedAt))),
            ("position_minimum_change_m", Self.floatCSV(positionMinimumChange)),
            ("dominant_sample_count", String(dominant.count)),
            ("stable_id_switch_count", String(stableIDSwitches)),
            ("direction_step_mean_degrees", Self.floatCSV(Self.mean(directionChanges))),
            ("direction_step_max_degrees", Self.floatCSV(directionChanges.max() ?? 0)),
            ("position_step_mean_cm", Self.floatCSV(Self.mean(positionChangesCM))),
            ("position_step_max_cm", Self.floatCSV(positionChangesCM.max() ?? 0)),
            ("position_raw_delta_mean_cm", Self.floatCSV(Self.mean(rawPositionDeltasCM))),
            ("position_raw_delta_max_cm", Self.floatCSV(rawPositionDeltasCM.max() ?? 0)),
            ("position_candidate_delta_mean_cm", Self.floatCSV(Self.mean(candidatePositionDeltasCM))),
            ("position_candidate_delta_max_cm", Self.floatCSV(candidatePositionDeltasCM.max() ?? 0)),
            ("position_output_delta_mean_cm", Self.floatCSV(Self.mean(outputPositionDeltasCM))),
            ("position_output_delta_max_cm", Self.floatCSV(outputPositionDeltasCM.max() ?? 0)),
            ("intensity_step_mean_percent", Self.floatCSV(Self.mean(intensityChangesPercent))),
            ("intensity_step_max_percent", Self.floatCSV(intensityChangesPercent.max() ?? 0)),
            ("after_10s_sample_count", String(afterSettling.count)),
            ("after_10s_changed_step_count", String(afterSettlingChangedSteps))
        ]
        let outputChangedCount = comparableEvents.filter { $0.outputChange.any }.count
        rows.append(contentsOf: [
            ("probe_transition_count", String(changeEvents.count)),
            ("same_stable_id_transition_count", String(comparableEvents.count)),
            ("stable_id_transition_count", String(changeEvents.count - comparableEvents.count)),
            ("any_output_change_count", String(outputChangedCount)),
            ("unchanged_output_count", String(comparableEvents.count - outputChangedCount)),
            ("any_output_change_rate_percent", Self.percentCSV(outputChangedCount, outOf: comparableEvents.count)),
            ("position_suppression_available", "true")
        ])
        rows.append(contentsOf: temporalParameterSummaryRows(
            name: "direction",
            events: comparableEvents,
            flag: { $0.direction }
        ))
        rows.append(contentsOf: temporalParameterSummaryRows(
            name: "position",
            events: comparableEvents,
            flag: { $0.position }
        ))
        rows.append(contentsOf: temporalParameterSummaryRows(
            name: "color",
            events: comparableEvents,
            flag: { $0.color }
        ))
        rows.append(contentsOf: temporalParameterSummaryRows(
            name: "intensity",
            events: comparableEvents,
            flag: { $0.intensity }
        ))
        rows.append(contentsOf: temporalParameterSummaryRows(
            name: "softness",
            events: comparableEvents,
            flag: { $0.shadowSoftness }
        ))
        return "metric,value\n" + rows.map { Self.csvField($0.0) + "," + Self.csvField($0.1) }.joined(separator: "\n") + "\n"
    }

    private func temporalParameterSummaryRows(
        name: String,
        events: [TemporalChangeEvent],
        flag: (TemporalChangeFlags) -> Bool,
        includesSuppression: Bool = true
    ) -> [(String, String)] {
        let rawChangeCount = events.filter { flag($0.rawChange) }.count
        let outputChangeCount = events.filter { flag($0.outputChange) }.count
        var rows: [(String, String)] = [
            ("\(name)_raw_change_count", String(rawChangeCount)),
            ("\(name)_output_change_count", String(outputChangeCount)),
            ("\(name)_output_unchanged_count", String(events.count - outputChangeCount)),
            ("\(name)_output_change_rate_percent", Self.percentCSV(outputChangeCount, outOf: events.count))
        ]
        if includesSuppression {
            let opportunities = events.filter { flag($0.gateOpportunity) }.count
            let suppressed = events.filter { flag($0.suppressedChange) }.count
            rows.append(contentsOf: [
                ("\(name)_gate_opportunity_count", String(opportunities)),
                ("\(name)_suppressed_change_count", String(suppressed)),
                ("\(name)_suppression_rate_percent", Self.percentCSV(suppressed, outOf: opportunities))
            ])
        }
        return rows
    }

    private static func floatCSV(_ value: Float) -> String { String(format: "%.6f", value) }
    private static func boolCSV(_ value: Bool) -> String { value ? "true" : "false" }
    private static func percentCSV(_ count: Int, outOf total: Int) -> String {
        guard total > 0 else { return "" }
        return String(format: "%.3f", Float(count) / Float(total) * 100)
    }
    private static func relativeChange(_ previous: Float, _ current: Float) -> Float {
        abs(current - previous) / max(abs(previous), 0.0001)
    }
    private static func directionAngleDegrees(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Float {
        guard simd_length_squared(lhs) > 0.000001, simd_length_squared(rhs) > 0.000001 else {
            return simd_distance(lhs, rhs) > 0.000001 ? 180 : 0
        }
        let dot = min(max(simd_dot(simd_normalize(lhs), simd_normalize(rhs)), -1), 1)
        return acos(dot) * 180 / .pi
    }
    private static func mean(_ values: [Float]) -> Float {
        values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count)
    }

    private func makeProbeSequenceExportFolder(mode: TemporalStabilityTestMode) throws -> (
        folderURL: URL,
        infoURL: URL,
        timelineURL: URL,
        lightParametersURL: URL,
        changeEventsURL: URL,
        summaryURL: URL
    ) {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        let exportRootURL = documentsURL.appending(path: "TechnicalEvaluations", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: exportRootURL, withIntermediateDirectories: true)

        let folderURL = exportRootURL.appending(
            path: "test-2-temporal-\(mode.filenameComponent)-\(Self.exportTimestampFormatter.string(from: .now))",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        return (
            folderURL: folderURL,
            infoURL: folderURL.appending(path: "sequence-info.txt"),
            timelineURL: folderURL.appending(path: "sequence-info.csv"),
            lightParametersURL: folderURL.appending(path: "light-parameters.csv"),
            changeEventsURL: folderURL.appending(path: "change-events.csv"),
            summaryURL: folderURL.appending(path: "summary.csv")
        )
    }

    private func sequenceInfoText(
        startedAt: Date,
        durationSeconds: Int,
        intervalSeconds: Int,
        maxStepCount: Int,
        mode: TemporalStabilityTestMode
    ) -> String {
        """
        sequence_started_at=\(Self.isoTimestampFormatter.string(from: startedAt))
        test=Test 2 - Zeitliche Stabilitaet
        mode=\(mode.rawValue)
        mode_title=\(mode.title)
        duration_seconds=\(durationSeconds)
        interval_seconds=\(intervalSeconds)
        max_step_count=\(maxStepCount)
        files_per_step=environment-cubemap.png,environment-cubemap-nearest.png,bright-mask-cubemap.png,average-luminance.txt,metadata.txt
        root_files=sequence-info.csv,light-parameters.csv,change-events.csv,summary.csv
        stabilization_raw=all temporal filters off; no freeze
        stabilization_stabilized=hysteresis, moving averages and minimum-change thresholds on; no output freeze
        change_detection_thresholds=direction 0.01 degrees; position 0.1 cm; color distance 0.001; intensity relative 0.1 percent; softness 0.001
        suppression_definition=filtered candidate differs from previous output, but current output remains unchanged
        position_suppression=available; export waits for matching geometry placement and records raw, moving-average candidate and gated output positions
        """
    }

    private func waitForFreshEnvironmentProbeCapture(
        after previousCaptureID: Int?,
        timeoutSeconds: Int
    ) async -> Int? {
        let minimumCaptureID = previousCaptureID ?? 0
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))

        while !Task.isCancelled {
            let currentCaptureID = latestEnvironmentTextureCaptureID
            if currentCaptureID > minimumCaptureID, latestEnvironmentTexture != nil {
                return currentCaptureID
            }

            if Date() >= deadline {
                return nil
            }

            try? await Task.sleep(for: .milliseconds(100))
        }

        return nil
    }

    private func waitForLightPlacement(
        requestID: Int,
        appModel: AppModel,
        timeoutSeconds: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while !Task.isCancelled {
            if appModel.brightRegionCompletedLightPlacementRequestID >= requestID {
                return true
            }
            if Date() >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        return false
    }

    private func exportCurrentProbeSequenceStep(
        to stepFolderURL: URL,
        index: Int,
        stepName: String,
        timestamp: Date,
        elapsedSeconds: TimeInterval,
        captureID: Int?,
        mode: TemporalStabilityTestMode,
        appModel: AppModel
    ) throws -> (fileURLs: [URL], timelineRow: String) {
        var fileURLs: [URL] = []
        var statusParts: [String] = []

        let probeDestinationURL = stepFolderURL.appending(path: "environment-cubemap.png")
        let nearestProbeDestinationURL = stepFolderURL.appending(path: "environment-cubemap-nearest.png")
        let maskDestinationURL = stepFolderURL.appending(path: "bright-mask-cubemap.png")
        let luminanceDestinationURL = stepFolderURL.appending(path: "average-luminance.txt")
        let metadataDestinationURL = stepFolderURL.appending(path: "metadata.txt")

        if let probePreviewURL = preferredProbePreviewURL(from: appModel.environmentProbePreviewURLs) {
            try copyFileReplacingExisting(from: probePreviewURL, to: probeDestinationURL)
            fileURLs.append(probeDestinationURL)
        } else {
            statusParts.append("missing_environment")
        }

        if let nearestProbePreviewURL = preferredNearestProbePreviewURL(from: appModel.environmentProbePreviewURLs) {
            try copyFileReplacingExisting(from: nearestProbePreviewURL, to: nearestProbeDestinationURL)
            fileURLs.append(nearestProbeDestinationURL)
        } else {
            statusParts.append("missing_nearest")
        }

        if let maskPreviewURL = appModel.brightRegionMaskPreviewURLs.first {
            try copyFileReplacingExisting(from: maskPreviewURL, to: maskDestinationURL)
            fileURLs.append(maskDestinationURL)
        } else {
            statusParts.append("missing_mask")
        }

        if let averageLuminance = appModel.environmentProbeAverageLuminance {
            let luminanceText = """
            average_luminance=\(String(format: "%.6f", averageLuminance))
            """
            try luminanceText.write(to: luminanceDestinationURL, atomically: true, encoding: .utf8)
            fileURLs.append(luminanceDestinationURL)
        } else {
            statusParts.append("missing_luminance")
        }

        let status = statusParts.isEmpty ? "ok" : statusParts.joined(separator: "+")
        let captureIDText = captureID.map(String.init) ?? ""
        let averageLuminanceText = appModel.environmentProbeAverageLuminance.map {
            String(format: "%.6f", $0)
        } ?? ""
        let metadataText = """
        step=\(stepName)
        index=\(index)
        elapsed_seconds=\(String(format: "%.3f", elapsedSeconds))
        timestamp=\(Self.isoTimestampFormatter.string(from: timestamp))
        capture_id=\(captureIDText)
        status=\(status)
        average_luminance=\(averageLuminanceText)
        mode=\(mode.rawValue)
        output_frozen=\(appModel.shouldFreezeEstimatedLightOutput)
        estimated_light_count=\(appModel.brightRegionEstimatedLights.count)
        environment_file=environment-cubemap.png
        nearest_file=environment-cubemap-nearest.png
        mask_file=bright-mask-cubemap.png
        """
        try metadataText.write(to: metadataDestinationURL, atomically: true, encoding: .utf8)
        fileURLs.append(metadataDestinationURL)

        let timelineRow = [
            stepName,
            String(index),
            String(format: "%.3f", elapsedSeconds),
            Self.isoTimestampFormatter.string(from: timestamp),
            captureIDText,
            status,
            averageLuminanceText,
            String(appModel.brightRegionEstimatedLights.count),
            appModel.brightRegionEstimatedLights.first.map { String($0.sourceRegionStableID) } ?? "",
            "\(stepName)/environment-cubemap.png",
            "\(stepName)/environment-cubemap-nearest.png",
            "\(stepName)/bright-mask-cubemap.png"
        ].map(Self.csvField).joined(separator: ",")

        return (fileURLs: fileURLs, timelineRow: timelineRow)
    }

    private func sequenceTimelineRow(
        stepName: String,
        index: Int,
        elapsedSeconds: TimeInterval,
        timestamp: Date,
        captureID: Int?,
        status: String,
        averageLuminance: Float?,
        lights: [BrightRegionEstimatedLightState],
        hasFiles: Bool
    ) -> String {
        let captureIDText = captureID.map(String.init) ?? ""
        let luminanceText = averageLuminance.map { String(format: "%.6f", $0) } ?? ""
        let dominantStableIDText = lights.first.map { String($0.sourceRegionStableID) } ?? ""
        let environmentFile = hasFiles ? stepName + "/environment-cubemap.png" : ""
        let nearestFile = hasFiles ? stepName + "/environment-cubemap-nearest.png" : ""
        let maskFile = hasFiles ? stepName + "/bright-mask-cubemap.png" : ""
        let fields: [String] = [
            stepName,
            String(index),
            String(format: "%.3f", elapsedSeconds),
            Self.isoTimestampFormatter.string(from: timestamp),
            captureIDText,
            status,
            luminanceText,
            String(lights.count),
            dominantStableIDText,
            environmentFile,
            nearestFile,
            maskFile
        ]
        return fields.map(Self.csvField).joined(separator: ",")
    }

    private func copyFileReplacingExisting(from sourceURL: URL, to destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }

        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    
#if targetEnvironment(simulator)
    private func copyProbeExportPackageToSimulatorDownloads(
        _ package: (folderURL: URL, fileURLs: [URL])
    ) throws -> URL {
        try copyExportFolderToSimulatorDownloads(package.folderURL)
    }

    private func copyExportFolderToSimulatorDownloads(_ folderURL: URL) throws -> URL {
        let rootURL = simulatorExportRootFolderURL()
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let destinationFolderURL = rootURL.appending(path: folderURL.lastPathComponent, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: destinationFolderURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: destinationFolderURL)
        }
        try FileManager.default.copyItem(at: folderURL, to: destinationFolderURL)

        return destinationFolderURL
    }
#endif
    
    private func updateBrightRegionMask(
        from texture: any MTLTexture,
        originTransform: simd_float4x4,
        appModel: AppModel,
        shouldExportPreview: Bool = true
    ) async {
        let signpostID = OSSignpostID(log: performanceLog)
        os_signpost(.begin, log: performanceLog, name: "BrightRegionMaskPipeline", signpostID: signpostID)
        defer {
            os_signpost(.end, log: performanceLog, name: "BrightRegionMaskPipeline", signpostID: signpostID)
        }

        if brightRegionAnalyzer == nil {
            brightRegionAnalyzer = EnvironmentProbeBrightRegionAnalyzer(device: texture.device)
            if brightRegionAnalyzer == nil {
                appModel.brightRegionMaskStatus = "Fehlgeschlagen: Bright-Region-Analyzer konnte nicht initialisiert werden."
                appModel.brightRegionMaskDebugSummary = "Bright-Region-Analyzer konnte nicht initialisiert werden."
            }
        }
        
        let percentileSignpostID = OSSignpostID(log: performanceLog)
        os_signpost(.begin, log: performanceLog, name: "LuminancePercentiles", signpostID: percentileSignpostID)
        let percentileThresholds = luminancePercentiles(
            for: texture,
            percentiles: [0.80, 0.95, 0.99]
        )
        os_signpost(.end, log: performanceLog, name: "LuminancePercentiles", signpostID: percentileSignpostID)

        guard let thresholds = percentileThresholds, thresholds.count == 3 else {
            appModel.brightRegionMaskStatus = "Fehlgeschlagen: Perzentil-Schwellen konnten nicht berechnet werden."
            appModel.brightRegionMaskDebugSummary = "Keine gueltigen Luminanz-Perzentile verfuegbar."
            appModel.canRecomputeBrightRegionLight = false
            return
        }

        let thresholdVector = SIMD3<Float>(thresholds[0], thresholds[1], thresholds[2])
        appModel.brightRegionMaskLastThreshold = thresholds[2]
        appModel.brightRegionMaskLastPercentileThresholds = thresholds

        appModel.brightRegionMaskStatus = "Maskenberechnung laeuft..."

        let maskComputeSignpostID = OSSignpostID(log: performanceLog)
        os_signpost(.begin, log: performanceLog, name: "BrightMaskCompute", signpostID: maskComputeSignpostID)
        let computedRegionTextures = await brightRegionAnalyzer?.makeMaskTexture(
            for: texture,
            thresholds: thresholdVector,
            progress: { status in
                appModel.brightRegionMaskStatus = status
            }
        )
        os_signpost(.end, log: performanceLog, name: "BrightMaskCompute", signpostID: maskComputeSignpostID)

        guard let regionTextures = computedRegionTextures else {
            appModel.brightRegionMaskStatus = "Fehlgeschlagen: GPU-Maskenshader konnte keine Maske erzeugen."
            appModel.brightRegionMaskDebugSummary = "Bright-Region-Maske konnte mit Metal nicht erzeugt werden."
            appModel.canRecomputeBrightRegionLight = false
            return
        }
        let maskTexture = regionTextures.mask
        let luminanceTexture = regionTextures.luminance
        
        if shouldExportPreview {
            let maskPreviewSignpostID = OSSignpostID(log: performanceLog)
            os_signpost(.begin, log: performanceLog, name: "MaskPreviewExport", signpostID: maskPreviewSignpostID)
            let savedImages = saveMaskPreviewImages(from: maskTexture, threshold: thresholds[2])
            os_signpost(.end, log: performanceLog, name: "MaskPreviewExport", signpostID: maskPreviewSignpostID)
            appModel.brightRegionMaskPreviewURLs = savedImages.crossURLs
            appModel.brightRegionMaskFaceURLs = savedImages.faceURLs
            appModel.brightRegionMaskPreviewVersion += 1
        }
        let minimumBrightRegionCount = 3
        let supplementalMinimumAngularSeparationDegrees: Float = 45
        let regionsSignpostID = OSSignpostID(log: performanceLog)
        os_signpost(.begin, log: performanceLog, name: "BrightRegionCPUReadbackAndMerge", signpostID: regionsSignpostID)
        let connectedBrightRegions = regionAnalyzer.connectedRegions(
            from: maskTexture,
            includedLevels: [2, 3]
        )
        var mergedBrightRegions = regionAnalyzer.mergedRegionsAcrossCubeFaces(
            from: connectedBrightRegions,
            faceSize: maskTexture.width
        )
        let primaryMergedRegionCount = mergedBrightRegions.count

        if mergedBrightRegions.count < minimumBrightRegionCount {
            mergedBrightRegions = supplementalBrightRegions(
                primaryRegions: mergedBrightRegions,
                targetCount: minimumBrightRegionCount,
                minimumAngularSeparationDegrees: supplementalMinimumAngularSeparationDegrees,
                maskTexture: maskTexture,
                luminanceTexture: luminanceTexture,
                colorTexture: texture
            )
        }

        let measuredRegions = regionMetricsReader.measuredRegions(
            from: mergedBrightRegions,
            luminanceTexture: luminanceTexture,
            colorTexture: texture
        )
        os_signpost(
            .end,
            log: performanceLog,
            name: "BrightRegionCPUReadbackAndMerge",
            signpostID: regionsSignpostID,
            "connected %d merged %d measured %d",
            connectedBrightRegions.count,
            mergedBrightRegions.count,
            measuredRegions.count
        )
        let environmentAverageLuminance = appModel.environmentProbeAverageLuminance
            ?? averageLuminance(from: luminanceTexture)
        if appModel.environmentProbeAverageLuminance == nil {
            appModel.environmentProbeAverageLuminance = environmentAverageLuminance
        }
        let analysis = BrightRegionAnalysisSnapshot(
            measuredRegions: measuredRegions,
            faceSize: maskTexture.width,
            originTransform: originTransform,
            thresholds: thresholds,
            environmentAverageLuminance: environmentAverageLuminance,
            primaryMergedRegionCount: primaryMergedRegionCount,
            connectedRegionCount: connectedBrightRegions.count,
            mergedRegionCount: mergedBrightRegions.count
        )
        latestBrightRegionAnalysis = analysis
        appModel.canRecomputeBrightRegionLight = true
        updateEstimatedLight(from: analysis, appModel: appModel)
        appModel.brightRegionMaskStatus = "Berechnet: Metal-Shader erfolgreich ausgefuehrt."
    }

    private func averageLuminance(from luminanceTexture: any MTLTexture) -> Float? {
        let sliceCount = luminanceTexture.textureType == .typeCube
            ? 6
            : max(luminanceTexture.arrayLength, 1)
        guard
            sliceCount > 0,
            luminanceTexture.width > 0,
            luminanceTexture.height > 0
        else {
            return nil
        }

        let pixelCountPerSlice = luminanceTexture.width * luminanceTexture.height
        var totalLuminance: Float = 0
        var totalPixelCount = 0

        for slice in 0..<sliceCount {
            guard let faceTexture = luminanceTexture.makeTextureView(
                pixelFormat: luminanceTexture.pixelFormat,
                textureType: .type2D,
                levels: 0..<1,
                slices: slice..<(slice + 1)
            ) else {
                continue
            }

            var pixels = [Float](repeating: 0, count: pixelCountPerSlice)
            pixels.withUnsafeMutableBytes { buffer in
                faceTexture.getBytes(
                    buffer.baseAddress!,
                    bytesPerRow: luminanceTexture.width * MemoryLayout<Float>.stride,
                    from: MTLRegionMake2D(0, 0, luminanceTexture.width, luminanceTexture.height),
                    mipmapLevel: 0
                )
            }

            totalLuminance += pixels.reduce(0, +)
            totalPixelCount += pixelCountPerSlice
        }

        guard totalPixelCount > 0 else {
            return nil
        }

        return totalLuminance / Float(totalPixelCount)
    }

    private func supplementalBrightRegions(
        primaryRegions: [MergedBrightRegion],
        targetCount: Int,
        minimumAngularSeparationDegrees: Float,
        maskTexture: any MTLTexture,
        luminanceTexture: any MTLTexture,
        colorTexture: any MTLTexture
    ) -> [MergedBrightRegion] {
        guard primaryRegions.count < targetCount else {
            return primaryRegions
        }

        var selectedRegions = primaryRegions
        var selectedDirections = selectedRegions.compactMap {
            regionAnalyzer.averageDirection(for: $0, faceSize: maskTexture.width)
        }

        let supplementalConnectedRegions = regionAnalyzer.connectedRegions(
            from: maskTexture,
            includedLevels: [1],
            excludedDirections: selectedDirections,
            minimumAngularSeparationDegrees: minimumAngularSeparationDegrees
        )
        let supplementalMergedRegions = regionAnalyzer.mergedRegionsAcrossCubeFaces(
            from: supplementalConnectedRegions,
            faceSize: maskTexture.width
        )
        let measuredSupplementalRegions = regionMetricsReader.measuredRegions(
            from: supplementalMergedRegions,
            luminanceTexture: luminanceTexture,
            colorTexture: colorTexture
        )
        let sortedSupplementalRegions = measuredSupplementalRegions.sorted {
            $0.luminance.total > $1.luminance.total
        }
        let minimumAngularSeparationCosine = Float(cos(Double(minimumAngularSeparationDegrees) * Double.pi / 180))

        for measuredRegion in sortedSupplementalRegions {
            guard selectedRegions.count < targetCount else {
                break
            }
            guard let direction = regionAnalyzer.averageDirection(
                for: measuredRegion.region,
                faceSize: maskTexture.width
            ) else {
                continue
            }
            guard selectedDirections.allSatisfy({ simd_dot(direction, $0) < minimumAngularSeparationCosine }) else {
                continue
            }

            selectedRegions.append(measuredRegion.region)
            selectedDirections.append(direction)
        }

        return selectedRegions
    }

    private func updateEstimatedLight(
        from analysis: BrightRegionAnalysisSnapshot,
        appModel: AppModel
    ) {
        let signpostID = OSSignpostID(log: performanceLog)
        os_signpost(.begin, log: performanceLog, name: "EstimateLights", signpostID: signpostID)
        defer {
            os_signpost(
                .end,
                log: performanceLog,
                name: "EstimateLights",
                signpostID: signpostID,
                "lights %d regions %d",
                appModel.brightRegionEstimatedLights.count,
                analysis.measuredRegions.count
            )
        }

        let measuredRegions = analysis.measuredRegions
        let originTransform = analysis.originTransform
        let faceSize = analysis.faceSize
        let thresholds = analysis.thresholds
        let dominanceScoreMode = appModel.brightRegionDominanceScoreMode
        let distanceScoreMode = appModel.brightRegionDistanceScoreMode
        let directionMode = appModel.brightRegionDirectionMode
        let colorMode = appModel.brightRegionColorMode
        let isHeightPriorEnabled = appModel.isBrightRegionHeightPriorEnabled
        let shadowSoftnessMode = appModel.brightRegionShadowSoftnessMode
        let isGeometryIgnored = appModel.isBrightRegionGeometryIgnored
        let environmentAverageLuminance = analysis.environmentAverageLuminance
        let maxHeightPriorBonus: Float = 0.3
        let noHitDistanceFallback: Float = 4.0

        func heightPriorMultiplier(for region: MeasuredBrightRegion) -> Float {
            guard isHeightPriorEnabled else {
                return 1
            }

            guard let worldDirection = lightEstimator.estimateWorldDirection(
                for: region,
                probeTransform: originTransform,
                faceSize: faceSize,
                directionMode: directionMode
            ) else {
                return 1
            }

            let upwardness = max(worldDirection.y, 0)
            return 1 + maxHeightPriorBonus * upwardness
        }

        func distanceMultiplier(for region: MeasuredBrightRegion) -> Float {
            let distance = distanceEstimate(for: region)
            guard distance.isFinite else { return 1 }

            let clampedDistance = min(max(distance, 0.35), 6)
            switch distanceScoreMode {
            case .off:
                return 1
            case .squared:
                return clampedDistance * clampedDistance
            case .cubed:
                return clampedDistance * clampedDistance * clampedDistance
            }
        }

        func clampedDistance(for region: MeasuredBrightRegion) -> Float {
            let distance = distanceEstimate(for: region)
            guard distance.isFinite else { return noHitDistanceFallback }

            return min(max(distance, 0.35), 6)
        }

        func distanceEstimate(for region: MeasuredBrightRegion) -> Float {
            guard !isGeometryIgnored else { return noHitDistanceFallback }

            return appModel.brightRegionDistanceEstimates[region.index] ?? noHitDistanceFallback
        }

        func observedLux(for region: MeasuredBrightRegion) -> Float {
            region.luminance.total
                * 500
                * appModel.brightRegionEstimatedDirectionalLightLuxMultiplier
        }

        func spotLux(for region: MeasuredBrightRegion) -> Float {
            let distance = clampedDistance(for: region)
            return observedLux(for: region) * distance * distance * heightPriorMultiplier(for: region)
        }

        func spotIntensityMultiplier(for displayIndex: Int, activeLightCount: Int) -> Float {
            switch appModel.brightRegionSpotLightIntensityDistributionMode {
            case .full:
                return 1
            case .dividedByLightCount:
                return 1 / Float(activeLightCount)
            case .dominantWithReducedSecondary:
                return displayIndex == 0 ? 1 : 0.5
            }
        }

        func finalSpotIntensity(for region: MeasuredBrightRegion, displayIndex: Int, activeLightCount: Int) -> Float {
            min(max(spotLux(for: region), 500), 20_000) * spotIntensityMultiplier(
                for: displayIndex,
                activeLightCount: activeLightCount
            )
        }

        func peakAverageRatio(for region: MeasuredBrightRegion) -> Float? {
            guard
                let environmentAverageLuminance,
                environmentAverageLuminance.isFinite,
                environmentAverageLuminance > 0,
                region.luminance.max.isFinite,
                region.luminance.max > 0
            else {
                return nil
            }

            return region.luminance.max / environmentAverageLuminance
        }

        func peakAverageShadowSoftness(for region: MeasuredBrightRegion) -> Float {
            guard let ratio = peakAverageRatio(for: region) else {
                return 0
            }

            return min(max((12 - ratio) / 11, 0), 1)
        }

        func shadowSoftness(for region: MeasuredBrightRegion) -> Float {
            switch shadowSoftnessMode {
            case .size:
                region.shadowSoftness
            case .peakAverage:
                peakAverageShadowSoftness(for: region)
            case .both:
                region.shadowSoftness * 0.6 + peakAverageShadowSoftness(for: region) * 0.4
            case .orthographicScale:
                region.shadowSoftness * 0.6 + peakAverageShadowSoftness(for: region) * 0.4
            }
        }

        func spotOuterAngleInDegrees(for region: MeasuredBrightRegion) -> Float {
            let maximumOuterAngle = appModel.brightRegionEstimatedSpotLightOuterAngleInDegrees
            if shadowSoftnessMode == .orthographicScale {
                return maximumOuterAngle
            }

            let minimumOuterAngle = min(
                maximumOuterAngle,
                max(1, appModel.brightRegionEstimatedSpotLightInnerAngleInDegrees + 1)
            )

            return minimumOuterAngle + (maximumOuterAngle - minimumOuterAngle) * shadowSoftness(for: region)
        }

        func finalDominanceScore(for region: MeasuredBrightRegion) -> Float {
            region.dominanceScore(for: dominanceScoreMode)
                * distanceMultiplier(for: region)
                * heightPriorMultiplier(for: region)
        }

        let sortedMeasuredRegions = measuredRegions.sorted { lhs, rhs in
            finalDominanceScore(for: lhs) > finalDominanceScore(for: rhs)
        }
        syncStableBrightRegionTrackPositions(from: appModel.brightRegionEstimatedLights)
        let stableTrackedRegions = Array(sortedMeasuredRegions.prefix(brightRegionHysteresisCandidateLimit))
        let stableRegionIDsByRegionIndex = stableBrightRegionIDs(
            for: stableTrackedRegions,
            originTransform: originTransform,
            faceSize: faceSize,
            directionMode: directionMode,
            sourcePosition: lightSourcePosition(
                appModel: appModel,
                probeTransform: originTransform
            ),
            distance: { region in
                isGeometryIgnored ? noHitDistanceFallback : clampedDistance(for: region)
            },
            score: finalDominanceScore
        )
        let selectedMeasuredRegions = hysteresisSelectedBrightRegions(
            from: stableTrackedRegions,
            stableIDsByRegionIndex: stableRegionIDsByRegionIndex,
            score: finalDominanceScore,
            isEnabled: appModel.isBrightRegionSelectionHysteresisEnabled
        )
        let estimatedLights = selectedMeasuredRegions.compactMap { region in
            lightEstimator.estimateLight(
                from: region,
                probeTransform: originTransform,
                faceSize: faceSize,
                sourcePosition: lightSourcePosition(
                    appModel: appModel,
                    probeTransform: originTransform
                ),
                distance: isGeometryIgnored ? noHitDistanceFallback : 2.0,
                directionMode: directionMode,
                colorMode: colorMode,
                whiteMix: appModel.brightRegionEstimatedLightWhiteMix
            )
        }
        let activeDebugSpotLightCount = max(1, min(
            appModel.brightRegionEstimatedSpotLightCount,
            estimatedLights.count
        ))
        let dominantRegion = sortedMeasuredRegions.first
        let estimatedLight = estimatedLights.first
        if let estimatedLight {
            let usesGeometryPlacement = appModel.brightRegionLightSourceOriginMode == .geometryHitOrSceneProbe
                && !isGeometryIgnored
            var previousLightsByStableID: [Int: BrightRegionEstimatedLightState] = [:]
            for light in appModel.brightRegionEstimatedLights where light.sourceRegionStableID > 0 && light.isPlacementResolved {
                if previousLightsByStableID[light.sourceRegionStableID] == nil {
                    previousLightsByStableID[light.sourceRegionStableID] = light
                }
            }
            let stableSourcePositionsByStableID = Dictionary(
                uniqueKeysWithValues: stableBrightRegionTracks.map { track in
                    (track.stableID, track.sourcePosition)
                }
            )
            let evaluatedLightStates = estimatedLights.enumerated().map { index, light in
                let stableID = stableRegionIDsByRegionIndex[light.sourceRegion.index] ?? 0
                let previousLight = previousLightsByStableID[stableID]
                let previousSlotLight = appModel.brightRegionEstimatedLights.indices.contains(index)
                    ? appModel.brightRegionEstimatedLights[index]
                    : nil
                let previousResolvedSlotLight = previousSlotLight?.isPlacementResolved == true
                    ? previousSlotLight
                    : nil
                let trackedSourcePosition = stableSourcePositionsByStableID[stableID]
                let rawPlacementPosition = trackedSourcePosition ?? light.position
                let placementPosition = usesGeometryPlacement
                    ? (previousLight?.position
                        ?? previousResolvedSlotLight?.position
                        ?? trackedSourcePosition
                        ?? light.position)
                    : (trackedSourcePosition ?? light.position)
                let rawShadowSoftness = shadowSoftness(for: light.sourceRegion)
                let appearance = stabilizedLightAppearance(
                    direction: light.direction,
                    color: light.color,
                    intensity: light.intensity,
                    shadowSoftness: rawShadowSoftness,
                    stableID: stableID,
                    isDirectionAverageEnabled: appModel.isStableLightDirectionAverageEnabled,
                    isColorAverageEnabled: appModel.isStableLightColorAverageEnabled,
                    isIntensityAverageEnabled: appModel.isStableLightIntensityAverageEnabled,
                    isShadowSoftnessAverageEnabled: appModel.isStableLightShadowSoftnessAverageEnabled,
                    isMinimumChangeEnabled: appModel.isStableLightAppearanceMinimumChangeEnabled,
                    directionMinimumChangeDegrees: appModel.stableLightDirectionMinimumChangeDegrees,
                    colorMinimumChange: appModel.stableLightColorMinimumChange,
                    intensityMinimumRelativeChange: appModel.stableLightIntensityMinimumRelativeChange,
                    shadowSoftnessMinimumChange: appModel.stableLightShadowSoftnessMinimumChange
                )

                let commonHeightMultiplier = heightPriorMultiplier(for: light.sourceRegion)
                let rawState = BrightRegionEstimatedLightState(
                    id: index,
                    sourceRegionIndex: light.sourceRegion.index,
                    sourceRegionStableID: stableID,
                    direction: light.direction,
                    position: rawPlacementPosition,
                    isPlacementResolved: true,
                    color: light.color,
                    intensity: light.intensity,
                    heightMultiplier: commonHeightMultiplier,
                    sourceSizePixels: light.sourceRegion.sourceSizePixels,
                    shadowSoftness: rawShadowSoftness
                )
                let candidateState = BrightRegionEstimatedLightState(
                    id: index,
                    sourceRegionIndex: light.sourceRegion.index,
                    sourceRegionStableID: stableID,
                    direction: appearance.candidateDirection,
                    position: rawPlacementPosition,
                    isPlacementResolved: true,
                    color: appearance.candidateColor,
                    intensity: appearance.candidateIntensity,
                    heightMultiplier: commonHeightMultiplier,
                    sourceSizePixels: light.sourceRegion.sourceSizePixels,
                    shadowSoftness: appearance.candidateShadowSoftness
                )
                let outputState = BrightRegionEstimatedLightState(
                    id: index,
                    sourceRegionIndex: light.sourceRegion.index,
                    sourceRegionStableID: stableID,
                    direction: appearance.direction,
                    position: placementPosition,
                    isPlacementResolved: !usesGeometryPlacement
                        || previousLight != nil
                        || previousResolvedSlotLight != nil,
                    color: appearance.color,
                    intensity: appearance.intensity,
                    heightMultiplier: commonHeightMultiplier,
                    sourceSizePixels: light.sourceRegion.sourceSizePixels,
                    shadowSoftness: appearance.shadowSoftness
                )
                return (raw: rawState, candidate: candidateState, output: outputState)
            }
            let rawEstimatedLightStates = evaluatedLightStates.map(\.raw)
            let filteredCandidateLightStates = evaluatedLightStates.map(\.candidate)
            let estimatedLightStates = evaluatedLightStates.map(\.output)
            pruneStableLightAppearanceHistories(activeStableIDs: Set(estimatedLightStates.map(\.sourceRegionStableID)))

            appModel.brightRegionRawEstimatedLights = rawEstimatedLightStates
            appModel.brightRegionFilteredCandidateLights = filteredCandidateLightStates

            appModel.brightRegionEstimatedLightDebugLine = estimatedLightDebugDescription(for: estimatedLight)
            appModel.brightRegionEstimatedLightPlacementDebugLine = lightPlacementDescription(for: appModel)
            appModel.brightRegionEstimatedLightPositionDebugLine = "\(estimatedLightPositionDebugDescription(for: estimatedLight)) | \(appModel.brightRegionEstimatedLightPlacementDebugLine)"
            appModel.brightRegionProbePosition = probePosition(from: originTransform)
            appModel.applyEstimatedLightSnapshot(
                hasLight: true,
                direction: estimatedLight.direction,
                position: estimatedLightStates.first?.position ?? estimatedLight.position,
                color: estimatedLightStates.first?.color ?? estimatedLight.color,
                intensity: estimatedLightStates.first?.intensity ?? estimatedLight.intensity,
                lights: estimatedLightStates
            )
        } else {
            appModel.brightRegionRawEstimatedLights = []
            appModel.brightRegionFilteredCandidateLights = []
            appModel.brightRegionEstimatedLightDebugLine = "Keine dominante Lichtquelle geschaetzt."
            appModel.brightRegionEstimatedLightPositionDebugLine = "Position: nicht verfuegbar"
            appModel.brightRegionEstimatedLightPlacementDebugLine = "Placement: nicht verfuegbar"
            appModel.brightRegionEstimatedLightTotalIntensityDebugLine = "Gesamthelligkeit: nicht verfuegbar"
            appModel.brightRegionProbePosition = probePosition(from: originTransform)
            appModel.applyEstimatedLightSnapshot(
                hasLight: false,
                direction: SIMD3<Float>(repeating: 0),
                position: appModel.brightRegionEstimatedLightPosition,
                color: appModel.brightRegionEstimatedLightColor,
                intensity: 0,
                lights: []
            )
            stableLightAppearanceHistoriesByStableID.removeAll()
            activeBrightRegionStableIDs.removeAll()
            pendingBrightRegionSlotSwitches.removeAll()
        }
        appModel.brightRegionPlaneHitDebugSummaries = [:]
        appModel.brightRegionRegionBaseDebugLines = sortedMeasuredRegions.enumerated().map { index, measuredRegion in
            let region = measuredRegion.region
            let isDominant = measuredRegion.index == dominantRegion?.index
            let baseDominanceScore = measuredRegion.dominanceScore(for: dominanceScoreMode)
            let heightMultiplier = heightPriorMultiplier(for: measuredRegion)
            let distanceMultiplier = distanceMultiplier(for: measuredRegion)
            let distance = isGeometryIgnored ? nil : appModel.brightRegionDistanceEstimates[measuredRegion.index]
            let dominanceScore = baseDominanceScore * distanceMultiplier * heightMultiplier
            let pixelCountPerFace = Dictionary(grouping: region.parts, by: \.face)
                .map { face, parts in
                    (face: face, pixelCount: parts.reduce(0) { $0 + $1.pixels.count })
                }
                .sorted { lhs, rhs in
                    lhs.face < rhs.face
                }
                .map { "face \($0.face) -> \($0.pixelCount) px" }
                .joined(separator: ", ")
            let luminance = measuredRegion.luminance
            let color = measuredRegion.color
            let dominantDescription = isDominant ? " | dominant" : ""
            let distanceDescription: String
            if let distance {
                distanceDescription = "\(String(format: "%.2f", distance))m"
            } else if distanceScoreMode != .off || isGeometryIgnored {
                distanceDescription = "fallback \(String(format: "%.2f", noHitDistanceFallback))m"
            } else {
                distanceDescription = "none"
            }
            let spotDescription = "observedLux: \(String(format: "%.1f", observedLux(for: measuredRegion))) | spotLux: \(String(format: "%.1f", spotLux(for: measuredRegion))) | spotMode: \(appModel.brightRegionSpotLightIntensityDistributionMode.title) | spotActive: \(activeDebugSpotLightCount) | spotX: \(String(format: "%.2f", spotIntensityMultiplier(for: index, activeLightCount: activeDebugSpotLightCount))) | finalSpot: \(String(format: "%.1f", finalSpotIntensity(for: measuredRegion, displayIndex: index, activeLightCount: activeDebugSpotLightCount))) | spotOuter: \(String(format: "%.1f", spotOuterAngleInDegrees(for: measuredRegion)))deg"
            let peakAverageRatioDescription = peakAverageRatio(for: measuredRegion).map {
                String(format: "%.2f", $0)
            } ?? "none"
            let shadowDescription = "sourceSize: \(String(format: "%.2f", measuredRegion.sourceSizePixels))px | sizeSoft: \(String(format: "%.2f", measuredRegion.shadowSoftness)) | peakAvg: \(peakAverageRatioDescription) | peakAvgSoft: \(String(format: "%.2f", peakAverageShadowSoftness(for: measuredRegion))) | shadowSoft: \(String(format: "%.2f", shadowSoftness(for: measuredRegion)))"
            let scoreDescription = "score: \(String(format: "%.4f", dominanceScore)) | base: \(String(format: "%.4f", baseDominanceScore)) | dist: \(distanceDescription) | distX: \(String(format: "%.3f", distanceMultiplier)) | heightX: \(String(format: "%.3f", heightMultiplier))"
            let luminanceDescription = "avgLum: \(String(format: "%.4f", luminance.average)) | totalLum: \(String(format: "%.4f", luminance.total)) | maxLum: \(String(format: "%.4f", luminance.max))"
            let colorDescription = "avgColor: (\(String(format: "%.4f", color.average.x)), \(String(format: "%.4f", color.average.y)), \(String(format: "%.4f", color.average.z))) | weightedColor: (\(String(format: "%.4f", color.luminanceWeightedAverage.x)), \(String(format: "%.4f", color.luminanceWeightedAverage.y)), \(String(format: "%.4f", color.luminanceWeightedAverage.z))) | peakColor: (\(String(format: "%.4f", color.brightestPixel.x)), \(String(format: "%.4f", color.brightestPixel.y)), \(String(format: "%.4f", color.brightestPixel.z))) | totalColor: (\(String(format: "%.4f", color.total.x)), \(String(format: "%.4f", color.total.y)), \(String(format: "%.4f", color.total.z)))"
            let stableIDDescription = stableRegionIDsByRegionIndex[measuredRegion.index].map {
                "stableID: \($0)"
            } ?? "stableID: none"
            return "Region \(index + 1)\(dominantDescription): \(stableIDDescription) | \(scoreDescription) | \(spotDescription) | \(shadowDescription) | \(region.pixelCount) px | faces: \(region.faces.sorted()) | \(pixelCountPerFace) | \(luminanceDescription) | \(colorDescription)"
        }
        appModel.brightRegionPlaneHitDebugSamples = planeHitDebugSamples(
            from: sortedMeasuredRegions,
            probeTransform: originTransform,
            faceSize: faceSize
        )
        appModel.brightRegionLightPlacementRequestID += 1
        let heightPriorDescription = isHeightPriorEnabled ? "max +30%" : "aus"
        appModel.brightRegionMaskDebugSummary = "Maske exportiert | Score: \(dominanceScoreMode.title) | Distance: \(distanceScoreMode.title) | Richtung: \(directionMode.title) | Farbe: \(colorMode.title) | Hoehenprior: \(heightPriorDescription) | ShadowSoft: \(shadowSoftnessMode.title) | p80: \(String(format: "%.4f", thresholds[0])) | p95: \(String(format: "%.4f", thresholds[1])) | p99: \(String(format: "%.4f", thresholds[2])) | Regionen roh: \(analysis.connectedRegionCount) | primaer: \(analysis.primaryMergedRegionCount) | final: \(analysis.mergedRegionCount)"
    }

    private func stableBrightRegionIDs(
        for measuredRegions: [MeasuredBrightRegion],
        originTransform: simd_float4x4,
        faceSize: Int,
        directionMode: BrightRegionDirectionMode,
        sourcePosition: SIMD3<Float>,
        distance: (MeasuredBrightRegion) -> Float,
        score: (MeasuredBrightRegion) -> Float
    ) -> [Int: Int] {
        let descriptors = measuredRegions.compactMap { region -> BrightRegionTrackDescriptor? in
            guard let direction = lightEstimator.estimateWorldDirection(
                for: region,
                probeTransform: originTransform,
                faceSize: faceSize,
                directionMode: directionMode
            ) else {
                return nil
            }

            return BrightRegionTrackDescriptor(
                measuredRegion: region,
                direction: direction,
                sourcePosition: sourcePosition + direction * distance(region),
                score: score(region),
                pixelCount: region.pixelCount,
                color: region.color.luminanceWeightedAverage
            )
        }

        guard !descriptors.isEmpty else {
            stableBrightRegionTracks = stableBrightRegionTracks
                .map { track in
                    var missedTrack = track
                    missedTrack.missedUpdates += 1
                    return missedTrack
                }
                .filter { $0.missedUpdates <= stableBrightRegionMissedUpdateLimit }
            return [:]
        }

        var stableIDsByRegionIndex: [Int: Int] = [:]
        var updatedTracks: [StableBrightRegionTrack] = []
        var matchedTrackIDs = Set<Int>()

        for descriptor in descriptors {
            if let matchedTrack = bestMatchingTrack(
                for: descriptor,
                excluding: matchedTrackIDs
            ) {
                matchedTrackIDs.insert(matchedTrack.stableID)
                stableIDsByRegionIndex[descriptor.measuredRegion.index] = matchedTrack.stableID
                updatedTracks.append(updatedTrack(from: matchedTrack, descriptor: descriptor))
            } else {
                let stableID = nextStableBrightRegionID
                nextStableBrightRegionID += 1
                stableIDsByRegionIndex[descriptor.measuredRegion.index] = stableID
                updatedTracks.append(StableBrightRegionTrack(
                    stableID: stableID,
                    direction: descriptor.direction,
                    sourcePosition: descriptor.sourcePosition,
                    score: descriptor.score,
                    pixelCount: descriptor.pixelCount,
                    color: descriptor.color,
                    missedUpdates: 0
                ))
            }
        }

        let missedTracks = stableBrightRegionTracks
            .filter { !matchedTrackIDs.contains($0.stableID) }
            .map { track in
                var missedTrack = track
                missedTrack.missedUpdates += 1
                return missedTrack
            }
            .filter { $0.missedUpdates <= stableBrightRegionMissedUpdateLimit }

        stableBrightRegionTracks = updatedTracks + missedTracks
        return stableIDsByRegionIndex
    }

    private func syncStableBrightRegionTrackPositions(from lights: [BrightRegionEstimatedLightState]) {
        let resolvedPositionsByStableID = Dictionary(
            lights.compactMap { light -> (Int, SIMD3<Float>)? in
                guard light.sourceRegionStableID > 0, light.isPlacementResolved else {
                    return nil
                }

                return (light.sourceRegionStableID, light.position)
            },
            uniquingKeysWith: { existing, _ in existing }
        )

        guard !resolvedPositionsByStableID.isEmpty else {
            return
        }

        stableBrightRegionTracks = stableBrightRegionTracks.map { track in
            guard let resolvedPosition = resolvedPositionsByStableID[track.stableID] else {
                return track
            }

            var updatedTrack = track
            updatedTrack.sourcePosition = resolvedPosition
            return updatedTrack
        }
    }

    private func hysteresisSelectedBrightRegions(
        from rankedRegions: [MeasuredBrightRegion],
        stableIDsByRegionIndex: [Int: Int],
        score: (MeasuredBrightRegion) -> Float,
        isEnabled: Bool
    ) -> [MeasuredBrightRegion] {
        guard isEnabled else {
            activeBrightRegionStableIDs = rankedRegions
                .prefix(brightRegionHysteresisActiveLimit)
                .compactMap { stableIDsByRegionIndex[$0.index] }
            pendingBrightRegionSlotSwitches.removeAll()
            return Array(rankedRegions.prefix(brightRegionHysteresisActiveLimit))
        }

        let regionsByStableID = Dictionary(
            rankedRegions.compactMap { region -> (Int, MeasuredBrightRegion)? in
                guard let stableID = stableIDsByRegionIndex[region.index] else {
                    return nil
                }

                return (stableID, region)
            },
            uniquingKeysWith: { existing, replacement in
                score(existing) >= score(replacement) ? existing : replacement
            }
        )
        let rankedStableIDs = rankedRegions.reduce(into: [Int]()) { result, region in
            guard let stableID = stableIDsByRegionIndex[region.index], !result.contains(stableID) else {
                return
            }

            result.append(stableID)
        }
        var selectedStableIDs: [Int] = []

        for slotIndex in 0..<brightRegionHysteresisActiveLimit {
            let previousStableID = slotIndex < activeBrightRegionStableIDs.count
                ? activeBrightRegionStableIDs[slotIndex]
                : nil
            let previousRegion = previousStableID.flatMap { regionsByStableID[$0] }
            let candidateStableID = rankedStableIDs.first { stableID in
                !selectedStableIDs.contains(stableID)
            }
            let candidateRegion = candidateStableID.flatMap { regionsByStableID[$0] }

            let selectedStableID: Int?
            if
                let previousStableID,
                let previousRegion,
                !selectedStableIDs.contains(previousStableID)
            {
                if
                    let candidateStableID,
                    let candidateRegion,
                    candidateStableID != previousStableID,
                    score(candidateRegion) > score(previousRegion) * brightRegionHysteresisSwitchMargin
                {
                    let pendingSwitch = pendingBrightRegionSlotSwitches[slotIndex]
                    let confirmationCount = pendingSwitch?.stableID == candidateStableID
                        ? pendingSwitch!.count + 1
                        : 1

                    if confirmationCount >= brightRegionHysteresisRequiredConfirmations {
                        selectedStableID = candidateStableID
                        pendingBrightRegionSlotSwitches[slotIndex] = nil
                    } else {
                        selectedStableID = previousStableID
                        pendingBrightRegionSlotSwitches[slotIndex] = (
                            stableID: candidateStableID,
                            count: confirmationCount
                        )
                    }
                } else {
                    selectedStableID = previousStableID
                    pendingBrightRegionSlotSwitches[slotIndex] = nil
                }
            } else {
                selectedStableID = candidateStableID
                pendingBrightRegionSlotSwitches[slotIndex] = nil
            }

            if let selectedStableID {
                selectedStableIDs.append(selectedStableID)
            }
        }

        let selectedRegions = selectedStableIDs.compactMap { regionsByStableID[$0] }
        activeBrightRegionStableIDs = selectedRegions.compactMap { stableIDsByRegionIndex[$0.index] }
        return selectedRegions
    }

    private func bestMatchingTrack(
        for descriptor: BrightRegionTrackDescriptor,
        excluding matchedTrackIDs: Set<Int>
    ) -> StableBrightRegionTrack? {
        let scoreLogRatioCostLimit = logf(16)
        let pixelLogRatioCostLimit = logf(24)

        return stableBrightRegionTracks
            .filter { !matchedTrackIDs.contains($0.stableID) }
            .compactMap { track -> (track: StableBrightRegionTrack, cost: Float)? in
                let isActiveTrack = activeBrightRegionStableIDs.contains(track.stableID)
                let angleDegrees = angularDistanceDegrees(descriptor.direction, track.direction)
                guard angleDegrees <= stableBrightRegionMaximumActiveAngleDegrees else {
                    return nil
                }
                let positionDistance = simd_distance(descriptor.sourcePosition, track.sourcePosition)
                guard positionDistance <= stableBrightRegionMaximumActivePositionDistance else {
                    return nil
                }

                let scoreLogRatio = min(
                    absoluteLogRatio(descriptor.score, track.score),
                    scoreLogRatioCostLimit
                )
                let pixelLogRatio = min(
                    absoluteLogRatio(Float(descriptor.pixelCount), Float(track.pixelCount)),
                    pixelLogRatioCostLimit
                )
                let colorDistance = simd_distance(descriptor.color, track.color)
                let missedPenalty = Float(track.missedUpdates) * stableBrightRegionMissedUpdateCost
                let activeTrackBonus = isActiveTrack ? stableBrightRegionActiveTrackCostBonus : 0
                let cost = angleDegrees
                    + positionDistance * stableBrightRegionPositionCostMultiplier
                    + scoreLogRatio * 2
                    + pixelLogRatio
                    + colorDistance * 0.75
                    + missedPenalty
                    + activeTrackBonus

                return (track, cost)
            }
            .min { lhs, rhs in lhs.cost < rhs.cost }?
            .track
    }

    private func updatedTrack(
        from track: StableBrightRegionTrack,
        descriptor: BrightRegionTrackDescriptor
    ) -> StableBrightRegionTrack {
        return StableBrightRegionTrack(
            stableID: track.stableID,
            direction: simd_normalize(
                track.direction * (1 - stableBrightRegionDescriptorBlend)
                    + descriptor.direction * stableBrightRegionDescriptorBlend
            ),
            sourcePosition: track.sourcePosition * (1 - stableBrightRegionDescriptorBlend)
                + descriptor.sourcePosition * stableBrightRegionDescriptorBlend,
            score: track.score * (1 - stableBrightRegionDescriptorBlend)
                + descriptor.score * stableBrightRegionDescriptorBlend,
            pixelCount: Int((
                Float(track.pixelCount) * (1 - stableBrightRegionDescriptorBlend)
                    + Float(descriptor.pixelCount) * stableBrightRegionDescriptorBlend
            ).rounded()),
            color: track.color * (1 - stableBrightRegionDescriptorBlend)
                + descriptor.color * stableBrightRegionDescriptorBlend,
            missedUpdates: 0
        )
    }

    private func angularDistanceDegrees(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Float {
        let dotProduct = min(max(simd_dot(simd_normalize(lhs), simd_normalize(rhs)), -1), 1)
        return acosf(dotProduct) * 180 / Float.pi
    }

    private func absoluteLogRatio(_ lhs: Float, _ rhs: Float) -> Float {
        let safeLHS = max(lhs, 0.0001)
        let safeRHS = max(rhs, 0.0001)
        return abs(logf(safeLHS / safeRHS))
    }

    private func stabilizedLightAppearance(
        direction: SIMD3<Float>,
        color: SIMD3<Float>,
        intensity: Float,
        shadowSoftness: Float,
        stableID: Int,
        isDirectionAverageEnabled: Bool,
        isColorAverageEnabled: Bool,
        isIntensityAverageEnabled: Bool,
        isShadowSoftnessAverageEnabled: Bool,
        isMinimumChangeEnabled: Bool,
        directionMinimumChangeDegrees: Float,
        colorMinimumChange: Float,
        intensityMinimumRelativeChange: Float,
        shadowSoftnessMinimumChange: Float
    ) -> (
        direction: SIMD3<Float>,
        color: SIMD3<Float>,
        intensity: Float,
        shadowSoftness: Float,
        candidateDirection: SIMD3<Float>,
        candidateColor: SIMD3<Float>,
        candidateIntensity: Float,
        candidateShadowSoftness: Float
    ) {
        guard stableID > 0 else {
            return (
                direction, color, intensity, shadowSoftness,
                direction, color, intensity, shadowSoftness
            )
        }

        var history = stableLightAppearanceHistoriesByStableID[stableID] ?? StableLightAppearanceHistory()
        let averagedDirection: SIMD3<Float>
        if isDirectionAverageEnabled {
            history.directions.append(direction)
            trim(&history.directions, limit: stableLightAppearanceHistoryLimit)
            averagedDirection = averageDirection(from: history.directions)
        } else {
            history.directions.removeAll()
            averagedDirection = direction
        }

        let averagedColor: SIMD3<Float>
        if isColorAverageEnabled {
            history.colors.append(color)
            trim(&history.colors, limit: stableLightAppearanceHistoryLimit)
            averagedColor = averageVector(from: history.colors)
        } else {
            history.colors.removeAll()
            averagedColor = color
        }

        let averagedIntensity: Float
        if isIntensityAverageEnabled {
            history.intensities.append(intensity)
            trim(&history.intensities, limit: stableLightAppearanceHistoryLimit)
            averagedIntensity = averageScalar(from: history.intensities)
        } else {
            history.intensities.removeAll()
            averagedIntensity = intensity
        }

        let averagedShadowSoftness: Float
        if isShadowSoftnessAverageEnabled {
            history.shadowSoftnesses.append(shadowSoftness)
            trim(&history.shadowSoftnesses, limit: stableLightAppearanceHistoryLimit)
            averagedShadowSoftness = averageScalar(from: history.shadowSoftnesses)
        } else {
            history.shadowSoftnesses.removeAll()
            averagedShadowSoftness = shadowSoftness
        }

        let stabilizedDirection = gatedDirectionValue(
            candidate: averagedDirection,
            previous: history.outputDirection,
            minimumAngleDegrees: directionMinimumChangeDegrees,
            isEnabled: isMinimumChangeEnabled
        )
        let stabilizedColor = gatedVectorValue(
            candidate: averagedColor,
            previous: history.outputColor,
            minimumChange: colorMinimumChange,
            isEnabled: isMinimumChangeEnabled
        )
        let stabilizedIntensity = gatedRelativeScalarValue(
            candidate: averagedIntensity,
            previous: history.outputIntensity,
            minimumRelativeChange: intensityMinimumRelativeChange,
            isEnabled: isMinimumChangeEnabled
        )
        let stabilizedShadowSoftness = gatedScalarValue(
            candidate: averagedShadowSoftness,
            previous: history.outputShadowSoftness,
            minimumChange: shadowSoftnessMinimumChange,
            isEnabled: isMinimumChangeEnabled
        )

        history.outputDirection = stabilizedDirection
        history.outputColor = stabilizedColor
        history.outputIntensity = stabilizedIntensity
        history.outputShadowSoftness = stabilizedShadowSoftness
        stableLightAppearanceHistoriesByStableID[stableID] = history
        return (
            stabilizedDirection,
            stabilizedColor,
            stabilizedIntensity,
            stabilizedShadowSoftness,
            averagedDirection,
            averagedColor,
            averagedIntensity,
            averagedShadowSoftness
        )
    }

    private func pruneStableLightAppearanceHistories(activeStableIDs: Set<Int>) {
        stableLightAppearanceHistoriesByStableID = stableLightAppearanceHistoriesByStableID.filter { stableID, _ in
            activeStableIDs.contains(stableID)
        }
    }

    private func trim<T>(_ values: inout [T], limit: Int) {
        if values.count > limit {
            values.removeFirst(values.count - limit)
        }
    }

    private func averageVector(from values: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !values.isEmpty else {
            return SIMD3<Float>(repeating: 0)
        }

        let total = values.reduce(SIMD3<Float>(repeating: 0)) { result, value in
            result + value
        }
        return total / Float(values.count)
    }

    private func averageDirection(from values: [SIMD3<Float>]) -> SIMD3<Float> {
        let average = averageVector(from: values)
        guard simd_length_squared(average) > 0.0001 else {
            return values.last ?? SIMD3<Float>(repeating: 0)
        }

        return simd_normalize(average)
    }

    private func averageScalar(from values: [Float]) -> Float {
        guard !values.isEmpty else {
            return 0
        }

        return values.reduce(0, +) / Float(values.count)
    }

    private func gatedDirectionValue(
        candidate: SIMD3<Float>,
        previous: SIMD3<Float>?,
        minimumAngleDegrees: Float,
        isEnabled: Bool
    ) -> SIMD3<Float> {
        guard isEnabled, let previous else {
            return candidate
        }

        return angularDistanceDegrees(candidate, previous) >= minimumAngleDegrees
            ? candidate
            : previous
    }

    private func gatedVectorValue(
        candidate: SIMD3<Float>,
        previous: SIMD3<Float>?,
        minimumChange: Float,
        isEnabled: Bool
    ) -> SIMD3<Float> {
        guard isEnabled, let previous else {
            return candidate
        }

        return simd_length(candidate - previous) >= minimumChange ? candidate : previous
    }

    private func gatedScalarValue(
        candidate: Float,
        previous: Float?,
        minimumChange: Float,
        isEnabled: Bool
    ) -> Float {
        guard isEnabled, let previous else {
            return candidate
        }

        return abs(candidate - previous) >= minimumChange ? candidate : previous
    }

    private func gatedRelativeScalarValue(
        candidate: Float,
        previous: Float?,
        minimumRelativeChange: Float,
        isEnabled: Bool
    ) -> Float {
        guard isEnabled, let previous else {
            return candidate
        }

        let safePrevious = max(abs(previous), 0.0001)
        let relativeChange = abs(candidate - previous) / safePrevious
        return relativeChange >= minimumRelativeChange ? candidate : previous
    }

    private func lightSourcePosition(
        appModel: AppModel,
        probeTransform: simd_float4x4
    ) -> SIMD3<Float> {
        switch appModel.brightRegionLightSourceOriginMode {
        case .geometryHitOrSceneProbe:
            appModel.environmentProbePositionOverride
        case .sceneProbePosition:
            appModel.environmentProbePositionOverride
        case .environmentProbePosition:
            probePosition(from: probeTransform)
        }
    }

    private func lightPlacementDescription(for appModel: AppModel) -> String {
        switch appModel.brightRegionLightSourceOriginMode {
        case .geometryHitOrSceneProbe:
            "Placement: directional fallback von lila Kugel"
        case .sceneProbePosition:
            "Placement: manuell von lila Kugel"
        case .environmentProbePosition:
            "Placement: manuell von blauer Kugel"
        }
    }

    private func planeHitDebugSamples(
        from sortedMeasuredRegions: [MeasuredBrightRegion],
        probeTransform: simd_float4x4,
        faceSize: Int
    ) -> [BrightRegionPlaneHitDebugSample] {
        sortedMeasuredRegions.enumerated().flatMap { displayIndex, measuredRegion in
            measuredRegion.luminance.luminanceSamples
                .sorted { lhs, rhs in lhs.luminance > rhs.luminance }
                .prefix(4)
                .enumerated()
                .map { sampleIndex, sample in
                    BrightRegionPlaneHitDebugSample(
                        id: "\(measuredRegion.index)-\(sample.face)-\(sample.x)-\(sample.y)",
                        regionIndex: measuredRegion.index,
                        regionDisplayIndex: displayIndex + 1,
                        sampleIndex: sampleIndex + 1,
                        face: sample.face,
                        direction: lightEstimator.estimateWorldDirection(
                            for: sample,
                            probeTransform: probeTransform,
                            faceSize: faceSize
                        ),
                        luminance: sample.luminance
                    )
                }
        }
    }

    private func environmentProbeAnalysisTransform(
        from rawTransform: simd_float4x4,
        appModel: AppModel
    ) -> simd_float4x4 {
        worldReferenceAdjustedProbeTransform(rawTransform, appModel: appModel)
    }

    private func worldReferenceAdjustedProbeTransform(
        _ transform: simd_float4x4,
        appModel: AppModel
    ) -> simd_float4x4 {
        guard appModel.hasWorldReferenceAnchorPose else {
            appModel.hasRotatedEnvironmentProbeDebugPosition = false
            return transform
        }

        let anchorPosition = appModel.worldReferenceAnchorPosition
        let pivotToOrigin = translationTransform(-anchorPosition)
        let originToPivot = translationTransform(anchorPosition)
        let rotation = horizontalRotationTransform(from: appModel.worldReferenceAnchorTransform)
        let adjustedTransform = originToPivot * rotation * pivotToOrigin * transform

        appModel.rotatedEnvironmentProbeDebugPosition = probePosition(from: adjustedTransform)
        appModel.hasRotatedEnvironmentProbeDebugPosition = true
        return adjustedTransform
    }

    private func horizontalRotationTransform(from transform: simd_float4x4) -> simd_float4x4 {
        let projectedZAxis = SIMD2<Float>(
            transform.columns.2.x,
            transform.columns.2.z
        )
        let zAxisLength = sqrt(projectedZAxis.x * projectedZAxis.x + projectedZAxis.y * projectedZAxis.y)

        guard zAxisLength > 0.0001 else {
            return simd_float4x4(1)
        }

        let sinYaw = projectedZAxis.x / zAxisLength
        let cosYaw = projectedZAxis.y / zAxisLength

        return simd_float4x4(
            SIMD4<Float>(cosYaw, 0, -sinYaw, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(sinYaw, 0, cosYaw, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    private func translationTransform(_ translation: SIMD3<Float>) -> simd_float4x4 {
        var transform = simd_float4x4(1)
        transform.columns.3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
        return transform
    }

    private func estimatedLightDebugDescription(for light: EstimatedEnvironmentLight) -> String {
        let direction = light.direction
        let position = light.position
        let color = light.color

        return "Dominante Lichtquelle | direction: (\(String(format: "%.3f", direction.x)), \(String(format: "%.3f", direction.y)), \(String(format: "%.3f", direction.z))) | position: (\(String(format: "%.3f", position.x)), \(String(format: "%.3f", position.y)), \(String(format: "%.3f", position.z))) | color: (\(String(format: "%.3f", color.x)), \(String(format: "%.3f", color.y)), \(String(format: "%.3f", color.z))) | intensity: \(String(format: "%.4f", light.intensity))"
    }

    private func estimatedLightPositionDebugDescription(for light: EstimatedEnvironmentLight) -> String {
        let position = light.position
        return "Position: x \(String(format: "%.3f", position.x)) | y \(String(format: "%.3f", position.y)) | z \(String(format: "%.3f", position.z))"
    }

    private func probePosition(from transform: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
    }

    private func eulerDegrees(from quaternion: simd_quatf) -> SIMD3<Float> {
        let q = quaternion.normalized.vector
        let x = q.x
        let y = q.y
        let z = q.z
        let w = q.w

        let roll = atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y))
        let sinp = 2 * (w * y - z * x)
        let pitch = abs(sinp) >= 1
            ? (sinp >= 0 ? Float.pi / 2 : -Float.pi / 2)
            : asin(sinp)
        let yaw = atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))

        return SIMD3<Float>(roll, pitch, yaw) * (180 / Float.pi)
    }

    private func poseDebugDescription(label: String, transform: simd_float4x4) -> String {
        let position = probePosition(from: transform)
        let forward = worldDirection(from: [0, 0, -1], transform: transform)
        let right = worldDirection(from: [1, 0, 0], transform: transform)
        let up = worldDirection(from: [0, 1, 0], transform: transform)

        return "\(label) pos \(formatDirection(position)) | fwd \(formatDirection(forward)), yaw \(formatYaw(forward)) | right \(formatDirection(right)), yaw \(formatYaw(right)) | up \(formatDirection(up))"
    }

    private func worldDirection(
        from localDirection: SIMD3<Float>,
        transform: simd_float4x4
    ) -> SIMD3<Float> {
        let worldDirection4 = transform * SIMD4<Float>(
            localDirection.x,
            localDirection.y,
            localDirection.z,
            0
        )
        return simd_normalize(SIMD3<Float>(
            worldDirection4.x,
            worldDirection4.y,
            worldDirection4.z
        ))
    }

    private func localCubemapDirection(for face: CubemapFace) -> SIMD3<Float> {
        switch face {
        case .positiveX:
            [1, 0, 0]
        case .negativeX:
            [-1, 0, 0]
        case .positiveY:
            [0, 1, 0]
        case .negativeY:
            [0, -1, 0]
        case .positiveZ:
            [0, 0, -1]
        case .negativeZ:
            [0, 0, 1]
        }
    }

    private func faceName(for face: CubemapFace) -> String {
        switch face {
        case .positiveX:
            "+X(slice 0)"
        case .negativeX:
            "-X(slice 1)"
        case .positiveY:
            "+Y(slice 2)"
        case .negativeY:
            "-Y(slice 3)"
        case .positiveZ:
            "+Z(slice 4)"
        case .negativeZ:
            "-Z(slice 5)"
        }
    }

    private func formatDirection(_ direction: SIMD3<Float>) -> String {
        "(\(String(format: "%.2f", direction.x)), \(String(format: "%.2f", direction.y)), \(String(format: "%.2f", direction.z)))"
    }

    private func formatYaw(_ direction: SIMD3<Float>) -> String {
        "\(String(format: "%.1f", yawDegrees(for: direction)))deg"
    }

    private func yawDegrees(for direction: SIMD3<Float>) -> Float {
        let yawRadians = atan2(direction.x, direction.z)
        return yawRadians * 180 / .pi
    }

    private func savePreviewImages(from texture: any MTLTexture) -> SavedProbeImages {
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return SavedProbeImages(crossURLs: [], faceURLs: [:])
        }
        
        let outputFolder = folder.appending(path: "EnvironmentProbePreview", directoryHint: .isDirectory)
        
        do {
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            
            let sliceCount = texture.textureType == .typeCube ? 6 : max(texture.arrayLength, 1)
            var faceImages: [Int: CIImage] = [:]
            var unscaledFaceImages: [Int: CIImage] = [:]
            
            for slice in 0..<sliceCount {
                guard let textureView = texture.makeTextureView(
                    pixelFormat: texture.pixelFormat,
                    textureType: .type2D,
                    levels: 0..<1,
                    slices: slice..<(slice + 1)
                ),
                      var image = CIImage(mtlTexture: textureView, options: [.colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
                else {
                    continue
                }
                
                let orientedImage = image
                    .transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(texture.height)))

                unscaledFaceImages[slice] = orientedImage
                faceImages[slice] = orientedImage
                    .transformed(by: CGAffineTransform(scaleX: 32, y: 32))
            }
            
            let faceURLs = try saveRawFaceImages(
                from: faceImages,
                outputFolder: outputFolder
            )
            let interpolatedOutputURL = try saveCrossLayout(
                from: faceImages,
                outputFolder: outputFolder
            )
            let nearestOutputURL = try saveNearestCrossLayout(
                from: unscaledFaceImages,
                scale: 32,
                outputFolder: outputFolder
            )
            
            print(
                "Environment Probe Preview gespeichert:",
                outputFolder.path(percentEncoded: false)
            )
            return SavedProbeImages(
                crossURLs: [interpolatedOutputURL, nearestOutputURL].compactMap { $0 },
                faceURLs: faceURLs
            )
        } catch {
            print("Environment Probe Preview konnte nicht gespeichert werden:", error.localizedDescription)
            return SavedProbeImages(crossURLs: [], faceURLs: [:])
        }
    }
    
    private func saveRawFaceImages(
        from faceImages: [Int: CIImage],
        outputFolder: URL
    ) throws -> [Int: URL] {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var urls: [Int: URL] = [:]
        
        for face in CubemapFace.allCases {
            guard let image = faceImages[face.rawValue] else {
                continue
            }
            
            let outputURL = outputFolder.appending(path: "probe-face-\(face.filenameComponent)-raw.png")
            try ciContext.writePNGRepresentation(
                of: image,
                to: outputURL,
                format: .RGBA8,
                colorSpace: colorSpace
            )
            urls[face.rawValue] = outputURL
        }
        
        return urls
    }
    
    private func saveCrossLayout(
        from faceImages: [Int: CIImage],
        outputFolder: URL
    ) throws -> URL? {
        guard
            let referenceImage = faceImages[CubemapFace.positiveZ.rawValue] ?? faceImages.values.first
        else {
            return nil
        }
        
        let faceWidth = referenceImage.extent.width
        let faceHeight = referenceImage.extent.height
        let canvasRect = CGRect(x: 0, y: 0, width: faceWidth * 4, height: faceHeight * 3)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var composite = CIImage(color: .black).cropped(to: canvasRect)

        for face in CubemapFace.allCases {
            guard let image = faceImages[face.rawValue] else {
                continue
            }

            let position = face.crossPosition
            let translatedImage = image.transformed(by: .init(
                translationX: CGFloat(position.column) * faceWidth,
                y: CGFloat(2 - position.row) * faceHeight
            ))

            composite = translatedImage.composited(over: composite)
        }

        let outputURL = outputFolder.appending(path: "probe-cross-raw.png")
        try ciContext.writePNGRepresentation(
            of: composite,
            to: outputURL,
            format: .RGBA8,
            colorSpace: colorSpace
        )
        return outputURL
    }

    private func saveNearestCrossLayout(
        from faceImages: [Int: CIImage],
        scale: Int,
        outputFolder: URL
    ) throws -> URL? {
        guard
            let referenceImage = faceImages[CubemapFace.positiveZ.rawValue] ?? faceImages.values.first
        else {
            return nil
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let faceWidth = Int(referenceImage.extent.width.rounded())
        let faceHeight = Int(referenceImage.extent.height.rounded())
        guard faceWidth > 0, faceHeight > 0, scale > 0 else {
            return nil
        }

        let scaledFaceWidth = faceWidth * scale
        let scaledFaceHeight = faceHeight * scale
        let canvasWidth = scaledFaceWidth * 4
        let canvasHeight = scaledFaceHeight * 3
        guard
            let context = CGContext(
                data: nil,
                width: canvasWidth,
                height: canvasHeight,
                bitsPerComponent: 8,
                bytesPerRow: canvasWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        context.interpolationQuality = .none

        for face in CubemapFace.allCases {
            guard let image = faceImages[face.rawValue] else {
                continue
            }

            let imageExtent = image.extent.integral
            guard let cgImage = ciContext.createCGImage(image, from: imageExtent) else {
                continue
            }

            let position = face.crossPosition
            let rect = CGRect(
                x: CGFloat(position.column * scaledFaceWidth),
                y: CGFloat((2 - position.row) * scaledFaceHeight),
                width: CGFloat(scaledFaceWidth),
                height: CGFloat(scaledFaceHeight)
            )
            context.draw(cgImage, in: rect)
        }

        guard let composite = context.makeImage() else {
            return nil
        }

        let outputURL = outputFolder.appending(path: "probe-cross-raw-nearest.png")
        try writePNG(image: composite, to: outputURL)
        return outputURL
    }
    
    private func saveMaskPreviewImages(
        from texture: any MTLTexture,
        threshold: Float
    ) -> SavedProbeImages {
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return SavedProbeImages(crossURLs: [], faceURLs: [:])
        }
        
        let outputFolder = folder.appending(path: "EnvironmentProbeMaskPreview", directoryHint: .isDirectory)
        
        do {
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            
            let sliceCount = texture.textureType == .typeCube ? 6 : max(texture.arrayLength, 1)
            var faceImages: [Int: CGImage] = [:]
            
            for slice in 0..<sliceCount {
                guard
                    let faceTexture = texture.makeTextureView(
                        pixelFormat: texture.pixelFormat,
                        textureType: .type2D,
                        levels: 0..<1,
                        slices: slice..<(slice + 1)
                    ),
                    let faceImage = makeMaskFaceImage(from: faceTexture)
                else {
                    continue
                }
                
                faceImages[slice] = faceImage
            }
            
            let faceURLs = try saveMaskFaceImages(
                from: faceImages,
                outputFolder: outputFolder
            )
            let crossURL = try saveMaskCrossLayout(
                from: faceImages,
                outputFolder: outputFolder,
                threshold: threshold
            )
            
            return SavedProbeImages(
                crossURLs: crossURL.map { [$0] } ?? [],
                faceURLs: faceURLs
            )
        } catch {
            print("Environment Probe Mask Preview konnte nicht gespeichert werden:", error.localizedDescription)
            return SavedProbeImages(crossURLs: [], faceURLs: [:])
        }
    }
    
    private func makeMaskFaceImage(from texture: any MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        let floatCount = width * height
        let bytesPerRow = width * MemoryLayout<Float>.stride
        var floatPixels = [Float](repeating: 0, count: floatCount)
        
        floatPixels.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        
        let grayPixels = Data(floatPixels.map { pixel in
            UInt8(max(0, min(255, Int(pixel * 255.0))))
        })
        
        guard let provider = CGDataProvider(data: grayPixels as CFData) else {
            return nil
        }
        
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
    
    private func makeFaceImages(from texture: any MTLTexture, scale: CGFloat) -> [Int: CIImage] {
        let sliceCount = texture.textureType == .typeCube ? 6 : max(texture.arrayLength, 1)
        var faceImages: [Int: CIImage] = [:]
        
        for slice in 0..<sliceCount {
            guard let textureView = texture.makeTextureView(
                pixelFormat: texture.pixelFormat,
                textureType: .type2D,
                levels: 0..<1,
                slices: slice..<(slice + 1)
            ),
                  let baseImage = CIImage(
                    mtlTexture: textureView,
                    options: [.colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!]
                  ) else {
                continue
            }
            
            let orientedImage = baseImage
                .transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(texture.height)))
            
            if scale == 1 {
                faceImages[slice] = orientedImage
            } else {
                faceImages[slice] = orientedImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        
        return faceImages
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
            print("EnvironmentProbeReader: Pixel-Format fuer readRGBPixels nicht unterstuetzt: \(texture.pixelFormat.rawValue)")
            return nil
        }
    }

    private static func srgbToLinear(_ value: Float) -> Float {
        if value <= 0.04045 {
            return value / 12.92
        }

        return powf((value + 0.055) / 1.055, 2.4)
    }

    private func brightestCubemapFace(in texture: any MTLTexture) -> (face: CubemapFace, averageLuminance: Float)? {
        let sliceCount = texture.textureType == .typeCube ? 6 : max(texture.arrayLength, 1)
        var faceAverages: [(face: CubemapFace, averageLuminance: Float)] = []

        for face in CubemapFace.allCases where face.rawValue < sliceCount {
            guard
                let faceTexture = texture.makeTextureView(
                    pixelFormat: texture.pixelFormat,
                    textureType: .type2D,
                    levels: 0..<1,
                    slices: face.rawValue..<(face.rawValue + 1)
                ),
                let pixels = readRGBPixels(from: faceTexture),
                !pixels.isEmpty
            else {
                continue
            }

            let totalLuminance = pixels.reduce(Float(0)) { total, pixel in
                total + dot(pixel, SIMD3<Float>(0.2126, 0.7152, 0.0722))
            }
            faceAverages.append((
                face: face,
                averageLuminance: totalLuminance / Float(pixels.count)
            ))
        }

        return faceAverages.max { lhs, rhs in
            lhs.averageLuminance < rhs.averageLuminance
        }
    }

    private func saveMaskFaceImages(
        from faceImages: [Int: CGImage],
        outputFolder: URL
    ) throws -> [Int: URL] {
        var urls: [Int: URL] = [:]
        
        for face in CubemapFace.allCases {
            guard let image = faceImages[face.rawValue] else {
                continue
            }
            
            let outputURL = outputFolder.appending(path: "mask-face-\(face.filenameComponent).png")
            try writePNG(image: image, to: outputURL)
            urls[face.rawValue] = outputURL
        }
        
        return urls
    }
    
    private func saveMaskCrossLayout(
        from faceImages: [Int: CGImage],
        outputFolder: URL,
        threshold: Float
    ) throws -> URL? {
        guard let referenceImage = faceImages[CubemapFace.positiveZ.rawValue] ?? faceImages.values.first else {
            return nil
        }
        
        let faceWidth = referenceImage.width
        let faceHeight = referenceImage.height
        let canvasWidth = faceWidth * 4
        let canvasHeight = faceHeight * 3
        
        guard
            let context = CGContext(
                data: nil,
                width: canvasWidth,
                height: canvasHeight,
                bitsPerComponent: 8,
                bytesPerRow: canvasWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else {
            return nil
        }
        
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        context.interpolationQuality = .none
        
        for face in CubemapFace.allCases {
            guard let image = faceImages[face.rawValue] else {
                continue
            }
            
            let position = face.crossPosition
            let rect = CGRect(
                x: position.column * faceWidth,
                y: (2 - position.row) * faceHeight,
                width: faceWidth,
                height: faceHeight
            )
            context.draw(image, in: rect)
        }
        
        guard let composite = context.makeImage() else {
            return nil
        }
        
        let outputURL = outputFolder.appending(path: "mask-cross-threshold-\(String(format: "%.4f", threshold)).png")
        try writePNG(image: composite, to: outputURL)
        return outputURL
    }
    
    private func writePNG(image: CGImage, to outputURL: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
    
    private func luminancePercentiles(
        for texture: any MTLTexture,
        percentiles: [Float]
    ) -> [Float]? {
        let sliceCount = texture.textureType == .typeCube ? 6 : max(texture.arrayLength, 1)
        guard sliceCount > 0, !percentiles.isEmpty else {
            return nil
        }

        var luminanceValues: [Float] = []
        luminanceValues.reserveCapacity(texture.width * texture.height * sliceCount)

        for slice in 0..<sliceCount {
            guard
                let faceTexture = texture.makeTextureView(
                    pixelFormat: texture.pixelFormat,
                    textureType: .type2D,
                    levels: 0..<1,
                    slices: slice..<(slice + 1)
                ),
                let pixels = readRGBPixels(from: faceTexture)
            else {
                continue
            }

            for pixel in pixels {
                let luminance = dot(pixel, SIMD3<Float>(0.2126, 0.7152, 0.0722))
                luminanceValues.append(luminance)
            }
        }

        guard !luminanceValues.isEmpty else {
            return nil
        }

        let sortedValues = luminanceValues.sorted()

        return percentiles.map { percentile in
            percentileValue(in: sortedValues, percentile: percentile)
        }
    }

    private func percentileValue(
        in sortedValues: [Float],
        percentile: Float
    ) -> Float {
        guard !sortedValues.isEmpty else {
            return 0
        }

        let clampedPercentile = min(max(percentile, 0), 1)
        let lastIndex = sortedValues.count - 1
        let position = Float(lastIndex) * clampedPercentile
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))

        if lowerIndex == upperIndex {
            return sortedValues[lowerIndex]
        }

        let fraction = position - Float(lowerIndex)
        let lowerValue = sortedValues[lowerIndex]
        let upperValue = sortedValues[upperIndex]
        return lowerValue + (upperValue - lowerValue) * fraction

    }
}

private struct SavedProbeImages {
    let crossURLs: [URL]
    let faceURLs: [Int: URL]
}

extension EnvironmentProbeReader {
    private static let exportTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static let isoTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
