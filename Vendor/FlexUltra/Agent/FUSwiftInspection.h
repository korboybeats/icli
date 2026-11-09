#import <Foundation/Foundation.h>

BOOL FUSwiftInspectionAvailable(void);
NSString *FUSwiftInspectionUnavailableReason(void);
BOOL FUSwiftValueInspectionAvailable(void);
NSString *FUSwiftValueInspectionUnavailableReason(void);
NSDictionary *FUHandleSwiftInspect(NSString *requestID, NSDictionary *request);
