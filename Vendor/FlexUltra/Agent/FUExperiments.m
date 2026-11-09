#import "FUExperiments.h"

#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <math.h>

#import "FUDefaults.h"
#import "FUObjectRegistry.h"
#import "FUObjectSerialization.h"
#import "FUProtocol.h"

static NSObject *FUExperimentLock;
static NSString *FUExperimentID;
static NSString *FUExperimentGeneration;
static NSTimeInterval FUExperimentStartedAt = 0;
static NSMutableArray<NSDictionary *> *FUExperimentMutations;
static BOOL FUExperimentActive = NO;
static BOOL FUExperimentMutationInFlight = NO;
static const NSUInteger FUExperimentMaxMutations = 256;

static void FUInitializeExperimentState(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FUExperimentLock = [NSObject new];
        FUExperimentMutations = [NSMutableArray array];
    });
}

static NSDictionary *FUExperimentStatusLocked(void) {
    NSMutableDictionary *result = [@{
        @"active": @(FUExperimentActive),
        @"mutation_count": @(FUExperimentMutations.count),
        @"max_mutations": @(FUExperimentMaxMutations),
        @"mutation_in_flight": @(FUExperimentMutationInFlight),
        @"current_generation": FUCurrentObjectGeneration(),
    } mutableCopy];
    if (FUExperimentActive) {
        result[@"experiment_id"] = FUExperimentID ?: @"";
        result[@"generation"] = FUExperimentGeneration ?: @"";
        result[@"started_at_unix_ms"] = @((uint64_t)llround(FUExperimentStartedAt * 1000.0));
    }
    return result;
}

NSDictionary *FUExperimentStatusSnapshot(void) {
    FUInitializeExperimentState();
    @synchronized (FUExperimentLock) {
        return FUExperimentStatusLocked();
    }
}

static void FUExperimentClearLocked(void) {
    FUExperimentActive = NO;
    FUExperimentMutationInFlight = NO;
    FUExperimentID = nil;
    FUExperimentGeneration = nil;
    FUExperimentStartedAt = 0;
    [FUExperimentMutations removeAllObjects];
}

static NSDictionary *FUExperimentStateErrorLocked(NSString *code, NSString *message) {
    NSMutableDictionary *error = [FUErrorInfo(code, message) mutableCopy];
    if (FUExperimentID.length) error[@"active_experiment_id"] = FUExperimentID;
    if (FUExperimentGeneration.length) error[@"experiment_generation"] = FUExperimentGeneration;
    error[@"current_generation"] = FUCurrentObjectGeneration();
    return error;
}

BOOL FUExperimentPrepareMutation(NSDictionary *request, NSString **experimentID, NSDictionary **errorInfo) {
    if (experimentID) *experimentID = nil;
    if (errorInfo) *errorInfo = nil;
    if (![request.allKeys containsObject:@"experiment_id"]) return YES;

    id rawExperimentID = request[@"experiment_id"];
    if (![rawExperimentID isKindOfClass:[NSString class]] || [(NSString *)rawExperimentID length] == 0) {
        if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"experiment_id must be a non-empty string when supplied.");
        return NO;
    }

    FUInitializeExperimentState();
    NSString *requestedID = rawExperimentID;
    @synchronized (FUExperimentLock) {
        if (!FUExperimentActive) {
            if (errorInfo) *errorInfo = FUExperimentStateErrorLocked(@"experiment_not_active", @"No reversible experiment is active in this target process.");
            return NO;
        }
        if (![FUExperimentGeneration isEqualToString:FUCurrentObjectGeneration()]) {
            if (errorInfo) *errorInfo = FUExperimentStateErrorLocked(@"stale_experiment", @"The active experiment belongs to a different target process generation.");
            return NO;
        }
        if (![FUExperimentID isEqualToString:requestedID]) {
            if (errorInfo) *errorInfo = FUExperimentStateErrorLocked(@"experiment_mismatch", @"experiment_id does not match the active experiment in this target process.");
            return NO;
        }
        if (FUExperimentMutationInFlight) {
            if (errorInfo) *errorInfo = FUExperimentStateErrorLocked(@"experiment_busy", @"Another experiment mutation is currently being recorded.");
            return NO;
        }
        if (FUExperimentMutations.count >= FUExperimentMaxMutations) {
            if (errorInfo) *errorInfo = FUExperimentStateErrorLocked(@"experiment_full", @"The active experiment reached its reversible mutation limit. Roll it back or commit it before continuing.");
            return NO;
        }
        FUExperimentMutationInFlight = YES;
        if (experimentID) *experimentID = [requestedID copy];
        return YES;
    }
}

