//
//  DeviceAnchorTracker.swift
//  AR-Lighting-Study
//
//  Tracks the device pose and manages persistent ARKit world-reference anchors.
//  It publishes tracking status and reference transforms through AppModel.

import ARKit
import Foundation
import Observation
import QuartzCore
import simd

@MainActor
@Observable
final class DeviceAnchorTracker {
    private static let worldReferenceAnchorIDKey = "WorldReferenceAnchorID"
    private static let worldReferenceAnchorIDsKey = "WorldReferenceAnchorIDs"
    private static let worldReferenceRestoreGraceDuration: TimeInterval = 8

    private var session: ARKitSession?
    private var worldTrackingProvider: WorldTrackingProvider?
    private var trackingTask: Task<Void, Never>?
    private var worldAnchorUpdatesTask: Task<Void, Never>?
    private var startRequestCount = 0
    private var knownWorldReferenceAnchorIDs: Set<UUID> = []
    private var trackedWorldReferenceAnchors: [UUID: WorldAnchor] = [:]
    private var missingWorldReferenceStartedAt: Date?
    private var isSettingWorldReferenceAnchor = false
    private var isAutoWorldReferenceCreationPaused = false

    func start(appModel: AppModel) {
        startRequestCount += 1
        isAutoWorldReferenceCreationPaused = false
        guard trackingTask == nil else { return }

        appModel.deviceAnchorTrackingStatus = "Device-Anchor-Tracking startet..."
        appModel.hasDeviceAnchorPose = false

        trackingTask = Task {
            guard WorldTrackingProvider.isSupported else {
                appModel.deviceAnchorTrackingStatus = "WorldTrackingProvider wird nicht unterstuetzt."
                self.trackingTask = nil
                self.startRequestCount = 0
                return
            }

            do {
                let session = ARKitSession()
                let worldTrackingProvider = WorldTrackingProvider()
                self.session = session
                self.worldTrackingProvider = worldTrackingProvider

                let authorizationResult = await session.requestAuthorization(for: [.worldSensing])
                for (_, authorizationStatus) in authorizationResult where authorizationStatus == .denied {
                    appModel.deviceAnchorTrackingStatus = "World-Sensing-Zugriff wurde abgelehnt."
                    self.trackingTask = nil
                    self.startRequestCount = 0
                    return
                }

                let providers: [any DataProvider] = [worldTrackingProvider]
                try await session.run(providers)
                appModel.deviceAnchorTrackingStatus = "Device-Anchor-Tracking aktiv"
                restoreWorldReferenceAnchorIDs(appModel: appModel)
                observeWorldAnchorUpdates(appModel: appModel)

                while !Task.isCancelled {
                    updateDeviceAnchor(appModel: appModel)
                    updateMissingWorldReferenceAnchorStatus(appModel: appModel)
                    try? await Task.sleep(for: .seconds(1))
                }
            } catch {
                appModel.deviceAnchorTrackingStatus = "Device-Anchor-Tracking fehlgeschlagen: \(error.localizedDescription)"
                appModel.hasDeviceAnchorPose = false
                self.trackingTask = nil
                self.startRequestCount = 0
            }
        }
    }

    func stop(appModel: AppModel) {
        startRequestCount = max(0, startRequestCount - 1)
        guard startRequestCount == 0 else { return }

        trackingTask?.cancel()
        trackingTask = nil
        worldAnchorUpdatesTask?.cancel()
        worldAnchorUpdatesTask = nil
        session?.stop()
        session = nil
        worldTrackingProvider = nil
        missingWorldReferenceStartedAt = nil
        isSettingWorldReferenceAnchor = false
        isAutoWorldReferenceCreationPaused = false
        trackedWorldReferenceAnchors.removeAll()
        appModel.deviceAnchorTrackingStatus = "Device-Anchor-Tracking gestoppt"
    }

    func setWorldReferenceAnchor(appModel: AppModel) async {
        await setWorldReferenceAnchor(appModel: appModel, reason: "WorldAnchor gesetzt.")
    }

