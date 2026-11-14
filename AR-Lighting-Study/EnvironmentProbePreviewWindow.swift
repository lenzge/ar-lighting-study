//
//  EnvironmentProbePreviewWindow.swift
//  AR-Lighting-Study
//
//  Shows Environment Probe previews and exposes dataset import, storage, and export actions.
//  It is the main inspection UI for a captured or recorded probe.

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct EnvironmentProbePreviewWindow: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedPreviewURL: URL?
    @State private var isImportingProbeDataset = false

    var body: some View {
        @Bindable var appModel = appModel

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Environment Probe")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Spacer()

                    Button("Probe komplett aktualisieren") {
                        appModel.environmentProbeReader.refreshEnvironmentProbeAnalysis(appModel: appModel)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !appModel.canRefreshEnvironmentProbePreview
                            || appModel.isRuntimeEvaluationRunning
                    )
                }

                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Probe-Updates: \(appModel.environmentProbeUpdateCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("Letztes Update: \(lastUpdateText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(appModel.environmentProbeDebugSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Average luminance")
                        .font(.headline)
                    Spacer()
                    if let averageLuminance = appModel.environmentProbeAverageLuminance {
                        Text(averageLuminance, format: .number.precision(.fractionLength(4)))
                            .font(.title3.monospacedDigit())
                            .fontWeight(.semibold)
                    } else {
                        Text("Noch kein Wert")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Luminanz-Status")
                        .font(.headline)

                    Text(appModel.environmentProbeLuminanceStatus)
                        .font(.callout)
                        .foregroundStyle(luminanceStatusColor)

                    Text(luminanceStatusHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button("Dataset speichern") {
                            appModel.environmentProbeReader.saveCurrentDataset(appModel: appModel)
                        }
                        .buttonStyle(.bordered)
                        .disabled(appModel.environmentProbeUpdateCount == 0)

                        Button("Letztes Dataset laden") {
                            appModel.environmentProbeReader.loadLatestRecordedDataset(appModel: appModel)
                        }
                        .buttonStyle(.borderedProminent)

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

                    if let folderURL = appModel.environmentProbeLatestDatasetFolderURL {
                        Text(folderURL.path(percentEncoded: false))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    if !appModel.environmentProbeLatestDatasetFileURLs.isEmpty {
                        ShareLink(
                            items: appModel.environmentProbeLatestDatasetFileURLs,
                            subject: Text("Environment Probe Dataset"),
                            message: Text("Gespeichertes Environment-Probe-Dataset")
                        ) {
                            Text("Dataset per AirDrop teilen")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button("Probe-Paket exportieren") {
                        appModel.environmentProbeReader.exportCurrentProbePackage(appModel: appModel)
                    }
                    .buttonStyle(.borderedProminent)

                    Text(appModel.environmentProbeExportStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let folderURL = appModel.environmentProbeLatestExportFolderURL {
                        Text(folderURL.path(percentEncoded: false))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    #if !targetEnvironment(simulator)
                    if !appModel.environmentProbeLatestExportFileURLs.isEmpty {
                        ShareLink(
                            items: appModel.environmentProbeLatestExportFileURLs,
                            subject: Text("Environment Probe Export"),
                            message: Text("Probe-Cubemap, Masken-Cubemap und Luminanzwert")
                        ) {
                            Text("Probe-Paket per AirDrop teilen")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    #endif
                }

                if !appModel.environmentProbePreviewURLs.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(appModel.environmentProbePreviewURLs, id: \.self) { url in
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
                            version: appModel.environmentProbePreviewVersion
                        )
                    }

                    ShareLink(
                        items: appModel.environmentProbePreviewURLs,
                        subject: Text("Environment Probe Preview"),
                        message: Text("Exportierte Environment-Probe-PNGs")
                    ) {
                        Text("Probe exportieren")
                    }
                } else {
                    Text("Sobald eine Environment Probe vorliegt, erscheint hier die aufgefaltete Cubemap-Vorschau.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .onChange(of: appModel.environmentProbePreviewURLs, initial: true) { _, newURLs in
            guard let firstURL = newURLs.first else {
                selectedPreviewURL = nil
                return
            }

            if selectedPreviewURL == nil || !newURLs.contains(selectedPreviewURL!) {
                selectedPreviewURL = firstURL
            }
        }
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
    }

    private func displayName(for url: URL) -> String {
        switch url.deletingPathExtension().lastPathComponent {
        case "probe-cross-raw":
            "Interpolierte Ansicht"
        case "probe-cross-raw-nearest":
            "Pixelgenaue Ansicht"
        default:
            url.deletingPathExtension()
                .lastPathComponent
                .replacingOccurrences(of: "probe-cross-", with: "")
        }
    }

    private var lastUpdateText: String {
        guard let lastProbeUpdateAt = appModel.environmentProbeLastUpdateAt else {
            return "noch nie"
        }

        return lastProbeUpdateAt.formatted(
            .relative(presentation: .named, unitsStyle: .wide)
        )
    }

    private var luminanceStatusColor: Color {
        let status = appModel.environmentProbeLuminanceStatus.lowercased()
        if status.contains("berechnet") {
            return .green
        }
        if status.contains("laeuft") {
            return .orange
        }
        if status.contains("fehlgeschlagen") || status.contains("nicht verfuegbar") {
            return .red
        }
        return .secondary
    }

    private var luminanceStatusHint: String {
        if let averageLuminance = appModel.environmentProbeAverageLuminance {
            return "Aktueller Durchschnittswert: \(averageLuminance.formatted(.number.precision(.fractionLength(4))))"
        }

        return "Hier siehst du sofort, ob der Metal-Shader schon durchgelaufen ist oder an welcher Stelle es haengt."
    }
}

struct EnvironmentProbePreviewImage: View {
    let url: URL
    let version: Int
    @State private var uiImage: UIImage?

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 720, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                ProgressView()
                    .frame(width: 240, height: 160)
            }
        }
        .task(id: "\(url.absoluteString)#\(version)") {
            uiImage = UIImage(contentsOfFile: url.path(percentEncoded: false))
        }
    }
}
