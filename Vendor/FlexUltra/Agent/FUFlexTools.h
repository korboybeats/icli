#import <Foundation/Foundation.h>

NSDictionary *FUHandleBookmarksList(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleBookmarksAdd(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleBookmarksRemove(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleNetworkTransactions(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleLogMessages(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleGlobalsEntries(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleGlobalsOpen(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleGlobalsInvoke(NSString *requestID, NSDictionary *request);
