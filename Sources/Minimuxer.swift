//
//  Minimuxer.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation
import RustBridge
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum MinimuxerComponent: String {
    case heartbeat
    case mounter
}

public struct MinimuxerBackgroundError: Error, CustomStringConvertible {
    public let component: MinimuxerComponent
    public let error: Error
    
    public var description: String {
        return "[\(component.rawValue)] \(error.localizedDescription)"
    }
}

public enum RestartStatus {
    case ready(MinimuxerComponent)
    case failed(MinimuxerComponent, Error)
}

public struct Minimuxer {
    public static func describeError(_ error: MinimuxerError) -> String {
        return error.description
    }
    
    public static func bindTunnelConfig(_ binding: TunnelConfigBinding) {
        IfaceScanner.shared.bindTunnelConfig(binding)
    }
    
    public static func ready() -> Bool {
        
        let deviceIP: String
        do {
            if Muxer.isrppairing {
                deviceIP = "10.7.0.1"
            } else {
                deviceIP = try DeviceEndpoint.shared.ip()
            }

        } catch {
            debugLog("[minimuxer] minimuxer not ready: device endpoint not initialized")
            return false
        }
        
        let deviceConnection = testDeviceConnection(ifaddr: deviceIP)
        if Muxer.isrppairing {
            return true
        }
        
        let deviceExists: Bool
        do {
            _ = try Device.getFirstDevice()
            deviceExists = true
        } catch {
            deviceExists = false
        }
        guard deviceConnection, deviceExists, Heartbeat.lastBeatSuccessful, Mounter.dmgMounted, Muxer.started, Muxer.usbmuxdReady else {
            verboseLog(
                "minimuxer not ready: " +
                "conn=\(deviceConnection) " +
                "dev=\(deviceExists) " +
                "hb=\(Heartbeat.lastBeatSuccessful) " +
                "dmg=\(Mounter.dmgMounted) " +
                "started=\(Muxer.started) " +
                "ready=\(Muxer.usbmuxdReady)"
            )
            return false
        }
        
        if #available(iOS 26.4, *) {
            if !IfaceScanner.shared.vpnPatched() {
                debugLog("[minimuxer] WARN: VPN subnet not patched")
            }
        }
        return true
    }

    public static var isLoggingEnabled = true

    public static func setLogging(_ enabled: Bool) {
        rustBridgeSetDebug(enabled)
        Minimuxer.isLoggingEnabled = enabled
    }

    public static func start(pairingFile: String) throws {
        try Muxer.start(pairingFile: pairingFile)
    }

    public static func retargetUsbmuxdAddr() {
        Muxer.retargetUsbmuxdAddr()
    }

    public static func fetchUDID() -> String? {
        verboseLog("[minimuxer] Getting UDID for first device")
        guard Muxer.started else {
            debugLog("[minimuxer] ERROR: minimuxer has not started!")
            return nil
        }
        let udid: String?
        if Muxer.isrppairing {
            udid = RustIdevice.fetchUDID()
        } else {
            udid = (try? Device.getFirstDevice())?.getUDID()
        }

        if let udid = udid {
            verboseLog("[minimuxer] UDID: \(udid)")
        } else {
            debugLog("[minimuxer] ERROR: Failed to get UDID")
        }
        return udid
    }

    public static func testDeviceConnection(ifaddr: String?) -> Bool {
        guard let ip = ifaddr else { return false }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Muxer.isrppairing ? MuxerConstants.rsdPort.bigEndian : MuxerConstants.lockdowndPort.bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let result = poll(&pfd, 1, 100)
        return result > 0 && (pfd.revents & Int16(POLLOUT)) != 0
    }

    public static func yeetAppAfc(bundleId: String, ipaBytes: Data) throws {
        try Install.yeetAppAfc(bundleId: bundleId, ipaBytes: ipaBytes)
    }

    public static func installIpa(bundleId: String) throws {
        try Install.installIpa(bundleId: bundleId)
    }

    public static func removeApp(bundleId: String) throws {
        try Install.removeApp(bundleId: bundleId)
    }

    public static func debugApp(appId: String) throws {
        try JIT.debugApp(appId: appId)
    }

    public static func attachDebugger(pid: UInt32) throws {
        try JIT.attachDebugger(pid: pid)
    }

    public static var onBackgroundError: ((Error) async -> Void)?
    internal static var docsPath: String?
    
    private static var continuation: CheckedContinuation<Void, Error>?
    private static let stateLock = NSLock()

    public static func startAutoMounter(docsPath: String) {
        self.docsPath = docsPath
        Mounter.startAutoMounter(docsPath: docsPath)
    }

    public static func restart() async throws {
        stateLock.lock()
        guard continuation == nil else {
            stateLock.unlock()
            verboseLog("[minimuxer] Restart already in progress, ignoring request.")
            throw MinimuxerError.RestartAlreadyInProgressError
        }
        stateLock.unlock()

        verboseLog("[minimuxer] Restarting services...")
        
        try await withCheckedThrowingContinuation { (co: CheckedContinuation<Void, Error>) in
            stateLock.lock()
            
            // 1. Reset states
            Mounter.dmgMounted = false
            Heartbeat.stop()
            
            // 2. Set the active continuation
            self.continuation = co
            stateLock.unlock()

            // 3. Restart mounter
            if let docsPath = docsPath {
                Mounter.startAutoMounter(docsPath: docsPath)
            }

            // 4. Force NetworkObserver to scan and restart heartbeat
            NetworkObserver.shared.refreshEndpoint()
        }
    }

    public static func checkAndNotify(_ status: RestartStatus) async {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        switch status {
            case .ready:
                if let co = continuation, ready() {
                    continuation = nil
                    co.resume(returning: ())
                }
            case .failed(let component, let error):
                if let co = continuation {
                    continuation = nil
                    co.resume(throwing: error)
                } else {
                    let wrappedError = MinimuxerBackgroundError(component: component, error: error)
                    await onBackgroundError?(wrappedError)
                }
        }
    }

    public static func installProvisioningProfile(profile: Data) throws {
        try Provision.installProvisioningProfile(profile: profile)
    }

    public static func removeProvisioningProfile(id: String) throws {
        try Provision.removeProvisioningProfile(id: id)
    }

    public static func dumpProfiles(docsPath: String) throws -> String {
        return try Provision.dumpProfiles(docsPath: docsPath)
    }
}

@inline(__always)
func debugLog(_ text: String) {
    print(text)
}

@inline(__always)
func verboseLog(_ text: String) {
    if Minimuxer.isLoggingEnabled {
        print(text)
    }
}
