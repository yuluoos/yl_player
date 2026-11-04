// Read Core Audio's process-scoped output list. The set command changes only
// the normal default output, leaving the system-alert and input devices alone.
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

static const AudioObjectID systemObject = kAudioObjectSystemObject;
static AudioObjectPropertyAddress address(AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress){selector, scope, kAudioObjectPropertyElementMain};
}
static void check(OSStatus status) {
    if (status != noErr) {
        fprintf(stderr, "Core Audio status %d\n", (int)status);
        exit(1);
    }
}
static UInt32 scalar(AudioObjectID object, AudioObjectPropertySelector key, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = address(key, scope);
    UInt32 value = 0, size = sizeof(value);
    check(AudioObjectGetPropertyData(object, &a, 0, NULL, &size, &value));
    return value;
}
static NSArray<NSNumber *> *objects(AudioObjectID object, AudioObjectPropertySelector key, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = address(key, scope);
    UInt32 size = 0;
    check(AudioObjectGetPropertyDataSize(object, &a, 0, NULL, &size));
    if (!size) return @[];
    NSMutableData *storage = [NSMutableData dataWithLength:size];
    check(AudioObjectGetPropertyData(object, &a, 0, NULL, &size, storage.mutableBytes));
    const AudioObjectID *ids = storage.bytes;
    NSMutableArray *values = [NSMutableArray array];
    for (UInt32 i = 0; i < size / sizeof(*ids); i++) [values addObject:@(ids[i])];
    return values;
}
static void emit(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    fwrite(data.bytes, 1, data.length, stdout);
    putchar('\n');
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        AudioObjectPropertyScope global = kAudioObjectPropertyScopeGlobal, output = kAudioObjectPropertyScopeOutput;
        AudioObjectPropertyAddress def = address(kAudioHardwarePropertyDefaultOutputDevice, global);
        if (argc == 3 && !strcmp(argv[1], "set")) {
            AudioObjectID target = (AudioObjectID)strtoul(argv[2], NULL, 10);
            check(AudioObjectSetPropertyData(systemObject, &def, 0, NULL, sizeof(target), &target));
            return 0;
        }
        NSNumber *current = @(scalar(systemObject, def.mSelector, global));
        if (argc == 2 && !strcmp(argv[1], "list")) {
            NSMutableArray *devices = [NSMutableArray array];
            for (NSNumber *num in objects(systemObject, kAudioHardwarePropertyDevices, global)) {
                AudioObjectID device = num.unsignedIntValue;
                if (!objects(device, kAudioDevicePropertyStreams, output).count) continue;
                UInt32 type = scalar(device, kAudioDevicePropertyTransportType, global);
                char fourcc[] = {type >> 24, type >> 16, type >> 8, type, 0};
                CFStringRef name = NULL;
                UInt32 size = sizeof(name);
                AudioObjectPropertyAddress a = address(kAudioObjectPropertyName, global);
                check(AudioObjectGetPropertyData(device, &a, 0, NULL, &size, &name));
                [devices addObject:@{@"id":num, @"name":CFBridgingRelease(name), @"transport":@(fourcc),
                    @"canBeDefault":@(scalar(device,kAudioDevicePropertyDeviceCanBeDefaultDevice,output))}];
            }
            emit(@{@"default":current, @"devices":devices});
        } else if (argc == 3 && !strcmp(argv[1], "process")) {
            pid_t pid = (pid_t)strtol(argv[2], NULL, 10);
            AudioObjectID process = 0;
            UInt32 size = sizeof(process);
            AudioObjectPropertyAddress a = address(kAudioHardwarePropertyTranslatePIDToProcessObject, global);
            check(AudioObjectGetPropertyData(systemObject, &a, sizeof(pid), &pid, &size, &process));
            emit(@{@"default":current, @"process":@(process),
                @"runningOutput":@(process && scalar(process,kAudioProcessPropertyIsRunningOutput,global)),
                @"outputDevices":process ? objects(process,kAudioProcessPropertyDevices,output) : @[]});
        } else {
            fprintf(stderr, "usage: probe list | process PID | set OUTPUT_ID\n");
            return 2;
        }
    }
}
