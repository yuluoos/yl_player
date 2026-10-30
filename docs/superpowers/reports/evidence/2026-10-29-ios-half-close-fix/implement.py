from pathlib import Path
p=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS/YlHlsMediaProxy.swift');s=p.read_text().replace('  private var cancelled = false','  private var connectionDeadlines: [ObjectIdentifier: DispatchSourceTimer] = [:]\n  private var cancelled = false',1)
s=s.replace('      result["activeConnections"] = Double(connections.count)','      result["activeConnections"] = Double(connections.count)\n      result["connectionDeadlines"] = Double(connectionDeadlines.count)',1)
s=s.replace('      connections.removeAll()\n      return values','      connections.removeAll()\n      connectionDeadlines.values.forEach { $0.cancel() }\n      connectionDeadlines.removeAll()\n      return values',1)
s=s.replace('      connections[identifier] = connection\n','''      connections[identifier] = connection
      // EOF closes only the client's write side. Independently bound the whole
      // exchange, including a stalled downstream send or a silent full close.
      let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
      let lifetime = (TimeInterval(max(1, configuration.connectTimeoutMs)) +
        TimeInterval(max(1, configuration.readTimeoutMs))) / 1_000
      timer.schedule(deadline: .now() + lifetime)
      timer.setEventHandler { [weak self, weak connection] in
        guard let self, let connection else { return }
        self.close(connection)
      }
      connectionDeadlines[identifier] = timer
      timer.resume()
''',1)
s=s.replace('''        if isComplete {
          self.close(connection, diagnosticCancelCause: 2)
        } else {
          self.monitorDisconnect(connection)
        }''','''        // A complete request followed by FIN still permits a response.
        if !isComplete { self.monitorDisconnect(connection) }''',1)
s=s.replace('''      if error != nil || isComplete {
        self.close(connection, diagnosticCancelCause: error == nil ? 2 : 3)
      } else {''','''      if error != nil {
        self.close(connection, diagnosticCancelCause: 3)
      } else if !isComplete {''',1)
s=s.replace('      connections.removeValue(forKey: identifier)\n','      connections.removeValue(forKey: identifier)\n      connectionDeadlines.removeValue(forKey: identifier)?.cancel()\n',1)
p.write_text(s)
