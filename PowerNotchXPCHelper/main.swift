//
//  main.swift
//  PowerNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation
import Security

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    
    /// This method is where the NSXPCListener configures, accepts, and resumes a new incoming NSXPCConnection.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        var ownCode: SecCode?
        var staticCode: SecStaticCode?
        var signingInfo: CFDictionary?
        var teamID: String?
        if SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
           SecCodeCopyStaticCode(ownCode, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo) == errSecSuccess {
            teamID = (signingInfo as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        }
        if let teamID, !teamID.isEmpty {
            newConnection.setCodeSigningRequirement("identifier \"com.powernotch.app\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\"")
        } else {
            guard newConnection.effectiveUserIdentifier == getuid() else {
                newConnection.invalidate()
                return false
            }
            newConnection.setCodeSigningRequirement("identifier \"com.powernotch.app\"")
        }
        
        // Configure the connection.
        // First, set the interface that the exported object implements.
        newConnection.exportedInterface = NSXPCInterface(with: (any PowerNotchXPCHelperProtocol).self)
        
        // Next, set the object that the connection exports. All messages sent on the connection to this service will be sent to the exported object to handle. The connection retains the exported object.
        let exportedObject = PowerNotchXPCHelper()
        newConnection.exportedObject = exportedObject
        
        // Resuming the connection allows the system to deliver more incoming messages.
        newConnection.resume()
        
        // Returning true from this method tells the system that you have accepted this connection. If you want to reject the connection for some reason, call invalidate() on the connection and return false.
        return true
    }
}

// Create the delegate for the service.
let delegate = ServiceDelegate()

// Set up the one NSXPCListener for this service. It will handle all incoming connections.
let listener = NSXPCListener.service()
listener.delegate = delegate

// Resuming the serviceListener starts this service. This method does not return.
listener.resume()
