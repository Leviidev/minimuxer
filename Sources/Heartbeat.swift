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
    private actor MutableState {
        var running = false
        var taskActive = false

        func tryStart() -> Bool {
            if taskActive {
                running = true
                return false
            }
            running = true
            taskActive = true
            return true
        }

        func stop() {
            running = false
        }

        func terminate() {
            taskActive = false
            running = false
        }
    }

    private static let state = MutableState()

    public static var lastBeatSuccessful = false

    /// Start the heartbeat loop. Safe to call multiple times — ignored if a task is already active.
    public static func start() async {
        guard await state.tryStart() else {
            return
        }

        verboseLog("[minimuxer] Starting heartbeat task...")
        Task.detached(priority: .userInitiated) {
            verboseLog("[minimuxer] heartbeat-task: started")

            await heartbeatLoop()

            await state.terminate()
            lastBeatSuccessful = false
            verboseLog("[minimuxer] heartbeat-task: stopped")
        }
    }

    /// Signal the heartbeat task to stop. The task will exit on next iteration.
    public static func stop() async {
        await state.stop()
        lastBeatSuccessful = false
        verboseLog("[minimuxer] Heartbeat stop requested")
    }

    private static func heartbeatLoop() async {
        while !Muxer.usbmuxdReady {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let ts = ISO8601DateFormatter().string(from: Date())
            verboseLog("[\(ts)] [minimuxer] heartbeat-task: Waiting for usbmuxd to be ready...")
        }
        verboseLog("[minimuxer] heartbeat-task: usbmuxd is ready")

        // outer loop
        while await state.running {
            let deviceIP: String
            do {
                deviceIP = try DeviceEndpoint.shared.ip()
            } catch {
                verboseLog("[minimuxer] heartbeat-task: deviceIP unavailable")
                lastBeatSuccessful = false
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            
            // verify tunnel/device reachability first
            if !Minimuxer.testDeviceConnection(ifaddr: deviceIP) {
                verboseLog("[minimuxer] heartbeat-task: device IP not reachable, waiting...")
                lastBeatSuccessful = false
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            verboseLog("[minimuxer] heartbeat-task: device IP reachable at: \(deviceIP)")

            let device: Device
            do {
                device = try Device.getFirstDevice()
            } catch {
                debugLog("[minimuxer] heartbeat-task: WARN: Could not query device from usbmuxd for heartbeat")
                lastBeatSuccessful = false
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }

            // Check lockdown first — heartbeat wraps InvalidConf as UnknownError
            switch RustLockdown.connect(device: device.internalInstance, label: "minimuxer") {
                case .success: break
                case .error(let err):
                    if err.contains("InvalidConf") {
                        debugLog("[minimuxer] heartbeat-task: ERROR: Invalid pairing file — the device rejected the SSL handshake. Please redo-pairing for your device.")
                        verboseLog("[minimuxer] heartbeat-task: exiting due to invalid pairing")
                        await Minimuxer.checkAndNotify(.failed(.heartbeat, MinimuxerError.PairingFile))
                        lastBeatSuccessful = false
                        await state.stop()
                        return
                    } else {
                        debugLog("[minimuxer] heartbeat-task: WARN: Could not connect to lockdown for heartbeat: \(err)")
                    }
                    lastBeatSuccessful = false
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
            }

            let heartbeat: RustHeartbeat
            switch RustHeartbeat.connect(device: device.internalInstance, label: "minimuxer") {
                case .success(let hb): heartbeat = hb
                case .error(let err):
                    debugLog("[minimuxer] heartbeat-task: ERROR: Failed to create heartbeat client: \(err)")
                    lastBeatSuccessful = false
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
            }

            // Inner loop: keep receiving and sending heartbeats
            while await state.running {
                guard let plist = heartbeat.receive(timeoutMs: MuxerConstants.heartbeatTimeoutMs) else {
                    debugLog("[minimuxer] heartbeat-task: ERROR: Heartbeat recv failed")
                    lastBeatSuccessful = false
                    break
                }

                if heartbeat.send(plistXml: plist) {
                    lastBeatSuccessful = true
                    await Minimuxer.checkAndNotify(.ready(.heartbeat))
                } else {
                    debugLog("[minimuxer] heartbeat-task: ERROR: Heartbeat send failed")
                    lastBeatSuccessful = false
                    break
                }
            }
        }
    }
}