void FUExperimentAbortMutation(NSString *experimentID) {
    if (experimentID.length == 0) return;
    FUInitializeExperimentState();
    @synchronized (FUExperimentLock) {
        if (FUExperimentActive && [FUExperimentID isEqualToString:experimentID]) {
            FUExperimentMutationInFlight = NO;
        }
    }
}

static NSString *FUExperimentUndoRecord(NSDictionary *record) {
    NSString *mutation = [record[@"mutation"] isKindOfClass:[NSString class]] ? record[@"mutation"] : @"unknown";
    __block NSString *failureMessage = nil;
    void (^rollbackRecord)(void) = ^{
        @try {
            if ([mutation isEqualToString:@"defaults"]) {
                NSString *key = record[@"key"];
                BOOL previousExists = [record[@"previous_exists"] boolValue];
                NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
                if (previousExists) {
                    id previousValue = record[@"previous_value"];
                    if (previousValue) [defaults setObject:previousValue forKey:key];
                } else {
                    [defaults removeObjectForKey:key];
                }
                [defaults synchronize];
                FURecordDefaultsOwnership(key, [record[@"previous_owned"] boolValue]);
            } else if ([mutation isEqualToString:@"ui.set_text"]) {
                id object = record[@"object"];
                NSString *oldText = record[@"old_text"] ?: @"";
                NSString *kind = record[@"kind"];
                if ([kind isEqualToString:@"text_field"] && [object isKindOfClass:[UITextField class]]) {
                    ((UITextField *)object).text = oldText;
                } else if ([kind isEqualToString:@"text_view"] && [object isKindOfClass:[UITextView class]]) {
                    ((UITextView *)object).text = oldText;
                } else if ([kind isEqualToString:@"search_bar"] && [object isKindOfClass:[UISearchBar class]]) {
                    ((UISearchBar *)object).text = oldText;
                } else {
                    failureMessage = @"The retained text target no longer matches its recorded UIKit type.";
                }
            } else if ([mutation isEqualToString:@"ui.set_value"]) {
                id object = record[@"object"];
                NSString *kind = record[@"kind"];
                NSNumber *oldValue = record[@"old_value"];
                if ([kind isEqualToString:@"switch"] && [object isKindOfClass:[UISwitch class]]) {
                    [(UISwitch *)object setOn:oldValue.boolValue animated:NO];
                } else if ([kind isEqualToString:@"slider"] && [object isKindOfClass:[UISlider class]]) {
                    [(UISlider *)object setValue:oldValue.floatValue animated:NO];
                } else if ([kind isEqualToString:@"stepper"] && [object isKindOfClass:[UIStepper class]]) {
                    ((UIStepper *)object).value = oldValue.doubleValue;
                } else if ([kind isEqualToString:@"segmented_control"] && [object isKindOfClass:[UISegmentedControl class]]) {
                    ((UISegmentedControl *)object).selectedSegmentIndex = oldValue.integerValue;
                } else {
                    failureMessage = @"The retained value target no longer matches its recorded UIKit type.";
                }
            } else if ([mutation isEqualToString:@"ui.scroll"]) {
                id object = record[@"object"];
                if ([object isKindOfClass:[UIScrollView class]]) {
                    CGPoint offset = CGPointMake([record[@"x"] doubleValue], [record[@"y"] doubleValue]);
                    [(UIScrollView *)object setContentOffset:offset animated:NO];
                } else {
                    failureMessage = @"The retained scroll target is no longer a UIScrollView.";
                }
            } else {
                failureMessage = [NSString stringWithFormat:@"Unknown undo record type '%@'.", mutation];
            }
        } @catch (NSException *exception) {
            failureMessage = FUTruncatedString(exception.reason ?: exception.name, 512);
        }
    };

    BOOL uiMutation = [mutation hasPrefix:@"ui."];
    if (uiMutation && !NSThread.isMainThread) dispatch_sync(dispatch_get_main_queue(), rollbackRecord);
    else rollbackRecord();
    return failureMessage;
}

