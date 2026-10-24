import Foundation
import CallKit
import AVFoundation
import UIKit

final class CallKitManager: NSObject {
    private let provider: CXProvider
    private var currentUUID: UUID?
    private var answerAction: CXAnswerCallAction?

    var onStart: ((String) -> Void)?
    var onAnswer: (() -> Void)?
    var onEnd: (() -> Void)?
    var onMute: ((Bool) -> Void)?
    var onDTMF: ((String) -> Void)?
    var onAudioActivated: (() -> Void)?
    var onAudioDeactivated: (() -> Void)?
    var onPrepareAudio: (() -> Void)?

    override init() {
        let configuration = CXProviderConfiguration(localizedName: "CALLSHARE")
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber]
        configuration.includesCallsInRecents = true
        configuration.iconTemplateImageData = UIImage(named: "CallKitTemplateIcon")?.pngData()
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func reportIncoming(number: String, callerName: String?) {
        guard currentUUID == nil else { return }
        let uuid = UUID()
        currentUUID = uuid

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: number)
        update.localizedCallerName = callerName
        update.hasVideo = false
        update.supportsDTMF = true
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if error != nil { self?.currentUUID = nil }
        }
    }

    func startOutgoing(number: String) {
        let uuid = UUID()
        currentUUID = uuid
        let handle = CXHandle(type: .phoneNumber, value: number)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = false
        let transaction = CXTransaction(action: action)
        CXCallController().request(transaction) { [weak self] error in
            if error != nil { self?.currentUUID = nil }
        }
    }

    func endCurrentCall() {
        guard let uuid = currentUUID else { return }
        let transaction = CXTransaction(action: CXEndCallAction(call: uuid))
        CXCallController().request(transaction) { _ in }
    }

    func answerCurrentCall() {
        guard let uuid = currentUUID else { return }
        let action = CXAnswerCallAction(call: uuid)
        CXCallController().request(CXTransaction(action: action)) { error in
            if let error {
                NSLog("[CallKit] In-app answer request failed: %@", error.localizedDescription)
            }
        }
    }

    func setMuted(_ muted: Bool) {
        guard let uuid = currentUUID else { return }
        let action = CXSetMutedCallAction(call: uuid, muted: muted)
        CXCallController().request(CXTransaction(action: action)) { error in
            if let error {
                NSLog("[CallKit] In-app mute request failed: %@", error.localizedDescription)
            }
        }
    }

    func fulfillAnswerIfNeeded() {
        answerAction?.fulfill()
        answerAction = nil
    }

    func reportOutgoingConnecting() {
        guard let uuid = currentUUID else { return }
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
    }

    func reportOutgoingConnected() {
        guard let uuid = currentUUID else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    func reportRemoteEnd(reason: CXCallEndedReason = .remoteEnded) {
        guard let uuid = currentUUID else { return }
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        currentUUID = nil
        answerAction = nil
        // AppModel.handleRemoteEnd() already closes the voice gate and stops the
        // engine synchronously. Avoid issuing a second, untagged deactivation here;
        // CallKit's didDeactivate callback may arrive after a subsequent call starts.
    }

    func clearCurrentCall() {
        currentUUID = nil
        answerAction = nil
    }
}

extension CallKitManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        currentUUID = nil
        answerAction = nil
        onAudioDeactivated?()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        currentUUID = action.callUUID
        // Send GSM call signalling before negotiating the Bluetooth HFP audio route.
        // The voice engine still waits for CallKit activation and J7 GSM readiness.
        reportOutgoingConnecting()
        onStart?(action.handle.value)
        onPrepareAudio?()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        answerAction = action
        // Deliver the GSM answer command before Bluetooth audio-route negotiation.
        onAnswer?()
        onPrepareAudio?()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        onEnd?()
        action.fulfill()
        currentUUID = nil
        answerAction = nil
        // onEnd (AppModel) closes audio before this action is fulfilled. Let the
        // provider's didDeactivate notification represent the system transition.
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        action.fail()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        onMute?(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        onDTMF?(action.digits)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        onAudioActivated?()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // CallKit callbacks do not carry the UUID whose audio session changed.
        // If a new call is already current, a late deactivation from the previous
        // call must not tear down the new call's audio engine.
        if currentUUID != nil { return }
        onAudioDeactivated?()
    }
}