    func clearWorldReferenceAnchors(appModel: AppModel) async {
        let anchorsToRemove = Array(trackedWorldReferenceAnchors.values)
        var removedAnchorCount = 0
        var removalErrorDescription: String?

        if let worldTrackingProvider {
            for anchor in anchorsToRemove {
                do {
                    try await worldTrackingProvider.removeAnchor(anchor)
                    removedAnchorCount += 1
                } catch {
                    removalErrorDescription = error.localizedDescription
                }
            }
        }

        knownWorldReferenceAnchorIDs.removeAll()
        trackedWorldReferenceAnchors.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.worldReferenceAnchorIDKey)
        UserDefaults.standard.removeObject(forKey: Self.worldReferenceAnchorIDsKey)
        missingWorldReferenceStartedAt = nil
        isAutoWorldReferenceCreationPaused = true

        appModel.worldReferenceAnchorID = nil
        appModel.worldReferenceAnchorTransform = simd_float4x4(1)
        appModel.worldReferenceAnchorPosition = SIMD3<Float>(repeating: 0)
        appModel.worldReferenceAnchorRotationEulerDegrees = SIMD3<Float>(repeating: 0)
        appModel.hasWorldReferenceAnchorPose = false
        appModel.hasRotatedEnvironmentProbeDebugPosition = false
        updateWorldReferenceAnchorDebug(appModel: appModel)
        appModel.environmentProbeReader.refreshEnvironmentProbeAnalysis(appModel: appModel)

