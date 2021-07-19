//
//  Libre2ConnectionService.swift
//  LibreDirectPlayground
//
//  Created by Reimar Metzen on 06.07.21.
//

import Foundation
import Combine
import CoreBluetooth

class SensorConnectionService: NSObject, SensorConnectionProtocol {
    private let expectedBufferSize = 46
    private var rxBuffer = Data()

    private var updateSubject = PassthroughSubject<SensorUpdate, Never>()

    private var manager: CBCentralManager! = nil
    private let managerQueue: DispatchQueue = DispatchQueue(label: "libre-direct.ble-queue") // , qos: .unspecified

    private var abbottServiceUuid: [CBUUID] = [CBUUID(string: "FDE3")]
    private var bleLoginUuid: CBUUID = CBUUID(string: "F001")
    private var compositeRawDataUuid: CBUUID = CBUUID(string: "F002")
    private var libre3DataUuid = CBUUID(string: "089810CC-EF89-11E9-81B4-2A2AE2DBCCE4")

    private var readCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?

    private var stayConnected = false
    private var sensor: Sensor? = nil

    private var peripheral: CBPeripheral? {
        didSet {
            oldValue?.delegate = nil
            peripheral?.delegate = self
        }
    }

    override init() {
        super.init()

        manager = CBCentralManager(delegate: self, queue: managerQueue, options: nil)
    }

    func subscribeForUpdates() -> AnyPublisher<SensorUpdate, Never> {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        return updateSubject.eraseToAnyPublisher()
    }

    func connectSensor(sensor: Sensor) {
        print("SensorConnectionService connectSensor")
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        self.sensor = sensor

        managerQueue.async {
            self.scan()
        }
    }

    func disconnectSensor() {
        print("SensorConnectionService disconnectSensor")
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        self.sensor = nil

        managerQueue.sync {
            self.disconnect()
        }
    }

    private func scan() {
        print("SensorConnectionService scan")
        dispatchPrecondition(condition: .onQueue(managerQueue))

        guard sensor != nil else {
            return
        }

        setStayConnected(stayConnected: true)

        guard manager.state == .poweredOn else {
            return
        }

        if manager.isScanning {
            manager.stopScan()
        }

        sendUpdate(connectionState: .scanning)
        manager.scanForPeripherals(withServices: nil, options: nil) // abbottServiceUuid
    }

    private func disconnect() {
        print("SensorConnectionService disconnect")
        dispatchPrecondition(condition: .onQueue(managerQueue))

        setStayConnected(stayConnected: false)

        if manager.isScanning {
            manager.stopScan()
        }

        if let peripheral = peripheral {
            manager.cancelPeripheralConnection(peripheral)
        } else {
            sendUpdate(connectionState: .disconnected)
        }
    }

    private func connect(_ peripheral: CBPeripheral) {
        print("SensorConnectionService connect")
        dispatchPrecondition(condition: .onQueue(managerQueue))

        if manager.isScanning {
            manager.stopScan()
        }

        self.peripheral = peripheral

        sendUpdate(connectionState: .connecting)
        manager.connect(peripheral, options: nil)
    }

    private func unlock() -> Data? {
        print("SensorConnectionService unlock")
        dispatchPrecondition(condition: .onQueue(managerQueue))

        if sensor == nil {
            return nil
        }

        sensor!.unlockCount = sensor!.unlockCount + 1

        let unlockPayload = Libre2.streamingUnlockPayload(sensorUID: sensor!.uuid, info: sensor!.patchInfo, enableTime: 42, unlockCount: UInt16(sensor!.unlockCount))
        return Data(unlockPayload)
    }

    private func resetBuffer() {
        print("SensorConnectionService resetBuffer")
        dispatchPrecondition(condition: .onQueue(managerQueue))

        rxBuffer = Data()
    }

    private func setStayConnected(stayConnected: Bool) {
        print("SensorConnectionService setStayConnected \(stayConnected.description)")
        dispatchPrecondition(condition: .onQueue(managerQueue))

        self.stayConnected = stayConnected
    }

    private func sendUpdate(connectionState: SensorConnectionState) {
        print("SensorConnectionService sendUpdate \(connectionState.description)")
        dispatchPrecondition(condition: .onQueue(managerQueue))

        updateSubject.send(SensorConnectionUpdate(connectionState: connectionState))
    }

    private func sendUpdate(sensorAge: Int) {
        print("SensorConnectionService sendUpdate \(sensorAge.description)")
        dispatchPrecondition(condition: .onQueue(managerQueue))

        updateSubject.send(SensorAgeUpdate(sensorAge: sensorAge))
    }

    private func sendUpdate(glucoseTrend: [SensorGlucose]) {
        print("SensorConnectionService sendUpdate \(glucoseTrend.description)")
        dispatchPrecondition(condition: .onQueue(managerQueue))

        updateSubject.send(SensorReadingUpdate(glucoseTrend: glucoseTrend))
    }

    private func sendUpdate(error: Error?) {
        print("SensorConnectionService sendUpdate \(error?.localizedDescription ?? "")")
        dispatchPrecondition(condition: .onQueue(managerQueue))

        guard let error = error else {
            return
        }

        sendUpdate(errorMessage: error.localizedDescription)
    }

    private func sendUpdate(errorMessage: String) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        updateSubject.send(SensorErrorUpdate(errorMessage: errorMessage))
    }

    private func sendUpdate(errorCode: Int) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        updateSubject.send(SensorErrorUpdate(errorCode: errorCode))
    }
}

