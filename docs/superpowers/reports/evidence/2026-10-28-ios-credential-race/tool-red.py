from pathlib import Path
p=Path('tool/playback_network/test_abr_policy.py');s=p.read_text();start=s.index('    def test_intent_revision_rejects_cross_revision_windows_and_tickets(');end=s.index('    def test_valid_rejections',start)
t=s[start:end].replace('test_intent_revision_rejects_cross_revision_windows_and_tickets','test_credential_revision_rejects_cross_revision_windows_and_tickets').replace('intentRevision','credentialRevision')
s=s[:end]+t+s[end:];p.write_text(s)
