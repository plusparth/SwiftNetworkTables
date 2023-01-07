//
//  NT4Client.swift
//  
//
//  Created by Parth Oza on 1/5/23.
//

import Foundation
import Starscream
import MessagePack
import Stream
import GenericJSON

public class NT4Client {
    private let appName: String
    private let onTopicAnnounce: (NT4Topic) -> Void
    private let onTopicUnannounce: (NT4Topic) -> Void
    private let onNewTopicData: (NT4Topic, Int64, MessagePack) -> Void
    
    private let onConnect: () -> Void
    private let onDisconnect: () -> Void
    
    private let serverBaseAddress: String
    private var ws: WebSocket?
    private var wsDelegate: NTWebSocketDelegate?
    private var clientIdx = 0
    private let useSecure = false
    private var serverAddress: String = ""
    private var serverConnectionActive = false
    private var serverConnectionRequested = false
    private var serverTimeOffsetMicros: Int64?
    private var networkLatencyMicros: Int64?
    
    private var uidCounter = 0
    private var subscriptions: [Int:NT4Subscription] = [:]
    private var publishedTopics: [String:NT4Topic] = [:]
    private var serverTopics: [String:NT4Topic] = [:]
    
    private var timer: Timer?
    
    private var jsonEncoder = JSONEncoder()
    private var jsonDecoder = JSONDecoder()
    
    public init(appName: String, onTopicAnnounce: @escaping (NT4Topic) -> Void, onTopicUnannounce: @escaping (NT4Topic) -> Void, onNewTopicData: @escaping (NT4Topic, Int64, MessagePack) -> Void, onConnect: @escaping () -> Void, onDisconnect: @escaping () -> Void, serverBaseAddress: String) {
        self.appName = appName
        self.onTopicAnnounce = onTopicAnnounce
        self.onTopicUnannounce = onTopicUnannounce
        self.onNewTopicData = onNewTopicData
        self.onConnect = onConnect
        self.onDisconnect = onDisconnect
        self.serverBaseAddress = serverBaseAddress
        
    }
    
    
    // MARK: - Public API
    
