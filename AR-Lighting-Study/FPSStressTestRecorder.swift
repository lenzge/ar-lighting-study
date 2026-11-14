//
//  FPSStressTestRecorder.swift
//  AR-Lighting-Study
//

//  Records RealityKit frame intervals while a configured lighting stress scenario is active.
//  It writes raw samples and summary statistics as CSV files.
import Foundation

final class FPSStressTestRecorder: @unchecked Sendable {
    struct CompletedSession {
        let folderURL: URL
        let fileURLs: [URL]
        let intervalCount: Int
        let actualDurationSeconds: Double
        let averageFPS: Double?
        let medianFrameTimeMilliseconds: Double?
        let p95FrameTimeMilliseconds: Double?
    }

    struct StoredSession {
        let folderURL: URL
        let fileURLs: [URL]
    }

    private struct FrameSample {
        let index: Int
        let elapsedSeconds: Double
        let frameTimeMilliseconds: Double
    }

    private struct Configuration {
        let scenario: PerformanceStressScenario
        let configuredWarmupSeconds: Int
        let configuredMeasurementSeconds: Int
        let activeDirectionalLightCount: Int
        let activeDynamicShadowCount: Int
    }

    private let lock = NSLock()
    private var configuration: Configuration?
    private var measurementStartedAt: Date?
    private var firstFrameTimestamp: TimeInterval?
    private var previousFrameTimestamp: TimeInterval?
    private var samples: [FrameSample] = []
    private var isMeasuring = false

    func prepare(
        scenario: PerformanceStressScenario,
        warmupSeconds: Int,
        measurementSeconds: Int,
        activeDirectionalLightCount: Int,
        activeDynamicShadowCount: Int
    ) {
        lock.lock()
        defer { lock.unlock() }

        configuration = Configuration(
            scenario: scenario,
            configuredWarmupSeconds: warmupSeconds,
            configuredMeasurementSeconds: measurementSeconds,
            activeDirectionalLightCount: activeDirectionalLightCount,
            activeDynamicShadowCount: activeDynamicShadowCount
        )
        measurementStartedAt = nil
        firstFrameTimestamp = nil
        previousFrameTimestamp = nil
        samples = []
        isMeasuring = false
    }

    func beginMeasurement() {
        lock.lock()
        defer { lock.unlock() }

        guard configuration != nil else { return }
        measurementStartedAt = .now
        firstFrameTimestamp = nil
        previousFrameTimestamp = nil
        samples = []
        isMeasuring = true
    }

    func recordFrame(at timestamp: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }

        guard isMeasuring else { return }

        if firstFrameTimestamp == nil {
            firstFrameTimestamp = timestamp
        }

        defer { previousFrameTimestamp = timestamp }
        guard let previousFrameTimestamp else { return }

