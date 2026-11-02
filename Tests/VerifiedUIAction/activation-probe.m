// Device-only research driver. Restricts all actions to the owned TestHost.
#import "../../Sources/IcliPrivate/Accessibility.m"

IcliScreenMetrics icli_screen_metrics(void) { return (IcliScreenMetrics){430, 932, 3, 0}; }
void icli_screen_fixed_to_point(double x, double y, double *px, double *py) { *px=x; *py=y; }
void icli_screen_point_to_fixed(double x, double y, double *px, double *py) { *px=x; *py=y; }

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3 && argc != 4) return 64;
        int pid = atoi(argv[1]);
        char path[4096] = {0};
        if (proc_pidpath(pid, path, sizeof(path)) <= 0
            || !strstr(path, "/IcliTestHost.app/IcliTestHost")) return 65;
        if (!prepareAX()) return 66;
        enableSwitches();
        AXElement root = createApp(pid);
        CFTypeRef raw = NULL;
        int query = copyAttribute(root, (CFStringRef)(uintptr_t)3015, &raw);
        CFRelease(root);
        if (query || !raw || CFGetTypeID(raw) != CFArrayGetTypeID()) return 67;
        NSArray *rows = CFBridgingRelease(raw);
        id chosen = nil;
        for (id element in rows) {
            if ([attribute((__bridge AXElement)element, 5019) isEqual:@(argv[2])]) {
                if (chosen) return 68;
                chosen = element;
            }
        }
        if (!chosen) return 69;
        AXElement target = (__bridge AXElement)chosen;
        id capable = attribute(target, 2019);
        int (*activate)(AXElement, uint32_t) = dlsym(RTLD_DEFAULT, "AXUIElementPerformAction");
        if (!activate) return 70;
        if (argc == 4) {
            puts("{\"phase\":\"resolved\"}"); fflush(stdout);
            if (getchar() != '1') return 71;
        }
        // 2010 traced in iOS 17.1.1 AXElement._performActivate. Deliberately
        // avoid AXElement.press, which contains a coordinate-event fallback.
        int result = activate(target, 2010);
        NSDictionary *report = @{@"pid":@(pid), @"identifier":@(argv[2]), @"action":@2010,
                                  @"capable":capable ?: NSNull.null, @"ax_error":@(result)};
        NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        fwrite(data.bytes,1,data.length,stdout); putchar('\n');
        return 0;
    }
}
