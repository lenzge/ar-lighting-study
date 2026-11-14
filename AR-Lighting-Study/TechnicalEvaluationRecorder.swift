//
//  TechnicalEvaluationRecorder.swift
//  AR-Lighting-Study
//

//  Records probe arrivals and full analysis durations during the runtime evaluation.
//  It exports samples and aggregate values as CSV and text files.
import Foundation

@MainActor
final class TechnicalEvaluationRecorder {
    struct CompletedSession {
        let folderURL: URL
        let fileURLs: [URL]
        let probeArrivalCount: Int
        let analysisCount: Int
        let durationSeconds: TimeInterval
    }

    struct StoredSession {
        let folderURL: URL
        let fileURLs: [URL]
    }

    private struct ProbeArrivalSample {
        let captureID: Int
        let timestamp: Date
        let elapsedSeconds: TimeInterval
        let interarrivalMilliseconds: Double?
    }

    private struct AnalysisSample {
        let captureID: Int
        let timestamp: Date
        let elapsedSeconds: TimeInterval
        let durationMilliseconds: Double
        let succeeded: Bool
        let lightCount: Int
        let regionCount: Int
    }

    private var folderURL: URL?
    private var probeArrivalsURL: URL?
    private var analysisTimesURL: URL?
    private var summaryURL: URL?
    private var infoURL: URL?
    private var startedAt: Date?
    private var startedAtUptime: TimeInterval?
    private var configuredDurationSeconds = 60
    private var configuredAnalysisIntervalSeconds: Double = 1
    private var previousProbeArrivalUptime: TimeInterval?
    private var probeArrivalSamples: [ProbeArrivalSample] = []
    private var analysisSamples: [AnalysisSample] = []
    private(set) var isRecording = false

