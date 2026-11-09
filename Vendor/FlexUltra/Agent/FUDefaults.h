#import <Foundation/Foundation.h>

void FURecordDefaultsOwnership(NSString *key, BOOL owned);

NSDictionary *FUHandleDefaultsEntries(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleDefaultsGet(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleDefaultsSet(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleDefaultsRemove(NSString *requestID, NSDictionary *request);
