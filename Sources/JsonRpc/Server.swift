import Foundation
import NIO

public final class TCPServer {
    private let group: EventLoopGroup
    private let config: Config
    private var channel: Channel?
    private let closure: RPCClosure

    public init(group: EventLoopGroup, config: Config = Config(), closure: @escaping RPCClosure) {
        self.group = group
        self.config = config
        self.closure = closure
        self.state = .initializing
    }

    deinit {
        assert(.stopped == self.state)
    }

    public func start(host: String, port: Int) -> EventLoopFuture<TCPServer> {
        assert(.initializing == self.state)

        let framingHandler: ChannelHandler
        switch self.config.framing {
        case .jsonpos:
            framingHandler = JsonPosCodec()
        case .brute:
            framingHandler = BruteForceCodec<JSONRequest>()
        case .default:
            framingHandler = NewlineCodec()
        }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.add(handler: IdleStateHandler(readTimeout: self.config.timeout))
                    .then { channel.pipeline.add(handler: framingHandler) }
                    .then { channel.pipeline.add(handler: CodableCodec<JSONRequest, JSONResponse>()) }
                    .then { channel.pipeline.add(handler: Handler(self.closure)) }
            }
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

        self.state = .starting("\(host):\(port)")
        return bootstrap.bind(host: host, port: port).then { channel in
            self.channel = channel
            self.state = .started
            return channel.eventLoop.newSucceededFuture(result: self)
        }
    }

    public func stop() -> EventLoopFuture<Void> {
        if .started != self.state {
            return self.group.next().newFailedFuture(error: ServerError.notReady)
        }
        guard let channel = self.channel else {
            return self.group.next().newFailedFuture(error: ServerError.notReady)
        }
        self.state = .stopping
        channel.closeFuture.whenComplete {
            self.state = .stopped
        }
        return channel.close()
    }

    private var _state = State.initializing
    private let lock = NSLock()
    private var state: State {
        get {
            return self.lock.withLock {
                _state
            }
        }
        set {
            self.lock.withLock {
                _state = newValue
                print("\(self) \(_state)")
            }
        }
    }

    private enum State: Equatable {
        case initializing
        case starting(String)
        case started
        case stopping
        case stopped
    }

    public struct Config {
        public let timeout: TimeAmount
        public let framing: Framing

        public init(timeout: TimeAmount = TimeAmount.seconds(5), framing: Framing = .default) {
            self.timeout = timeout
            self.framing = framing
        }
    }
}

private class Handler: ChannelInboundHandler {
    public typealias InboundIn = JSONRequest
    public typealias OutboundOut = JSONResponse

    private let closure: RPCClosure

    public init(_ closure: @escaping RPCClosure) {
        self.closure = closure
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let request = unwrapInboundIn(data)
        self.closure(request.method, RPCObject(request.params), { result in
            let response: JSONResponse
            switch result {
            case .success(let handlerResult):
                print("rpc handler returned success", handlerResult)
                response = JSONResponse(id: request.id, result: handlerResult)
            case .failure(let handlerError):
                print("rpc handler returned failure", handlerError)
                response = JSONResponse(id: request.id, error: handlerError)
            }
            ctx.channel.writeAndFlush(self.wrapOutboundOut(response), promise: nil)
        })
    }

    public func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        if let remoteAddress = ctx.remoteAddress {
            print("client", remoteAddress, "error", error)
        }
        switch error {
        case CodecError.badFraming, CodecError.badJson:
            let response = JSONResponse(id: "unknown", errorCode: .parseError, error: error)
            ctx.channel.writeAndFlush(self.wrapOutboundOut(response), promise: nil)
        case CodecError.requestTooLarge:
            let response = JSONResponse(id: "unknown", errorCode: .invalidRequest, error: error)
            ctx.channel.writeAndFlush(self.wrapOutboundOut(response), promise: nil)
        default:
            let response = JSONResponse(id: "unknown", errorCode: .internalError, error: error)
            ctx.channel.writeAndFlush(self.wrapOutboundOut(response), promise: nil)
        }
        // close the client connection
        ctx.close(promise: nil)
    }

    public func channelActive(ctx: ChannelHandlerContext) {
        if let remoteAddress = ctx.remoteAddress {
            print("client", remoteAddress, "connected")
        }
    }

    public func channelInactive(ctx: ChannelHandlerContext) {
        if let remoteAddress = ctx.remoteAddress {
            print("client", remoteAddress, "disconnected")
        }
    }

    func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        if (event as? IdleStateHandler.IdleStateEvent) == .read {
            self.errorCaught(ctx: ctx, error: ServerError.timeout)
        } else {
            ctx.fireUserInboundEventTriggered(event)
        }
    }
}

internal enum ServerError: Error {
    case notReady
    case cantBind
    case timeout
}
