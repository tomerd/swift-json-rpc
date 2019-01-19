import Foundation
import NIO

public enum ResultType<Value, Error> {
    case success(Value)
    case failure(Error)
}

internal extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        self.lock()
        defer {
            self.unlock()
        }
        return body()
    }
}

public struct Config {
    public let timeout: TimeAmount

    public init(timeout: TimeAmount = TimeAmount.seconds(5)) {
        self.timeout = timeout
    }
}
