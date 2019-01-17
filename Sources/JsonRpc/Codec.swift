import Foundation
import NIO
import NIOFoundationCompat

// aggregate bytes till delimiter and add delimiter at end
internal final class JsonCodec: ByteToMessageDecoder, ChannelOutboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private let delimiter: UInt8 = 0x0A // '\n'
    private let delimiter2: UInt8 = 0x0D // '\r'
    private let last: UInt8 = 0x7D // '}'

    public var cumulationBuffer: ByteBuffer?

    // inbound
    public func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let readable: Int? = buffer.withUnsafeReadableBytes { bytes in
            // try to find a json payload looking for }\n or }\r
            for i in 1 ..< bytes.count {
                if bytes[i - 1] == last, (bytes[i] == delimiter || bytes[i] == delimiter2) {
                    return i
                }
            }
            return nil
        }
        if let r = readable {
            // copy the slice
            let slice = buffer.readSlice(length: r)!
            // call next handler
            ctx.fireChannelRead(wrapInboundOut(slice))
            return .continue
        }
        return .needMoreData
    }

    // outbound
    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var buffer = self.unwrapOutboundIn(data)
        // add delimiter
        buffer.write(integer: delimiter)
        ctx.write(wrapOutboundOut(buffer), promise: promise)
    }

    func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        if (event as? IdleStateHandler.IdleStateEvent) == .read, self.cumulationBuffer?.readableBytes ?? 0 > 0 {
            // we got something but then timedout, so probably not be a json
            ctx.fireErrorCaught(CodecError.notJson)
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

    private let inType: In.Type
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(_ inType: In.Type) {
        self.inType = inType
    }

    // inbound
    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let data = buffer.readData(length: buffer.readableBytes)! // safe to bang here since we reading by readableBytes
        do {
            print("decoding: \(String(decoding: data, as: UTF8.self))")
            let decodable = try self.decoder.decode(self.inType, from: data)
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
            var buffer = ctx.channel.allocator.buffer(capacity: data.count)
            buffer.write(bytes: data)
            ctx.write(wrapOutboundOut(buffer), promise: promise)
        } catch let error as EncodingError {
            ctx.fireErrorCaught(CodecError.badJson(error))
        } catch {
            ctx.fireErrorCaught(error)
        }
    }
}

internal enum CodecError: Error {
    case notJson
    case badJson(Error)
}
