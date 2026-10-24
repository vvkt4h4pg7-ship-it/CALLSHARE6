import Foundation
import CallKit
import AVFoundation
import UIKit

final class CallKitManager: NSObject {
    private let provider: CXProvider
    private var currentUUID: UUID?
    private var answerAction: CXAnswerCallAction?

    // Call-control closures complete only after the BLE GATT write is acknowledged.
    // This keeps CallKit's AirPods/HFP audio-session transition from racing signalling.
    var onStart: ((String, @escaping (Bool) -> Void) -> Void)?
    var onAnswer: ((@escaping (Bool) -> Void) -> Void)?
    var onEnd: ((@escaping (Bool) -> Void) -> Void)?
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

    func failAnswerIfNeeded() {
        answerAction?.fail()
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
        // Report the local intent immediately, but do not enable HFP audio until
        // the MAKE_CALL write has been acknowledged by the J7 GATT server.
        reportOutgoingConnecting()
        var finished = false
        let timeout = DispatchWorkItem { [weak self] in
            guard !finished else { return }
            finished = true
            self?.currentUUID = nil
            action.fail()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.0, execute: timeout)
        guard let onStart else {
            timeout.cancel()
            currentUUID = nil
            action.fail()
            return
        }
        onStart(action.handle.value) { [weak self] written in
            guard let self, !finished else { return }
            finished = true
            timeout.cancel()
            guard written else {
                self.currentUUID = nil
                action.fail()
                return
            }
            self.onPrepareAudio?()
            action.fulfill()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        answerAction = action
        // Keep the answer action pending until J7 confirms the answer event.
        // Prepare AVAudioSession only after the ANSWER write reaches GATT.
        guard let onAnswer else {
            answerAction = nil
            action.fail()
            return
        }
        onAnswer { [weak self] written in
            guard let self else { return }
            guard written else {
                self.answerAction?.fail()
                self.answerAction = nil
                return
            }
            if self.answerAction != nil { self.onPrepareAudio?() }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        // Let VOICE_CLOSE then HANGUP finish their GATT writes before CallKit
        // deactivates the active HFP route. If BLE is temporarily unavailable,
        // AppModel completes the local action and retains a retry intent.
        guard let onEnd else {
            action.fulfill()
            currentUUID = nil
            answerAction = nil
            return
        }
        var finished = false
        let timeout = DispatchWorkItem { [weak self] in
            guard !finished else { return }
            finished = true
            action.fulfill()
            self?.currentUUID = nil
            self?.answerAction = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: timeout)
        onEnd { [weak self] _ in
            guard let self, !finished else { return }
            finished = true
            timeout.cancel()
            action.fulfill()
            self.currentUUID = nil
            self.answerAction = nil
        }
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
