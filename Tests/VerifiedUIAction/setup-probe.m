// Device-only check that production AX setup preserves a host's native client
// context. This does not enable switches, query another app, or dispatch input.
#import "../../Sources/IcliPrivate/Accessibility.m"

IcliScreenMetrics icli_screen_metrics(void) { return (IcliScreenMetrics){430, 932, 3, 0}; }
void icli_screen_fixed_to_point(double x, double y, double *px, double *py) { *px=x; *py=y; }
void icli_screen_point_to_fixed(double x, double y, double *px, double *py) { *px=x; *py=y; }
void icli_as_mobile_user(void (^body)(void)) { body(); }

int main(void) {
    @autoreleasepool {
        void *ax = dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_NOW);
        uint64_t (*incoming)(void) = ax ? dlsym(ax, "AXRequestingClient") : NULL;
        void (*setIncoming)(uint64_t) = ax ? dlsym(ax, "_AXSetRequestingClient") : NULL;
        uint64_t (*outgoing)(uint64_t) = ax ? dlsym(ax, "AXOverrideRequestingClientType") : NULL;
        if (!incoming || !setIncoming || !outgoing) return 67;
        uint64_t previousIncoming = incoming(), previousOutgoing = outgoing(10);
        setIncoming(10);
        BOOL ready = prepareAX();
        // The native override function returns its prior value. Restore both
        // process-local contexts before checking the recorded values.
        uint64_t current = incoming(), requested = outgoing(previousOutgoing);
        setIncoming(previousIncoming);
        printf("{\"expected_client\":10,\"incoming_client\":%llu,\"outgoing_client\":%llu}\n",
               (unsigned long long)current, (unsigned long long)requested);
        return ready && current == 10 && requested == 10 ? 0 : 68;
    }
}
