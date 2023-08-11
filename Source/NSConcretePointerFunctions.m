/**Implementation for NSConcretePointerFunctions for GNUStep
   Copyright (C) 2009 Free Software Foundation, Inc.

   Written by:  Richard Frith-Macdonald <rfm@gnu.org>
   Date:	2009

   This file is part of the GNUstep Base Library.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this library; if not, write to the Free
   Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
   Boston, MA 02110 USA.

   */

#import "common.h"
#import "NSConcretePointerFunctions.h"

static void *
acquireMallocMemory(const void *item,
                    NSUInteger (*size)(const void *item), BOOL shouldCopy)
{
    if (shouldCopy == YES) {
        NSUInteger len = (*size)(item);
        void *newItem = malloc(len);

        memcpy(newItem, item, len);
        item = newItem;
    }
    return (void *)item;
}

static void *
acquireRetainedObject(const void *item,
                      NSUInteger (*size)(const void *item), BOOL shouldCopy)
{
    if (shouldCopy == YES) {
        return [(NSObject *)item copy];
    }
    return [(NSObject *)item retain];
}

static void *
acquireExistingMemory(const void *item,
                      NSUInteger (*size)(const void *item), BOOL shouldCopy)
{
    return (void *)item;
}

static NSString *
describeString(const void *item)
{
    return [NSString stringWithFormat:@"%s", (char *)item];
}

static NSString *
describeInteger(const void *item)
{
    return [NSString stringWithFormat:@"%" PRIdPTR, (intptr_t)item];
}

static NSString *
describeObject(const void *item)
{
    return [(NSObject *)item description];
}

static NSString *
describePointer(const void *item)
{
    return [NSString stringWithFormat:@"%p", item];
}

static BOOL
equalDirect(const void *item1, const void *item2,
            NSUInteger (*size)(const void *item))
{
    return (item1 == item2) ? YES : NO;
}

static BOOL
equalObject(const void *item1, const void *item2,
            NSUInteger (*size)(const void *item))
{
    return [(NSObject *)item1 isEqual:(NSObject *)item2];
}

static BOOL
equalMemory(const void *item1, const void *item2,
            NSUInteger (*size)(const void *item))
{
    NSUInteger s1 = (*size)(item1);
    NSUInteger s2 = (*size)(item2);

    return (s1 == s2 && memcmp(item1, item2, s1) == 0) ? YES : NO;
}

static BOOL
equalString(const void *item1, const void *item2,
            NSUInteger (*size)(const void *item))
{
    return (strcmp((const char *)item1, (const char *)item2) == 0) ? YES : NO;
}

static NSUInteger
hashDirect(const void *item, NSUInteger (*size)(const void *item))
{
    return (NSUInteger)(uintptr_t)item;
}

static NSUInteger
hashObject(const void *item, NSUInteger (*size)(const void *item))
{
    return [(NSObject *)item hash];
}

static NSUInteger
hashMemory(const void *item, NSUInteger (*size)(const void *item))
{
    unsigned len = (*size)(item);
    NSUInteger hash = 0;

    while (len-- > 0) {
        hash = (hash << 5) + hash + *(const uint8_t *)item++;
    }
    return hash;
}

static NSUInteger
hashShifted(const void *item, NSUInteger (*size)(const void *item))
{
    return ((NSUInteger)(uintptr_t)item) >> 2;
}

static NSUInteger
hashString(const void *item, NSUInteger (*size)(const void *item))
{
    NSUInteger hash = 0;

    while (*(const uint8_t *)item != 0) {
        hash = (hash << 5) + hash + *(const uint8_t *)item++;
    }
    return hash;
}

static void
relinquishMallocMemory(const void *item,
                       NSUInteger (*size)(const void *item))
{
    free((void *)item);
}

static void
relinquishRetainedMemory(const void *item,
                         NSUInteger (*size)(const void *item))
{
    [(NSObject *)item release];
}

@implementation NSConcretePointerFunctions

+ (id)allocWithZone:(NSZone *)zone
{
    return (id)NSAllocateObject(self, 0, zone);
}

- (id)copyWithZone:(NSZone *)zone
{
    return NSCopyObject(self, 0, zone);
}