        let frameTimeSeconds = timestamp - previousFrameTimestamp
        guard frameTimeSeconds > 0, frameTimeSeconds.isFinite else { return }
        let elapsedSeconds = timestamp - (firstFrameTimestamp ?? timestamp)
        samples.append(
            FrameSample(
                index: samples.count + 1,
                elapsedSeconds: max(0, elapsedSeconds),
                frameTimeMilliseconds: frameTimeSeconds * 1000
            )
        )
    }

    func cancelWithoutExport() {
        lock.lock()
        defer { lock.unlock() }

        configuration = nil
        measurementStartedAt = nil
        firstFrameTimestamp = nil
        previousFrameTimestamp = nil
        samples = []
        isMeasuring = false
    }

    func finish(wasCancelled: Bool) throws -> CompletedSession? {
        let snapshot: (Configuration, Date?, [FrameSample])?

        lock.lock()
        if let configuration {
            snapshot = (configuration, measurementStartedAt, samples)
        } else {
            snapshot = nil
        }
        self.configuration = nil
        measurementStartedAt = nil
        firstFrameTimestamp = nil
        previousFrameTimestamp = nil
        samples = []
        isMeasuring = false
        lock.unlock()

        guard let (configuration, measurementStartedAt, samples) = snapshot else {
            return nil
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

        let folderURL = rootURL.appending(
            path: "test-4-fps-\(Self.filenameTimestampFormatter.string(from: .now))-\(configuration.scenario.filenameComponent)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let frameTimesURL = folderURL.appending(path: "frame-times.csv")
        let summaryURL = folderURL.appending(path: "summary.csv")
        let infoURL = folderURL.appending(path: "test-info.txt")

        let frameTimes = samples.map(\.frameTimeMilliseconds)
        let actualDurationSeconds = frameTimes.reduce(0, +) / 1000
        let averageFPS = actualDurationSeconds > 0
            ? Double(frameTimes.count) / actualDurationSeconds
            : nil
        let medianFrameTime = Self.percentile(frameTimes, percentile: 0.5)
        let p95FrameTime = Self.percentile(frameTimes, percentile: 0.95)
        let p99FrameTime = Self.percentile(frameTimes, percentile: 0.99)
        let over90FPSBudgetCount = frameTimes.filter { $0 > (1000.0 / 90.0) }.count
        let over60FPSBudgetCount = frameTimes.filter { $0 > (1000.0 / 60.0) }.count

        try Self.frameTimesCSV(
            samples: samples,
            scenario: configuration.scenario
        ).write(to: frameTimesURL, atomically: true, encoding: .utf8)
        try Self.summaryCSV(
            configuration: configuration,
            samples: samples,
            actualDurationSeconds: actualDurationSeconds,
            averageFPS: averageFPS,
            medianFrameTime: medianFrameTime,
            p95FrameTime: p95FrameTime,
            p99FrameTime: p99FrameTime,
            over90FPSBudgetCount: over90FPSBudgetCount,
            over60FPSBudgetCount: over60FPSBudgetCount,
            wasCancelled: wasCancelled
        ).write(to: summaryURL, atomically: true, encoding: .utf8)
        try Self.infoText(
            configuration: configuration,
            measurementStartedAt: measurementStartedAt,
            finishedAt: .now,
            wasCancelled: wasCancelled
        ).write(to: infoURL, atomically: true, encoding: .utf8)

        return CompletedSession(
            folderURL: folderURL,
            fileURLs: [frameTimesURL, summaryURL, infoURL],
            intervalCount: samples.count,
            actualDurationSeconds: actualDurationSeconds,
            averageFPS: averageFPS,
            medianFrameTimeMilliseconds: medianFrameTime,
            p95FrameTimeMilliseconds: p95FrameTime
        )
    }

    static func latestSession() throws -> StoredSession? {
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

        let folders = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix("test-4-fps-") }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }

        guard let folderURL = folders.first else { return nil }
        let fileURLs = ["frame-times.csv", "summary.csv", "test-info.txt"]
            .map { folderURL.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        return StoredSession(folderURL: folderURL, fileURLs: fileURLs)
    }

    private static func frameTimesCSV(
        samples: [FrameSample],
        scenario: PerformanceStressScenario
    ) -> String {
        let header = "scenario,frame_interval_index,elapsed_seconds,frame_time_ms,instantaneous_fps"
        let rows = samples.map { sample in
            let instantaneousFPS = 1000 / sample.frameTimeMilliseconds
            return [
                scenario.rawValue,
                String(sample.index),
                decimal(sample.elapsedSeconds, digits: 6),
                decimal(sample.frameTimeMilliseconds, digits: 6),
                decimal(instantaneousFPS, digits: 4)
            ].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    private static func summaryCSV(
        configuration: Configuration,
        samples: [FrameSample],
        actualDurationSeconds: Double,
        averageFPS: Double?,
        medianFrameTime: Double?,
        p95FrameTime: Double?,
        p99FrameTime: Double?,
        over90FPSBudgetCount: Int,
        over60FPSBudgetCount: Int,
        wasCancelled: Bool
    ) -> String {
        let intervalCount = samples.count
        let over90Percent = intervalCount > 0
            ? Double(over90FPSBudgetCount) / Double(intervalCount) * 100
            : nil
        let over60Percent = intervalCount > 0
            ? Double(over60FPSBudgetCount) / Double(intervalCount) * 100
            : nil
        let frameTimes = samples.map(\.frameTimeMilliseconds)

        return [
            "metric,value,unit",
            "scenario,\(configuration.scenario.rawValue),",
            "completed,\(wasCancelled ? "false" : "true"),",
            "configured_warmup_duration,\(configuration.configuredWarmupSeconds),s",
            "configured_measurement_duration,\(configuration.configuredMeasurementSeconds),s",
            "actual_measurement_duration,\(decimal(actualDurationSeconds, digits: 6)),s",
            "frame_interval_count,\(intervalCount),count",
            "estimated_frame_count,\(intervalCount > 0 ? intervalCount + 1 : 0),count",
            "average_fps,\(averageFPS.map { decimal($0, digits: 4) } ?? ""),fps",
            "frame_time_mean,\(mean(frameTimes).map { decimal($0, digits: 6) } ?? ""),ms",
            "frame_time_median,\(medianFrameTime.map { decimal($0, digits: 6) } ?? ""),ms",
            "frame_time_min,\(frameTimes.min().map { decimal($0, digits: 6) } ?? ""),ms",
            "frame_time_max,\(frameTimes.max().map { decimal($0, digits: 6) } ?? ""),ms",
            "frame_time_p95,\(p95FrameTime.map { decimal($0, digits: 6) } ?? ""),ms",
            "frame_time_p99,\(p99FrameTime.map { decimal($0, digits: 6) } ?? ""),ms",
            "frames_over_11_11_ms,\(over90FPSBudgetCount),count",
            "frames_over_11_11_ms_percent,\(over90Percent.map { decimal($0, digits: 4) } ?? ""),percent",
            "frames_over_16_67_ms,\(over60FPSBudgetCount),count",
            "frames_over_16_67_ms_percent,\(over60Percent.map { decimal($0, digits: 4) } ?? ""),percent",
            "active_directional_lights,\(configuration.activeDirectionalLightCount),count",
            "active_dynamic_shadows,\(configuration.activeDynamicShadowCount),count",
            "environment_lighting_enabled,true,",
            "grounding_shadows_enabled,true,"
        ].joined(separator: "\n") + "\n"
    }

    private static func infoText(
        configuration: Configuration,
        measurementStartedAt: Date?,
        finishedAt: Date,
        wasCancelled: Bool
    ) -> String {
        """
        test=test_4_fps_stress
        measurement_kind=realitykit_scene_update_rate
        scenario=\(configuration.scenario.rawValue)
        scenario_title=\(configuration.scenario.title)
        started_at=\(measurementStartedAt.map(isoTimestampString) ?? "")
        finished_at=\(isoTimestampString(finishedAt))
        completed=\(wasCancelled ? "false" : "true")
        configured_warmup_seconds=\(configuration.configuredWarmupSeconds)
        configured_measurement_seconds=\(configuration.configuredMeasurementSeconds)
        active_directional_lights=\(configuration.activeDirectionalLightCount)
        active_dynamic_shadows=\(configuration.activeDynamicShadowCount)
        environment_lighting_enabled=true
        grounding_shadows_enabled=true
        probe_analysis_running=false
        debug_visualizations_enabled=false
        notes=SceneEvents.Update approximates RealityKit frame rate; verify a representative run with Instruments when possible.
        """
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
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

    private static func isoTimestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
