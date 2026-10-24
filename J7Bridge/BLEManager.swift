import Foundation
import CoreBluetooth
import Darwin

final class BLEManager: NSObject, ObservableObject {
    private var central: CBCentralManager!
    private(set) var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?
    private var flowChar: CBCharacteristic?
    private var txChar: CBCharacteristic?

    private var rxParser = K7Protocol.StreamParser()
    private var rxNotifyEnabled = false
    private var audioWriteType: CBCharacteristicWriteType = .withoutResponse
    private var audioTXQueue: [Data] = []
    private let maxQueuedAudioFrames = 100
    private var audioTXCount = 0
    private var audioTXBackpressureEvents = 0
    private var audioTXQueueDrops = 0
    private var audioRXCount = 0
    private var rxValueCount = 0

    var onStatus: ((String) -> Void)?
    var onDevice: ((String?) -> Void)?
    var onControlPayload: ((Data) -> Void)?
    var onAudioPayload: ((Data) -> Void)?
    var onReady: (() -> Void)?

    private var readyNotified = false

    // Serialize write-with-response control frames. In particular, VOICE_CLOSE
    // must complete before HANGUP is sent, so the call-end opcode is not raced
    // by the preceding audio-gate control write.
    private var controlTXQueue: [(frame: Data, retries: Int)] = []
    private var controlWriteInFlight = false
    private var inFlightControlWrite: (frame: Data, retries: Int)?

    var isReady: Bool { peripheral?.state == .connected && txChar != nil && rxNotifyEnabled }

