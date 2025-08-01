import Foundation
import CoreData
import CoreBluetooth
import SwiftUI
import MapKit
import MeshtasticProtobufs
import CocoaMQTT
import OSLog

// ---------------------------------------------------------------------------------------
// Meshtastic BLE Device Manager
// ---------------------------------------------------------------------------------------
class BLEManager: NSObject, CBPeripheralDelegate, MqttClientProxyManagerDelegate, ObservableObject {
	static var shared: BLEManager! // Singleton instance

	let appState: AppState

	let context: NSManagedObjectContext

	private var centralManager: CBCentralManager!

	@Published var peripherals: [Peripheral] = []
	@Published var connectedPeripheral: Peripheral!
	@Published var lastConnectionError: String
	@Published var invalidVersion = false
	@Published var isSwitchedOn: Bool = false
	@Published var automaticallyReconnect: Bool = true
	@Published var mqttProxyConnected: Bool = false
	@Published var mqttError: String = ""
	public var minimumVersion = "2.3.15"
	public var connectedVersion: String
	public var isConnecting: Bool = false
	public var isConnected: Bool = false
	public var isSubscribed: Bool = false
	public var allowDisconnect: Bool = false
	private var configNonce: UInt32 = 1
	var timeoutTimer: Timer?
	var timeoutTimerCount = 0
	var positionTimer: Timer?
	var maintenanceTimer: Timer?
	let mqttManager = MqttClientProxyManager.shared
	var wantRangeTestPackets = false
	var wantStoreAndForwardPackets = false
	/* Meshtastic Service Details */
	var TORADIO_characteristic: CBCharacteristic!
	var FROMRADIO_characteristic: CBCharacteristic!
	var FROMNUM_characteristic: CBCharacteristic!
	var LEGACY_LOGRADIO_characteristic: CBCharacteristic!
	var LOGRADIO_characteristic: CBCharacteristic!
	let meshtasticServiceCBUUID = CBUUID(string: "0x6BA1B218-15A8-461F-9FA8-5DCAE273EAFD")
	let TORADIO_UUID = CBUUID(string: "0xF75C76D2-129E-4DAD-A1DD-7866124401E7")
	let FROMRADIO_UUID = CBUUID(string: "0x2C55E69E-4993-11ED-B878-0242AC120002")
	let EOL_FROMRADIO_UUID = CBUUID(string: "0x8BA2BCC2-EE02-4A55-A531-C525C5E454D5")
	let FROMNUM_UUID = CBUUID(string: "0xED9DA18C-A800-4F66-A670-AA7547E34453")
	let LEGACY_LOGRADIO_UUID = CBUUID(string: "0x6C6FD238-78FA-436B-AACF-15C5BE1EF2E2")
	let LOGRADIO_UUID = CBUUID(string: "0x5a3d6e49-06e6-4423-9944-e9de8cdf9547")
	@AppStorage("purgeStaleNodeDays") var purgeStaleNodeDays: Double = 0

	let NONCE_ONLY_CONFIG = 69420
	let NONCE_ONLY_DB = 69421
	private var isWaitingForWantConfigResponse = false

	private var wantConfigTimer: Timer?
	private var wantConfigRetryCount = 0
	private let maxWantConfigRetries = 6
	private let wantConfigTimeoutInterval: TimeInterval = 6.0

	// MARK: init
	private override init() {
	   // Default initialization should not be used
	   fatalError("Use setup(appState:context:) to initialize the singleton")
	}

	static func setup(appState: AppState, context: NSManagedObjectContext) {
	   guard shared == nil else {
		   Logger.services.warning("[BLE] BLEManager already initialized")
		   return
	   }
	   shared = BLEManager(appState: appState, context: context)
	}

