#import <Foundation/Foundation.h>

NSDictionary *FUExperimentStatusSnapshot(void);
BOOL FUExperimentPrepareMutation(NSDictionary *request, NSString **experimentID, NSDictionary **errorInfo);
void FUExperimentAbortMutation(NSString *experimentID);
BOOL FUExperimentCommitMutation(NSString *experimentID, NSDictionary *undoRecord, NSMutableDictionary *result, NSDictionary **errorInfo);
id FUExperimentCopyPropertyListValue(id value);

NSDictionary *FUHandleExperimentBegin(NSString *requestID);
NSDictionary *FUHandleExperimentStatus(NSString *requestID);
NSDictionary *FUHandleExperimentCommit(NSString *requestID);
NSDictionary *FUHandleExperimentRollback(NSString *requestID);
