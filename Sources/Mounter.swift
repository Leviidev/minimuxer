//
//  Mounter.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation
import RustBridge
import ZIPFoundation


public protocol MounterProvider: AnyObject {
    var dmgMounted:Bool { get set }
    func startAutoMounter(docsPath: String);
}

public class Mounter {
    public static var provider: MounterProvider?;

    private static func getProvider() -> any MounterProvider {
        if let provider {
            return provider
        } else {
            if Muxer.isrppairing {
                provider = RPMounter()
            } else {
                provider = LockDownMounter()
            }
        }
        return provider!
    }
    public static func startAutoMounter(docsPath: String) {
        getProvider().startAutoMounter(docsPath: docsPath)
    }
    public static var dmgMounted: Bool {
        get { getProvider().dmgMounted }
        set { getProvider().dmgMounted = newValue }
    }
}

public class LockDownMounter: MounterProvider {
    public var dmgMounted = false
    private var threadAlive = false
    private let lock = NSLock()

    public func startAutoMounter(docsPath: String) {
        lock.lock()
        guard !threadAlive else {
            lock.unlock()
            return
        }
        threadAlive = true
        lock.unlock()

        let path = docsPath.hasPrefix("file://") ? String(docsPath.dropFirst(7)) : docsPath
        let dmgDocsPath = "\(path)/DMG"

        verboseLog("[minimuxer] mount-thread: Starting mount thread...")
        Task.detached(priority: .userInitiated) {
            defer {
                self.lock.withLock{
                    self.threadAlive = false
                }
                verboseLog("[minimuxer] mount-thread: stopped")
            }
            verboseLog("[minimuxer] mount-thread: started")

            while !Muxer.usbmuxdReady {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let ts = ISO8601DateFormatter().string(from: Date())
                verboseLog("[\(ts)] [minimuxer] mount-thread: Waiting for usbmuxd to be ready...")
            }
            verboseLog("[minimuxer] mount-thread: usbmuxd is ready")

            try? FileManager.default.createDirectory(atPath: dmgDocsPath, withIntermediateDirectories: true)

            while !self.dmgMounted {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                do {
                    let device = try Device.getFirstDevice()
                    let lockdown: RustLockdown
                    switch RustLockdown.connect(device: device.internalInstance, label: "minimuxer") {
                        case .success(let ld): lockdown = ld
                        case .error(let err):
                              if err.contains("InvalidConf") {
                                  debugLog("[minimuxer] mounter-thread: ERROR: Invalid pairing file — the device rejected the SSL handshake. Please redo-pairing for your device.")
                                  debugLog("[minimuxer] mounter-thread: exiting due to invalid pairing")
                                  await Minimuxer.checkAndNotify(.failed(.mounter, MinimuxerError.PairingFile))
                                  return
                          } else {
                            debugLog("[minimuxer] mount-thread: WARN: Could not connect to lockdown for mounter: \(err)")
                        }
                        continue
                    }
                    guard let versionStr = lockdown.getValue(key: "ProductVersion") else {
                        debugLog("[minimuxer] mount-thread: WARN: Could not get device version for mounter")
                        continue
                    }

                    let major = Int(versionStr.split(separator: ".").first ?? "0") ?? 0
                    if major < 17 {
                        try await self.handlePre17Mount(device: device, iosVersion: versionStr, dmgDocsPath: dmgDocsPath)
                    } else {
                        try await self.handlePost17Mount(dmgDocsPath: dmgDocsPath)
                    }
                } catch let error as MinimuxerError {
                    if error == .NoDevice {
                        continue
                    }
                    debugLog("[minimuxer] mount-thread: ERROR: Mount failed with .NoDevice error: \(error)")
                    await Minimuxer.checkAndNotify(.failed(.mounter, error))
                    return
                } catch {
                    debugLog("[minimuxer] mount-thread: ERROR: Mount failed with unknown error: \(error)")
                    await Minimuxer.checkAndNotify(.failed(.mounter, error))
                    return
                }
            }
        }
    }

