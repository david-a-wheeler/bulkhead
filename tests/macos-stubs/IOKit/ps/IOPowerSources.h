/* Stand-in for Apple's header; see ../../README.md. */
#ifndef STUB_IOPOWERSOURCES_H
#define STUB_IOPOWERSOURCES_H

#include <IOKit/IOKitLib.h>

typedef void (*IOPowerSourceCallbackType)(void *context);

CFRunLoopSourceRef IOPSNotificationCreateRunLoopSource(
    IOPowerSourceCallbackType callback, void *context);

#endif
