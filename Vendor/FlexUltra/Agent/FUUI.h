#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef BOOL (*FUUIExperimentPrepareMutationCallback)(NSDictionary *request, NSString **experimentID, NSDictionary **errorInfo);
typedef void (*FUUIExperimentAbortMutationCallback)(NSString *experimentID);
typedef BOOL (*FUUIExperimentCommitMutationCallback)(NSString *experimentID, NSDictionary *undoRecord, NSMutableDictionary *result, NSDictionary **errorInfo);

void FUUIConfigureExperimentCallbacks(FUUIExperimentPrepareMutationCallback prepare,
                                      FUUIExperimentAbortMutationCallback abort,
                                      FUUIExperimentCommitMutationCallback commit);

NSArray<UIWindow *> *FUAllWindows(void);
UIWindow *FUKeyWindow(void);
NSDictionary *FUWindowJSON(UIWindow *window);
NSArray<NSNumber *> *FUViewPathFromRoot(UIView *view, UIView *rootView);
NSDictionary *FUStableSelectorForView(UIView *view, UIView *rootView);
UIView *FUViewForActionHandle(NSString *handle);

NSDictionary *FUHandleUIWindows(NSString *requestID);
NSDictionary *FUHandleUIKeyWindow(NSString *requestID);
NSDictionary *FUHandleUIHierarchy(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleUIFind(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleUIResolve(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleUIWait(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleUIActivate(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleUISelect(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleUIBack(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleUIDismiss(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleUIFirstResponder(NSString *requestID);
NSDictionary *FUHandleUIDismissKeyboard(NSString *requestID);
NSDictionary *FUHandleUIAlert(NSString *requestID);
NSDictionary *FUHandleUIAlertAction(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleUIHitTest(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleUITap(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleUISetText(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleUISetValue(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleUIScroll(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleUIScreenshot(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleUISnapshot(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleUISnapshotSave(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleUISnapshotDiff(NSString *requestID, NSDictionary *request);
NSDictionary *FUHandleUIDeepInspect(NSString *requestID, NSDictionary *request);
