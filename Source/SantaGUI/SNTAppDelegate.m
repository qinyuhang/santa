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

#import "SNTAppDelegate.h"

#import "SNTAboutWindowController.h"
#import "SNTConfigurator.h"
#import "SNTFileWatcher.h"
#import "SNTNotificationManager.h"
#import "SNTXPCConnection.h"

@interface SNTAppDelegate ()
@property SNTAboutWindowController *aboutWindowController;
@property SNTFileWatcher *configFileWatcher;
@property SNTNotificationManager *notificationManager;
@property SNTXPCConnection *listener;
@end

@implementation SNTAppDelegate

#pragma mark App Delegate methods

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
  [self setupMenu];

  self.configFileWatcher = [[SNTFileWatcher alloc] initWithFilePath:kDefaultConfigFilePath
                                                            handler:^{
      [[SNTConfigurator configurator] reloadConfigData];
  }];

  self.notificationManager = [[SNTNotificationManager alloc] init];

  NSNotificationCenter *workspaceNotifications = [[NSWorkspace sharedWorkspace] notificationCenter];

  [workspaceNotifications addObserverForName:NSWorkspaceSessionDidResignActiveNotification
                                      object:nil
                                       queue:[NSOperationQueue currentQueue]
                                  usingBlock:^(NSNotification *note) {
      self.listener.invalidationHandler = nil;
      self.listener.rejectedHandler = nil;
      [self.listener invalidate];
      self.listener = nil;
  }];
  [workspaceNotifications addObserverForName:NSWorkspaceSessionDidBecomeActiveNotification
                                      object:nil
                                       queue:[NSOperationQueue currentQueue]
                                  usingBlock:^(NSNotification *note) {
      [self attemptReconnection];
  }];

  [self createConnection];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
  self.aboutWindowController = [[SNTAboutWindowController alloc] init];
  [self.aboutWindowController showWindow:self];
  return NO;
}

#pragma mark Connection handling

- (void)createConnection {
  __weak __typeof(self) weakSelf = self;

  self.listener = [[SNTXPCConnection alloc] initClientWithName:[SNTXPCNotifierInterface serviceId]
                                                       options:NSXPCConnectionPrivileged];
  self.listener.exportedInterface = [SNTXPCNotifierInterface notifierInterface];
  self.listener.exportedObject = self.notificationManager;
  self.listener.rejectedHandler = ^{
      [weakSelf attemptReconnection];
  };
  self.listener.invalidationHandler = self.listener.rejectedHandler;
  [self.listener resume];
}

- (void)attemptReconnection {
  // TODO(rah): Make this smarter.
  sleep(5);
  [self createConnection];
}

#pragma mark Menu Management

- (void)setupMenu {
  // Whilst the user will never see the menu, having one with the Copy and Select All options
  // allows the shortcuts for these items to work, which is useful for being able to copy
  // information from notifications. The mainMenu must have a nested menu for this to work properly.
  NSMenu *mainMenu = [[NSMenu alloc] init];
  NSMenu *editMenu = [[NSMenu alloc] init];
  [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
  [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
  NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
  [editMenuItem setSubmenu:editMenu];
  [mainMenu addItem:editMenuItem];
  [NSApp setMainMenu:mainMenu];
}

@end
