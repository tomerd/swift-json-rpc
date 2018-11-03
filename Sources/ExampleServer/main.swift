import Dispatch
import JSONRPC
import NIO

private class ServerExample {
    public static func main() {
        let group = DispatchGroup()
        let address = ("127.0.0.1", 8000)
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        // start server
        let calculator = Calculator()
        let server = TCPServer(group: eventLoopGroup, closure: calculator.handle)
        _ = try! server.start(host: address.0, port: address.1).wait()
        // trap
        group.enter()
        let signalSource = trap(signal: Signal.INT) { signal in
            print("intercepted signal: \(signal)")
            server.stop().whenComplete {
                group.leave()
            }
        }
        group.wait()
        // cleanup
        signalSource.cancel()
    }

    private class Calculator {
        func handle(method: String, params: RPCObject, callback: (RPCResult) -> Void) {
            switch method.lowercased() {
            case "add":
                self.add(params: params, callback: callback)
            case "substract":
                self.substract(params: params, callback: callback)
            default:
                callback(.failure(RPCError(.invalidMethod)))
            }
        }

        func add(params: RPCObject, callback: (RPCResult) -> Void) {
            let values = extractNumbers(params)
            guard values.count > 1 else {
                return callback(.failure(RPCError(.invalidParams("expected 2 arguments or more"))))
            }
            return callback(.success(.number(values.reduce(0, +))))
        }

        func substract(params: RPCObject, callback: (RPCResult) -> Void) {
            let values = extractNumbers(params)
            guard values.count > 1 else {
                return callback(.failure(RPCError(.invalidParams("expected 2 arguments or more"))))
            }
            return callback(.success(.number(values[1...].reduce(values[0], -))))
        }

        func extractNumbers(_ object: RPCObject) -> [Int] {
            switch object {
            case .list(let items):
                return items.map {
                    switch $0 {
                    case .number(let value):
                        return value
                    default:
                        return nil
                    }
                }.compactMap { $0 }
            default:
                return []
            }
        }
    }

    private static func trap(signal sig: Signal, handler: @escaping (Signal) -> Void) -> DispatchSourceSignal {
        let signalSource = DispatchSource.makeSignalSource(signal: sig.rawValue, queue: DispatchQueue.global())
        signal(sig.rawValue, SIG_IGN)
        signalSource.setEventHandler(handler: {
            signalSource.cancel()
            handler(sig)
        })
        signalSource.resume()
        return signalSource
    }

    private enum Signal: Int32 {
        case HUP = 1
        case INT = 2
        case QUIT = 3
        case ABRT = 6
        case KILL = 9
        case ALRM = 14
        case TERM = 15
    }
}

ServerExample.main()
