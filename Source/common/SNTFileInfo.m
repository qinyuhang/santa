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

#import "SNTFileInfo.h"

#import <CommonCrypto/CommonDigest.h>

#include <mach-o/loader.h>
#include <mach-o/swap.h>
#include <sys/stat.h>

// Simple class to hold the data of a mach_header and the offset within the file
// in which that header was found.
@interface MachHeaderWithOffset : NSObject
@property NSData *data;
@property uint32_t offset;
- (instancetype)initWithData:(NSData *)data offset:(uint32_t)offset;
@end
@implementation MachHeaderWithOffset
- (instancetype)initWithData:(NSData *)data offset:(uint32_t)offset {
  self = [super init];
  if (self) {
    _data = data;
    _offset = offset;
  }
  return self;
}
@end

@interface SNTFileInfo ()
@property NSString *path;
@property NSFileHandle *fileHandle;
@property NSUInteger fileSize;

// Cached properties
@property NSBundle *bundleRef;
@property NSDictionary *infoDict;
@property NSDictionary *quarantineDict;
@property NSDictionary *cachedHeaders;
@end

@implementation SNTFileInfo

extern NSString *const NSURLQuarantinePropertiesKey WEAK_IMPORT_ATTRIBUTE;

- (instancetype)initWithPath:(NSString *)path error:(NSError **)error {
  self = [super init];
  if (self) {
    _path = [self resolvePath:path];
    if (_path.length == 0) {
      if (error) {
        NSString *errStr = @"Unable to resolve empty path";
        if (path) errStr = [@"Unable to resolve path: " stringByAppendingString:path];
        *error = [NSError errorWithDomain:@"com.google.santa.fileinfo"
                                     code:260
                                 userInfo:@{ NSLocalizedDescriptionKey: errStr }];
      }
      return nil;
    }

    _fileHandle = [NSFileHandle fileHandleForReadingAtPath:_path];

    struct stat fileStat;
    fstat(_fileHandle.fileDescriptor, &fileStat);
    _fileSize = fileStat.st_size;

    if (_fileSize == 0) return nil;
  }

  return self;
}

- (instancetype)initWithPath:(NSString *)path {
  return [self initWithPath:path error:NULL];
}

# pragma mark Hashing

- (NSString *)SHA1 {
  const int chunkSize = 4096;

  CC_SHA1_CTX c;
  CC_SHA1_Init(&c);
  for (uint64_t offset = 0; offset < self.fileSize; offset += chunkSize) {
    @autoreleasepool {
      int readSize;
      if (offset + chunkSize > self.fileSize) {
        readSize = (int)(self.fileSize - offset);
      } else {
        readSize = chunkSize;
      }

      NSData *chunk = [self safeSubdataWithRange:NSMakeRange(offset, readSize)];
      if (!chunk) {
        CC_SHA1_Final(NULL, &c);
        return nil;
      }

      CC_SHA1_Update(&c, chunk.bytes, readSize);
    }
  }
  unsigned char sha1[CC_SHA1_DIGEST_LENGTH];
  CC_SHA1_Final(sha1, &c);

  NSMutableString *buf = [[NSMutableString alloc] initWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
  for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
    [buf appendFormat:@"%02x", (unsigned char)sha1[i]];
  }

  return buf;
}

