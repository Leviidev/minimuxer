//
//  NetworkObserver.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Network
import Foundation

public final class NetworkObserver {

    public static let shared = NetworkObserver()   // keep alive

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "net.monitor")

    private var started = false
    private let lock = NSLock()

    @discardableResult
    public func start() -> Bool {
        lock.withLock{
            guard !started else {
                verboseLog("[minimuxer] [net] monitor already started")
                return false
            }

            monitor.pathUpdateHandler = { [weak self] path in
                verboseLog("[minimuxer] [net] path changed, status: \(path.status)")
                guard path.status == .satisfied else { return }
                self?.refreshEndpoint()
            }

            monitor.start(queue: queue)
            started = true
            verboseLog("[minimuxer] [net] monitor started")
            return true
        }
    }
    
    public func refreshEndpoint() {
        verboseLog("[minimuxer] [net] refreshing interfaces list and peers")
        IfaceScanner.shared.refresh()

        verboseLog("[minimuxer] [net] retrive the first vpn interface info")
        if let info = try? IfaceScanner.shared.probableVPN() {
            verboseLog("[minimuxer] [net] vpn: \(info) peer: \(info.peerIP ?? "nil")")

            if let peer = info.peerIP {
                verboseLog("[minimuxer] [net] update the device endpoint with discovered peer on the vpn interface")
                DeviceEndpoint.shared.update(peer)
                Muxer.notifyDeviceAttached(deviceIP: peer)
                if !Muxer.isrppairing {
                    Task { 
                        await Heartbeat.start()
                    }
                }
            } else {
                verboseLog("[minimuxer] [net] peer not available for \(info.name)")
                DeviceEndpoint.shared.clear()
                Muxer.notifyDeviceDetached()
                if !Muxer.isrppairing {
                    Task { 
                        await Heartbeat.stop()
                    }
                }
            }
        } else {
            verboseLog("[minimuxer] [net] no SideVPN endpoint detected")
            DeviceEndpoint.shared.clear()
            Muxer.notifyDeviceDetached()
            if !Muxer.isrppairing {
                Task {
                    await Heartbeat.stop()
                }
            }
        }
    }
    
    @discardableResult
    public func stop() -> Bool {
        lock.withLock{
            if !started {
                verboseLog("[minimuxer] [net] monitor already stopped")
                return false
            }
            monitor.cancel()
            started = false
            verboseLog("[minimuxer] [net] monitor stopped")
            return true
        }
    }
    
    var isWifiSatisfied: Bool {
        let path = monitor.currentPath
        return path.status == .satisfied && path.usesInterfaceType(.wifi)
    }
    
    var isWiredSatisfied: Bool {
        let path = monitor.currentPath
        return path.status == .satisfied && path.usesInterfaceType(.wiredEthernet)
    }
    
    var isBridgeSatisfied: Bool {
        let path = monitor.currentPath
        if path.status == .satisfied && path.usesInterfaceType(.other) {
            return true
        }
        return IfaceScanner.shared.interfaces.contains { info in
            info.name.lowercased().contains("bridge") || info.name.lowercased().contains("ap")
        }
    }
}
