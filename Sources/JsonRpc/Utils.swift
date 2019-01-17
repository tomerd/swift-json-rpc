import Foundation

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
