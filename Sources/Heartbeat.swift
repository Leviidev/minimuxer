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

        print("[minimuxer] Starting heartbeat thread...")

        Thread.detachNewThread {
            defer {
                lock.lock()
                threadAlive = false
                running = false
                lock.unlock()
                lastBeatSuccessful = false
                print("[minimuxer] heartbeat-thread: stopped")
            }

            print("[minimuxer] heartbeat-thread: started")

            while !Muxer.usbmuxdReady {
                Thread.sleep(forTimeInterval: 1)
                let ts = ISO8601DateFormatter().string(from: Date())
                print("[\(ts)] [minimuxer] heartbeat-thread: Waiting for usbmuxd to be ready...")
            }
            print("[minimuxer] heartbeat-thread: usbmuxd is ready")

            // outer loop
            while running {
                let deviceIP: String
                do {
                    deviceIP = try DeviceEndpoint.shared.ip()
                } catch {
                    print("[minimuxer] heartbeat-thread: deviceIP unavailable")
                    lastBeatSuccessful = false
                    Thread.sleep(forTimeInterval: 1)
                    continue
                }
                
                // verify tunnel/device reachability first
                if !Minimuxer.testDeviceConnection(ifaddr: deviceIP) {
                    print("[minimuxer] heartbeat-thread: device IP not reachable, waiting...")
                    lastBeatSuccessful = false
                    Thread.sleep(forTimeInterval: 1)
                    continue
                }
                print("[minimuxer] heartbeat-thread: device IP reachable at: \(deviceIP)")

                let device: Device
                do {
                    device = try Device.getFirstDevice()
                } catch {
                    print("[minimuxer] heartbeat-thread: WARN: Could not query device from usbmuxd for heartbeat")
                    lastBeatSuccessful = false
                    Thread.sleep(forTimeInterval: 1)
                    continue
                }

                // Check lockdown first — heartbeat wraps InvalidConf as UnknownError
                switch RustLockdown.connect(device: device.internalInstance, label: "minimuxer") {
                    case .success: break
                    case .error(let err):
                        if err.contains("InvalidConf") {
                            print("[minimuxer] heartbeat-thread: ERROR: Invalid pairing file — the device rejected the SSL handshake. Please re-pair your device.")
                            print("[minimuxer] heartbeat-thread: exiting due to invalid pairing")
                            lastBeatSuccessful = false
                            lock.lock()
                            running = false
                            lock.unlock()
                            return
                        } else {
                            print("[minimuxer] heartbeat-thread: WARN: Could not connect to lockdown for heartbeat: \(err)")
                        }
                        lastBeatSuccessful = false
                        Thread.sleep(forTimeInterval: 1)
                        continue
                }

                let heartbeat: RustHeartbeat
                switch RustHeartbeat.connect(device: device.internalInstance, label: "minimuxer") {
                    case .success(let hb): heartbeat = hb
                    case .error(let err):
                        if err.contains("InvalidConf") {
                            print("[minimuxer] heartbeat-thread: ERROR: Invalid pairing file — the device rejected the SSL handshake. Please re-pair your device.")
                            print("[minimuxer] heartbeat-thread: exiting due to invalid pairing")
                            lastBeatSuccessful = false
                            lock.lock()
                            running = false
                            lock.unlock()
                            return
                        } else {
                        print("[minimuxer] heartbeat-thread: ERROR: Failed to create heartbeat client: \(err)")
                        }
                        lastBeatSuccessful = false
                        Thread.sleep(forTimeInterval: 1)
                        continue
                }

                // Inner loop: keep receiving and sending heartbeats
                while running {
                   guard let plist = heartbeat.receive(timeoutMs: MuxerConstants.heartbeatTimeoutMs) else {
                       print("[minimuxer] heartbeat-thread: ERROR: Heartbeat recv failed")
                       lastBeatSuccessful = false
                       break
                   }

                    if heartbeat.send(plistXml: plist) {
                        lastBeatSuccessful = true
                    } else {
                        print("[minimuxer] heartbeat-thread: ERROR: Heartbeat send failed")
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
        print("[minimuxer] Heartbeat stop requested")
    }
}
