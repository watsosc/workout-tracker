import Foundation
import CoreBluetooth
import UIKit

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
    /// A device exposing the Heart Rate service is connected and subscribed (or the mock stream is on).
    @Published private(set) var isHeartRateDeviceConnected = false
    @Published private(set) var statusText = "Disconnected" {
        didSet { if statusText != oldValue { Self.log("status: \(statusText)") } }
    }

    /// Devices already logged during this scan (diagnostics only).
    private var loggedDevices: Set<UUID> = []

    nonisolated static func log(_ message: String) {
        print("[HR] \(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(message)")
    }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var heartRateCharacteristic: CBCharacteristic?

    /// Receives every sample; the workout store keeps them with the on-device workout.
    private var onSample: (@MainActor (Int, Date) -> Void)?
    private var isActive = false
    private var receiveExpiryTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var mockTask: Task<Void, Never>?
    /// Sensors that failed or timed out on connect; skipped for a while so another can be tried.
    private var recentlyFailed: [UUID: Date] = [:]

    private let heartRateServiceUUID = CBUUID(string: "180D")
    private let heartRateMeasurementUUID = CBUUID(string: "2A37")

    func start(onSample: @escaping @MainActor (Int, Date) -> Void) {
        self.onSample = onSample
        guard !isActive else { return }
        isActive = true

        if shouldUseMockHeartRate {
            statusText = "Mock heart-rate stream"
            isHeartRateDeviceConnected = true
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
        isActive = false
        onSample = nil
        receiveExpiryTask?.cancel()
        receiveExpiryTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        mockTask?.cancel()
        mockTask = nil

        if central?.state == .poweredOn {
            central?.stopScan()
        }
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        heartRateCharacteristic = nil
        isHeartRateDeviceConnected = false

        latestBpm = nil
        samples = []
        isReceivingData = false
        statusText = "Disconnected"
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
            statusText = "Connected, no recent data"
        }
    }

    /// Drops the current sensor (if any) and looks for one again. Used by the "retry" tap.
    func reconnect() {
        guard isActive, !shouldUseMockHeartRate else { return }
        Self.log("manual retry")
        recentlyFailed.removeAll()
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        resetPeripheral()
        startScanningIfReady()
    }

    private func resetPeripheral() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        peripheral = nil
        heartRateCharacteristic = nil
        isHeartRateDeviceConnected = false
        isReceivingData = false
    }

    private func startScanningIfReady() {
        guard let central else { return }
        guard isActive, peripheral == nil else { return }
        guard central.state == .poweredOn else {
            statusText = bluetoothStateText(central.state)
            return
        }

        // A sensor already connected to the phone (paired in iOS Settings, or held by another app
        // such as Garmin Connect) stops advertising, so scanning alone never finds it.
        let connected = central.retrieveConnectedPeripherals(withServices: [heartRateServiceUUID])
        if let existing = connected.first(where: { !isRecentlyFailed($0) }) ?? connected.first {
            connect(to: existing)
            return
        }

        Self.log("connected HR peripherals from system: \(connected.map { $0.name ?? $0.identifier.uuidString })")
        statusText = "Scanning for heart-rate sensor"
        loggedDevices.removeAll()
        // In the foreground scan everything and match on the advertised Heart Rate service ourselves
        // (also logs what's nearby). Background scans must name a service.
        let foreground = UIApplication.shared.applicationState == .active
        central.scanForPeripherals(
            withServices: foreground ? nil : [heartRateServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func connect(to peripheral: CBPeripheral) {
        guard let central else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        statusText = "Connecting to \(peripheral.name ?? "HR sensor")"
        if central.isScanning { central.stopScan() }
        central.connect(peripheral)

        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, self.peripheral === peripheral, !self.isHeartRateDeviceConnected else { return }
            self.recentlyFailed[peripheral.identifier] = Date()
            self.central?.cancelPeripheralConnection(peripheral)
            self.resetPeripheral()
            self.statusText = "Couldn't connect to \(peripheral.name ?? "HR sensor"), retrying"
            self.startScanningIfReady()
        }
    }

    private func isRecentlyFailed(_ peripheral: CBPeripheral) -> Bool {
        guard let failedAt = recentlyFailed[peripheral.identifier] else { return false }
        return Date().timeIntervalSince(failedAt) < 30
    }

    private func bluetoothStateText(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "Bluetooth ready"
        case .poweredOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth permission denied. Allow it in Settings"
        case .unsupported: return "Bluetooth unsupported"
        case .resetting: return "Bluetooth resetting"
        default: return "Bluetooth unavailable"
        }
    }

    private func enqueueSample(_ bpm: Int, at date: Date) {
        latestBpm = bpm
        samples.append(LiveHeartRateSample(timestamp: date, bpm: bpm))
        if samples.count > 120 {
            samples.removeFirst(samples.count - 120)
        }

        onSample?(bpm, date)
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
            statusText = bluetoothStateText(central.state)
            if central.state == .poweredOn {
                startScanningIfReady()
            } else {
                // Connections are gone when Bluetooth goes off; start over when it comes back.
                resetPeripheral()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        Task { @MainActor in
            if services.contains(heartRateServiceUUID), loggedDevices.insert(peripheral.identifier).inserted {
                Self.log("found HR sensor: \(name ?? "?") rssi=\(RSSI)")
            }
            guard services.contains(heartRateServiceUUID) else { return }
            guard isActive, self.peripheral == nil, !isRecentlyFailed(peripheral) else { return }
            connect(to: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            statusText = "Connected to \(peripheral.name ?? "HR sensor")"
            peripheral.discoverServices([heartRateServiceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            guard self.peripheral === peripheral else { return }
            Self.log("didFailToConnect \(peripheral.name ?? "?"): \(error?.localizedDescription ?? "no error")")
            recentlyFailed[peripheral.identifier] = Date()
            resetPeripheral()
            statusText = "Couldn't connect to \(peripheral.name ?? "HR sensor"), retrying"
            startScanningIfReady()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            Self.log("didDisconnect \(peripheral.name ?? "?"): \(error?.localizedDescription ?? "no error")")
            guard self.peripheral === peripheral else { return }
            resetPeripheral()
            guard isActive else { return }
            statusText = "Disconnected, scanning"
            startScanningIfReady()
        }
    }
}

extension HeartRateBluetoothManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            Self.log("services on \(peripheral.name ?? "?") id=\(peripheral.identifier.uuidString.prefix(8)): \(peripheral.services?.map(\.uuid.uuidString) ?? []) error=\(error?.localizedDescription ?? "none")")
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
            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            isHeartRateDeviceConnected = true
            statusText = "Connected to \(peripheral.name ?? "HR sensor"), waiting for data"
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Self.log("notify state for \(characteristic.uuid): \(characteristic.isNotifying) error=\(error?.localizedDescription ?? "none")")
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard error == nil else {
                Self.log("value error: \(error!.localizedDescription)")
                return
            }
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
