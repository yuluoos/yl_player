from pathlib import Path
p=Path('tool/playback_network/test_network_profile.py');s=p.read_text();pos=s.index('    def test_transfer_crosses_rate_boundary')
s=s[:pos]+'''    def test_waiting_for_budget_lock_observes_deadline_and_stop(self):
        for stop in [False,True]:
            with self.subTest(stop=stop):
                shaper=net.Shaper(net.Profile(profile(step())))
                shaper.lock.acquire();done=threading.Event();failures=[]
                def consume():
                    try:shaper.consume(1,deadline=shaper.elapsed()+(.06 if not stop else 10))
                    except Exception as error:failures.append(type(error))
                    finally:done.set()
                worker=threading.Thread(target=consume,daemon=True);worker.start()
                if stop:shaper.stopped.set()
                try:self.assertTrue(done.wait(.5),'A queued request must not wait for the lock owner after cancellation/deadline')
                finally:shaper.lock.release();worker.join(timeout=1)
                self.assertEqual(failures,[net.Disconnected if stop else TimeoutError])

'''+s[pos:];p.write_text(s)
