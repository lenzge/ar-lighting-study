//
//  ARLightingStudyApp.swift
//  AR-Lighting-Study
//
//  Configures the shared AppModel and registers every window and the Immersive Space.
//  This is the application's SwiftUI entry point.

import SwiftUI

@main
struct ARLightingStudyApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }
        .windowStyle(.volumetric)
        .windowResizability(.contentSize)
        .defaultSize(width: 720, height: 640)

        WindowGroup(id: AppModel.environmentProbeWindowID) {
            EnvironmentProbePreviewWindow()
                .environment(appModel)
        }
        .defaultSize(width: 1100, height: 900)

        WindowGroup(id: AppModel.environmentProbeMaskWindowID) {
            EnvironmentProbeMaskPreviewWindow()
                .environment(appModel)
        }
        .defaultSize(width: 1100, height: 900)

        WindowGroup(id: AppModel.deviceAnchorWindowID) {
            DeviceAnchorTrackingWindow()
                .environment(appModel)
        }
        .defaultSize(width: 560, height: 720)

        WindowGroup(id: AppModel.lightTuningWindowID) {
            EstimatedLightTuningWindow()
                .environment(appModel)
        }
        .defaultSize(width: 700, height: 900)

        WindowGroup(id: AppModel.temporalStabilityWindowID) {
            TemporalStabilityWindow()
                .environment(appModel)
        }
        .defaultSize(width: 520, height: 680)

        WindowGroup(id: AppModel.technicalTestsWindowID) {
            TechnicalTestsWindow()
                .environment(appModel)
        }
        .defaultSize(width: 620, height: 760)

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveView()
                .environment(appModel)
                .onAppear {
                    appModel.immersiveSpaceState = .open
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
