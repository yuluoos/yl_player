"""Reproduce the observed request/connection/packet chain; no acceptance override.
Run from repository root with the original task-linked run directory as argv[1].
"""
import hashlib
import ipaddress
import json
from pathlib import Path
import re
import struct
import sys
sys.path.insert(0, 'tool/playback_network')
from packet_evidence import _records, _tcp
run = Path(sys.argv[1])
logs = [json.loads(line) for line in (run/'client-network.jsonl').read_text().splitlines()]
attribution = json.loads((run/'task-log-attribution.json').read_text())
request = next(row for row in attribution['requests'] if row['targetPhenomenon'] and row['requestID'] == 46)
selected = sorted(set(request['taskLogIndices'] + request['connectionLogIndices']))
connection_logs = [dict(index=i, **logs[i]) for i in selected]
summary = next(row['message'] for row in connection_logs if 'nw_protocol_tcp_log_summary' in row['message'])
address = re.search(r'(\d+\.\d+\.\d+\.\d+):(\d+)<->(\d+\.\d+\.\d+\.\d+):(\d+)', summary)
client = (address[1], int(address[2])); server = (address[3], int(address[4]))
raw = (run/'packets/capture.pcap').read_bytes()
first = None; packets = []; client_times = []; server_times = []
for ns, frame in _records(raw):
    if first is None: first = ns
    decoded = _tcp(frame, ipaddress.ip_address(server[0]).packed, server[1])
    if decoded is None: continue
    endpoint, direction, seq, ack, flags, payload = decoded
    (client_times if direction == 'client' else server_times).append(ns)
    if endpoint != client: continue
    tcp = frame[14 + (frame[14] & 15) * 4:]
    options = tcp[20:(tcp[12] >> 4) * 4]; timestamp = None
    while options:
        kind = options[0]
        if kind == 0: break
        if kind == 1: options = options[1:]; continue
        size = options[1]
        if kind == 8: timestamp = struct.unpack('!II', options[2:10])
        options = options[size:]
    packets.append(dict(relativeSeconds=(ns-first)/1e9, direction=direction,
        sequence=seq, acknowledgment=ack, flags=flags, payloadBytes=len(payload), tcpTimestamp=timestamp))
start, end = max(zip(client_times, client_times[1:]), key=lambda pair: pair[1]-pair[0])
health = json.loads((run/'server-health.json').read_text())['samples']
result = dict(proxyID=request['proxyID'], requestID=46, foundationTaskID=request['foundationTaskID'],
    connectionIDs=request['connectionIDs'], client=client, server=server,
    captureSHA256=hashlib.sha256(raw).hexdigest(), captureStartEpochNanoseconds=first,
    largestClientGapSeconds=(end-start)/1e9, clientGapRelativeSeconds=[(t-first)/1e9 for t in (start,end)],
    serverPacketsDuringClientGap=sum(start < t < end for t in server_times),
    maxServerHeartbeatGapSeconds=max(b['listenerSeconds']-a['listenerSeconds'] for a,b in zip(health,health[1:])),
    packets=packets, clientConnectionLogs=connection_logs,
    fullHistoricalRootCauseEstablished=False, physicalBottleneckLocationEstablished=False,
    interpretation='Exact task identity, logged tuple and TCP sequence bind this timeout instance. Endpoint absence is not absence of transmission. Late SYNs and RSTs do not identify the physical buffering component. Device and Mac wall clocks are not directly compared.')
(run/'failure-chain.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k not in ('packets','clientConnectionLogs')}, indent=2))
