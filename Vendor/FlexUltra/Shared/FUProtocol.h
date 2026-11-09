#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const NSUInteger FUProtocolVersion;
FOUNDATION_EXPORT const uint16_t FUDaemonPort;
FOUNDATION_EXPORT NSString *const FUProtocolErrorDomain;

typedef NS_OPTIONS(NSUInteger, FUOperationFlags) {
    FUOperationFlagNone = 0,
    FUOperationFlagAgentCapability = 1 << 0,
    FUOperationFlagHeapWorker = 1 << 1,
    FUOperationFlagLongTimeout = 1 << 2,
    FUOperationFlagMCPStateChanging = 1 << 3,
    FUOperationFlagMCPDestructive = 1 << 4,
    FUOperationFlagMCPIdempotent = 1 << 5,
    FUOperationFlagMCPOpenWorld = 1 << 6,
    FUOperationFlagDaemonLocal = 1 << 7,
};

NSArray<NSDictionary<NSString *, id> *> *FUOperationCatalog(void);
NSArray<NSString *> *FUAgentCapabilities(void);
NSString * _Nullable FUOperationForMCPTool(NSString *toolName);
NSDictionary<NSString *, NSNumber *> * _Nullable FUMCPToolAnnotations(NSString *toolName);
BOOL FUOperationUsesHeapWorker(NSString *operation);
BOOL FUOperationIsDaemonLocal(NSString *operation);
NSInteger FUReceiveTimeoutSecondsForOperation(NSString *operation);

NSDictionary * _Nullable FUReadJSONLine(int fd, NSError **error);
BOOL FUWriteJSONLine(int fd, NSDictionary *object, NSError **error);

NSDictionary *FUResponse(NSString *requestID, BOOL ok, id _Nullable result, NSDictionary * _Nullable errorInfo);
NSDictionary *FUErrorInfo(NSString *code, NSString *message);
NSDictionary *FUEnrichErrorInfo(NSDictionary * _Nullable errorInfo, NSString * _Nullable operation);

NS_ASSUME_NONNULL_END
