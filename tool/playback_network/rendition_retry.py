"""Observe post-reset admissions; never infer AVPlayer's private retry policy."""
from proxy_boundaries import summarize_proxy_boundaries


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
    if not isinstance(high_assets, set) or not high_assets or not all(isinstance(v, str) and v for v in high_assets):
        raise ValueError('retry evidence requires explicit owned high assets')
    servers = {s['requestId']: s for s in server_rows}
    joined = {(s['proxyID'], s['requestID']): servers[s['serverRequestID']]
              for s in observation['requests']}
    high = [b for b in boundaries if joined[b['proxyID'], b['requestID']]['asset'] in high_assets]
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
    return dict(highResets=resets, rootCauseEstablished=False, capabilityAccepted=False,
        interpretation='After means admission strictly after recorded termination in device uptime; already outstanding requests and other proxy lifetimes are separate. No requests proves only absence in this capture, not a private penalty timer or future behavior.')
