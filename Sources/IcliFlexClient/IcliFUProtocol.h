// Adapted by icli: namespaced symbols and private on-demand transport.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const NSUInteger IcliFUProtocolVersion;
FOUNDATION_EXPORT const uint16_t IcliFUDaemonPort;
FOUNDATION_EXPORT NSString *const IcliFUProtocolErrorDomain;

typedef NS_OPTIONS(NSUInteger, IcliFUOperationFlags) {
    IcliFUOperationFlagNone = 0,
    IcliFUOperationFlagAgentCapability = 1 << 0,
    IcliFUOperationFlagHeapWorker = 1 << 1,
    IcliFUOperationFlagLongTimeout = 1 << 2,
    IcliFUOperationFlagMCPStateChanging = 1 << 3,
    IcliFUOperationFlagMCPDestructive = 1 << 4,
    IcliFUOperationFlagMCPIdempotent = 1 << 5,
    IcliFUOperationFlagMCPOpenWorld = 1 << 6,
    IcliFUOperationFlagDaemonLocal = 1 << 7,
};

NSArray<NSDictionary<NSString *, id> *> *IcliFUOperationCatalog(void);
NSArray<NSString *> *IcliFUAgentCapabilities(void);
NSString * _Nullable IcliFUOperationForMCPTool(NSString *toolName);
NSDictionary<NSString *, NSNumber *> * _Nullable IcliFUMCPToolAnnotations(NSString *toolName);
BOOL IcliFUOperationUsesHeapWorker(NSString *operation);
BOOL IcliFUOperationIsDaemonLocal(NSString *operation);
NSInteger IcliFUReceiveTimeoutSecondsForOperation(NSString *operation);

NSDictionary * _Nullable IcliFUReadJSONLine(int fd, NSError **error);
BOOL IcliFUWriteJSONLine(int fd, NSDictionary *object, NSError **error);

NSDictionary *IcliFUResponse(NSString *requestID, BOOL ok, id _Nullable result, NSDictionary * _Nullable errorInfo);
NSDictionary *IcliFUErrorInfo(NSString *code, NSString *message);
NSDictionary *IcliFUEnrichErrorInfo(NSDictionary * _Nullable errorInfo, NSString * _Nullable operation);

NS_ASSUME_NONNULL_END
