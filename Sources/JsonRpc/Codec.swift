import Foundation
import NIO
import NIOFoundationCompat

private let maxPayload = 1_000_000 // 1MB

// aggregate bytes till delimiter and add delimiter at end
internal final class NewlineCodec: ByteToMessageDecoder, ChannelOutboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private let delimiter1: UInt8 = 0x0D // '\r'
    private let delimiter2: UInt8 = 0x0A // '\n'
    private var delimiterBuffer: ByteBuffer?

    public var cumulationBuffer: ByteBuffer?

    public func handlerAdded(ctx: ChannelHandlerContext) {
        self.delimiterBuffer = ctx.channel.allocator.buffer(capacity: 2)
        self.delimiterBuffer!.write(bytes: [delimiter1, delimiter2])
    }

    // inbound
    public func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let readable: Int? = buffer.withUnsafeReadableBytes { bytes in
            if bytes.count >= maxPayload {
                ctx.fireErrorCaught(CodecError.requestTooLarge)
                return nil
            }
            if bytes.count < 3 {
                return nil
            }
            // try to find a json payload looking \r\n
            for i in 1 ..< bytes.count {
                if bytes[i - 1] == delimiter1, bytes[i] == delimiter2 {
                    return i - 1
                }
            }
            return nil
        }
        guard let r = readable else {
            return .needMoreData
        }
        // slice the buffer
        let slice = buffer.readSlice(length: r)!
        buffer.moveReaderIndex(forwardBy: 1)
        // call next handler
        ctx.fireChannelRead(wrapInboundOut(slice))
        return .continue
    }

    // outbound
    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        // original data
        ctx.write(data, promise: promise)
        // add delimiter
        ctx.write(wrapOutboundOut(self.delimiterBuffer!), promise: promise)
    }

    func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        if (event as? IdleStateHandler.IdleStateEvent) == .read, self.cumulationBuffer?.readableBytes ?? 0 > 0 {
            // we got something but then timedout, so probably not be a json
            ctx.fireErrorCaught(CodecError.badFraming)
        } else {
            ctx.fireUserInboundEventTriggered(event)
        }
    }
}

// https://www.poplatek.fi/payments/jsonpos/transport
// JSON/RPC messages are framed with the following format (in the following byte-by-byte order):
// 8 bytes: ASCII lowercase hex-encoded length (LEN) of the actual JSON/RPC message (receiver MUST accept both uppercase and lowercase)
// 1 byte: a colon (":", 0x3a), not included in LEN
// LEN bytes: a JSON/RPC message, no leading or trailing whitespace
// 1 byte: a newline (0x0a), not included in LEN
internal final class JsonPosCodec: ByteToMessageDecoder, ChannelOutboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private let newline: UInt8 = 0x0A // '\n'
    private let colon: UInt8 = 0x3A // ':'

    public var cumulationBuffer: ByteBuffer?

    private var newlineBuffer: ByteBuffer?
    private var colonBuffer: ByteBuffer?

    public func handlerAdded(ctx: ChannelHandlerContext) {
        self.newlineBuffer = ctx.channel.allocator.buffer(capacity: 1)
        self.newlineBuffer!.write(integer: self.newline)
        self.colonBuffer = ctx.channel.allocator.buffer(capacity: 1)
        self.colonBuffer!.write(integer: self.colon)
    }

    // inbound
    public func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let payloadSize: Int? = buffer.withUnsafeReadableBytes { bytes in
            if bytes.count >= maxPayload {
                ctx.fireErrorCaught(CodecError.requestTooLarge)
                return nil
            }
            if bytes.count < 10 {
                return nil
            }
            guard let hex = String(bytes: bytes[0 ..< 8], encoding: .utf8), let payloadSize = Int(hex, radix: 16) else {
                ctx.fireErrorCaught(CodecError.badFraming)
                return nil
            }
            if colon != bytes[8] {
                ctx.fireErrorCaught(CodecError.badFraming)
                return nil
            }
            if bytes.count < payloadSize + 10 || newline != bytes[bytes.count - 1] {
                return nil
            }
            return payloadSize
        }
        guard let length = payloadSize else {
            return .needMoreData
        }
        // slice the buffer
        let slice = buffer.getSlice(at: 9, length: length)!
        buffer.moveReaderIndex(to: length + 10)
        // call next handler
        ctx.fireChannelRead(wrapInboundOut(slice))
        return .continue
    }

    // outbound
    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let payload = self.unwrapOutboundIn(data)
        // length
        var sizeBuffer = ctx.channel.allocator.buffer(capacity: 8)
        sizeBuffer.write(string: String(payload.readableBytes, radix: 16).leftPadding(toLength: 8, withPad: "0"))
        ctx.write(wrapOutboundOut(sizeBuffer), promise: promise)
        // colon
        ctx.write(wrapOutboundOut(self.colonBuffer!), promise: promise)
        // payload
        ctx.write(data, promise: promise)
        // newline
        ctx.write(wrapOutboundOut(self.newlineBuffer!), promise: promise)
    }

    func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        if (event as? IdleStateHandler.IdleStateEvent) == .read, self.cumulationBuffer?.readableBytes ?? 0 > 0 {
            // we got something but then timedout, so probably not be a valid frame
            ctx.fireErrorCaught(CodecError.badFraming)
        } else {
            ctx.fireUserInboundEventTriggered(event)
        }
    }
}

