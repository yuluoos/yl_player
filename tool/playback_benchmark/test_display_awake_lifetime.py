"""Verify the assertion remains tied to command lifetime, using caffeinate's timeout semantics."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('display_awake',Path(__file__).resolve().parents[1]/'run_with_display_awake.py')
awake=importlib.util.module_from_spec(spec);spec.loader.exec_module(awake)


class DisplayAwakeLifetimeTests(unittest.TestCase):
    def test_command_longer_than_four_minutes_keeps_display_protected_until_exit(self):
        state={'seconds':0,'assertion':None,'ownerFinished':False,'released':False}
        class Process:
            pid=73
            def __init__(self,args,**kwargs):
                self.assertion=args[0]=='/usr/bin/caffeinate';self.returncode=None
                if self.assertion:
                    self.timeout=int(args[args.index('-t')+1]) if '-t' in args else None
                    self.owner=int(args[args.index('-w')+1])
                    state['assertion']=self
            def poll(self):return self.returncode
            def wait(self,timeout=None):
                if self.assertion:return self.returncode
                if state['seconds']<300:
                    state['seconds']+=60
                    raise subprocess.TimeoutExpired('owned playback',timeout)
                a=state['assertion'];protected=a.owner==self.pid and (a.timeout is None or state['seconds']<a.timeout)
                self.returncode=0 if protected else 91
                state['ownerFinished']=True
                return self.returncode
            def terminate(self):
                state['released']=state['ownerFinished'];self.returncode=0
        with patch.object(awake.subprocess,'Popen',Process):
            self.assertEqual(awake.run(['owned-playback']),0,'Display assertion expired while playback was still running')
        self.assertTrue(state['released'],'Protection must be released after the owned command exits')