    private func handlePre17Mount(device: Device, iosVersion: String, dmgDocsPath: String) async throws {
        verboseLog("[minimuxer] Starting image mounter (pre-17)")
        guard let mounter = RustMounter.connect(device: device.internalInstance, label: "sidestore-image-reeeee") else {
            debugLog("[minimuxer] ERROR: Unable to start mobile image mounter")
            throw MinimuxerError.Mount
        }

        if let lookupResult = mounter.lookup(imageType: "Developer"),
           let data = lookupResult.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let sigArray = plist["ImageSignature"] as? [Any], !sigArray.isEmpty {
             verboseLog("[minimuxer] Developer disk image already mounted")
             dmgMounted = true
             await Minimuxer.checkAndNotify(.ready(.mounter))
             return
        }

        let dmgPath = "\(dmgDocsPath)/\(iosVersion).dmg"
        let sigPath = "\(dmgPath).signature"
        
        verboseLog("[minimuxer] Pre17 DMG: \(dmgPath)")
        verboseLog("[minimuxer] Pre17 Signature: \(sigPath)")
        
        if !FileManager.default.fileExists(atPath: dmgPath) {
            verboseLog("[minimuxer] Downloading iOS \(iosVersion) DMG...")
//             try downloadPre17Image(iosVersion: iosVersion, dmgDocsPath: dmgDocsPath)
            try LockDownMounter.downloadPre17Image(iosVersion: iosVersion, dmgDocsPath: dmgDocsPath)
        }

        let dmgSize = (try? Data(contentsOf: URL(fileURLWithPath: dmgPath)).count) ?? -1
        let sigSize = (try? Data(contentsOf: URL(fileURLWithPath: sigPath)).count) ?? -1

        verboseLog("[minimuxer] Uploading image (dmg=\(dmgSize) bytes, sig=\(sigSize) bytes)...")
        guard mounter.upload(path: dmgPath, signature: sigPath, imageType: "Developer") else {
            debugLog("[minimuxer] ERROR: Unable to upload developer disk image")
            throw MinimuxerError.Mount
        }
        verboseLog("[minimuxer] Successfully uploaded the image")
        
        verboseLog("[minimuxer] Mounting developer image...")
        guard mounter.mount(path: dmgPath, signature: sigPath, imageType: "Developer") else {
            debugLog("[minimuxer] ERROR: Unable to mount developer image")
            throw MinimuxerError.Mount
        }
         verboseLog("[minimuxer] Successfully mounted the image")
         dmgMounted = true
         await Minimuxer.checkAndNotify(.ready(.mounter))
    }

    private func handlePost17Mount(dmgDocsPath: String) async throws {
        let (imageData, trustcacheData, manifestData) = try LockDownMounter.loadPost17Image(dmgDocsPath: dmgDocsPath)

         verboseLog(
             "[minimuxer] Mounting DDI " +
             "(image=\(imageData.count) bytes, " +
             "trustcache=\(trustcacheData.count) bytes, " +
             "manifest=\(manifestData.count) bytes)"
         )

        let result = rustBridgeMountPersonalizedDDI(
            image: imageData,
            trustcache: trustcacheData,
            manifest: manifestData,
            muxerAddr: MuxerConstants.usbmuxdSocket,
            deviceIp: try DeviceEndpoint.shared.ip()
        )
        if result == 0 {
            verboseLog("[minimuxer] DDI mounted successfully")
            dmgMounted = true
            await Minimuxer.checkAndNotify(.ready(.mounter))
        } else {
            debugLog("[minimuxer] ERROR: Failed to mount DDI (code \(result))")
            switch result {
                case 1: throw MinimuxerError.NoConnection
                case 4: throw MinimuxerError.CreateLockdown
                case 5: throw MinimuxerError.GetLockdownValue
                case 6: throw MinimuxerError.ImageLookup
                case 8: throw MinimuxerError.Mount
            default: throw MinimuxerError.Mount
            }
        }
    }

