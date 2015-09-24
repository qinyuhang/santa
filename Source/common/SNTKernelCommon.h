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

///
/// Common defines between kernel <-> userspace
///

#include <sys/param.h>

#ifndef SANTA__COMMON__KERNELCOMMON_H
#define SANTA__COMMON__KERNELCOMMON_H

// Defines the lengths of paths and Vnode IDs passed around.
#define MAX_VNODE_ID_STR 21  // digits in UINT64_MAX + 1 for NULL-terminator

// Defines the name of the userclient class and the driver bundle ID.
#define USERCLIENT_CLASS "com_google_SantaDriver"
#define USERCLIENT_ID "com.google.santa-driver"

// List of methods supported by the driver.
enum SantaDriverMethods {
  kSantaUserClientOpen,
  kSantaUserClientAllowBinary,
  kSantaUserClientDenyBinary,
  kSantaUserClientClearCache,
  kSantaUserClientCacheCount,

  // Any methods supported by the driver should be added above this line to
  // ensure this remains the count of methods.
  kSantaUserClientNMethods,
};

// Enum defining actions that can be passed down the IODataQueue and in
// response methods.
typedef enum {
  ACTION_UNSET = 0,

  // CHECKBW
  ACTION_REQUEST_CHECKBW = 10,
  ACTION_RESPOND_CHECKBW_ALLOW = 11,
  ACTION_RESPOND_CHECKBW_DENY = 12,

  // NOTIFY
  ACTION_NOTIFY_EXEC = 20,
  ACTION_NOTIFY_WRITE = 21,
  ACTION_NOTIFY_RENAME = 22,
  ACTION_NOTIFY_LINK = 23,
  ACTION_NOTIFY_EXCHANGE = 24,
  ACTION_NOTIFY_DELETE = 25,

  // SHUTDOWN
  ACTION_REQUEST_SHUTDOWN = 90,

  // ERROR
  ACTION_ERROR = 99,
} santa_action_t;

#define CHECKBW_RESPONSE_VALID(x) \
  (x == ACTION_RESPOND_CHECKBW_ALLOW || x == ACTION_RESPOND_CHECKBW_DENY)

// Message struct that is sent down the IODataQueue.
typedef struct {
  santa_action_t action;
  uint64_t vnode_id;
  uid_t uid;
  gid_t gid;
  pid_t pid;
  pid_t ppid;
  char path[MAXPATHLEN];
  char newpath[MAXPATHLEN];
} santa_message_t;

#endif  // SANTA__COMMON__KERNELCOMMON_H
