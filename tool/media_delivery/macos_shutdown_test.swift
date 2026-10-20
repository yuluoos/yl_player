import AppKit
import FlutterMacOS
import yl_player_media_core
import yl_player_media_delivery

@main struct MacOSShutdownTests {
  static func spin(_ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(60)
    while !predicate() && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(predicate(), "Timed out")
  }

  static func call(_ channel: FlutterMethodChannel, _ method: String, _ arguments: Any? = nil) -> Any? {
    var done = false
    var result: Any?
    channel.invokeMethod(method, arguments: arguments) { result = $0; done = true }
    spin { done }
    if let error = result as? FlutterError {
      fatalError("Dart call failed: \(error.code) \(error.message ?? "") \(String(describing: error.details))")
    }
    return result
  }

  static func fetch(_ url: URL) -> Bool {
    var result: Bool?
    let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
    URLSession.shared.dataTask(with: request) { data, response, error in
      let ok = error == nil && (response as? HTTPURLResponse)?.statusCode == 200 &&
        String(data: data ?? Data(), encoding: .utf8)?.contains("#EXTM3U") == true
      DispatchQueue.main.async { result = ok }
    }.resume()
    spin { result != nil }
    return result!
  }

  static func main() throws {
    setbuf(stdout, nil)
    _ = NSApplication.shared
    let bundle = Bundle(path: CommandLine.arguments[1])!
    let source = CommandLine.arguments[2]
    func start(_ name: String) -> (FlutterEngine, FlutterMethodChannel, URL) {
      let project = FlutterDartProject(precompiledDartBundle: bundle)
      project.dartEntrypointArguments = []
      let engine = FlutterEngine(name: name, project: project, allowHeadlessExecution: true)
      let channel = FlutterMethodChannel(name: "dev.ylplayer.shutdown_test", binaryMessenger: engine.binaryMessenger)
      var ready = false
      channel.setMethodCallHandler { call, reply in
        if call.method == "ready" { ready = true; reply(nil) }
        else { reply(FlutterMethodNotImplemented) }
      }
      YlPlayerMediaDeliveryPlugin.register(
        with: engine.registrar(forPlugin: "YlPlayerMediaDeliveryPlugin"))
      precondition(engine.run(withEntrypoint: nil))
      spin { ready }
      let result = call(channel, "prepare", source) as! [String: Any]
      let url = URL(string: result["uri"] as! String)!
      precondition(fetch(url), "Live delivery did not become reachable")
      return (engine, channel, url)
    }
    let (engineA, channelA, urlA) = start("delivery-A")
    let (engineB, _, urlB) = start("delivery-B")
    defer { engineA.shutDownEngine(); engineB.shutDownEngine() }
    print("PASS two real Flutter engines have independent active HTTP deliveries")
    let pluginA = engineA.valuePublished(byPlugin: "YlPlayerMediaDeliveryPlugin") as! YlPlayerMediaDeliveryPlugin
    pluginA.shutdown()
    precondition(!fetch(urlA), "Explicit shutdown must close engine A's active HTTP origin")
    precondition(call(channelA, "channelsRemoved") as? Bool == true, "Owner/factory channels remain registered")
    engineA.shutDownEngine()
    precondition(engineA.valuePublished(byPlugin: "YlPlayerMediaDeliveryPlugin") === pluginA,
                 "Test must retain engine A and its published plugin after shutdown")
    pluginA.shutdown()
    pluginA.shutdown()
    precondition(!fetch(urlA), "Repeated shutdown reopened engine A")
    do {
      _ = try YlMediaDeliveryRegistry.service(for: ObjectIdentifier(engineA.binaryMessenger as AnyObject))
      fatalError("Closed engine A remains in delivery registry")
    } catch let error as NativePlayerError {
      precondition(error.code == "airplay.delivery_unavailable")
    }
    _ = try YlMediaDeliveryRegistry.service(for: ObjectIdentifier(engineB.binaryMessenger as AnyObject))
    precondition(fetch(urlB), "Engine A shutdown damaged engine B")
    let pluginB = engineB.valuePublished(byPlugin: "YlPlayerMediaDeliveryPlugin") as! YlPlayerMediaDeliveryPlugin
    pluginB.shutdown()
    engineB.shutDownEngine()
    precondition(!fetch(urlB), "Engine B origin survived its own shutdown")
    print("PASS explicit shutdown closes HTTP, channels and registry; retained engines and repeated calls are safe; engine B stays live")
  }
}
