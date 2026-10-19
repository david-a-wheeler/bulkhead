/* Implementations of the stand-ins (see README.md), for running
 * infer-watch.c on Linux. CFRunLoopRun sends a power-source change,
 * idle sleep, forced sleep, and a wake, then returns. IOAllowPowerChange
 * prints the notification ID it gets, so the test can check that each
 * sleep was allowed. */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOMessage.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <stdio.h>
#include <stdlib.h>

struct __CFRunLoop {
  int unused;
};
struct __CFRunLoopSource {
  int unused;
};
struct __CFString {
  int unused;
};
struct IONotificationPort {
  int unused;
};

static struct __CFRunLoop loop;
static struct __CFRunLoopSource port_source, power_source;
static const struct __CFString default_mode;
static struct IONotificationPort notification_port;
const CFRunLoopMode kCFRunLoopDefaultMode = &default_mode;

static IOServiceInterestCallback system_callback;
static void *system_refcon;
static IOPowerSourceCallbackType power_callback;
static void *power_context;
static int sources_added;

/* CFRunLoopGetCurrent: return the one fake run loop. */
CFRunLoopRef CFRunLoopGetCurrent(void) { return &loop; }

/* CFRunLoopAddSource: check that it's one of our sources, and count it. */
void CFRunLoopAddSource(CFRunLoopRef rl, CFRunLoopSourceRef source,
                        CFRunLoopMode mode) {
  if (rl != &loop || mode != kCFRunLoopDefaultMode ||
      (source != &port_source && source != &power_source)) {
    (void) fprintf(stderr, "stubs: bad CFRunLoopAddSource\n");
    exit(3);
  }
  sources_added++;
}

/* CFRunLoopRun: send the fixed sequence of power events, then return. */
void CFRunLoopRun(void) {
  if (sources_added != 2 || system_callback == NULL || power_callback == NULL) {
    (void) fprintf(stderr, "stubs: CFRunLoopRun before setup\n");
    exit(3);
  }
  power_callback(power_context);
  system_callback(system_refcon, 1, kIOMessageCanSystemSleep, (void *) 11);
  system_callback(system_refcon, 1, kIOMessageSystemWillSleep, (void *) 12);
  system_callback(system_refcon, 1, kIOMessageSystemHasPoweredOn, NULL);
  (void) fflush(stdout);
}

/* IONotificationPortGetRunLoopSource: return the fake port's source. */
CFRunLoopSourceRef IONotificationPortGetRunLoopSource(IONotificationPortRef notify) {
  return notify == &notification_port ? &port_source : NULL;
}

/* IORegisterForSystemPower: record the callback for CFRunLoopRun. */
io_connect_t IORegisterForSystemPower(void *refcon,
                                      IONotificationPortRef *thePortRef,
                                      IOServiceInterestCallback callback,
                                      io_object_t *notifier) {
  system_refcon = refcon;
  system_callback = callback;
  *thePortRef = &notification_port;
  *notifier = 7;
  return 5;
}

/* IOAllowPowerChange: print what it was called with, for the test. */
IOReturn IOAllowPowerChange(io_connect_t kernelPort, intptr_t notificationID) {
  printf("allowed %u %ld\n", kernelPort, (long) notificationID);
  (void) fflush(stdout);
  return kIOReturnSuccess;
}

/* IOPSNotificationCreateRunLoopSource: record the callback for
 * CFRunLoopRun. */
CFRunLoopSourceRef IOPSNotificationCreateRunLoopSource(
    IOPowerSourceCallbackType callback, void *context) {
  power_callback = callback;
  power_context = context;
  return &power_source;
}