extension SensorConnectionService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("CBCentralManagerDelegate didUpdateState: \(manager.state.rawValue)")
        dispatchPrecondition(condition: .onQueue(managerQueue))

        switch manager.state {
        case .poweredOff:
            sendUpdate(connectionState: .powerOff)

        case .poweredOn:
            sendUpdate(connectionState: .disconnected)

            if stayConnected {
                scan()
            }
        default:
            sendUpdate(connectionState: .unknown)

        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        print("CBCentralManagerDelegate didDiscover: \(peripheral.name?.description ?? "-")")
        dispatchPrecondition(condition: .onQueue(managerQueue))

        guard let sensor = sensor, let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else {
            return
        }

        if manufacturerData.count == 8 {
            var foundUUID = manufacturerData.subdata(in: 2..<8)
            foundUUID.append(contentsOf: [0x07, 0xe0])

            let result = foundUUID == sensor.uuid && peripheral.name?.lowercased().starts(with: "abbott") ?? false
            if result {
                connect(peripheral)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("CBCentralManagerDelegate didConnect: \(peripheral.name?.description ?? "-")")
        dispatchPrecondition(condition: .onQueue(managerQueue))

        peripheral.discoverServices(abbottServiceUuid)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("CBCentralManagerDelegate didFailToConnect: \(peripheral.name?.description ?? "-")")
        print("CBCentralManagerDelegate didFailToConnect with error: \(error?.localizedDescription ?? "-")")
        dispatchPrecondition(condition: .onQueue(managerQueue))

        sendUpdate(connectionState: .disconnected)
        sendUpdate(error: error)

        guard stayConnected else {
            return
        }

        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("CBCentralManagerDelegate didDisconnectPeripheral: \(peripheral.name?.description ?? "-")")
        print("CBCentralManagerDelegate didDisconnectPeripheral with error: \(error?.localizedDescription ?? "-")")
        dispatchPrecondition(condition: .onQueue(managerQueue))

        sendUpdate(connectionState: .disconnected)
        sendUpdate(error: error)

        guard stayConnected else {
            return
        }

        connect(peripheral)
    }
}

extension SensorConnectionService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        print("CBCentralManagerDelegate didDiscoverServices: \(peripheral.name?.description ?? "-")")
        print("CBCentralManagerDelegate didDiscoverServices with error: \(error?.localizedDescription ?? "-")")
        dispatchPrecondition(condition: .onQueue(managerQueue))

        sendUpdate(error: error)

        if let services = peripheral.services {
            for service in services {
                print("CBCentralManagerDelegate didDiscoverServices with service: \(service.uuid)")
                
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        print("CBCentralManagerDelegate didDiscoverCharacteristicsFor: \(peripheral.name?.description ?? "-")")
        print("CBCentralManagerDelegate didDiscoverCharacteristicsFor with error: \(error?.localizedDescription ?? "-")")
        dispatchPrecondition(condition: .onQueue(managerQueue))

        sendUpdate(error: error)

        if let characteristics = service.characteristics {
            for characteristic in characteristics {
                print("CBCentralManagerDelegate didDiscoverCharacteristicsFor with uuid: \(characteristic.uuid.description)")
                
                if characteristic.uuid == compositeRawDataUuid {
                    readCharacteristic = characteristic
                }

                if characteristic.uuid == bleLoginUuid {
                    writeCharacteristic = characteristic

                    if let unlock = unlock() {
                        peripheral.writeValue(unlock, for: characteristic, type: .withResponse)
                    }
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        print("CBCentralManagerDelegate didUpdateNotificationStateFor: \(peripheral.name?.description ?? "-")")
        print("CBCentralManagerDelegate didUpdateNotificationStateFor with error: \(error?.localizedDescription ?? "-")")
        dispatchPrecondition(condition: .onQueue(managerQueue))

        sendUpdate(error: error)
        sendUpdate(connectionState: .connected)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        print("CBCentralManagerDelegate didWriteValueFor: \(peripheral.name?.description ?? "-")")
        print("CBCentralManagerDelegate didWriteValueFor with error: \(error?.localizedDescription ?? "-")")
        dispatchPrecondition(condition: .onQueue(managerQueue))

        sendUpdate(error: error)

        if characteristic.uuid == bleLoginUuid {
            peripheral.setNotifyValue(true, for: readCharacteristic!)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        print("CBCentralManagerDelegate didUpdateValueFor: \(peripheral.name?.description ?? "-")")
        print("CBCentralManagerDelegate didUpdateValueFor with error: \(error?.localizedDescription ?? "-")")
        dispatchPrecondition(condition: .onQueue(managerQueue))

        if error != nil {
            sendUpdate(errorMessage: error!.localizedDescription)
        }

        guard let value = characteristic.value else {
            return
        }

        rxBuffer.append(value)

        if rxBuffer.count == expectedBufferSize {
            if let sensor = sensor {
                do {
                    let decryptedBLE = Data(try Libre2.decryptBLE(sensorUID: sensor.uuid, data: rxBuffer))
                    let sensorUpdate = Libre2.parseBLEData(decryptedBLE, calibration: sensor.calibration)

                    sendUpdate(sensorAge: sensorUpdate.age)
                    sendUpdate(glucoseTrend: sensorUpdate.trend)
                    resetBuffer()
                } catch {
                    resetBuffer()
                }
            }
        }
    }
}