    static func loadPost17Image(dmgDocsPath: String) throws -> (Data, Data, Data){
        let dir = URL(fileURLWithPath: dmgDocsPath)
        let tasks: [(String, URL)] = [
            (MuxerConstants.ddiImageURL, dir.appendingPathComponent("Image.dmg")),
            (MuxerConstants.ddiTrustcacheURL, dir.appendingPathComponent("Image.dmg.trustcache")),
            (MuxerConstants.ddiManifestURL, dir.appendingPathComponent("BuildManifest.plist"))
        ]

        for (urlStr, path) in tasks {
            if !FileManager.default.fileExists(atPath: path.path) {
                verboseLog("[minimuxer] Downloading \(path.lastPathComponent)...")
                guard let url = URL(string: urlStr), let data = try? Data(contentsOf: url) else {
                    debugLog("[minimuxer] ERROR: Failed to download \(path.lastPathComponent)")
                    throw MinimuxerError.DownloadImage
                }
                try data.write(to: path)
            }
        }
        verboseLog("[minimuxer] Files downloaded, reading to memory")

         let imageURL = tasks[0].1
         let trustcacheURL = tasks[1].1
         let manifestURL = tasks[2].1

         verboseLog("[minimuxer] Image:      \(imageURL.path)")
         verboseLog("[minimuxer] Trustcache: \(trustcacheURL.path)")
         verboseLog("[minimuxer] Manifest:   \(manifestURL.path)")

         let imageData = try Data(contentsOf: imageURL)
         let trustcacheData = try Data(contentsOf: trustcacheURL)
         let manifestData = try Data(contentsOf: manifestURL)


        return (imageData, trustcacheData, manifestData)
    }

    private static func downloadPre17Image(iosVersion: String, dmgDocsPath: String) throws {
        guard let url = URL(string: MuxerConstants.pre17VersionsURL),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let dmgUrlStr = json[iosVersion],
              let dmgUrl = URL(string: dmgUrlStr) else {
            debugLog("[minimuxer] ERROR: Unable to download DMG dictionary or find version")
            throw MinimuxerError.DownloadImage
        }

        let zipData = try Data(contentsOf: dmgUrl)
        let zipPath = "\(dmgDocsPath)/dmg.zip"
        try zipData.write(to: URL(fileURLWithPath: zipPath))

        let tmpPath = "\(dmgDocsPath)/tmp"
        try? FileManager.default.removeItem(atPath: tmpPath)
        try FileManager.default.createDirectory(atPath: tmpPath, withIntermediateDirectories: true)

        let tmpPathURL = URL(fileURLWithPath: tmpPath)
        try FileManager.default.unzipItem(at: URL(fileURLWithPath: zipPath), to: tmpPathURL)
        try? FileManager.default.removeItem(atPath: zipPath)

        for item in try FileManager.default.contentsOfDirectory(atPath: tmpPath) {
            let itemPath = "\(tmpPath)/\(item)"
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDir), isDir.boolValue,
                  !item.contains("__MACOSX") else { continue }
            let dmgFile = "\(itemPath)/DeveloperDiskImage.dmg"
            let sigFile = "\(itemPath)/DeveloperDiskImage.dmg.signature"
            if FileManager.default.fileExists(atPath: dmgFile) {
                try FileManager.default.moveItem(atPath: dmgFile, toPath: "\(dmgDocsPath)/\(iosVersion).dmg")
                try FileManager.default.moveItem(atPath: sigFile, toPath: "\(dmgDocsPath)/\(iosVersion).dmg.signature")
            }
        }
        try? FileManager.default.removeItem(atPath: tmpPath)
    }
}

public class RPMounter: MounterProvider {
    public var dmgMounted: Bool = false

    public func startAutoMounter(docsPath: String) {
        let path = docsPath.hasPrefix("file://") ? String(docsPath.dropFirst(7)) : docsPath
        let dmgDocsPath = "\(path)/DMG"

        do {
            let (imageData, trustcacheData, manifestData) = try LockDownMounter.loadPost17Image(dmgDocsPath: dmgDocsPath)
            Thread.detachNewThread {
                verboseLog("[minimuxer] Starting mount thread...")

                try? FileManager.default.createDirectory(atPath: dmgDocsPath, withIntermediateDirectories: true)

                while !self.dmgMounted {
                    Thread.sleep(forTimeInterval: 1.0)
                    do {
                        try RustIdevice.mountPersonalizedDDI(image: imageData, trustcache: trustcacheData, manifest: manifestData)
                        verboseLog("[minimuxer] DDI mounted successfully")
                        self.dmgMounted = true
                    } catch {
                        debugLog("[minimuxer] ERROR: Failed to mount DDI: \(error)")
                    }
                }
            }
        } catch {
            debugLog("[minimuxer] ERROR: \(error)")
        }

    }

}
