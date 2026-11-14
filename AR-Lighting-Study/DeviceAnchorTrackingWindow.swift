//
//  DeviceAnchorTrackingWindow.swift
//  AR-Lighting-Study
//
//  Displays device-pose diagnostics and controls for world-reference anchors.
//  It delegates all tracking operations to DeviceAnchorTracker.

import SwiftUI
import simd

struct DeviceAnchorTrackingWindow: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Device Anchor")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Spacer()

                    Text(appModel.hasDeviceAnchorPose ? "Live" : "Warte")
                        .font(.caption.monospaced())
                        .foregroundStyle(appModel.hasDeviceAnchorPose ? .green : .orange)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(appModel.deviceAnchorTrackingStatus)
                        .font(.callout)
                        .foregroundStyle(statusColor)

                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("Letztes Update: \(lastUpdateText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                PoseSection(
                    title: "Position",
                    values: appModel.deviceAnchorPosition,
                    unit: "m",
                    fractionLength: 1,
                    isEnabled: appModel.hasDeviceAnchorPose
                )

                PoseSection(
                    title: "Rotation Euler XYZ",
                    values: appModel.deviceAnchorRotationEulerDegrees,
                    unit: "deg",
                    fractionLength: 0,
                    isEnabled: appModel.hasDeviceAnchorPose
                )

                PoseSection(
                    title: "Startposition",
                    values: appModel.deviceAnchorStartPosition,
                    unit: "m",
                    fractionLength: 1,
                    isEnabled: appModel.hasDeviceAnchorStartPose
                )

                PoseSection(
                    title: "Startrotation Euler XYZ",
                    values: appModel.deviceAnchorStartRotationEulerDegrees,
                    unit: "deg",
                    fractionLength: 0,
                    isEnabled: appModel.hasDeviceAnchorStartPose
                )

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("WorldAnchor Referenz")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Spacer()

                        Button("Jetzt setzen") {
                            Task {
                                await appModel.deviceAnchorTracker.setWorldReferenceAnchor(appModel: appModel)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!appModel.hasDeviceAnchorPose)

                        Button("Alle loeschen", role: .destructive) {
                            Task {
                                await appModel.deviceAnchorTracker.clearWorldReferenceAnchors(appModel: appModel)
                            }
                        }
                        .buttonStyle(.bordered)

                        Button("Aktiven loeschen", role: .destructive) {
                            Task {
                                await appModel.deviceAnchorTracker.deleteActiveWorldReferenceAnchor(appModel: appModel)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(appModel.worldReferenceAnchorID == nil)

                        Button("Nur aktiven behalten") {
                            Task {
                                await appModel.deviceAnchorTracker.keepOnlyActiveWorldReferenceAnchor(appModel: appModel)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(appModel.worldReferenceAnchorID == nil || appModel.worldReferenceKnownAnchorCount <= 1)
                    }

                    Text(appModel.worldReferenceAnchorStatus)
                        .font(.caption)
                        .foregroundStyle(appModel.hasWorldReferenceAnchorPose ? .green : .secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Aktiver Anchor: \(appModel.worldReferenceActiveAnchorDebugID)")
                        Text("Bekannt/Getrackt: \(appModel.worldReferenceKnownAnchorCount) / \(appModel.worldReferenceTrackedAnchorCount)")
                        Text("Getrackte IDs: \(appModel.worldReferenceTrackedAnchorDebugIDs)")
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                }

                PoseSection(
                    title: "Position",
                    values: appModel.worldReferenceAnchorPosition,
                    unit: "m",
                    fractionLength: 1,
                    isEnabled: appModel.hasWorldReferenceAnchorPose
                )

                PoseSection(
                    title: "Rotation Euler XYZ",
                    values: appModel.worldReferenceAnchorRotationEulerDegrees,
                    unit: "deg",
                    fractionLength: 0,
                    isEnabled: appModel.hasWorldReferenceAnchorPose
                )

                RotationMatrixSection(
                    transform: appModel.worldReferenceAnchorTransform,
                    isEnabled: appModel.hasWorldReferenceAnchorPose
                )

                Divider()

                HStack {
                    Text("Environment Probe Anchor")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Spacer()

                    Text(appModel.hasEnvironmentProbeAnchorPose ? "Live" : "Warte")
                        .font(.caption.monospaced())
                        .foregroundStyle(appModel.hasEnvironmentProbeAnchorPose ? .green : .orange)
                }

                PoseSection(
                    title: "Position",
                    values: appModel.environmentProbeAnchorPosition,
                    unit: "m",
                    fractionLength: 1,
                    isEnabled: appModel.hasEnvironmentProbeAnchorPose
                )

                PoseSection(
                    title: "Rotation Euler XYZ",
                    values: appModel.environmentProbeAnchorRotationEulerDegrees,
                    unit: "deg",
                    fractionLength: 0,
                    isEnabled: appModel.hasEnvironmentProbeAnchorPose
                )

                PoseSection(
                    title: "Startposition",
                    values: appModel.environmentProbeAnchorStartPosition,
                    unit: "m",
                    fractionLength: 1,
                    isEnabled: appModel.hasEnvironmentProbeAnchorStartPose
                )

                PoseSection(
                    title: "Startrotation Euler XYZ",
                    values: appModel.environmentProbeAnchorStartRotationEulerDegrees,
                    unit: "deg",
                    fractionLength: 0,
                    isEnabled: appModel.hasEnvironmentProbeAnchorStartPose
                )

                PoseSection(
                    title: "Rotierte Debug-Sphere-Position",
                    values: appModel.rotatedEnvironmentProbeDebugPosition,
                    unit: "m",
                    fractionLength: 1,
                    isEnabled: appModel.hasRotatedEnvironmentProbeDebugPosition
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .task {
            appModel.deviceAnchorTracker.start(appModel: appModel)
        }
        .onDisappear {
            appModel.deviceAnchorTracker.stop(appModel: appModel)
        }
    }

    private var lastUpdateText: String {
        guard let lastUpdateAt = appModel.deviceAnchorLastUpdateAt else {
            return "noch kein Pose-Update"
        }

        return lastUpdateAt.formatted(date: .omitted, time: .standard)
    }

    private var statusColor: Color {
        let status = appModel.deviceAnchorTrackingStatus.lowercased()
        if status.contains("aktiv") {
            return .green
        }
        if status.contains("fehlgeschlagen") || status.contains("abgelehnt") {
            return .red
        }
        return .secondary
    }
}

private struct RotationMatrixSection: View {
    let transform: simd_float4x4
    let isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rotation Matrix 3x3")
                .font(.headline)

            Grid(horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<3, id: \.self) { column in
                            Text(value(row: row, column: column), format: .number.precision(.fractionLength(3)))
                                .font(.callout.monospacedDigit())
                                .frame(minWidth: 72, alignment: .trailing)
                        }
                    }
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func value(row: Int, column: Int) -> Float {
        transform[column][row]
    }
}

private struct PoseSection: View {
    let title: String
    let values: SIMD3<Float>
    let unit: String
    let fractionLength: Int
    let isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                axisRow("x", value: values.x)
                axisRow("y", value: values.y)
                axisRow("z", value: values.z)
            }
            .opacity(isEnabled ? 1 : 0.45)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func axisRow(_ axis: String, value: Float) -> some View {
        GridRow {
            Text(axis)
                .foregroundStyle(.secondary)
            Text(value, format: .number.precision(.fractionLength(fractionLength)))
                .font(.title3.monospacedDigit())
            Text(unit)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    DeviceAnchorTrackingWindow()
        .environment(AppModel())
}
