//
//  MinimuxerError.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation

public enum MinimuxerError: Error, Equatable {
    case NoDevice
    case NoConnection
    case NoVPN
    case PairingFile
    case RestartAlreadyInProgressError

    public static var connectionError: MinimuxerError {
        #if targetEnvironment(simulator)
        return .NoVPN
        #else
        let net = NetworkObserver.shared
        if net.isWifiSatisfied || net.isWiredSatisfied || net.isBridgeSatisfied {
            return .NoVPN
        } else {
            return .NoConnection
        }
        #endif
    }

    case CreateDebug
    case CreateInstproxy
    case CreateLockdown
    case CreateCoreDevice
    case CreateSoftwareTunnel
    case CreateRemoteServer
    case CreateProcessControl

    case GetLockdownValue
    case Connect
    case Close
    case XpcHandshake
    case NoService
    case InvalidProductVersion
    case LookupApps
    case FindApp
    case BundlePath
    case MaxPacket
    case WorkingDirectory
    case Argv
    case LaunchSuccess
    case Detach
    case Attach

    case CreateAfc
    case RwAfc
    case InstallApp(String)
    case UninstallApp

    case CreateMisagent
    case ProfileInstall
    case ProfileRemove

    case CreateFolder
    case DownloadImage
    case ImageLookup
    case ImageRead
    case Mount
}

extension MinimuxerError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .NoDevice: return "NoDevice"
        case .NoConnection: return "NoConnection"
        case .NoVPN: return "NoVPN"
        case .PairingFile: return "PairingFile"
        case .RestartAlreadyInProgressError: return "RestartAlreadyInProgressError"
        case .CreateDebug: return "CreateDebug"
        case .CreateInstproxy: return "CreateInstproxy"
        case .CreateLockdown: return "CreateLockdown"
        case .CreateCoreDevice: return "CreateCoreDevice"
        case .CreateSoftwareTunnel: return "CreateSoftwareTunnel"
        case .CreateRemoteServer: return "CreateRemoteServer"
        case .CreateProcessControl: return "CreateProcessControl"
        case .GetLockdownValue: return "GetLockdownValue"
        case .Connect: return "Connect"
        case .Close: return "Close"
        case .XpcHandshake: return "XpcHandshake"
        case .NoService: return "NoService"
        case .InvalidProductVersion: return "InvalidProductVersion"
        case .LookupApps: return "LookupApps"
        case .FindApp: return "FindApp"
        case .BundlePath: return "BundlePath"
        case .MaxPacket: return "MaxPacket"
        case .WorkingDirectory: return "WorkingDirectory"
        case .Argv: return "Argv"
        case .LaunchSuccess: return "LaunchSuccess"
        case .Detach: return "Detach"
        case .Attach: return "Attach"
        case .CreateAfc: return "CreateAfc"
        case .RwAfc: return "RwAfc"
        case .InstallApp(let msg): return "InstallApp(\(msg))"
        case .UninstallApp: return "UninstallApp"
        case .CreateMisagent: return "CreateMisagent"
        case .ProfileInstall: return "ProfileInstall"
        case .ProfileRemove: return "ProfileRemove"
        case .CreateFolder: return "CreateFolder"
        case .DownloadImage: return "DownloadImage"
        case .ImageLookup: return "ImageLookup"
        case .ImageRead: return "ImageRead"
        case .Mount: return "Mount"
        }
    }
}