    var autoReconnect = true
    private var reconnectWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: "com.ugur.callshare.callendlogr1.ble-central.r1",
                CBCentralManagerOptionShowPowerAlertKey: true
            ]
        )
    }

    func startScan() {
        guard peripheral == nil else {
            log("[BLE] scan skipped; a peripheral is already assigned")
            return
        }
        guard central.state == .poweredOn else {
            log("[BLE] Bluetooth not ready: \(central.state.rawValue)")
            return
        }
        central.stopScan()
        onStatus?("Scanning")
        log("[BLE] Scanning for IKOS K7 service")
        central.scanForPeripherals(withServices: [K7Protocol.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func disconnect() {
        reconnectWorkItem?.cancel()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        resetTransportState()
        onStatus?("Disconnected")
    }

    func sendAnswer() { sendControl(Data([K7Protocol.cmdAnswer])) }

    /// Sends this iPhone's current Wi-Fi IPv4 to our companion Android app.
    /// Opcode 0xE7 is a CALLSHARE-owned extension; never send it to a stock K7 dongle.
    func sendCallsharePeerIPv4(_ address: String) {
        let cleaned = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsed = in_addr()
        guard inet_pton(AF_INET, cleaned, &parsed) == 1 else {
            log("[BLE] CALLSHARE peer IPv4 rejected: \(cleaned)")
            return
        }
        sendControl(Data([K7Protocol.cmdCallsharePeerIPv4]) + Data(cleaned.utf8))
        log("[BLE] CALLSHARE peer IPv4 sent \(cleaned)")
    }

    /// Sends one chunk of a CALLSHARE SMS payload using the existing serialized
    /// BLE control queue. The complete C0-delimited frame is split into writes
    /// no larger than CoreBluetooth's negotiated maximum; Android's FrameStream
    /// reassembles these ordered writes before dispatching opcode 0xE9.
    @discardableResult
    func sendCallshareSMSSendChunk(_ json: Data) -> Bool {
        guard isReady, json.count < 250,
              let p = peripheral, p.state == .connected, txChar != nil else { return false }

        let frame = K7Protocol.wrapControl(Data([K7Protocol.cmdCallshareSendSMSChunk]) + json)
        let maximumWrite = p.maximumWriteValueLength(for: .withResponse)
        guard maximumWrite > 0 else { return false }

        var offset = 0
        while offset < frame.count {
            let end = min(frame.count, offset + maximumWrite)
            controlTXQueue.append((frame: Data(frame[offset..<end]), retries: 0))
            offset = end
        }
        flushControlTX()
        return true
    }

    private func notifyReadyIfPossible() {
        guard !readyNotified, peripheral?.state == .connected, txChar != nil, rxNotifyEnabled else { return }
        readyNotified = true
        log("[BLE] GATT CONTROL READY (TX + RX notify)")
        onReady?()
    }
    func sendHangup() { sendControl(Data([K7Protocol.cmdHangup])) }

    func sendVoiceOpen() {
        sendControl(Data([K7Protocol.evtVoiceOpen]))
        log("[VOICE] OPEN requested")
    }

    func sendVoiceClose() {
        audioTXQueue.removeAll(keepingCapacity: true)
        sendControl(Data([K7Protocol.evtVoiceClose]))
        log("[VOICE] CLOSE requested; audio queue cleared")
    }

    @discardableResult
    func sendMakeCall(number: String, simId: UInt8) -> Bool {
        // CallKit may begin the UI while CoreBluetooth is restoring the GATT link.
        // The caller can hold this specific dial request and retry it from onReady.
        guard isReady, let connectedPeripheral = peripheral,
              connectedPeripheral.state == .connected, txChar != nil else {
            log("[BLE] MAKE_CALL deferred: GATT control channel is not ready")
            return false
        }
        sendControl(K7Protocol.makeCallPayload(number: number, simId: simId))
        return true
    }

    func sendDTMF(_ value: UInt8) {
        sendControl(K7Protocol.dtmfPayload(value))
    }

    func requestDeviceCheck() { sendControl(Data([K7Protocol.cmdDevCheck])) }
    func requestBattery() { sendControl(Data([K7Protocol.cmdReadBattery])) }
    func requestFirmware() { sendControl(Data([K7Protocol.cmdFirmwareVersion])) }
    func requestIMEI() { sendControl(Data([K7Protocol.cmdIMEIInfo])) }
    func requestCurrentCall() { sendControl(Data([K7Protocol.cmdGetCurrentCall])) }

    /// Queue every AMR frame and honor CoreBluetooth's no-response write
    /// backpressure. The old implementation wrote blindly; on a busy link
    /// that can silently lose a large part of the 50-fps voice stream.
    func sendAudio(_ amr: Data) {
        guard !amr.isEmpty else { return }
        guard let toc = amr.first else { return }
        let frameType = Int((toc >> 3) & 0x0F)
        let expectedLengths = [13, 14, 16, 18, 20, 21, 27, 32, 6, 7, 6, 6, 0, 0, 0, 1]
        guard frameType < expectedLengths.count,
              expectedLengths[frameType] == amr.count else {
            audioTXQueueDrops += 1
            if audioTXQueueDrops == 1 || audioTXQueueDrops % 25 == 0 {
                log("[BLE] AUDIO TX rejected invalid AMR len=\(amr.count) ft=\(frameType)")
            }
            return
        }

        let frame = K7Protocol.wrapAudio(amr)
        audioTXQueue.append(frame)
        if audioTXQueue.count > maxQueuedAudioFrames {
            // Preserve low latency: drop the oldest frame instead of allowing
            // an ever-growing queue to turn a live call into delayed audio.
            audioTXQueue.removeFirst(audioTXQueue.count - maxQueuedAudioFrames)
            audioTXQueueDrops += 1
            if audioTXQueueDrops == 1 || audioTXQueueDrops % 25 == 0 {
                log("[BLE] AUDIO TX queue overflow; dropped oldest frames")
            }
        }

        if peripheral == nil || txChar == nil {
            if audioTXQueue.count == 1 || audioTXQueue.count % 25 == 0 {
                log("[BLE] AUDIO TX queued waiting for BLE TX characteristic count=\(audioTXQueue.count)")
            }
            return
        }
        flushAudioTX()
    }

    private func sendControl(_ payload: Data) {
        guard peripheral != nil, txChar != nil else { return }
        controlTXQueue.append((frame: K7Protocol.wrapControl(payload), retries: 0))
        flushControlTX()
    }

    private func flushControlTX() {
        guard !controlWriteInFlight,
              let p = peripheral,
              p.state == .connected,
              let tx = txChar,
              !controlTXQueue.isEmpty else { return }

        let item = controlTXQueue.removeFirst()
        if tx.properties.contains(.write) {
            controlWriteInFlight = true
            inFlightControlWrite = item
            p.writeValue(item.frame, for: tx, type: .withResponse)
        } else if tx.properties.contains(.writeWithoutResponse) {
            // Keep compatibility with peers that expose only no-response writes.
            p.writeValue(item.frame, for: tx, type: .withoutResponse)
            DispatchQueue.main.async { [weak self] in self?.flushControlTX() }
        }
    }

    private func flushAudioTX() {
        guard let p = peripheral, let tx = txChar, p.state == .connected else { return }

        if audioWriteType == .withoutResponse {
            while !audioTXQueue.isEmpty && p.canSendWriteWithoutResponse {
                let frame = audioTXQueue.removeFirst()
                p.writeValue(frame, for: tx, type: .withoutResponse)
                audioTXCount += 1
                if audioTXCount == 1 || audioTXCount % 25 == 0 {
                    log("[BLE] AUDIO TX #\(audioTXCount) len=\(frame.count) queue=\(audioTXQueue.count) HEX=\(K7Protocol.hex(frame))")
                }
            }

            if !audioTXQueue.isEmpty {
                audioTXBackpressureEvents += 1
                if audioTXBackpressureEvents == 1 || audioTXBackpressureEvents % 25 == 0 {
                    log("[BLE] AUDIO TX backpressure queue=\(audioTXQueue.count)")
                }
            }
        } else {
            // Fallback for unusual peers that expose only write-with-response.
            // It is slower but guarantees delivery semantics.
            while !audioTXQueue.isEmpty {
                let frame = audioTXQueue.removeFirst()
                p.writeValue(frame, for: tx, type: .withResponse)
                audioTXCount += 1
                if audioTXCount == 1 || audioTXCount % 25 == 0 {
                    log("[BLE] AUDIO TX(response) #\(audioTXCount) len=\(frame.count) queue=\(audioTXQueue.count)")
                }
            }
        }
    }

    private func resetTransportState() {
        peripheral = nil
        rxChar = nil
        flowChar = nil
        txChar = nil
        rxNotifyEnabled = false
        readyNotified = false
        audioWriteType = .withoutResponse
        rxParser.reset()
        audioTXQueue.removeAll(keepingCapacity: true)
        controlTXQueue.removeAll(keepingCapacity: true)
        controlWriteInFlight = false
        inFlightControlWrite = nil
        audioRXCount = 0
        rxValueCount = 0
        audioTXCount = 0
        audioTXBackpressureEvents = 0
        audioTXQueueDrops = 0
    }

    private func scheduleReconnect() {
        guard autoReconnect, peripheral == nil else { return }
        reconnectWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.startScan() }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    // Release build: diagnostic messages are disabled and constructed lazily.
    private func log(_ value: @autoclosure () -> String) { }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("[BLE] state=\(central.state.rawValue)")
        if central.state == .poweredOn { startScan() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if self.peripheral != nil { return }
        self.peripheral = peripheral
        onDevice?(peripheral.name)
        log("[BLE] FOUND \(peripheral.name ?? "IKOS K7") RSSI=\(RSSI)")
        central.stopScan()
        onStatus?("Connecting")
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let restoredPeripheral = restored.first else {
            log("[BLE] state restoration callback had no peripheral")
            return
        }
        peripheral = restoredPeripheral
        restoredPeripheral.delegate = self
        onDevice?(restoredPeripheral.name)
        log("[BLE] RESTORED peripheral=\(restoredPeripheral.name ?? "IKOS K7") state=\(restoredPeripheral.state.rawValue)")
        if restoredPeripheral.state == .connected {
            onStatus?("Connected")
            restoredPeripheral.discoverServices([K7Protocol.service])
        } else {
            central.connect(restoredPeripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onStatus?("Connected")
        rxParser.reset()
        log("[BLE] CONNECTED")
        peripheral.discoverServices([K7Protocol.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("[BLE] CONNECT FAIL \(error?.localizedDescription ?? "unknown")")
        resetTransportState()
        onStatus?("Disconnected")
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("[BLE] DISCONNECTED \(error?.localizedDescription ?? "")")
        resetTransportState()
        onStatus?("Disconnected")
        scheduleReconnect()
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            log("[BLE] service discovery error \(error!)")
            return
        }
        peripheral.services?.forEach { service in
            log("[BLE] SERVICE \(service.uuid)")
            guard service.uuid == K7Protocol.service else { return }
            peripheral.discoverCharacteristics([K7Protocol.rx, K7Protocol.flow, K7Protocol.tx], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            log("[BLE] characteristic discovery error \(error!)")
            return
        }
        guard service.uuid == K7Protocol.service else { return }

        service.characteristics?.forEach { characteristic in
            switch characteristic.uuid {
            case K7Protocol.rx:
                rxChar = characteristic
                log("[BLE] RX 5CB8 props=\(characteristic.properties)")
                rxParser.reset()
                peripheral.setNotifyValue(true, for: characteristic)
            case K7Protocol.flow:
                flowChar = characteristic
                log("[BLE] FLOW 5CB9 props=\(characteristic.properties)")
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            case K7Protocol.tx:
                txChar = characteristic
                if characteristic.properties.contains(.writeWithoutResponse) {
                    audioWriteType = .withoutResponse
                } else if characteristic.properties.contains(.write) {
                    audioWriteType = .withResponse
                }
                log("[BLE] TX 5CBA props=\(characteristic.properties) audioWriteType=\(audioWriteType == .withoutResponse ? "WITHOUT_RESPONSE" : "WITH_RESPONSE") maxWriteNoResp=\(peripheral.maximumWriteValueLength(for: .withoutResponse))")
                flushAudioTX()
            default:
                break
            }
        }
        notifyReadyIfPossible()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let enabled = characteristic.isNotifying
        if characteristic.uuid == K7Protocol.rx {
            rxNotifyEnabled = enabled
        }
        log("[BLE] notify \(characteristic.uuid) enabled=\(enabled) error=\(error?.localizedDescription ?? "none")")
        notifyReadyIfPossible()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == K7Protocol.tx, controlWriteInFlight else { return }

        let completed = inFlightControlWrite
        controlWriteInFlight = false
        inFlightControlWrite = nil

        if error != nil, let completed, completed.retries < 1, peripheral.state == .connected {
            // One bounded retry for transient GATT write failures; no unbounded loop.
            controlTXQueue.insert((frame: completed.frame, retries: completed.retries + 1), at: 0)
        }
        flushControlTX()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        log("[BLE] readyForNoResponseWrite queue=\(audioTXQueue.count)")
        flushAudioTX()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else {
            log("[BLE] RX error \(error?.localizedDescription ?? "no data")")
            return
        }

        guard characteristic.uuid == K7Protocol.rx else {
            // FLOW is a separate control/credit characteristic; do not feed its
            // payload through the channel-3 parser as if it were audio/control.
            if characteristic.uuid == K7Protocol.flow {
                log("[BLE] FLOW RX \(K7Protocol.hex(data))")
            }
            return
        }

        for parsed in rxParser.feed(data) {
            if parsed.channel == 3 {
                audioRXCount += 1
                onAudioPayload?(parsed.payload)
            } else {
                log("[BLE] CONTROL RX ch=\(parsed.channel) len=\(parsed.payload.count) HEX=\(K7Protocol.hex(parsed.payload))")
                onControlPayload?(parsed.payload)
            }
        }
    }
}
