//
//  MTLCommandBuffer+Async.swift
//  AR-Lighting-Study
//

//  Adds an async waiting helper to Metal command buffers.
//  It lets the GPU analysis code await completion without blocking the main actor.
import Dispatch
import Metal

extension MTLCommandBuffer {
    func waitUntilCompletedAsync() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                self.waitUntilCompleted()
                continuation.resume()
            }
        }
    }
}
