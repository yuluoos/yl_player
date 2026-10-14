"""Run only the remaining owned consumers with an isolated Flutter lipo adapter."""
from pathlib import Path
import os,sys,subprocess,shlex
import xml.etree.ElementTree as ET
root=Path(os.environ['YL_REPO_ROOT']).resolve()
sys.path.insert(0,str(root/'tool/consumer_fixtures/apple_flutter'))
import consumers
adapter=Path('/private/tmp/p01-lipo-compat/lipo')
assert adapter.is_file()
prefix='export PATH='+shlex.quote(str(adapter.parent))+':"$PATH"\n'
patch='''require 'xcodeproj'
p = Xcodeproj::Project.open(ARGV[0])
phases = p.targets.flat_map(&:shell_script_build_phases).select { |x| x.shell_script.include?('macos_assemble.sh') }
abort 'Expected exactly two owned Flutter shell phases' unless phases.size == 2
phases.each { |x| x.shell_script = ARGV[1] + x.shell_script unless x.shell_script.start_with?(ARGV[1]) }
p.save
'''
for platform,manager in [('macos','swiftpm')]:
 host=consumers.bootstrap(platform,manager,link=True)
 if platform=='macos':
  subprocess.run(['ruby','-e',patch,str(host/'macos/Runner.xcodeproj'),prefix],check=True)
 if platform=='macos' and manager=='swiftpm':
  scheme=host/'macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme'
  tree=ET.parse(scheme)
  actions=[n for n in tree.getroot().iter('ActionContent') if 'macos_assemble.sh' in n.get('scriptText','')]
  assert len(actions)==1
  for action in actions:
   script=action.get('scriptText')
   if not script.startswith(prefix):action.set('scriptText',prefix+script)
  tree.write(scheme,encoding='UTF-8',xml_declaration=True)
 consumers.check(platform,manager,link=True)
