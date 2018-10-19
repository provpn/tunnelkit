//
//  ControlChannelSerializer.swift
//  TunnelKit
//
//  Created by Davide De Rosa on 9/10/18.
//  Copyright (c) 2018 Davide De Rosa. All rights reserved.
//
//  https://github.com/keeshux
//
//  This file is part of TunnelKit.
//
//  TunnelKit is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  TunnelKit is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with TunnelKit.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation
import __TunnelKitNative
import SwiftyBeaver

private let log = SwiftyBeaver.self

protocol ControlChannelSerializer {
    func reset()
    
    func serialize(packet: ControlPacket) throws -> Data

    func deserialize(data: Data, start: Int, end: Int?) throws -> ControlPacket
}

extension ControlChannel {
    class PlainSerializer: ControlChannelSerializer {
        func reset() {
        }
        
        func serialize(packet: ControlPacket) throws -> Data {
            return packet.serialized()
        }
        
        func deserialize(data packet: Data, start: Int, end: Int?) throws -> ControlPacket {
            var offset = start
            let end = end ?? packet.count
            
            guard end >= offset + PacketOpcodeLength else {
                throw ControlChannelError("Missing opcode")
            }
            let codeValue = packet[offset] >> 3
            guard let code = PacketCode(rawValue: codeValue) else {
                throw ControlChannelError("Unknown code: \(codeValue))")
            }
            let key = packet[offset] & 0b111
            offset += PacketOpcodeLength

            log.debug("Control: Try read packet with code \(code) and key \(key)")
            
            guard end >= offset + PacketSessionIdLength else {
                throw ControlChannelError("Missing sessionId")
            }
            let sessionId = packet.subdata(offset: offset, count: PacketSessionIdLength)
            offset += PacketSessionIdLength

            guard end >= offset + 1 else {
                throw ControlChannelError("Missing ackSize")
            }
            let ackSize = packet[offset]
            offset += 1

            var ackIds: [UInt32]?
            var ackRemoteSessionId: Data?
            if ackSize > 0 {
                guard end >= (offset + Int(ackSize) * PacketIdLength) else {
                    throw ControlChannelError("Missing acks")
                }
                var ids: [UInt32] = []
                for _ in 0..<ackSize {
                    let id = packet.networkUInt32Value(from: offset)
                    ids.append(id)
                    offset += PacketIdLength
                }

                guard end >= offset + PacketSessionIdLength else {
                    throw ControlChannelError("Missing remoteSessionId")
                }
                let remoteSessionId = packet.subdata(offset: offset, count: PacketSessionIdLength)
                offset += PacketSessionIdLength

                ackIds = ids
                ackRemoteSessionId = remoteSessionId
            }

            if code == .ackV1 {
                guard let ackIds = ackIds else {
                    throw ControlChannelError("Ack packet without ids")
                }
                guard let ackRemoteSessionId = ackRemoteSessionId else {
                    throw ControlChannelError("Ack packet without remoteSessionId")
                }
                return ControlPacket(key: key, sessionId: sessionId, ackIds: ackIds as [NSNumber], ackRemoteSessionId: ackRemoteSessionId)
            }

            guard end >= offset + PacketIdLength else {
                throw ControlChannelError("Missing packetId")
            }
            let packetId = packet.networkUInt32Value(from: offset)
            offset += PacketIdLength

            var payload: Data?
            if offset < end {
                payload = packet.subdata(in: offset..<end)
            }

            let controlPacket = ControlPacket(code: code, key: key, sessionId: sessionId, packetId: packetId, payload: payload)
            if let ackIds = ackIds {
                controlPacket.ackIds = ackIds as [NSNumber]
                controlPacket.ackRemoteSessionId = ackRemoteSessionId
            }
            return controlPacket
        }
    }
}

extension ControlChannel {
    class AuthSerializer: ControlChannelSerializer {
        private let encrypter: Encrypter
        
        private let decrypter: Decrypter
        
        private let prefixLength: Int
        
        private let hmacLength: Int
        
        private let authLength: Int
        
        private let preambleLength: Int
        
        private var currentReplayId: BidirectionalState<UInt32>
        
        private let plain: PlainSerializer
        
        init(withKey key: StaticKey, digest: SessionProxy.Digest) throws {
            let crypto = CryptoBox(cipherAlgorithm: nil, digestAlgorithm: digest.rawValue)
            try crypto.configure(
                withCipherEncKey: nil,
                cipherDecKey: nil,
                hmacEncKey: key.hmacSendKey,
                hmacDecKey: key.hmacReceiveKey
            )
            encrypter = crypto.encrypter()
            decrypter = crypto.decrypter()
            
            prefixLength = PacketOpcodeLength + PacketSessionIdLength
            hmacLength = crypto.digestLength()
            authLength = hmacLength + PacketReplayIdLength + PacketReplayTimestampLength
            preambleLength = prefixLength + authLength
            
            currentReplayId = BidirectionalState(withResetValue: 1)
            plain = PlainSerializer()
        }
        
        func reset() {
            currentReplayId.reset()
        }
        
        func serialize(packet: ControlPacket) throws -> Data {
            return try serialize(packet: packet, timestamp: UInt32(Date().timeIntervalSince1970))
        }
        
        func serialize(packet: ControlPacket, timestamp: UInt32) throws -> Data {
            let data = try packet.serialized(withAuthenticator: encrypter, replayId: currentReplayId.outbound, timestamp: timestamp)
            currentReplayId.outbound += 1
            return data
        }
        
        // XXX: start/end are ignored, parses whole packet
        func deserialize(data packet: Data, start: Int, end: Int?) throws -> ControlPacket {
            let end = packet.count
            
            // data starts with (prefix=(header + sessionId) + auth=(hmac + replayId))
            guard end >= preambleLength else {
                throw ControlChannelError("Missing HMAC")
            }
            
            // needs a copy for swapping
            var authPacket = packet
            let authCount = authPacket.count
            try authPacket.withUnsafeMutableBytes { (ptr: UnsafeMutablePointer<UInt8>) in
                PacketSwapCopy(ptr, packet, prefixLength, authLength)
                try decrypter.verifyBytes(ptr, length: authCount, flags: nil)
            }
            
            // TODO: validate replay packet id
            
            return try plain.deserialize(data: authPacket, start: authLength, end: nil)
        }
    }
}