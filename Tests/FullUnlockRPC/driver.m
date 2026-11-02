// Integrate the production engine against an owned macOS fixture process,
// never SpringBoard. No device passcode or device attempts are involved.
#import "../../Sources/IcliPrivate/FullUnlock.m"
bool icli_wake(void) { return true; }
IcliLockStatus icli_lock_status(void) { return (IcliLockStatus){0}; }
int main(int argc, char **argv) {
    @autoreleasepool {
        FullUnlock session = {0};
        if (task_for_pid(mach_task_self(), atoi(argv[1]), &session.task)) {
            puts("FAIL cannot obtain fixture task port"); return 1;
        }
        if (mach_port_mod_refs(mach_task_self(), session.task, MACH_PORT_RIGHT_SEND, 1)) {
            puts("FAIL cannot retain fixture task port"); return 1;
        }
        bool ok = prepareContext(&session, false);
        if (ok) ok = invokeUnlock(&session, (const uint8_t *)"fixture-passcode", strlen("fixture-passcode"));
        if (!ok) { printf("FAIL before cleanup: %s\n", session.error); fflush(stdout); }
        cleanup(&session);
        uint8_t byte;
        if (ok && readTask(&session, session.region + DATA_OFFSET, &byte, 1)) {
            puts("FAIL request region remained readable after cleanup"); return 1;
        }
        mach_port_deallocate(mach_task_self(), session.task);
        printf("%s %s\n", ok && !session.error[0] ? "PASS" : "FAIL", session.error);
        return ok && !session.error[0] ? 0 : 1;
    }
}
