"""Validate owned-server lifecycle evidence; no attribution of remote retry causes."""
import math
import re


def summarize_lifecycle(trace, rows):
    def require(ok):
        if not ok: raise ValueError('invalid connection lifecycle evidence')
    def integer(value, maximum=10000):
        return type(value) is int and 0 <= value <= maximum
    def finite(value):
        try:return type(value) in (float,int) and math.isfinite(value) and value >= 0
        except OverflowError:return False
    require(isinstance(trace,dict) and set(trace)=={'version','acceptedCount','rejectedCount','droppedRejections','connections','rejections'})
    require(type(trace['version']) is int and trace['version'] in (1,2))
    require(integer(trace['acceptedCount']) and integer(trace['rejectedCount'],2**53-1) and integer(trace['droppedRejections'],2**53-1))
    connections=trace['connections'];rejects=trace['rejections']
    require(isinstance(connections,list) and len(connections)==trace['acceptedCount'])
    require(isinstance(rejects,list) and len(rejects)==min(trace['rejectedCount'],32))
    require(trace['droppedRejections']==trace['rejectedCount']-len(rejects))
    require(isinstance(rows,list) and len(rows)<=10000)
    by_connection={};request_ids=set()
    for row in rows:
        require(isinstance(row,dict) and integer(row.get('connectionId')) and row['connectionId']>0 and
                integer(row.get('requestId')) and row['requestId']>0 and integer(row.get('connectionRequestIndex')) and row['connectionRequestIndex']>0)
        require(row['requestId'] not in request_ids);request_ids.add(row['requestId'])
        by_connection.setdefault(row['connectionId'],[]).append(row)
    require(request_ids==set(range(1,len(rows)+1)))
    missing=[];unclosed=[];closed_reasons={};previous=0;unrecorded=0
    for index,c in enumerate(connections,1):
        require(isinstance(c,dict) and set(c)=={'connectionId','acceptedSeconds','closedSeconds','activeAtAdmission','requestIds','unrecordedRequests','closeReason'} | ({'connectionToken'} if trace['version']==2 else set()))
        if trace['version']==2:require(isinstance(c['connectionToken'],str) and re.fullmatch('[0-9a-f]{64}',c['connectionToken']))
        require(type(c['connectionId']) is int and c['connectionId']==index and finite(c['acceptedSeconds']) and c['acceptedSeconds']>=previous)
        previous=c['acceptedSeconds'];require(integer(c['activeAtAdmission'],8) and c['activeAtAdmission']>0)
        require(c['closeReason'] in (None,'handlerEnded','absoluteDeadline','serverShutdown','handlerError','requestRecordLimit'))
        if c['closedSeconds'] is None:unclosed.append(index)
        else:
            require(finite(c['closedSeconds']) and c['closedSeconds']>=c['acceptedSeconds'] and c['closeReason'] is not None)
            closed_reasons[c['closeReason']]=closed_reasons.get(c['closeReason'],0)+1
        require(integer(c['unrecordedRequests'],1))
        unrecorded+=c['unrecordedRequests']
        if c['closeReason']=='requestRecordLimit':require(c['unrecordedRequests']==1)
        if c['unrecordedRequests']:require(len(rows)==10000)
        requests=c['requestIds'];require(isinstance(requests,list) and len(requests)<=10000 and all(integer(i) and i>0 for i in requests))
        observed=sorted(by_connection.pop(index,[]),key=lambda r:r['connectionRequestIndex'])
        require([r['connectionRequestIndex'] for r in observed]==list(range(1,len(requests)+1)))
        require(requests==[r['requestId'] for r in observed])
        if not requests and not c['unrecordedRequests']:missing.append(index)
    require(not by_connection)
    previous=0
    for rejection in rejects:
        require(isinstance(rejection,dict) and set(rejection)=={'elapsed','reason','active'})
        require(finite(rejection['elapsed']) and rejection['elapsed']>=previous);previous=rejection['elapsed']
        require(rejection['reason'] in ('activeLimit','connectionLimit') and integer(rejection['active'],8))
        if rejection['reason']=='activeLimit':require(rejection['active']==8)
        else:require(trace['acceptedCount']==10000 and rejection['elapsed']>=connections[-1]['acceptedSeconds'])
    return dict(version=trace['version'],acceptedCount=len(connections),rejectedCount=trace['rejectedCount'],
        droppedRejections=trace['droppedRejections'],unrecordedRequests=unrecorded,parsedRequests=len(rows),withoutParsedRequest=missing,
        unclosedConnections=unclosed,closedReasonCounts=closed_reasons,
        complete=not unclosed and not trace['droppedRejections'] and not unrecorded,retryCauseProven=False,capabilityAccepted=False,
        interpretation='Server-local elapsed time from listener construction, not profile time. handlerEnded means only that the handler returned; it does not prove peer FIN/reset or identify a URLSession transaction.')