BOOL FUExperimentCommitMutation(NSString *experimentID, NSDictionary *undoRecord, NSMutableDictionary *result, NSDictionary **errorInfo) {
    if (errorInfo) *errorInfo = nil;
    if (experimentID.length == 0) return YES;
    FUInitializeExperimentState();
    __block NSDictionary *recordError = nil;
    @synchronized (FUExperimentLock) {
        if (!FUExperimentActive) {
            recordError = FUExperimentStateErrorLocked(@"experiment_not_active", @"The experiment ended before the mutation could be recorded.");
        } else if (![FUExperimentGeneration isEqualToString:FUCurrentObjectGeneration()]) {
            recordError = FUExperimentStateErrorLocked(@"stale_experiment", @"The experiment generation changed before the mutation could be recorded.");
        } else if (![FUExperimentID isEqualToString:experimentID]) {
            recordError = FUExperimentStateErrorLocked(@"experiment_mismatch", @"The active experiment changed before the mutation could be recorded.");
        } else if (!undoRecord || FUExperimentMutations.count >= FUExperimentMaxMutations) {
            recordError = FUExperimentStateErrorLocked(@"experiment_full", @"The active experiment could not record an undo entry for this mutation.");
        } else {
            NSUInteger mutationIndex = FUExperimentMutations.count;
            [FUExperimentMutations addObject:undoRecord];
            FUExperimentMutationInFlight = NO;
            if (result) {
                result[@"experiment_id"] = FUExperimentID;
                result[@"experiment_mutation_index"] = @(mutationIndex);
                result[@"experiment_mutation_count"] = @(FUExperimentMutations.count);
            }
            return YES;
        }
        FUExperimentMutationInFlight = NO;
    }

    NSString *undoFailure = undoRecord ? FUExperimentUndoRecord(undoRecord) : @"No undo record was available for the completed mutation.";
    NSMutableDictionary *error = [recordError mutableCopy] ?: [FUErrorInfo(@"experiment_record_failed", @"The completed mutation could not be recorded in the active experiment.") mutableCopy];
    error[@"mutation_reverted"] = [NSNumber numberWithBool:(undoFailure.length == 0)];
    if (undoFailure.length) error[@"revert_error"] = undoFailure;
    if (errorInfo) *errorInfo = error;
    return NO;
}

id FUExperimentCopyPropertyListValue(id value) {
    if (!value) return nil;
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:&error];
    if (!data || error) return [value copy];
    id copy = [NSPropertyListSerialization propertyListWithData:data
                                                        options:NSPropertyListMutableContainersAndLeaves
                                                         format:nil
                                                          error:&error];
    return copy ?: [value copy];
}

