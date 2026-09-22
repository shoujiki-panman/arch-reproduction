/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A class that manages peer discovery-token exchange over the local network by using MultipeerConnectivity.
*/

import Foundation
import MultipeerConnectivity

struct MPCSessionConstants {
    static let kKeyIdentity: String = "identity"
    static let kKeyTag: String = "tag"
}

class MPCSession: NSObject, MCSessionDelegate, MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate {
    var peerDataHandler: ((Data, MCPeerID) -> Void)?
    var peerConnectedHandler: ((MCPeerID) -> Void)?
    var peerDisconnectedHandler: ((MCPeerID) -> Void)?
    private let serviceString: String
    private let mcSession: MCSession
    private let localPeerID: MCPeerID
    private let mcAdvertiser: MCNearbyServiceAdvertiser
    private let identityString: String
    private let maxNumPeers: Int
    /// Derived from today's invitation. Only phones that opened the same link
    /// carry the same tag, so nobody else is even invited.
    private let discoveryTag: String
    /// A second value from the invitation, not derivable from the tag that is
    /// broadcast, that an inviting phone must present to be let in.
    private let joinProof: Data
    private var mcBrowser: MCNearbyServiceBrowser?

    init(service: String, identity: String, maxPeers: Int, displayName: String,
         discoveryTag: String, joinProof: Data) {
        serviceString = service
        identityString = identity
        self.discoveryTag = discoveryTag
        self.joinProof = joinProof
        // iOS 16 and later return the model ("iPhone") from UIDevice.current.name
        // unless the app carries the user-assigned-device-name entitlement, so on
        // two of the same phone every row in the list reads the same. The caller
        // supplies a name the pair can tell apart instead.
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        localPeerID = MCPeerID(displayName: trimmed.isEmpty ? "iPhone" : String(trimmed.prefix(20)))
        mcSession = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        mcAdvertiser = MCNearbyServiceAdvertiser(peer: localPeerID,
                                                 discoveryInfo: [MPCSessionConstants.kKeyIdentity: identityString,
                                                                 MPCSessionConstants.kKeyTag: discoveryTag],
                                                 serviceType: serviceString)
        mcBrowser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: serviceString)
        maxNumPeers = maxPeers

        super.init()
        mcSession.delegate = self
        mcAdvertiser.delegate = self
        mcBrowser?.delegate = self
    }

    // MARK: - `MPCSession` public methods.
    func start() {
        mcAdvertiser.startAdvertisingPeer()
        if mcBrowser == nil {
            mcBrowser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: serviceString)
            mcBrowser?.delegate = self
        }
        mcBrowser?.startBrowsingForPeers()
    }

    func suspend() {
        mcAdvertiser.stopAdvertisingPeer()
        mcBrowser = nil
    }

    func invalidate() {
        suspend()
        mcSession.disconnect()
    }

    /// Drop one phone: someone refused, removed, or asking again and again.
    func disconnect(_ peer: MCPeerID) {
        mcSession.cancelConnectPeer(peer)
    }

    func sendDataToAllPeers(data: Data) {
        sendData(data: data, peers: mcSession.connectedPeers, mode: .reliable)
    }

    func sendData(data: Data, peers: [MCPeerID], mode: MCSessionSendDataMode) {
        do {
            try mcSession.send(data, toPeers: peers, with: mode)
        } catch let error {
            NSLog("Error sending data: \(error)")
        }
    }

    // MARK: - `MPCSession` private methods.
    private func peerConnected(peerID: MCPeerID) {
        if let handler = peerConnectedHandler {
            DispatchQueue.main.async {
                handler(peerID)
            }
        }
        if mcSession.connectedPeers.count == maxNumPeers {
            self.suspend()
        }
    }

    private func peerDisconnected(peerID: MCPeerID) {
        if let handler = peerDisconnectedHandler {
            DispatchQueue.main.async {
                handler(peerID)
            }
        }

        if mcSession.connectedPeers.count < maxNumPeers {
            self.start()
        }
    }

    // MARK: - `MCSessionDelegate`.
    internal func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:
            peerConnected(peerID: peerID)
        case .notConnected:
            peerDisconnected(peerID: peerID)
        case .connecting:
            break
        @unknown default:
            fatalError("Unhandled MCSessionState")
        }
    }

    internal func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if let handler = peerDataHandler {
            DispatchQueue.main.async {
                handler(data, peerID)
            }
        }
    }

    internal func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // The sample app intentional omits this implementation.
    }

    internal func session(_ session: MCSession,
                          didStartReceivingResourceWithName resourceName: String,
                          fromPeer peerID: MCPeerID,
                          with progress: Progress) {
        // The sample app intentional omits this implementation.
    }

    internal func session(_ session: MCSession,
                          didFinishReceivingResourceWithName resourceName: String,
                          fromPeer peerID: MCPeerID,
                          at localURL: URL?,
                          withError error: Error?) {
        // The sample app intentional omits this implementation.
    }

    // MARK: - `MCNearbyServiceBrowserDelegate`.
    internal func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard let identityValue = info?[MPCSessionConstants.kKeyIdentity] else {
            return
        }
        guard identityValue == identityString,
              info?[MPCSessionConstants.kKeyTag] == discoveryTag,
              mcSession.connectedPeers.count < maxNumPeers else { return }
        browser.invitePeer(peerID, to: mcSession, withContext: joinProof, timeout: 10)
    }

    internal func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        // The sample app intentional omits this implementation.
    }

    // MARK: - `MCNearbyServiceAdvertiserDelegate`.
    internal func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                             didReceiveInvitationFromPeer peerID: MCPeerID,
                             withContext context: Data?,
                             invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Only a phone holding the same invitation, and only while there is room.
        guard context == joinProof, mcSession.connectedPeers.count < maxNumPeers else {
            invitationHandler(false, nil)
            return
        }
        invitationHandler(true, mcSession)
    }
}
