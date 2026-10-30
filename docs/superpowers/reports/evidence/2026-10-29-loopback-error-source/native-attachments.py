from pathlib import Path
import subprocess,json
r=Path('/private/tmp/yl-loopback-error-source');result={}
for platform in ('ios','macos'):
 result[platform]={}
 for test,prefix,key in [('testProxyResetRecordsRealLoopbackErrorAndReclaimsTask','loopback-reset-error-source','reset'),('testProxyTransactionsPreserveMissingResponseDatesAfterOwnedConnectionClose','forced-close-transaction-bytes','double')]:
  out=r/(platform+'-'+key+'-attachments');bundle=r/(platform+'-final.xcresult')
  if not (out/'manifest.json').exists():subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(bundle),'--output-path',str(out),'--test-id','YlDashResourceLoaderTests/'+test+'()'],check=True,capture_output=True)
  manifest=json.loads((out/'manifest.json').read_text());files=[v for group in manifest for v in group['attachments'] if v['suggestedHumanReadableName'].startswith(prefix)];assert len(files)==1
  result[platform][key]=json.loads((out/files[0]['exportedFileName']).read_text())
(r/'controlled-native.json').write_text(json.dumps(result,indent=2)+'\n')
for platform,d in result.items():
 v=d['reset'];print(platform,'reset',{k:v[k] for k in ('cancelCause','cancelSource','cancelErrorDomain','cancelErrorCode')})
 v=d['double']['trace'];print(platform,'double',v['metrics']['transactionCount'])
