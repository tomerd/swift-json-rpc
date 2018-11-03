import Foundation
import NIO

public final class TCPClient {
    public let group: EventLoopGroup
    public let config: Config
    private var channel: Channel?
    private var shutdown = false

    public init(group: EventLoopGroup, config: Config = Config()) {
        self.group = group
        self.config = config
        self.channel = nil
    }

    deinit {
        assert(shutdown)
    }

    public func connect(host: String, port: Int) -> EventLoopFuture<TCPClient> {
        let bootstrap = ClientBootstrap(group: self.group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelInitializer { channel in
                channel.pipeline.add(handler: IdleStateHandler(readTimeout: self.config.timeout))
                    .then { channel.pipeline.add(handler: JsonCodec()) }
                    .then { channel.pipeline.add(handler: CodableCodec<JSONResponse, JSONRequest>(JSONResponse.self)) }
                    .then { channel.pipeline.add(handler: Handler()) }
            }

        print("\(self) connecting to \(host):\(port)")
        return bootstrap.connect(host: host, port: port).then { channel in
            self.channel = channel
            guard let localAddress = channel.localAddress else {
                return channel.eventLoop.newFailedFuture(error: ClientError.cantBind)
            }
            print("\(self) connected to \(localAddress)")
            return channel.eventLoop.newSucceededFuture(result: self)
        }
    }

    public func disconnect() -> EventLoopFuture<Void> {
        print("disconnecting \(self)")
        guard let channel = self.channel else {
            return self.group.next().newFailedFuture(error: ClientError.notReady)
        }
        channel.closeFuture.whenComplete {
            self.shutdown = true
            print("\(self) disconnecting")
        }
        channel.close(promise: nil)
        return channel.closeFuture
    }

    public func call(method: String, params: RPCObject) -> EventLoopFuture<Result> {
        guard let channel = self.channel else {
            return self.group.next().newFailedFuture(error: ClientError.notReady)
        }
        let promise: EventLoopPromise<JSONResponse> = channel.eventLoop.newPromise()
        let request = JSONRequest(id: NSUUID().uuidString, method: method, params: JSONObject(params))
        let requestWrapper = JSONRequestWrapper(request: request, promise: promise)
        let future = channel.writeAndFlush(requestWrapper)
        future.cascadeFailure(promise: promise) // if write fails
        return future.then {
            promise.futureResult.map { Result($0) }
        }
    }

    public struct Config {
        public let timeout: TimeAmount

        public init(timeout: TimeAmount = TimeAmount.seconds(5)) {
            self.timeout = timeout
        }
    }

    public typealias Result = ResultType<RPCObject, Error>

    public struct Error: Equatable {
        public let kind: Kind
        public let description: String

        init(kind: Kind, description: String) {
            self.kind = kind
            self.description = description
        }

        internal init(_ error: JSONError) {
            self.init(kind: JSONErrorCode(rawValue: error.code).map { Kind($0) } ?? .otherServerError, description: error.message)
        }

        public enum Kind {
            case invalidMethod
            case invalidParams
            case invalidRequest
            case invalidServerResponse
            case otherServerError

            internal init(_ code: JSONErrorCode) {
                switch code {
                case .invalidRequest:
                    self = .invalidRequest
                case .methodNotFound:
                    self = .invalidMethod
                case .invalidParams:
                    self = .invalidParams
                case .parseError:
                    self = .invalidServerResponse
                case .internalError, .other:
                    self = .otherServerError
                }
            }
        }
    }
}

private class Handler: ChannelInboundHandler, ChannelOutboundHandler {
    public typealias InboundIn = JSONResponse
    public typealias OutboundIn = JSONRequestWrapper
    public typealias OutboundOut = JSONRequest

    private var queue = CircularBuffer<(String, EventLoopPromise<JSONResponse>)>()

    // outbound
    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let requestWrapper = self.unwrapOutboundIn(data)
        queue.append((requestWrapper.request.id, requestWrapper.promise))
        ctx.write(wrapOutboundOut(requestWrapper.request), promise: promise)
    }

    // inbound
    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        if let remoteAddress = ctx.remoteAddress {
            print("server", remoteAddress, "response", data)
        }
        if self.queue.isEmpty {
            return ctx.fireChannelRead(data) // already complete
        }
        let promise = queue.removeFirst().1
        let response = unwrapInboundIn(data)
        promise.succeed(result: response)
    }

    public func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        if let remoteAddress = ctx.remoteAddress {
            print("server", remoteAddress, "error", error)
        }
        if self.queue.isEmpty {
            return ctx.fireErrorCaught(error) // already complete
        }
        let item = queue.removeFirst()
        let requestId = item.0
        let promise = item.1
        switch error {
        case CodecError.notJson, CodecError.badJson:
            promise.succeed(result: JSONResponse(id: requestId, errorCode: .parseError, error: error))
        default:
            promise.fail(error: error)
            // close the connection
            ctx.close(promise: nil)
        }
    }

    public func channelActive(ctx: ChannelHandlerContext) {
        if let remoteAddress = ctx.remoteAddress {
            print("server", remoteAddress, "connected")
        }
    }

    public func channelInactive(ctx: ChannelHandlerContext) {
        if let remoteAddress = ctx.remoteAddress {
            print("server ", remoteAddress, "disconnected")
        }
        self.errorCaught(ctx: ctx, error: ClientError.connectionResetByPeer)
    }

    func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        if (event as? IdleStateHandler.IdleStateEvent) == .read {
            self.errorCaught(ctx: ctx, error: ClientError.timeout)
        } else {
            ctx.fireUserInboundEventTriggered(event)
        }
    }
}

private struct JSONRequestWrapper {
    let request: JSONRequest
    let promise: EventLoopPromise<JSONResponse>
}

internal enum ClientError: Error {
    case notReady
    case cantBind
    case timeout
    case connectionResetByPeer
}

internal extension ResultType where Value == RPCObject, Error == TCPClient.Error {
    init(_ response: JSONResponse) {
        if let result = response.result {
            self = .success(RPCObject(result))
        } else if let error = response.error {
            self = .failure(TCPClient.Error(error))
        } else {
            self = .failure(TCPClient.Error(kind: .invalidServerResponse, description: "invalid server response"))
        }
    }
}
