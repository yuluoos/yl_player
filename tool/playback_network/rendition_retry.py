"""Observe post-reset admissions; never infer AVPlayer's private retry policy."""
from proxy_boundaries import summarize_proxy_boundaries


def _validate_high_assets(high_assets):
    if not isinstance(high_assets, set) or not high_assets or not all(isinstance(v, str) and v for v in high_assets):
        raise ValueError('retry evidence requires explicit owned high assets')


def summarize_rendition_retries(boundaries, server_rows, high_assets):
    """Require complete joins and v7 error attribution before counting absence.

    Admission and downstream termination use the same device uptime clock.
    Server timestamps must not determine whether a request followed an error.
    A different proxy is kept separate: its traffic cannot prove that the
    original AVPlayer item spontaneously retried the rendition.
    """
    observation = summarize_proxy_boundaries(boundaries, server_rows, 7)
    if not observation['fullyCorrelated']:
        raise ValueError('retry evidence requires complete request correlation')
    _validate_high_assets(high_assets)
    servers = {s['requestId']: s for s in server_rows}
    joined = {(s['proxyID'], s['requestID']): servers[s['serverRequestID']]
              for s in observation['requests']}
    high = [b for b in boundaries if joined[b['proxyID'], b['requestID']]['asset'] in high_assets]
    return dict(highResets=_high_resets(high, joined), rootCauseEstablished=False, capabilityAccepted=False,
        interpretation='After means admission strictly after recorded termination in device uptime; already outstanding requests and other proxy lifetimes are separate. No requests proves only absence in this capture, not a private penalty timer or future behavior.')


def _high_resets(high, joined):
    resets = []
    for failed in high:
        if (failed['outcome'], failed['cancelCause'], failed['cancelErrorDomain'], failed['cancelErrorCode']) != (1, 3, 1, 54):
            continue
        terminal = failed['downstreamTerminal']
        later = [b for b in high if b['admission'] > terminal]
        same = [b for b in later if b['proxyID'] == failed['proxyID']]
        asset = joined[failed['proxyID'], failed['requestID']]['asset']
        resets.append(dict(proxyID=failed['proxyID'], requestID=failed['requestID'],
            source=failed['cancelSource'],
            sameProxyLaterHighRequests=[b['requestID'] for b in same],
            sameProxySameAssetRetries=[b['requestID'] for b in same if joined[b['proxyID'], b['requestID']]['asset'] == asset],
            otherProxyLaterHighRequests=[dict(proxyID=b['proxyID'], requestID=b['requestID']) for b in later if b['proxyID'] != failed['proxyID']],
            sameProxyOutstandingHighRequests=[b['requestID'] for b in high
                if b is not failed and b['proxyID'] == failed['proxyID'] and b['admission'] <= terminal < b['downstreamTerminal']]))
    return resets


def summarize_scoped_rendition_retries(boundaries, server_rows, high_assets):
    """Keep unavailable proxy scopes explicit without weakening the strict API.

    Unmatched server media cannot be assigned to a proxy and blocks all absence
    claims. A locally cancelled request without a server join remains unknown,
    even when Foundation reports zero bytes.
    """
    observation = summarize_proxy_boundaries(boundaries, server_rows, 7)
    _validate_high_assets(high_assets)
    servers = {s['requestId']: s for s in server_rows}
    joined = {(r['proxyID'], r['requestID']): servers[r['serverRequestID']]
              for r in observation['requests'] if r['serverRequestID'] is not None}
    groups = {}
    for row in boundaries:
        groups.setdefault(row['proxyID'], []).append(row)
    scopes = []
    for proxy, rows in groups.items():
        unknown = [dict(requestID=r['requestID'], cancelCause=r['cancelCause'],
            cancelSource=r['cancelSource'], cancelErrorDomain=r['cancelErrorDomain'],
            cancelErrorCode=r['cancelErrorCode'], taskOutcome=r['taskOutcome'])
            for r in rows if (proxy, r['requestID']) not in joined]
        complete = not unknown and not observation['unmatchedServerRequestIDs']
        resets = None
        if complete:
            high = [r for r in rows if joined[proxy, r['requestID']]['asset'] in high_assets]
            resets = _high_resets(high, joined)
            for reset in resets:
                del reset['otherProxyLaterHighRequests']
        scopes.append(dict(proxyID=proxy, requestCount=len(rows),
            correlatedRequestCount=len(rows)-len(unknown), uncorrelatedRequests=unknown,
            retryObservationComplete=complete, highResets=resets))
    return dict(fullyCorrelated=observation['fullyCorrelated'],
        unmatchedServerRequestIDs=observation['unmatchedServerRequestIDs'], proxyScopes=scopes,
        rootCauseEstablished=False, capabilityAccepted=False, physicalOutputVerified=False,
        interpretation='Scopes describe recorded admissions within one proxy only, using device uptime. Null highResets means unavailable, not no retry. Unknown cancelled requests remain uncorrelated; zero bytes do not prove no transmission. Unmatched server media blocks all scopes. Complete local scopes do not pass the strict whole-capture gate or prove future behavior.')


def main():
    import argparse
    import gzip
    import json
    from pathlib import Path

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--boundaries', type=Path, required=True)
    parser.add_argument('--server-requests', type=Path, required=True)
    parser.add_argument('--high-assets', type=Path, required=True,
                        help='JSON array of explicit owned high-rendition asset paths')
    parser.add_argument('--scoped', action='store_true',
                        help='Report each proxy separately; this is not an acceptance gate')
    args = parser.parse_args()

    def read_rows(path):
        opener = gzip.open if path.suffix == '.gz' else open
        with opener(path, 'rt') as stream:
            return [json.loads(line) for line in stream if line.strip()]

    assets = json.loads(args.high_assets.read_text())
    if not isinstance(assets, list) or not all(isinstance(v, str) for v in assets):
        parser.error('high-assets must be a JSON array of asset paths')
    summarize = summarize_scoped_rendition_retries if args.scoped else summarize_rendition_retries
    result = summarize(read_rows(args.boundaries), read_rows(args.server_requests), set(assets))
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
