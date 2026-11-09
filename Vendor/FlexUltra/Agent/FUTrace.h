#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSDictionary *FUHandleTraceStart(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleTraceStatus(NSString *requestID);
NSDictionary *FUHandleTraceEvents(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleTraceStop(NSString *requestID);

// Read-only status used by target.health without exposing trace state or locks.
NSDictionary *FUTraceStatusSnapshot(void);

NS_ASSUME_NONNULL_END
