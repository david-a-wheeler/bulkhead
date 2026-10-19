/*
 * infer-watch: run a hook before the Mac sleeps, after it wakes, and
 * whenever a power source changes, for the local AI engine (see
 * local-ai-plan.md, "Kill on sleep" and "Power and cooling"). It runs
 * as you, as a launchd agent that host-setup.sh builds and installs;
 * none of this needs root.
 *
 * Usage: infer-watch HOOK
 *
 * Before sleep it runs "HOOK sleep", and only lets the Mac sleep once
 * that's done, so the hook can unload the model before its memory goes
 * into the sleep image. macOS waits about 30 seconds for that, so the
 * hook gets at most SLEEP_SECONDS. After waking it runs "HOOK wake", and
 * when a power source changes (e.g., the battery level, or plugging
 * in), "HOOK power". It also runs "HOOK power" once at startup.
 *
 * Hooks run one at a time, so each other kind gets only OTHER_SECONDS,
 * to keep it from delaying the sleep hook.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOMessage.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define SLEEP_SECONDS 25
#define OTHER_SECONDS 10

extern char **environ;
static char *hook;
static io_connect_t root_port;

/* run_hook: run "HOOK EVENT", waiting at most SECONDS; then kill it
 * and everything it started. */
static void run_hook(const char *event, int seconds) {
  char *argv[] = {hook, (char *)event, NULL};
  posix_spawnattr_t attr;
  pid_t pid;
  int status, err, tenths;

  posix_spawnattr_init(&attr);
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
  posix_spawnattr_setpgroup(&attr, 0);
  err = posix_spawn(&pid, hook, NULL, &attr, argv, environ);
  posix_spawnattr_destroy(&attr);
  if (err != 0) {
    fprintf(stderr, "infer-watch: can't run %s: %s\n", hook, strerror(err));
    return;
  }
  for (tenths = 0; tenths < seconds * 10; tenths++) {
    if (waitpid(pid, &status, WNOHANG) == pid) {
      if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
        fprintf(stderr, "infer-watch: \"%s %s\" failed\n", hook, event);
      return;
    }
    usleep(100000);
  }
  fprintf(stderr, "infer-watch: \"%s %s\" took over %d seconds; stopped it\n",
          hook, event, seconds);
  kill(-pid, SIGKILL);
  while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
    ;
}

static void system_power(void *refcon, io_service_t service,
                         natural_t message, void *argument) {
  (void)refcon;
  (void)service;
  switch (message) {
  case kIOMessageCanSystemSleep:
    /* Idle sleep: allow it. kIOMessageSystemWillSleep follows. */
    IOAllowPowerChange(root_port, (long)argument);
    break;
  case kIOMessageSystemWillSleep:
    run_hook("sleep", SLEEP_SECONDS);
    IOAllowPowerChange(root_port, (long)argument);
    break;
  case kIOMessageSystemHasPoweredOn:
    run_hook("wake", OTHER_SECONDS);
    break;
  }
}

static void power_source(void *context) {
  (void)context;
  run_hook("power", OTHER_SECONDS);
}

int main(int argc, char **argv) {
  IONotificationPortRef port;
  io_object_t notifier;
  CFRunLoopSourceRef sources;

  if (argc != 2) {
    fprintf(stderr, "Usage: infer-watch HOOK\n");
    return 2;
  }
  hook = argv[1];
  root_port = IORegisterForSystemPower(NULL, &port, system_power, &notifier);
  if (root_port == MACH_PORT_NULL) {
    fprintf(stderr, "infer-watch: IORegisterForSystemPower failed\n");
    return 1;
  }
  CFRunLoopAddSource(CFRunLoopGetCurrent(),
                     IONotificationPortGetRunLoopSource(port),
                     kCFRunLoopDefaultMode);
  sources = IOPSNotificationCreateRunLoopSource(power_source, NULL);
  if (sources == NULL) {
    fprintf(stderr, "infer-watch: IOPSNotificationCreateRunLoopSource failed\n");
    return 1;
  }
  CFRunLoopAddSource(CFRunLoopGetCurrent(), sources, kCFRunLoopDefaultMode);
  run_hook("power", OTHER_SECONDS);
  CFRunLoopRun();
  return 1;
}
