import ipaddress
import copy
import json
from pathlib import Path
import struct
import tempfile
import unittest

from transaction_connections import connection_token
try:
    import packet_evidence
except ImportError:
    packet_evidence = None


CLIENT = '192.0.2.7'
SERVER = '192.0.2.9'
PORT = 18080
KEY = b'packet-test-key'
CID = '87654321-1234-1234-1234-123456789abc'
REQUEST = f'GET /private/path HTTP/1.1\r\nHost: secret.example\r\nX-Yl-Trace-Id: {CID}\r\n\r\n'.encode()


def packet(seq=100, flags=2, data=b'', server=False, port=PORT, ack=0):
    source, destination = (SERVER, CLIENT) if server else (CLIENT, SERVER)
    ports = (port, 54321) if server else (54321, port)
    tcp = struct.pack('!HHIIBBHHH', *ports, seq, ack, 0x50, flags, 65535, 0, 0) + data
    ip = struct.pack('!BBHHHBBH4s4s', 0x45, 0, 20 + len(tcp), 1, 0, 64, 6, 0,
                     ipaddress.IPv4Address(source).packed, ipaddress.IPv4Address(destination).packed)
    return b'\0' * 12 + b'\x08\x00' + ip + tcp


def pcap(packets, endian='<', nano=False, link=1):
    magic = 0xa1b23c4d if nano else 0xa1b2c3d4
    result = [struct.pack(endian + 'IHHIIII', magic, 2, 4, 0, 0, 65535, link)]
    for index, data in enumerate(packets):
        result.append(struct.pack(endian + 'IIII', 1000 + index // 1000,
                                  (index % 1000) * (1000000 if nano else 1000), len(data), len(data)) + data)
    return b''.join(result)


class PacketEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(packet_evidence, 'packet evidence parser missing')
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'capture.pcap'

    def summarize(self, packets=None, raw=None, **options):
        self.path.write_bytes(raw if raw is not None else pcap(packets, **options))
        return packet_evidence.summarize_pcap(self.path, key=KEY, server_host=SERVER, server_port=PORT)

    def test_syn_split_out_of_order_retransmission_and_sanitized_output(self):
        parts = [packet(), packet(900, 18, server=True, ack=101),
                 packet(121, 24, REQUEST[20:]), packet(101, 24, REQUEST[:20]),
                 packet(101, 24, REQUEST[:20]), packet(900, 20, server=True)]
        result = self.summarize(parts)
        flow = result['flows'][0]
        self.assertEqual(flow['connectionToken'], connection_token(KEY, (CLIENT, 54321), (SERVER, PORT)))
        self.assertEqual(flow['client']['packetCount'], 4)
        self.assertEqual(flow['server']['flagCounts']['RST'], 1)
        self.assertEqual(flow['client']['payloadBytes'], len(REQUEST) + 20)
        self.assertEqual(flow['http'], {'status':'parsed', 'reason':None,
                                       'requests':[{'method':'GET', 'correlationID':CID}]})
        self.assertEqual(flow['packets'][1]['relativeTimeSeconds'], 0.001)
        self.assertEqual(flow['packets'][2]['sequenceNumber'], 121)
        encoded = json.dumps(result)
        for secret in (CLIENT, SERVER, ': 54321', f': {PORT}', '/private/path', 'secret.example'):
            self.assertNotIn(secret, encoded)
        self.assertFalse(result['unsentProven'])
        self.assertFalse(result['physicalDeliveryProven'])

    def test_classic_pcap_endian_and_timestamp_variants(self):
        for endian in ('<', '>'):
            for nano in (False, True):
                with self.subTest(endian=endian, nano=nano):
                    flow = self.summarize([packet(), packet(101, 24, REQUEST)], endian=endian, nano=nano)['flows'][0]
                    self.assertEqual(flow['packets'][1]['relativeTimeSeconds'], 0.001)
                    self.assertEqual(flow['http']['requests'][0]['correlationID'], CID)

    def test_gap_incomplete_header_and_missing_syn_remain_unknown(self):
        for packets, reason in (([packet(), packet(111, 24, REQUEST)], 'stream-gap'),
                                ([packet(), packet(101, 24, REQUEST[:-1])], 'incomplete-header'),
                                ([packet(101, 24, REQUEST)], 'missing-opening-syn')):
            with self.subTest(reason=reason):
                http = self.summarize(packets)['flows'][0]['http']
                self.assertEqual(http, {'status':'unknown', 'reason':reason, 'requests':[]})

    def test_rst_before_request_is_observation_not_unsent_proof(self):
        result = self.summarize([packet(), packet(0, 20, server=True, ack=101)])
        flow = result['flows'][0]
        self.assertEqual(flow['server']['flagCounts']['RST'], 1)
        self.assertEqual(flow['http']['reason'], 'no-request-bytes')
        self.assertFalse(result['unsentProven'])

    def test_exact_header_only_and_no_correlation_is_explicit(self):
        for request in (f'HEAD /{CID} HTTP/1.1\r\nOther: X-Yl-Trace-Id: {CID}\r\n\r\n'.encode(),
                        b'HEAD / HTTP/1.1\r\nHost: host\r\n\r\n'):
            http = self.summarize([packet(), packet(101, 24, request)])['flows'][0]['http']
            self.assertEqual(http['requests'], [{'method':'HEAD', 'correlationID':None}])
            self.assertEqual(http['status'], 'parsed')

    def test_invalid_duplicate_correlation_and_request_body_do_not_bind(self):
        variants = [REQUEST.replace(CID.encode(), b'not-uuid'),
                    REQUEST[:-2] + f'X-Yl-Trace-Id: {CID}\r\n\r\n'.encode(),
                    REQUEST[:-2] + b'Content-Length: 3\r\n\r\nabc',
                    REQUEST.replace(b'GET ', b'POST ')]
        for request in variants:
            with self.subTest(request=request):
                http = self.summarize([packet(), packet(101, 24, request)])['flows'][0]['http']
                self.assertEqual(http['status'], 'unknown')
                self.assertEqual(http['requests'], [])

    def test_multiple_complete_requests_and_partial_tail(self):
        request = REQUEST + REQUEST.replace(b'GET ', b'HEAD ') + b'GET /'
        http = self.summarize([packet(), packet(101, 24, request)])['flows'][0]['http']
        self.assertEqual(len(http['requests']), 2)
        self.assertEqual(http['reason'], 'incomplete-header')

    def test_syn_retransmission_unique_but_tuple_reuse_ambiguous(self):
        flow = self.summarize([packet(), packet(), packet(101, 24, REQUEST)])['flows'][0]
        self.assertEqual(flow['connectionInstanceStatus'], 'single-opening-syn')
        flow = self.summarize([packet(), packet(101, 24, REQUEST), packet(seq=900)])['flows'][0]
        self.assertEqual(flow['connectionInstanceStatus'], 'multiple-opening-syn')
        self.assertEqual(flow['http']['reason'], 'multiple-opening-syn')
        self.assertEqual(flow['http']['requests'], [])

    def test_conflicting_retransmitted_bytes_are_unknown(self):
        flow = self.summarize([packet(), packet(101, 24, REQUEST), packet(101, 24, b'HEAD')])['flows'][0]
        self.assertEqual(flow['http']['reason'], 'conflicting-retransmission')
        self.assertEqual(flow['http']['requests'], [])

    def test_syn_ack_retransmission_and_competing_replies(self):
        for reply, tail_ack, binding, has_header in (
                (900, 901, 'observed', True),
                (1000, 901, 'ambiguous', True),
                (1000, 1001, 'ambiguous', False)):
            with self.subTest(reply=reply, tail_ack=tail_ack):
                summary = self.summarize([
                    packet(), packet(900, 18, server=True, ack=101),
                    packet(101, 24, REQUEST[:20], ack=901),
                    packet(), packet(reply, 18, server=True, ack=101),
                    packet(121, 24, REQUEST[20:], ack=tail_ack)])
                flow = summary['flows'][0]
                boundaries = [dict(proxyID='abc', requestID=4, correlationID=CID)]
                transaction = dict(index=0, connectionToken=flow['connectionToken'],
                                   proxyConnection=False, binding='unmatched')
                connections = dict(requests=[dict(proxyID='abc', requestID=4,
                                                   transactions=[transaction])])
                row = packet_evidence.attribute_packets(summary, boundaries, connections)['requests'][0]
                self.assertEqual(row['transactions'][0]['binding'], binding)
                self.assertEqual(row['transactions'][0]['packetObserved'], True if binding == 'observed' else None)
                self.assertEqual(row['transactions'][0]['flowIndices'], [0])
                self.assertEqual(row['correlationPacketObserved'], True if has_header else None)

    def test_sequence_wrap_and_syn_payload(self):
        flow = self.summarize([packet(0xfffffffe, 2, REQUEST[:2]), packet(1, 24, REQUEST[2:])])['flows'][0]
        self.assertEqual(flow['http']['requests'][0]['correlationID'], CID)

    def test_filters_exact_service_port_and_ignores_non_ipv4_frames(self):
        result = self.summarize([packet(port=PORT+1), b'\0'*12 + b'\x08\x06' + b'\0'*28, packet()])
        self.assertEqual(result['packetCount'], 1)
        self.assertEqual(result['ignoredPacketCount'], 2)
        self.assertEqual(len(result['flows']), 1)

    def test_empty_capture_is_not_proof_of_no_transmission(self):
        result = self.summarize([])
        self.assertEqual(result['flows'], [])
        self.assertEqual(result['packetCount'], 0)
        self.assertFalse(result['unsentProven'])

    def test_rejects_truncated_unsupported_and_fragmented_evidence(self):
        raw = pcap([packet()])
        truncated_record = bytearray(raw)
        struct.pack_into('<I', truncated_record, 24+12, len(packet())+1)
        fragment = bytearray(packet()); struct.pack_into('!H', fragment, 14+6, 0x2000)
        variants = [raw[:12], raw[:-1], raw+b'\0', bytes(truncated_record), pcap([packet()], link=113),
                    pcap([bytes(fragment)]), pcap([packet()[:30]])]
        for malformed in variants:
            with self.subTest(length=len(malformed)), self.assertRaises(ValueError):
                self.summarize(raw=malformed)

    def test_output_bound_rejects_instead_of_dropping_packets(self):
        with self.assertRaisesRegex(ValueError, 'packet limit'):
            self.summarize([packet()] * 100001)


class PacketAttributionTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(hasattr(packet_evidence, 'attribute_packets'), 'packet attribution missing')
        self.boundaries = [dict(proxyID='ABC', requestID=7, correlationID=CID.upper())]
        self.observation = dict(availability='reported', requests=[dict(proxyID='abc', requestID=7,
            transactions=[dict(index=0, connectionToken='a'*64, proxyConnection=False, binding='bound')])])
        self.summary = dict(flows=[dict(connectionToken='a'*64, connectionInstanceStatus='single-opening-syn',
            packets=[dict(flags=['SYN'])], http=dict(requests=[dict(method='GET',correlationID=CID)]))])

    def attribute(self):
        return packet_evidence.attribute_packets(self.summary, self.boundaries, self.observation)

    def test_known_endpoint_references_unique_flow_without_copying_packet_arrays(self):
        result = self.attribute()
        row = result['requests'][0]
        self.assertEqual((row['proxyID'], row['requestID']), ('ABC', 7))
        self.assertTrue(row['packetObserved'])
        self.assertEqual(row['transactions'][0]['binding'], 'observed')
        self.assertEqual(row['transactions'][0]['flowIndices'], [0])
        self.assertTrue(row['transactions'][0]['packetObserved'])
        self.assertNotIn('packets', json.dumps(result))
        self.assertFalse(result['unsentProven'])
        self.assertFalse(result['rootCauseEstablished'])

    def test_absent_endpoint_exact_case_insensitive_correlation_is_task_evidence_only(self):
        self.observation['requests'][0]['transactions'][0].update(
            connectionToken=None, binding='endpoint-unavailable')
        row = self.attribute()['requests'][0]
        self.assertTrue(row['packetObserved'])
        self.assertTrue(row['correlationPacketObserved'])
        self.assertEqual(row['correlationFlowTokens'], ['a'*64])
        self.assertEqual(row['correlationFlowIndices'], [0])
        self.assertIsNone(row['transactions'][0]['packetObserved'])
        self.assertEqual(row['transactions'][0]['binding'], 'endpoint-unavailable')
        self.assertEqual(row['transactions'][0]['flowIndices'], [])

    def test_unsupported_endpoint_keeps_its_transaction_classification(self):
        transaction = self.observation['requests'][0]['transactions'][0]
        transaction.update(connectionToken=None, binding='unsupported-endpoint', endpointFields=15)
        row = self.attribute()['requests'][0]
        self.assertTrue(row['correlationPacketObserved'])
        self.assertEqual(row['transactions'][0]['binding'], 'unsupported-endpoint')
        self.assertIsNone(row['transactions'][0]['packetObserved'])
        self.assertEqual(row['transactions'][0]['flowIndices'], [])

    def test_absent_endpoint_and_nonmatching_correlation_remain_unknown(self):
        self.observation['requests'][0]['transactions'][0].update(
            connectionToken=None, binding='endpoint-unavailable')
        for correlation in (None, 'prefix-' + CID, CID[:-1] + 'd'):
            with self.subTest(correlation=correlation):
                self.summary['flows'][0]['http']['requests'][0]['correlationID'] = correlation
                row = self.attribute()['requests'][0]
                self.assertIsNone(row['packetObserved'])
                self.assertIsNone(row['correlationPacketObserved'])
                self.assertEqual(row['correlationFlowIndices'], [])

    def test_repeated_tuple_missing_syn_and_unmatched_endpoint_do_not_bind(self):
        self.summary['flows'][0]['http']['requests'] = []
        for state, binding in (('multiple-opening-syn', 'ambiguous'), ('missing-opening-syn', 'missing-opening-syn')):
            with self.subTest(state=state):
                self.summary['flows'][0]['connectionInstanceStatus'] = state
                row = self.attribute()['requests'][0]
                self.assertIsNone(row['packetObserved'])
                self.assertIsNone(row['transactions'][0]['packetObserved'])
                self.assertEqual(row['transactions'][0]['binding'], binding)
                self.assertEqual(row['transactions'][0]['flowIndices'], [0])
        self.summary['flows'] = []
        transaction = self.attribute()['requests'][0]['transactions'][0]
        self.assertEqual(transaction['binding'], 'not-observed-in-capture')
        self.assertIsNone(transaction['packetObserved'])

    def test_same_correlation_across_flows_preserves_all_references(self):
        self.observation['requests'][0]['transactions'] = []
        self.summary['flows'].append(copy.deepcopy(self.summary['flows'][0]))
        self.summary['flows'][1]['connectionToken'] = 'b'*64
        row = self.attribute()['requests'][0]
        self.assertEqual(row['correlationFlowIndices'], [0, 1])
        self.assertEqual(row['correlationFlowTokens'], ['a'*64, 'b'*64])
        self.assertTrue(row['packetObserved'])
        self.assertEqual(row['transactions'], [])

    def test_duplicate_token_flows_and_proxy_transactions_do_not_bind(self):
        self.summary['flows'][0]['http']['requests'] = []
        self.summary['flows'] *= 2
        transaction = self.attribute()['requests'][0]['transactions'][0]
        self.assertEqual(transaction['binding'], 'ambiguous')
        self.assertEqual(transaction['flowIndices'], [0, 1])
        self.assertIsNone(transaction['packetObserved'])
        self.observation['requests'][0]['transactions'][0]['proxyConnection'] = True
        transaction = self.attribute()['requests'][0]['transactions'][0]
        self.assertEqual(transaction['binding'], 'proxy')
        self.assertIsNone(transaction['packetObserved'])

    def test_lifecycle_tuple_ambiguity_survives_single_opening_syn_capture(self):
        self.observation['requests'][0]['transactions'][0]['binding'] = 'ambiguous'
        self.summary['flows'][0]['http']['requests'] = []
        row = self.attribute()['requests'][0]
        transaction = row['transactions'][0]
        self.assertEqual(transaction['binding'], 'ambiguous')
        self.assertIsNone(transaction['packetObserved'])
        self.assertEqual(transaction['flowIndices'], [0])
        self.assertIsNone(row['packetObserved'])


if __name__ == '__main__':
    unittest.main()
