/* Stand-in for Apple's header; see ../../README.md. */
#ifndef STUB_IOPMLIB_H
#define STUB_IOPMLIB_H

#include <IOKit/IOKitLib.h>

io_connect_t IORegisterForSystemPower(void *refcon,
                                      IONotificationPortRef *thePortRef,
                                      IOServiceInterestCallback callback,
                                      io_object_t *notifier);
IOReturn IOAllowPowerChange(io_connect_t kernelPort, intptr_t notificationID);

#endif
