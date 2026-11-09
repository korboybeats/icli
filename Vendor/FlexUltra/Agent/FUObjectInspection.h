#import <Foundation/Foundation.h>

NSArray *FUClassHierarchyNames(id explorer);
NSMutableDictionary *FUPropertyEntry(id property, id target, NSString *declaringClass, BOOL includeValue);
NSMutableDictionary *FUIvarEntry(id ivar, id target, NSString *declaringClass, BOOL includeValue);
NSMutableDictionary *FUMethodEntry(id method, NSString *declaringClass);
NSArray *FUPropertyMetadata(id explorer, id target, BOOL includeValues, NSUInteger offset, NSUInteger limit, NSString *query, NSUInteger *total);
NSArray *FUIvarMetadata(id explorer, id target, BOOL includeValues, NSUInteger offset, NSUInteger limit, NSString *query, NSUInteger *total);
NSArray *FUMethodMetadata(id explorer, NSString *groupsSelector, NSUInteger offset, NSUInteger limit, NSString *query, NSUInteger *total);
id FUObjectExplorerForObject(id object);
id FUObjectTargetFromRequest(NSString *requestID, NSDictionary *request, NSString **resolvedHandle, NSString **targetSource, NSString **resolvedBy, NSDictionary **errorResponse);

NSDictionary *FUHandleObjectList(NSString *requestID, NSDictionary *request, NSString *kind);
NSDictionary *FUHandleObjectCall(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleObjectPin(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleObjectUnpin(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleObjectGetSet(NSString *requestID, NSDictionary *request, BOOL setValue);
NSDictionary *FUHandleObjectInspect(NSString *requestID, NSDictionary *request);
