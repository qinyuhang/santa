/// Copyright 2015 Google Inc. All rights reserved.
///
/// Licensed under the Apache License, Version 2.0 (the "License");
/// you may not use this file except in compliance with the License.
/// You may obtain a copy of the License at
///
///    http://www.apache.org/licenses/LICENSE-2.0
///
///    Unless required by applicable law or agreed to in writing, software
///    distributed under the License is distributed on an "AS IS" BASIS,
///    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
///    See the License for the specific language governing permissions and
///    limitations under the License.

#include <sys/stat.h>
#include <sys/types.h>

#import "SNTApplication.h"

#include "SNTCommonEnums.h"
#include "SNTLogging.h"

#import "SNTConfigurator.h"
#import "SNTDaemonControlController.h"
#import "SNTDatabaseController.h"
#import "SNTDriverManager.h"
#import "SNTEventLog.h"
#import "SNTEventTable.h"
#import "SNTExecutionController.h"
#import "SNTFileWatcher.h"
#import "SNTRuleTable.h"
#import "SNTXPCConnection.h"
#import "SNTXPCControlInterface.h"
#import "SNTXPCNotifierInterface.h"

@interface SNTApplication ()
@property SNTDriverManager *driverManager;
@property SNTEventLog *eventLog;
@property SNTEventTable *eventTable;
@property SNTExecutionController *execController;
@property SNTFileWatcher *configFileWatcher;
@property SNTRuleTable *ruleTable;
@property SNTXPCConnection *controlConnection;
@property SNTXPCConnection *notifierConnection;
@end

@implementation SNTApplication

- (instancetype)init {
  self = [super init];
  if (self) {
    // Locate and connect to driver
    _driverManager = [[SNTDriverManager alloc] init];

    if (!_driverManager) {
      LOGE(@"Failed to connect to driver, exiting.");

      // TODO(rah): Consider trying to load the extension from within santad.
      return nil;
    }

    // Initialize tables
    _ruleTable = [SNTDatabaseController ruleTable];
    if (!_ruleTable) {
      LOGE(@"Failed to initialize rule table.");
      return nil;
    }

    _eventTable = [SNTDatabaseController eventTable];
    if (!_eventTable) {
      LOGE(@"Failed to initialize event table.");
      return nil;
    }

    // Establish XPC listener for GUI agent connections
    _notifierConnection =
        [[SNTXPCConnection alloc] initServerWithName:[SNTXPCNotifierInterface serviceId]];
    _notifierConnection.remoteInterface = [SNTXPCNotifierInterface notifierInterface];
    [_notifierConnection resume];

    // Establish XPC listener for santactl connections
    _controlConnection =
        [[SNTXPCConnection alloc] initServerWithName:[SNTXPCControlInterface serviceId]];
    _controlConnection.exportedInterface = [SNTXPCControlInterface controlInterface];
    _controlConnection.exportedObject =
        [[SNTDaemonControlController alloc] initWithDriverManager:_driverManager];
    [_controlConnection resume];

    _configFileWatcher = [[SNTFileWatcher alloc] initWithFilePath:kDefaultConfigFilePath
                                                          handler:^{
        [[SNTConfigurator configurator] reloadConfigData];

        // Ensure config file remains root:wheel 0644
        chown([kDefaultConfigFilePath fileSystemRepresentation], 0, 0);
        chmod([kDefaultConfigFilePath fileSystemRepresentation], 0644);
    }];

    _eventLog = [[SNTEventLog alloc] init];

    // Initialize the binary checker object
    _execController = [[SNTExecutionController alloc] initWithDriverManager:_driverManager
                                                                  ruleTable:_ruleTable
                                                                 eventTable:_eventTable
                                                         notifierConnection:_notifierConnection
                                                                   eventLog:_eventLog];
    if (!_execController) return nil;
  }

  return self;
}

- (void)run {
  LOGI(@"Connected to driver, activating.");

  // Create the queues used for execution requests and logging.
  dispatch_queue_t exec_queue = dispatch_queue_create(
      "com.google.santad.execution_queue", DISPATCH_QUEUE_CONCURRENT);
  dispatch_set_target_queue(exec_queue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));

  dispatch_queue_t log_queue = dispatch_queue_create(
      "com.google.santad.log_queue", DISPATCH_QUEUE_CONCURRENT);
  dispatch_set_target_queue(
      log_queue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));

  [self.driverManager listenWithBlock:^(santa_message_t message) {
      @autoreleasepool {
        switch (message.action) {
          case ACTION_REQUEST_SHUTDOWN: {
            LOGI(@"Driver requested a shutdown");
            exit(0);
          }
          case ACTION_NOTIFY_DELETE:
          case ACTION_NOTIFY_EXCHANGE:
          case ACTION_NOTIFY_LINK:
          case ACTION_NOTIFY_RENAME:
          case ACTION_NOTIFY_WRITE: {
            dispatch_async(log_queue, ^{
              NSRegularExpression *re = [[SNTConfigurator configurator] fileChangesRegex];
              NSString *path = @(message.path);
              if ([re numberOfMatchesInString:path options:0 range:NSMakeRange(0, path.length)]) {
                [self.eventLog logFileModification:message];
              }
            });
            break;
          }
          case ACTION_NOTIFY_EXEC: {
            dispatch_async(log_queue, ^{
              [self.eventLog logAllowedExecution:message];
            });
            break;
          }
          case ACTION_REQUEST_CHECKBW: {
            dispatch_async(exec_queue, ^{
                [self.execController validateBinaryWithMessage:message];
            });
            break;
          }
          default: {
            LOGE(@"Received request without a valid action: %d", message.action);
            exit(1);
          }
        }
      }
  }];
}

@end
