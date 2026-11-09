#import <Foundation/Foundation.h>

NSString *FUCurrentObjectGeneration(void);
NSString *FUObjectGenerationFromHandle(NSString *handle);
BOOL FUObjectHandleIsStale(NSString *handle);
NSDictionary *FUObjectHandleErrorInfo(NSString *handle, NSString *notFoundMessage);
void FUObjectHandleErrorParts(NSString *handle,
                              NSString *notFoundMessage,
                              NSString **errorCode,
                              NSString **errorMessage);

NSString *FURegisterObject(id object);
id FUObjectForHandle(NSString *handle);
NSString *FUPinObject(id object);
BOOL FUUnpinObjectHandle(NSString *handle);
