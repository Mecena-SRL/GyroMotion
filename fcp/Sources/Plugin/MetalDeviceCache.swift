// SPDX-License-Identifier: GPL-3.0-or-later
// One Metal device and command queue per GPU Final Cut renders on, and the effect's working buffers.
import Foundation
import Metal

final class MetalDeviceCache {
    static let shared = MetalDeviceCache()
    private let lock = NSLock()
    private var queues: [UInt64: MTLCommandQueue] = [:]

    func device(_ registryID: UInt64) -> MTLDevice? {
        MTLCopyAllDevices().first { $0.registryID == registryID }
    }

    /// The queue of the GPU: Gyroflow keeps its Metal state by the queue, so it's always the same one
    func queue(_ registryID: UInt64) -> MTLCommandQueue? {
        lock.lock(); defer { lock.unlock() }
        if let q = queues[registryID] { return q }
        guard let q = device(registryID)?.makeCommandQueue() else { return nil }
        q.label = "Mecena Motion"
        queues[registryID] = q
        return q
    }
}
