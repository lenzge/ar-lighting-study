//
//  EnvironmentProbeMaskPreviewWindow.swift
//  AR-Lighting-Study
//
//  Shows the Bright Region mask, detected regions, and the experiment controls.
//  It provides a visual checkpoint for the current probe analysis.

import SwiftUI

struct EnvironmentProbeMaskPreviewWindow: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedPreviewURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Bright Region Mask")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Spacer()

                    Button("Probe komplett aktualisieren") {
                        appModel.environmentProbeReader.refreshEnvironmentProbeAnalysis(appModel: appModel)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!appModel.canRefreshEnvironmentProbePreview)
                }

                BrightRegionExperimentControls()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Threshold: \(appModel.brightRegionMaskLastThreshold, format: .number.precision(.fractionLength(4)))")
                        .font(.headline.monospacedDigit())

                    Text("Apple cameraScaleReference: \(appModel.environmentProbeCameraScaleReference, format: .number.precision(.fractionLength(4)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Text(appModel.brightRegionMaskStatus)
                        .font(.callout)
                        .foregroundStyle(maskStatusColor)

                    Text(appModel.brightRegionMaskDebugSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Dominante Lichtquelle")
                        .font(.headline)

                    Text(appModel.brightRegionEstimatedLightDebugLine)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)

                    Text(appModel.brightRegionEstimatedLightPositionDebugLine)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary)

                    Text(appModel.brightRegionEstimatedLightTotalIntensityDebugLine)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Gefundene Regionen")
                        .font(.headline)

                    if appModel.brightRegionRegionDebugLines.isEmpty {
                        Text("Noch keine Regionen berechnet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appModel.brightRegionRegionDebugLines, id: \.self) { line in
                            Text(line)
                                .font(.caption.monospaced())
                        }
                    }
                }

                if !appModel.brightRegionMaskPreviewURLs.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(appModel.brightRegionMaskPreviewURLs, id: \.self) { url in
                                Button {
                                    selectedPreviewURL = url
                                } label: {
                                    Text(displayName(for: url))
                                        .font(.caption)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(selectedPreviewURL == url ? .accentColor : .gray)
                            }
                        }
                    }

                    if let selectedPreviewURL {
                        EnvironmentProbePreviewImage(
                            url: selectedPreviewURL,
                            version: appModel.brightRegionMaskPreviewVersion
                        )
                    }

                    ShareLink(
                        items: appModel.brightRegionMaskPreviewURLs,
                        subject: Text("Bright Region Mask Preview"),
                        message: Text("Exportierte Bright-Region-Masken")
                    ) {
                        Text("Maske exportieren")
                    }
                } else {
                    Text("Sobald eine Probe ausgewertet wurde, erscheint hier die aufgefaltete Cubemap-Maske.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .onChange(of: appModel.brightRegionMaskPreviewURLs, initial: true) { _, newURLs in
            guard let firstURL = newURLs.first else {
                selectedPreviewURL = nil
                return
            }

            if selectedPreviewURL == nil || !newURLs.contains(selectedPreviewURL!) {
                selectedPreviewURL = firstURL
            }
        }
    }

    private func displayName(for url: URL) -> String {
        url.deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "mask-cross-", with: "")
    }

    private var maskStatusColor: Color {
        let status = appModel.brightRegionMaskStatus.lowercased()
        if status.contains("berechnet") {
            return .green
        }
        if status.contains("laeuft") {
            return .orange
        }
        if status.contains("fehlgeschlagen") {
            return .red
        }
        return .secondary
    }
}
