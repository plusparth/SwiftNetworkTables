//
//  NT4Utils.swift
//  
//
//  Created by Parth Oza on 1/5/23.
//

import Foundation
import MessagePack
import GenericJSON


private let typeStringToIdx: [String:Int] = [
    "boolean":0,
    "double":1,
    "int":2,
    "float": 3,
    "string": 4,
    "json": 4,
    "raw": 5,
    "rpc": 5,
    "msgpack": 5,
    "protobuf": 5,
    "boolean[]": 16,
    "double[]": 17,
    "int[]": 18,
    "float[]": 19,
    "string[]": 20
]

func typeStringToIdxLookup(type: String) -> Int {
    // default to binary
    return typeStringToIdx[type] ?? 5
}

func serialize(topicId: Int, timestamp: Int64, typeId: Int, data: MessagePack) -> MessagePack {
    return MessagePack([MessagePack(topicId), MessagePack(timestamp), MessagePack(typeId), data])
}

public struct NT4TopicProperties: Codable {
    public var persistent: Bool
    public var retained: Bool
    
    init(persistent: Bool = false, retained: Bool = false) {
        self.persistent = persistent
        self.retained = retained
    }
    
    init(jsonObject: [String:JSON]) {
        self.persistent = jsonObject["persistent"]?.boolValue ?? false
        self.retained = jsonObject["retained"]?.boolValue ?? false
    }
}

public struct NT4Topic: Codable {
    let uid: Int
    let name: String
    let type: String
    var properties: NT4TopicProperties
    
    init(uid: Int, name: String, type: String, properties: NT4TopicProperties) {
        self.uid = uid
        self.name = name
        self.type = type
        self.properties = properties
    }
    
    func toPublishObject() -> Codable {
        struct NT4TopicPublish: Codable {
            let name: String
            let type: String
            let pubuid: Int
            let properties: NT4TopicProperties
            
            init(topic: NT4Topic) {
                self.name = topic.name
                self.type = topic.type
                self.pubuid = topic.uid
                self.properties = topic.properties
            }
        }
        
        return NT4TopicPublish(topic: self)
    }
    
    func toUnpublishObject() -> Codable {
        struct NT4TopicUnpublish: Codable {
            let pubuid: Int
            
            init(topic: NT4Topic) {
                self.pubuid = topic.uid
            }
        }
        
        return NT4TopicUnpublish(topic: self)
    }
    
    func getTypeIdx() -> Int {
        return typeStringToIdxLookup(type: type)
    }
}


struct NT4SubscriptionOptions: Codable {
    let periodic: Float
    let all: Bool
    let topicsonly: Bool
    let prefix: Bool
    
    init(periodic: Float = 0.01, sendAll: Bool = false, topicsOnly: Bool = false, prefixMode: Bool = false) {
        self.periodic = periodic
        self.all = sendAll
        self.topicsonly = topicsOnly
        self.prefix = prefixMode
    }
}

struct NT4Subscription {
    var uid: Int
    var topics: [String]
    var options: NT4SubscriptionOptions
    
    init(uid: Int, topics: [String], options: NT4SubscriptionOptions) {
        self.uid = uid
        self.topics = topics
        self.options = options
    }
    
    func toSubscribeObject() -> Codable {
        struct NT4SubscriptionSubscribe: Codable {
            let topics: [String]
            let subuid: Int
            let options: NT4SubscriptionOptions
            
            init(subscription: NT4Subscription) {
                self.topics = subscription.topics
                self.subuid = subscription.uid
                self.options = subscription.options
            }
        }
        
        return NT4SubscriptionSubscribe(subscription: self)
    }
    
    func toUnsubscribeObject() -> Codable {
        struct NT4SubscriptionUnsubscribe: Codable {
            let subuid: Int
            
            init(subscription: NT4Subscription) {
                self.subuid = subscription.uid
            }
        }
        
        return NT4SubscriptionUnsubscribe(subscription: self)
    }
}





