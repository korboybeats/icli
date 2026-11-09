#import <Foundation/Foundation.h>

typedef NSDictionary *(*FUHeapFlexStatusProvider)(BOOL loadIfNeeded);
typedef NSDictionary *(*FUHeapObjectReferenceProvider)(id object);
typedef id (*FUHeapObjectTargetProvider)(NSString *requestID, NSDictionary *request, NSString **resolvedHandle, NSString **targetSource, NSString **resolvedBy, NSDictionary **errorResponse);

void FUHeapConfigure(FUHeapFlexStatusProvider flexStatusProvider,
                     FUHeapObjectReferenceProvider objectReferenceProvider,
                     FUHeapObjectTargetProvider objectTargetProvider);

NSDictionary *FUHandleHeapSnapshot(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleHeapInstances(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleHeapSubclasses(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleHeapReferences(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleHeapReferenceGraph(NSString *requestID, NSDictionary *request);