	private init(appState: AppState, context: NSManagedObjectContext) {
		self.appState = appState
		self.context = context
		self.lastConnectionError = ""
		self.connectedVersion = "0.0.0"
		super.init()
		centralManager = CBCentralManager(delegate: self, queue: nil)
		mqttManager.delegate = self
		// Run clearStaleNodes every hour
		maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true, block: { _ in
			let result = clearStaleNodes(nodeExpireDays: Int(self.purgeStaleNodeDays), context: self.context)
			// If you are connected and the clear worked, pull nodes back from the node in case we have deleted anything from that app that is in the device nodedb
			if result && self.isSubscribed {
				self.sendWantConfig()
			}
		})
	}

	// MARK: Scanning for BLE Devices
	// Scan for nearby BLE devices using the Meshtastic BLE service ID
	func startScanning() {
		if isSwitchedOn {
			centralManager.scanForPeripherals(withServices: [meshtasticServiceCBUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
			Logger.services.info("✅ [BLE] Scanning Started")
		}
	}

	// Stop Scanning For BLE Devices
	func stopScanning() {
		if centralManager.isScanning {
			centralManager.stopScan()
			Logger.services.info("🛑 [BLE] Stopped Scanning")
		}
	}

	// MARK: BLE Connect functions
	/// The action after the timeout-timer has fired
	///
	/// - Parameters:
	///     - timer: The time that fired the event
	///
	@objc func timeoutTimerFired(timer: Timer) {
		guard let timerContext = timer.userInfo as? [String: String] else { return }
		let name: String = timerContext["name", default: "Unknown"]

		self.timeoutTimerCount += 1
		self.lastConnectionError = ""

		if timeoutTimerCount == 10 {
			if connectedPeripheral != nil {
				self.centralManager?.cancelPeripheralConnection(connectedPeripheral.peripheral)
			}
			connectedPeripheral = nil
			if self.timeoutTimer != nil {

				self.timeoutTimer!.invalidate()
			}
			self.isConnected = false
			self.isConnecting = false
			self.lastConnectionError = "🚨 " + String.localizedStringWithFormat("Connection failed after %d attempts to connect to %@. You may need to forget your device under Settings > Bluetooth.".localized, timeoutTimerCount, name)
			Logger.services.error("\(self.lastConnectionError, privacy: .public)")
			self.timeoutTimerCount = 0
			self.startScanning()
		} else {
			Logger.services.info("🚨 [BLE] Connecting 2 Second Timeout Timer Fired \(self.timeoutTimerCount, privacy: .public) Time(s): \(name, privacy: .public)")
		}
	}

	// Connect to a specific peripheral
	func connectTo(peripheral: CBPeripheral) {
		stopScanning()
		DispatchQueue.main.async {
			self.isConnecting = true
			self.lastConnectionError = ""
			self.automaticallyReconnect = true
		}
		if connectedPeripheral != nil {
			Logger.services.info("ℹ️ [BLE] Disconnecting from: \(self.connectedPeripheral.name, privacy: .public) to connect to \(peripheral.name ?? "Unknown", privacy: .public)")
			disconnectPeripheral()
		}

		centralManager?.connect(peripheral)
		// Invalidate any existing timer
		if timeoutTimer != nil {
			timeoutTimer!.invalidate()
		}
		// Use a timer to keep track of connecting peripherals, context to pass the radio name with the timer and the RunLoop to prevent
		// the timer from running on the main UI thread
		let context = ["name": "\(peripheral.name ?? "Unknown")"]
		timeoutTimer = Timer.scheduledTimer(timeInterval: 1.5, target: self, selector: #selector(timeoutTimerFired), userInfo: context, repeats: true)
		RunLoop.current.add(timeoutTimer!, forMode: .common)
		Logger.services.info("ℹ️ BLE Connecting: \(peripheral.name ?? "Unknown", privacy: .public)")
	}

	// Disconnect Connected Peripheral
	func cancelPeripheralConnection() {

		if mqttProxyConnected {
			mqttManager.mqttClientProxy?.disconnect()
		}
		FROMRADIO_characteristic = nil
		isConnecting = false
		isConnected = false
		isSubscribed = false
		allowDisconnect = false
		self.connectedPeripheral = nil
		invalidVersion = false
		connectedVersion = "0.0.0"
		connectedPeripheral = nil
		if timeoutTimer != nil {
			timeoutTimer!.invalidate()
		}
		automaticallyReconnect = false
		stopScanning()
		startScanning()
	}

	// Disconnect Connected Peripheral
	func disconnectPeripheral(reconnect: Bool = true) {
		// Ensure all operations run on the main thread
		DispatchQueue.main.async { [weak self] in
			guard let self = self else { return }
			guard let connectedPeripheral = self.connectedPeripheral else { return }
			if self.mqttProxyConnected {
				self.mqttManager.mqttClientProxy?.disconnect()
			}
			self.isWaitingForWantConfigResponse = false
			if wantConfigTimer != nil {
				self.wantConfigTimer?.invalidate()
			}
			self.wantConfigTimer = nil
			self.wantConfigRetryCount = 0
			self.automaticallyReconnect = reconnect
			self.centralManager?.cancelPeripheralConnection(connectedPeripheral.peripheral)
			self.FROMRADIO_characteristic = nil
			self.isConnected = false
			self.isSubscribed = false
			self.allowDisconnect = false
			self.invalidVersion = false
			self.connectedVersion = "0.0.0"
			self.stopScanning()
			self.startScanning()
		}
	}

	// Called each time a peripheral is connected
	func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
		isConnecting = false
		isConnected = true
		if UserDefaults.preferredPeripheralId.count < 1 {
			UserDefaults.preferredPeripheralId = peripheral.identifier.uuidString
		}
		// Invalidate and reset connection timer count
		timeoutTimerCount = 0
		if timeoutTimer != nil {
			timeoutTimer!.invalidate()
		}

		// remove any connection errors
		self.lastConnectionError = ""
		// Map the peripheral to the connectedPeripheral ObservedObjects
		connectedPeripheral = peripherals.filter({ $0.peripheral.identifier == peripheral.identifier }).first
		if connectedPeripheral != nil {
			connectedPeripheral.peripheral.delegate = self
		} else {
			// we are null just disconnect and start over
			lastConnectionError = "🚫 [BLE] Bluetooth connection error, please try again."
			disconnectPeripheral()
			return
		}
		// Discover Services
		peripheral.discoverServices([meshtasticServiceCBUUID])
		Logger.services.info("✅ [BLE] Connected: \(peripheral.name ?? "Unknown", privacy: .public)")
	}

	// Called when a Peripheral fails to connect
	func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
		if let e = error {
			// https://developer.apple.com/documentation/corebluetooth/cberror/code
			let errorCode = (e as NSError).code
			cancelPeripheralConnection()
			if errorCode == 14 { // Peer removed pairing information
				// Forgetting and reconnecting seems to be necessary so we need to show the user an error telling them to do that
				lastConnectionError = "🚨 " + String.localizedStringWithFormat("%@ This error usually cannot be fixed without forgetting the device under Settings > Bluetooth and re pairing the radio.".localized, e.localizedDescription)
				Logger.services.error("🚨 [BLE] Failed to connect: \(peripheral.name ?? "Unknown".localized) Error Code: \(errorCode, privacy: .public) Error: \(self.lastConnectionError, privacy: .public)")
			} else {
				lastConnectionError = "🚨 \(e.localizedDescription)"
				Logger.services.error("🚨 [BLE] Failed to connect: \(peripheral.name ?? "Unknown".localized, privacy: .public) Error Code: \(errorCode, privacy: .public) Error: \(e.localizedDescription, privacy: .public)")
			}
		}
	}

	// Disconnect Peripheral Event
	func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
		resetWantConfigRetries()
		self.connectedPeripheral = nil
		self.isConnecting = false
		self.isConnected = false
		self.isSubscribed = false
		let manager = LocalNotificationManager()
		if let e = error {
			// https://developer.apple.com/documentation/corebluetooth/cberror/code
			let errorCode = (e as NSError).code
			if errorCode == 6 { // CBError.Code.connectionTimeout The connection has timed out unexpectedly.
				// Happens when device is manually reset / powered off
				lastConnectionError = "🚨" + String.localizedStringWithFormat("%@ The app will automatically reconnect to the preferred radio if it comes back in range.".localized, e.localizedDescription)
				Logger.services.error("🚨 [BLE] Disconnected: \(peripheral.name ?? "Unknown".localized, privacy: .public) Error Code: \(errorCode, privacy: .public) Error: \(e.localizedDescription, privacy: .public)")
			} else if errorCode == 7 { // CBError.Code.peripheralDisconnected The specified device has disconnected from us.
				// Seems to be what is received when a tbeam sleeps, immediately recconnecting does not work.
				if UserDefaults.preferredPeripheralId == peripheral.identifier.uuidString {
					manager.notifications = [
						Notification(
							id: (peripheral.identifier.uuidString),
							title: "Radio Disconnected".localized,
							subtitle: "\(peripheral.name ?? "Unknown".localized)",
							content: e.localizedDescription,
							target: "bluetooth",
							path: "meshtastic:///bluetooth"
						)
					]
					manager.schedule()
				}
				lastConnectionError = "🚨 \("The specified device has disconnected from us".localized)"
				Logger.services.error("🚨 [BLE] Disconnected: \(peripheral.name ?? "Unknown".localized, privacy: .public) Error Code: \(errorCode, privacy: .public) Error: \(e.localizedDescription, privacy: .public)")
			} else if errorCode == 14 { // Peer removed pairing information
				// Forgetting and reconnecting seems to be necessary so we need to show the user an error telling them to do that
				lastConnectionError = "🚨 " + String.localizedStringWithFormat("%@ This error usually cannot be fixed without forgetting the device under Settings > Bluetooth and re-connecting to the radio.".localized, e.localizedDescription)
				Logger.services.error("🚨 [BLE] Disconnected: \(peripheral.name ?? "Unknown".localized) Error Code: \(errorCode, privacy: .public) Error: \(self.lastConnectionError, privacy: .public)")
			} else {
				if UserDefaults.preferredPeripheralId == peripheral.identifier.uuidString {
					manager.notifications = [
						Notification(
							id: (peripheral.identifier.uuidString),
							title: "Radio Disconnected".localized,
							subtitle: "\(peripheral.name ?? "Unknown".localized)",
							content: e.localizedDescription,
							target: "bluetooth",
							path: "meshtastic:///bluetooth"
						)
					]
					manager.schedule()
				}
				lastConnectionError = "🚨 \(e.localizedDescription)"
				Logger.services.error("🚨 [BLE] Disconnected: \(peripheral.name ?? "Unknown".localized, privacy: .public) Error Code: \(errorCode, privacy: .public) Error: \(e.localizedDescription, privacy: .public)")
			}
		} else {
			// Disconnected without error which indicates user intent to disconnect
			// Happens when swiping to disconnect
			Logger.services.info("ℹ️ [BLE] Disconnected: \(peripheral.name ?? "Unknown".localized, privacy: .public): \(String(describing: "User Initiated Disconnect".localized), privacy: .public)")
		}
		// Start a scan so the disconnected peripheral is moved to the peripherals[] if it is awake
		self.startScanning()
	}

	// MARK: Peripheral Services functions
	func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
		if let error {
			Logger.services.error("🚫 [BLE] Discover Services error \(error.localizedDescription, privacy: .public)")
		}
		guard let services = peripheral.services else { return }
		for service in services where service.uuid == meshtasticServiceCBUUID {
			peripheral.discoverCharacteristics([TORADIO_UUID, FROMRADIO_UUID, FROMNUM_UUID, LEGACY_LOGRADIO_UUID, LOGRADIO_UUID], for: service)
			Logger.services.info("✅ [BLE] Service for Meshtastic discovered by \(peripheral.name ?? "Unknown", privacy: .public)")
		}
	}

	// MARK: Discover Characteristics Event
	func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {

		if let error {
			Logger.services.error("🚫 [BLE] Discover Characteristics error for \(peripheral.name ?? "Unknown", privacy: .public) \(error.localizedDescription, privacy: .public) disconnecting device")
			// Try and stop crashes when this error occurs
			disconnectPeripheral()
			return
		}

		guard let characteristics = service.characteristics else { return }

		for characteristic in characteristics {
			switch characteristic.uuid {

			case TORADIO_UUID:
				Logger.services.info("✅ [BLE] did discover TORADIO characteristic for Meshtastic by \(peripheral.name ?? "Unknown", privacy: .public)")
				TORADIO_characteristic = characteristic

			case FROMRADIO_UUID:
				Logger.services.info("✅ [BLE] did discover FROMRADIO characteristic for Meshtastic by \(peripheral.name ?? "Unknown", privacy: .public)")
				FROMRADIO_characteristic = characteristic
				peripheral.readValue(for: FROMRADIO_characteristic)

			case FROMNUM_UUID:
				Logger.services.info("✅ [BLE] did discover FROMNUM (Notify) characteristic for Meshtastic by \(peripheral.name ?? "Unknown", privacy: .public)")
				FROMNUM_characteristic = characteristic
				peripheral.setNotifyValue(true, for: characteristic)

			case LEGACY_LOGRADIO_UUID:
				Logger.services.info("✅ [BLE] did discover legacy LOGRADIO (Notify) characteristic for Meshtastic by \(peripheral.name ?? "Unknown", privacy: .public)")
				LEGACY_LOGRADIO_characteristic = characteristic
				peripheral.setNotifyValue(true, for: characteristic)

			case LOGRADIO_UUID:
				Logger.services.info("✅ [BLE] did discover LOGRADIO (Notify) characteristic for Meshtastic by \(peripheral.name ?? "Unknown", privacy: .public)")
				LOGRADIO_characteristic = characteristic
				peripheral.setNotifyValue(true, for: characteristic)

			default:
				break
			}
		}
		if ![FROMNUM_characteristic, TORADIO_characteristic].contains(nil) {
			if mqttProxyConnected {
				mqttManager.mqttClientProxy?.disconnect()
			}
			sendWantConfig()
		}
	}

	// MARK: MqttClientProxyManagerDelegate Methods
	func onMqttConnected() {
		mqttProxyConnected = true
		mqttError = ""
		Logger.services.info("📲 [MQTT Client Proxy] onMqttConnected now subscribing to \(self.mqttManager.topic, privacy: .public).")
		mqttManager.mqttClientProxy?.subscribe(mqttManager.topic)
	}

	func onMqttDisconnected() {
		mqttProxyConnected = false
		Logger.services.info("📲 MQTT Disconnected")
	}

	func onMqttMessageReceived(message: CocoaMQTTMessage) {

		if message.topic.contains("/stat/") {
			return
		}
		var proxyMessage = MqttClientProxyMessage()
		proxyMessage.topic = message.topic
		proxyMessage.data = Data(message.payload)
		proxyMessage.retained = message.retained

		var toRadio: ToRadio!
		toRadio = ToRadio()
		toRadio.mqttClientProxyMessage = proxyMessage
		guard let binaryData: Data = try? toRadio.serializedData() else {
			return
		}
		if connectedPeripheral?.peripheral.state ?? CBPeripheralState.disconnected == CBPeripheralState.connected {
			connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
		}
	}

	func onMqttError(message: String) {
		mqttProxyConnected = false
		mqttError = message
		Logger.services.info("📲 [MQTT Client Proxy] onMqttError: \(message, privacy: .public)")
	}

	// MARK: Protobuf Methods
	func requestDeviceMetadata(fromUser: UserEntity, toUser: UserEntity, context: NSManagedObjectContext) -> Int64 {

		guard connectedPeripheral?.peripheral.state ?? CBPeripheralState.disconnected == CBPeripheralState.connected else { return 0 }

		var adminPacket = AdminMessage()
		adminPacket.getDeviceMetadataRequest = true
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		if let serializedData: Data = try? adminPacket.serializedData() {
			dataMessage.payload = serializedData
			dataMessage.portnum = PortNum.adminApp
			dataMessage.wantResponse = true
			meshPacket.decoded = dataMessage
		} else {
			return 0
		}

		let messageDescription = "🛎️ [Device Metadata] Requested for node \(toUser.longName ?? "Unknown".localized) by \(fromUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return Int64(meshPacket.id)
		}
		return 0
	}

	func sendTraceRouteRequest(destNum: Int64, wantResponse: Bool) -> Bool {

		var success = false
		guard connectedPeripheral?.peripheral.state ?? CBPeripheralState.disconnected == CBPeripheralState.connected else { return success }

		let fromNodeNum = connectedPeripheral.num
		let routePacket = RouteDiscovery()
		var meshPacket = MeshPacket()
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.to = UInt32(destNum)
		meshPacket.from	= UInt32(fromNodeNum)
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		if let serializedData: Data = try? routePacket.serializedData() {
			dataMessage.payload = serializedData
			dataMessage.portnum = PortNum.tracerouteApp
			dataMessage.wantResponse = true
			meshPacket.decoded = dataMessage
		} else {
			return false
		}
		var toRadio: ToRadio!
		toRadio = ToRadio()
		toRadio.packet = meshPacket
		guard let binaryData: Data = try? toRadio.serializedData() else {
			return false
		}
		if connectedPeripheral?.peripheral.state ?? CBPeripheralState.disconnected == CBPeripheralState.connected {
			connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
			success = true

			let traceRoute = TraceRouteEntity(context: context)
			let nodes = NodeInfoEntity.fetchRequest()
			if let connectedNum = self.connectedPeripheral?.num {
				nodes.predicate = NSPredicate(format: "num IN %@", [destNum, connectedNum])
			} else {
				nodes.predicate = NSPredicate(format: "num == %@", destNum)
			}
			do {
				let fetchedNodes = try context.fetch(nodes)
				let receivingNode = fetchedNodes.first(where: { $0.num == destNum })
				traceRoute.id = Int64(meshPacket.id)
				traceRoute.time = Date()
				traceRoute.node = receivingNode
				do {
					try context.save()
					Logger.data.info("💾 Saved TraceRoute sent to node: \(String(receivingNode?.user?.longName ?? "Unknown".localized), privacy: .public)")
				} catch {
					context.rollback()
					let nsError = error as NSError
					Logger.data.error("Error Updating Core Data BluetoothConfigEntity: \(nsError, privacy: .public)")
				}

				let logString = String.localizedStringWithFormat("Sent a Trace Route Request to node: %@".localized, destNum.toHex())
				Logger.mesh.info("🪧 \(logString, privacy: .public)")

			} catch {

			}
		}
		return success
	}

 func sendWantConfig() {
	 isWaitingForWantConfigResponse = true

	 guard connectedPeripheral?.peripheral.state ?? CBPeripheralState.disconnected == CBPeripheralState.connected else { return }

	 if FROMRADIO_characteristic == nil {
		 Logger.mesh.error("🚨 \("Unsupported Firmware Version Detected, unable to connect to device.".localized, privacy: .public)")
		 invalidVersion = true
		 return
	 } else {
		 // Send Heartbeat before wantConfig
		var heartbeatToRadio: ToRadio = ToRadio()
		heartbeatToRadio.payloadVariant = .heartbeat(Heartbeat())
		guard let heartbeatBinaryData: Data = try? heartbeatToRadio.serializedData() else {
			Logger.mesh.error("Failed to serialize Heartbeat ToRadio message")
			return
		}
		connectedPeripheral!.peripheral.writeValue(heartbeatBinaryData, for: TORADIO_characteristic, type: .withResponse)

		 let nodeName = connectedPeripheral?.peripheral.name ?? "Unknown".localized
		 let logString = String.localizedStringWithFormat("Issuing Want Config to %@".localized, nodeName)
		 Logger.mesh.info("🛎️ \(logString, privacy: .public)")
		 // BLE Characteristics discovered, issue wantConfig
		 var toRadio: ToRadio = ToRadio()
		 configNonce = UInt32(NONCE_ONLY_DB)
		 if !isSubscribed {
			 configNonce = UInt32(NONCE_ONLY_CONFIG) // Get config first
		 }
		 toRadio.wantConfigID = configNonce
		 guard let binaryData: Data = try? toRadio.serializedData() else {
			 return
		 }
		 connectedPeripheral!.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
		 // Either Read the config complete value or from num notify value
		 guard connectedPeripheral != nil else { return }
		 connectedPeripheral!.peripheral.readValue(for: FROMRADIO_characteristic)
		 // Start timeout timer
		 startWantConfigTimeout()
	 }
 }

 private func startWantConfigTimeout() {
	 // Cancel any existing timer
	 wantConfigTimer?.invalidate()
	 // Start new timer
	 wantConfigTimer = Timer.scheduledTimer(withTimeInterval: wantConfigTimeoutInterval, repeats: false) { [weak self] _ in
		 self?.handleWantConfigTimeout()
	 }
 }

 private func handleWantConfigTimeout() {
	 guard isWaitingForWantConfigResponse else { return }
	 wantConfigRetryCount += 1
	 if wantConfigRetryCount == 1 {
		 allowDisconnect = true
	 }
	 if wantConfigRetryCount < maxWantConfigRetries {
		 Logger.mesh.warning("⏰ Want Config timeout, retrying... (attempt \(self.wantConfigRetryCount + 1)/\(self.maxWantConfigRetries))")
		 sendWantConfig()
	 } else {
		 Logger.mesh.error("🚨 Want Config failed after \(self.maxWantConfigRetries) attempts, forcing disconnect")
		 lastConnectionError = "Bluetooth connection timeout, keep your node closer or reboot your radio if the problem continues.".localized
		 disconnectPeripheral(reconnect: false)
	 }
 }

 func onWantConfigResponseReceived() {
	 if isWaitingForWantConfigResponse {
		 isWaitingForWantConfigResponse = false
		 wantConfigTimer?.invalidate()
		 wantConfigTimer = nil
		 wantConfigRetryCount = 0 // Reset retry count on success
	 }
 }

 // Call this to reset the retry mechanism (e.g., on new connection)
 func resetWantConfigRetries() {
	 wantConfigRetryCount = 0
	 wantConfigTimer?.invalidate()
	 wantConfigTimer = nil
	 isWaitingForWantConfigResponse = false
 }

	func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
		if let error {
			Logger.services.error("💥 [BLE] didUpdateNotificationStateFor error: \(characteristic.uuid, privacy: .public) \(error.localizedDescription, privacy: .public)")
		} else {
			Logger.services.info("ℹ️ [BLE] peripheral didUpdateNotificationStateFor \(characteristic.uuid, privacy: .public)")
		}
	}

	fileprivate func handleRadioLog(radioLog: String) {
		var log = radioLog
		/// Debug Log Level
		if log.starts(with: "DEBUG |") {
			do {
				let logString = log
				if let coordsMatch = try CommonRegex.COORDS_REGEX.firstMatch(in: logString) {
					log = "\(log.replacingOccurrences(of: "DEBUG |", with: "").trimmingCharacters(in: .whitespaces))"
					log = log.replacingOccurrences(of: "[,]", with: "", options: .regularExpression)
					Logger.radio.debug("🛰️ \(log.prefix(upTo: coordsMatch.range.lowerBound), privacy: .public) \(coordsMatch.0.replacingOccurrences(of: "[,]", with: "", options: .regularExpression), privacy: .private(mask: .none)) \(log.suffix(from: coordsMatch.range.upperBound), privacy: .public)")
				} else {
					log = log.replacingOccurrences(of: "[,]", with: "", options: .regularExpression)
					Logger.radio.debug("🕵🏻‍♂️ \(log.replacingOccurrences(of: "DEBUG |", with: "").trimmingCharacters(in: .whitespaces), privacy: .public)")
				}
			} catch {
				log = log.replacingOccurrences(of: "[,]", with: "", options: .regularExpression)
				Logger.radio.debug("🕵🏻‍♂️ \(log.replacingOccurrences(of: "DEBUG |", with: "").trimmingCharacters(in: .whitespaces), privacy: .public)")
			}
		} else if log.starts(with: "INFO  |") {
			do {
				let logString = log
				if let coordsMatch = try CommonRegex.COORDS_REGEX.firstMatch(in: logString) {
					log = "\(log.replacingOccurrences(of: "INFO  |", with: "").trimmingCharacters(in: .whitespaces))"
					log = log.replacingOccurrences(of: "[,]", with: "", options: .regularExpression)
					Logger.radio.info("🛰️ \(log.prefix(upTo: coordsMatch.range.lowerBound), privacy: .public) \(coordsMatch.0.replacingOccurrences(of: "[,]", with: "", options: .regularExpression), privacy: .private) \(log.suffix(from: coordsMatch.range.upperBound), privacy: .public)")
				} else {
					log = log.replacingOccurrences(of: "[,]", with: "", options: .regularExpression)
					Logger.radio.info("📢 \(log.replacingOccurrences(of: "INFO  |", with: "").trimmingCharacters(in: .whitespaces), privacy: .public)")
				}
			} catch {
				log = log.replacingOccurrences(of: "[,]", with: "", options: .regularExpression)
				Logger.radio.info("📢 \(log.replacingOccurrences(of: "INFO  |", with: "").trimmingCharacters(in: .whitespaces), privacy: .public)")
			}
		} else if log.starts(with: "WARN  |") {
			log = log.replacingOccurrences(of: "[,]", with: "", options: .regularExpression)
			Logger.radio.warning("⚠️ \(log.replacingOccurrences(of: "WARN  |", with: "").trimmingCharacters(in: .whitespaces), privacy: .public)")
		} else if log.starts(with: "ERROR |") {
			log = log.replacingOccurrences(of: "[,]", with: "", options: .regularExpression)
			Logger.radio.error("💥 \(log.replacingOccurrences(of: "ERROR |", with: "").trimmingCharacters(in: .whitespaces), privacy: .public)")
		} else if log.starts(with: "CRIT  |") {
			log = log.replacingOccurrences(of: "[,]", with: "", options: .regularExpression)
			Logger.radio.critical("🧨 \(log.replacingOccurrences(of: "CRIT  |", with: "").trimmingCharacters(in: .whitespaces), privacy: .public)")
		} else {
			log = log.replacingOccurrences(of: "[,]", with: "", options: .regularExpression)
			Logger.radio.debug("📟 \(log, privacy: .public)")
		}
	}

	func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {

		if let error {
			Logger.services.error("🚫 [BLE] didUpdateValueFor Characteristic error \(error.localizedDescription, privacy: .public)")
			let errorCode = (error as NSError).code
			if errorCode == 5 || errorCode == 15 {
				// BLE PIN connection errors
				// 5 CBATTErrorDomain Code=5 "Authentication is insufficient."
				// 15 CBATTErrorDomain Code=15 "Encryption is insufficient."
				lastConnectionError = "🚨" + String.localizedStringWithFormat("%@ Please try connecting again and check the PIN carefully.".localized, error.localizedDescription)
				Logger.services.error("🚫 [BLE] \(error.localizedDescription, privacy: .public) Please try connecting again and check the PIN carefully.")
				self.disconnectPeripheral(reconnect: false)
			}
			return
		}

		switch characteristic.uuid {
		case LOGRADIO_UUID:
			if characteristic.value == nil || characteristic.value!.isEmpty {
				return
			}
			do {
				let logRecord = try LogRecord(serializedBytes: characteristic.value!)
				var message = logRecord.source.isEmpty ? logRecord.message : "[\(logRecord.source)] \(logRecord.message)"
				switch logRecord.level {
				case .debug:
					message = "DEBUG | \(message)"
				case .info:
					message = "INFO  | \(message)"
				case .warning:
				   message = "WARN  | \(message)"
				case .error:
				   message = "ERROR | \(message)"
				case .critical:
				  message = "CRIT  | \(message)"
				default:
					message = "DEBUG | \(message)"
				}
				handleRadioLog(radioLog: message)
			} catch {
				// Ignore fail to parse as LogRecord
			}

		case FROMRADIO_UUID:

			if characteristic.value == nil || characteristic.value!.isEmpty {
				return
			}
			var decodedInfo = FromRadio()

			do {
				decodedInfo = try FromRadio(serializedBytes: characteristic.value!)

			} catch {
				Logger.services.error("💥 \(error.localizedDescription, privacy: .public) \(characteristic.value!, privacy: .public)")
			}
			// Publish mqttClientProxyMessages received on the from radio
			if decodedInfo.payloadVariant == FromRadio.OneOf_PayloadVariant.mqttClientProxyMessage(decodedInfo.mqttClientProxyMessage) {
				let message = CocoaMQTTMessage(topic: decodedInfo.mqttClientProxyMessage.topic, payload: [UInt8](decodedInfo.mqttClientProxyMessage.data), retained: decodedInfo.mqttClientProxyMessage.retained)
				mqttManager.mqttClientProxy?.publish(message)
			} else if decodedInfo.payloadVariant == FromRadio.OneOf_PayloadVariant.clientNotification(decodedInfo.clientNotification) {
				var path = "meshtastic:///settings/debugLogs"
				if decodedInfo.clientNotification.hasReplyID {
					/// Set Sent bool on TraceRouteEntity to false if we got rate limited
					if decodedInfo.clientNotification.message.starts(with: "TraceRoute") {
						let traceRoute = getTraceRoute(id: Int64(decodedInfo.clientNotification.replyID), context: context)
						traceRoute?.sent = false
						do {
							try context.save()
							Logger.data.info("💾 [TraceRouteEntity] Trace Route Rate Limited")
						} catch {
							context.rollback()
							let nsError = error as NSError
							Logger.data.error("💥 [TraceRouteEntity] Error Updating Core Data: \(nsError, privacy: .public)")
						}
					}
					if decodedInfo.clientNotification.payloadVariant == ClientNotification.OneOf_PayloadVariant.lowEntropyKey(decodedInfo.clientNotification.lowEntropyKey) ||
						decodedInfo.clientNotification.payloadVariant == ClientNotification.OneOf_PayloadVariant.duplicatedPublicKey(decodedInfo.clientNotification.duplicatedPublicKey) {
						path = "meshtastic:///settings/security"
					}
				}
				let manager = LocalNotificationManager()
				manager.notifications = [
					Notification(
						id: UUID().uuidString,
						title: "Firmware Notification".localized,
						subtitle: "\(decodedInfo.clientNotification.level)".capitalized,
						content: decodedInfo.clientNotification.message,
						target: "settings",
						path: path
					)
				]
				manager.schedule()
				Logger.data.error("⚠️ Client Notification: \(decodedInfo.clientNotification.message, privacy: .public)")
			}

			switch decodedInfo.packet.decoded.portnum {

				// Handle Any local only packets we get over BLE
			case .unknownApp:
				var nowKnown = false

				// MyInfo from initial connection
				if decodedInfo.myInfo.isInitialized && decodedInfo.myInfo.myNodeNum > 0 {
					let myInfo = myInfoPacket(myInfo: decodedInfo.myInfo, peripheralId: self.connectedPeripheral.id, context: context)

					if myInfo != nil {
						UserDefaults.preferredPeripheralNum = Int(myInfo?.myNodeNum ?? 0)
						connectedPeripheral.num = myInfo?.myNodeNum ?? 0
						connectedPeripheral.name = myInfo?.bleName ?? "Unknown".localized
						connectedPeripheral.longName = myInfo?.bleName ?? "Unknown".localized
						let newConnection = Int64(UserDefaults.preferredPeripheralNum) != Int64(decodedInfo.myInfo.myNodeNum)
						if newConnection {
							// Onboard a new device connection here
						}
					}
					tryClearExistingChannels()
				}
				// NodeInfo
				if decodedInfo.nodeInfo.num > 0 {
					onWantConfigResponseReceived()
					nowKnown = true
					if let nodeInfo = nodeInfoPacket(nodeInfo: decodedInfo.nodeInfo, channel: decodedInfo.packet.channel, context: context) {
						if self.connectedPeripheral != nil && self.connectedPeripheral.num == nodeInfo.num {
							if nodeInfo.user != nil {
								connectedPeripheral.shortName = nodeInfo.user?.shortName ?? "?"
								connectedPeripheral.longName = nodeInfo.user?.longName ?? "Unknown".localized
								UserDefaults.hardwareModel = nodeInfo.user?.hwModel ?? "Unset".localized
							}
						}
					}
				}
				guard let cp = connectedPeripheral else {
					return
				}
				// Channels
				if decodedInfo.channel.isInitialized {
					nowKnown = true
					channelPacket(channel: decodedInfo.channel, fromNum: Int64(truncatingIfNeeded: cp.num), context: context)
				}
				// Config
				if decodedInfo.config.isInitialized && !invalidVersion && cp.num != 0 {
					nowKnown = true
					localConfig(config: decodedInfo.config, context: context, nodeNum: Int64(truncatingIfNeeded: cp.num), nodeLongName: cp.longName)
				}
				// Module Config
				if decodedInfo.moduleConfig.isInitialized && !invalidVersion && cp.num != 0 {
					onWantConfigResponseReceived()
					nowKnown = true
					moduleConfig(config: decodedInfo.moduleConfig, context: context, nodeNum: Int64(truncatingIfNeeded: cp.num), nodeLongName: cp.longName)
					if decodedInfo.moduleConfig.payloadVariant == ModuleConfig.OneOf_PayloadVariant.cannedMessage(decodedInfo.moduleConfig.cannedMessage) {
						_ = self.getCannedMessageModuleMessages(destNum: cp.num, wantResponse: true)
					}
					if decodedInfo.config.payloadVariant == Config.OneOf_PayloadVariant.device(decodedInfo.config.device) {
						var dc = decodedInfo.config.device
						if dc.tzdef.isEmpty {
							dc.tzdef =  TimeZone.current.posixDescription
							_ = self.saveTimeZone(config: dc, user: cp.num)
						}
					}
				}
				// Device Metadata
				if decodedInfo.metadata.firmwareVersion.count > 0 && !invalidVersion {
					nowKnown = true
					deviceMetadataPacket(metadata: decodedInfo.metadata, fromNum: cp.num, context: context)
					connectedPeripheral.firmwareVersion = decodedInfo.metadata.firmwareVersion
					let lastDotIndex = decodedInfo.metadata.firmwareVersion.lastIndex(of: ".")
					if lastDotIndex == nil {
						invalidVersion = true
						connectedVersion = "0.0.0"
					} else {
						let version = decodedInfo.metadata.firmwareVersion[...(lastDotIndex ?? String.Index(utf16Offset: 6, in: decodedInfo.metadata.firmwareVersion))]
						nowKnown = true
						connectedVersion = String(version.dropLast())
						UserDefaults.firmwareVersion = connectedVersion
					}
					let supportedVersion = connectedVersion == "0.0.0" ||  self.minimumVersion.compare(connectedVersion, options: .numeric) == .orderedAscending || minimumVersion.compare(connectedVersion, options: .numeric) == .orderedSame
					if !supportedVersion {
						invalidVersion = true
						lastConnectionError = "🚨" + "Update Your Firmware".localized
						return
					}
				}
				// Log any other unknownApp calls
				if !nowKnown { Logger.mesh.info("🕸️ MESH PACKET received for Unknown App UNHANDLED \((try? decodedInfo.packet.jsonString()) ?? "JSON Decode Failure", privacy: .public)") }
			case .textMessageApp, .detectionSensorApp:
				textMessageAppPacket(
					packet: decodedInfo.packet,
					wantRangeTestPackets: wantRangeTestPackets,
					connectedNode: (self.connectedPeripheral != nil ? connectedPeripheral.num : 0),
					context: context,
					appState: appState
				)
			case .alertApp:
				textMessageAppPacket(
					packet: decodedInfo.packet,
					wantRangeTestPackets: wantRangeTestPackets,
					critical: true,
					connectedNode: (self.connectedPeripheral != nil ? connectedPeripheral.num : 0),
					context: context,
					appState: appState
				)
			case .remoteHardwareApp:
				Logger.mesh.info("🕸️ MESH PACKET received for Remote Hardware App UNHANDLED \((try? decodedInfo.packet.jsonString()) ?? "JSON Decode Failure", privacy: .public)")
			case .positionApp:
				upsertPositionPacket(packet: decodedInfo.packet, context: context)
			case .waypointApp:
				waypointPacket(packet: decodedInfo.packet, context: context)
			case .nodeinfoApp:
				if !invalidVersion { upsertNodeInfoPacket(packet: decodedInfo.packet, context: context) }
			case .routingApp:
				if !invalidVersion {
					guard let peripheral = self.connectedPeripheral else {
						Logger.mesh.error("🕸️ connectedPeripheral is nil. Unable to determine connectedNodeNum for routingPacket.")
						return
					}
					routingPacket(packet: decodedInfo.packet, connectedNodeNum: peripheral.num, context: context)
				}
			case .adminApp:
				adminAppPacket(packet: decodedInfo.packet, context: context)
			case .replyApp:
				Logger.mesh.info("🕸️ MESH PACKET received for Reply App handling as a text message")
				textMessageAppPacket(packet: decodedInfo.packet, wantRangeTestPackets: wantRangeTestPackets, connectedNode: (self.connectedPeripheral != nil ? connectedPeripheral.num : 0), context: context, appState: appState)
			case .ipTunnelApp:
				Logger.mesh.info("🕸️ MESH PACKET received for IP Tunnel App UNHANDLED UNHANDLED")
			case .serialApp:
				Logger.mesh.info("🕸️ MESH PACKET received for Serial App UNHANDLED UNHANDLED")
			case .storeForwardApp:
				storeAndForwardPacket(packet: decodedInfo.packet, connectedNodeNum: (self.connectedPeripheral != nil ? connectedPeripheral.num : 0), context: context)
			case .rangeTestApp:
				if wantRangeTestPackets {
					textMessageAppPacket(
						packet: decodedInfo.packet,
						wantRangeTestPackets: true,
						connectedNode: (self.connectedPeripheral != nil ? connectedPeripheral.num : 0),
						context: context,
						appState: appState
					)
				} else {
					Logger.mesh.info("🕸️ MESH PACKET received for Range Test App Range testing is disabled.")
				}
			case .telemetryApp:
				if !invalidVersion { telemetryPacket(packet: decodedInfo.packet, connectedNode: (self.connectedPeripheral != nil ? connectedPeripheral.num : 0), context: context) }
			case .textMessageCompressedApp:
				Logger.mesh.info("🕸️ MESH PACKET received for Text Message Compressed App UNHANDLED")
			case .zpsApp:
				Logger.mesh.info("🕸️ MESH PACKET received for Zero Positioning System App UNHANDLED")
			case .privateApp:
				Logger.mesh.info("🕸️ MESH PACKET received for Private App UNHANDLED UNHANDLED")
			case .atakForwarder:
				Logger.mesh.info("🕸️ MESH PACKET received for ATAK Forwarder App UNHANDLED UNHANDLED")
			case .simulatorApp:
				Logger.mesh.info("🕸️ MESH PACKET received for Simulator App UNHANDLED UNHANDLED")
			case .audioApp:
				Logger.mesh.info("🕸️ MESH PACKET received for Audio App UNHANDLED UNHANDLED")
			case .tracerouteApp:
				if let routingMessage = try? RouteDiscovery(serializedBytes: decodedInfo.packet.decoded.payload) {
					let traceRoute = getTraceRoute(id: Int64(decodedInfo.packet.decoded.requestID), context: context)
					traceRoute?.response = true
					guard let connectedNode = getNodeInfo(id: Int64(connectedPeripheral.num), context: context) else {
						return
					}
					var hopNodes: [TraceRouteHopEntity] = []
					let connectedHop = TraceRouteHopEntity(context: context)
					connectedHop.time = Date()
					connectedHop.num = connectedPeripheral.num
					connectedHop.name = connectedNode.user?.longName ?? "???"
					// If nil, set to unknown, INT8_MIN (-128) then divide by 4
					connectedHop.snr = Float(routingMessage.snrBack.last ?? -128) / 4
					if let mostRecent = traceRoute?.node?.positions?.lastObject as? PositionEntity, mostRecent.time! >= Calendar.current.date(byAdding: .hour, value: -24, to: Date())! {
						connectedHop.altitude = mostRecent.altitude
						connectedHop.latitudeI = mostRecent.latitudeI
						connectedHop.longitudeI = mostRecent.longitudeI
						traceRoute?.hasPositions = true
					}
					var routeString = "\(connectedNode.user?.longName ?? "???") --> "
					hopNodes.append(connectedHop)
					traceRoute?.hopsTowards = Int32(routingMessage.route.count)
					for (index, node) in routingMessage.route.enumerated() {
						var hopNode = getNodeInfo(id: Int64(node), context: context)
						if hopNode == nil && hopNode?.num ?? 0 > 0 && node != 4294967295 {
							hopNode = createNodeInfo(num: Int64(node), context: context)
						}
						let traceRouteHop = TraceRouteHopEntity(context: context)
						traceRouteHop.time = Date()
						if routingMessage.snrTowards.count >= index + 1 {
							traceRouteHop.snr = Float(routingMessage.snrTowards[index]) / 4
						} else {
							// If no snr in route, set unknown
							traceRouteHop.snr = -32
						}
						if let hn = hopNode, hn.hasPositions {
							if let mostRecent = hn.positions?.lastObject as? PositionEntity, mostRecent.time! >= Calendar.current.date(byAdding: .hour, value: -24, to: Date())! {
								traceRouteHop.altitude = mostRecent.altitude
								traceRouteHop.latitudeI = mostRecent.latitudeI
								traceRouteHop.longitudeI = mostRecent.longitudeI
								traceRoute?.hasPositions = true
							}
						}
						traceRouteHop.num = hopNode?.num ?? 0
						if hopNode != nil {
							if decodedInfo.packet.rxTime > 0 {
								hopNode?.lastHeard = Date(timeIntervalSince1970: TimeInterval(Int64(decodedInfo.packet.rxTime)))
							}
						}
						hopNodes.append(traceRouteHop)

						let hopName = hopNode?.user?.longName ?? (node == 4294967295 ? "Repeater" : String(hopNode?.num.toHex() ?? "Unknown".localized))
						let mqttLabel = hopNode?.viaMqtt ?? false ? "MQTT " : ""
						let snrLabel = (traceRouteHop.snr != -32) ? String(traceRouteHop.snr) : "unknown ".localized
						routeString += "\(hopName) \(mqttLabel)(\(snrLabel)dB) --> "
					}
					let destinationHop = TraceRouteHopEntity(context: context)
					destinationHop.name = traceRoute?.node?.user?.longName ?? "Unknown".localized
					destinationHop.time = Date()
					// If nil, set to unknown, INT8_MIN (-128) then divide by 4
					destinationHop.snr = Float(routingMessage.snrTowards.last ?? -128) / 4
					destinationHop.num = traceRoute?.node?.num ?? 0
					if let mostRecent = traceRoute?.node?.positions?.lastObject as? PositionEntity, mostRecent.time! >= Calendar.current.date(byAdding: .hour, value: -24, to: Date())! {
						destinationHop.altitude = mostRecent.altitude
						destinationHop.latitudeI = mostRecent.latitudeI
						destinationHop.longitudeI = mostRecent.longitudeI
						traceRoute?.hasPositions = true
					}
					hopNodes.append(destinationHop)
					/// Add the destination node to the end of the route towards string and the beginning of the route back string
					routeString += "\(traceRoute?.node?.user?.longName ?? "Unknown".localized) \((traceRoute?.node?.num ?? 0).toHex()) (\(destinationHop.snr != -32 ? String(destinationHop.snr) : "unknown ".localized)dB)"
					traceRoute?.routeText = routeString
					// Default to -1 only fill in if routeBack is valid below
					traceRoute?.hopsBack = -1
					// Only if hopStart is set and there is an SNR entry
					if decodedInfo.packet.hopStart > 0 && routingMessage.snrBack.count > 0 {
						traceRoute?.hopsBack = Int32(routingMessage.routeBack.count)
						var routeBackString = "\(traceRoute?.node?.user?.longName ?? "Unknown".localized) \((traceRoute?.node?.num ?? 0).toHex()) --> "
						for (index, node) in routingMessage.routeBack.enumerated() {
							var hopNode = getNodeInfo(id: Int64(node), context: context)
							if hopNode == nil && hopNode?.num ?? 0 > 0 && node != 4294967295 {
								hopNode = createNodeInfo(num: Int64(node), context: context)
							}
							let traceRouteHop = TraceRouteHopEntity(context: context)
							traceRouteHop.time = Date()
							traceRouteHop.back = true
							if routingMessage.snrBack.count >= index + 1 {
								traceRouteHop.snr = Float(routingMessage.snrBack[index]) / 4
							} else {
								// If no snr in route, set to unknown
								traceRouteHop.snr = -32
							}
							if let hn = hopNode, hn.hasPositions {
								if let mostRecent = hn.positions?.lastObject as? PositionEntity, mostRecent.time! >= Calendar.current.date(byAdding: .hour, value: -24, to: Date())! {
									traceRouteHop.altitude = mostRecent.altitude
									traceRouteHop.latitudeI = mostRecent.latitudeI
									traceRouteHop.longitudeI = mostRecent.longitudeI
									traceRoute?.hasPositions = true
								}
							}
							traceRouteHop.num = hopNode?.num ?? 0
							if hopNode != nil {
								if decodedInfo.packet.rxTime > 0 {
									hopNode?.lastHeard = Date(timeIntervalSince1970: TimeInterval(Int64(decodedInfo.packet.rxTime)))
								}
							}
							hopNodes.append(traceRouteHop)

							let hopName = hopNode?.user?.longName ?? (node == 4294967295 ? "Repeater" : String(hopNode?.num.toHex() ?? "Unknown".localized))
							let mqttLabel = hopNode?.viaMqtt ?? false ? "MQTT " : ""
							let snrLabel = (traceRouteHop.snr != -32) ? String(traceRouteHop.snr) : "unknown ".localized
							routeBackString += "\(hopName) \(mqttLabel)(\(snrLabel)dB) --> "
						}
						// If nil, set to unknown, INT8_MIN (-128) then divide by 4
						let snrBackLast = Float(routingMessage.snrBack.last ?? -128) / 4
						routeBackString += "\(connectedNode.user?.longName ?? String(connectedNode.num.toHex())) (\(snrBackLast != -32 ? String(snrBackLast) : "unknown ".localized)dB)"
						traceRoute?.routeBackText = routeBackString
					}
					traceRoute?.hops = NSOrderedSet(array: hopNodes)
					traceRoute?.time = Date()

					if let tr = traceRoute {
						let manager = LocalNotificationManager()
						manager.notifications = [
							Notification(
								id: (UUID().uuidString),
								title: "Traceroute Complete",
								subtitle: "TR received back from \(destinationHop.name ?? "unknown")",
								content: "Hops from: \(tr.hopsTowards), Hops back: \(tr.hopsBack)\n\(tr.routeText ?? "Unknown".localized)\n\(tr.routeBackText ?? "Unknown".localized)",
								target: "nodes",
								path: "meshtastic:///nodes?nodenum=\(tr.node?.num ?? 0)"
							)
						]
						manager.schedule()
					}

					do {
						try context.save()
						Logger.data.info("💾 Saved Trace Route")
					} catch {
						context.rollback()
						let nsError = error as NSError
						Logger.data.error("Error Updating Core Data TraceRouteHop: \(nsError, privacy: .public)")
					}
					let logString = String.localizedStringWithFormat("Trace Route request returned: %@".localized, routeString)
					Logger.mesh.info("🪧 \(logString, privacy: .public)")
				}
			case .neighborinfoApp:
				if let neighborInfo = try? NeighborInfo(serializedBytes: decodedInfo.packet.decoded.payload) {
					Logger.mesh.info("🕸️ MESH PACKET received for Neighbor Info App UNHANDLED \((try? neighborInfo.jsonString()) ?? "JSON Decode Failure", privacy: .public)")
				}
			case .paxcounterApp:
				paxCounterPacket(packet: decodedInfo.packet, context: context)
			case .mapReportApp:
				Logger.mesh.info("🕸️ MESH PACKET received Map Report App UNHANDLED \((try? decodedInfo.packet.jsonString()) ?? "JSON Decode Failure", privacy: .public)")
			case .UNRECOGNIZED:
				Logger.mesh.info("🕸️ MESH PACKET received UNRECOGNIZED App UNHANDLED \((try? decodedInfo.packet.jsonString()) ?? "JSON Decode Failure", privacy: .public)")
			case .max:
				Logger.services.info("MAX PORT NUM OF 511")
			case .atakPlugin:
				Logger.mesh.info("🕸️ MESH PACKET received for ATAK Plugin App UNHANDLED \((try? decodedInfo.packet.jsonString()) ?? "JSON Decode Failure", privacy: .public)")
			case .powerstressApp:
				Logger.mesh.info("🕸️ MESH PACKET received for Power Stress App UNHANDLED \((try? decodedInfo.packet.jsonString()) ?? "JSON Decode Failure", privacy: .public)")
			case .reticulumTunnelApp:
				Logger.mesh.info("🕸️ MESH PACKET received for Reticulum Tunnel App UNHANDLED \((try? decodedInfo.packet.jsonString()) ?? "JSON Decode Failure", privacy: .public)")
			case .keyVerificationApp:
				Logger.mesh.warning("🕸️ MESH PACKET received for Key Verification App UNHANDLED \((try? decodedInfo.packet.jsonString()) ?? "JSON Decode Failure", privacy: .public)")
			case .cayenneApp:
				Logger.mesh.info("🕸️ MESH PACKET received Cayenne App UNHANDLED \((try? decodedInfo.packet.jsonString()) ?? "JSON Decode Failure", privacy: .public)")
			}

			if decodedInfo.configCompleteID != 0 && decodedInfo.configCompleteID == NONCE_ONLY_CONFIG {
				invalidVersion = false
				lastConnectionError = ""
				isSubscribed = true
				allowDisconnect = true
				Logger.mesh.info("🤜 [BLE] Want Config Complete. ID:\(decodedInfo.configCompleteID, privacy: .public)")
				if sendTime() {
				}
				peripherals.removeAll(where: { $0.peripheral.state == CBPeripheralState.disconnected })
				// Config conplete returns so we don't read the characteristic again

				/// MQTT Client Proxy and RangeTest and Store and Forward interest
				if connectedPeripheral.num > 0 {

					let fetchNodeInfoRequest = NodeInfoEntity.fetchRequest()
					fetchNodeInfoRequest.predicate = NSPredicate(format: "num == %lld", Int64(connectedPeripheral.num))
					do {
						let fetchedNodeInfo = try context.fetch(fetchNodeInfoRequest)
						if fetchedNodeInfo.count == 1 {
							// Subscribe to Mqtt Client Proxy if enabled
							if fetchedNodeInfo[0].mqttConfig != nil && fetchedNodeInfo[0].mqttConfig?.enabled ?? false && fetchedNodeInfo[0].mqttConfig?.proxyToClientEnabled ?? false {
								mqttManager.connectFromConfigSettings(node: fetchedNodeInfo[0])
							} else {
								if mqttProxyConnected {
									mqttManager.mqttClientProxy?.disconnect()
								}
							}
							// Set initial unread message badge states
							appState.unreadChannelMessages = fetchedNodeInfo[0].myInfo?.unreadMessages ?? 0
							appState.unreadDirectMessages = fetchedNodeInfo[0].user?.unreadMessages ?? 0
						}
						if fetchedNodeInfo.count == 1 && fetchedNodeInfo[0].rangeTestConfig?.enabled == true {
							wantRangeTestPackets = true
						}
						if fetchedNodeInfo.count == 1 && fetchedNodeInfo[0].storeForwardConfig?.enabled == true {
							wantStoreAndForwardPackets = true
						}

					} catch {
						Logger.data.error("Failed to find a node info for the connected node \(error.localizedDescription, privacy: .public)")
					}
					Logger.mesh.info("🤜 [BLE] Want Config Complete. ID:\(decodedInfo.configCompleteID, privacy: .public)")
					sendWantConfig()

				}
				// MARK: Share Location Position Update Timer
				// Use context to pass the radio name with the timer
				// Use a RunLoop to prevent the timer from running on the main UI thread
				if UserDefaults.provideLocation {
					let interval = UserDefaults.provideLocationInterval >= 10 ? UserDefaults.provideLocationInterval : 30
					positionTimer = Timer.scheduledTimer(timeInterval: TimeInterval(interval), target: self, selector: #selector(positionTimerFired), userInfo: context, repeats: true)
					if positionTimer != nil {
						RunLoop.current.add(positionTimer!, forMode: .common)
					}
				}
				return
			}
			if decodedInfo.configCompleteID != 0 && decodedInfo.configCompleteID == NONCE_ONLY_DB {
				Logger.mesh.info("🤜 [BLE] Want Config DB Complete. ID:\(decodedInfo.configCompleteID, privacy: .public)")
			}
		case FROMNUM_UUID:
			Logger.services.info("🗞️ [BLE] (Notify) characteristic value will be read next")
		default:
			Logger.services.error("🚫 Unhandled Characteristic UUID: \(characteristic.uuid, privacy: .public)")
		}
		if FROMRADIO_characteristic != nil {
			// Either Read the config complete value or from num notify value
			peripheral.readValue(for: FROMRADIO_characteristic)
		}
	}

	public func sendMessage(message: String, toUserNum: Int64, channel: Int32, isEmoji: Bool, replyID: Int64) -> Bool {
		var success = false

		// Return false if we are not properly connected to a device, handle retry logic in the view for now
		if connectedPeripheral == nil || connectedPeripheral!.peripheral.state != CBPeripheralState.connected {

			self.disconnectPeripheral()
			self.startScanning()

			// Try and connect to the preferredPeripherial first
			let preferredPeripheral = peripherals.filter({ $0.peripheral.identifier.uuidString == UserDefaults.preferredPeripheralId as String }).first
			if preferredPeripheral != nil && preferredPeripheral?.peripheral != nil {
				connectTo(peripheral: preferredPeripheral!.peripheral)
			}
			let nodeName = connectedPeripheral?.peripheral.name ?? "Unknown".localized
			let logString = String.localizedStringWithFormat("Message Send Failed, not properly connected to %@".localized, nodeName)
			Logger.mesh.info("🚫 \(logString, privacy: .public)")

			success = false
		} else if message.count < 1 {

			// Don't send an empty message
			Logger.mesh.info("🚫 Don't Send an Empty Message")
			success = false

		} else {
			guard let fromUserNum = self.connectedPeripheral?.num else {
				Logger.mesh.error("🚫 Connected peripheral user number is nil, cannot send message.")
				return false
			}

			let messageUsers = UserEntity.fetchRequest()
			messageUsers.predicate = NSPredicate(format: "num IN %@", [fromUserNum, Int64(toUserNum)])

			do {

				let fetchedUsers = try context.fetch(messageUsers)
				if fetchedUsers.isEmpty {

					Logger.data.error("🚫 Message Users Not Found, Fail")
					success = false
				} else if fetchedUsers.count >= 1 {

					let newMessage = MessageEntity(context: context)
					newMessage.messageId = Int64(UInt32.random(in: UInt32(UInt8.max)..<UInt32.max))
					newMessage.messageTimestamp =  Int32(Date().timeIntervalSince1970)
					newMessage.receivedACK = false
					newMessage.read = true
					if toUserNum > 0 {
						newMessage.toUser = fetchedUsers.first(where: { $0.num == toUserNum })
						newMessage.toUser?.lastMessage = Date()
						if newMessage.toUser?.pkiEncrypted ?? false {
							newMessage.publicKey = newMessage.toUser?.publicKey
							newMessage.pkiEncrypted = true
						}
					}
					newMessage.fromUser = fetchedUsers.first(where: { $0.num == fromUserNum })
					newMessage.isEmoji = isEmoji
					newMessage.admin = false
					newMessage.channel = channel
					if replyID > 0 {
						newMessage.replyID = replyID
					}
					newMessage.messagePayload = message
					newMessage.messagePayloadMarkdown = generateMessageMarkdown(message: message)
					newMessage.read = true

					let dataType = PortNum.textMessageApp
					var messageQuotesReplaced = message.replacingOccurrences(of: "’", with: "'")
					messageQuotesReplaced = message.replacingOccurrences(of: "”", with: "\"")
					let payloadData: Data = messageQuotesReplaced.data(using: String.Encoding.utf8)!

					var dataMessage = DataMessage()
					dataMessage.payload = payloadData
					dataMessage.portnum = dataType

					var meshPacket = MeshPacket()
					if newMessage.toUser?.pkiEncrypted ?? false {
						meshPacket.pkiEncrypted = true
						meshPacket.publicKey = newMessage.toUser?.publicKey ?? Data()
						// Auto Favorite nodes you DM so they don't roll out of the nodedb
						if !(newMessage.toUser?.userNode?.favorite ?? true) {
							newMessage.toUser?.userNode?.favorite = true
							do {
								try context.save()
								if let connectedPeripheral = self.connectedPeripheral {
									Logger.data.info("💾 Auto favorited node based on sending a message \(connectedPeripheral.num.toHex(), privacy: .public) to \(toUserNum.toHex(), privacy: .public)")
								} else {
									Logger.data.warning("⚠️ connectedPeripheral is nil while attempting to log auto-favoriting a node.")
								}
								guard let userNode = newMessage.toUser?.userNode else {
									Logger.data.warning("⚠️ Unable to set favorite node: userNode is nil.")
									return false
								}
								_ = self.setFavoriteNode(node: userNode, connectedNodeNum: fromUserNum)
							} catch {
								context.rollback()
								let nsError = error as NSError
								Logger.data.error("Unresolved Core Data error when auto favoriting in Send Message Function. Error: \(nsError, privacy: .public)")
							}
						}
					}
					meshPacket.id = UInt32(newMessage.messageId)
					if toUserNum > 0 {
						meshPacket.to = UInt32(toUserNum)
					} else {
						meshPacket.to = Constants.maximumNodeNum
					}
					meshPacket.channel = UInt32(channel)
					meshPacket.from	= UInt32(fromUserNum)
					meshPacket.decoded = dataMessage
					meshPacket.decoded.emoji = isEmoji ? 1 : 0
					if replyID > 0 {
						meshPacket.decoded.replyID = UInt32(replyID)
					}
					meshPacket.wantAck = true

					var toRadio: ToRadio!
					toRadio = ToRadio()
					toRadio.packet = meshPacket
					guard let binaryData: Data = try? toRadio.serializedData() else {
						return false
					}
					if connectedPeripheral?.peripheral.state ?? CBPeripheralState.disconnected == CBPeripheralState.connected {
						connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
						let logString = String.localizedStringWithFormat("Sent message %@ from %@ to %@".localized, String(newMessage.messageId), fromUserNum.toHex(), toUserNum.toHex())

						Logger.mesh.info("💬 \(logString, privacy: .public)")
						do {
							try context.save()
							Logger.data.info("💾 Saved a new sent message from \(self.connectedPeripheral?.num.toHex() ?? "0", privacy: .public) to \(toUserNum.toHex(), privacy: .public)")
							success = true

						} catch {
							context.rollback()
							let nsError = error as NSError
							Logger.data.error("Unresolved Core Data error in Send Message Function your database is corrupted running a node db reset should clean up the data. Error: \(nsError, privacy: .public)")
						}
					}
				}
			} catch {
				Logger.data.error("💥 Send message failure \(self.connectedPeripheral?.num.toHex() ?? "0", privacy: .public) to \(toUserNum.toHex(), privacy: .public)")
			}
		}
		return success
	}

	public func sendWaypoint(waypoint: Waypoint) -> Bool {
		if waypoint.latitudeI == 0 && waypoint.longitudeI == 0 {
			return false
		}
		var success = false
		let fromNodeNum = UInt32(connectedPeripheral.num)
		var meshPacket = MeshPacket()
		meshPacket.to = Constants.maximumNodeNum
		meshPacket.from	= fromNodeNum
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		do {
			dataMessage.payload = try waypoint.serializedData()
		} catch {
			// Could not serialiaze the payload
			return false
		}

		dataMessage.portnum = PortNum.waypointApp
		meshPacket.decoded = dataMessage
		var toRadio: ToRadio!
		toRadio = ToRadio()
		toRadio.packet = meshPacket
		guard let binaryData: Data = try? toRadio.serializedData() else {
			return false
		}
		let logString = String.localizedStringWithFormat("Sent a Waypoint Packet from: %@".localized, String(fromNodeNum))
		Logger.mesh.info("📍 \(logString, privacy: .public)")
		if connectedPeripheral?.peripheral.state ?? CBPeripheralState.disconnected == CBPeripheralState.connected {
			connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
			success = true
			let wayPointEntity = getWaypoint(id: Int64(waypoint.id), context: context)
			wayPointEntity.id = Int64(waypoint.id)
			wayPointEntity.name = waypoint.name.count >= 1 ? waypoint.name : "Dropped Pin"
			wayPointEntity.longDescription = waypoint.description_p
			wayPointEntity.icon	= Int64(waypoint.icon)
			wayPointEntity.latitudeI = waypoint.latitudeI
			wayPointEntity.longitudeI = waypoint.longitudeI
			if waypoint.expire > 1 {
				wayPointEntity.expire = Date.init(timeIntervalSince1970: Double(waypoint.expire))
			} else {
				wayPointEntity.expire = nil
			}
			if waypoint.lockedTo > 0 {
				wayPointEntity.locked = Int64(waypoint.lockedTo)
			} else {
				wayPointEntity.locked = 0
			}
			if wayPointEntity.created == nil {
				wayPointEntity.created = Date()
			} else {
				wayPointEntity.lastUpdated = Date()
			}
			do {
				try context.save()
				Logger.data.info("💾 Updated Waypoint from Waypoint App Packet From: \(fromNodeNum.toHex(), privacy: .public)")
			} catch {
				context.rollback()
				let nsError = error as NSError
				Logger.data.error("Error Saving NodeInfoEntity from WAYPOINT_APP \(nsError, privacy: .public)")
			}
		}
		return success
	}

	@MainActor
	public func getPositionFromPhoneGPS(destNum: Int64, fixedPosition: Bool) -> Position? {
		var positionPacket = Position()

		guard let lastLocation = LocationsHandler.shared.locationsArray.last else {
			return nil
		}

		if lastLocation == CLLocation(latitude: 0, longitude: 0) {
			return nil
		}

		positionPacket.latitudeI = Int32(lastLocation.coordinate.latitude * 1e7)
		positionPacket.longitudeI = Int32(lastLocation.coordinate.longitude * 1e7)
		let timestamp = lastLocation.timestamp
		positionPacket.time = UInt32(timestamp.timeIntervalSince1970)
		positionPacket.timestamp = UInt32(timestamp.timeIntervalSince1970)
		positionPacket.altitude = Int32(lastLocation.altitude)
		positionPacket.satsInView = UInt32(LocationsHandler.satsInView)
		let currentSpeed = lastLocation.speed
		if currentSpeed > 0 && (!currentSpeed.isNaN || !currentSpeed.isInfinite) {
			positionPacket.groundSpeed = UInt32(currentSpeed)
		}
		let currentHeading = lastLocation.course
		if (currentHeading > 0  && currentHeading <= 360) && (!currentHeading.isNaN || !currentHeading.isInfinite) {
			positionPacket.groundTrack = UInt32(currentHeading)
		}
		/// Set location source for time
		if !fixedPosition {
			/// From GPS treat time as good
			positionPacket.locationSource = Position.LocSource.locExternal
		} else {
			/// From GPS, but time can be old and have drifted
			positionPacket.locationSource = Position.LocSource.locManual
		}
		return positionPacket
	}

	@MainActor
	public func setFixedPosition(fromUser: UserEntity, channel: Int32) -> Bool {
		var adminPacket = AdminMessage()
		guard let positionPacket = getPositionFromPhoneGPS(destNum: fromUser.num, fixedPosition: true) else {
			return false
		}
		adminPacket.setFixedPosition = positionPacket
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(fromUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		meshPacket.channel = UInt32(channel)
		var dataMessage = DataMessage()
		meshPacket.decoded = dataMessage
		if let serializedData: Data = try? adminPacket.serializedData() {
			dataMessage.payload = serializedData
			dataMessage.portnum = PortNum.adminApp
			meshPacket.decoded = dataMessage
		} else {
			return false
		}
		let messageDescription = "🚀 Sent Set Fixed Postion Admin Message to: \(fromUser.longName ?? "Unknown".localized) from: \(fromUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func removeFixedPosition(fromUser: UserEntity, channel: Int32) -> Bool {
		var adminPacket = AdminMessage()
		adminPacket.removeFixedPosition = true
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(fromUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		meshPacket.channel = UInt32(channel)
		var dataMessage = DataMessage()
		if let serializedData: Data = try? adminPacket.serializedData() {
			dataMessage.payload = serializedData
			dataMessage.portnum = PortNum.adminApp
			meshPacket.decoded = dataMessage
		} else {
			return false
		}
		let messageDescription = "🚀 Sent Remove Fixed Position Admin Message to: \(fromUser.longName ?? "Unknown".localized) from: \(fromUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	@MainActor
	public func sendPosition(channel: Int32, destNum: Int64, wantResponse: Bool) -> Bool {
		let fromNodeNum = connectedPeripheral.num
		guard let positionPacket = getPositionFromPhoneGPS(destNum: destNum, fixedPosition: false) else {
			Logger.services.error("Unable to get position data from device GPS to send to node")
			return false
		}

		var meshPacket = MeshPacket()
		meshPacket.to = UInt32(destNum)
		meshPacket.channel = UInt32(channel)
		meshPacket.from	= UInt32(fromNodeNum)
		var dataMessage = DataMessage()
		if let serializedData: Data = try? positionPacket.serializedData() {
			dataMessage.payload = serializedData
			dataMessage.portnum = PortNum.positionApp
			dataMessage.wantResponse = wantResponse
			meshPacket.decoded = dataMessage
		} else {
			Logger.services.error("Failed to serialize position packet data")
			return false
		}

		var toRadio: ToRadio!
		toRadio = ToRadio()
		toRadio.packet = meshPacket
		guard let binaryData: Data = try? toRadio.serializedData() else {
			Logger.services.error("Failed to serialize position packet")
			return false
		}
		if connectedPeripheral?.peripheral.state ?? CBPeripheralState.disconnected == CBPeripheralState.connected {
			connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
			let logString = String.localizedStringWithFormat("Sent a Position Packet from the Apple device GPS to node: %@".localized, String(fromNodeNum))
			Logger.services.debug("📍 \(logString, privacy: .public)")
			return true
		} else {
			Logger.services.error("Device no longer connected. Unable to send position information.")
			return false
		}
	}

	@MainActor
	@objc func positionTimerFired(timer: Timer) {
		// Check for connected node
		if connectedPeripheral != nil {
			// Send a position out to the mesh if "share location with the mesh" is enabled in settings
			if UserDefaults.provideLocation {
				_ = sendPosition(channel: 0, destNum: connectedPeripheral.num, wantResponse: false)
			}
		}
	}

	public func sendTime() -> Bool {
		if self.connectedPeripheral?.num ?? 0 <= 0 {
			Logger.mesh.error("🚫 Unable to send time, connected node is disconnected or invalid")
			return false
		}
		var adminPacket = AdminMessage()
		adminPacket.setTimeOnly = UInt32(Date().timeIntervalSince1970)
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(self.connectedPeripheral.num)
		meshPacket.from = UInt32(self.connectedPeripheral.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		meshPacket.channel = 0
		var dataMessage = DataMessage()
		if let serializedData: Data = try? adminPacket.serializedData() {
			dataMessage.payload = serializedData
			dataMessage.portnum = PortNum.adminApp
			meshPacket.decoded = dataMessage
		} else {
			return false
		}
		let messageDescription = "🕛 Sent Set Time Admin Message to the connectecd node."
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func sendShutdown(fromUser: UserEntity, toUser: UserEntity) -> Bool {
		var adminPacket = AdminMessage()
		adminPacket.shutdownSeconds = 5
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		if let serializedData: Data = try? adminPacket.serializedData() {
			dataMessage.payload = serializedData
			dataMessage.portnum = PortNum.adminApp
			meshPacket.decoded = dataMessage
		} else {
			return false
		}
		let messageDescription = "🚀 Sent Shutdown Admin Message to: \(toUser.longName ?? "Unknown".localized) from: \(fromUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func sendReboot(fromUser: UserEntity, toUser: UserEntity) -> Bool {
		var adminPacket = AdminMessage()
		adminPacket.rebootSeconds = 5
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		if let serializedData: Data = try? adminPacket.serializedData() {
			dataMessage.payload = serializedData
			dataMessage.portnum = PortNum.adminApp
			meshPacket.decoded = dataMessage
		} else {
			return false
		}
		let messageDescription = "🚀 Sent Reboot Admin Message to: \(toUser.longName ?? "Unknown".localized) from: \(fromUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func sendRebootOta(fromUser: UserEntity, toUser: UserEntity) -> Bool {
		var adminPacket = AdminMessage()
		adminPacket.rebootOtaSeconds = 5
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		if let serializedData: Data = try? adminPacket.serializedData() {
			dataMessage.payload = serializedData
			dataMessage.portnum = PortNum.adminApp
			meshPacket.decoded = dataMessage
		} else {
			return false
		}
		let messageDescription = "🚀 Sent Reboot OTA Admin Message to: \(toUser.longName ?? "Unknown".localized) from: \(fromUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func sendEnterDfuMode(fromUser: UserEntity, toUser: UserEntity) -> Bool {
		var adminPacket = AdminMessage()
		adminPacket.enterDfuModeRequest = true
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		meshPacket.channel = UInt32(0)
		var dataMessage = DataMessage()
		if let serializedData: Data = try? adminPacket.serializedData() {
			dataMessage.payload = serializedData
			dataMessage.portnum = PortNum.adminApp
			meshPacket.decoded = dataMessage
		} else {
			return false
		}
		automaticallyReconnect = false
		let messageDescription = "🚀 Sent enter DFU mode Admin Message to: \(toUser.longName ?? "Unknown".localized) from: \(fromUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func sendFactoryReset(fromUser: UserEntity, toUser: UserEntity, resetDevice: Bool = false) -> Bool {
		var adminPacket = AdminMessage()
		if resetDevice {
			adminPacket.factoryResetDevice = 5
		} else {
			adminPacket.factoryResetConfig = 5
		}
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	=  UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		if let serializedData: Data = try? adminPacket.serializedData() {
			dataMessage.payload = serializedData
			dataMessage.portnum = PortNum.adminApp
			meshPacket.decoded = dataMessage
		} else {
			return false
		}

		let messageDescription = "🚀 Sent Factory Reset Admin Message to: \(toUser.longName ?? "Unknown".localized) from: \(fromUser.longName ??  "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func sendNodeDBReset(fromUser: UserEntity, toUser: UserEntity) -> Bool {
		var adminPacket = AdminMessage()
		adminPacket.nodedbReset = 5
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= 0 // UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp

		meshPacket.decoded = dataMessage
		let messageDescription = "🚀 Sent NodeDB Reset Admin Message to: \(toUser.longName ?? "Unknown".localized) from: \(fromUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func connectToPreferredPeripheral() -> Bool {
		var success = false
		// Return false if we are not properly connected to a device, handle retry logic in the view for now
		if connectedPeripheral == nil || connectedPeripheral!.peripheral.state != CBPeripheralState.connected {
			self.disconnectPeripheral()
			self.startScanning()
			// Try and connect to the preferredPeripherial first
			let preferredPeripheral = peripherals.filter({ $0.peripheral.identifier.uuidString == UserDefaults.standard.object(forKey: "preferredPeripheralId") as? String ?? "" }).first
			if preferredPeripheral != nil && preferredPeripheral?.peripheral != nil {
				connectTo(peripheral: preferredPeripheral!.peripheral)
				success = true
			}
		} else if connectedPeripheral != nil && isSubscribed {
			success = true
		}
		return success
	}

	public func getChannel(channel: Channel, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.getChannelRequest = UInt32(channel.index + 1)
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true
		meshPacket.decoded = dataMessage

		let messageDescription = "🎛️ Requested Channel \(channel.index) for \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return Int64(meshPacket.id)
		}
		return 0
	}
	public func saveChannel(channel: Channel, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setChannel = channel
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true
		meshPacket.decoded = dataMessage

		let messageDescription = "🛟 Saved Channel \(channel.index) for \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return Int64(meshPacket.id)
		}
		return 0
	}

	public func saveChannelSet(base64UrlString: String, addChannels: Bool = false, okToMQTT: Bool = false) -> Bool {
		if isConnected {

			var i: Int32 = 0
			var myInfo: MyInfoEntity
			// Before we get started delete the existing channels from the myNodeInfo
			if !addChannels {
				tryClearExistingChannels()
			}

			let decodedString = base64UrlString.base64urlToBase64()
			if let decodedData = Data(base64Encoded: decodedString) {
				do {
					let channelSet: ChannelSet = try ChannelSet(serializedBytes: decodedData)
					for cs in channelSet.settings {
						if addChannels {
							// We are trying to add a channel so lets get the last index
							let fetchMyInfoRequest = MyInfoEntity.fetchRequest()
							fetchMyInfoRequest.predicate = NSPredicate(format: "myNodeNum == %lld", Int64(connectedPeripheral.num))
							do {
								let fetchedMyInfo = try context.fetch(fetchMyInfoRequest)
								if fetchedMyInfo.count == 1 {
									i = Int32(fetchedMyInfo[0].channels?.count ?? -1)
									myInfo = fetchedMyInfo[0]
									// Bail out if the index is negative or bigger than our max of 8
									if i < 0 || i > 8 {
										return false
									}
									// Bail out if there are no channels or if the same channel name already exists
									guard let mutableChannels = myInfo.channels!.mutableCopy() as? NSMutableOrderedSet else {
										return false
									}
									if mutableChannels.first(where: {($0 as AnyObject).name == cs.name }) is ChannelEntity {
										return false
									}
								}
							} catch {
								Logger.data.error("Failed to find a node MyInfo to save these channels to: \(error.localizedDescription, privacy: .public)")
							}
						}

						var chan = Channel()
						if i == 0 {
							chan.role = Channel.Role.primary
						} else {
							chan.role = Channel.Role.secondary
						}
						chan.settings = cs
						chan.index = i
						i += 1

						var adminPacket = AdminMessage()
						adminPacket.setChannel = chan
						var meshPacket: MeshPacket = MeshPacket()
						meshPacket.to = UInt32(connectedPeripheral.num)
						meshPacket.from	= UInt32(connectedPeripheral.num)
						meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
						meshPacket.priority =  MeshPacket.Priority.reliable
						meshPacket.wantAck = true
						meshPacket.channel = 0
						var dataMessage = DataMessage()
						guard let adminData: Data = try? adminPacket.serializedData() else {
							return false
						}
						dataMessage.payload = adminData
						dataMessage.portnum = PortNum.adminApp
						meshPacket.decoded = dataMessage
						var toRadio: ToRadio!
						toRadio = ToRadio()
						toRadio.packet = meshPacket
						guard let binaryData: Data = try? toRadio.serializedData() else {
							return false
						}
						if connectedPeripheral?.peripheral.state ?? CBPeripheralState.disconnected == CBPeripheralState.connected {
							self.connectedPeripheral.peripheral.writeValue(binaryData, for: self.TORADIO_characteristic, type: .withResponse)
							let logString = String.localizedStringWithFormat("Sent a Channel for: %@ Channel Index %d".localized, String(connectedPeripheral.num), chan.index)
							Logger.mesh.info("🎛️ \(logString, privacy: .public)")
						}
					}
					// Save the LoRa Config and the device will reboot
					var adminPacket = AdminMessage()
					adminPacket.setConfig.lora = channelSet.loraConfig
					adminPacket.setConfig.lora.configOkToMqtt = okToMQTT // Preserve users okToMQTT choice
					var meshPacket: MeshPacket = MeshPacket()
					meshPacket.to = UInt32(connectedPeripheral.num)
					meshPacket.from	= UInt32(connectedPeripheral.num)
					meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
					meshPacket.priority =  MeshPacket.Priority.reliable
					meshPacket.wantAck = true
					meshPacket.channel = 0
					var dataMessage = DataMessage()
					guard let adminData: Data = try? adminPacket.serializedData() else {
						return false
					}
					dataMessage.payload = adminData
					dataMessage.portnum = PortNum.adminApp
					meshPacket.decoded = dataMessage
					var toRadio: ToRadio!
					toRadio = ToRadio()
					toRadio.packet = meshPacket
					guard let binaryData: Data = try? toRadio.serializedData() else {
						return false
					}
					if connectedPeripheral?.peripheral.state ?? CBPeripheralState.disconnected == CBPeripheralState.connected {
						self.connectedPeripheral.peripheral.writeValue(binaryData, for: self.TORADIO_characteristic, type: .withResponse)
						let logString = String.localizedStringWithFormat("Sent a LoRa.Config for: %@".localized, String(connectedPeripheral.num))
						Logger.mesh.info("📻 \(logString, privacy: .public)")
					}

					if self.connectedPeripheral != nil {
						self.sendWantConfig()
						return true
					}

				} catch {
					return false
				}
			}
		}
		return false
	}

	public func addContactFromURL(base64UrlString: String) -> Bool {
		if isConnected {

			let decodedString = base64UrlString.base64urlToBase64()
			if let decodedData = Data(base64Encoded: decodedString) {
				do {
					let contact: SharedContact = try SharedContact(serializedBytes: decodedData)
					var adminPacket = AdminMessage()
					adminPacket.addContact = contact
					var meshPacket: MeshPacket = MeshPacket()
					meshPacket.to = UInt32(connectedPeripheral.num)
					meshPacket.from	= UInt32(connectedPeripheral.num)
					meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
					meshPacket.priority =  MeshPacket.Priority.reliable
					meshPacket.wantAck = true
					meshPacket.channel = 0
					var dataMessage = DataMessage()
					guard let adminData: Data = try? adminPacket.serializedData() else {
						return false
					}
					dataMessage.payload = adminData
					dataMessage.portnum = PortNum.adminApp
					meshPacket.decoded = dataMessage
					var toRadio: ToRadio!
					toRadio = ToRadio()
					toRadio.packet = meshPacket
					guard let binaryData: Data = try? toRadio.serializedData() else {
						return false
					}

					// Create a NodeInfo (User) packet for the newly added contact
					var dataNodeMessage = DataMessage()
					if let nodeInfoData = try? contact.user.serializedData() {
						dataNodeMessage.payload = nodeInfoData
						dataNodeMessage.portnum = PortNum.nodeinfoApp
						var nodeMeshPacket = MeshPacket()
						nodeMeshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
						nodeMeshPacket.to = UInt32.max
						nodeMeshPacket.from = UInt32(contact.nodeNum)
						nodeMeshPacket.decoded = dataNodeMessage
						// Update local database with the new node info
						upsertNodeInfoPacket(packet: nodeMeshPacket, context: context)
					}

					if connectedPeripheral?.peripheral.state ?? CBPeripheralState.disconnected == CBPeripheralState.connected {
						self.connectedPeripheral.peripheral.writeValue(binaryData, for: self.TORADIO_characteristic, type: .withResponse)
						let logString = String.localizedStringWithFormat("Added contact %@ to device".localized, contact.user.longName)
						Logger.mesh.info("📻 \(logString, privacy: .public)")
					}

					if self.connectedPeripheral != nil {
						self.sendWantConfig()
						return true
					}

				} catch {
					Logger.data.error("Failed to decode contact data: \(error.localizedDescription, privacy: .public)")
					return false
				}
			}
		}
		return false
	}

	public func saveUser(config: User, fromUser: UserEntity, toUser: UserEntity) -> Int64 {
		var adminPacket = AdminMessage()
		adminPacket.setOwner = config
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		if let serializedData: Data = try? adminPacket.serializedData() {
			dataMessage.payload = serializedData
			dataMessage.portnum = PortNum.adminApp
			meshPacket.decoded = dataMessage
		} else {
			return 0
		}
		let messageDescription = "🛟 Saved User Config for \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return Int64(meshPacket.id)
		}
		return 0
	}

	public func removeNode(node: NodeInfoEntity, connectedNodeNum: Int64) -> Bool {
		var adminPacket = AdminMessage()
		adminPacket.removeByNodenum = UInt32(node.num)
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(connectedNodeNum)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		if let serializedData: Data = try? adminPacket.serializedData() {
			dataMessage.payload = serializedData
			dataMessage.portnum = PortNum.adminApp
			meshPacket.decoded = dataMessage
		} else {
			return false
		}
		var toRadio: ToRadio!
		toRadio = ToRadio()
		toRadio.packet = meshPacket
		guard let binaryData: Data = try? toRadio.serializedData() else {
			return false
		}

		if connectedPeripheral?.peripheral.state ?? CBPeripheralState.disconnected == CBPeripheralState.connected {
			do {
				connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
				context.delete(node.user!)
				context.delete(node)
				try context.save()
				return true
			} catch {
				context.rollback()
				let nsError = error as NSError
				Logger.data.error("🚫 Error deleting node from core data: \(nsError, privacy: .public)")
			}
		}
		return false
	}

	public func setFavoriteNode(node: NodeInfoEntity, connectedNodeNum: Int64) -> Bool {
		var adminPacket = AdminMessage()
		adminPacket.setFavoriteNode = UInt32(node.num)
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(connectedNodeNum)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage
		var toRadio: ToRadio!
		toRadio = ToRadio()
		toRadio.packet = meshPacket
		guard let binaryData: Data = try? toRadio.serializedData() else {
			return false
		}

		if connectedPeripheral?.peripheral.state ?? CBPeripheralState.disconnected == CBPeripheralState.connected {
			connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
			return true
		}
		return false
	}

	public func removeFavoriteNode(node: NodeInfoEntity, connectedNodeNum: Int64) -> Bool {
		var adminPacket = AdminMessage()
		adminPacket.removeFavoriteNode = UInt32(node.num)
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(connectedNodeNum)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage
		var toRadio: ToRadio!
		toRadio = ToRadio()
		toRadio.packet = meshPacket
		guard let binaryData: Data = try? toRadio.serializedData() else {
			return false
		}

		if connectedPeripheral?.peripheral.state ?? CBPeripheralState.disconnected == CBPeripheralState.connected {
			connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
			return true
		}
		return false
	}

	public func setIgnoredNode(node: NodeInfoEntity, connectedNodeNum: Int64) -> Bool {
		var adminPacket = AdminMessage()
		adminPacket.setIgnoredNode = UInt32(node.num)
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(connectedNodeNum)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage
		var toRadio: ToRadio!
		toRadio = ToRadio()
		toRadio.packet = meshPacket
		guard let binaryData: Data = try? toRadio.serializedData() else {
			return false
		}

		if connectedPeripheral?.peripheral.state ?? CBPeripheralState.disconnected == CBPeripheralState.connected {
			connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
			return true
		}
		return false
	}

	public func removeIgnoredNode(node: NodeInfoEntity, connectedNodeNum: Int64) -> Bool {
		var adminPacket = AdminMessage()
		adminPacket.removeIgnoredNode = UInt32(node.num)
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(connectedNodeNum)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage
		var toRadio: ToRadio!
		toRadio = ToRadio()
		toRadio.packet = meshPacket
		guard let binaryData: Data = try? toRadio.serializedData() else {
			return false
		}

		if connectedPeripheral?.peripheral.state ?? CBPeripheralState.disconnected == CBPeripheralState.connected {
			connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
			return true
		}
		return false
	}

	public func saveLicensedUser(ham: HamParameters, fromUser: UserEntity, toUser: UserEntity) -> Int64 {
		var adminPacket = AdminMessage()
		adminPacket.setHamMode = ham
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage
		let messageDescription = "🛟 Saved Ham Parameters for \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return Int64(meshPacket.id)
		}
		return 0
	}
	public func saveBluetoothConfig(config: Config.BluetoothConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {
		var adminPacket = AdminMessage()
		adminPacket.setConfig.bluetooth = config
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage
		let messageDescription = "🛟 Saved Bluetooth Config for \(toUser.longName ?? "Unknown".localized)"

		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			upsertBluetoothConfigPacket(config: config, nodeNum: toUser.num, sessionPasskey: toUser.userNode?.sessionPasskey, context: context)
			return Int64(meshPacket.id)
		}

		return 0
	}

	public func saveDeviceConfig(config: Config.DeviceConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setConfig.device = config
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage
		let messageDescription = "🛟 Saved Device Config for \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			upsertDeviceConfigPacket(config: config, nodeNum: toUser.num, sessionPasskey: toUser.userNode?.sessionPasskey, context: context)
			return Int64(meshPacket.id)
		}
		return 0
	}
	public func saveTimeZone(config: Config.DeviceConfig, user: Int64) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setConfig.device = config
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(user)
		meshPacket.from	= UInt32(user)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage
		let messageDescription = "⌚ Device Config timezone was empty set timezone to \(config.tzdef)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return Int64(meshPacket.id)
		}
		return 0
	}

	public func saveDisplayConfig(config: Config.DisplayConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {
		var adminPacket = AdminMessage()
		adminPacket.setConfig.display = config
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage
		let messageDescription = "🛟 Saved Display Config for \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			upsertDisplayConfigPacket(config: config, nodeNum: toUser.num, sessionPasskey: toUser.userNode?.sessionPasskey, context: context)
			return Int64(meshPacket.id)
		}
		return 0
	}

	public func saveLoRaConfig(config: Config.LoRaConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setConfig.lora = config
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage
		let messageDescription = "🛟 Saved LoRa Config for \(toUser.longName ?? "Unknown".localized)"

		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			upsertLoRaConfigPacket(config: config, nodeNum: toUser.num, sessionPasskey: toUser.userNode?.sessionPasskey, context: context)
			return Int64(meshPacket.id)
		}
		return 0
	}

	public func savePositionConfig(config: Config.PositionConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setConfig.position = config
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp

		meshPacket.decoded = dataMessage

		let messageDescription = "🛟 Saved Position Config for \(toUser.longName ?? "Unknown".localized)"

		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			upsertPositionConfigPacket(config: config, nodeNum: toUser.num, context: context)
			return Int64(meshPacket.id)
		}

		return 0
	}

	public func savePowerConfig(config: Config.PowerConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setConfig.power = config

		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp

		meshPacket.decoded = dataMessage

		let messageDescription = "🛟 Saved Power Config for \(toUser.longName ?? "Unknown".localized)"

		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			upsertPowerConfigPacket(config: config, nodeNum: toUser.num, context: context)
			return Int64(meshPacket.id)
		}

		return 0
	}

	public func saveNetworkConfig(config: Config.NetworkConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setConfig.network = config
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp

		meshPacket.decoded = dataMessage

		let messageDescription = "🛟 Saved Network Config for \(toUser.longName ?? "Unknown".localized)"

		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			upsertNetworkConfigPacket(config: config, nodeNum: toUser.num, context: context)
			return Int64(meshPacket.id)
		}

		return 0
	}

	public func saveSecurityConfig(config: Config.SecurityConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setConfig.security = config
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp

		meshPacket.decoded = dataMessage

		let messageDescription = "🛟 Saved Security Config for \(toUser.longName ?? "Unknown".localized)"

		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			upsertSecurityConfigPacket(config: config, nodeNum: toUser.num, context: context)
			return Int64(meshPacket.id)
		}

		return 0
	}

	public func saveAmbientLightingModuleConfig(config: ModuleConfig.AmbientLightingConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setModuleConfig.ambientLighting = config
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage

		let messageDescription = "🛟 Saved Ambient Lighting Module Config for \(toUser.longName ?? "Unknown".localized)"

		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			upsertAmbientLightingModuleConfigPacket(config: config, nodeNum: toUser.num, context: context)
			return Int64(meshPacket.id)
		}

		return 0
	}

	public func saveCannedMessageModuleConfig(config: ModuleConfig.CannedMessageConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setModuleConfig.cannedMessage = config
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage

		let messageDescription = "🛟 Saved Canned Message Module Config for \(toUser.longName ?? "Unknown".localized)"

		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			upsertCannedMessagesModuleConfigPacket(config: config, nodeNum: toUser.num, context: context)
			return Int64(meshPacket.id)
		}

		return 0
	}

	public func saveCannedMessageModuleMessages(messages: String, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setCannedMessageModuleMessages = messages
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true
		meshPacket.decoded = dataMessage

		let messageDescription = "🛟 Saved Canned Message Module Messages for \(toUser.longName ?? "Unknown".localized)"

		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {

			return Int64(meshPacket.id)
		}

		return 0
	}

	public func saveDetectionSensorModuleConfig(config: ModuleConfig.DetectionSensorConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setModuleConfig.detectionSensor = config
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage

		let messageDescription = "🛟 Saved Detection Sensor Module Config for \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			upsertDetectionSensorModuleConfigPacket(config: config, nodeNum: toUser.num, context: context)
			return Int64(meshPacket.id)
		}
		return 0
	}

	public func saveExternalNotificationModuleConfig(config: ModuleConfig.ExternalNotificationConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setModuleConfig.externalNotification = config
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage

		let messageDescription = "🛟 Saved External Notification Module Config for \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			upsertExternalNotificationModuleConfigPacket(config: config, nodeNum: toUser.num, context: context)
			return Int64(meshPacket.id)
		}
		return 0
	}

	public func savePaxcounterModuleConfig(config: ModuleConfig.PaxcounterConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setModuleConfig.paxcounter = config
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage

		let messageDescription = "🛟 Saved PAX Counter Module Config for \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			upsertPaxCounterModuleConfigPacket(config: config, nodeNum: toUser.num, context: context)
			return Int64(meshPacket.id)
		}

		return 0
	}

	public func saveRtttlConfig(ringtone: String, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setRingtoneMessage = ringtone
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage

		let messageDescription = "🛟 Saved RTTTL Ringtone Config for \(toUser.longName ?? "Unknown".localized)"

		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			upsertRtttlConfigPacket(ringtone: ringtone, nodeNum: toUser.num, context: context)
			return Int64(meshPacket.id)
		}

		return 0
	}

	public func saveMQTTConfig(config: ModuleConfig.MQTTConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setModuleConfig.mqtt = config
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp

		meshPacket.decoded = dataMessage

		let messageDescription = "🛟 Saved MQTT Config for \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			upsertMqttModuleConfigPacket(config: config, nodeNum: toUser.num, context: context)
			return Int64(meshPacket.id)
		}
		return 0
	}

	public func saveRangeTestModuleConfig(config: ModuleConfig.RangeTestConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setModuleConfig.rangeTest = config
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage

		let messageDescription = "🛟 Saved Range Test Module Config for \(toUser.longName ?? "Unknown".localized)"

		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			upsertRangeTestModuleConfigPacket(config: config, nodeNum: toUser.num, context: context)
			return Int64(meshPacket.id)
		}

		return 0
	}

	public func saveSerialModuleConfig(config: ModuleConfig.SerialConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setModuleConfig.serial = config
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage

		let messageDescription = "🛟 Saved Serial Module Config for \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			upsertSerialModuleConfigPacket(config: config, nodeNum: toUser.num, context: context)
			return Int64(meshPacket.id)
		}
		return 0
	}

	public func saveStoreForwardModuleConfig(config: ModuleConfig.StoreForwardConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setModuleConfig.storeForward = config
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage

		let messageDescription = "🛟 Saved Store & Forward Module Config for \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			upsertStoreForwardModuleConfigPacket(config: config, nodeNum: toUser.num, context: context)
			return Int64(meshPacket.id)
		}
		return 0
	}

	public func saveTelemetryModuleConfig(config: ModuleConfig.TelemetryConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setModuleConfig.telemetry = config
		if fromUser != toUser {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return 0
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage

		let messageDescription = "Saved Telemetry Module Config for \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			upsertTelemetryModuleConfigPacket(config: config, nodeNum: toUser.num, context: context)
			return Int64(meshPacket.id)
		}
		return 0
	}

	public func getChannel(channelIndex: UInt32, fromUser: UserEntity, toUser: UserEntity, wantResponse: Bool) -> Bool {

		var adminPacket = AdminMessage()
		adminPacket.getChannelRequest = channelIndex

		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = wantResponse

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true

		meshPacket.decoded = dataMessage

		let messageDescription = "🛎️ Sent a Get Channel \(channelIndex) Request Admin Message for node: \(toUser.longName ?? "Unknown".localized))"

		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {

			return true
		}

		return false
	}

	public func getCannedMessageModuleMessages(destNum: Int64, wantResponse: Bool) -> Bool {

		var adminPacket = AdminMessage()
		adminPacket.getCannedMessageModuleMessagesRequest = true

		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(destNum)
		meshPacket.from	= UInt32(connectedPeripheral.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		meshPacket.decoded.wantResponse = wantResponse

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = wantResponse

		meshPacket.decoded = dataMessage

		var toRadio: ToRadio!
		toRadio = ToRadio()
		toRadio.packet = meshPacket

		guard let binaryData: Data = try? toRadio.serializedData() else {
			return false
		}

		if connectedPeripheral?.peripheral.state ?? CBPeripheralState.disconnected == CBPeripheralState.connected {
			connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
			let logString = String.localizedStringWithFormat("Requested Canned Messages Module Messages for node: %@".localized, String(connectedPeripheral.num))
			Logger.mesh.info("🥫 \(logString, privacy: .public)")
			return true
		}

		return false
	}

	public func requestBluetoothConfig(fromUser: UserEntity, toUser: UserEntity) -> Bool {

		var adminPacket = AdminMessage()
		adminPacket.getConfigRequest = AdminMessage.ConfigType.bluetoothConfig
		if UserDefaults.enableAdministration {
			adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		}
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true

		meshPacket.decoded = dataMessage

		let messageDescription = "🛎️ Requested Bluetooth Config using an admin key for node: \(String(connectedPeripheral.num))"

		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func requestDeviceConfig(fromUser: UserEntity, toUser: UserEntity) -> Bool {

		var adminPacket = AdminMessage()
		adminPacket.getConfigRequest = AdminMessage.ConfigType.deviceConfig
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true

		meshPacket.decoded = dataMessage

		let messageDescription = "🛎️ Requested Device Config using an admin key for node: \(toUser.longName ?? "Unknown".localized)"

		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func requestDisplayConfig(fromUser: UserEntity, toUser: UserEntity) -> Bool {

		var adminPacket = AdminMessage()
		adminPacket.getConfigRequest = AdminMessage.ConfigType.displayConfig
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true

		meshPacket.decoded = dataMessage

		let messageDescription = "🛎️ Requested Display Config using an admin key for node: \(toUser.longName ?? "Unknown".localized)"

		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func requestLoRaConfig(fromUser: UserEntity, toUser: UserEntity) -> Bool {

		var adminPacket = AdminMessage()
		adminPacket.getConfigRequest = AdminMessage.ConfigType.loraConfig
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true

		meshPacket.decoded = dataMessage

		let messageDescription = "🛎️ Requested LoRa Config using an admin key for node: \(toUser.longName ?? "Unknown".localized)"

		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {

			return true
		}

		return false
	}

	public func requestNetworkConfig(fromUser: UserEntity, toUser: UserEntity) -> Bool {

		var adminPacket = AdminMessage()
		adminPacket.getConfigRequest = AdminMessage.ConfigType.networkConfig
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true
		meshPacket.decoded = dataMessage

		let messageDescription = "🛎️ Requested Network Config using an admin Key for node: \(toUser.longName ?? "Unknown".localized)"

		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func requestPositionConfig(fromUser: UserEntity, toUser: UserEntity) -> Bool {

		var adminPacket = AdminMessage()
		adminPacket.getConfigRequest = AdminMessage.ConfigType.positionConfig
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true

		meshPacket.decoded = dataMessage

		let messageDescription = "🛎️ Requested Position Config using an admin key for node: \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func requestPowerConfig(fromUser: UserEntity, toUser: UserEntity) -> Bool {

		var adminPacket = AdminMessage()
		adminPacket.getConfigRequest = AdminMessage.ConfigType.powerConfig
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true

		meshPacket.decoded = dataMessage

		let messageDescription = "🛎️ Requested Power Config using an admin key for node: \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func requestSecurityConfig(fromUser: UserEntity, toUser: UserEntity) -> Bool {

		var adminPacket = AdminMessage()
		adminPacket.getConfigRequest = AdminMessage.ConfigType.securityConfig
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true

		meshPacket.decoded = dataMessage

		let messageDescription = "🛎️ Requested Security Config using an admin key for node: \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func requestAmbientLightingConfig(fromUser: UserEntity, toUser: UserEntity) -> Bool {

		var adminPacket = AdminMessage()
		adminPacket.getModuleConfigRequest = AdminMessage.ModuleConfigType.ambientlightingConfig
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true

		meshPacket.decoded = dataMessage

		let messageDescription = "🛎️ Requested Ambient Lighting Config using an admin key for node: \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func requestCannedMessagesModuleConfig(fromUser: UserEntity, toUser: UserEntity) -> Bool {

		var adminPacket = AdminMessage()
		adminPacket.getModuleConfigRequest = AdminMessage.ModuleConfigType.cannedmsgConfig
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true

		meshPacket.decoded = dataMessage

		let messageDescription = "🛎️ Requested Canned Messages Module Config using an admin key for node: \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func requestExternalNotificationModuleConfig(fromUser: UserEntity, toUser: UserEntity) -> Bool {

		var adminPacket = AdminMessage()
		adminPacket.getModuleConfigRequest = AdminMessage.ModuleConfigType.extnotifConfig
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true

		meshPacket.decoded = dataMessage

		let messageDescription = "🛎️ Requested External Notificaiton Module Config using an admin key for node: \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func requestPaxCounterModuleConfig(fromUser: UserEntity, toUser: UserEntity) -> Bool {

		var adminPacket = AdminMessage()
		adminPacket.getModuleConfigRequest = AdminMessage.ModuleConfigType.paxcounterConfig
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true

		meshPacket.decoded = dataMessage

		let messageDescription = "🛎️ Requested PAX Counter Module Config using an admin key for node: \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func requestRtttlConfig(fromUser: UserEntity, toUser: UserEntity) -> Bool {

		var adminPacket = AdminMessage()
		adminPacket.getRingtoneRequest = true
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true

		meshPacket.decoded = dataMessage

		let messageDescription = "🛎️ Requested RTTTL Ringtone Config using an admin key for node: \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func requestRangeTestModuleConfig(fromUser: UserEntity, toUser: UserEntity) -> Bool {

		var adminPacket = AdminMessage()
		adminPacket.getModuleConfigRequest = AdminMessage.ModuleConfigType.rangetestConfig
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true

		meshPacket.decoded = dataMessage

		let messageDescription = "🛎️ Requested Range Test Module Config using an admin key for node: \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func requestMqttModuleConfig(fromUser: UserEntity, toUser: UserEntity) -> Bool {

		var adminPacket = AdminMessage()
		adminPacket.getModuleConfigRequest = AdminMessage.ModuleConfigType.mqttConfig
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true

		meshPacket.decoded = dataMessage

		let messageDescription = "🛎️ Requested MQTT Module Config using an admin key for node: \(String(connectedPeripheral.num))"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func requestDetectionSensorModuleConfig(fromUser: UserEntity, toUser: UserEntity) -> Bool {

		var adminPacket = AdminMessage()
		adminPacket.getModuleConfigRequest = AdminMessage.ModuleConfigType.detectionsensorConfig
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true

		meshPacket.decoded = dataMessage

		let messageDescription = "🛎️ Requested Detection Sensor Module Config using an admin key for node: \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func requestSerialModuleConfig(fromUser: UserEntity, toUser: UserEntity) -> Bool {

		var adminPacket = AdminMessage()
		adminPacket.getModuleConfigRequest = AdminMessage.ModuleConfigType.serialConfig
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true

		meshPacket.decoded = dataMessage

		let messageDescription = "🛎️ Requested Serial Module Config using an admin key for node: \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func requestStoreAndForwardModuleConfig(fromUser: UserEntity, toUser: UserEntity) -> Bool {

		var adminPacket = AdminMessage()
		adminPacket.getModuleConfigRequest = AdminMessage.ModuleConfigType.storeforwardConfig
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true

		meshPacket.decoded = dataMessage

		let messageDescription = "🛎️ Requested Store and Forward Module Config using an admin key for node: \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	public func requestTelemetryModuleConfig(fromUser: UserEntity, toUser: UserEntity) -> Bool {

		var adminPacket = AdminMessage()
		adminPacket.getModuleConfigRequest = AdminMessage.ModuleConfigType.telemetryConfig
		adminPacket.sessionPasskey = toUser.userNode?.sessionPasskey ?? Data()
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true

		var dataMessage = DataMessage()
		guard let adminData: Data = try? adminPacket.serializedData() else {
			return false
		}
		dataMessage.payload = adminData
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true

		meshPacket.decoded = dataMessage

		let messageDescription = "🛎️ Requested Telemetry Module Config using an admin key for node: \(toUser.longName ?? "Unknown".localized)"
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription) {
			return true
		}
		return false
	}

	// Send an admin message to a radio, save a message to core data for logging
	private func sendAdminMessageToRadio(meshPacket: MeshPacket, adminDescription: String) -> Bool {

		var toRadio: ToRadio!
		toRadio = ToRadio()
		toRadio.packet = meshPacket
		guard let binaryData: Data = try? toRadio.serializedData() else {
			return false
		}

		if connectedPeripheral?.peripheral.state ?? CBPeripheralState.disconnected == CBPeripheralState.connected {
			connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
			Logger.mesh.debug("\(adminDescription, privacy: .public)")
			return true
		}
		return false
	}

	public func requestStoreAndForwardClientHistory(fromUser: UserEntity, toUser: UserEntity) -> Bool {

		/// send a request for ClientHistory with a time period matching the heartbeat
		var sfPacket = StoreAndForward()
		sfPacket.rr = StoreAndForward.RequestResponse.clientHistory
		sfPacket.history.window = UInt32(toUser.userNode?.storeForwardConfig?.historyReturnWindow ?? 120)
		sfPacket.history.lastRequest = UInt32(toUser.userNode?.storeForwardConfig?.lastRequest ?? 0)
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		guard let sfData: Data = try? sfPacket.serializedData() else {
			return false
		}
		dataMessage.payload = sfData
		dataMessage.portnum = PortNum.storeForwardApp
		dataMessage.wantResponse = true
		meshPacket.decoded = dataMessage

		var toRadio: ToRadio!
		toRadio = ToRadio()
		toRadio.packet = meshPacket
		guard let binaryData: Data = try? toRadio.serializedData() else {
			return false
		}
		if connectedPeripheral?.peripheral.state ?? CBPeripheralState.disconnected == CBPeripheralState.connected {
			connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
			Logger.mesh.debug("📮 Sent a request for a Store & Forward Client History to \(toUser.num.toHex(), privacy: .public) for the last \(120, privacy: .public) minutes.")
			return true
		}
		return false
	}

	func storeAndForwardPacket(packet: MeshPacket, connectedNodeNum: Int64, context: NSManagedObjectContext) {
		if let storeAndForwardMessage = try? StoreAndForward(serializedBytes: packet.decoded.payload) {
			// Handle each of the store and forward request / response messages
			switch storeAndForwardMessage.rr {
			case .unset:
				Logger.mesh.info("\("📮 Store and Forward \(storeAndForwardMessage.rr) message received from \(packet.from.toHex())")")
			case .routerError:
				Logger.mesh.info("\("☠️ Store and Forward \(storeAndForwardMessage.rr) message received from \(packet.from.toHex())")")
			case .routerHeartbeat:
				/// When we get a router heartbeat we know there is a store and forward node on the network
				/// Check if it is the primary S&F Router and save the timestamp of the last heartbeat so that we can show the request message history menu item on node long press if the router has been seen recently
				if storeAndForwardMessage.heartbeat.secondary == 0 {

					guard let routerNode = getNodeInfo(id: Int64(packet.from), context: context) else {
						return
					}
					if routerNode.storeForwardConfig != nil {
						routerNode.storeForwardConfig?.enabled = true
						routerNode.storeForwardConfig?.isRouter = storeAndForwardMessage.heartbeat.secondary == 0
						routerNode.storeForwardConfig?.lastHeartbeat = Date()
					} else {
						let newConfig = StoreForwardConfigEntity(context: context)
						newConfig.enabled = true
						newConfig.isRouter = storeAndForwardMessage.heartbeat.secondary == 0
						newConfig.lastHeartbeat = Date()
						routerNode.storeForwardConfig = newConfig
					}

					do {
						try context.save()
					} catch {
						context.rollback()
						Logger.data.error("Save Store and Forward Router Error")
					}
				}
				Logger.mesh.info("\("💓 Store and Forward \(storeAndForwardMessage.rr) message received from \(packet.from.toHex())")")
			case .routerPing:
				Logger.mesh.info("\("🏓 Store and Forward \(storeAndForwardMessage.rr) message received from \(packet.from.toHex())")")
			case .routerPong:
				Logger.mesh.info("\("🏓 Store and Forward \(storeAndForwardMessage.rr) message received from \(packet.from.toHex())")")
			case .routerBusy:
				Logger.mesh.info("\("🐝 Store and Forward \(storeAndForwardMessage.rr) message received from \(packet.from.toHex())")")
			case .routerHistory:
				/// Set the Router History Last Request Value
				guard let routerNode = getNodeInfo(id: Int64(packet.from), context: context) else {
					return
				}
				if routerNode.storeForwardConfig != nil {
					routerNode.storeForwardConfig?.lastRequest = Int32(storeAndForwardMessage.history.lastRequest)
				} else {
					let newConfig = StoreForwardConfigEntity(context: context)
					newConfig.lastRequest = Int32(storeAndForwardMessage.history.lastRequest)
					routerNode.storeForwardConfig = newConfig
				}

				do {
					try context.save()
				} catch {
					context.rollback()
					Logger.data.error("Save Store and Forward Router Error")
				}
				Logger.mesh.info("\("📜 Store and Forward \(storeAndForwardMessage.rr) message received from \(packet.from.toHex())")")
			case .routerStats:
				Logger.mesh.info("\("📊 Store and Forward \(storeAndForwardMessage.rr) message received from \(packet.from.toHex())")")
			case .clientError:
				Logger.mesh.info("\("☠️ Store and Forward \(storeAndForwardMessage.rr) message received from \(packet.from.toHex())")")
			case .clientHistory:
				Logger.mesh.info("\("📜 Store and Forward \(storeAndForwardMessage.rr) message received from \(packet.from.toHex())")")
			case .clientStats:
				Logger.mesh.info("\("📊 Store and Forward \(storeAndForwardMessage.rr) message received from \(packet.from.toHex())")")
			case .clientPing:
				Logger.mesh.info("\("🏓 Store and Forward \(storeAndForwardMessage.rr) message received from \(packet.from.toHex())")")
			case .clientPong:
				Logger.mesh.info("\("🏓 Store and Forward \(storeAndForwardMessage.rr) message received from \(packet.from.toHex())")")
			case .clientAbort:
				Logger.mesh.info("\("🛑 Store and Forward \(storeAndForwardMessage.rr) message received from \(packet.from.toHex())")")
			case .UNRECOGNIZED:
				Logger.mesh.info("\("📮 Store and Forward \(storeAndForwardMessage.rr) message received from \(packet.from.toHex())")")
			case .routerTextDirect:
				Logger.mesh.info("\("💬 Store and Forward \(storeAndForwardMessage.rr) message received from \(packet.from.toHex())")")
				textMessageAppPacket(
					packet: packet,
					wantRangeTestPackets: false,
					connectedNode: connectedNodeNum,
					storeForward: true,
					context: context,
					appState: appState
				)
			case .routerTextBroadcast:
				Logger.mesh.info("\("✉️ Store and Forward \(storeAndForwardMessage.rr) message received from \(packet.from.toHex())")")
				textMessageAppPacket(
					packet: packet,
					wantRangeTestPackets: false,
					connectedNode: connectedNodeNum,
					storeForward: true,
					context: context,
					appState: appState
				)
			}
		}
	}

	public func tryClearExistingChannels() {
		// Before we get started delete the existing channels from the myNodeInfo
		let fetchMyInfoRequest = MyInfoEntity.fetchRequest()
		fetchMyInfoRequest.predicate = NSPredicate(format: "myNodeNum == %lld", Int64(connectedPeripheral.num))

		do {
			let fetchedMyInfo = try context.fetch(fetchMyInfoRequest)
			if fetchedMyInfo.count == 1 {
				let mutableChannels = fetchedMyInfo[0].channels?.mutableCopy() as? NSMutableOrderedSet
				mutableChannels?.removeAllObjects()
				fetchedMyInfo[0].channels = mutableChannels
				do {
					try context.save()
				} catch {
					Logger.data.error("Failed to clear existing channels from local app database: \(error.localizedDescription, privacy: .public)")
				}
			}
		} catch {
			Logger.data.error("Failed to find a node MyInfo to save these channels to: \(error.localizedDescription, privacy: .public)")
		}
	}
}

// MARK: - CB Central Manager implmentation
extension BLEManager: CBCentralManagerDelegate {

	// MARK: Bluetooth enabled/disabled
	func centralManagerDidUpdateState(_ central: CBCentralManager) {
		if central.state == CBManagerState.poweredOn {
			Logger.services.info("✅ [BLE] powered on")
			isSwitchedOn = true
			startScanning()
		} else {
			isSwitchedOn = false
		}

		var status = ""
		switch central.state {
		case .poweredOff:
			status = "BLE is powered off"
		case .poweredOn:
			status = "BLE is poweredOn"
		case .resetting:
			status = "BLE is resetting"
		case .unauthorized:
			status = "BLE is unauthorized"
		case .unknown:
			status = "BLE is unknown"
		case .unsupported:
			status = "BLE is unsupported"
		default:
			status = "Default".localized
		}
		Logger.services.info("📜 [BLE] Bluetooth status: \(status, privacy: .public)")
	}

	// Called each time a peripheral is discovered
	func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
		if self.automaticallyReconnect && peripheral.identifier.uuidString == UserDefaults.standard.object(forKey: "preferredPeripheralId") as? String ?? "" {
			self.connectTo(peripheral: peripheral)
			Logger.services.info("✅ [BLE] Reconnecting to prefered peripheral: \(peripheral.name ?? "Unknown", privacy: .public)")
		}
		let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
		let device = Peripheral(id: peripheral.identifier.uuidString, num: 0, name: name ?? "Unknown", shortName: "?", longName: name ?? "Unknown", firmwareVersion: "Unknown", rssi: RSSI.intValue, lastUpdate: Date(), peripheral: peripheral)
		let index = peripherals.map { $0.peripheral }.firstIndex(of: peripheral)
		if let peripheralIndex = index {
			peripherals[peripheralIndex] = device
		} else {
			peripherals.append(device)
		}
		let today = Date()
		let visibleDuration = Calendar.current.date(byAdding: .second, value: -5, to: today)!
		self.peripherals.removeAll(where: { $0.lastUpdate < visibleDuration})
	}
}
