#import "ICLIFlexHost.h"
#import "ICLIFlexBuild.h"
static ICLIFlexTransport currentTransport;
void ICLIFlexSetTransport(ICLIFlexTransport callback) { currentTransport = callback; }
const char *icli_flex_build_id(void) { return ICLI_FULL_FLEX_BUILD; }
int32_t icli_flex_receive_timeout(const char *operation) { return (int32_t)IcliFUReceiveTimeoutSecondsForOperation(@(operation)); }
char *icli_flex_catalog_json(void) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:IcliFUOperationCatalog() options:0 error:nil];
    return strdup([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}
NSDictionary *ICLIFlexHostRequest(NSDictionary *request) {
    if (!currentTransport) return IcliFUResponse(request[@"id"] ?: @"", NO, nil, IcliFUErrorInfo(@"transport_unavailable", @"No icli request transport is installed."));
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    char *answer = currentTransport([[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding].UTF8String);
    NSDictionary *reply = nil;
    if (answer) {
        reply = [NSJSONSerialization JSONObjectWithData:[@(answer) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        free(answer);
    }
    return reply ?: IcliFUResponse(request[@"id"] ?: @"", NO, nil, IcliFUErrorInfo(@"invalid_response", @"The icli transport did not return JSON."));
}

char *icli_flex_error_json(const char *identifier, const char *code, const char *message, const char *operation) {
    NSDictionary *error = IcliFUEnrichErrorInfo(IcliFUErrorInfo(@(code), @(message)), @(operation));
    NSDictionary *reply = IcliFUResponse(@(identifier), NO, nil, error);
    NSData *data = [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
    return strdup([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}
