//
//  ContentView.swift
//  AR-Lighting-Study
//
//  Provides the landing screen, the user-test entry flow, and the development menu.
//  It is the primary UI bridge for opening the immersive experience and debug tools.

import SwiftUI
import Darwin
import simd
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var isShowingDevelopmentMenu = false

    var body: some View {
        if isShowingDevelopmentMenu {
            DevelopmentMenuView {
                Task { @MainActor in
                    await startImmersiveStackingMode()
                }
            }
        } else {
            VStack(spacing: 104) {
                Button {
                    Task { @MainActor in
                        await startImmersiveStackingMode()
                    }
                } label: {
                    Text("Start")
                        .font(.largeTitle.weight(.semibold))
                        .frame(height: 144)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(appModel.immersiveSpaceState == .inTransition)

                Button {
                    appModel.isStackingControlsVisible = false
                    appModel.configureDevelopmentStartMode()
                    isShowingDevelopmentMenu = true
                } label: {
                    Text("Development Mode")
                        .font(.headline.weight(.semibold))
                        .frame(height: 48)
                        .frame(width: 240)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .frame(width: 520)
            .padding(32)
        }
    }

    @MainActor
    private func startImmersiveStackingMode() async {
        appModel.configureStackingStartMode()

        switch appModel.immersiveSpaceState {
        case .open:
            dismiss()

        case .closed:
            appModel.immersiveSpaceState = .inTransition
            switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
            case .opened:
                dismiss()

            case .userCancelled, .error:
                fallthrough
            @unknown default:
                appModel.immersiveSpaceState = .closed
            }

        case .inTransition:
            break
        }
    }
}

struct StackingControlsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isShowingQuestionnaire = false
    @State private var isShowingCompletionMenu = false
    @State private var questionnaireRatings: [Int: Int] = [:]

    var body: some View {
        Group {
            if isShowingCompletionMenu {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Danke fürs mitmachen!")
                        .font(.title2.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .center)

                    Button {
                        isShowingCompletionMenu = false
                        questionnaireRatings.removeAll()
                        appModel.restartStackingRotation()
                    } label: {
                        Text("Continue")
                            .font(.title3.weight(.semibold))
                            .frame(height: 56)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button {
                        exit(0)
                    } label: {
                        Text("Exit")
                            .font(.title3.weight(.semibold))
                            .frame(height: 56)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            } else if isShowingQuestionnaire {
                VStack(alignment: .leading, spacing: 40) {
                    ForEach(Array(questionnaireQuestions.enumerated()), id: \.offset) { index, question in
                        LikertQuestionRow(
                            question: question,
                            selection: Binding(
                                get: { questionnaireRatings[index] },
                                set: { questionnaireRatings[index] = $0 }
                            )
                        )
                    }

                    Button {
                        appModel.saveStackingQuestionnaireResponse(
                            ratingsByQuestionIndex: questionnaireRatings
                        )
                        isShowingQuestionnaire = false
                        if !appModel.isStackingPresetExplorerActive {
                            appModel.advanceStackingLevel()
                        }
                    } label: {
                        Text("Continue")
                            .font(.title3.weight(.semibold))
                            .frame(height: 64)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
                }
            } else if appModel.isStackingPresetExplorerActive {
                VStack(alignment: .leading, spacing: 12) {
                    Text(appModel.stackingLightPresetDebugLine)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    LazyVGrid(columns: explorerPresetColumns, spacing: 8) {
                        ForEach(BrightRegionTestPreset.all) { preset in
                            Button {
                                appModel.applyStackingExplorerPreset(preset)
                            } label: {
                                Text(preset.displayID)
                                    .font(.title3.weight(.semibold))
                                    .frame(height: 56)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(appModel.activeStackingLightPreset.id == preset.id ? .accentColor : .gray)
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            appModel.saveStackingPresetSelectionResponse()
                            isShowingCompletionMenu = true
                        } label: {
                            Text("Next")
                                .font(.title3.weight(.semibold))
                                .frame(height: 56)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button {
                            appModel.reloadStackingCubeScene()
                        } label: {
                            Text("Restart")
                                .font(.title3.weight(.semibold))
                                .frame(height: 56)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
            } else {
                VStack(spacing: 16) {
                    Text(appModel.stackingLightPresetDebugLine)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    Button {
                        questionnaireRatings.removeAll()
                        isShowingQuestionnaire = true
                    } label: {
                        Text("Next")
                            .font(.title3.weight(.semibold))
                            .frame(height: 64)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        appModel.reloadStackingCubeScene()
                    } label: {
                        Text("Restart")
                            .font(.title3.weight(.semibold))
                            .frame(height: 64)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        }
        .frame(width: controlsWidth)
        .padding(isShowingQuestionnaire ? 36 : 24)
    }

    private var controlsWidth: CGFloat {
        if isShowingQuestionnaire {
            return 920
        }

        if appModel.isStackingPresetExplorerActive || isShowingCompletionMenu {
            return 720
        }

        return 520
    }

    private var explorerPresetColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ]
    }

    private var questionnaireQuestions: [String] {
        StackingQuestionnaire.questions
    }
}

private struct LikertQuestionRow: View {
    let question: String
    @Binding var selection: Int?

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            Text(question)
                .font(.title3)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 14) {
                Text("1")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                ForEach(1...5, id: \.self) { value in
                    Button {
                        selection = value
                    } label: {
                        Circle()
                            .strokeBorder(.primary.opacity(0.75), lineWidth: 2.5)
                            .background(
                                Circle()
                                    .fill(selection == value ? Color.accentColor : Color.clear)
                                    .padding(8)
                            )
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Bewertung \(value)")
                }

                Text("5")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
        }
    }
}

private struct DevelopmentMenuView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    let startUserTest: () -> Void
    @State private var isImportingProbeDataset = false
    @State private var isSettingsExpanded = false

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(AppModel.ImmersiveScene.allCases) { scene in
                    Button {
                        appModel.selectedImmersiveScene = scene
                    } label: {
                        Text(scene.title)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(appModel.selectedImmersiveScene == scene ? .accentColor : .gray)
                }
            }

            Button("Probe komplett aktualisieren") {
                appModel.environmentProbeReader.refreshEnvironmentProbeAnalysis(appModel: appModel)
            }
            .buttonStyle(.bordered)
            .disabled(!appModel.canRefreshEnvironmentProbePreview)

            DisclosureGroup("Einstellungen", isExpanded: $isSettingsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    CompactToggle("Grounding Shadows", isOn: $appModel.areGroundingShadowsEnabled)
                    CompactToggle("Estimated Lights", isOn: $appModel.isEstimatedEnvironmentLightRenderingEnabled)
                    CompactToggle("Real-World Occlusion", isOn: $appModel.isRealWorldOcclusionEnabled)
                    CompactToggle("Environment Light", isOn: $appModel.isEnvironmentLightingEnabled)
                    CompactToggle("Custom IBL", isOn: $appModel.isCustomImageBasedLightEnabled)
                    CompactToggle("Scene Reconstruction", isOn: $appModel.isSceneReconstructionVisualizationEnabled)
                    CompactToggle("Plane Classification", isOn: $appModel.isPlaneClassificationVisualizationEnabled)
                    CompactToggle("Probe Faces", isOn: $appModel.isProbeFaceDebugEnabled)
                    CompactToggle("Probe Debug Spheres", isOn: $appModel.areLightProbeDebugSpheresVisible)
                    CompactToggle("Stable-ID Farben", isOn: $appModel.usesStableIDDebugColors)
                    CompactToggle("Zeitliche Stabilisierung", isOn: temporalLightStabilizationBinding)
                    CompactToggle("10s Licht-Freeze", isOn: estimatedLightWarmupFreezeBinding)
                }
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: 4) {
                Text("Environment Probe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(appModel.environmentProbeSessionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(appModel.hasEnvironmentProbeTexture ? "Texture: vorhanden" : "Texture: nicht vorhanden")
                    .font(.caption.monospaced())
                    .foregroundStyle(appModel.hasEnvironmentProbeTexture ? .green : .orange)
                if let averageLuminance = appModel.environmentProbeAverageLuminance {
                    Text("Avg luminance: \(averageLuminance, format: .number.precision(.fractionLength(4)))")
                        .font(.headline.monospacedDigit())
                } else {
                    Text("Avg luminance: noch nicht berechnet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Text(appModel.environmentProbeLuminanceStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(appModel.isUsingRecordedEnvironmentProbe ? "Quelle: Recorded Dataset" : "Quelle: Live Probe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Dataset speichern") {
                    appModel.environmentProbeReader.saveCurrentDataset(appModel: appModel)
                }
                .buttonStyle(.bordered)
                .disabled(appModel.environmentProbeUpdateCount == 0)

                Button("Letztes Dataset laden") {
                    appModel.environmentProbeReader.loadLatestRecordedDataset(appModel: appModel)
                }
                .buttonStyle(.bordered)

                Button("Dataset importieren") {
                    isImportingProbeDataset = true
                }
                .buttonStyle(.bordered)
            }

            #if targetEnvironment(simulator)
            Button("Simulator: Downloads/ProbeImport laden") {
                appModel.environmentProbeReader.importDatasetFromSimulatorDownloads(appModel: appModel)
            }
            .buttonStyle(.borderedProminent)
            #endif

            Text(appModel.environmentProbeDatasetStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !appModel.environmentProbeLatestDatasetFileURLs.isEmpty {
                ShareLink(
                    items: appModel.environmentProbeLatestDatasetFileURLs,
                    subject: Text("Environment Probe Dataset"),
                    message: Text("Gespeichertes Environment-Probe-Dataset")
                ) {
                    Text("Dataset teilen")
                }
                .buttonStyle(.borderedProminent)
            }

            Button {
                openWindow(id: AppModel.environmentProbeWindowID)
            } label: {
                Text("Probe-Fenster")
            }
            .buttonStyle(.borderedProminent)

            Button {
                openWindow(id: AppModel.environmentProbeMaskWindowID)
            } label: {
                Text("Masken-Fenster")
            }
            .buttonStyle(.bordered)

            Button {
                openWindow(id: AppModel.deviceAnchorWindowID)
            } label: {
                Text("Device-Anchor-Fenster")
            }
            .buttonStyle(.bordered)

            Button {
                openWindow(id: AppModel.lightTuningWindowID)
            } label: {
                Text("Licht-Menü")
            }
            .buttonStyle(.bordered)

            Button {
                openWindow(id: AppModel.temporalStabilityWindowID)
            } label: {
                Text("Zeitliche Stabilisierung")
            }
            .buttonStyle(.bordered)

            Button {
                openWindow(id: AppModel.technicalTestsWindowID)
            } label: {
                Text("Technische Tests")
            }
            .buttonStyle(.bordered)

            Button("User Test") {
                startUserTest()
            }
            .buttonStyle(.borderedProminent)
            .disabled(appModel.immersiveSpaceState == .inTransition)

            ToggleImmersiveSpaceButton()
        }
        .frame(width: 660, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .fileImporter(
            isPresented: $isImportingProbeDataset,
            allowedContentTypes: [.folder, .json, .data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                guard !urls.isEmpty else { return }
                if urls.count == 1, let url = urls.first, url.hasDirectoryPath {
                    appModel.environmentProbeImportDatasetURL = url
                    appModel.environmentProbeReader.importDataset(appModel: appModel, from: url)
                } else {
                    appModel.environmentProbeReader.importDatasetFiles(appModel: appModel, from: urls)
                }
            case .failure(let error):
                appModel.environmentProbeDatasetStatus = "Dataset-Import abgebrochen: \(error.localizedDescription)"
            }
        }
        .onChange(of: appModel.isSceneReconstructionVisualizationEnabled) { _, isEnabled in
            if isEnabled {
                appModel.isPlaneClassificationVisualizationEnabled = false
            }
        }
        .onChange(of: appModel.isPlaneClassificationVisualizationEnabled) { _, isEnabled in
            if isEnabled {
                appModel.isSceneReconstructionVisualizationEnabled = false
            }
        }
    }

    private var temporalLightStabilizationBinding: Binding<Bool> {
        Binding(
            get: { appModel.isTemporalLightStabilizationEnabled },
            set: { appModel.setTemporalLightStabilizationEnabled($0) }
        )
    }

    private var estimatedLightWarmupFreezeBinding: Binding<Bool> {
        Binding(
            get: { appModel.freezesEstimatedLightAfterWarmup },
            set: { appModel.setEstimatedLightWarmupFreezeEnabled($0) }
        )
    }

}

private struct CompactToggle: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
        }
    }

}

#Preview(windowStyle: .volumetric) {
    ContentView()
        .environment(AppModel())
}
