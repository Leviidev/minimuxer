//
//  Heartbeat.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation
import RustBridge

public class Heartbeat {
    public static var lastBeatSuccessful = false
    private static var running = false      // "should keep going" signal
    private static var threadAlive = false   // true while a thread is actually executing
    private static let lock = NSLock()

    /// Start the heartbeat loop. Safe to call multiple times — ignored if a thread is already alive.
    public static func start() {
        lock.lock()
        guard !threadAlive else {
            // A thread is still running — just make sure it keeps going
            running = true
            lock.unlock()
            return
        }
        running = true
        threadAlive = true
        lock.unlock()

        verboseLog("[minimuxer] Starting heartbeat thread...")
        Task.detached(priority: .userInitiated) {
            defer {
                lock.withLock{
                    threadAlive = false
                    running = false
                }
                lastBeatSuccessful = false
                verboseLog("[minimuxer] heartbeat-thread: stopped")
            }

            verboseLog("[minimuxer] heartbeat-thread: started")

            while !Muxer.usbmuxdReady {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let ts = ISO8601DateFormatter().string(from: Date())
                verboseLog("[\(ts)] [minimuxer] heartbeat-thread: Waiting for usbmuxd to be ready...")
            }
            verboseLog("[minimuxer] heartbeat-thread: usbmuxd is ready")

            // outer loop
            while running {
                let deviceIP: String
                do {
                    deviceIP = try DeviceEndpoint.shared.ip()
                } catch {
                    verboseLog("[minimuxer] heartbeat-thread: deviceIP unavailable")
                    lastBeatSuccessful = false
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                
                // verify tunnel/device reachability first
                if !Minimuxer.testDeviceConnection(ifaddr: deviceIP) {
                    verboseLog("[minimuxer] heartbeat-thread: device IP not reachable, waiting...")
                    lastBeatSuccessful = false
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                verboseLog("[minimuxer] heartbeat-thread: device IP reachable at: \(deviceIP)")

                let device: Device
                do {
                    device = try Device.getFirstDevice()
                } catch {
                    debugLog("[minimuxer] heartbeat-thread: WARN: Could not query device from usbmuxd for heartbeat")
                    lastBeatSuccessful = false
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }

                // Check lockdown first — heartbeat wraps InvalidConf as UnknownError
                switch RustLockdown.connect(device: device.internalInstance, label: "minimuxer") {
                    case .success: break
                    case .error(let err):
                        if err.contains("InvalidConf") {
                            debugLog("[minimuxer] heartbeat-thread: ERROR: Invalid pairing file — the device rejected the SSL handshake. Please redo-pairing for your device.")
                            verboseLog("[minimuxer] heartbeat-thread: exiting due to invalid pairing")
                            await Minimuxer.checkAndNotify(.failed(.heartbeat, MinimuxerError.PairingFile))
                            lastBeatSuccessful = false
                            lock.lock()
                            running = false
                            lock.unlock()
                            return
                        } else {
                            debugLog("[minimuxer] heartbeat-thread: WARN: Could not connect to lockdown for heartbeat: \(err)")
                        }
                        lastBeatSuccessful = false
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        continue
                }

                let heartbeat: RustHeartbeat
                switch RustHeartbeat.connect(device: device.internalInstance, label: "minimuxer") {
                    case .success(let hb): heartbeat = hb
                    case .error(let err):
                        debugLog("[minimuxer] heartbeat-thread: ERROR: Failed to create heartbeat client: \(err)")
                        lastBeatSuccessful = false
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        continue
                }

                // Inner loop: keep receiving and sending heartbeats
                while running {
                   guard let plist = heartbeat.receive(timeoutMs: MuxerConstants.heartbeatTimeoutMs) else {
                       debugLog("[minimuxer] heartbeat-thread: ERROR: Heartbeat recv failed")
                       lastBeatSuccessful = false
                       break
                   }

                    if heartbeat.send(plistXml: plist) {
                        lastBeatSuccessful = true
                        await Minimuxer.checkAndNotify(.ready(.heartbeat))
                    } else {
                        debugLog("[minimuxer] heartbeat-thread: ERROR: Heartbeat send failed")
                        lastBeatSuccessful = false
                        break
                    }
                }
            }
        }
    }

    /// Signal the heartbeat thread to stop. The thread will exit on next iteration.
    public static func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        running = false
        lastBeatSuccessful = false
        verboseLog("[minimuxer] Heartbeat stop requested")
    }
}
