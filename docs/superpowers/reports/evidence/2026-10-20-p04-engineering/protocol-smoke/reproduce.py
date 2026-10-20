import asyncio, hashlib, io, json, os, signal, socket, sys, tarfile, tempfile
from pathlib import Path
sys.path.insert(0, str(Path.cwd()/'tool/playback_network'))
from live_relay import LiveRelay
from network_profile import Profile

async def main():
    root=Path.cwd(); peer=Path('/private/tmp/yl-rtmp-foundation')
    source=root/'tool/consumer_fixtures/apple_flutter/Resources/h264_aac.flv'
    media_hash=hashlib.sha256(source.read_bytes()).hexdigest()
    assert media_hash=='cfe009b1b03b6cacf4ae9f037eed4441a32b99508d4fabccb429bea439cf570b'
    assert hashlib.sha256((peer/'mediamtx.tar.gz').read_bytes()).hexdigest()=='25e20ed41611f1f3103b8359585210b29b11b69fa0d9e11bd11b92f7bbcb42ef'
    with tarfile.open(peer/'mediamtx.tar.gz') as archive:
        assert hashlib.sha256(archive.extractfile('mediamtx').read()).digest()==hashlib.sha256((peer/'mediamtx').read_bytes()).digest()
    output=Path(tempfile.mkdtemp(prefix='p04-live-smoke-',dir='/private/tmp'))
    children=[]; handles=[]; relays=[]; reports=[]
    def port():
        with socket.socket() as s:
            s.bind(('127.0.0.1',0)); return s.getsockname()[1]
    async def spawn(args,name):
        handle=(output/name).open('wb');handles.append(handle)
        process=await asyncio.create_subprocess_exec(*args,stdout=handle,stderr=asyncio.subprocess.STDOUT,start_new_session=True)
        children.append(process);return process
    try:
        rtmp,hls,flv=port(),port(),port()
        config=output/'peer.yml'
        config.write_text(f'logLevel: warn\nrtsp: false\nrtmp: true\nrtmpAddress: 127.0.0.1:{rtmp}\nhls: true\nhlsAddress: 127.0.0.1:{hls}\nhlsVariant: mpegts\nhlsAlwaysRemux: true\nwebrtc: false\nsrt: false\nmoq: false\napi: false\nmetrics: false\npprof: false\nplayback: false\npaths:\n  all_others:\n')
        server=await spawn([str(peer/'mediamtx'),str(config)],'server.log')
        await asyncio.sleep(.5);assert server.returncode is None
        ffmpeg=['/opt/homebrew/bin/ffmpeg','-nostdin','-hide_banner','-loglevel','warning']
        pub=await spawn(ffmpeg+['-re','-stream_loop','-1','-i',str(source),'-c','copy','-f','flv',f'rtmp://127.0.0.1:{rtmp}/live/owned'],'publisher.log')
        flv_pub=await spawn(ffmpeg+['-re','-stream_loop','-1','-i',str(source),'-c','copy','-f','flv','-listen','1',f'http://127.0.0.1:{flv}/live.flv'],'flv.log')
        await asyncio.sleep(5);assert pub.returncode is None and flv_pub.returncode is None
        profile=Profile(dict(id='protocol-smoke-v1',steps=[dict(atMs=0,bytesPerSecond=500000,latencyMs=0),dict(atMs=1000,bytesPerSecond=100000,latencyMs=10),dict(atMs=2000,bytesPerSecond=500000,latencyMs=0)]))
        for protocol, upstream, scheme,path in [('hls',hls,'http','live/owned/index.m3u8'),('flv',flv,'http','live.flv'),('rtmp',rtmp,'rtmp','live/owned')]:
            log=(output/(protocol+'.jsonl')).open('w');handles.append(log)
            relay=LiveRelay(profile,log,run_id='smoke-'+protocol,protocol=protocol,media_hash=media_hash,upstream_port=upstream)
            relays.append(relay);await relay.start()
            consumer=await spawn(ffmpeg+['-i',f'{scheme}://127.0.0.1:{relay.port}/{path}','-t','4','-map','0:v:0','-map','0:a:0','-f','null','-'],protocol+'-decode.log')
            code=await asyncio.wait_for(consumer.wait(),30)
            await relay.close()
            receipt=relay.receipt(); receipt['decoderExitCode']=code
            rows=[json.loads(line) for line in (output/(protocol+'.jsonl')).read_text().splitlines()]
            receipt['phaseBytes']=[sum(row['phaseBytes'][i] for row in rows) for i in range(3)]
            reports.append(receipt)
            assert code==0, protocol
            assert receipt['cleaned'] and sum(receipt['phaseBytes'])>0
    finally:
        for relay in relays: await relay.close()
        for process in reversed(children):
            if process.returncode is None:
                os.killpg(process.pid,signal.SIGTERM)
                try: await asyncio.wait_for(process.wait(),3)
                except asyncio.TimeoutError:
                    os.killpg(process.pid,signal.SIGKILL);await process.wait()
        for handle in handles: handle.close()
        (output/'report.json').write_text(json.dumps(dict(kind='independent-decoder-protocol-smoke',reports=reports,physicalOutputVerified=False,capabilityAccepted=False),indent=2)+'\n')
        print(output,flush=True)

asyncio.run(main())
