#import "ICLIFlexLog.h"
#include <stdarg.h>
#include <stdio.h>
void ICLIFlexFileLog(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/icli-flex_debug.log"];
    FILE *file = fopen(path.fileSystemRepresentation, "a");
    if (file) { fprintf(file, "%s\n", line.UTF8String); fclose(file); }
}
