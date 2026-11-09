#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NSString *FUAddressOfObject(id object);
NSString *FUClassName(id object);
NSString *FUTruncatedString(NSString *string, NSUInteger limit);
NSString *FUSafeSummary(id object);
NSDictionary *FUObjectReference(id object);
id FUJSONValue(id value);
id FUJSONFloatingNumber(CGFloat value);
NSDictionary *FURectJSON(CGRect rect);
NSDictionary *FUPointJSON(CGPoint point);
NSDictionary *FUSizeJSON(CGSize size);
