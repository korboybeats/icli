#import <Foundation/Foundation.h>

typedef NSDictionary *(*FURuntimeObjectReferenceProvider)(id object);
typedef NSMutableDictionary *(*FURuntimePropertyEntryProvider)(id property, id target, NSString *declaringClass, BOOL includeValue);
typedef NSMutableDictionary *(*FURuntimeIvarEntryProvider)(id ivar, id target, NSString *declaringClass, BOOL includeValue);
typedef NSMutableDictionary *(*FURuntimeMethodEntryProvider)(id method, NSString *declaringClass);

void FURuntimeConfigure(
    FURuntimeObjectReferenceProvider objectReferenceProvider,
    FURuntimePropertyEntryProvider propertyEntryProvider,
    FURuntimeIvarEntryProvider ivarEntryProvider,
    FURuntimeMethodEntryProvider methodEntryProvider
);

NSDictionary *FUFlexStatus(BOOL loadIfNeeded);
NSDictionary<NSString *, NSDictionary *> *FUOperationSupport(BOOL loadIfNeeded);
id FUFlexManager(void);
id FURuntimeClientInstance(NSString *requestID, NSDictionary **errorResponse);
NSDictionary *FUHandleFlexVisibility(NSString *requestID, BOOL show);
NSDictionary *FURuntimeClasses(NSString *requestID, NSDictionary *request);
NSDictionary *FURuntimeClass(NSString *requestID, NSDictionary *request);
NSDictionary *FURuntimeClassProtocols(NSString *requestID, NSDictionary *request);
NSDictionary *FURuntimeImages(NSString *requestID, NSDictionary *request);
NSDictionary *FURuntimeImageClasses(NSString *requestID, NSDictionary *request);
NSDictionary *FURuntimeProtocols(NSString *requestID, NSDictionary *request);
NSDictionary *FURuntimeProtocolClasses(NSString *requestID, NSDictionary *request);
NSDictionary *FURuntimeProtocol(NSString *requestID, NSDictionary *request);
NSDictionary *FURuntimeMethods(NSString *requestID, NSDictionary *request);
NSDictionary *FURuntimeProperties(NSString *requestID, NSDictionary *request);
NSDictionary *FURuntimeIvars(NSString *requestID, NSDictionary *request);
