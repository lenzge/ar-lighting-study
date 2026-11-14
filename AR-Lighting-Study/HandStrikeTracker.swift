//
//  HandStrikeTracker.swift
//  AR-Lighting-Study
//

//  Samples tracked hand positions and estimates their velocities through ARKit.
//  ImmersiveView uses these samples for the optional strike interaction.
import ARKit
import Foundation
import QuartzCore
import simd

@MainActor
final class HandStrikeTracker {
    struct HandSample {
        let chirality: HandAnchor.Chirality
        let position: SIMD3<Float>
        let velocity: SIMD3<Float>
    }

    private var session: ARKitSession?
    private var handTrackingProvider: HandTrackingProvider?
    private var trackingTask: Task<Void, Never>?
    private var previousPositions: [HandAnchor.Chirality: SIMD3<Float>] = [:]
    private var previousUpdateTimes: [HandAnchor.Chirality: TimeInterval] = [:]
    private(set) var handSamples: [HandSample] = []
    private(set) var status = "Hand-Strike-Tracking gestoppt"

    func start() {
        guard trackingTask == nil else { return }
        status = "Hand-Strike-Tracking startet..."

        trackingTask = Task {
            guard HandTrackingProvider.isSupported else {
                status = "HandTrackingProvider wird nicht unterstuetzt."
                trackingTask = nil
                return
            }

            do {
                let session = ARKitSession()
                let handTrackingProvider = HandTrackingProvider()
                self.session = session
                self.handTrackingProvider = handTrackingProvider

                let authorizationResult = await session.requestAuthorization(for: [.handTracking])
                for (_, authorizationStatus) in authorizationResult where authorizationStatus == .denied {
                    status = "Hand-Tracking-Zugriff wurde abgelehnt."
                    trackingTask = nil
                    return
                }

                try await session.run([handTrackingProvider])
                status = "Hand-Strike-Tracking aktiv"

                while !Task.isCancelled {
                    updateHandSamples()
                    try? await Task.sleep(for: .milliseconds(16))
                }
            } catch {
                status = "Hand-Strike-Tracking fehlgeschlagen: \(error.localizedDescription)"
                trackingTask = nil
            }
        }
    }

    func stop() {
        trackingTask?.cancel()
        trackingTask = nil
        session?.stop()
        session = nil
        handTrackingProvider = nil
        previousPositions.removeAll()
        previousUpdateTimes.removeAll()
        handSamples.removeAll()
        status = "Hand-Strike-Tracking gestoppt"
    }

    private func updateHandSamples() {
        guard let handTrackingProvider else {
            handSamples.removeAll()
            return
        }

        let timestamp = CACurrentMediaTime()
        let anchors = handTrackingProvider.latestAnchors
        handSamples = [anchors.leftHand, anchors.rightHand].compactMap { anchor in
            guard
                let anchor,
                anchor.isTracked,
                let position = strikePosition(from: anchor)
            else {
                return nil
            }

            let previousPosition = previousPositions[anchor.chirality] ?? position
            let previousUpdateTime = previousUpdateTimes[anchor.chirality] ?? timestamp
            let deltaTime = max(Float(timestamp - previousUpdateTime), 0.001)
            let velocity = (position - previousPosition) / deltaTime

            previousPositions[anchor.chirality] = position
            previousUpdateTimes[anchor.chirality] = timestamp

            return HandSample(
                chirality: anchor.chirality,
                position: position,
                velocity: velocity
            )
        }
    }

    private func strikePosition(from anchor: HandAnchor) -> SIMD3<Float>? {
        guard let handSkeleton = anchor.handSkeleton else { return nil }

        let wrist = handSkeleton.joint(.wrist)
        guard wrist.isTracked else { return nil }

        let originFromJointTransform = anchor.originFromAnchorTransform * wrist.anchorFromJointTransform
        return SIMD3<Float>(
            originFromJointTransform.columns.3.x,
            originFromJointTransform.columns.3.y,
            originFromJointTransform.columns.3.z
        )
    }
}
