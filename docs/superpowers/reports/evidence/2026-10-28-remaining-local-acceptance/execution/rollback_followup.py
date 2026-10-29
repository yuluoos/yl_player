from pathlib import Path
base=(Path('/private/tmp/yl-local-acceptance/final_recovery.py')).read_text().split('properties=root/')[0].replace("'recovery-results.json'","'rollback-followup-results.json'")
exec(base)
run('android_multi_player_rollback-corrected',['sh',str(root/'tool/run_android_integration.sh'),'integration_test/android_multi_player_rollback_test.dart'],root/'packages/yl_player/example',extra=dict(YL_ANDROID_DEVICE_ID='emulator-5580',YL_ANDROID_API='36'))
run('rollback-format',['dart','format','--output=none','--set-exit-if-changed','packages/yl_player/example/integration_test/android_multi_player_rollback_test.dart'])
run('rollback-analyze',['flutter','analyze','--no-pub','integration_test/android_multi_player_rollback_test.dart'],root/'packages/yl_player/example')
run('state_update_cadence-fresh',['sh',str(root/'tool/run_android_integration.sh'),'integration_test/state_update_cadence_test.dart'],root/'packages/yl_player/example',extra=dict(YL_ANDROID_DEVICE_ID='emulator-5580',YL_ANDROID_API='36'))
