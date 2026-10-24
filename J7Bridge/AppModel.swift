import Foundation
import Combine
import CallKit
import Network
import Darwin

struct CallshareSMSMessage: Identifiable, Codable, Equatable {
    var id: String
    var address: String
    var body: String
    var direction: String
    var timestampMs: Int64
    var status: String
    var statusDetail: String?
    var isUnread: Bool

    var date: Date { Date(timeIntervalSince1970: Double(timestampMs) / 1_000.0) }
    var isOutgoing: Bool { direction.caseInsensitiveCompare("outgoing") == .orderedSame || direction.caseInsensitiveCompare("out") == .orderedSame }
}

struct CallshareSMSConversation: Identifiable {
    var id: String { address }
    let address: String
    let latestMessage: CallshareSMSMessage
    let unreadCount: Int
}

struct CallshareSMSRoute: Hashable {
    let address: String
    let targetMessageID: String?
}

private struct IncomingSMSAssembly {
    let id: String
    let address: String
    let direction: String
    let timestampMs: Int64
    let parts: Int
    var status: String
    var replay: Bool
    var chunks: [Data?]
    var received = 0
    var updatedAt = Date()
}

@MainActor
final class AppModel: ObservableObject {
    @Published var bleStatus = "Disconnected"
    @Published var deviceName = "-"
    @Published var callStatus = "IDLE"
    @Published var number = ""
    @Published var callerName = ""
    @Published var voiceStatus = "CLOSED"
    @Published var wifiStatus = "Waiting"
    @Published private(set) var iPhoneIPv4 = "-"
    @Published var j7Host: String {
        didSet {
            UserDefaults.standard.set(j7Host, forKey: "j7bridge.j7Host")
            wifi.setJ7Host(j7Host)
        }
    }
    @Published var dialString = ""
    @Published var battery = "-"
    @Published var firmware = "-"
    @Published var imei = "-"
    @Published var isMuted = false
    @Published private(set) var callStartedAt: Date?
    @Published private(set) var callConnectedAt: Date?
    @Published private(set) var smsMessages: [CallshareSMSMessage] = []
    @Published var selectedTab = 0
    @Published var pendingSMSNavigationID: String?

    private var incomingSMSAssemblies: [String: IncomingSMSAssembly] = [:]
    private let smsMessagesDefaultsKey = "j7bridge.smsMessages.v1"
    private let smsDeletedConversationsDefaultsKey = "j7bridge.smsDeletedConversations.v1"
    private var deletedSMSConversationAddresses: Set<String> = []
    private static let smsChunkBytes = 36
    private static let smsMaxBodyBytes = 16_384
    private static let smsHistoryLimit = 200

    var smsConversations: [CallshareSMSConversation] {
        let grouped = Dictionary(grouping: smsMessages, by: \.address)
        return grouped.compactMap { address, messages in
            guard let latest = messages.max(by: { $0.timestampMs < $1.timestampMs }) else { return nil }
            return CallshareSMSConversation(address: address, latestMessage: latest, unreadCount: messages.filter(\.isUnread).count)
        }.sorted { $0.latestMessage.timestampMs > $1.latestMessage.timestampMs }
    }

    @Published var autoConnect: Bool {
        didSet {
            UserDefaults.standard.set(autoConnect, forKey: "j7bridge.autoConnect")
            ble.autoReconnect = autoConnect
        }
    }
    @Published var resolveCallerNames: Bool {
        didSet { UserDefaults.standard.set(resolveCallerNames, forKey: "j7bridge.resolveCallerNames") }
    }
    @Published var missedCallNotifications: Bool {
        didSet { UserDefaults.standard.set(missedCallNotifications, forKey: "j7bridge.missedCallNotifications") }
    }
    @Published var simSlot: Int {
        didSet { UserDefaults.standard.set(simSlot, forKey: "j7bridge.simSlot") }
    }

    let ble: BLEManager
    let callKit: CallKitManager
    let contacts: ContactsManager
    let history: CallHistoryStore
    let notifications = NotificationManager()
    let wifi: WiFiTransport
    let wifiVoice: WiFiVoiceEngine

    private var currentDirection: CallDirection?
    private var currentContactName: String?
    private var callAudioActive = false
    private var remoteVoiceOpen = false
    private var gsmCallReady = false
    private var voiceOpenCommandSent = false
    private var networkMonitor: NWPathMonitor?
    private let networkQueue = DispatchQueue(label: "com.callshare.hybrid.network-monitor")
    private var lastAnnouncedIPv4: String?
    private var pendingOutgoingCall: (number: String, simId: UInt8)?
    private var pendingOutgoingCallCompletion: ((Bool) -> Void)?
    private var pendingOutgoingCallTimeout: DispatchWorkItem?
    private var pendingAnswerCommand = false
    private var pendingAnswerAwaitingGSMOffhook = false
    private var pendingAnswerCompletion: ((Bool) -> Void)?
    private var pendingAnswerTimeout: DispatchWorkItem?
    private var pendingAnswerRetryWorkItem: DispatchWorkItem?
    private var pendingAnswerWriteInFlight = false
    private var pendingAnswerAttempts = 0
    private var pendingHangupCommand = false
    private var pendingVoiceCloseForHangup = false
    private var pendingHangupWriteInFlight = false
    private var pendingEndCompletion: ((Bool) -> Void)?
    private var pendingHangupRetryCount = 0
    private var pendingHangupRetryWorkItem: DispatchWorkItem?
    private var didStart = false

