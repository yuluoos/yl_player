from pathlib import Path
import sys
r=Path('/private/tmp/yl-production-recovery')
p=Path('tool/playback_network/test_abr_accesslog.py');s=p.read_text().replace("'no-install', 'credential']:", "'no-install', 'credential', 'ends-low', 'no-downshift']:")
s=s.replace("            else:rr[-1]['automaticEvents'][0]['credentialCommitAccepted']=False", "            elif mutation=='credential':rr[-1]['automaticEvents'][0]['credentialCommitAccepted']=False\n            elif mutation=='ends-low':rr[-1]['width']=320\n            else:rr[1]['width']=640")
p.write_text(s)
