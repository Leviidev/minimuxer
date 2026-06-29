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
    private actor MutableState {
        var continuation: CheckedContinuation<Void, Error>?
        var docsPath: String?
        
        func setDocsPath(_ path: String) {
            self.docsPath = path
        }
        
        func registerContinuation(_ co: CheckedContinuation<Void, Error>) throws {
            if continuation != nil {
                throw MinimuxerError.RestartAlreadyInProgressError
            }
            self.continuation = co
        }
        
        func consumeContinuation() -> CheckedContinuation<Void, Error>? {
            let co = continuation
            continuation = nil
            return co
        }
    }
    
    private static let state = MutableState()

    public static func describeError(_ error: MinimuxerError) -> String {
        return error.description
    }
    
    public static func bindTunnelConfig(_ binding: TunnelConfigBinding) {
        IfaceScanner.shared.bindTunnelConfig(binding)
    }
    
    public static func ready() -> Result<Bool, MinimuxerError> {
        
        let deviceIP: String
        do {
            deviceIP = try DeviceEndpoint.shared.ip()
        } catch {
            debugLog("[minimuxer] minimuxer not ready: device endpoint not initialized")
            return .failure(MinimuxerError.connectionError)
        }
        
        let deviceConnection = testDeviceConnection(ifaddr: deviceIP)
        // check if rrpairing first
        if Muxer.isrppairing {
            verboseLog(
                "minimuxer not ready: " +
                "conn=\(deviceConnection) " +
                "hb=\(Heartbeat.lastBeatSuccessful) " +
                "dmg=\(Mounter.dmgMounted) " +
                "started=\(Muxer.started) " +
                "ready=\(Muxer.usbmuxdReady)"
            )
            return deviceConnection ? .success(true) : .failure(MinimuxerError.connectionError)
        }
        
        // continue with lockdown validation
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
            return .failure(MinimuxerError.connectionError)
        }
        
        if #available(iOS 26.4, *) {
            if !IfaceScanner.shared.vpnPatched() {
                debugLog("[minimuxer] WARN: VPN subnet not patched")
            }
        }
        return .success(true)
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
        // mahee96: minimuxer ready check can be invoked by caller,
        //          and we don't enforce it here coz sometime caller can determine best timings
        //          ex: cellular based refreshing etc.
//        guard case .success(let isReady) = ready(), isReady else {
//            debugLog("[minimuxer] ERROR: minimuxer is not ready!")
//            return nil
//        }
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
    
    public static func startAutoMounter(docsPath: String) async {
        await state.setDocsPath(docsPath)
        await Mounter.startAutoMounter(docsPath: docsPath)
    }

    public static func restart() async throws {
        verboseLog("[minimuxer] Restarting services...")
        
        try await withCheckedThrowingContinuation { (co: CheckedContinuation<Void, Error>) in
            Task {
                do {
                    try await state.registerContinuation(co)
                    
                    // 1. Reset states
                    Mounter.dmgMounted = false
                    await Heartbeat.stop()
                    
                    // 2. Restart mounter
                    if let docsPath = await state.docsPath {
                        await Mounter.startAutoMounter(docsPath: docsPath)
                    }
                    
                    // 3. Force NetworkObserver to scan and restart heartbeat
                    NetworkObserver.shared.refreshEndpoint()
                } catch {
                    co.resume(throwing: error)
                }
            }
        }
    }

    public static func checkAndNotify(_ status: RestartStatus) async {
        switch status {
            case .ready:
                if case .success(let isReady) = ready(), isReady {
                    if let co = await state.consumeContinuation() {
                        co.resume(returning: ())
                    }
                }
            case .failed(let component, let error):
                if let co = await state.consumeContinuation() {
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
