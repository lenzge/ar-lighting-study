//
//  TechnicalTestsWindow.swift
//  AR-Lighting-Study
//

//  Provides the UI for runtime, temporal-stability, and FPS stress tests.
//  It starts, stops, and shares the datasets produced by those test workflows.
import SwiftUI

struct TechnicalTestsWindow: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedPerformanceStressScenario = PerformanceStressScenario.environmentAndGrounding

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Technische Tests")
                    .font(.title2.weight(.semibold))

                runtimeEvaluationControls

                Divider()

                temporalStabilityTestControls

                Divider()

                fpsStressTestControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .task {
            if appModel.runtimeEvaluationLatestFileURLs.isEmpty {
                appModel.environmentProbeReader.loadLatestRuntimeEvaluation(appModel: appModel)
            }
            if appModel.fpsStressTestLatestFileURLs.isEmpty {
                appModel.loadLatestFPSStressTest()
            }
        }
    }

    private var runtimeEvaluationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Test 1 – Laufzeit & Probe-Updates")
                .font(.headline)

            Text("Misst 60 Sekunden lang echte ARKit-Probe-Ankuenfte und die Dauer vollstaendiger Analysen.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("60s Laufzeittest starten") {
                    appModel.environmentProbeReader.startRuntimeEvaluation(appModel: appModel)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    appModel.isRuntimeEvaluationRunning
                        || appModel.isEnvironmentProbeSequenceExportRunning
                        || !appModel.hasEnvironmentProbeTexture
                        || !appModel.canRecomputeBrightRegionLight
                )

                Button("Test stoppen") {
                    appModel.environmentProbeReader.stopRuntimeEvaluation(appModel: appModel)
                }
                .buttonStyle(.bordered)
                .disabled(!appModel.isRuntimeEvaluationRunning)
            }

            Button("Letzte Messung laden") {
                appModel.environmentProbeReader.loadLatestRuntimeEvaluation(appModel: appModel)
            }
            .buttonStyle(.bordered)
            .disabled(appModel.isRuntimeEvaluationRunning)

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(runtimeEvaluationStatusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(appModel.isRuntimeEvaluationRunning ? .primary : .secondary)
            }

            if let folderURL = appModel.runtimeEvaluationLatestFolderURL {
                Text(folderURL.path(percentEncoded: false))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !appModel.runtimeEvaluationLatestFileURLs.isEmpty {
                ShareLink(
                    items: appModel.runtimeEvaluationLatestFileURLs,
                    subject: Text("Technische Auswertung – Test 1"),
                    message: Text("Probe-Ankunftsraten und Analyselaufzeiten als CSV")
                ) {
                    Text("CSV-Dateien teilen / sichern")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var temporalStabilityTestControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Test 2 – Zeitliche Stabilitaet")
                .font(.headline)

            Text("Vergleicht getrennte 60-s-Laeufe ohne und mit Stabilisierung. Env-Maps, Masken und Lichtparameter werden alle 2 s gespeichert.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Testmodus", selection: temporalStabilityTestModeBinding) {
                ForEach(TemporalStabilityTestMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(appModel.isEnvironmentProbeSequenceExportRunning)

            HStack(spacing: 8) {
                Button("60s Test starten") {
                    appModel.environmentProbeReader.startProbeSequenceExport(
                        appModel: appModel,
                        mode: appModel.selectedTemporalStabilityTestMode
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    appModel.isEnvironmentProbeSequenceExportRunning
                        || appModel.isRuntimeEvaluationRunning
                        || appModel.isFPSStressTestRunning
                        || !appModel.hasEnvironmentProbeTexture
                )

                Button("Test stoppen") {
                    appModel.environmentProbeReader.stopProbeSequenceExport(appModel: appModel)
                }
                .buttonStyle(.bordered)
                .disabled(!appModel.isEnvironmentProbeSequenceExportRunning)
            }

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(temporalStabilityStatusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(appModel.isEnvironmentProbeSequenceExportRunning ? .primary : .secondary)
            }

            if let folderURL = appModel.environmentProbeLatestSequenceExportFolderURL {
                Text(folderURL.path(percentEncoded: false))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            #if !targetEnvironment(simulator)
            if !appModel.environmentProbeLatestSequenceExportFileURLs.isEmpty {
                ShareLink(
                    items: appModel.environmentProbeLatestSequenceExportFileURLs,
                    subject: Text("Technische Auswertung – Test 2"),
                    message: Text("Zeitliche Stabilitaet: Env-Maps, Lichtparameter und Zusammenfassung")
                ) {
                    Text("Test-2-Daten per AirDrop teilen")
                }
                .buttonStyle(.borderedProminent)
            }
            #endif
        }
    }

    private var fpsStressTestControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Test 4 – FPS-Stresstest")
                .font(.headline)

            Picker("Stress", selection: $selectedPerformanceStressScenario) {
                ForEach(PerformanceStressScenario.allCases) { scenario in
                    Text(scenario.title).tag(scenario)
                }
            }

            HStack(spacing: 8) {
                Button("Szenario anwenden") {
                    appModel.environmentProbeReader.pauseAnalysisForFPSStressTest(appModel: appModel)
                    appModel.applyPerformanceStressScenario(selectedPerformanceStressScenario)
                }
                .buttonStyle(.bordered)
                .disabled(appModel.isFPSStressTestRunning)

                Button("FPS-Test starten") {
                    appModel.startFPSStressTest(scenario: selectedPerformanceStressScenario)
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.isFPSStressTestRunning)

                Button("Test stoppen") {
                    appModel.cancelFPSStressTest()
                }
                .buttonStyle(.bordered)
                .disabled(!appModel.isFPSStressTestRunning)
            }

            Button("Letzte Messung laden") {
                appModel.loadLatestFPSStressTest()
            }
            .buttonStyle(.bordered)
            .disabled(appModel.isFPSStressTestRunning)

            Text(appModel.performanceRenderStressStatus)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Text("Aktiv: \(appModel.activePerformanceDirectionalLightCount) Directional Lights | \(appModel.activePerformanceDynamicShadowCount) dynamische Schatten | Environment + Grounding")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(fpsStressTestStatusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(appModel.isFPSStressTestRunning ? .primary : .secondary)
            }

            if let folderURL = appModel.fpsStressTestLatestFolderURL {
                Text(folderURL.path(percentEncoded: false))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !appModel.fpsStressTestLatestFileURLs.isEmpty {
                ShareLink(
                    items: appModel.fpsStressTestLatestFileURLs,
                    subject: Text("Technische Auswertung – Test 4"),
                    message: Text("FPS-Stresstest mit Directional Lights als CSV")
                ) {
                    Text("CSV-Dateien teilen / sichern")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var temporalStabilityTestModeBinding: Binding<TemporalStabilityTestMode> {
        Binding(
            get: { appModel.selectedTemporalStabilityTestMode },
            set: { appModel.selectedTemporalStabilityTestMode = $0 }
        )
    }

    private var runtimeEvaluationStatusText: String {
        guard appModel.isRuntimeEvaluationRunning, let startedAt = appModel.runtimeEvaluationStartedAt else {
            return appModel.runtimeEvaluationStatus
        }

        let elapsedSeconds = Date().timeIntervalSince(startedAt)
        let remainingSeconds = max(0, appModel.runtimeEvaluationDurationSeconds - Int(elapsedSeconds.rounded(.down)))
        return "\(appModel.runtimeEvaluationStatus) · noch \(remainingSeconds) s"
    }

    private var temporalStabilityStatusText: String {
        guard appModel.isEnvironmentProbeSequenceExportRunning, let startedAt = appModel.temporalStabilityTestStartedAt else {
            return appModel.environmentProbeSequenceExportStatus
        }

        let elapsedSeconds = Date().timeIntervalSince(startedAt)
        let remainingSeconds = max(0, appModel.temporalStabilityTestDurationSeconds - Int(elapsedSeconds.rounded(.down)))
        return "\(appModel.environmentProbeSequenceExportStatus) · noch \(remainingSeconds) s"
    }

    private var fpsStressTestStatusText: String {
        guard appModel.isFPSStressTestRunning, let phaseStartedAt = appModel.fpsStressTestPhaseStartedAt else {
            return appModel.fpsStressTestStatus
        }

        let elapsed = Date().timeIntervalSince(phaseStartedAt)
        let remaining = max(0, appModel.fpsStressTestPhaseDurationSeconds - Int(elapsed.rounded(.down)))
        let phase = switch appModel.fpsStressTestPhase {
        case .idle: "bereit"
        case .warmingUp: "Warm-up"
        case .measuring: "Messung"
        }
        return "\(phase): noch \(remaining) s | \(appModel.fpsStressTestStatus)"
    }
}
