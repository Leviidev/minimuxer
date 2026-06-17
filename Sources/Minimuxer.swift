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
            deviceIP = try DeviceEndpoint.shared.ip()
        } catch {
            print("[minimuxer] minimuxer not ready: device endpoint not initialized")
            return false
        }
        
        let deviceConnection = testDeviceConnection(ifaddr: deviceIP)
        let deviceExists: Bool
        do {
            _ = try Device.getFirstDevice()
            deviceExists = true
        } catch {
            deviceExists = false
        }
        guard deviceConnection, deviceExists, Heartbeat.lastBeatSuccessful, Mounter.dmgMounted, Muxer.started, Muxer.usbmuxdReady else {
            print(
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
                print("[minimuxer] WARN: VPN subnet not patched")
            }
        }
        return true
    }

    public static func setDebug(_ debug: Bool) {
        rustBridgeSetDebug(debug)
    }

    public static func start(pairingFile: String, logPath: String) throws {
        try startWithLogger(pairingFile: pairingFile, logPath: logPath, isConsoleLoggingEnabled: true)
    }

    public static func startWithLogger(pairingFile: String, logPath: String, isConsoleLoggingEnabled: Bool) throws {
        try Muxer.start(pairingFile: pairingFile, logPath: logPath)
    }

    public static func retargetUsbmuxdAddr() {
        Muxer.retargetUsbmuxdAddr()
    }

    public static func fetchUDID() -> String? {
        print("[minimuxer] Getting UDID for first device")
        guard Muxer.started else {
            print("[minimuxer] ERROR: minimuxer has not started!")
            return nil
        }
        let udid = (try? Device.getFirstDevice())?.getUDID()
        if let udid = udid {
            print("[minimuxer] UDID: \(udid)")
        } else {
            print("[minimuxer] ERROR: Failed to get UDID")
        }
        return udid
    }

    public static func testDeviceConnection(ifaddr: String?) -> Bool {
        guard let ip = ifaddr else { return false }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = MuxerConstants.lockdowndPort.bigEndian
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
        try Jit.debugApp(appId: appId)
    }

    public static func attachDebugger(pid: UInt32) throws {
        try Jit.attachDebugger(pid: pid)
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
            print("[minimuxer] Restart already in progress, ignoring request.")
            throw MinimuxerError.RestartAlreadyInProgressError
        }
        stateLock.unlock()

        print("[minimuxer] Restarting services...")
        
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
