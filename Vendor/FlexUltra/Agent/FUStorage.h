#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NSDictionary * _Nonnull (*FUStorageFlexStatusProvider)(BOOL loadIfNeeded);
typedef id _Nullable (*FUStorageJSONValueProvider)(id _Nullable value);

void FUStorageConfigure(FUStorageFlexStatusProvider flexStatusProvider, FUStorageJSONValueProvider jsonValueProvider);

NSDictionary *FUHandleSQLiteTables(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleSQLiteColumns(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleSQLiteRows(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleRealmTables(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleRealmColumns(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleRealmRows(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleFilesystemList(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleFilesystemStat(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleFilesystemRead(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleFilesystemSearch(NSString *requestID, NSDictionary *request);

NS_ASSUME_NONNULL_END
