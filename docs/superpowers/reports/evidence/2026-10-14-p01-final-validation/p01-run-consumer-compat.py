"""Run only the remaining owned consumers with an isolated Flutter lipo adapter."""
from pathlib import Path
import os,sys,subprocess,shlex
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
for platform,manager in [('macos','cocoapods'),('ios','swiftpm'),('macos','swiftpm')]:
 host=consumers.bootstrap(platform,manager,link=True)
 if platform=='macos':
  subprocess.run(['ruby','-e',patch,str(host/'macos/Runner.xcodeproj'),prefix],check=True)
 consumers.check(platform,manager,link=True)