    public func connect() {
        if !serverConnectionRequested {
            serverConnectionRequested = true
            socketConnect()
            
            self.timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
                self.socketSendTimestamp()
            }
        }
    }
    
    public func disconnect() {
        if serverConnectionRequested {
            serverConnectionRequested = false
            if serverConnectionActive {
                ws?.disconnect(closeCode: 0)
                serverConnectionActive = false
                timer?.invalidate()
            }
        }
    }
    
    public func subscribe(topicPatterns: [String], prefixMode: Bool, sendAll: Bool = false, periodic: Float = 0.1) -> Int {
        let options = NT4SubscriptionOptions(periodic: periodic, sendAll: sendAll, prefixMode: prefixMode)
        let newSub = NT4Subscription(uid: getNewUID(), topics: topicPatterns, options: options)
        
        subscriptions[newSub.uid] = newSub
        if (serverConnectionActive) {
            socketSubscribe(subscription: newSub)
        }
        
        return newSub.uid
    }
    
    public func subscribeTopicsOnly(topicPatterns: [String], prefixMode: Bool) -> Int {
        let options = NT4SubscriptionOptions(topicsOnly: true, prefixMode: prefixMode)
        let newSub = NT4Subscription(uid: getNewUID(), topics: topicPatterns, options: options)
        
        subscriptions[newSub.uid] = newSub
        if (serverConnectionActive) {
            socketSubscribe(subscription: newSub)
        }
        
        return newSub.uid
    }
    
    public func unsubscribe(subscriptionId: Int) {
        if let subscription = subscriptions[subscriptionId] {
            subscriptions.removeValue(forKey: subscriptionId)
            if serverConnectionActive {
                socketUnsubscribe(subscription: subscription)
            }
        }
    }
    
    public func clearAllSubscriptions() {
        for (id, _) in subscriptions {
            unsubscribe(subscriptionId: id)
        }
    }
    
    public func setProperties(topic: String, properties: NT4TopicProperties) {
        publishedTopics[topic]?.properties = properties
        serverTopics[topic]?.properties = properties
        
        if serverConnectionActive {
            socketSetProperties(topic: topic, newProperties: properties)
        }
    }
    
    
    // TODO: persistent and retained
    
    public func publishTopic(topic: String, type: String) {
        if let _ =  publishedTopics[topic] {
            return
        }
        
        let newTopic = NT4Topic(uid: getNewUID(), name: topic, type: type, properties: NT4TopicProperties())
        publishedTopics[topic] = newTopic
        
        if serverConnectionActive {
            socketPublish(topic: newTopic)
        }
    }
    
    public func unpublishTopic(topic: String) {
        if let topicObject = publishedTopics[topic] {
            publishedTopics.removeValue(forKey: topic)
            
            if serverConnectionActive {
                socketUnpublish(topic: topicObject)
            }
        }
    }
    
    public func addSample(topic: String, value: MessagePack) {
        // TODO: figure out type checking here
        addTimestampedSample(topic: topic, timestamp: getServerTimeMicros() ?? 0, value: value)
    }
    
    public func addTimestampedSample(topic: String, timestamp: Int64, value: MessagePack) {
        if let topicObject = publishedTopics[topic] {
            Task { // TODO: is there a better way to do this?
                let msg = serialize(topicId: topicObject.uid, timestamp: timestamp, typeId: typeStringToIdxLookup(type: topicObject.type), data: value)
                let bytes = try await MessagePack.encode(msg)
                socketSendBinary(data: Data(bytes))
            }
        }
    }
    
    // MARK: - Time Sync Handling
    
    public func getClientTimeMicros() -> Int64 {
        return Int64(DispatchTime.now().uptimeNanoseconds / 1000);
    }
    
    public func getServerTimeMicros() -> Int64? {
        if let timeOffset = self.serverTimeOffsetMicros {
            return getClientTimeMicros() + timeOffset
        } else {
            return nil
        }
    }
    
    public func getNetworkLatencyMicros() -> Int64? {
        return networkLatencyMicros
    }
    
    private func socketSendTimestamp() {
        Task { // TODO: is there a better way to do this?
            let timeToSend = getClientTimeMicros()
            let msg = serialize(topicId: -1, timestamp: 0, typeId: typeStringToIdxLookup(type: "int"), data: MessagePack(timeToSend))
            let bytes = try await MessagePack.encode(msg)
            socketSendBinary(data: Data(bytes))
        }
        
    }
    
    private func onSocketReceiveTimestamp(serverTimestamp: Int64, clientTimestamp: Int64) {
        let receiveTimestamp = self.getClientTimeMicros()
        
        let roundTripTime = receiveTimestamp - clientTimestamp
        self.networkLatencyMicros = roundTripTime / 2
        
        if let networkLatencyMicros = self.networkLatencyMicros {
            let serverTimeOnReceive = serverTimestamp + networkLatencyMicros
            self.serverTimeOffsetMicros = serverTimeOnReceive - receiveTimestamp
            
            // TODO: log timestamp here
        }
    }
    
    
    // MARK: - Socket Message Send Handlers
    
    private func socketSubscribe(subscription: NT4Subscription) {
        socketSendJSON(method: "subscribe", data: subscription.toSubscribeObject())
    }
    
    private func socketUnsubscribe(subscription: NT4Subscription) {
        socketSendJSON(method: "unsubscribe", data: subscription.toUnsubscribeObject())
    }
    
    private func socketPublish(topic: NT4Topic) {
        socketSendJSON(method: "publish", data: topic.toPublishObject())
    }
    
    private func socketUnpublish(topic: NT4Topic) {
        socketSendJSON(method: "unpublish", data: topic.toUnpublishObject())
    }
    
    private func socketSetProperties(topic: String, newProperties: NT4TopicProperties) {
        do {
            let propertiesJSON = try JSON(encodable: newProperties)
            let propertiesUpdate: JSON = [
                "name": JSON(stringLiteral: topic),
                "update": propertiesJSON
            ]
            socketSendJSON(method: "setproperties", data: propertiesUpdate)
        } catch {
            
        }
    }
    
    private func socketSendJSON(method: String, data: Encodable) {
        if let ws = self.ws {
            do {
                if let jsonString = String(data: try jsonEncoder.encode(data), encoding: .utf8) {
                    ws.write(string: jsonString)
                }
            } catch {
                // TODO: log
                return
            }
        }
    }
    
    private func socketSendBinary(data: Data) {
        if self.serverConnectionActive {
            ws?.write(data: data)
        }
    }
    
    
    // MARK: - Socket Message Receive Handlers
    
    private func onSocketConnected() {
        serverConnectionActive = true
        
        // Sync timestamps to start
        socketSendTimestamp()
        
        
        for (_, topic) in publishedTopics {
            socketPublish(topic: topic)
        }
        
        for (_, subscription) in subscriptions {
            socketSubscribe(subscription: subscription)
        }
        
        // User provided on connect function
        self.onConnect()
    }
    
    private func onSocketDisconnected(reason: String, code: UInt16) {
        serverConnectionActive = false
        
        // User provided disconnect function
        onDisconnect()
        
        serverTopics.removeAll()
        
        if !reason.isEmpty {
            // TODO: log reason here
        }
        
        if serverConnectionRequested {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { timer in
                self.socketConnect()
            }
        }
        
    }
    
    private func onSocketTextMessage(message: String) {
        do {
            let data = try jsonDecoder.decode(JSON.self, from: Data(message.utf8))
            if let method = data.objectValue?["method"]?.stringValue {
                if let params = data.objectValue?["params"]?.objectValue {
                    switch method {
                    case "announce":
                        if let uid = params["id"]?.doubleValue, let name = params["name"]?.stringValue, let type = params["type"]?.stringValue, let properties = params["properties"]?.objectValue {
                                                
                            let topic = NT4Topic(uid: Int(uid), name: name, type: type, properties: NT4TopicProperties(jsonObject: properties))
                            serverTopics[name] = topic
                            
                            // User provided function
                            onTopicAnnounce(topic)
                        }
                    case "unannounce":
                        if let name = params["name"]?.stringValue, let topic = serverTopics[name] {
                            serverTopics.removeValue(forKey: name)
                            
                            // User provided function
                            onTopicUnannounce(topic)
                        } else {
                            // TODO: error
                        }
                    case "properties":
                        if let name = params["name"]?.stringValue, let propertiesDict = params["update"]?.objectValue {
                            let newProperties = NT4TopicProperties(jsonObject: propertiesDict)
                            serverTopics[name]?.properties = newProperties
                        }
                    default:
                        // TODO: error
                        print("no u")
                    }
                } else {
                    
                }
            } else {
                
            }
        } catch {
            
        }
        
    }
    
    private func onSocketBinaryMessage(message: Data) {
        let currentTimestamp = getClientTimeMicros()
        Task {
            var decoder = MessagePackReader(InputByteStream([UInt8](message)))
            do {
                // decode as many arrays as we can
                while let decodedArray = try await decoder.decode().arrayValue {
                    if decodedArray.count == 4 {
                        if let topicID = decodedArray[0].integerValue, let timestamp = decodedArray[1].integerValue {
                            if topicID >= 0 {
                                for (_, topic) in serverTopics {
                                    if topic.uid == topicID {
                                        onNewTopicData(topic, Int64(timestamp), decodedArray[3])
                                    }
                                }
                            } else if topicID == -1 {
                                if let serverTimestamp = decodedArray[3].integerValue {
                                    onSocketReceiveTimestamp(serverTimestamp: Int64(serverTimestamp), clientTimestamp: currentTimestamp)
                                }
                            }
                        }
                    }
                }
//                let topicId = try await decoder.decode(Int.self)
//                let timestamp = try await decoder.decode()
//                let type = try await decoder.decode(Int.self)
                
//                let value = try await decoder.decode()
            
                
//                switch type {
//                case 0:
//                    value = try await decoder.decode(Bool.self)
//                case 1:
//                    value = try await decoder.decode(Double.self)
//                case 2:
//                    value = try await decoder.decode(Int.self)
//                case 3:
//                    value = try await decoder.decode(Float.self)
//                case 4:
//                    value = try await decoder.decode(String.self)
//                case 5:
//                    value = try await decoder.decode([UInt8].self)
//                case 16:
//                    value = try await decoder.decode([Bool].self)
//                case 17:
//                    value = try await decoder.decode([Double].self)
//                case 18:
//                    value = try await decoder.decode([Int].self)
//                case 19:
//                    value = try await decoder.decode([Float].self)
//                case 20:
//                    value = try await decoder.decode([String].self)
//                }
                
            } catch {
                
            }
        }
        
    }
    
    private func onError(error: Error?) {
        // TODO: Is this right?
        onSocketDisconnected(reason: "", code: 1)
//        self.ws?.disconnect(closeCode: 0);
    }
    
    private func socketConnect() {
        clientIdx = Int.random(in: 0..<1000000000)
        
        let port: Int
        let prefix: String
        if useSecure {
            prefix = "wss"
            port = 5811
        } else {
            prefix = "ws"
            port = 5810
        }
        
        serverAddress = "\(prefix)://\(serverBaseAddress):\(port)/nt/\(appName)_\(clientIdx)"
        
        var request = URLRequest(url: URL(string: serverAddress)!)
        
        request.timeoutInterval = 5
        
        self.ws = WebSocket(request: request)
        wsDelegate = NTWebSocketDelegate(onConnected: onSocketConnected, onTextMessage: onSocketTextMessage, onBinaryMessage: onSocketBinaryMessage, onDisconnected: onSocketDisconnected, onError: onError)
        self.ws?.delegate = wsDelegate
        self.ws?.connect()
    }
    
    private func getNewUID() -> Int {
        self.uidCounter += 1
        return self.uidCounter + self.clientIdx
    }
    
}