// no delimeter is provided, brute force try to decode the json
internal final class BruteForceCodec<T>: ByteToMessageDecoder, ChannelOutboundHandler where T: Decodable {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private let last: UInt8 = 0x7D // '}'

    public var cumulationBuffer: ByteBuffer?

    func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let readable: Int? = buffer.withUnsafeReadableBytes { bytes in
            if bytes.count >= maxPayload {
                ctx.fireErrorCaught(CodecError.requestTooLarge)
                return nil
            }
            if last != bytes[bytes.count - 1] {
                return nil
            }
            let data = buffer.getData(at: buffer.readerIndex, length: bytes.count)!
            do {
                _ = try JSONDecoder().decode(T.self, from: data)
                return bytes.count
            } catch is DecodingError {
                return nil
            } catch {
                ctx.fireErrorCaught(error)
                return nil
            }
        }
        guard let length = readable else {
            return .needMoreData
        }
        // slice the buffer
        let slice = buffer.readSlice(length: length)!
        // call next handler
        ctx.fireChannelRead(wrapInboundOut(slice))
        return .continue
    }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        ctx.writeAndFlush(data, promise: promise)
    }

    func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        if (event as? IdleStateHandler.IdleStateEvent) == .read, self.cumulationBuffer?.readableBytes ?? 0 > 0 {
            // we got something but then timedout, so probably not be a valid frame
            ctx.fireErrorCaught(CodecError.badFraming)
        } else {
            ctx.fireUserInboundEventTriggered(event)
        }
    }
}

// bytes to codable and back
internal final class CodableCodec<In, Out>: ChannelInboundHandler, ChannelOutboundHandler where In: Decodable, Out: Encodable {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = In
    public typealias OutboundIn = Out
    public typealias OutboundOut = ByteBuffer

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // inbound
    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let data = buffer.readData(length: buffer.readableBytes)!
        do {
            print("--> decoding \(String(decoding: data, as: UTF8.self))")
            let decodable = try self.decoder.decode(In.self, from: data)
            // call next handler
            ctx.fireChannelRead(wrapInboundOut(decodable))
        } catch let error as DecodingError {
            ctx.fireErrorCaught(CodecError.badJson(error))
        } catch {
            ctx.fireErrorCaught(error)
        }
    }

    // outbound
    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        do {
            let encodable = self.unwrapOutboundIn(data)
            let data = try encoder.encode(encodable)
            print("<-- encoding \(String(decoding: data, as: UTF8.self))")
            var buffer = ctx.channel.allocator.buffer(capacity: data.count)
            buffer.write(bytes: data)
            ctx.write(wrapOutboundOut(buffer), promise: promise)
        } catch let error as EncodingError {
            promise?.fail(error: CodecError.badJson(error))
        } catch {
            promise?.fail(error: error)
        }
    }
}

internal enum CodecError: Error {
    case badFraming
    case badJson(Error)
    case requestTooLarge
}