        if let removalErrorDescription {
            appModel.worldReferenceAnchorStatus = "WorldAnchors vergessen, aber Entfernen teilweise fehlgeschlagen: \(removalErrorDescription)"
        } else {
            appModel.worldReferenceAnchorStatus = "WorldAnchors geloescht. Entfernt: \(removedAnchorCount), gespeicherte IDs: 0."
        }
    }

    func keepOnlyActiveWorldReferenceAnchor(appModel: AppModel) async {
        guard let activeAnchorID = appModel.worldReferenceAnchorID else {
            appModel.worldReferenceAnchorStatus = "Kein aktiver WorldAnchor zum Behalten."
            return
        }

        let anchorsToRemove = trackedWorldReferenceAnchors.values.filter { $0.id != activeAnchorID }
        var removedAnchorCount = 0
        var removalErrorDescription: String?

        if let worldTrackingProvider {
            for anchor in anchorsToRemove {
                do {
                    try await worldTrackingProvider.removeAnchor(anchor)
                    removedAnchorCount += 1
                } catch {
                    removalErrorDescription = error.localizedDescription
                }
            }
        }

        knownWorldReferenceAnchorIDs = [activeAnchorID]
        trackedWorldReferenceAnchors = trackedWorldReferenceAnchors.filter { $0.key == activeAnchorID }
        saveWorldReferenceAnchorID(activeAnchorID)
        missingWorldReferenceStartedAt = nil
        isAutoWorldReferenceCreationPaused = false
        updateWorldReferenceAnchorDebug(appModel: appModel)
        appModel.environmentProbeReader.refreshEnvironmentProbeAnalysis(appModel: appModel)

        if let removalErrorDescription {
            appModel.worldReferenceAnchorStatus = "Nur aktiven WorldAnchor behalten, Entfernen teilweise fehlgeschlagen: \(removalErrorDescription)"
        } else {
            appModel.worldReferenceAnchorStatus = "Nur aktiver WorldAnchor behalten. Entfernt: \(removedAnchorCount), gespeicherte IDs: 1."
        }
    }

    func deleteActiveWorldReferenceAnchor(appModel: AppModel) async {
        guard let activeAnchorID = appModel.worldReferenceAnchorID else {
            appModel.worldReferenceAnchorStatus = "Kein aktiver WorldAnchor zum Loeschen."
            return
        }

        var removedAnchorCount = 0
        var removalErrorDescription: String?

        if
            let worldTrackingProvider,
            let activeAnchor = trackedWorldReferenceAnchors[activeAnchorID]
        {
            do {
                try await worldTrackingProvider.removeAnchor(activeAnchor)
                removedAnchorCount += 1
            } catch {
                removalErrorDescription = error.localizedDescription
            }
        }

        knownWorldReferenceAnchorIDs.remove(activeAnchorID)
        trackedWorldReferenceAnchors.removeValue(forKey: activeAnchorID)
        saveWorldReferenceAnchorIDs()
        if UserDefaults.standard.string(forKey: Self.worldReferenceAnchorIDKey) == activeAnchorID.uuidString {
            UserDefaults.standard.removeObject(forKey: Self.worldReferenceAnchorIDKey)
        }

        missingWorldReferenceStartedAt = nil
        appModel.worldReferenceAnchorID = nil
        appModel.worldReferenceAnchorTransform = simd_float4x4(1)
        appModel.worldReferenceAnchorPosition = SIMD3<Float>(repeating: 0)
        appModel.worldReferenceAnchorRotationEulerDegrees = SIMD3<Float>(repeating: 0)
        appModel.hasWorldReferenceAnchorPose = false
        appModel.hasRotatedEnvironmentProbeDebugPosition = false

        if let nextTrackedAnchor = trackedWorldReferenceAnchors.values.first {
            isAutoWorldReferenceCreationPaused = false
            saveWorldReferenceAnchorID(nextTrackedAnchor.id)
            applyWorldReferenceAnchor(nextTrackedAnchor, appModel: appModel)
        } else {
            appModel.worldReferenceAnchorID = knownWorldReferenceAnchorIDs.first
            isAutoWorldReferenceCreationPaused = knownWorldReferenceAnchorIDs.isEmpty
            updateWorldReferenceAnchorDebug(appModel: appModel)
        }

        appModel.environmentProbeReader.refreshEnvironmentProbeAnalysis(appModel: appModel)

        if let removalErrorDescription {
            appModel.worldReferenceAnchorStatus = "Aktiver WorldAnchor vergessen, aber Entfernen fehlgeschlagen: \(removalErrorDescription)"
        } else if appModel.hasWorldReferenceAnchorPose {
            appModel.worldReferenceAnchorStatus = "Aktiver WorldAnchor geloescht. Entfernt: \(removedAnchorCount), naechster Anchor aktiv."
        } else if appModel.worldReferenceAnchorID != nil {
            appModel.worldReferenceAnchorStatus = "Aktiver WorldAnchor geloescht. Entfernt: \(removedAnchorCount), suche naechsten gespeicherten Anchor."
        } else {
            appModel.worldReferenceAnchorStatus = "Aktiver WorldAnchor geloescht. Entfernt: \(removedAnchorCount), gespeicherte IDs: 0."
        }
    }

    private func setWorldReferenceAnchor(appModel: AppModel, reason: String) async {
        guard appModel.hasDeviceAnchorPose else {
            appModel.worldReferenceAnchorStatus = "WorldAnchor wartet auf eine Device-Pose."
            return
        }
        guard !isSettingWorldReferenceAnchor else { return }
        isSettingWorldReferenceAnchor = true
        defer { isSettingWorldReferenceAnchor = false }

        let anchor = WorldAnchor(originFromAnchorTransform: appModel.deviceAnchorTransform)

        do {
            guard let worldTrackingProvider else {
                appModel.worldReferenceAnchorStatus = "WorldAnchor wartet auf World-Tracking."
                return
            }

            try await worldTrackingProvider.addAnchor(anchor)
            saveWorldReferenceAnchorID(anchor.id)
            applyWorldReferenceAnchor(anchor, appModel: appModel)
            missingWorldReferenceStartedAt = nil
            isAutoWorldReferenceCreationPaused = false
            appModel.worldReferenceAnchorStatus = reason
        } catch {
            appModel.worldReferenceAnchorStatus = "WorldAnchor fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func updateDeviceAnchor(appModel: AppModel) {
        guard
            let worldTrackingProvider,
            let deviceAnchor = worldTrackingProvider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())
        else {
            appModel.deviceAnchorTrackingStatus = "DeviceAnchor noch nicht verfuegbar"
            appModel.hasDeviceAnchorPose = false
            return
        }

        let transform = deviceAnchor.originFromAnchorTransform
        let position = position(from: transform)
        let rotation = eulerDegrees(from: simd_quatf(transform))

        appModel.deviceAnchorTransform = transform
        appModel.deviceAnchorPosition = position
        appModel.deviceAnchorRotationEulerDegrees = rotation
        if !appModel.hasDeviceAnchorStartPose {
            appModel.deviceAnchorStartPosition = position
            appModel.deviceAnchorStartRotationEulerDegrees = rotation
            appModel.hasDeviceAnchorStartPose = true
        }
        appModel.deviceAnchorLastUpdateAt = .now
        appModel.deviceAnchorTrackingStatus = "Device-Anchor-Tracking aktiv"
        appModel.hasDeviceAnchorPose = true
    }

    private func observeWorldAnchorUpdates(appModel: AppModel) {
        guard
            worldAnchorUpdatesTask == nil,
            let worldTrackingProvider
        else { return }

        worldAnchorUpdatesTask = Task {
            for await update in worldTrackingProvider.anchorUpdates {
                let anchor = update.anchor
                guard knownWorldReferenceAnchorIDs.contains(anchor.id) else { continue }

                switch update.event {
                case .added, .updated:
                    guard anchor.isTracked else { continue }
                    trackedWorldReferenceAnchors[anchor.id] = anchor
                    applyWorldReferenceAnchor(anchor, appModel: appModel)
                    missingWorldReferenceStartedAt = nil
                    appModel.worldReferenceAnchorStatus = "WorldAnchor getrackt."
                case .removed:
                    trackedWorldReferenceAnchors.removeValue(forKey: anchor.id)
                    updateWorldReferenceAnchorDebug(appModel: appModel)
                    guard appModel.worldReferenceAnchorID == anchor.id else { continue }
                    appModel.hasWorldReferenceAnchorPose = false
                    appModel.worldReferenceAnchorStatus = "WorldAnchor entfernt. Suche bekannte WorldAnchor..."
                @unknown default:
                    continue
                }
            }
        }
    }

    private func applyWorldReferenceAnchor(_ anchor: WorldAnchor, appModel: AppModel) {
        let hadPose = appModel.hasWorldReferenceAnchorPose
        let activeAnchorID = appModel.worldReferenceAnchorID
        let transform = anchor.originFromAnchorTransform
        trackedWorldReferenceAnchors[anchor.id] = anchor
        appModel.worldReferenceAnchorID = anchor.id
        appModel.worldReferenceAnchorTransform = transform
        appModel.worldReferenceAnchorPosition = position(from: transform)
        appModel.worldReferenceAnchorRotationEulerDegrees = eulerDegrees(from: simd_quatf(transform))
        appModel.hasWorldReferenceAnchorPose = true
        updateWorldReferenceAnchorDebug(appModel: appModel)

        if !hadPose || activeAnchorID != anchor.id {
            appModel.environmentProbeReader.refreshEnvironmentProbeAnalysis(appModel: appModel)
        }
    }

    private func restoreWorldReferenceAnchorIDs(appModel: AppModel) {
        var restoredIDs: [UUID] = []

        if let storedIDStrings = UserDefaults.standard.stringArray(forKey: Self.worldReferenceAnchorIDsKey) {
            restoredIDs.append(contentsOf: storedIDStrings.compactMap { UUID(uuidString: $0) })
        }

        if
            let legacyStoredID = UserDefaults.standard.string(forKey: Self.worldReferenceAnchorIDKey),
            let legacyID = UUID(uuidString: legacyStoredID),
            !restoredIDs.contains(legacyID)
        {
            restoredIDs.append(legacyID)
        }

        knownWorldReferenceAnchorIDs = Set(restoredIDs)
        saveWorldReferenceAnchorIDs()
        updateWorldReferenceAnchorDebug(appModel: appModel)

        guard !restoredIDs.isEmpty else {
            appModel.worldReferenceAnchorID = nil
            appModel.hasWorldReferenceAnchorPose = false
            updateWorldReferenceAnchorDebug(appModel: appModel)
            appModel.worldReferenceAnchorStatus = "Kein gespeicherter WorldAnchor. Bitte manuell mit Jetzt setzen anlegen."
            return
        }

        appModel.worldReferenceAnchorID = restoredIDs.first
        updateWorldReferenceAnchorDebug(appModel: appModel)
        appModel.worldReferenceAnchorStatus = "Suche \(restoredIDs.count) gespeicherte WorldAnchor..."
    }

    private func saveWorldReferenceAnchorID(_ id: UUID) {
        knownWorldReferenceAnchorIDs.insert(id)
        UserDefaults.standard.set(id.uuidString, forKey: Self.worldReferenceAnchorIDKey)
        saveWorldReferenceAnchorIDs()
    }

    private func saveWorldReferenceAnchorIDs() {
        let idStrings = knownWorldReferenceAnchorIDs
            .map(\.uuidString)
            .sorted()
        UserDefaults.standard.set(idStrings, forKey: Self.worldReferenceAnchorIDsKey)
    }

    private func updateWorldReferenceAnchorDebug(appModel: AppModel) {
        appModel.worldReferenceKnownAnchorCount = knownWorldReferenceAnchorIDs.count
        appModel.worldReferenceTrackedAnchorCount = trackedWorldReferenceAnchors.count
        appModel.worldReferenceActiveAnchorDebugID = appModel.worldReferenceAnchorID
            .map { shortID($0) } ?? "none"

        let trackedIDs = trackedWorldReferenceAnchors.keys
            .map { shortID($0) }
            .sorted()
        appModel.worldReferenceTrackedAnchorDebugIDs = trackedIDs.isEmpty
            ? "none"
            : trackedIDs.joined(separator: ", ")
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private func updateMissingWorldReferenceAnchorStatus(appModel: AppModel) {
        guard appModel.hasDeviceAnchorPose else { return }
        guard !isAutoWorldReferenceCreationPaused else { return }

        if appModel.hasWorldReferenceAnchorPose {
            missingWorldReferenceStartedAt = nil
            return
        }

        let now = Date()
        if missingWorldReferenceStartedAt == nil {
            missingWorldReferenceStartedAt = now
            appModel.worldReferenceAnchorStatus = knownWorldReferenceAnchorIDs.isEmpty
                ? "Kein gespeicherter WorldAnchor. Automatische Erstellung wird vorbereitet..."
                : "Suche gespeicherten WorldAnchor..."
            return
        }

        guard
            let missingWorldReferenceStartedAt,
            now.timeIntervalSince(missingWorldReferenceStartedAt) >= Self.worldReferenceRestoreGraceDuration
        else {
            return
        }

        // Start a new anchor only after existing persistent anchors had time to
        // resolve. Keeping their IDs allows them to be used again when the user
        // returns to their original environment.
        self.missingWorldReferenceStartedAt = now
        let reason: String
        if knownWorldReferenceAnchorIDs.isEmpty {
            reason = "Kein gespeicherter WorldAnchor. WorldAnchor automatisch gesetzt."
            appModel.worldReferenceAnchorStatus = "Kein gespeicherter WorldAnchor. WorldAnchor wird automatisch gesetzt..."
        } else {
            reason = "Kein gespeicherter WorldAnchor in dieser Umgebung. WorldAnchor automatisch gesetzt."
            appModel.worldReferenceAnchorStatus = "Gespeicherter WorldAnchor nicht getrackt. Neuer WorldAnchor wird automatisch gesetzt..."
        }

        Task {
            await self.setWorldReferenceAnchor(appModel: appModel, reason: reason)
        }
    }

    private func position(from transform: simd_float4x4) -> SIMD3<Float> {
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
}
