#import <Foundation/Foundation.h>

typedef NSDictionary *(*FURequestTargetHealthProvider)(NSString *requestID);

NSDictionary *FUDispatchRequest(NSDictionary *request,
                                NSString *agentBuildID,
                                FURequestTargetHealthProvider targetHealthProvider);
