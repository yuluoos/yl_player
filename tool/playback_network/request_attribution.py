"""Audit recorded transaction phases and server receipts without repairing gaps."""
from connection_lifecycle import summarize_lifecycle
from proxy_boundaries import IncompleteSuccessfulTransactions, summarize_proxy_boundaries
from transaction_metrics import CORE, DURATIONS


def _transaction(index, item):
    complete = item['fetchType'] == 1 and all(item[k] is not None for k in ('fetchSeconds',)+CORE)
    state = 'complete-network-timing' if complete else 'partial-timing'
    dates = item.get('durationStates')
    if dates is not None:
        if dates['requestSeconds'] == 0 and dates['responseSeconds'] == 3:
            state = 'request-recorded-response-unobserved'
        elif dates['fetchToRequestSeconds'] == 2 and dates['requestSeconds'] == dates['responseSeconds'] == 3:
            state = 'before-recorded-request'
    return dict(index=index, timingState=state, timingComplete=complete,
        durations={k:item[k] for k in sorted(DURATIONS)}, durationStates=dates,
        transportBytes=item.get('transportBytes'), serverRequestID=None)


def summarize_request_attribution(boundaries, server_rows, lifecycle):
    # The existing validators own structural/identity/byte validation. Only their
    # explicitly validated partial observation may survive a strict timing error.
    failures = []
    try:
        observation = summarize_proxy_boundaries(boundaries, server_rows)
    except IncompleteSuccessfulTransactions as error:
        observation = error.observation
        failures.extend(error.failures)
    coverage = summarize_lifecycle(lifecycle, server_rows)
    coverage['allAcceptedConnectionsHaveParsedRequests'] = (
        coverage['complete'] and coverage['rejectedCount'] == 0 and not coverage['withoutParsedRequest'])
    if not observation['fullyCorrelated']:
        failures.append(dict(code='incomplete-request-correlation'))
    requests = []
    for raw, row in zip(boundaries, observation['requests']):
        metrics = row['transactionMetrics']
        transactions = [_transaction(i, item) for i, item in enumerate(metrics['transactions'])]
        # A task-level trace ID cannot assign its server receipt to a particular
        # Foundation transaction. Counts, ordinal order and cross-clock proximity
        # do not create that missing binding.
        requests.append(dict(proxyID=row['proxyID'], requestID=row['requestID'],
            correlationID=raw.get('correlationID'), outcome=row['outcome'],
            cancelCause=row['cancelCause'], taskOutcome=row['taskOutcome'],
            serverRequestID=row['serverRequestID'],
            serverReceipt=('parsed-request-observed' if row['serverRequestID'] is not None
                           else 'not-observed-in-recorded-requests'),
            physicalReceipt='unknown', metricAvailability=metrics['byteEvidence']['availability'],
            taskSeconds=metrics['taskSeconds'], allTransactionTimingsComplete=metrics['complete'],
            finalTransactionTimingComplete=(transactions[-1]['timingComplete'] if transactions
                and not metrics['truncated'] else None), transactions=transactions))
    return dict(version=1, diagnosticOnly=True, serverCoverage=coverage, requests=requests,
        strictProxyEvidencePassed=not failures, strictFailures=failures,
        unmatchedServerRequestIDs=observation['unmatchedServerRequestIDs'],
        rootCauseEstablished=False, capabilityAccepted=False, physicalOutputVerified=False,
        interpretation='Timing states describe Foundation observations, not why a phase is absent. '
            'A parsed server receipt binds a proxy task, not its individual transactions. '
            'Complete handler logs cover admitted application connections, not TCP backlog, packets, '
            'partial requests or physical delivery. Unobserved trace IDs and zero counts do not prove '
            'no transmission. No missing timestamp or receipt is synthesized; strict failures remain.')


def main():
    import argparse
    import gzip
    import json
    from pathlib import Path

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--boundaries', type=Path, required=True)
    parser.add_argument('--server-requests', type=Path, required=True)
    parser.add_argument('--lifecycle', type=Path, required=True)
    args = parser.parse_args()

    def read(path):
        opener = gzip.open if path.suffix == '.gz' else open
        with opener(path, 'rt') as stream:
            return stream.read()

    result = summarize_request_attribution(
        [json.loads(line) for line in read(args.boundaries).splitlines() if line.strip()],
        [json.loads(line) for line in read(args.server_requests).splitlines() if line.strip()],
        json.loads(read(args.lifecycle)))
    # Exit zero means a valid diagnostic was produced, never media acceptance.
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
