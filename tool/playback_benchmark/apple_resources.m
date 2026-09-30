// Test-only self-process sampling. Never linked into a production player package.
#import <Foundation/Foundation.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#include <libproc.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

__attribute__((visibility("default"))) const char *yl_resource_snapshot(void) {
  static _Thread_local char result[1024];
  @autoreleasepool {
    struct timespec clock;
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &clock) != 0) return NULL;
    uint64_t timeUs = (uint64_t)clock.tv_sec * 1000000 + clock.tv_nsec / 1000;
    struct rusage cpu = {0};
    struct rusage_info_v4 memory = {0};
    BOOL ok = getrusage(RUSAGE_SELF, &cpu) == 0 &&
      proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&memory) == 0;
    NSString *thermal = @"unknown";
    switch (NSProcessInfo.processInfo.thermalState) {
      case NSProcessInfoThermalStateNominal: thermal = @"nominal"; break;
      case NSProcessInfoThermalStateFair: thermal = @"fair"; break;
      case NSProcessInfoThermalStateSerious: thermal = @"serious"; break;
      case NSProcessInfoThermalStateCritical: thermal = @"critical"; break;
      default: break;
    }
    NSString *power = @"unknown";
    CFTypeRef snapshot = IOPSCopyPowerSourcesInfo();
    if (snapshot) {
      CFStringRef type = IOPSGetProvidingPowerSourceType(snapshot);
      if (type && CFEqual(type, CFSTR(kIOPSACPowerValue))) power = @"ac";
      else if (type && CFEqual(type, CFSTR(kIOPSBatteryPowerValue))) power = @"battery";
      CFRelease(snapshot);
    }
    uint64_t cpuUs = ((uint64_t)cpu.ru_utime.tv_sec + cpu.ru_stime.tv_sec) * 1000000 +
      cpu.ru_utime.tv_usec + cpu.ru_stime.tv_usec;
    NSDictionary *row = @{@"monotonicUs": @(timeUs), @"status": ok ? @"ok" : @"unavailable",
      @"cpuUs": ok ? @(cpuUs) : NSNull.null,
      @"rssBytes": ok ? @(memory.ri_resident_size) : NSNull.null,
      @"footprintBytes": ok ? @(memory.ri_phys_footprint) : NSNull.null,
      @"thermal": thermal, @"power": power};
    NSData *data = [NSJSONSerialization dataWithJSONObject:row options:0 error:nil];
    if (!data || data.length >= sizeof(result)) return NULL;
    memcpy(result, data.bytes, data.length); result[data.length] = 0;
    return result; // Thread-local borrowed bytes, copied before the next call.
  }
}