class NTWebSocketDelegate: WebSocketDelegate {
    private let onConnected: () -> Void
    private let onTextMessage: (String) -> Void
    private let onBinaryMessage: (Data) -> Void
    private let onDisconnected: (String, UInt16) -> Void
    private let onError: (Error?) -> Void
    
    init(onConnected: @escaping () -> Void, onTextMessage: @escaping (String) -> Void, onBinaryMessage: @escaping (Data) -> Void, onDisconnected: @escaping (String, UInt16) -> Void, onError: @escaping (Error?) -> Void) {
        self.onConnected = onConnected
        self.onTextMessage = onTextMessage
        self.onBinaryMessage = onBinaryMessage
        self.onDisconnected = onDisconnected
        self.onError = onError
    }
    
    // MARK: - WebSocketDelegate
    func didReceive(event: WebSocketEvent, client: WebSocket) {
        switch event {
        case .connected(let headers):
            print("websocket is connected: \(headers)")
            onConnected()
        case .disconnected(let reason, let code):
            print("websocket is disconnected: \(reason) with code: \(code)")
            onDisconnected(reason, code)
        case .text(let string):
            print("Received text: \(string)")
            onTextMessage(string)
        case .binary(let data):
            print("Received data: \(data.description)")
            onBinaryMessage(data)
        case .ping(_):
            break
        case .pong(_):
            break
        case .viabilityChanged(_):
            break
        case .reconnectSuggested(_):
            break
        case .cancelled:
            break
        case .error(let error):
            handleError(error)
        }
    }
    
    func handleError(_ error: Error?) {
        if let e = error as? WSError {
            print("websocket encountered an error: \(e.message)")
        } else if let e = error {
            print("websocket encountered an error: \(e.localizedDescription)")
        } else {
            print("websocket encountered an error")
        }
        onError(error)
    }
    
}
