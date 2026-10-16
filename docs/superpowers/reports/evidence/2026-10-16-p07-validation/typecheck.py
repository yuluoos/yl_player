from pathlib import Path
import subprocess,sys
root=Path('/private/tmp/yl-p07-validation/yl_player')
p=root/'packages/yl_player_apple/darwin/yl_player_apple'
s=p/'Sources/yl_player_apple'
platform=sys.argv[1]
if platform=='macos':
 target='arm64-apple-macosx12.0';sdk='macosx';slice='macos-arm64_x86_64';engine='darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64'
else:
 target='arm64-apple-ios15.0';sdk='iphoneos';slice='ios-arm64';engine='ios/Flutter.xcframework/ios-arm64'
framework=Path('/Users/yy2021_8689/flutter/bin/cache/artifacts/engine')/engine
sdkpath=subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'],text=True).strip()
files=sorted(s.rglob('*.swift'))
cmd=['xcrun','swiftc','-typecheck','-module-name','yl_player_apple','-target',target,'-sdk',sdkpath,'-module-cache-path','/private/tmp/yl-p07-validation/typecheck-cache-'+platform,'-F',str(framework),'-F',str(p/'Frameworks/YlFFmpegBridge.xcframework'/slice),*[str(f) for f in files]]
print('Full production typecheck',target,len(files),'Swift sources',flush=True)
r=subprocess.run(cmd)
print('TYPECHECK_EXIT',r.returncode,flush=True)
raise SystemExit(r.returncode)
