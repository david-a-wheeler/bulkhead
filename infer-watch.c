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
 * to keep it from delaying the sleep hook. A hook that runs too long
 * is killed, along with everything it started.
 *
 * It waits STARTUP_SECONDS before doing anything, so if it misbehaves
 * you have time to stop it (with launchctl bootout, since launchd
 * restarts it if it's only killed). Each restart waits again.
 *
 * tests/test_infer_watch.sh compiles this on Linux against stand-ins
 * for Apple's headers, to check it with gcc's warnings and analyzer and
 * run it under sanitizers.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOMessage.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>

/* The tests set shorter ones. */
#ifndef SLEEP_SECONDS
#define SLEEP_SECONDS 25
#endif
#ifndef OTHER_SECONDS
#define OTHER_SECONDS 10
#endif
#ifndef STARTUP_SECONDS
#define STARTUP_SECONDS 120
#endif

extern char **environ;

/* Writable, since posix_spawn's argv isn't const. */
static char sleep_event[] = "sleep";
static char wake_event[] = "wake";
static char power_event[] = "power";

static char *hook;
static io_connect_t root_port = MACH_PORT_NULL;

/* log_line: log a timestamped line, in the same format as the hook's. */
static void log_line(const char *format, ...)
    __attribute__((format(printf, 1, 2)));
static void log_line(const char *format, ...) {
  char stamp[32] = "";
  time_t now = time(NULL);
  struct tm local;
  va_list args;

  if (localtime_r(&now, &local) != NULL)
    (void) strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", &local);
  (void) fprintf(stderr, "%s infer-watch: ", stamp);
  va_start(args, format);
  (void) vfprintf(stderr, format, args);
  va_end(args);
  (void) fputc('\n', stderr);
}

/* seconds_since: seconds elapsed since START, on the monotonic clock. */
static double seconds_since(const struct timespec *start) {
  struct timespec now;

  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
    return 0;
  return (double) (now.tv_sec - start->tv_sec) +
         (double) (now.tv_nsec - start->tv_nsec) / 1e9;
}

/* waitpid_retry: waitpid, retried if a signal interrupts it. */
static pid_t waitpid_retry(pid_t pid, int *status, int options) {
  pid_t result;

  do {
    result = waitpid(pid, status, options);
  } while (result < 0 && errno == EINTR);
  return result;
}

/* run_hook: run "HOOK EVENT" in its own process group, waiting at most
 * SECONDS; then kill the group. */
static void run_hook(char *event, int seconds) {
  char *argv[] = {hook, event, NULL};
  const struct timespec tenth = {0, 100000000L};
  struct timespec start;
  posix_spawnattr_t attr;
  pid_t pid, result;
  int status = 0, err;

  err = posix_spawnattr_init(&attr);
  if (err != 0) {
    log_line("posix_spawnattr_init failed: %s", strerror(err));
    return;
  }
  err = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
  if (err == 0)
    err = posix_spawnattr_setpgroup(&attr, 0);
  if (err == 0)
    err = posix_spawn(&pid, hook, NULL, &attr, argv, environ);
  (void) posix_spawnattr_destroy(&attr);
  if (err != 0) {
    log_line("can't run %s %s: %s", hook, event, strerror(err));
    return;
  }
  if (clock_gettime(CLOCK_MONOTONIC, &start) != 0) {
    log_line("clock_gettime failed: %s", strerror(errno));
    start.tv_sec = 0;
    start.tv_nsec = 0;
  }
  for (;;) {
    result = waitpid_retry(pid, &status, WNOHANG);
    if (result == pid) {
      if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
        log_line("%s %s failed", hook, event);
      return;
    }
    if (result < 0) {
      log_line("waitpid failed: %s", strerror(errno));
      return;
    }
    if (seconds_since(&start) >= seconds)
      break;
    (void) nanosleep(&tenth, NULL);
  }
  log_line("%s %s took over %d seconds; stopped it", hook, event, seconds);
  /* PID hasn't been reaped, so its process group still exists. */
  if (kill(-pid, SIGKILL) != 0)
    log_line("kill failed: %s", strerror(errno));
  if (waitpid_retry(pid, &status, 0) < 0)
    log_line("waitpid failed: %s", strerror(errno));
}

/* allow_power_change: tell macOS it may go ahead with ARGUMENT's
 * sleep. */
static void allow_power_change(void *argument) {
  IOReturn result = IOAllowPowerChange(root_port, (intptr_t) argument);

  if (result != kIOReturnSuccess)
    log_line("IOAllowPowerChange failed: 0x%x", (unsigned) result);
}

/* on_sleep_or_wake: handle macOS's sleep and wake notifications. */
static void on_sleep_or_wake(void *refcon, io_service_t service,
                             uint32_t message, void *argument) {
  (void) refcon; /* Unused */
  (void) service; /* Unused */
  switch (message) {
  case kIOMessageCanSystemSleep:
    /* Idle sleep: allow it. kIOMessageSystemWillSleep follows. */
    allow_power_change(argument);
    break;
  case kIOMessageSystemWillSleep:
    run_hook(sleep_event, SLEEP_SECONDS);
    allow_power_change(argument);
    break;
  case kIOMessageSystemHasPoweredOn:
    run_hook(wake_event, OTHER_SECONDS);
    break;
  default:
    break;
  }
}

/* on_power_source_change: handle a power source change. */
static void on_power_source_change(void *context) {
  (void) context; /* Unused */
  run_hook(power_event, OTHER_SECONDS);
}

/* pause_for: wait SECONDS, even if signals interrupt. */
static void pause_for(int seconds) {
  struct timespec left = {seconds, 0};

  while (nanosleep(&left, &left) != 0 && errno == EINTR)
    continue;
}

/* main: wait STARTUP_SECONDS, register for power events, then handle
 * them until the run loop stops (it shouldn't). */
int main(int argc, char **argv) {
  IONotificationPortRef sleep_wake_port = NULL;
  io_object_t notifier = MACH_PORT_NULL;
  CFRunLoopSourceRef power_source_changes;

  if (argc != 2 || argv[1][0] != '/') {
    (void) fprintf(stderr, "Usage: infer-watch /ABSOLUTE/PATH/TO/HOOK\n");
    return 2;
  }
  hook = argv[1];
  log_line("waiting %d seconds before starting", STARTUP_SECONDS);
  pause_for(STARTUP_SECONDS);
  root_port = IORegisterForSystemPower(NULL, &sleep_wake_port,
                                       on_sleep_or_wake, &notifier);
  if (root_port == MACH_PORT_NULL || sleep_wake_port == NULL) {
    log_line("IORegisterForSystemPower failed");
    return 1;
  }
  CFRunLoopAddSource(CFRunLoopGetCurrent(),
                     IONotificationPortGetRunLoopSource(sleep_wake_port),
                     kCFRunLoopDefaultMode);
  power_source_changes =
      IOPSNotificationCreateRunLoopSource(on_power_source_change, NULL);
  if (power_source_changes == NULL) {
    log_line("IOPSNotificationCreateRunLoopSource failed");
    return 1;
  }
  CFRunLoopAddSource(CFRunLoopGetCurrent(), power_source_changes,
                     kCFRunLoopDefaultMode);
  log_line("watching for sleep, wake, and power changes");
  run_hook(power_event, OTHER_SECONDS);
  CFRunLoopRun();
  log_line("the run loop stopped");
  return 1;
}
