"""Link owned CFNetwork log entries to validated proxy task identities."""
from collections import defaultdict
import re


TASK_CONNECTION = re.compile(r'(setting up|now using) Connection ([0-9]+)')
CONNECTION_PREFIX = re.compile(r'^Connection ([0-9]+):|^(?:[\w]+ )?\[C([0-9]+)(?=[:. \]])')


def summarize_client_tasks(logs, requests, pid):
    if type(pid) is not int or pid <= 1:
        raise ValueError('invalid test process')
    tasks = {row['foundationTaskID']: ([], set(), set()) for row in requests if row.get('foundationTaskID')}
    connection_rows = defaultdict(list)
    for index, row in enumerate(logs):
        if row['pid'] != pid or row['subsystem'] not in ('com.apple.CFNetwork', 'com.apple.network'):
            raise ValueError('unexpected client log source')
        message = row['message']
        if not isinstance(message, str):
            raise ValueError('invalid client log message')
        if row['subsystem'] == 'com.apple.CFNetwork' and message.startswith('Task '):
            identity, _, detail = message[5:].partition(' ')
            event = tasks.get(identity.lower())
            if event is not None:
                indices, setups, uses = event
                indices.append(index)
                match = TASK_CONNECTION.fullmatch(detail)
                if match:
                    connections = setups if match[1] == 'setting up' else uses
                    connections.add(int(match[2]))
        else:
            match = CONNECTION_PREFIX.match(message)
            if match:
                connection_rows[int(match[1] or match[2])].append(index)

    linked = []
    related = set()
    for request in requests:
        identity = request.get('foundationTaskID')
        indices, setups, uses = tasks.get(identity, ([], (), ()))
        related.update(setups, uses)
        linked.append(dict(proxyID=request['proxyID'], requestID=request['requestID'],
                           foundationTaskID=identity, taskLogIndices=indices,
                           setupConnectionIDs=sorted(setups), usedConnectionIDs=sorted(uses)))
    matched = sum(bool(row['taskLogIndices']) for row in linked)
    return dict(version=1, availability='reported', complete=bool(linked) and matched == len(linked),
                logEntryCount=len(logs), matchedTaskCount=matched, requests=linked,
                connectionLogIndices={str(c): connection_rows[c] for c in sorted(related)})
