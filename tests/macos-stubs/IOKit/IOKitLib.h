/* Stand-in for Apple's header; see ../README.md. */
#ifndef STUB_IOKITLIB_H
#define STUB_IOKITLIB_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

typedef unsigned int natural_t;
typedef natural_t mach_port_t;
#define MACH_PORT_NULL ((mach_port_t)0)
typedef int kern_return_t;
typedef kern_return_t IOReturn;
#define kIOReturnSuccess 0
typedef mach_port_t io_object_t;
typedef io_object_t io_service_t;
typedef io_object_t io_connect_t;
typedef struct IONotificationPort *IONotificationPortRef;
typedef void (*IOServiceInterestCallback)(void *refcon, io_service_t service,
                                          uint32_t messageType,
                                          void *messageArgument);

CFRunLoopSourceRef IONotificationPortGetRunLoopSource(IONotificationPortRef notify);

#endif
