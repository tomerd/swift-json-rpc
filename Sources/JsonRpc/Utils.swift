public enum ResultType<Value, Error> {
    case success(Value)
    case failure(Error)
}
