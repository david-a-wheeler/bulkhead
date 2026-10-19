/* Stand-in for Apple's header; see ../README.md. */
#ifndef STUB_COREFOUNDATION_H
#define STUB_COREFOUNDATION_H

typedef struct __CFRunLoop *CFRunLoopRef;
typedef struct __CFRunLoopSource *CFRunLoopSourceRef;
typedef const struct __CFString *CFStringRef;
typedef CFStringRef CFRunLoopMode;

extern const CFRunLoopMode kCFRunLoopDefaultMode;

CFRunLoopRef CFRunLoopGetCurrent(void);
void CFRunLoopAddSource(CFRunLoopRef rl, CFRunLoopSourceRef source,
                        CFRunLoopMode mode);
void CFRunLoopRun(void);

#endif
