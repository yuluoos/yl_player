"""Explicit, owned-host-only setup for the existing native lipo adapter."""
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import sys
import xml.etree.ElementTree as ET


def prefix(path):
    return 'export PATH='+shlex.quote(str(path))+':"$PATH"\n'


def patch_script(script, addition):
    if 'macos_assemble.sh' not in script: raise ValueError('not a Flutter phase')
    if script.startswith(addition): return script
    if script.startswith('export PATH='): raise ValueError('conflicting adapter')
    return addition+script


def patch_scheme(path, addition):
    tree=ET.parse(path)
    actions=[node for node in tree.getroot().iter('ActionContent')
             if 'macos_assemble.sh' in node.get('scriptText','')]
    if len(actions)!=1: raise ValueError('expected one Flutter prepare action')
    for node in actions: node.set('scriptText',patch_script(node.get('scriptText'),addition))
    tree.write(path,encoding='UTF-8',xml_declaration=True)


def configure(host, root, manager, enabled):
    marker=host/'lipo-compat.json'
    if not enabled:
        if marker.exists(): raise ValueError('compatibility host requires --lipo-compat; use a fresh host for native defaults')
        return
    owner=json.loads((host/'consumer.json').read_text())
    if owner['repo_root']!=str(root) or owner['platform']!='macos': raise ValueError('host ownership mismatch')
    source=Path(__file__).with_name('lipo_verify_compat.py').read_text()
    folder=host/'lipo-compat';folder.mkdir(exist_ok=True)
    script='#!'+sys.executable+'\n'+source.split('\n',1)[1]
    adapter=folder/'lipo'
    if adapter.exists() and adapter.read_text()!=script: raise ValueError('adapter changed')
    adapter.write_text(script);adapter.chmod(0o755)
    addition=prefix(folder)
    # Xcode resets PATH for shell phases: scope the adapter to the two generated
    # Flutter phases, not the shared SDK or the inspection commands.
    ruby="""require 'xcodeproj'
p = Xcodeproj::Project.open(ARGV[0])
phases = p.targets.flat_map(&:shell_script_build_phases).select { |x| x.shell_script.include?('macos_assemble.sh') }
abort 'Expected two Flutter phases' unless phases.size == 2
phases.each do |x|
  next if x.shell_script.start_with?(ARGV[1])
  abort 'Conflicting adapter' if x.shell_script.start_with?('export PATH=')
  x.shell_script = ARGV[1] + x.shell_script
end
p.save
"""
    subprocess.run(['ruby','-e',ruby,str(host/'macos/Runner.xcodeproj'),addition],check=True)
    if manager=='swiftpm': patch_scheme(host/'macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme',addition)
    marker.write_text(json.dumps(dict(schemaVersion=1,adapterSha256=hashlib.sha256(adapter.read_bytes()).hexdigest(),
        scope='owned-Flutter-build-phases',requiredArchitectures=['arm64','x86_64']),indent=2)+'\n')
