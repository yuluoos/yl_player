from pathlib import Path
root=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS')
for name in ('YlHlsMediaProxy.swift','YlHlsResourceLoader.swift'):
 p=root/name;s=p.read_text();old='''    sessionConfiguration.timeoutIntervalForResource = TimeInterval(
      max(1, configuration.connectTimeoutMs + configuration.readTimeoutMs)
    ) / 1_000''';new='''    // Native options may exceed the map's limits. Convert before summing so
    // valid Int64 inputs cannot trap before Foundation receives the interval.
    sessionConfiguration.timeoutIntervalForResource = max(1,
      TimeInterval(configuration.connectTimeoutMs) + TimeInterval(configuration.readTimeoutMs)
    ) / 1_000''';assert old in s;s=s.replace(old,new)
 if name=='YlHlsResourceLoader.swift':
  old='''    let maximumWaitMs = max(1_000, configuration.connectTimeoutMs + configuration.readTimeoutMs + 1_000)
    let deadline = DispatchTime.now() + .milliseconds(Int(maximumWaitMs))'''
  new='''    let maximumWaitSeconds = max(1,
      (TimeInterval(configuration.connectTimeoutMs) + TimeInterval(configuration.readTimeoutMs)) / 1_000 + 1)
    let deadline = DispatchTime.now() + maximumWaitSeconds''';assert old in s;s=s.replace(old,new)
 p.write_text(s)