    static func latestRuntimeTestSession() throws -> StoredSession? {
        guard let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        let rootURL = documentsURL.appending(
            path: "TechnicalEvaluations",
            directoryHint: .isDirectory
        )
        guard FileManager.default.fileExists(atPath: rootURL.path(percentEncoded: false)) else {
            return nil
        }

        let sessionFolders = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix("test-1-runtime-") }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }

        guard let folderURL = sessionFolders.first else { return nil }
        let expectedFilenames = [
            "probe-arrivals.csv",
            "analysis-times.csv",
            "summary.csv",
            "test-info.txt"
        ]
        let fileURLs = expectedFilenames
            .map { folderURL.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }

        return StoredSession(folderURL: folderURL, fileURLs: fileURLs)
    }

    func startRuntimeTest(
        durationSeconds: Int,
        analysisIntervalSeconds: Double
    ) throws -> URL {
        guard !isRecording else {
            throw CocoaError(.fileWriteFileExists)
        }

        guard let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        let rootURL = documentsURL.appending(
            path: "TechnicalEvaluations",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let sessionFolderURL = rootURL.appending(
            path: "test-1-runtime-\(Self.filenameTimestampFormatter.string(from: .now))",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: sessionFolderURL, withIntermediateDirectories: true)

        let newProbeArrivalsURL = sessionFolderURL.appending(path: "probe-arrivals.csv")
        let newAnalysisTimesURL = sessionFolderURL.appending(path: "analysis-times.csv")
        let newSummaryURL = sessionFolderURL.appending(path: "summary.csv")
        let newInfoURL = sessionFolderURL.appending(path: "test-info.txt")

        folderURL = sessionFolderURL
        probeArrivalsURL = newProbeArrivalsURL
        analysisTimesURL = newAnalysisTimesURL
        summaryURL = newSummaryURL
        infoURL = newInfoURL
        startedAt = .now
        startedAtUptime = ProcessInfo.processInfo.systemUptime
        configuredDurationSeconds = durationSeconds
        configuredAnalysisIntervalSeconds = analysisIntervalSeconds
        previousProbeArrivalUptime = nil
        probeArrivalSamples = []
        analysisSamples = []
        isRecording = true

        try probeArrivalsCSV().write(to: newProbeArrivalsURL, atomically: true, encoding: .utf8)
        try analysisTimesCSV().write(to: newAnalysisTimesURL, atomically: true, encoding: .utf8)
        try infoText(finishedAt: nil).write(to: newInfoURL, atomically: true, encoding: .utf8)

        return sessionFolderURL
    }

    func recordProbeArrival(captureID: Int, timestamp: Date = .now) {
        guard
            isRecording,
            let startedAtUptime,
            let probeArrivalsURL
        else {
            return
        }

        let uptime = ProcessInfo.processInfo.systemUptime
        let sample = ProbeArrivalSample(
            captureID: captureID,
            timestamp: timestamp,
            elapsedSeconds: max(0, uptime - startedAtUptime),
            interarrivalMilliseconds: previousProbeArrivalUptime.map { max(0, uptime - $0) * 1000 }
        )
        previousProbeArrivalUptime = uptime
        probeArrivalSamples.append(sample)

        do {
            try probeArrivalsCSV().write(to: probeArrivalsURL, atomically: true, encoding: .utf8)
        } catch {
            print("TechnicalEvaluationRecorder: Probe-CSV konnte nicht geschrieben werden:", error.localizedDescription)
        }
    }

    func recordAnalysis(
        captureID: Int,
        durationMilliseconds: Double,
        succeeded: Bool,
        lightCount: Int,
        regionCount: Int,
        timestamp: Date = .now
    ) {
        guard
            isRecording,
            let startedAtUptime,
            let analysisTimesURL
        else {
            return
        }

        let sample = AnalysisSample(
            captureID: captureID,
            timestamp: timestamp,
            elapsedSeconds: max(0, ProcessInfo.processInfo.systemUptime - startedAtUptime),
            durationMilliseconds: durationMilliseconds,
            succeeded: succeeded,
            lightCount: lightCount,
            regionCount: regionCount
        )
        analysisSamples.append(sample)

        do {
            try analysisTimesCSV().write(to: analysisTimesURL, atomically: true, encoding: .utf8)
        } catch {
            print("TechnicalEvaluationRecorder: Analyse-CSV konnte nicht geschrieben werden:", error.localizedDescription)
        }
    }

    func finish() throws -> CompletedSession? {
        guard
            isRecording,
            let folderURL,
            let probeArrivalsURL,
            let analysisTimesURL,
            let summaryURL,
            let infoURL,
            let startedAt
        else {
            return nil
        }

        let finishedAt = Date()
        let durationSeconds = max(0, finishedAt.timeIntervalSince(startedAt))
        isRecording = false

        try probeArrivalsCSV().write(to: probeArrivalsURL, atomically: true, encoding: .utf8)
        try analysisTimesCSV().write(to: analysisTimesURL, atomically: true, encoding: .utf8)
        try summaryCSV(actualDurationSeconds: durationSeconds)
            .write(to: summaryURL, atomically: true, encoding: .utf8)
        try infoText(finishedAt: finishedAt).write(to: infoURL, atomically: true, encoding: .utf8)

        return CompletedSession(
            folderURL: folderURL,
            fileURLs: [probeArrivalsURL, analysisTimesURL, summaryURL, infoURL],
            probeArrivalCount: probeArrivalSamples.count,
            analysisCount: analysisSamples.count,
            durationSeconds: durationSeconds
        )
    }

    private func probeArrivalsCSV() -> String {
        let header = "capture_id,timestamp,elapsed_seconds,interarrival_ms"
        let rows = probeArrivalSamples.map { sample in
            [
                String(sample.captureID),
                Self.isoTimestampFormatter.string(from: sample.timestamp),
                Self.decimal(sample.elapsedSeconds, digits: 3),
                sample.interarrivalMilliseconds.map { Self.decimal($0, digits: 3) } ?? ""
            ].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    private func analysisTimesCSV() -> String {
        let header = "capture_id,timestamp,elapsed_seconds,duration_ms,succeeded,light_count,region_count"
        let rows = analysisSamples.map { sample in
            [
                String(sample.captureID),
                Self.isoTimestampFormatter.string(from: sample.timestamp),
                Self.decimal(sample.elapsedSeconds, digits: 3),
                Self.decimal(sample.durationMilliseconds, digits: 3),
                sample.succeeded ? "true" : "false",
                String(sample.lightCount),
                String(sample.regionCount)
            ].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    private func summaryCSV(actualDurationSeconds: TimeInterval) -> String {
        let interarrivalValues = probeArrivalSamples.compactMap(\.interarrivalMilliseconds)
        let successfulAnalysisValues = analysisSamples
            .filter(\.succeeded)
            .map(\.durationMilliseconds)
        let observedProbeRate: Double?
        if
            let first = probeArrivalSamples.first,
            let last = probeArrivalSamples.last,
            probeArrivalSamples.count > 1,
            last.elapsedSeconds > first.elapsedSeconds
        {
            observedProbeRate = Double(probeArrivalSamples.count - 1)
                / (last.elapsedSeconds - first.elapsedSeconds)
        } else {
            observedProbeRate = nil
        }

        var rows = [
            "metric,value,unit",
            "actual_duration,\(Self.decimal(actualDurationSeconds, digits: 3)),s",
            "probe_arrival_count,\(probeArrivalSamples.count),count",
            "observed_probe_rate,\(observedProbeRate.map { Self.decimal($0, digits: 4) } ?? ""),Hz",
            "probe_interarrival_mean,\(Self.mean(interarrivalValues).map { Self.decimal($0, digits: 3) } ?? ""),ms",
            "probe_interarrival_median,\(Self.median(interarrivalValues).map { Self.decimal($0, digits: 3) } ?? ""),ms",
            "probe_interarrival_min,\(interarrivalValues.min().map { Self.decimal($0, digits: 3) } ?? ""),ms",
            "probe_interarrival_max,\(interarrivalValues.max().map { Self.decimal($0, digits: 3) } ?? ""),ms",
            "analysis_count,\(analysisSamples.count),count",
            "successful_analysis_count,\(successfulAnalysisValues.count),count",
            "analysis_duration_mean,\(Self.mean(successfulAnalysisValues).map { Self.decimal($0, digits: 3) } ?? ""),ms",
            "analysis_duration_median,\(Self.median(successfulAnalysisValues).map { Self.decimal($0, digits: 3) } ?? ""),ms",
            "analysis_duration_min,\(successfulAnalysisValues.min().map { Self.decimal($0, digits: 3) } ?? ""),ms",
            "analysis_duration_max,\(successfulAnalysisValues.max().map { Self.decimal($0, digits: 3) } ?? ""),ms"
        ]

        if let p95 = Self.percentile(successfulAnalysisValues, percentile: 0.95) {
            rows.append("analysis_duration_p95,\(Self.decimal(p95, digits: 3)),ms")
        } else {
            rows.append("analysis_duration_p95,,ms")
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private func infoText(finishedAt: Date?) -> String {
        let startedAtText = startedAt.map(Self.isoTimestampFormatter.string(from:)) ?? ""
        let finishedAtText = finishedAt.map(Self.isoTimestampFormatter.string(from:)) ?? ""
        return """
        test=test_1_runtime_and_probe_rate
        started_at=\(startedAtText)
        finished_at=\(finishedAtText)
        configured_duration_seconds=\(configuredDurationSeconds)
        analysis_delay_after_iteration_seconds=\(Self.decimal(configuredAnalysisIntervalSeconds, digits: 3))
        analysis_preview_exports=false
        probe_arrival_count=\(probeArrivalSamples.count)
        analysis_count=\(analysisSamples.count)
        notes=Release build on device recommended; keep scene and viewpoint static.
        """
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func median(_ values: [Double]) -> Double? {
        percentile(values, percentile: 0.5)
    }

    private static func percentile(_ values: [Double], percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let position = min(max(percentile, 0), 1) * Double(sorted.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        guard lowerIndex != upperIndex else { return sorted[lowerIndex] }
        let fraction = position - Double(lowerIndex)
        return sorted[lowerIndex] + (sorted[upperIndex] - sorted[lowerIndex]) * fraction
    }

    private static func decimal(_ value: Double, digits: Int) -> String {
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
    }

    private static let filenameTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
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
