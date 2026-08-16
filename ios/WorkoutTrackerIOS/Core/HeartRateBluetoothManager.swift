import Foundation
import CoreBluetooth

struct LiveHeartRateSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let bpm: Int
}

@MainActor
final class HeartRateBluetoothManager: NSObject, ObservableObject {
    @Published private(set) var samples: [LiveHeartRateSample] = []
    @Published private(set) var latestBpm: Int?
    @Published private(set) var isReceivingData = false
    @Published private(set) var statusText = "Disconnected"

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var heartRateCharacteristic: CBCharacteristic?

    private var activeSessionId: Int?
    private var api: WorkoutAPI?
    private var pendingUpload: [[String: Any]] = []
    private var uploadTask: Task<Void, Never>?
    private var receiveExpiryTask: Task<Void, Never>?
    private var mockTask: Task<Void, Never>?

    private let heartRateServiceUUID = CBUUID(string: "180D")
    private let heartRateMeasurementUUID = CBUUID(string: "2A37")
    private let sourceName = "GARMIN_BLE"
    private let iso = ISO8601DateFormatter()

    override init() {
        super.init()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func start(for sessionId: Int, api: WorkoutAPI) {
        activeSessionId = sessionId
        self.api = api
        startUploadLoop()

        if shouldUseMockHeartRate {
            statusText = "Mock heart-rate stream"
            startMockStream()
            return
        }

        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
        } else {
            startScanningIfReady()
        }
    }

    func stop() {
        flushPendingUpload()

        uploadTask?.cancel()
        uploadTask = nil
        receiveExpiryTask?.cancel()
        receiveExpiryTask = nil
        mockTask?.cancel()
        mockTask = nil

        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        heartRateCharacteristic = nil
        activeSessionId = nil

        latestBpm = nil
        samples = []
        isReceivingData = false
        statusText = "Disconnected"
    }

    private func startUploadLoop() {
        uploadTask?.cancel()
        uploadTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await flushPendingUploadIfNeeded()
            }
        }
    }

    private var shouldUseMockHeartRate: Bool {
        let env = ProcessInfo.processInfo.environment["WORKOUT_MOCK_HEART_RATE"]
        if env == "1" || env?.lowercased() == "true" { return true }
        return UserDefaults.standard.bool(forKey: "workout.ios.mock-heart-rate")
    }

    private func startMockStream() {
        mockTask?.cancel()
        mockTask = Task {
            var index = 0
            while !Task.isCancelled {
                let bpm = mockBpm(index: index)
                let now = Date()
                enqueueSample(bpm, at: now)
                markReceiving()
                index += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func mockBpm(index: Int) -> Int {
        let baseline = 107.5
        let amplitude = 27.5
        let value = baseline + amplitude * sin(Double(index) * 0.33)
        return max(80, min(135, Int(value.rounded())))
    }

    private func markReceiving() {
        isReceivingData = true
        statusText = "Receiving heart rate"
        receiveExpiryTask?.cancel()
        receiveExpiryTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            isReceivingData = false
            statusText = "Connected (no recent samples)"
        }
    }

    private func startScanningIfReady() {
        guard let central else { return }
        guard activeSessionId != nil else { return }
        guard central.state == .poweredOn else {
            statusText = "Bluetooth unavailable"
            return
        }

        statusText = "Scanning for Garmin/HR sensor"
        central.scanForPeripherals(withServices: [heartRateServiceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func enqueueSample(_ bpm: Int, at date: Date) {
        latestBpm = bpm
        samples.append(LiveHeartRateSample(timestamp: date, bpm: bpm))
        if samples.count > 120 {
            samples.removeFirst(samples.count - 120)
        }

        pendingUpload.append([
            "recordedAt": iso.string(from: date),
            "bpm": bpm,
            "source": sourceName
        ])

        if pendingUpload.count >= 24 {
            Task { await flushPendingUploadIfNeeded() }
        }
    }

    private func flushPendingUpload() {
        guard let sessionId = activeSessionId, let api else { return }
        let payload = pendingUpload
        pendingUpload = []
        guard !payload.isEmpty else { return }

        Task {
            do {
                _ = try await api.appendHeartRateSamples(sessionId: sessionId, samples: payload)
            } catch {
                await MainActor.run {
                    pendingUpload.insert(contentsOf: payload, at: 0)
                    if pendingUpload.count > 500 {
                        pendingUpload = Array(pendingUpload.suffix(500))
                    }
                }
            }
        }
    }

    private func flushPendingUploadIfNeeded(force: Bool = false) async {
        guard let sessionId = activeSessionId, let api else { return }
        guard force || pendingUpload.count >= 10 else { return }

        let payload = pendingUpload
        pendingUpload = []

        do {
            _ = try await api.appendHeartRateSamples(sessionId: sessionId, samples: payload)
        } catch {
            pendingUpload.insert(contentsOf: payload, at: 0)
            if pendingUpload.count > 500 {
                pendingUpload = Array(pendingUpload.suffix(500))
            }
        }
    }

    private func parseHeartRate(from data: Data) -> Int? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data)
        let flags = bytes[0]
        let isUInt16 = (flags & 0x01) != 0

        if isUInt16 {
            guard bytes.count >= 3 else { return nil }
            return Int(UInt16(bytes[1]) | (UInt16(bytes[2]) << 8))
        }

        guard bytes.count >= 2 else { return nil }
        return Int(bytes[1])
    }
}

extension HeartRateBluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                statusText = "Bluetooth ready"
                startScanningIfReady()
            case .poweredOff:
                statusText = "Bluetooth is off"
            case .unauthorized:
                statusText = "Bluetooth permission denied"
            case .unsupported:
                statusText = "Bluetooth unsupported"
            default:
                statusText = "Bluetooth unavailable"
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            guard self.peripheral == nil else { return }
            self.peripheral = peripheral
            peripheral.delegate = self
            statusText = "Connecting to \(peripheral.name ?? "HR sensor")"
            central.stopScan()
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            statusText = "Connected to \(peripheral.name ?? "HR sensor")"
            peripheral.discoverServices([heartRateServiceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.peripheral = nil
            self.heartRateCharacteristic = nil
            isReceivingData = false
            statusText = "Disconnected, scanning..."
            startScanningIfReady()
        }
    }
}

extension HeartRateBluetoothManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard error == nil else {
                statusText = "Failed to discover services"
                return
            }
            guard let service = peripheral.services?.first(where: { $0.uuid == heartRateServiceUUID }) else {
                statusText = "Heart-rate service not found"
                return
            }
            peripheral.discoverCharacteristics([heartRateMeasurementUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard error == nil else {
                statusText = "Failed to discover characteristics"
                return
            }
            guard let characteristic = service.characteristics?.first(where: { $0.uuid == heartRateMeasurementUUID }) else {
                statusText = "Heart-rate characteristic not found"
                return
            }
            heartRateCharacteristic = characteristic
            peripheral.setNotifyValue(true, for: characteristic)
            statusText = "Waiting for heart-rate data"
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard error == nil else { return }
            guard characteristic.uuid == heartRateMeasurementUUID else { return }
            guard let data = characteristic.value else { return }
            guard let bpm = parseHeartRate(from: data), bpm >= 20, bpm <= 255 else { return }

            mockTask?.cancel()
            mockTask = nil

            let now = Date()
            enqueueSample(bpm, at: now)
            markReceiving()
        }
    }
}
