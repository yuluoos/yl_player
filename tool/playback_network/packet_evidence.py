"""Sanitized observations from a bounded classic-pcap capture of one HTTP service.

Packet presence is capture-point evidence, not proof of physical delivery. Missing
requests, missing packets, and unknown stream state never prove an unsent request.
"""
import hashlib
import ipaddress
from pathlib import Path
import re
import struct

from transaction_connections import connection_token


MAX_CAPTURE_BYTES = 64 * 1024 * 1024
MAX_PACKETS = 100000
MAX_HTTP_REQUESTS = 10000
FLAGS = ((1, 'FIN'), (2, 'SYN'), (4, 'RST'), (8, 'PSH'), (16, 'ACK'),
         (32, 'URG'), (64, 'ECE'), (128, 'CWR'), (256, 'NS'))
UUID = re.compile(rb'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
HEADER_NAME = re.compile(rb"[!#$%&'*+.^_`|~0-9a-zA-Z-]+")


def _records(data):
    variants = {b'\xd4\xc3\xb2\xa1': ('<', 1000000), b'\xa1\xb2\xc3\xd4': ('>', 1000000),
                b'\x4d\x3c\xb2\xa1': ('<', 1000000000), b'\xa1\xb2\x3c\x4d': ('>', 1000000000)}
    if len(data) < 24 or data[:4] not in variants:
        raise ValueError('unsupported or truncated pcap header')
    endian, resolution = variants[data[:4]]
    major, minor, _, _, snaplen, link = struct.unpack_from(endian + 'HHIIII', data, 4)
    if (major, minor) != (2, 4) or link != 1 or not snaplen:
        raise ValueError('unsupported pcap format or link type')
    position = 24
    while position < len(data):
        if len(data) - position < 16:
            raise ValueError('truncated pcap record header')
        seconds, fraction, captured, original = struct.unpack_from(endian + 'IIII', data, position)
        position += 16
        if fraction >= resolution or captured != original or captured > snaplen or position + captured > len(data):
            raise ValueError('invalid or truncated pcap packet')
        yield seconds * 1000000000 + fraction * (1000000000 // resolution), data[position:position + captured]
        position += captured


def _tcp(frame, host, port):
    if len(frame) < 14:
        raise ValueError('truncated Ethernet header')
    if frame[12:14] != b'\x08\x00':
        return None
    ip = frame[14:]
    if len(ip) < 20 or ip[0] >> 4 != 4:
        raise ValueError('invalid or truncated IPv4 header')
    header = (ip[0] & 15) * 4
    size = struct.unpack_from('!H', ip, 2)[0]
    if header < 20 or size < header or size > len(ip):
        raise ValueError('invalid or truncated IPv4 packet')
    if ip[9] != 6:
        return None
    if struct.unpack_from('!H', ip, 6)[0] & 0x3fff:
        raise ValueError('fragmented IPv4 TCP evidence unsupported')
    tcp = ip[header:size]
    if len(tcp) < 20:
        raise ValueError('truncated TCP header')
    source_port, destination_port, sequence, acknowledgment = struct.unpack_from('!HHII', tcp)
    tcp_header = (tcp[12] >> 4) * 4
    if tcp_header < 20 or tcp_header > len(tcp):
        raise ValueError('invalid or truncated TCP header')
    if ip[16:20] == host and destination_port == port:
        direction = 'client'
        client = (str(ipaddress.IPv4Address(ip[12:16])), source_port)
    elif ip[12:16] == host and source_port == port:
        direction = 'server'
        client = (str(ipaddress.IPv4Address(ip[16:20])), destination_port)
    else:
        return None
    return client, direction, sequence, acknowledgment, tcp[13] | ((tcp[12] & 1) << 8), tcp[tcp_header:]


def _http(opening_sequences, segments):
    result = dict(status='unknown', reason=None, requests=[])
    if len(opening_sequences) != 1:
        result['reason'] = 'multiple-opening-syn' if opening_sequences else 'missing-opening-syn'
        return result
    if not segments:
        result['reason'] = 'no-request-bytes'
        return result
    start = (next(iter(opening_sequences)) + 1) & 0xffffffff
    ordered = sorted(((sequence - start) & 0xffffffff, data) for sequence, data in segments)
    stream = bytearray()
    gap = False
    for offset, data in ordered:
        if offset >= 0x80000000:
            result['reason'] = 'unsupported-sequence-span'
            return result
        if offset > len(stream):
            gap = True
            break
        overlap = min(len(data), len(stream) - offset)
        if stream[offset:offset + overlap] != data[:overlap]:
            result['reason'] = 'conflicting-retransmission'
            return result
        stream.extend(data[overlap:])
    position = 0
    while position < len(stream):
        end = stream.find(b'\r\n\r\n', position)
        if end == -1:
            result['reason'] = 'stream-gap' if gap else 'incomplete-header'
            return result
        lines = bytes(stream[position:end]).split(b'\r\n')
        request = re.fullmatch(rb'(GET|HEAD) [\x21-\x7e]+ HTTP/1\.[01]', lines[0])
        headers = {}
        for line in lines[1:]:
            name, separator, value = line.partition(b':')
            if not separator or not HEADER_NAME.fullmatch(name) or re.search(rb'[\x00-\x08\x0a-\x1f\x7f]', value):
                result['reason'] = 'unsupported-request-framing'
                return result
            headers.setdefault(name.lower(), []).append(value.strip(b' \t'))
        if (request is None or b'transfer-encoding' in headers or
                headers.get(b'content-length', [b'0']) != [b'0']):
            result['reason'] = 'unsupported-request-framing'
            return result
        correlations = headers.get(b'x-yl-trace-id', [])
        if len(correlations) > 1 or (correlations and not UUID.fullmatch(correlations[0])):
            result['reason'] = 'invalid-correlation-header'
            return result
        result['requests'].append(dict(method=request[1].decode('ascii'),
                                       correlationID=correlations[0].decode('ascii').lower() if correlations else None))
        if len(result['requests']) > MAX_HTTP_REQUESTS:
            raise ValueError('HTTP request summary limit exceeded')
        position = end + 4
    result.update(status='unknown' if gap else 'parsed', reason='stream-gap' if gap else None)
    return result


def _flow_evidence(openings, segments_by_ack, packets):
    if len(openings) == 1:
        opening_ack = (next(iter(openings)) + 1) & 0xffffffff
        replies = {p['sequenceNumber'] for p in packets
                   if p['direction'] == 'server' and 'SYN' in p['flags'] and 'ACK' in p['flags']
                   and p['acknowledgmentNumber'] == opening_ack}
        if len(replies) > 1:
            # Each reply gives the client a different initial ACK. Keep headers
            # observed under one reply, without splicing competing handshakes.
            requests = []
            for sequence in sorted(replies):
                segments = segments_by_ack.get((sequence + 1) & 0xffffffff, [])
                requests.extend(_http(openings, segments)['requests'])
                if len(requests) > MAX_HTTP_REQUESTS:
                    raise ValueError('HTTP request summary limit exceeded')
            reason = 'multiple-syn-ack-sequences'
            return reason, dict(status='unknown', reason=reason, requests=requests)
    state = ('multiple-opening-syn' if len(openings) > 1 else
             'single-opening-syn' if openings else 'missing-opening-syn')
    segments = [segment for group in segments_by_ack.values() for segment in group]
    return state, _http(openings, segments)


def summarize_pcap(path, *, key: bytes, server_host: str, server_port: int):
    """Return JSON-safe evidence; reject unsupported, truncated or over-limit input.

    Accept Ethernet IPv4 TCP classic pcap, with complete captured packets. TCP
    checksums are not validated because host captures may precede checksum offload.
    All retransmissions count; HTTP reassembly requires one distinct opening SYN.
    """
    with Path(path).open('rb') as source:
        data = source.read(MAX_CAPTURE_BYTES + 1)
    if len(data) > MAX_CAPTURE_BYTES:
        raise ValueError('pcap file limit exceeded')
    host = ipaddress.IPv4Address(server_host).packed
    flows = {}
    streams = {}
    first_time = None
    packet_count = ignored = 0
    for timestamp, frame in _records(data):
        if first_time is None:
            first_time = timestamp
        decoded = _tcp(frame, host, server_port)
        if decoded is None:
            ignored += 1
            continue
        client, direction, sequence, acknowledgment, flags, payload = decoded
        packet_count += 1
        if packet_count > MAX_PACKETS:
            raise ValueError('owned packet limit exceeded')
        token = connection_token(key, client, (server_host, server_port))
        if token not in flows:
            flows[token] = dict(connectionToken=token, packets=[],
                               client=dict(packetCount=0, payloadBytes=0, flagCounts={}),
                               server=dict(packetCount=0, payloadBytes=0, flagCounts={}))
            streams[token] = (set(), {})
        flow = flows[token]
        side = flow[direction]
        side['packetCount'] += 1
        side['payloadBytes'] += len(payload)
        names = [name for mask, name in FLAGS if flags & mask]
        for name in names:
            side['flagCounts'][name] = side['flagCounts'].get(name, 0) + 1
        flow['packets'].append(dict(relativeTimeSeconds=(timestamp - first_time) / 1000000000,
                                   direction=direction, flags=names, sequenceNumber=sequence,
                                   acknowledgmentNumber=acknowledgment, payloadBytes=len(payload)))
        if direction == 'client':
            openings, segments_by_ack = streams[token]
            if flags & 2 and not flags & 16:
                openings.add(sequence)
            if payload:
                segment = ((sequence + bool(flags & 2)) & 0xffffffff, payload)
                segments_by_ack.setdefault(acknowledgment if flags & 16 else None, []).append(segment)
    for token, flow in flows.items():
        flow['connectionInstanceStatus'], flow['http'] = _flow_evidence(*streams[token], flow['packets'])
    return dict(version=1, availability='reported', captureSHA256=hashlib.sha256(data).hexdigest(),
                packetCount=packet_count, ignoredPacketCount=ignored, flows=list(flows.values()),
                unsentProven=False, physicalDeliveryProven=False,
                interpretation='Only packets observed at the capture point are reported. Counts include retransmissions. '
                'A single distinct opening SYN permits stream parsing but cannot rule out unobserved tuple reuse. '
                'Missing packets, missing correlation IDs and unknown streams never prove no transmission or physical delivery.')


def attribute_packets(packet_summary, boundaries, connection_observation):
    """Join already validated proxy/transaction evidence without ordinal inference.

    Flow indices reference packet_summary['flows']; ambiguous candidates remain
    available for inspection but do not establish transaction packet observation.
    A captured exact correlation header establishes only task-level observation.
    """
    flows = packet_summary['flows']
    tokens = {}
    correlations = {}
    for index, flow in enumerate(flows):
        tokens.setdefault(flow['connectionToken'], []).append(index)
        for request in flow['http']['requests']:
            correlation = request['correlationID']
            if correlation is not None:
                matches = correlations.setdefault(correlation.lower(), [])
                if index not in matches:
                    matches.append(index)
    observations = {(row['proxyID'].lower(), row['requestID']): row
                    for row in connection_observation['requests']}
    requests = []
    for row in boundaries:
        observation = observations[(row['proxyID'].lower(), row['requestID'])]
        correlation = row.get('correlationID')
        correlation_indices = correlations.get(correlation.lower(), []) if correlation is not None else []
        transactions = []
        for transaction in observation['transactions']:
            token = transaction['connectionToken']
            indices = tokens.get(token, []) if token is not None else []
            if transaction['proxyConnection']:
                binding = 'proxy'
            elif transaction['binding'] == 'ambiguous':
                binding = 'ambiguous'
            elif token is None:
                binding = transaction['binding']
            elif not indices:
                binding = 'not-observed-in-capture'
            elif len(indices) != 1 or flows[indices[0]]['connectionInstanceStatus'] in (
                    'multiple-opening-syn', 'multiple-syn-ack-sequences'):
                binding = 'ambiguous'
            elif flows[indices[0]]['connectionInstanceStatus'] == 'missing-opening-syn':
                binding = 'missing-opening-syn'
            else:
                binding = 'observed'
            transactions.append(dict(index=transaction['index'], connectionToken=token,
                                     packetObserved=True if binding == 'observed' else None,
                                     binding=binding, flowIndices=indices))
        observed = bool(correlation_indices) or any(item['packetObserved'] is True for item in transactions)
        requests.append(dict(proxyID=row['proxyID'], requestID=row['requestID'],
                             packetObserved=True if observed else None,
                             correlationPacketObserved=True if correlation_indices else None,
                             correlationFlowTokens=[flows[index]['connectionToken'] for index in correlation_indices],
                             correlationFlowIndices=correlation_indices, transactions=transactions))
    return dict(version=1, requests=requests, unsentProven=False, rootCauseEstablished=False,
                interpretation='Exact captured correlation headers establish task-level packet observation only. '
                'Transactions require a unique endpoint-token flow with one opening SYN sequence and no competing SYN-ACK sequences; '
                'established lifecycle tuple ambiguity remains unbound even in a partial capture. '
                'flow indices on unbound transactions identify candidates only. '
                'Unknown or not-observed-in-capture never means unsent. No retry or cancellation cause is established.')
