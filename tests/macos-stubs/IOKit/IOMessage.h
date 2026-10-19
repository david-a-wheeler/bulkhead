/* Stand-in for Apple's header; see ../README.md. */
#ifndef STUB_IOMESSAGE_H
#define STUB_IOMESSAGE_H

#include <stdint.h>

/* sys_iokit | sub_iokit_common | message, as in Apple's IOMessage.h. */
#define iokit_common_msg(message) ((uint32_t)(0xe0000000u | (message)))
#define kIOMessageCanSystemSleep iokit_common_msg(0x270)
#define kIOMessageSystemWillSleep iokit_common_msg(0x280)
#define kIOMessageSystemHasPoweredOn iokit_common_msg(0x300)

#endif