NSDictionary *FUHandleExperimentBegin(NSString *requestID) {
    FUInitializeExperimentState();
    @synchronized (FUExperimentLock) {
        if (FUExperimentActive) {
            return FUResponse(requestID, NO, nil, FUExperimentStateErrorLocked(@"experiment_active", @"A reversible experiment is already active in this target process."));
        }
        FUExperimentID = [[[[NSUUID UUID] UUIDString] lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@""];
        FUExperimentGeneration = [FUCurrentObjectGeneration() copy];
        FUExperimentStartedAt = NSDate.date.timeIntervalSince1970;
        FUExperimentActive = YES;
        FUExperimentMutationInFlight = NO;
        [FUExperimentMutations removeAllObjects];
        return FUResponse(requestID, YES, FUExperimentStatusLocked(), nil);
    }
}

NSDictionary *FUHandleExperimentStatus(NSString *requestID) {
    FUInitializeExperimentState();
    @synchronized (FUExperimentLock) {
        return FUResponse(requestID, YES, FUExperimentStatusLocked(), nil);
    }
}

NSDictionary *FUHandleExperimentCommit(NSString *requestID) {
    FUInitializeExperimentState();
    @synchronized (FUExperimentLock) {
        if (!FUExperimentActive) {
            return FUResponse(requestID, NO, nil, FUExperimentStateErrorLocked(@"experiment_not_active", @"No reversible experiment is active in this target process."));
        }
        if (![FUExperimentGeneration isEqualToString:FUCurrentObjectGeneration()]) {
            return FUResponse(requestID, NO, nil, FUExperimentStateErrorLocked(@"stale_experiment", @"The active experiment belongs to a different target process generation."));
        }
        if (FUExperimentMutationInFlight) {
            return FUResponse(requestID, NO, nil, FUExperimentStateErrorLocked(@"experiment_busy", @"An experiment mutation is still in progress."));
        }
        NSString *experimentID = [FUExperimentID copy];
        NSString *generation = [FUExperimentGeneration copy];
        NSUInteger mutationCount = FUExperimentMutations.count;
        FUExperimentClearLocked();
        return FUResponse(requestID, YES, @{
            @"committed": @YES,
            @"experiment_id": experimentID ?: @"",
            @"generation": generation ?: @"",
            @"mutation_count": @(mutationCount),
            @"active": @NO,
        }, nil);
    }
}

NSDictionary *FUHandleExperimentRollback(NSString *requestID) {
    FUInitializeExperimentState();

    __block NSString *experimentID = nil;
    __block NSString *generation = nil;
    __block NSArray<NSDictionary *> *records = nil;
    @synchronized (FUExperimentLock) {
        if (!FUExperimentActive) {
            return FUResponse(requestID, NO, nil, FUExperimentStateErrorLocked(@"experiment_not_active", @"No reversible experiment is active in this target process."));
        }
        if (![FUExperimentGeneration isEqualToString:FUCurrentObjectGeneration()]) {
            return FUResponse(requestID, NO, nil, FUExperimentStateErrorLocked(@"stale_experiment", @"The active experiment belongs to a different target process generation."));
        }
        if (FUExperimentMutationInFlight) {
            return FUResponse(requestID, NO, nil, FUExperimentStateErrorLocked(@"experiment_busy", @"An experiment mutation is still in progress."));
        }
        experimentID = [FUExperimentID copy];
        generation = [FUExperimentGeneration copy];
        records = [FUExperimentMutations copy];
        FUExperimentClearLocked();
    }

    NSUInteger restored = 0;
    NSUInteger failureCount = 0;
    NSMutableArray<NSDictionary *> *failures = [NSMutableArray array];
    for (NSInteger index = (NSInteger)records.count - 1; index >= 0; index--) {
        NSDictionary *record = records[(NSUInteger)index];
        NSString *mutation = [record[@"mutation"] isKindOfClass:[NSString class]] ? record[@"mutation"] : @"unknown";
        NSString *failureMessage = FUExperimentUndoRecord(record);

        if (failureMessage.length) {
            failureCount++;
            if (failures.count < 32) {
                [failures addObject:@{
                    @"mutation_index": @((NSUInteger)index),
                    @"mutation": mutation,
                    @"code": @"rollback_failed",
                    @"message": failureMessage,
                }];
            }
        } else {
            restored++;
        }
    }

    return FUResponse(requestID, YES, @{
        @"rolled_back": @YES,
        @"experiment_id": experimentID ?: @"",
        @"generation": generation ?: @"",
        @"attempted": @(records.count),
        @"restored": @(restored),
        @"failure_count": @(failureCount),
        @"failures": failures,
        @"failures_truncated": [NSNumber numberWithBool:(failureCount > failures.count)],
        @"fully_restored": [NSNumber numberWithBool:(failureCount == 0)],
        @"active": @NO,
    }, nil);
}