- (NSString *)SHA256 {
  const int chunkSize = 4096;

  CC_SHA256_CTX c;
  CC_SHA256_Init(&c);
  for (uint64_t offset = 0; offset < self.fileSize; offset += chunkSize) {
    @autoreleasepool {
      int readSize;
      if (offset + chunkSize > self.fileSize) {
        readSize = (int)(self.fileSize - offset);
      } else {
        readSize = chunkSize;
      }

      NSData *chunk = [self safeSubdataWithRange:NSMakeRange(offset, readSize)];
      if (!chunk) {
        CC_SHA256_Final(NULL, &c);
        return nil;
      }

      CC_SHA256_Update(&c, chunk.bytes, readSize);
    }
  }
  unsigned char sha256[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(sha256, &c);

  NSMutableString *buf = [[NSMutableString alloc] initWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
    [buf appendFormat:@"%02x", (unsigned char)sha256[i]];
  }
  
  return buf;
}

# pragma mark File Type Info

- (NSArray *)architectures {
  return [self.machHeaders allKeys];
}


- (BOOL)isExecutable {
  struct mach_header *mach_header = [self firstMachHeader];
  if (mach_header && mach_header->filetype == MH_EXECUTE) return YES;
  return NO;
}

- (BOOL)isDylib {
  struct mach_header *mach_header = [self firstMachHeader];
  if (mach_header && mach_header->filetype == MH_DYLIB) return YES;
  return NO;
}

- (BOOL)isKext {
  struct mach_header *mach_header = [self firstMachHeader];
  if (mach_header && mach_header->filetype == MH_KEXT_BUNDLE) return YES;
  return NO;
}

- (BOOL)isMachO {
  return (self.machHeaders.count > 0);
}

- (BOOL)isFat {
  return (self.machHeaders.count > 1);
}

- (BOOL)isScript {
  const char *magic = (const char *)[[self safeSubdataWithRange:NSMakeRange(0, 2)] bytes];
  return (strncmp("#!", magic, 2) == 0);
}

- (BOOL)isXARArchive {
  const char *magic = (const char *)[[self safeSubdataWithRange:NSMakeRange(0, 4)] bytes];
  return (strncmp("xar!", magic, 4) == 0);
}

- (BOOL)isMissingPageZero {
  // This method only checks i386 arch because the kernel enforces this for other archs
  // See bsd/kern/mach_loader.c, search for enforce_hard_pagezero.
  MachHeaderWithOffset *x86Header = self.machHeaders[[self nameForCPUType:CPU_TYPE_X86]];
  if (!x86Header) return NO;

  struct mach_header *mh = (struct mach_header *)[x86Header.data bytes];
  if (mh->filetype != MH_EXECUTE) return NO;

  NSRange range = NSMakeRange(x86Header.offset + sizeof(struct mach_header),
                              sizeof(struct segment_command));
  NSData *lcData = [self safeSubdataWithRange:range];
  if (!lcData) return NO;

  // This code assumes the __PAGEZERO is always the first load-command in the file.
  // Given that the OS X ABI says "the static linker creates a __PAGEZERO segment
  // as the first segment of an executable file." this should be OK.
  struct load_command *lc = (struct load_command *)[lcData bytes];
  if (lc->cmd == LC_SEGMENT) {
    struct segment_command *segment = (struct segment_command *)lc;
    if (segment->vmaddr == 0 && segment->vmsize != 0 &&
        segment->initprot == 0 && segment->maxprot == 0 &&
        strcmp("__PAGEZERO", segment->segname) == 0) {
      return NO;
    }
  }
  return YES;
}

#pragma mark Bundle Information

///
///  Try and determine the bundle that the represented executable is contained within, if any.
///
///  Rationale: An NSBundle has a method executablePath for discovering the main binary within a
///  bundle but provides no way to get an NSBundle object when only the executablePath is known.
///  Also a bundle can contain multiple binaries within the MacOS folder and we want any of these
///  to count as being part of the bundle.
///
///  This method relies on executable bundles being laid out as follows:
///
/// @code
/// Bundle.app/
///    Contents/
///       MacOS/
///         executable
/// @endcode
///
///  If @c self.path is the full path to @c executable above, this method would return an
///  NSBundle reference for Bundle.app.
///
- (NSBundle *)bundle {
  if (!self.bundleRef) {
    self.bundleRef = (NSBundle *)[NSNull null];

    // Check that the full path is at least 4-levels deep:
    // e.g: /Calendar.app/Contents/MacOS/Calendar
    NSArray *pathComponents = [self.path pathComponents];
    if ([pathComponents count] < 4) return nil;

    pathComponents = [pathComponents subarrayWithRange:NSMakeRange(0, [pathComponents count] - 3)];
    NSBundle *bndl = [NSBundle bundleWithPath:[NSString pathWithComponents:pathComponents]];
    if (bndl && [bndl objectForInfoDictionaryKey:@"CFBundleIdentifier"]) self.bundleRef = bndl;
  }
  return self.bundleRef == (NSBundle *)[NSNull null] ? nil : self.bundleRef;
}

- (NSString *)bundlePath {
  return [self.bundle bundlePath];
}

- (NSDictionary *)infoPlist {
  if (!self.infoDict) {
    NSDictionary *d = [self embeddedPlist];
    if (d) {
      self.infoDict = d;
      return self.infoDict;
    }

    d = self.bundle.infoDictionary;
    if (d) {
      self.infoDict = d;
      return self.infoDict;
    }

    self.infoDict = (NSDictionary *)[NSNull null];
  }
  return self.infoDict == (NSDictionary *)[NSNull null] ? nil : self.infoDict;
}

- (NSString *)bundleIdentifier {
  return [[self.infoPlist objectForKey:@"CFBundleIdentifier"] description];
}

- (NSString *)bundleName {
  return [[self.infoPlist objectForKey:@"CFBundleName"] description];
}

- (NSString *)bundleVersion {
  return [[self.infoPlist objectForKey:@"CFBundleVersion"] description];
}

- (NSString *)bundleShortVersionString {
  return [[self.infoPlist objectForKey:@"CFBundleShortVersionString"] description];
}

#pragma mark Quarantine Data

- (NSString *)quarantineDataURL {
  NSURL *url = [self quarantineData][(__bridge NSString *)kLSQuarantineDataURLKey];
  return [url absoluteString];
}

- (NSString *)quarantineRefererURL {
  NSURL *url = [self quarantineData][(__bridge NSString *)kLSQuarantineOriginURLKey];
  return [url absoluteString];
}

- (NSString *)quarantineAgentBundleID {
  return [self quarantineData][(__bridge NSString *)kLSQuarantineAgentBundleIdentifierKey];
}

- (NSDate *)quarantineTimestamp {
  return [self quarantineData][(__bridge NSString *)kLSQuarantineTimeStampKey];
}

#pragma mark Internal Methods

- (NSDictionary *)machHeaders {
  if (self.cachedHeaders) return self.cachedHeaders;

  // Sanity check file length
  if (self.fileSize < sizeof(struct mach_header)) {
    self.cachedHeaders = [NSDictionary dictionary];
    return self.cachedHeaders;
  }

  NSMutableDictionary *machHeaders = [NSMutableDictionary dictionary];

  NSData *machHeader = [self parseSingleMachHeader:[self safeSubdataWithRange:NSMakeRange(0,
                                                                                          4096)]];
  if (machHeader) {
    struct mach_header *mh = (struct mach_header *)[machHeader bytes];
    MachHeaderWithOffset *mhwo = [[MachHeaderWithOffset alloc] initWithData:machHeader offset:0];
    machHeaders[[self nameForCPUType:mh->cputype]] = mhwo;
  } else {
    NSRange range = NSMakeRange(0, sizeof(struct fat_header));
    NSData *fatHeader = [self safeSubdataWithRange:range];
    struct fat_header *fh = (struct fat_header *)[fatHeader bytes];

    if (fatHeader && (fh->magic == FAT_MAGIC || fh->magic == FAT_CIGAM)) {
      int nfat_arch = OSSwapBigToHostInt32(fh->nfat_arch);
      range = NSMakeRange(sizeof(struct fat_header), sizeof(struct fat_arch) * nfat_arch);
      NSMutableData *fatArchs = [[self safeSubdataWithRange:range] mutableCopy];
      if (fatArchs) {
        struct fat_arch *fat_arch = (struct fat_arch *)[fatArchs mutableBytes];
        for (int i = 0; i < nfat_arch; i++) {
          int offset = OSSwapBigToHostInt32(fat_arch[i].offset);
          int size = OSSwapBigToHostInt32(fat_arch[i].size);
          int cputype = OSSwapBigToHostInt(fat_arch[i].cputype);

          range = NSMakeRange(offset, size);
          NSData *machHeader = [self parseSingleMachHeader:[self safeSubdataWithRange:range]];
          if (machHeader) {
            NSString *key = [self nameForCPUType:cputype];
            MachHeaderWithOffset *mhwo = [[MachHeaderWithOffset alloc] initWithData:machHeader
                                                                             offset:offset];
            machHeaders[key] = mhwo;
          }
        }
      }
    }
  }

  self.cachedHeaders = [machHeaders copy];
  return self.cachedHeaders;
}

- (NSData *)parseSingleMachHeader:(NSData *)inputData {
  if (inputData.length < sizeof(struct mach_header)) return nil;
  struct mach_header *mh = (struct mach_header *)[inputData bytes];

  if (mh->magic == MH_CIGAM || mh->magic == MH_CIGAM_64) {
    NSMutableData *mutableInput = [inputData mutableCopy];
    mh = (struct mach_header *)[mutableInput mutableBytes];
    swap_mach_header(mh, NXHostByteOrder());
  }

  if (mh->magic == MH_MAGIC || mh->magic == MH_MAGIC_64) {
    return [NSData dataWithBytes:mh length:sizeof(struct mach_header)];
  }

  return nil;
}

///
///  Locate an embedded plist in the file
///
- (NSDictionary *)embeddedPlist {
  // Look for an embedded Info.plist if there is one.
  // This could (and used to) use CFBundleCopyInfoDictionaryForURL but that uses mmap to read
  // the file and so can cause SIGBUS if the file is deleted/truncated while it's working.
  MachHeaderWithOffset *mhwo = [[self.machHeaders allValues] firstObject];
  if (!mhwo) return nil;

  struct mach_header *mh = (struct mach_header *)mhwo.data.bytes;
  if (mh->filetype != MH_EXECUTE) return self.infoDict;
  BOOL is64 = (mh->magic == MH_MAGIC_64 || mh->magic == MH_CIGAM_64);
  uint32_t ncmds = mh->ncmds;
  uint32_t nsects = 0;
  uint64_t offset = mhwo.offset;

  uint32_t sz_header = is64 ? sizeof(struct mach_header_64) : sizeof(struct mach_header);
  uint32_t sz_segment = is64 ? sizeof(struct segment_command_64) : sizeof(struct segment_command);
  uint32_t sz_section = is64 ? sizeof(struct section_64) : sizeof(struct section);

  offset += sz_header;

  // Loop through the load commands looking for the segment named __TEXT
  for (uint32_t i = 0; i < ncmds; i++) {
    NSData *cmdData = [self safeSubdataWithRange:NSMakeRange(offset, sz_segment)];
    if (!cmdData) return nil;
    struct segment_command_64 *lc = (struct segment_command_64 *)[cmdData bytes];
    if (lc->cmd == LC_SEGMENT || lc->cmd == LC_SEGMENT_64) {
      if (strncmp(lc->segname, "__TEXT", 6) == 0) {
        nsects = lc->nsects;
        offset += sz_segment;
        break;
      }
    }
    offset += lc->cmdsize;
  }

  // Loop through the sections in the __TEXT segment looking for an __info_plist section.
  for (uint32_t i = 0; i < nsects; i++) {
    NSData *sectData = [self safeSubdataWithRange:NSMakeRange(offset, sz_section)];
    if (!sectData) return nil;
    struct section_64 *sect = (struct section_64 *)[sectData bytes];
    if (sect && strncmp(sect->sectname, "__info_plist", 12) == 0 && sect->size < 2000000) {
      NSData *plistData = [self safeSubdataWithRange:NSMakeRange(sect->offset, sect->size)];
      if (!plistData) return nil;
      NSDictionary *plist;
      plist = [NSPropertyListSerialization propertyListWithData:plistData
                                                        options:NSPropertyListImmutable
                                                         format:NULL
                                                          error:NULL];
      if (plist) return plist;
    }
    offset += sz_section;
  }
  return nil;
}

///
///  Return the first mach_header in this file.
///
- (struct mach_header *)firstMachHeader {
  return (struct mach_header *)([[[[self.machHeaders allValues] firstObject] data] bytes]);
}

///
///  Extract a range of the file as an NSData, handling any exceptions.
///  Returns nil if the requested range is outside of the range of the file.
///
- (NSData *)safeSubdataWithRange:(NSRange)range {
  @try {
    if ((range.location + range.length) > self.fileSize) return nil;
    [self.fileHandle seekToFileOffset:range.location];
    NSData *d = [self.fileHandle readDataOfLength:range.length];
    if (d.length != range.length) return nil;
    return d;
  }
  @catch (NSException *e) {
    return nil;
  }
}

///
///  Retrieve quarantine data for a file and caches the dictionary
///
- (NSDictionary *)quarantineData {
  if (!self.quarantineDict && NSURLQuarantinePropertiesKey != NULL) {
    NSURL *url = [NSURL fileURLWithPath:self.path];
    NSDictionary *d = [url resourceValuesForKeys:@[ NSURLQuarantinePropertiesKey ] error:NULL];
    self.quarantineDict = d[NSURLQuarantinePropertiesKey];
    if (!self.quarantineDict) self.quarantineDict = (NSDictionary *)[NSNull null];
  }
  return (self.quarantineDict == (NSDictionary *)[NSNull null]) ? nil : self.quarantineDict;
}

///
///  Return a human-readable string for a cpu_type_t.
///
- (NSString *)nameForCPUType:(cpu_type_t)cpuType {
  switch (cpuType) {
    case CPU_TYPE_X86:
      return @"i386";
    case CPU_TYPE_X86_64:
      return @"x86-64";
    case CPU_TYPE_POWERPC:
      return @"ppc";
    case CPU_TYPE_POWERPC64:
      return @"ppc64";
    default:
      return @"unknown";
  }
  return nil;
}

///
///  Resolves a given path:
///    + Follows symlinks
///    + Converts relative paths to absolute
///    + If path is a directory, checks to see if that directory is a bundle and if so
///      returns the path to that bundles CFBundleExecutable.
///
- (NSString *)resolvePath:(NSString *)path {
  // Convert to absolute, standardized path
  path = [path stringByResolvingSymlinksInPath];
  if (![path isAbsolutePath]) {
    NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    path = [cwd stringByAppendingPathComponent:path];
  }
  path = [path stringByStandardizingPath];

  // Determine if file exists.
  // If path is actually a directory, check to see if it's a bundle and has a CFBundleExecutable.
  BOOL directory;
  if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&directory]) {
    return nil;
  } else if (directory) {
    NSString *infoPath = [path stringByAppendingPathComponent:@"Contents/Info.plist"];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:infoPath];
    if (d && d[@"CFBundleExecutable"]) {
      path = [path stringByAppendingPathComponent:@"Contents/MacOS"];
      return [path stringByAppendingPathComponent:d[@"CFBundleExecutable"]];
    } else {
      return nil;
    }
  } else {
    return path;
  }
}

@end