- (id)initWithOptions:(NSPointerFunctionsOptions)options
{
    _x.options = options;

    NSUInteger memoryOption = memoryType(options);
    NSUInteger personalityOption = personalityType(options);
    BOOL copyIn = isCopyIn(options);

    if (memoryOption == NSPointerFunctionsOpaqueMemory && copyIn) {
        NSLog(@"ERROR: Unsupported use of NSPointerFunctionsCopyIn with NSPointerFunctionsOpaqueMemory");
        NSParameterAssert(NO);
        return nil;
    }

    switch (memoryType) {
        case NSPointerFunctionsStrongMemory: {
            // Default option (0)
            _x.acquireFunction = acquireRetainedObject;
            _x.relinquishFunction = relinquishRetainedMemory;
        } break;
        case NSPointerFunctionsZeroingWeakMemory: {
            NSLog(@"ERROR: Unsupported NSPointerFunctionsOptions option NSPointerFunctionsZeroingWeakMemory");
            NSParameterAssert(NO);
            return nil;
        } break;
        case NSPointerFunctionsOpaqueMemory: {
            _x.acquireFunction = nil;
            _x.relinquishFunction = nil;
        } break;
        case NSPointerFunctionsMallocMemory: {
            NSLog(@"ERROR: Unsupported NSPointerFunctionsOptions option NSPointerFunctionsMallocMemory");
            NSParameterAssert(NO);
            return nil;
        } break;
        case NSPointerFunctionsMachVirtualMemory: {
            NSLog(@"ERROR: Unsupported NSPointerFunctionsOptions option NSPointerFunctionsMachVirtualMemory");
            NSParameterAssert(NO);
            return nil;
        } break;
        case NSPointerFunctionsWeakMemory: {
            _x.acquireFunction = nil;
            _x.relinquishFunction = nil;
        } break;
    }

    switch (personalityType) {
        case NSPointerFunctionsObjectPersonality: {
            // Default option (0)
            _x.descriptionFunction = describeObject;
            _x.hashFunction = hashObject;
            _x.isEqualFunction = equalObject;
        } break;
        case NSPointerFunctionsOpaquePersonality: {
            _x.descriptionFunction = describePointer;
            _x.hashFunction = hashDirect;
            _x.isEqualFunction = equalDirect;
        } break;
        case NSPointerFunctionsObjectPointerPersonality: {
            _x.descriptionFunction = describeObject;
            _x.hashFunction = hashShifted;
            _x.isEqualFunction = equalDirect;
        } break;
        case NSPointerFunctionsCStringPersonality: {
            NSLog(@"ERROR: Unsupported NSPointerFunctionsOptions option NSPointerFunctionsCStringPersonality");
            NSParameterAssert(NO);
            return nil;
        } break;
        case NSPointerFunctionsStructPersonality: {
            NSLog(@"ERROR: Unsupported NSPointerFunctionsOptions option NSPointerFunctionsStructPersonality");
            NSParameterAssert(NO);
            return nil;
        } break;
        case NSPointerFunctionsIntegerPersonality: {
            NSLog(@"ERROR: Unsupported NSPointerFunctionsOptions option NSPointerFunctionsIntegerPersonality");
            NSParameterAssert(NO);
            return nil;
        } break;
    }

    return self;
}

- (void *(*)(const void *item,
             NSUInteger (*size)(const void *item), BOOL shouldCopy))acquireFunction
{
    return _x.acquireFunction;
}

- (NSString *(*)(const void *item))descriptionFunction
{
    return _x.descriptionFunction;
}

- (NSUInteger (*)(const void *item,
                  NSUInteger (*size)(const void *item)))hashFunction
{
    return _x.hashFunction;
}

- (BOOL (*)(const void *item1, const void *item2,
            NSUInteger (*size)(const void *item)))isEqualFunction
{
    return _x.isEqualFunction;
}

- (void (*)(const void *item,
            NSUInteger (*size)(const void *item)))relinquishFunction
{
    return _x.relinquishFunction;
}

- (void)setAcquireFunction:(void *(*)(const void *item,
                                      NSUInteger (*size)(const void *item), BOOL shouldCopy))func
{
    _x.acquireFunction = func;
}

- (void)setDescriptionFunction:(NSString *(*)(const void *item))func
{
    _x.descriptionFunction = func;
}

- (void)setHashFunction:(NSUInteger (*)(const void *item,
                                        NSUInteger (*size)(const void *item)))func
{
    _x.hashFunction = func;
}

- (void)setIsEqualFunction:(BOOL (*)(const void *item1, const void *item2,
                                     NSUInteger (*size)(const void *item)))func
{
    _x.isEqualFunction = func;
}

- (void)setRelinquishFunction:(void (*)(const void *item,
                                        NSUInteger (*size)(const void *item)))func
{
    _x.relinquishFunction = func;
}

- (NSUInteger (*)(const void *item))sizeFunction
{
    NSLog(@"Error: Unsupported NSPointerFunctions property sizeFunction");
    NSParameterAssert(NO);
    return nil;
}

- (void)setSizeFunction:(NSUInteger (*)(const void *item))func
{
    NSLog(@"Error: Unsupported NSPointerFunctions property sizeFunction");
    NSParameterAssert(NO);
}

- (BOOL)usesStrongWriteBarrier
{
    NSLog(@"ERROR: Unsupported NSPointerFunctions property usesStrongWriteBarrier");
    NSParameterAssert(NO);
    return NO;
}

- (void)setUsesStrongWriteBarrier:(BOOL)flag
{
    NSLog(@"ERROR: Unsupported NSPointerFunctions property usesStrongWriteBarrier");
    NSParameterAssert(NO);
}

- (BOOL)usesWeakReadAndWriteBarriers
{
    NSLog(@"ERROR: Unsupported NSPointerFunctions property usesWeakReadAndWriteBarriers");
    NSParameterAssert(NO);
    return NO;
}

- (void)setUsesWeakReadAndWriteBarriers:(BOOL)flag
{
    NSLog(@"ERROR: Unsupported NSPointerFunctions property usesWeakReadAndWriteBarriers");
    NSParameterAssert(NO);
}

@end