    init() {
        autoConnect = UserDefaults.standard.object(forKey: "j7bridge.autoConnect") as? Bool ?? true
        resolveCallerNames = UserDefaults.standard.object(forKey: "j7bridge.resolveCallerNames") as? Bool ?? true
        missedCallNotifications = UserDefaults.standard.object(forKey: "j7bridge.missedCallNotifications") as? Bool ?? true
        simSlot = UserDefaults.standard.object(forKey: "j7bridge.simSlot") as? Int ?? 0
        let rememberedHost = UserDefaults.standard.string(forKey: "j7bridge.j7Host") ?? "192.168.93.232"
        j7Host = rememberedHost

        ble = BLEManager()
        callKit = CallKitManager()
        wifi = WiFiTransport(j7Host: rememberedHost, port: 50005)
        wifiVoice = WiFiVoiceEngine(transport: wifi)
        contacts = ContactsManager()
        history = CallHistoryStore()
        smsMessages = Self.loadSMSMessages(forKey: smsMessagesDefaultsKey)
        deletedSMSConversationAddresses = Self.loadDeletedSMSConversationAddresses(forKey: smsDeletedConversationsDefaultsKey)
        if !deletedSMSConversationAddresses.isEmpty {
            smsMessages.removeAll { deletedSMSConversationAddresses.contains(Self.canonicalSMSAddress($0.address)) }
        }

        notifications.onOpenSMS = { [weak self] messageID in
            guard let self else { return }
            self.pendingSMSNavigationID = messageID
            self.selectedTab = 3
        }

        ble.autoReconnect = autoConnect

        ble.onStatus = { [weak self] status in
            guard let self else { return }
            self.bleStatus = status
            if status == "Disconnected" { self.lastAnnouncedIPv4 = nil }
        }
        ble.onDevice = { [weak self] name in self?.deviceName = name ?? "IKOS K7 / CALLSHARE J7" }
        ble.onControlPayload = { [weak self] payload in self?.handleControl(payload) }
        // BLE audio notifications are intentionally ignored in R1. Wi-Fi R2 is the sole audio plane.
        // Legacy BLE audio remains unused; Wi-Fi UDP is the sole audio plane.
        ble.onAudioPayload = nil
        ble.onReady = { [weak self] in
            guard let self else { return }
            self.announceCurrentIPv4ToJ7(force: true)
            self.flushPendingCallControlsIfReady()
            if !self.pendingHangupCommand {
                self.flushPendingOutgoingCallIfReady()
            }
        }

        wifi.onJ7HostDiscovered = { [weak self] host in
            Task { @MainActor [weak self] in
                guard let self, Self.isIPv4(host), self.j7Host != host else { return }
                self.j7Host = host
            }
        }
        // The UDP control port is not used for call control; BLE GATT owns it.
        wifi.onControl = nil
        wifi.onAudioPCM = { [weak self] pcm, rate, channels, frames in
            self?.wifiVoice.receivePCM(pcm, sampleRate: rate, channels: channels, frames: frames)
        }
        callKit.onStart = { [weak self] number, completion in
            guard let self else { completion(false); return }
            self.beginOutgoing(number, completion: completion)
        }
        callKit.onAnswer = { [weak self] completion in
            guard let self else { completion(false); return }
            self.requestAnswerFromCallKit(completion: completion)
        }
        callKit.onEnd = { [weak self] completion in
            guard let self else { completion(false); return }
            self.endFromCallKit(completion: completion)
        }
        callKit.onMute = { [weak self] muted in
            self?.isMuted = muted
            self?.wifiVoice.setMuted(muted)
        }
        callKit.onDTMF = { [weak self] digits in self?.sendDTMFString(digits) }
        callKit.onPrepareAudio = { [weak self] in self?.wifiVoice.prepareForCallAudio() }
        callKit.onAudioActivated = { [weak self] in
            guard let self else { return }
            self.callAudioActive = true
            self.requestVoiceOpenIfReady()
            self.maybeStartVoice()
        }
        callKit.onAudioDeactivated = { [weak self] in
            guard let self else { return }
            self.callAudioActive = false
            if self.voiceOpenCommandSent || self.remoteVoiceOpen { self.ble.sendVoiceClose() }
            self.voiceOpenCommandSent = false
            self.remoteVoiceOpen = false
            self.gsmCallReady = false
            self.wifi.setAudioReceiveEnabled(false)
            self.wifiVoice.stop()
            self.voiceStatus = "CLOSED"
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        wifi.start()
        ble.startScan()
        startNetworkMonitor()
        notifications.requestPermission()
        if contacts.authorization == .authorized { contacts.load() }
        log("[HYBRID R1] Started: BLE GATT control + Wi-Fi R2 PCM audio")
    }

    func answerTest() { ble.sendAnswer() }

    func makeCall() {
        guard !pendingHangupCommand, (callStatus == "IDLE" || callStatus == "ENDED") else {
            log("[CALL] New outgoing call blocked until previous J7 hangup is confirmed")
            return
        }
        let cleaned = dialString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        beginCall(number: cleaned, direction: .outgoing, name: contacts.resolveName(for: cleaned))
        callKit.startOutgoing(number: cleaned)
    }

    // Start a real CALLSHARE GSM call from a selected contact or a recent call.
    // Keep this on the existing CallKit -> BLE MAKE_CALL path used by the keypad.
    func makeCall(to rawNumber: String) {
        guard (callStatus == "IDLE" || callStatus == "ENDED"), !pendingHangupCommand else {
            log("[CALL] Ignored selected-number call while status=\(callStatus) hangupPending=\(pendingHangupCommand)")
            return
        }

        // Contacts often store phone numbers with spaces, dashes or parentheses.
        // Strip formatting while keeping common telephone characters.
        let cleaned = rawNumber.filter { $0.isNumber || $0 == "+" || $0 == "*" || $0 == "#" }
        guard !cleaned.isEmpty, cleaned.contains(where: { $0.isNumber }) else {
            log("[CALL] Ignored invalid selected phone number")
            return
        }

        dialString = cleaned
        makeCall()
    }

    func endCall() { callKit.endCurrentCall() }

    // Route in-app controls through CallKit so they share the same callbacks as iOS controls.
    func answerCurrentCallFromInAppScreen() {
        guard callStatus == "RINGING" else { return }
        callKit.answerCurrentCall()
    }

    func toggleMuteFromInAppScreen() {
        callKit.setMuted(!isMuted)
    }

    func tapDialpad(_ digit: String) {
        if callStatus == "ACTIVE" { sendDTMFString(digit) }
        else { dialString.append(digit) }
    }

    func backspaceDialpad() {
        guard callStatus != "ACTIVE", !dialString.isEmpty else { return }
        dialString.removeLast()
    }

    func requestContacts() { contacts.requestAccessAndLoad() }
    func clearHistory() { history.clear() }

    func requestDeviceInfo() {
        ble.requestDeviceCheck()
        ble.requestBattery()
        ble.requestFirmware()
        ble.requestIMEI()
    }

    func sendDTMFString(_ digits: String) {
        for character in digits {
            switch character {
            case "0"..."9", "*", "#":
                ble.sendDTMF(UInt8(String(character).utf8.first!))
            default: break
            }
        }
    }

    func handleControl(_ payload: Data) {
        guard let op = payload.first else { return }
        switch op {
        case K7Protocol.evtReceiveCall:
            handleIncoming(payload)
        case K7Protocol.evtAnswer:
            // Android emits EVT_ANSWER after receiving the command, even when
            // TelecomManager.acceptRingingCall() fails. Treat this as a command
            // acknowledgement only; physical GSM OFFHOOK is the success signal.
            guard pendingAnswerCommand || pendingAnswerAwaitingGSMOffhook else {
                log("[CALL] Ignored unsolicited/stale BLE ANSWER acknowledgement")
                break
            }
            pendingAnswerCommand = false
            pendingAnswerAwaitingGSMOffhook = true
            pendingAnswerWriteInFlight = false
            pendingAnswerRetryWorkItem?.cancel()
            pendingAnswerRetryWorkItem = nil
            pendingAnswerAttempts = 0
            log("[CALL] J7 acknowledged ANSWER command; waiting for physical GSM OFFHOOK before fulfilling CallKit")
        case K7Protocol.evtReceiveCallEnd:
            handleRemoteEnd()
        case K7Protocol.evtVoiceOpen:
            remoteVoiceOpen = true
            log("[BLE] VOICE OPEN EVENT")
            maybeStartVoice()
        case K7Protocol.evtVoiceClose:
            remoteVoiceOpen = false
            voiceOpenCommandSent = false
            gsmCallReady = false
            log("[BLE] VOICE CLOSE EVENT")
            wifi.setAudioReceiveEnabled(false)
            wifiVoice.stop()
        case K7Protocol.evtMakeCall:
            callStatus = "DIALING"
            log("[CALL] BLE MAKE_CALL accepted \(K7Protocol.hex(payload)); waiting for physical GSM OFFHOOK")
            callKit.reportOutgoingConnecting()
        case K7Protocol.evtReadBattery:
            if payload.count >= 5 { battery = String(payload[4]) }
            log("[K7] BATTERY \(battery)")
        case K7Protocol.evtFirmwareVersion:
            firmware = K7Protocol.decodeASCIIBlock(payload, offset: 1)
            log("[K7] FIRMWARE \(firmware)")
        case K7Protocol.evtIMEIInfo:
            imei = K7Protocol.decodeASCIIBlock(payload, offset: 3)
            log("[K7] IMEI \(imei)")
        case K7Protocol.evtCallshareGSMOffhook:
            gsmCallReady = true
            if currentDirection == .incoming,
               callStatus == "RINGING",
               pendingAnswerCommand || pendingAnswerAwaitingGSMOffhook || pendingAnswerCompletion != nil {
                // Only physical OFFHOOK proves that the cellular call really
                // answered. Prepare the audio route, then fulfill CallKit.
                pendingAnswerCommand = false
                pendingAnswerAwaitingGSMOffhook = false
                pendingAnswerWriteInFlight = false
                pendingAnswerTimeout?.cancel()
                pendingAnswerTimeout = nil
                pendingAnswerRetryWorkItem?.cancel()
                pendingAnswerRetryWorkItem = nil
                pendingAnswerAttempts = 0
                callStatus = "ACTIVE"
                if callConnectedAt == nil { callConnectedAt = Date() }
                beginCallIfNeeded(direction: .incoming)
                let answerCompletion = pendingAnswerCompletion
                pendingAnswerCompletion = nil
                answerCompletion?(true)
                callKit.fulfillAnswerIfNeeded()
                log("[CALL] Incoming answer confirmed by physical GSM OFFHOOK")
            }
            log("[HYBRID] J7 GSM OFFHOOK event received; CallKit=\(callAudioActive ? "active" : "not active")")
            requestVoiceOpenIfReady()
        case K7Protocol.evtCallshareCallActive:
            // OFFHOOK includes outgoing dialing. Start the visible call timer only
            // when the Android Telecom state probe confirms the remote party answered.
            guard currentDirection == .outgoing, callStatus == "DIALING" else {
                log("[CALL] Ignored GSM ACTIVE confirmation outside outgoing dialing state")
                break
            }
            callStatus = "ACTIVE"
            if callConnectedAt == nil { callConnectedAt = Date() }
            callKit.reportOutgoingConnected()
            log("[CALL] J7 Telecom confirmed outgoing GSM call ACTIVE; connected timer started")
            requestVoiceOpenIfReady()
        case K7Protocol.evtCallshareJ7IPv4:
            handleJ7IPv4(payload)
        case K7Protocol.evtCallshareSMS:
            handleSMS(payload)
        case K7Protocol.evtCallshareSMSStatus:
            handleSMSStatus(payload)
        case K7Protocol.cmdCallsharePeerIPv4:
            log("[HYBRID] Unexpected iPhone-peer-IP opcode from J7")
        default:
            log("[BLE] CONTROL \(String(format: "%02X", op)) \(K7Protocol.hex(payload))")
        }
    }

    private func handleIncoming(_ payload: Data) {
        guard callStatus == "IDLE" || callStatus == "ENDED" else {
            log("[CALL] duplicate incoming ignored")
            return
        }
        let incomingNumber = K7Protocol.decodeIncomingNumber(payload)
        let name = resolveCallerNames ? contacts.resolveName(for: incomingNumber) : nil
        number = incomingNumber
        callerName = name ?? ""
        currentContactName = name
        currentDirection = .incoming
        callStartedAt = Date()
        callConnectedAt = nil
        callAudioActive = false
        remoteVoiceOpen = false
        gsmCallReady = false
        voiceOpenCommandSent = false
        pendingAnswerCommand = false
        pendingAnswerAwaitingGSMOffhook = false
        pendingAnswerWriteInFlight = false
        pendingAnswerRetryWorkItem?.cancel()
        pendingAnswerRetryWorkItem = nil
        pendingAnswerTimeout?.cancel()
        pendingAnswerTimeout = nil
        pendingAnswerCompletion = nil
        pendingAnswerAttempts = 0
        callStatus = "RINGING"
        log("[CALL] INCOMING over BLE \(name.map { "\($0) / " } ?? "")\(incomingNumber)")
        // Critical: report to CallKit immediately; never wait for UDP/IP/audio readiness.
        callKit.reportIncoming(number: incomingNumber, callerName: name)
        announceCurrentIPv4ToJ7(force: true)
    }

    private func beginOutgoing(_ outgoingNumber: String, completion: @escaping (Bool) -> Void) {
        number = outgoingNumber
        callerName = contacts.resolveName(for: outgoingNumber) ?? ""
        currentContactName = callerName.isEmpty ? nil : callerName
        dialString = ""
        beginCall(number: outgoingNumber, direction: .outgoing, name: currentContactName)
        callStatus = "DIALING"

        let selectedSIM = UInt8(simSlot)
        let queued = ble.sendMakeCall(number: outgoingNumber, simId: selectedSIM) { [weak self] written in
            guard let self else { completion(false); return }
            if written {
                self.clearPendingOutgoingCall()
                self.log("[CALL] MAKE_CALL GATT write acknowledged; now allowing CallKit audio activation")
                completion(true)
            } else {
                self.failOutgoingStart()
                completion(false)
            }
        }
        if queued {
            clearPendingOutgoingCall()
            log("[CALL] OUTGOING MAKE_CALL queued to GATT; SIM slot=\(simSlot)")
        } else {
            queuePendingOutgoingCall(number: outgoingNumber, simId: selectedSIM, completion: completion)
            log("[CALL] MAKE_CALL waiting for BLE GATT readiness")
        }
    }

    private func queuePendingOutgoingCall(number: String, simId: UInt8, completion: @escaping (Bool) -> Void) {
        clearPendingOutgoingCall()
        pendingOutgoingCall = (number: number, simId: simId)
        pendingOutgoingCallCompletion = completion
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  let pending = self.pendingOutgoingCall,
                  pending.number == number,
                  self.callStatus == "DIALING",
                  self.currentDirection == .outgoing else { return }
            let failedCompletion = self.pendingOutgoingCallCompletion
            self.clearPendingOutgoingCall()
            self.failOutgoingStart()
            failedCompletion?(false)
            self.log("[CALL] Outgoing call failed: BLE GATT was not ready within 5.5 seconds")
        }
        pendingOutgoingCallTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5, execute: timeout)
    }

    private func flushPendingOutgoingCallIfReady() {
        guard let pending = pendingOutgoingCall else { return }
        guard callStatus == "DIALING",
              currentDirection == .outgoing,
              number == pending.number else {
            clearPendingOutgoingCall()
            return
        }
        let completion = pendingOutgoingCallCompletion ?? { _ in }
        let queued = ble.sendMakeCall(number: pending.number, simId: pending.simId) { [weak self] written in
            guard let self else { completion(false); return }
            self.clearPendingOutgoingCall()
            if written {
                self.log("[CALL] Deferred MAKE_CALL GATT write acknowledged")
                completion(true)
            } else {
                self.failOutgoingStart()
                completion(false)
            }
        }
        guard queued else { return }
        clearPendingOutgoingCall()
        log("[CALL] Deferred MAKE_CALL queued after BLE GATT became ready")
    }

    private func clearPendingOutgoingCall() {
        pendingOutgoingCall = nil
        pendingOutgoingCallCompletion = nil
        pendingOutgoingCallTimeout?.cancel()
        pendingOutgoingCallTimeout = nil
    }

    private func failOutgoingStart() {
        clearPendingOutgoingCall()
        callStatus = "ENDED"
        callStartedAt = nil
        callConnectedAt = nil
        currentDirection = nil
        currentContactName = nil
        callAudioActive = false
        remoteVoiceOpen = false
        gsmCallReady = false
        voiceOpenCommandSent = false
        pendingAnswerCommand = false
        pendingAnswerAwaitingGSMOffhook = false
        pendingAnswerRetryWorkItem?.cancel()
        pendingAnswerRetryWorkItem = nil
        pendingAnswerCompletion = nil
        pendingAnswerTimeout?.cancel()
        pendingAnswerTimeout = nil
        voiceStatus = "CLOSED"
        wifi.setAudioReceiveEnabled(false)
        wifiVoice.stop()
    }

    private func requestAnswerFromCallKit(completion: @escaping (Bool) -> Void) {
        guard callStatus == "RINGING" else {
            completion(false)
            return
        }
        pendingAnswerCommand = true
        pendingAnswerCompletion = completion
        pendingAnswerAttempts = 0
        pendingAnswerTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingAnswerCommand || self.pendingAnswerAwaitingGSMOffhook else { return }
            self.pendingAnswerCommand = false
            self.pendingAnswerAwaitingGSMOffhook = false
            self.pendingAnswerWriteInFlight = false
            self.pendingAnswerRetryWorkItem?.cancel()
            self.pendingAnswerRetryWorkItem = nil
            let answerCompletion = self.pendingAnswerCompletion
            self.pendingAnswerCompletion = nil
            self.pendingAnswerTimeout = nil
            answerCompletion?(false)
            self.callKit.failAnswerIfNeeded()
            self.log("[CALL] Answer failed: J7 did not confirm physical GSM OFFHOOK within 5.5 seconds")
        }
        pendingAnswerTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5, execute: timeout)
        flushPendingCallControlsIfReady()
    }

    private func flushPendingCallControlsIfReady() {
        guard ble.isReady else {
            // A disconnected control channel must not silently discard Answer/Hangup.
            // Keep the intent until the GATT-ready callback fires again.
            completeEndAction(false)
            return
        }

        if pendingHangupCommand {
            guard !pendingHangupWriteInFlight else { return }
            pendingHangupWriteInFlight = true
            if pendingVoiceCloseForHangup {
                let queued = ble.sendVoiceClose { [weak self] written in
                    guard let self, self.pendingHangupCommand else { return }
                    if written {
                        self.pendingVoiceCloseForHangup = false
                        self.sendPendingHangupWrite()
                    } else {
                        self.pendingHangupWriteInFlight = false
                        self.completeEndAction(false)
                        self.schedulePendingHangupRetry()
                    }
                }
                if !queued {
                    pendingHangupWriteInFlight = false
                    completeEndAction(false)
                }
            } else {
                sendPendingHangupWrite()
            }
            return
        }

        guard pendingAnswerCommand, !pendingAnswerWriteInFlight, callStatus == "RINGING" else { return }
        pendingAnswerWriteInFlight = true
        pendingAnswerAttempts += 1
        let queued = ble.sendAnswer { [weak self] written in
            guard let self else { return }
            self.pendingAnswerWriteInFlight = false
            guard self.pendingAnswerCommand else { return }
            if written {
                // A GATT write ACK is transport-level only. Android's EVT_ANSWER
                // acknowledges the command; physical OFFHOOK fulfills the answer.
                if self.pendingAnswerAttempts < 4 {
                    self.schedulePendingAnswerRetry(after: 0.9)
                }
            } else if self.pendingAnswerAttempts < 4 {
                self.schedulePendingAnswerRetry(after: 0.45)
            } else {
                self.pendingAnswerCommand = false
                self.pendingAnswerAwaitingGSMOffhook = false
                self.pendingAnswerRetryWorkItem?.cancel()
                self.pendingAnswerRetryWorkItem = nil
                self.pendingAnswerTimeout?.cancel()
                self.pendingAnswerTimeout = nil
                let completion = self.pendingAnswerCompletion
                self.pendingAnswerCompletion = nil
                completion?(false)
                self.callKit.failAnswerIfNeeded()
            }
        }
        if !queued { pendingAnswerWriteInFlight = false }
    }

    private func schedulePendingAnswerRetry(after delay: TimeInterval) {
        pendingAnswerRetryWorkItem?.cancel()
        let retry = DispatchWorkItem { [weak self] in
            guard let self, self.pendingAnswerCommand, self.callStatus == "RINGING" else { return }
            self.pendingAnswerRetryWorkItem = nil
            self.flushPendingCallControlsIfReady()
        }
        pendingAnswerRetryWorkItem = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
    }

    private func sendPendingHangupWrite() {
        guard pendingHangupCommand, pendingHangupWriteInFlight else { return }
        let queued = ble.sendHangup { [weak self] written in
            guard let self else { return }
            self.pendingHangupWriteInFlight = false
            guard self.pendingHangupCommand else { return }
            if written {
                self.completeEndAction(true)
                self.schedulePendingHangupRetry()
            } else {
                self.completeEndAction(false)
                self.schedulePendingHangupRetry()
            }
        }
        if !queued {
            pendingHangupWriteInFlight = false
            completeEndAction(false)
        }
    }

    private func completeEndAction(_ success: Bool) {
        guard let completion = pendingEndCompletion else { return }
        pendingEndCompletion = nil
        completion(success)
    }

    private func schedulePendingHangupRetry() {
        pendingHangupRetryWorkItem?.cancel()
        guard pendingHangupCommand, pendingHangupRetryCount < 2 else { return }
        let retry = DispatchWorkItem { [weak self] in
            guard let self, self.pendingHangupCommand, self.ble.isReady else { return }
            self.pendingHangupRetryCount += 1
            self.pendingHangupWriteInFlight = false
            self.pendingVoiceCloseForHangup = false
            self.flushPendingCallControlsIfReady()
        }
        pendingHangupRetryWorkItem = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: retry)
    }

    private func beginCall(number: String, direction: CallDirection, name: String?) {
        self.number = number
        currentDirection = direction
        currentContactName = name
        callStartedAt = Date()
        callConnectedAt = nil
        callAudioActive = false
        remoteVoiceOpen = false
        gsmCallReady = false
        voiceOpenCommandSent = false
        if direction == .outgoing { callStatus = "DIALING" }
    }

    private func beginCallIfNeeded(direction: CallDirection) {
        if callStartedAt == nil { callStartedAt = Date() }
        currentDirection = direction
        if direction == .incoming && callerName.isEmpty { callerName = currentContactName ?? "" }
    }

    private func requestVoiceOpenIfReady() {
        let outgoingMayOpen = currentDirection == .outgoing && (callStatus == "DIALING" || callStatus == "ACTIVE")
        let incomingMayOpen = currentDirection == .incoming && callStatus == "ACTIVE"
        guard callAudioActive, gsmCallReady, outgoingMayOpen || incomingMayOpen else { return }
        guard !voiceOpenCommandSent else { return }
        voiceOpenCommandSent = true
        ble.sendVoiceOpen()
        log("[HYBRID] BLE VOICE_OPEN sent: CallKit audio active + GSM call accepted/started")
    }

    private func maybeStartVoice() {
        let outgoingMediaMayStart = (currentDirection == .outgoing && callStatus == "DIALING")
        guard callStatus == "ACTIVE" || outgoingMediaMayStart else {
            log("[VOICE] WAIT call state=\(callStatus)")
            return
        }
        guard remoteVoiceOpen else {
            log("[VOICE] WAIT J7 VOICE_OPEN over BLE")
            return
        }
        guard callAudioActive else {
            log("[VOICE] WAIT CallKit audio activation")
            return
        }
        log("[HYBRID] Voice gate passed: CallKit active + GSM active + BLE VOICE_OPEN; starting Wi-Fi R3 audio")
        if wifiVoice.start() {
            voiceStatus = "ACTIVE"
            wifi.setAudioReceiveEnabled(true)
        } else {
            voiceStatus = "CLOSED"
            wifi.setAudioReceiveEnabled(false)
        }
    }

    private func endFromCallKit(completion: @escaping (Bool) -> Void) {
        let pendingStartCompletion = pendingOutgoingCallCompletion
        clearPendingOutgoingCall()
        pendingStartCompletion?(false)

        pendingAnswerCommand = false
        pendingAnswerAwaitingGSMOffhook = false
        pendingAnswerWriteInFlight = false
        pendingAnswerRetryWorkItem?.cancel()
        pendingAnswerRetryWorkItem = nil
        pendingAnswerTimeout?.cancel()
        pendingAnswerTimeout = nil
        pendingAnswerAttempts = 0
        pendingAnswerCompletion?(false)
        pendingAnswerCompletion = nil

        pendingHangupCommand = true
        pendingVoiceCloseForHangup = true
        pendingHangupWriteInFlight = false
        pendingHangupRetryCount = 0
        pendingEndCompletion = completion
        pendingHangupRetryWorkItem?.cancel()
        pendingHangupRetryWorkItem = nil

        // Keep CallKit's current call registered until its CXEndCallAction is
        // fulfilled. The BLE write must finish before CallKit deactivates HFP.
        callAudioActive = false
        wifi.setAudioReceiveEnabled(false)
        wifiVoice.stop()
        voiceStatus = "CLOSED"
        voiceOpenCommandSent = false
        remoteVoiceOpen = false
        gsmCallReady = false
        finishHistory(direction: currentDirection ?? .outgoing)
        callStatus = "ENDED"
        flushPendingCallControlsIfReady()
    }

    private func handleRemoteEnd() {
        let pendingStartCompletion = pendingOutgoingCallCompletion
        clearPendingOutgoingCall()
        pendingStartCompletion?(false)
        pendingHangupCommand = false
        pendingVoiceCloseForHangup = false
        pendingHangupWriteInFlight = false
        pendingHangupRetryWorkItem?.cancel()
        pendingHangupRetryWorkItem = nil
        completeEndAction(true)
        pendingAnswerCommand = false
        pendingAnswerAwaitingGSMOffhook = false
        pendingAnswerWriteInFlight = false
        pendingAnswerRetryWorkItem?.cancel()
        pendingAnswerRetryWorkItem = nil
        pendingAnswerTimeout?.cancel()
        pendingAnswerTimeout = nil
        pendingAnswerAttempts = 0
        pendingAnswerCompletion?(false)
        pendingAnswerCompletion = nil

        // The local CallKit end action already finalized the call. Ignore its later
        // GSM IDLE echo to avoid duplicate call-history entries.
        if callStatus == "ENDED" && callStartedAt == nil { return }
        let wasRinging = callStatus == "RINGING"
        let direction = currentDirection ?? .incoming
        ble.sendVoiceClose()
        callAudioActive = false
        wifi.setAudioReceiveEnabled(false)
        wifiVoice.stop()
        voiceStatus = "CLOSED"
        voiceOpenCommandSent = false
        remoteVoiceOpen = false
        gsmCallReady = false
        finishHistory(direction: wasRinging ? .missed : direction)
        callStatus = "ENDED"
        log("[CALL] END EVENT over BLE")
        callKit.reportRemoteEnd()
    }

    private func finishHistory(direction: CallDirection) {
        let duration = callStartedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        if !number.isEmpty {
            history.add(number: number, name: currentContactName, direction: direction, duration: duration)
            if direction == .missed, missedCallNotifications {
                notifications.sendMissedCall(number: number, name: currentContactName)
            }
        }
        callStartedAt = nil
        callConnectedAt = nil
        currentDirection = nil
        currentContactName = nil
        callAudioActive = false
    }

    private func handleJ7IPv4(_ payload: Data) {
        guard payload.count > 1,
              let host = String(data: payload.dropFirst(), encoding: .utf8),
              Self.isIPv4(host) else {
            log("[HYBRID] Ignored invalid J7 IPv4 event payload=\(K7Protocol.hex(payload))")
            return
        }
        if j7Host != host {
            log("[HYBRID] J7 IP updated through BLE: \(j7Host) -> \(host)")
            j7Host = host
        } else {
            log("[HYBRID] J7 IP confirmed through BLE: \(host)")
        }
        announceCurrentIPv4ToJ7(force: true)
    }

    private func handleSMS(_ payload: Data) {
        guard payload.count > 1 else { return }
        let jsonData = Data(payload.dropFirst())
        guard let parsed = try? JSONSerialization.jsonObject(with: jsonData),
              let object = parsed as? [String: Any] else {
            log("[SMS] Invalid CALLSHARE SMS event JSON")
            return
        }

        if object["kind"] as? String == "message" {
            handleSMSMessageChunk(object)
            return
        }

        // Backward compatibility with early bridges that sent one {from, body} JSON.
        if let sender = object["from"] as? String, let body = object["body"] as? String {
            let messageID = "legacy-\(UUID().uuidString.lowercased())"
            let nowMs = Int64(Date().timeIntervalSince1970 * 1_000.0)
            let address = Self.canonicalSMSAddress(sender)
            restoreSMSConversation(forAddress: address)
            let message = CallshareSMSMessage(
                id: messageID, address: address, body: body, direction: "incoming",
                timestampMs: nowMs, status: "received", statusDetail: nil, isUnread: true
            )
            upsertSMS(message)
            notifications.sendSMS(sender: address, body: body, messageID: messageID)
            log("[SMS] Legacy notification received from \(address), body length=\(body.count)")
            return
        }
        log("[SMS] Unknown CALLSHARE SMS event format")
    }

    private func handleSMSMessageChunk(_ object: [String: Any]) {
        guard let id = object["id"] as? String, !id.isEmpty, id.count <= 80,
              let rawAddress = object["address"] as? String, !rawAddress.isEmpty,
              let direction = object["dir"] as? String,
              let encodedChunk = object["chunk"] as? String,
              let chunk = Data(base64Encoded: encodedChunk, options: [.ignoreUnknownCharacters]) else {
            log("[SMS] Invalid SMS message chunk metadata")
            return
        }
        let address = Self.canonicalSMSAddress(rawAddress)
        let parts = (object["parts"] as? NSNumber)?.intValue ?? 0
        let part = (object["part"] as? NSNumber)?.intValue ?? -1
        let timestampMs = (object["ts"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1_000.0)
        let status = object["status"] as? String ?? "received"
        let replay = object["replay"] as? Bool ?? false
        guard parts >= 1, parts <= 512, part >= 0, part < parts,
              chunk.count <= Self.smsChunkBytes else {
            log("[SMS] Invalid SMS chunk bounds id=\(id) part=\(part)/\(parts)")
            return
        }

        let now = Date()
        // Expire only abandoned assembly buffers; no stored SMS is removed.
        incomingSMSAssemblies = incomingSMSAssemblies.filter { now.timeIntervalSince($0.value.updatedAt) < 120 }

        var assembly: IncomingSMSAssembly
        if let existing = incomingSMSAssemblies[id] {
            guard existing.address == address, existing.parts == parts,
                  existing.timestampMs == timestampMs,
                  existing.direction.caseInsensitiveCompare(direction) == .orderedSame else {
                incomingSMSAssemblies.removeValue(forKey: id)
                log("[SMS] Conflicting metadata; discarded assembly id=\(id)")
                return
            }
            assembly = existing
        } else {
            guard incomingSMSAssemblies.count < 32 else {
                log("[SMS] Too many pending transfers; dropped id=\(id)")
                return
            }
            assembly = IncomingSMSAssembly(
                id: id, address: address, direction: direction, timestampMs: timestampMs,
                parts: parts, status: status, replay: replay,
                chunks: Array(repeating: nil, count: parts), updatedAt: now
            )
        }

        if assembly.chunks[part] == nil {
            assembly.chunks[part] = chunk
            assembly.received += 1
        }
        assembly.status = status
        assembly.replay = replay
        assembly.updatedAt = now

        guard assembly.received == assembly.parts else {
            incomingSMSAssemblies[id] = assembly
            return
        }
        incomingSMSAssemblies.removeValue(forKey: id)

        var bodyData = Data()
        for piece in assembly.chunks {
            guard let piece else { return }
            bodyData.append(piece)
            if bodyData.count > Self.smsMaxBodyBytes {
                log("[SMS] SMS body too large id=\(id)")
                return
            }
        }
        guard let body = String(data: bodyData, encoding: .utf8) else {
            log("[SMS] Invalid UTF-8 body id=\(id)")
            return
        }

        // If this is replayed bridge history, keep conversations deliberately deleted on this iPhone hidden.
        // A genuinely new (non-replay) SMS from the same sender restores that conversation.
        if assembly.replay && deletedSMSConversationAddresses.contains(address) {
            log("[SMS] Ignored replay for locally deleted conversation address=\(address)")
            return
        }
        if !assembly.replay { restoreSMSConversation(forAddress: address) }

        let previous = smsMessages.first(where: { $0.id == id })
        let incoming = direction.caseInsensitiveCompare("incoming") == .orderedSame || direction.caseInsensitiveCompare("in") == .orderedSame
        let message = CallshareSMSMessage(
            id: id, address: address, body: body, direction: direction,
            timestampMs: timestampMs, status: status,
            statusDetail: previous?.statusDetail,
            isUnread: previous?.isUnread ?? (incoming && !replay)
        )
        upsertSMS(message)

        if incoming && !replay && previous == nil {
            notifications.sendSMS(sender: address, body: body, messageID: id)
        }
        log("[SMS] Complete SMS stored id=\(id), UTF-8 bytes=\(bodyData.count), replay=\(replay)")
    }

    private func handleSMSStatus(_ payload: Data) {
        guard payload.count > 1,
              let parsed = try? JSONSerialization.jsonObject(with: Data(payload.dropFirst())),
              let object = parsed as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty else {
            log("[SMS] Invalid SMS status event")
            return
        }
        let status = object["status"] as? String ?? "unknown"
        let reason = object["reason"] as? String
        guard let index = smsMessages.firstIndex(where: { $0.id == id }) else {
            log("[SMS] Status arrived without local record id=\(id), status=\(status)")
            return
        }
        var message = smsMessages[index]
        message.status = status
        message.statusDetail = reason
        upsertSMS(message)
        log("[SMS] Status updated id=\(id), status=\(status), reason=\(reason ?? "-")")
    }

    @discardableResult
    func sendSMSReply(to address: String, body: String) -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= Self.smsMaxBodyBytes else { return false }
        guard ble.isReady else { return false }
        let normalizedAddress = Self.normalizedSMSAddress(address)
        guard !normalizedAddress.isEmpty else { return false }

        let timestampMs = Int64(Date().timeIntervalSince1970 * 1_000.0)
        let messageID = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        restoreSMSConversation(forAddress: normalizedAddress)
        let message = CallshareSMSMessage(
            id: messageID, address: normalizedAddress, body: text, direction: "outgoing",
            timestampMs: timestampMs, status: "sending", statusDetail: nil, isUnread: false
        )
        upsertSMS(message)
        guard transmitSMS(message) else {
            updateSMS(id: messageID, status: "failed", detail: "BLE disconnected or payload rejected")
            return false
        }
        scheduleSMSStatusTimeout(messageID)
        return true
    }

    @discardableResult
    func retrySMS(id: String) -> Bool {
        guard let message = smsMessages.first(where: { $0.id == id }),
              message.isOutgoing, message.status.caseInsensitiveCompare("failed") == .orderedSame,
              ble.isReady else { return false }
        updateSMS(id: id, status: "sending", detail: nil)
        guard let refreshed = smsMessages.first(where: { $0.id == id }), transmitSMS(refreshed) else {
            updateSMS(id: id, status: "failed", detail: "BLE disconnected or payload rejected")
            return false
        }
        scheduleSMSStatusTimeout(id)
        return true
    }

    func smsMessage(id: String) -> CallshareSMSMessage? {
        smsMessages.first(where: { $0.id == id })
    }

    func markSMSRead(forAddress address: String) {
        var changed = false
        for index in smsMessages.indices where smsMessages[index].address == address && smsMessages[index].isUnread {
            smsMessages[index].isUnread = false
            changed = true
        }
        if changed { persistSMSMessages() }
    }

    /// Removes a conversation from CALLSHARE's local iPhone history only.
    /// It does not send a delete command to the J7 or erase the SMS from the SIM.
    func deleteSMSConversation(forAddress address: String) {
        let canonicalAddress = Self.canonicalSMSAddress(address)
        guard !canonicalAddress.isEmpty else { return }

        deletedSMSConversationAddresses.insert(canonicalAddress)
        UserDefaults.standard.set(Array(deletedSMSConversationAddresses).sorted(), forKey: smsDeletedConversationsDefaultsKey)

        let removedIDs = Set(smsMessages.filter { Self.canonicalSMSAddress($0.address) == canonicalAddress }.map(\.id))
        smsMessages.removeAll { Self.canonicalSMSAddress($0.address) == canonicalAddress }
        incomingSMSAssemblies = incomingSMSAssemblies.filter { Self.canonicalSMSAddress($0.value.address) != canonicalAddress }
        if let pendingID = pendingSMSNavigationID, removedIDs.contains(pendingID) {
            pendingSMSNavigationID = nil
        }
        persistSMSMessages()
        log("[SMS] Deleted local conversation address=\(canonicalAddress), messages=\(removedIDs.count)")
    }

    private func restoreSMSConversation(forAddress address: String) {
        let canonicalAddress = Self.canonicalSMSAddress(address)
        guard !canonicalAddress.isEmpty, deletedSMSConversationAddresses.remove(canonicalAddress) != nil else { return }
        UserDefaults.standard.set(Array(deletedSMSConversationAddresses).sorted(), forKey: smsDeletedConversationsDefaultsKey)
    }

    private static func loadDeletedSMSConversationAddresses(forKey key: String) -> Set<String> {
        let stored = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(stored.map { canonicalSMSAddress($0) }.filter { !$0.isEmpty })
    }

    private static func canonicalSMSAddress(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizedSMSAddress(trimmed)
        return normalized.isEmpty ? trimmed : normalized
    }

    private func scheduleSMSStatusTimeout(_ messageID: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard let self,
                  let message = self.smsMessages.first(where: { $0.id == messageID }),
                  message.status.caseInsensitiveCompare("sending") == .orderedSame else { return }
            self.updateSMS(id: messageID, status: "failed", detail: "No SMS status received from J7 within 45 seconds")
        }
    }

    private func transmitSMS(_ message: CallshareSMSMessage) -> Bool {
        let bytes = Data(message.body.utf8)
        guard !bytes.isEmpty, bytes.count <= Self.smsMaxBodyBytes, ble.isReady else { return false }
        let parts = (bytes.count + Self.smsChunkBytes - 1) / Self.smsChunkBytes
        guard parts >= 1 && parts <= 512 else { return false }

        for part in 0..<parts {
            let start = part * Self.smsChunkBytes
            let end = min(bytes.count, start + Self.smsChunkBytes)
            let chunk = bytes.subdata(in: start..<end)
            let packet: [String: Any] = [
                "v": 1,
                "kind": "send",
                "id": message.id,
                "to": message.address,
                "ts": message.timestampMs,
                "part": part,
                "parts": parts,
                "chunk": chunk.base64EncodedString()
            ]
            guard let json = try? JSONSerialization.data(withJSONObject: packet, options: [.sortedKeys]),
                  json.count + 1 < 250,
                  ble.sendCallshareSMSSendChunk(json) else {
                return false
            }
        }
        return true
    }

    private func updateSMS(id: String, status: String, detail: String?) {
        guard let index = smsMessages.firstIndex(where: { $0.id == id }) else { return }
        var message = smsMessages[index]
        message.status = status
        message.statusDetail = detail
        upsertSMS(message)
    }

    private func upsertSMS(_ message: CallshareSMSMessage) {
        if let index = smsMessages.firstIndex(where: { $0.id == message.id }) {
            smsMessages[index] = message
        } else {
            smsMessages.append(message)
        }
        smsMessages.sort { $0.timestampMs > $1.timestampMs }
        if smsMessages.count > Self.smsHistoryLimit {
            smsMessages = Array(smsMessages.prefix(Self.smsHistoryLimit))
        }
        persistSMSMessages()
    }

    private func persistSMSMessages() {
        guard let data = try? JSONEncoder().encode(smsMessages) else { return }
        UserDefaults.standard.set(data, forKey: smsMessagesDefaultsKey)
    }

    private static func loadSMSMessages(forKey key: String) -> [CallshareSMSMessage] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let messages = try? JSONDecoder().decode([CallshareSMSMessage].self, from: data) else { return [] }
        return Array(messages.sorted { $0.timestampMs > $1.timestampMs }.prefix(200))
    }

    private static func normalizedSMSAddress(_ address: String) -> String {
        let clean = address.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[\s()\-]"#, with: "", options: .regularExpression)
        guard clean.range(of: #"^\+?[0-9]{3,20}$"#, options: .regularExpression) != nil else { return "" }
        return clean
    }

    private func startNetworkMonitor() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wifiConnected = path.status == .satisfied
                self.wifiStatus = wifiConnected ? "Connected" : "Disconnected"
                self.iPhoneIPv4 = Self.currentWiFiIPv4() ?? "-"
                if wifiConnected { self.announceCurrentIPv4ToJ7(force: false) }
            }
        }
        networkMonitor = monitor
        monitor.start(queue: networkQueue)
    }

    private func announceCurrentIPv4ToJ7(force: Bool) {
        guard ble.isReady else { return }
        guard let address = Self.currentWiFiIPv4() else { return }
        iPhoneIPv4 = address
        guard force || lastAnnouncedIPv4 != address else { return }
        lastAnnouncedIPv4 = address
        ble.sendCallsharePeerIPv4(address)
    }

    private static func currentWiFiIPv4() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return nil }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = start
        while let current = cursor {
            let item = current.pointee
            if String(cString: item.ifa_name) == "en0",
               let address = item.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET) {
                var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let result = String(cString: buffer)
                    if !result.hasPrefix("127.") { return result }
                }
            }
            cursor = item.ifa_next
        }
        return nil
    }

    private static func isIPv4(_ host: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, host, &address) == 1
    }

    /// Release build: diagnostics are disabled; the autoclosure keeps call-site
    /// interpolation lazy, so discarded log strings are not constructed.
    func log(_ line: @autoclosure () -> String) { }
}
