import JSONRPC
import NIO

let address = ("127.0.0.1", 7000)
let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
let client = TCPClient(group: eventLoopGroup)
_ = try! client.connect(host: address.0, port: address.1).wait()
// perform the method call
let result = try! client.call(method: "get_light_state", params: RPCObject(["target": "*"])).wait()
switch result {
case .success(let response):
    print("\(response)")
case .failure(let error):
    print("failed with \(error)")
}
// shutdown
try! client.disconnect().wait()
