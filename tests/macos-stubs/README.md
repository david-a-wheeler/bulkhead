# Stand-ins for Apple's headers

These declare only what `infer-watch.c` uses, so `test_infer_watch.sh`
can compile and check it on Linux. I wrote the signatures to match
Apple's, but I haven't checked them against the macOS SDK; the real
check is `host-setup.sh` building it on the Mac against Apple's own
headers. `stubs.c` implements them: its `CFRunLoopRun` sends a
fixed sequence of power events and then returns. If `infer-watch.c`
starts using more of Apple's API, declare it here with Apple's exact
signature.
