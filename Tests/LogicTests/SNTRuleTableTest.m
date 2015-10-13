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

#import <XCTest/XCTest.h>

#import "SNTRule.h"
#import "SNTRuleTable.h"

@interface SNTRuleTable (Testing)
@property NSString *santadCertSHA;
@property NSString *launchdCertSHA;
@end

/// This test case actually tests SNTRuleTable and SNTRule
@interface SNTRuleTableTest : XCTestCase
@property SNTRuleTable *sut;
@property FMDatabaseQueue *dbq;
@end

@implementation SNTRuleTableTest

- (void)setUp {
  [super setUp];

  self.dbq = [[FMDatabaseQueue alloc] init];
  self.sut = [[SNTRuleTable alloc] initWithDatabaseQueue:self.dbq];
}

- (SNTRule *)_exampleBinaryRule {
  SNTRule *r = [[SNTRule alloc] init];
  r.shasum = @"a";
  r.state = RULESTATE_BLACKLIST;
  r.type = RULETYPE_BINARY;
  r.customMsg = @"A rule";
  return r;
}

- (SNTRule *)_exampleCertRule {
  SNTRule *r = [[SNTRule alloc] init];
  r.shasum = @"b";
  r.state = RULESTATE_WHITELIST;
  r.type = RULETYPE_CERT;
  return r;
}

- (void)testAddRulesNotClean {
  NSUInteger ruleCount = self.sut.ruleCount;
  NSUInteger binaryRuleCount = self.sut.binaryRuleCount;

  [self.sut addRules:@[ [self _exampleBinaryRule] ] cleanSlate:NO];

  XCTAssertEqual(self.sut.ruleCount, ruleCount + 1);
  XCTAssertEqual(self.sut.binaryRuleCount, binaryRuleCount + 1);
}

- (void)testAddRulesClean {
  // Assert that insert without 'self' and launchd cert hashes fails
  XCTAssertFalse([self.sut addRules:@[ [self _exampleBinaryRule] ] cleanSlate:YES]);

  // Now add a binary rule without clean slate
  XCTAssertTrue([self.sut addRules:@[ [self _exampleBinaryRule] ] cleanSlate:NO]);

  // Now add a cert rule + the required rules as a clean slate,
  // assert that the binary rule was removed
  SNTRule *r1 = [[SNTRule alloc] init];
  r1.shasum = self.sut.launchdCertSHA;
  r1.state = RULESTATE_WHITELIST;
  r1.type = RULETYPE_CERT;
  SNTRule *r2 = [[SNTRule alloc] init];
  r2.shasum = self.sut.santadCertSHA;
  r2.state = RULESTATE_WHITELIST;
  r2.type = RULETYPE_CERT;

  XCTAssertTrue(([self.sut addRules:@[ [self _exampleCertRule], r1, r2 ] cleanSlate:YES]));
  XCTAssertEqual([self.sut binaryRuleCount], 0);
}

- (void)testAddMultipleRules {
  NSUInteger ruleCount = self.sut.ruleCount;

  [self.sut addRules:@[ [self _exampleBinaryRule],
                        [self _exampleCertRule],
                        [self _exampleBinaryRule] ]
          cleanSlate:NO];

  XCTAssertEqual(self.sut.ruleCount, ruleCount + 2);
}

- (void)testAddRulesEmptyArray {
  XCTAssertFalse([self.sut addRules:@[] cleanSlate:YES]);
}

- (void)testAddRulesNilArray {
  XCTAssertFalse([self.sut addRules:nil cleanSlate:YES]);
}

- (void)testFetchBinaryRule {
  [self.sut addRules:@[ [self _exampleBinaryRule], [self _exampleCertRule] ] cleanSlate:NO];

  SNTRule *r = [self.sut binaryRuleForSHA256:@"a"];
  XCTAssertNotNil(r);
  XCTAssertEqualObjects(r.shasum, @"a");
  XCTAssertEqual(r.type, RULETYPE_BINARY);

  r = [self.sut binaryRuleForSHA256:@"b"];
  XCTAssertNil(r);
}

- (void)testFetchCertificateRule {
  [self.sut addRules:@[ [self _exampleBinaryRule], [self _exampleCertRule] ] cleanSlate:NO];

  SNTRule *r = [self.sut certificateRuleForSHA256:@"b"];
  XCTAssertNotNil(r);
  XCTAssertEqualObjects(r.shasum, @"b");
  XCTAssertEqual(r.type, RULETYPE_CERT);

  r = [self.sut certificateRuleForSHA256:@"a"];
  XCTAssertNil(r);
}

- (void)testBadDatabase {
  NSString *dbPath = [NSTemporaryDirectory() stringByAppendingString:@"sntruletabletest_baddb.db"];
  [@"some text" writeToFile:dbPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];

  FMDatabaseQueue *dbq = [[FMDatabaseQueue alloc] initWithPath:dbPath];
  SNTRuleTable *sut = [[SNTRuleTable alloc] initWithDatabaseQueue:dbq];

  [sut addRules:@[ [self _exampleBinaryRule] ] cleanSlate:NO];

  XCTAssertGreaterThan(sut.ruleCount, 0);

  [[NSFileManager defaultManager] removeItemAtPath:dbPath error:NULL];
}

@end
