/** NSCalendar.m

   Copyright (C) 2010 Free Software Foundation, Inc.

   Written by: Stefan Bidigaray
   Date: December, 2010

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this library; see the file COPYING.LIB.
   If not, see <http://www.gnu.org/licenses/> or write to the
   Free Software Foundation, 51 Franklin Street, Fifth Floor,
   Boston, MA 02110-1301, USA.
*/

#import "common.h"
#import "Foundation/NSCalendar.h"
#import "Foundation/NSCoder.h"
#import "Foundation/NSDate.h"
#import "Foundation/NSDictionary.h"
#import "Foundation/NSException.h"
#import "Foundation/NSLocale.h"
#import "Foundation/NSNotification.h"
#import "Foundation/NSString.h"
#import "Foundation/NSTimeZone.h"
#import "Foundation/NSUserDefaults.h"
#import "GNUstepBase/GSLock.h"

#if defined(HAVE_UNICODE_UCAL_H)
#define id ucal_id
#include <unicode/ucal.h>
#include <unicode/uvernum.h>
#undef id
#elif defined(HAVE_ICU_H)
#include <icu.h>
#endif

GS_DECLARE const NSInteger NSDateComponentUndefined = NSIntegerMax;
GS_DECLARE const NSInteger NSUndefinedDateComponent = NSDateComponentUndefined;

const NSUInteger AllCalendarUnits =
      NSCalendarUnitEra
    | NSCalendarUnitYear
    | NSCalendarUnitMonth
    | NSCalendarUnitDay
    | NSCalendarUnitHour
    | NSCalendarUnitMinute
    | NSCalendarUnitSecond
    | NSCalendarUnitWeekday
    | NSCalendarUnitWeekdayOrdinal
    | NSCalendarUnitWeekOfMonth
    | NSCalendarUnitWeekOfYear
    | NSCalendarUnitYearForWeekOfYear
    | NSCalendarUnitNanosecond
    | NSCalendarUnitCalendar
    | NSCalendarUnitTimeZone;

#if GS_USE_ICU == 1
static UCalendarDateFields _NSCalendarUnitToDateField(NSCalendarUnit unit)
{
  if (unit & NSCalendarUnitEra)
    return UCAL_ERA;
  if (unit & NSCalendarUnitYear)
    return UCAL_YEAR;
  if (unit & NSCalendarUnitMonth)
    return UCAL_MONTH;
  if (unit & NSCalendarUnitDay)
    return UCAL_DAY_OF_MONTH;
  if (unit & NSCalendarUnitHour)
    return UCAL_HOUR_OF_DAY;
  if (unit & NSCalendarUnitMinute)
    return UCAL_MINUTE;
  if (unit & NSCalendarUnitSecond)
    return UCAL_SECOND;
  if (unit & NSCalendarUnitWeekOfYear)
    return UCAL_WEEK_OF_YEAR;
  if (unit & NSCalendarUnitWeekday)
    return UCAL_DAY_OF_WEEK;
  if (unit & NSCalendarUnitWeekdayOrdinal)
    return UCAL_DAY_OF_WEEK_IN_MONTH;
  return (UCalendarDateFields)-1;
}
#endif /* GS_USE_ICU */

typedef struct {
  NSString      *identifier;
  NSString      *localeID;
  NSTimeZone    *tz;
  void          *cal;
  NSInteger     firstWeekday;
  NSInteger     minimumDaysInFirstWeek;
} Calendar;
#define my ((Calendar*)_NSCalendarInternal)

@interface NSCalendar (PrivateMethods)
#if GS_USE_ICU == 1
- (void *) _locked_openCalendarFor: (NSTimeZone *)timeZone;
// Ensures that the calendar is initialized for the current time zone
// and returns a clone of it
- (void *) _locked_cloneCalendar:(UErrorCode *)err; 
#endif
- (void) _locked_resetCalendar;
- (NSString *) _localeIDWithLocale: (NSLocale*)locale;
- (NSString *) _localeIdentifier;
- (void) _setLocaleIdentifier: (NSString*)identifier;
@end

static NSCalendar *currentCalendar = nil;
static NSCalendar *autoupdatingCalendar = nil;
static NSRecursiveLock *classLock = nil;

#define TZ_NAME_LENGTH 1024
#define SECOND_TO_MILLI 1000.0
#define MILLI_TO_NANO 1000000

@implementation NSCalendar (PrivateMethods)

- (BOOL) _needsRefreshForLocale: (NSString *)locale
                       calendar: (NSString *)calendar
                       timeZone: (NSString *)timeZone
{
    BOOL needsToRefresh;

    [_lock lock];
    
    needsToRefresh = [locale isEqual:my->localeID] == NO
            || [calendar isEqual:my->identifier] == NO
            || [timeZone isEqual:[my->tz name]] == NO;

    [_lock unlock];
    
    return needsToRefresh;
}

- (BOOL) _needsRefreshForDefaultsChangeNotification: (NSNotification *)n
{
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    NSString *locale = [defs stringForKey:@"Locale"];
    NSString *calendar = [defs stringForKey:@"Calendar"];
    NSString *tz = [defs stringForKey:@"Local Time Zone"];
    BOOL needsToRefresh = [self _needsRefreshForLocale:locale calendar:calendar timeZone:tz];
    
    return needsToRefresh;
}

+ (void) _refreshCurrentCalendarFromDefaultsDidChange: (NSNotification*)n
{
    [classLock lock];

    if (currentCalendar != nil)
      {
        BOOL needToRefreshCurrentCalendar = [currentCalendar _needsRefreshForDefaultsChangeNotification:n];

        if (needToRefreshCurrentCalendar)
          {
            RELEASE(currentCalendar);
            currentCalendar = nil;
          }
      }

    [classLock unlock];
}

#if GS_USE_ICU == 1
- (void *) _locked_openCalendarFor: (NSTimeZone *)timeZone
{
    NSString *tzName;
    NSUInteger tzLen;
    unichar cTzId[TZ_NAME_LENGTH];
    const char *cLocaleId;
    UErrorCode err = U_ZERO_ERROR;
    UCalendarType type;

    cLocaleId = [my->localeID UTF8String];
    tzName = [timeZone name];
    tzLen = [tzName length];

    if (tzLen > TZ_NAME_LENGTH)
      {
        tzLen = TZ_NAME_LENGTH;
      }

    [tzName getCharacters:cTzId range:NSMakeRange(0, tzLen)];

    if ([NSGregorianCalendar isEqualToString:my->identifier])
      {
        type = UCAL_GREGORIAN;
      }
    else
      {
#ifndef UCAL_DEFAULT
        /*
         * Older versions of ICU used UCAL_TRADITIONAL rather than UCAL_DEFAULT
         * so if one is not available we use the other.
         */
        type = UCAL_TRADITIONAL;
#else
        type = UCAL_DEFAULT;
#endif
        // We do not need to call uloc_setKeywordValue() here to set the calendar
        // on the locale as the calendar is already encoded in the locale id by
        // _localeIDWithLocale:.
      }

    return ucal_open((const UChar *)cTzId, tzLen, cLocaleId, type, &err);
}

- (void *) _locked_cloneCalendar:(UErrorCode *)err
{
    if (my->cal == NULL)
	  {
	    [self _locked_resetCalendar];
	  }
	  
	return ucal_clone(my->cal, err);
}
#endif

- (void) _locked_resetCalendar
{
#if GS_USE_ICU == 1
    if (my->cal != NULL)
      {
        ucal_close(my->cal);
      }

    my->cal = [self _locked_openCalendarFor:my->tz];

    my->firstWeekday = NSNotFound;
    my->minimumDaysInFirstWeek = NSNotFound;

    if (NSNotFound == my->firstWeekday)
      {
        my->firstWeekday = ucal_getAttribute(my->cal, UCAL_FIRST_DAY_OF_WEEK);
      }
	else
      {
        ucal_setAttribute(my->cal, UCAL_FIRST_DAY_OF_WEEK, (int32_t)my->firstWeekday);
      }

    if (NSNotFound == my->minimumDaysInFirstWeek)
      {
        my->minimumDaysInFirstWeek = ucal_getAttribute(my->cal, UCAL_MINIMAL_DAYS_IN_FIRST_WEEK);
      }
    else
      {
        ucal_setAttribute(my->cal, UCAL_MINIMAL_DAYS_IN_FIRST_WEEK, (int32_t)my->minimumDaysInFirstWeek);
      }
#endif
}

- (NSString*) _localeIDWithLocale:(NSLocale *)locale
{
    NSString *result;
    NSString *localeId;
    NSMutableDictionary *tmpDict;

    [_lock lock];
    localeId = [locale localeIdentifier];
    if (my->identifier) {
        tmpDict = [[NSLocale componentsFromLocaleIdentifier:localeId] mutableCopyWithZone:NULL];
        [tmpDict removeObjectForKey:NSLocaleCalendar];
        [tmpDict setObject:my->identifier forKey:NSLocaleCalendarIdentifier];
        result = [NSLocale localeIdentifierFromComponents:tmpDict];
        RELEASE(tmpDict);
    } else {
        result = localeId;
    }
    [_lock unlock];

    return result;
}

- (NSString*) _localeIdentifier
{
    NSString *localeIdentifier;

    [_lock lock];
    localeIdentifier = RETAIN(my->localeID);
    [_lock unlock];

    return AUTORELEASE(localeIdentifier);
}

- (void) _setLocaleIdentifier: (NSString *)identifier
{
    [_lock lock];
    if ([identifier isEqualToString:my->localeID]) {
        [_lock unlock];
        return;
    }

    ASSIGN(my->localeID, identifier);
    [self _locked_resetCalendar];
    [_lock unlock];
}

- (void) _defaultsDidChange: (NSNotification*)n
{
    BOOL needsToRefresh;
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    NSString *locale = [defs stringForKey:@"Locale"];
    NSString *calendar = [defs stringForKey:@"Calendar"];
    NSString *tz = [defs stringForKey:@"Local Time Zone"];

    [classLock lock];
    [_lock lock];

    needsToRefresh = [self _needsRefreshForLocale:locale calendar:calendar timeZone:tz];

    if (needsToRefresh)
      {
#if GS_USE_ICU == 1
        if (my->cal != NULL)
          {
            ucal_close(my->cal);
            my->cal = NULL;
          }
#endif

        ASSIGN(my->localeID, locale);
        ASSIGN(my->identifier, calendar);
        RELEASE(my->tz);
        my->tz = [[NSTimeZone alloc] initWithName:tz];

        [self _locked_resetCalendar];
    }

    [_lock unlock];
    [classLock unlock];
}
@end

@implementation NSCalendar

+ (void) initialize
{
    if (self == [NSCalendar class])
      {
        classLock = [NSRecursiveLock new];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_refreshCurrentCalendarFromDefaultsDidChange:)
                                                     name:NSUserDefaultsDidChangeNotification
                                                   object:nil];
      }
}

+ (id) currentCalendar
{
  NSCalendar *result;

  [classLock lock];

  if (currentCalendar == nil)
    {
      // This identifier may be nil
      NSString *identifier = [[NSLocale currentLocale] objectForKey:NSLocaleCalendarIdentifier];

      currentCalendar = [[NSCalendar alloc] initWithCalendarIdentifier:identifier];
    }

    result = AUTORELEASE([currentCalendar copy]);

    [classLock unlock];

    return result;
}

+ (id) autoupdatingCurrentCalendar
{
  if (autoupdatingCalendar != nil)
    {
      return AUTORELEASE(RETAIN(autoupdatingCalendar));
    }

  [classLock lock];

  if (nil == autoupdatingCalendar)
    {
      ASSIGN(autoupdatingCalendar, [self currentCalendar]);
      [[NSNotificationCenter defaultCenter] addObserver:autoupdatingCalendar
                                               selector:@selector(_defaultsDidChange:)
                                                   name:NSUserDefaultsDidChangeNotification
                                                 object:nil];
    }

  [classLock unlock];

  return AUTORELEASE(RETAIN(autoupdatingCalendar));
}

+ (id) calendarWithIdentifier:(NSString *)identifier
{
    return AUTORELEASE([[self alloc] initWithCalendarIdentifier:identifier]);
}

- (id) init
{
    return [self initWithCalendarIdentifier:nil];
}

- (id) initWithCalendarIdentifier: (NSString *) identifier
{
    NSAssert(0 == _NSCalendarInternal, NSInvalidArgumentException);
    _NSCalendarInternal = NSZoneCalloc([self zone], sizeof(Calendar), 1);
    _lock = [[NSRecursiveLock alloc] init];

    if (identifier != NULL) {
        [_lock setName:[NSString stringWithFormat:@"NSCalendar.%@", identifier]];
    } else {
        [_lock setName:@"NSCalendar"];
    }
    my->firstWeekday = NSNotFound;
    my->minimumDaysInFirstWeek = NSNotFound;
    ASSIGN(my->identifier, identifier);
    ASSIGN(my->tz, [NSTimeZone defaultTimeZone]);
    my->cal = NULL;
    [self setLocale:[NSLocale currentLocale]];

    return self;
}

- (void) dealloc
{
    if (0 != _NSCalendarInternal) {
        [_lock lock];
#if GS_USE_ICU == 1
        if (my->cal != NULL) {
            ucal_close(my->cal);
            my->cal = NULL;
        }
#endif
        RELEASE(my->identifier);
        RELEASE(my->localeID);
        RELEASE(my->tz);
        NSZoneFree([self zone], _NSCalendarInternal);
        [_lock unlock];
        RELEASE(_lock);
    }
    [super dealloc];
}

- (NSString *) calendarIdentifier
{
    NSString *calendarIdentifier;

    [_lock lock];
    calendarIdentifier = RETAIN(my->identifier);
    [_lock unlock];

    return AUTORELEASE(calendarIdentifier);
}

- (NSInteger) component: (NSCalendarUnit)unit 
               fromDate: (NSDate *)date
{
    NSDateComponents *comps = [self components:unit fromDate:date];
    NSInteger val = 0;

    switch (unit) {
        case NSCalendarUnitEra:
            val = [comps era];
            break;
        case NSCalendarUnitYear:
            val = [comps year];
            break;
        case NSCalendarUnitMonth:
            val = [comps month];
            break;
        case NSCalendarUnitDay:
            val = [comps day];
            break;
        case NSCalendarUnitHour:
            val = [comps hour];
            break;
        case NSCalendarUnitMinute:
            val = [comps minute];
            break;
        case NSCalendarUnitSecond:
            val = [comps second];
            break;
        case NSCalendarUnitWeekday:
            val = [comps weekday];
            break;
        case NSCalendarUnitWeekdayOrdinal:
            val = [comps weekdayOrdinal];
            break;
        case NSCalendarUnitQuarter:
            val = [comps quarter];
            break;
        case NSCalendarUnitWeekOfMonth:
            val = [comps weekOfMonth];
            break;
        case NSCalendarUnitWeekOfYear:
            val = [comps weekOfYear];
            break;
        case NSCalendarUnitYearForWeekOfYear:
            val = [comps yearForWeekOfYear];
            break;
        case NSCalendarUnitNanosecond:
            val = [comps nanosecond];
            break;
        case NSCalendarUnitCalendar:
        case NSCalendarUnitTimeZone:
            // in these cases do nothing since they are undefined.
            break;
    }

    return val;
}

- (NSDateComponents *) components: (NSUInteger) unitFlags
                         fromDate: (NSDate *) date
{
#if GS_USE_ICU == 1
    NSDateComponents *comps;
    UErrorCode err = U_ZERO_ERROR;
    UDate udate;

    [_lock lock];
    udate = (UDate)floor([date timeIntervalSince1970] * SECOND_TO_MILLI);
    ucal_setMillis(my->cal, udate, &err);

    if (U_FAILURE(err))
	  {
        [_lock unlock];
        return nil;
      }

    comps = [[NSDateComponents alloc] init];

    if (unitFlags & NSCalendarUnitEra)
      {
        [comps setEra:ucal_get(my->cal, UCAL_ERA, &err)];
      }

    if (unitFlags & NSCalendarUnitYear)
      {
        [comps setYear:ucal_get(my->cal, UCAL_YEAR, &err)];
      }

    if (unitFlags & NSCalendarUnitMonth)
      {
        [comps setMonth:ucal_get(my->cal, UCAL_MONTH, &err) + 1];
      }

    if (unitFlags & NSCalendarUnitDay)
      {
        [comps setDay:ucal_get(my->cal, UCAL_DAY_OF_MONTH, &err)];
      }

    if (unitFlags & NSCalendarUnitHour)
      {
        [comps setHour:ucal_get(my->cal, UCAL_HOUR_OF_DAY, &err)];
      }

    if (unitFlags & NSCalendarUnitMinute)
      {
        [comps setMinute:ucal_get(my->cal, UCAL_MINUTE, &err)];
      }

    if (unitFlags & NSCalendarUnitSecond)
      {
        [comps setSecond:ucal_get(my->cal, UCAL_SECOND, &err)];
      }

    if (unitFlags & (NSWeekCalendarUnit | NSCalendarUnitWeekOfYear))
      {
        [comps setWeek:ucal_get(my->cal, UCAL_WEEK_OF_YEAR, &err)];
      }

    if (unitFlags & NSCalendarUnitWeekday)
      {
        [comps setWeekday:ucal_get(my->cal, UCAL_DAY_OF_WEEK, &err)];
      }

    if (unitFlags & NSCalendarUnitWeekdayOrdinal)
      {
        [comps setWeekdayOrdinal:ucal_get(my->cal, UCAL_DAY_OF_WEEK_IN_MONTH, &err)];
      }

    if (unitFlags & NSCalendarUnitQuarter)
      {
        [comps setQuarter:(ucal_get(my->cal, UCAL_MONTH, &err) + 3) / 3];
      }

    if (unitFlags & NSCalendarUnitWeekOfMonth)
      {
        [comps setWeekOfMonth:ucal_get(my->cal, UCAL_WEEK_OF_MONTH, &err)];
      }

    if (unitFlags & NSCalendarUnitYearForWeekOfYear)
      {
        [comps setYearForWeekOfYear:ucal_get(my->cal, UCAL_YEAR_WOY, &err)];
      }

    if (unitFlags & NSCalendarUnitNanosecond)
      {
        [comps setNanosecond:ucal_get(my->cal, UCAL_MILLISECOND, &err) * MILLI_TO_NANO];
      }

    [_lock unlock];

    return AUTORELEASE(comps);
#else
    return nil;
#endif
}

/*
 * Convenience macro for field extraction.
 * TODO: We need to implement NSWrapCalendarComponents,
 * but it is unclear how that actually works.
 */
#define COMPONENT_DIFF(cal, units, components, toDate, nsunit, setSel, uunit,        \
                       err)                                                          \
    do {                                                                             \
        if (nsunit == (units & nsunit)) {                                            \
            int32_t uunit##Diff = ucal_getFieldDifference(cal, toDate, uunit, &err); \
            if (U_FAILURE(err)) {                                                    \
                RELEASE(components);                                                 \
                [_lock unlock];                                                      \
                return nil;                                                          \
            }                                                                        \
            [components setSel uunit##Diff];                                         \
        }                                                                            \
    } while (0)

- (NSDateComponents *) components: (NSUInteger) unitFlags
                         fromDate: (NSDate *) startingDate
                           toDate: (NSDate *) resultDate
                          options: (NSUInteger) opts
{
#if GS_USE_ICU == 1 &&                                                 \
    (U_ICU_VERSION_MAJOR_NUM > 4 ||                                    \
     (U_ICU_VERSION_MAJOR_NUM == 4 && U_ICU_VERSION_MINOR_NUM >= 8) || \
     defined(HAVE_ICU_H))

    NSDateComponents *comps = nil;
    UErrorCode err = U_ZERO_ERROR;
    UDate udateFrom = (UDate)floor([startingDate timeIntervalSince1970] * SECOND_TO_MILLI);
    UDate udateTo = (UDate)floor([resultDate timeIntervalSince1970] * SECOND_TO_MILLI);

    [_lock lock];
    ucal_setMillis(my->cal, udateFrom, &err);
    if (U_FAILURE(err)) {
        [_lock unlock];
        return nil;
    }
    comps = [[NSDateComponents alloc] init];
    /*
     * Since the ICU field difference function automatically advances
     * the calendar as appropriate, we need to process the units from
     * the largest to the smallest.
     */
    COMPONENT_DIFF(my->cal, unitFlags, comps, udateTo, NSCalendarUnitEra, setEra:, UCAL_ERA, err);
    COMPONENT_DIFF(my->cal, unitFlags, comps, udateTo, NSCalendarUnitYear, setYear:, UCAL_YEAR, err);
    COMPONENT_DIFF(my->cal, unitFlags, comps, udateTo, NSCalendarUnitMonth, setMonth:, UCAL_MONTH, err);
    COMPONENT_DIFF(my->cal, unitFlags, comps, udateTo, NSCalendarUnitWeekOfYear, setWeek:, UCAL_WEEK_OF_YEAR, err);
    if (!(unitFlags & NSCalendarUnitWeekOfYear)) {
        /* We must avoid setting the same unit twice (it would be zero because
         * of the automatic advancement.
         */
        COMPONENT_DIFF(my->cal, unitFlags, comps, udateTo, NSWeekCalendarUnit, setWeek:, UCAL_WEEK_OF_YEAR, err);
    }
    COMPONENT_DIFF(my->cal, unitFlags, comps, udateTo, NSCalendarUnitWeekOfMonth, setWeekOfMonth:, UCAL_WEEK_OF_MONTH, err);
    COMPONENT_DIFF(my->cal, unitFlags, comps, udateTo, NSCalendarUnitDay, setDay:, UCAL_DAY_OF_MONTH, err);
    COMPONENT_DIFF(my->cal, unitFlags, comps, udateTo, NSCalendarUnitWeekdayOrdinal, setWeekdayOrdinal:, UCAL_DAY_OF_WEEK_IN_MONTH, err);
    COMPONENT_DIFF(my->cal, unitFlags, comps, udateTo, NSCalendarUnitWeekday, setWeekday:, UCAL_DAY_OF_WEEK, err);
    COMPONENT_DIFF(my->cal, unitFlags, comps, udateTo, NSCalendarUnitHour, setHour:, UCAL_HOUR_OF_DAY, err);
    COMPONENT_DIFF(my->cal, unitFlags, comps, udateTo, NSCalendarUnitMinute, setMinute:, UCAL_MINUTE, err);
    COMPONENT_DIFF(my->cal, unitFlags, comps, udateTo, NSCalendarUnitSecond, setSecond:, UCAL_SECOND, err);
    if (unitFlags & NSCalendarUnitNanosecond) {
        int32_t ms;

        ms = ucal_getFieldDifference(my->cal, udateTo, UCAL_MILLISECOND, &err);
        if (U_FAILURE(err)) {
            RELEASE(comps);
            [_lock unlock];
            return nil;
        }
        [comps setNanosecond:ms * MILLI_TO_NANO];
    }
    [_lock unlock];

    return AUTORELEASE(comps);
#else
    return nil;
#endif
}

#undef COMPONENT_DIFF

#define _ADD_COMPONENT(c, n)             \
    if (opts & NSWrapCalendarComponents) \
        ucal_roll(cal, c, n, &err);  \
    else                                 \
        ucal_add(cal, c, n, &err);   \
    if (U_FAILURE(err)) {                \
        ucal_close(cal);                  \
        return nil;                      \
    }

- (NSDate *) dateByAddingComponents: (NSDateComponents *) comps
                             toDate: (NSDate *) date
                            options: (NSUInteger) opts
{
#if GS_USE_ICU == 1
	void *cal;
    NSInteger amount;
    UErrorCode err = U_ZERO_ERROR;
    UDate udate;

    [_lock lock];
    cal = [self _locked_cloneCalendar:&err];
	[_lock unlock];
	
	if (U_FAILURE(err))
      {
	    return nil;
      }

    udate = (UDate)([date timeIntervalSince1970] * SECOND_TO_MILLI);
    ucal_setMillis(cal, udate, &err);

    if ((amount = [comps era]) != NSDateComponentUndefined)
      {
        _ADD_COMPONENT(UCAL_ERA, (int32_t)amount);
      }

    if ((amount = [comps year]) != NSDateComponentUndefined)
      {
        _ADD_COMPONENT(UCAL_YEAR, (int32_t)amount);
      }

    if ((amount = [comps month]) != NSDateComponentUndefined)
      {
        _ADD_COMPONENT(UCAL_MONTH, (int32_t)amount);
      }

    if ((amount = [comps day]) != NSDateComponentUndefined)
      {
        _ADD_COMPONENT(UCAL_DAY_OF_MONTH, (int32_t)amount);
      }

    if ((amount = [comps hour]) != NSDateComponentUndefined)
      {
        _ADD_COMPONENT(UCAL_HOUR_OF_DAY, (int32_t)amount);
      }

    if ((amount = [comps minute]) != NSDateComponentUndefined)
      {
        _ADD_COMPONENT(UCAL_MINUTE, (int32_t)amount);
      }

    if ((amount = [comps second]) != NSDateComponentUndefined)
      {
        _ADD_COMPONENT(UCAL_SECOND, (int32_t)amount);
      }

    if ((amount = [comps week]) != NSDateComponentUndefined)
      {
        _ADD_COMPONENT(UCAL_WEEK_OF_YEAR, (int32_t)amount);
      }

    if ((amount = [comps weekday]) != NSDateComponentUndefined)
      {
        _ADD_COMPONENT(UCAL_DAY_OF_WEEK, (int32_t)amount);
      }

    if ((amount = [comps weekOfMonth]) != NSDateComponentUndefined)
      {
        _ADD_COMPONENT(UCAL_WEEK_OF_MONTH, (int32_t)amount);
      }

    if ((amount = [comps yearForWeekOfYear]) != NSDateComponentUndefined)
      {
        _ADD_COMPONENT(UCAL_YEAR_WOY, (int32_t)amount);
      }

    if ((amount = [comps nanosecond]) != NSDateComponentUndefined)
      {
        _ADD_COMPONENT(UCAL_MILLISECOND, (int32_t)(amount / MILLI_TO_NANO));
      }

    udate = ucal_getMillis(cal, &err);
	ucal_close(cal);

    if (U_FAILURE(err))
	  {
        return nil;
      }

    return [NSDate dateWithTimeIntervalSince1970:(udate / SECOND_TO_MILLI)];
#else
    return nil;
#endif
}

#undef _ADD_COMPONENT

- (NSDateComponents *)components:(NSCalendarUnit)unitFlags fromDateComponents:(NSDateComponents *)startingDateComp toDateComponents:(NSDateComponents *)resultDateComp options:(NSCalendarOptions)options
{
    NSDate *startDate;
    NSDate *toDate;
    NSCalendar *startCalendar;
    NSCalendar *toCalendar;

    startCalendar = [startingDateComp calendar];

    if (startCalendar) {
        startDate = [startCalendar dateFromComponents:startingDateComp];
    } else {
        startDate = [self dateFromComponents:startingDateComp];
    }

    toCalendar = [resultDateComp calendar];

    if (toCalendar) {
        toDate = [toCalendar dateFromComponents:resultDateComp];
    } else {
        toDate = [self dateFromComponents:resultDateComp];
    }

    if (startDate && toDate) {
        return [self components:unitFlags fromDate:startDate toDate:toDate options:options];
    }

    return nil;
}

- (NSDate *)dateByAddingUnit:(NSCalendarUnit)unit value:(NSInteger)value toDate:(NSDate *)date options:(NSCalendarOptions)options
{
    NSDateComponents *components = [[NSDateComponents alloc] init];
    NSDate *result;

    [components setValue:value forComponent:unit];
    result = [self dateByAddingComponents:components toDate:date options:options];
    RELEASE(components);
    return result;
}

static inline UCalendarDateFields NSCalendarUnitToUCalendarDateField(NSCalendarUnit unit, BOOL* out_success)
{
    *out_success = YES;

    switch (unit)
    {
        case NSCalendarUnitEra:
            return UCAL_ERA;
        case NSCalendarUnitYear:
            return UCAL_YEAR;
        case NSCalendarUnitMonth:
            return UCAL_MONTH;
        case NSCalendarUnitDay:
            return UCAL_DAY_OF_MONTH;
        case NSCalendarUnitHour:
            return UCAL_HOUR_OF_DAY;
        case NSCalendarUnitMinute:
            return UCAL_MINUTE;
        case NSCalendarUnitSecond:
            return UCAL_SECOND;
        case NSCalendarUnitWeekday:
            return UCAL_DAY_OF_WEEK;
        case NSCalendarUnitWeekdayOrdinal:
            return UCAL_DAY_OF_WEEK_IN_MONTH;
        case NSCalendarUnitWeekOfMonth:
            return UCAL_WEEK_OF_MONTH;
        case NSCalendarUnitWeekOfYear:
            return UCAL_WEEK_OF_YEAR;
        case NSCalendarUnitYearForWeekOfYear:
            return UCAL_YEAR_WOY;

        // No equivalent in ICU
        case NSCalendarUnitQuarter:
        case NSCalendarUnitNanosecond:
        case NSCalendarUnitCalendar:
        case NSCalendarUnitTimeZone:
        default:
            *out_success = NO;
            return 0;
    }
}

- (NSDate *)dateBySettingUnit:(NSCalendarUnit)unit value:(NSInteger)value ofDate:(NSDate *)date options:(NSCalendarOptions)opts
{
    void *cal;
	UErrorCode err = U_ZERO_ERROR;
    BOOL ok;
    UCalendarDateFields ucalField;
    NSTimeInterval epochTime;
    NSTimeInterval newEpochTime;

    [_lock lock];
    cal = [self _locked_cloneCalendar:&err];
	[_lock unlock];
	
	if (U_FAILURE(err))
      {
	    return nil;
      }

    ucal_clear(cal);

    // Convert to ICU-equivalent calendar unit
    ucalField = NSCalendarUnitToUCalendarDateField(unit, &ok);
    NSAssert(ok, @"GNUStep does not implement the given date field.");

    // Set the ICU calendar to this date
    epochTime = [date timeIntervalSince1970] * SECOND_TO_MILLI;
    ucal_setMillis(cal, epochTime, &err);
    NSAssert(!U_FAILURE(err), ([NSString stringWithFormat:@"Couldn't setMillis to calendar: %s", u_errorName(err)]));

    // Set the field on the ICU calendar
    ucal_set(cal, ucalField, value);

    // Get the date back from the ICU calendar
    newEpochTime = ucal_getMillis(cal, &err);
    ucal_close(cal);

    NSAssert(!U_FAILURE(err), ([NSString stringWithFormat:@"Couldn't getMillis from calendar: %s", u_errorName(err)]));

    return [NSDate dateWithTimeIntervalSince1970:(newEpochTime / SECOND_TO_MILLI)];
}

- (NSDate *)dateBySettingHour:(NSInteger)h minute:(NSInteger)m second:(NSInteger)s ofDate:(NSDate *)date options:(NSCalendarOptions)opts
{
    NSDateComponents *components = [self components:AllCalendarUnits fromDate:date];

    [components setHour:h];
    [components setMinute:m];
    [components setSecond:s];

    return [self dateFromComponents:components];
}

- (NSDate *)dateWithEra:(NSInteger)eraValue
                   year:(NSInteger)yearValue
                  month:(NSInteger)monthValue
                    day:(NSInteger)dayValue
                   hour:(NSInteger)hourValue
                 minute:(NSInteger)minuteValue
                 second:(NSInteger)secondValue
             nanosecond:(NSInteger)nanosecondValue
{
    NSDateComponents *components = [[NSDateComponents alloc] init];
    NSDate *result;

    [components setEra:eraValue];
    [components setYear:yearValue];
    [components setMonth:monthValue];
    [components setDay:dayValue];
    [components setHour:hourValue];
    [components setMinute:minuteValue];
    [components setSecond:secondValue];
    [components setNanosecond:nanosecondValue];

    result = [self dateFromComponents:components];
    RELEASE(components);
    return result;
}

- (NSDate *)dateWithEra:(NSInteger)eraValue 
      yearForWeekOfYear:(NSInteger)yearValue 
             weekOfYear:(NSInteger)weekValue 
                weekday:(NSInteger)weekdayValue 
                   hour:(NSInteger)hourValue 
                 minute:(NSInteger)minuteValue 
                 second:(NSInteger)secondValue 
             nanosecond:(NSInteger)nanosecondValue
{
    NSDateComponents *components = [[NSDateComponents alloc] init];
    NSDate *result;

    [components setEra:eraValue];
    [components setYear:yearValue];
    [components setWeek:weekValue];
    [components setWeekday:weekdayValue];
    [components setHour:hourValue];
    [components setMinute:minuteValue];
    [components setSecond:secondValue];
    [components setNanosecond:nanosecondValue];

    result = [self dateFromComponents:components];
    RELEASE(components);
    return result;
}

- (NSDate *)startOfDayForDate:(NSDate *)date
{
    NSDateComponents *components = [self components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:date];

    return [self dateFromComponents:components];
}

- (BOOL)isDate:(NSDate *)date1 inSameDayAsDate:(NSDate *)date2
{
    NSDateComponents *components1 = [self components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:date1];
    NSDateComponents *components2 = [self components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:date2];
    
    return [components1 year] == [components2 year] &&
        [components1 month] == [components2 month] &&
        [components1 day] == [components2 day];
}

- (BOOL)isDate:(NSDate *)date1 equalToDate:(NSDate *)date2 toUnitGranularity:(NSCalendarUnit)unit
{
    return [self compareDate:date1 toDate:date2 toUnitGranularity:unit] == NSOrderedSame;
}

- (NSComparisonResult)compareDate:(NSDate *)date1 toDate:(NSDate *)date2 toUnitGranularity:(NSCalendarUnit)unit
{
    NSDateComponents *components1 = [self components:unit fromDate:date1];
    NSDateComponents *components2 = [self components:unit fromDate:date2];

    NSInteger value1 = [components1 valueForComponent:unit];
    NSInteger value2 = [components2 valueForComponent:unit];
    
    if (value1 == value2) {
        return NSOrderedSame;
    } else if (value1 < value2) { 
        return NSOrderedAscending;
    }
    return NSOrderedDescending;
}

- (BOOL)isDateInWeekend:(NSDate *)date
{
    NSInteger day = [self component:NSCalendarUnitWeekday fromDate:date];

    return (day == 1 || day == 7);
}

- (BOOL)nextWeekendStartDate:(out NSDate * _Nullable *)datep interval:(out NSTimeInterval *)tip options:(NSCalendarOptions)options afterDate:(NSDate * _Nonnull)date
{
    NSInteger day = [self component:NSCalendarUnitWeekday fromDate:date];
    NSInteger daysUntil;
    BOOL back = (options & NSCalendarSearchBackwards) == NSCalendarSearchBackwards;
    
    if (back) {
        // previous Monday
        daysUntil = day == 1 ? -5 : 1 - day;
    } else {
        // next Saturday
        daysUntil = 7 - (day % 7);
    }
    
    NSDate *next = [self dateByAddingUnit:NSDayCalendarUnit value:daysUntil toDate:date options:0];
    next = [self startOfDayForDate:next];
    
    if (back) {
        // 1 second before monday starts
        next = [self dateByAddingUnit:NSSecondCalendarUnit value:-1 toDate:next options:0];
    }
    
    if (datep) {
        *datep = next;
    }
    
    if (tip) {
        *tip = [next timeIntervalSinceDate:date];
    }
    
    return YES;
}

- (BOOL)isDateInToday:(NSDate *)date
{
    return [self isDate:date inSameDayAsDate:[NSDate date]];
}

- (BOOL)isDateInTomorrow:(NSDate *)date
{
    NSDate *tomorrow = [self dateByAddingUnit:NSDayCalendarUnit value:1 toDate:[NSDate date] options:0];
    return [self isDate:date inSameDayAsDate:tomorrow];
}

- (NSDate *) dateFromComponents: (NSDateComponents *) comps
{
#if GS_USE_ICU == 1
    NSInteger amount;
    UDate udate;
    UErrorCode err = U_ZERO_ERROR;
    void *cal;
    NSTimeZone *timeZone;
	BOOL reuseOurCalendar;

	timeZone = [comps timeZone];
	reuseOurCalendar = timeZone == nil || [timeZone isEqual:[self timeZone]];

    [_lock lock];

    if (reuseOurCalendar)
	  {
        // Reuse our already opened calendar
        timeZone = [self timeZone];
        cal = [self _locked_cloneCalendar:&err];

        if (U_FAILURE(err))
          {
            [_lock unlock];
            return nil;
          }
      }
    else
      {
        cal = [self _locked_openCalendarFor:timeZone];
      }

    [_lock unlock];

    if (cal == NULL)
      {
        return nil;
      }

    ucal_clear(cal);

    if ((amount = [comps era]) != NSDateComponentUndefined)
      {
        ucal_set(cal, UCAL_ERA, (int32_t)amount);
      }

    if ((amount = [comps year]) != NSDateComponentUndefined)
      {
        ucal_set(cal, UCAL_YEAR, (int32_t)amount);
      }

    if ((amount = [comps month]) != NSDateComponentUndefined)
      {
        ucal_set(cal, UCAL_MONTH, amount - 1);
      }

    if ((amount = [comps day]) != NSDateComponentUndefined)
      {
        ucal_set(cal, UCAL_DAY_OF_MONTH, (int32_t)amount);
      }

    if ((amount = [comps hour]) != NSDateComponentUndefined)
      {
        ucal_set(cal, UCAL_HOUR_OF_DAY, (int32_t)amount);
      }

    if ((amount = [comps minute]) != NSDateComponentUndefined)
      {
        ucal_set(cal, UCAL_MINUTE, (int32_t)amount);
      }

    if ((amount = [comps second]) != NSDateComponentUndefined)
      {
        ucal_set(cal, UCAL_SECOND, (int32_t)amount);
      }

    if ((amount = [comps week]) != NSDateComponentUndefined)
      {
        ucal_set(cal, UCAL_WEEK_OF_YEAR, (int32_t)amount);
      }

    if ((amount = [comps weekday]) != NSDateComponentUndefined)
      {
        ucal_set(cal, UCAL_DAY_OF_WEEK, (int32_t)amount);
      }

    if ((amount = [comps weekdayOrdinal]) != NSDateComponentUndefined)
      {
        ucal_set(cal, UCAL_DAY_OF_WEEK_IN_MONTH, (int32_t)amount);
      }

    if ((amount = [comps weekOfMonth]) != NSDateComponentUndefined)
      {
        ucal_set(cal, UCAL_WEEK_OF_MONTH, (int32_t)amount);
      }

    if ((amount = [comps yearForWeekOfYear]) != NSDateComponentUndefined)
      {
        ucal_set(cal, UCAL_YEAR_WOY, (int32_t)amount);
      }

    if ((amount = [comps nanosecond]) != NSDateComponentUndefined)
      {
        ucal_set(cal, UCAL_MILLISECOND, (int32_t)(amount / MILLI_TO_NANO));
      }

    udate = ucal_getMillis(cal, &err);
    ucal_close(cal);

    if (U_FAILURE(err))
      {
        return nil;
      }

    return [NSDate dateWithTimeIntervalSince1970:(udate / SECOND_TO_MILLI)];
#else
    return nil;
#endif
}

- (NSLocale *) locale
{
    NSLocale *locale;
    NSString *localeID;

    [_lock lock];
    localeID = RETAIN(my->localeID);
    [_lock unlock];
    locale = [[NSLocale alloc] initWithLocaleIdentifier:localeID];
    RELEASE(localeID);

    return AUTORELEASE(locale);
}

- (void) setLocale: (NSLocale *) locale
{
    // It's much easier to keep a copy of the NSLocale's string representation
    // than to have to build it everytime we have to open a UCalendar.
    [self _setLocaleIdentifier:[self _localeIDWithLocale:locale]];
}

- (NSUInteger) firstWeekday
{
    NSUInteger firstWeekday;

    [_lock lock];
    firstWeekday = my->firstWeekday;
    [_lock unlock];

    return firstWeekday;
}

- (void) setFirstWeekday: (NSUInteger)weekday
{
    [_lock lock];
    my->firstWeekday = weekday;
#if GS_USE_ICU == 1
    ucal_setAttribute(my->cal, UCAL_FIRST_DAY_OF_WEEK, my->firstWeekday);
#endif
    [_lock unlock];
}

- (NSUInteger) minimumDaysInFirstWeek
{
    NSUInteger minimumDaysInFirstWeek;

    [_lock lock];
    minimumDaysInFirstWeek = my->minimumDaysInFirstWeek;
    [_lock unlock];

    return minimumDaysInFirstWeek;
}

- (void) setMinimumDaysInFirstWeek: (NSUInteger)mdw
{
    [_lock lock];
    my->minimumDaysInFirstWeek = (int32_t)mdw;
#if GS_USE_ICU == 1
    ucal_setAttribute(my->cal, UCAL_MINIMAL_DAYS_IN_FIRST_WEEK, my->minimumDaysInFirstWeek);
#endif
    [_lock unlock];
}

- (NSTimeZone *) timeZone
{
    NSTimeZone *tz;

    [_lock lock];
    tz = RETAIN(my->tz);
    [_lock unlock];

    return AUTORELEASE(tz);
}

- (void) setTimeZone: (NSTimeZone *) tz
{
    [_lock lock];
    if ([tz isEqual:my->tz]) {
        [_lock unlock];
        return;
    }

    ASSIGN(my->tz, tz);
    [self _locked_resetCalendar];
    [_lock unlock];
}

- (NSRange) maximumRangeOfUnit: (NSCalendarUnit)unit
{
    NSRange result = NSMakeRange(0, 0);
#if GS_USE_ICU == 1
    UCalendarDateFields dateField;
    UErrorCode err = U_ZERO_ERROR;

    dateField = _NSCalendarUnitToDateField(unit);

    if (dateField != (UCalendarDateFields)-1)
      {
        void *cal;

        [_lock lock];
        cal = [self _locked_cloneCalendar:&err];
        [_lock unlock];

        // We really don't care if there are any errors...
        result.location = (NSUInteger)ucal_getLimit(cal, dateField, UCAL_MINIMUM, &err);
        result.length = (NSUInteger)ucal_getLimit(cal, dateField, UCAL_MAXIMUM, &err) - result.location + 1;

        ucal_close(cal);

        // ICU's month is 0-based, while NSCalendar is 1-based
        if (dateField == UCAL_MONTH)
          {
            result.location += 1;
          }
      }
#endif

    return result;
}

- (NSRange) minimumRangeofUnit: (NSCalendarUnit)unit
{
    NSRange result = NSMakeRange(0, 0);
#if GS_USE_ICU == 1
    UCalendarDateFields dateField;
    UErrorCode err = U_ZERO_ERROR;

    dateField = _NSCalendarUnitToDateField(unit);

    if (dateField != (UCalendarDateFields)-1)
      {
        void *cal;

        [_lock lock];
        cal = [self _locked_cloneCalendar:&err];
        [_lock unlock];

        // We really don't care if there are any errors...
        result.location = (NSUInteger)ucal_getLimit(cal, dateField, UCAL_GREATEST_MINIMUM, &err);
        result.length = (NSUInteger)ucal_getLimit(cal, dateField, UCAL_LEAST_MAXIMUM, &err) - result.location + 1;
		
        ucal_close(cal);

        // ICU's month is 0-based, while NSCalendar is 1-based
        if (dateField == UCAL_MONTH)
          {
            result.location += 1;
          }
      }
#endif

    return result;
}

- (NSUInteger) ordinalityOfUnit: (NSCalendarUnit) smaller
                         inUnit: (NSCalendarUnit) larger
                        forDate: (NSDate *) date
{
    return 0;
}

- (NSRange) rangeOfUnit: (NSCalendarUnit) smaller
                 inUnit: (NSCalendarUnit) larger
                forDate: (NSDate *) date
{
    return NSMakeRange(0, 0);
}

- (BOOL) rangeOfUnit: (NSCalendarUnit) unit
           startDate: (NSDate **) datep
            interval: (NSTimeInterval *)tip
             forDate: (NSDate *)date
{
    return NO;
}

- (BOOL) isEqual: (id)obj
{
#if GS_USE_ICU == 1
    BOOL isEqual;

    [_lock lock];
    isEqual = (BOOL)ucal_equivalentTo(my->cal, ((Calendar *)(((NSCalendar *)obj)->_NSCalendarInternal))->cal);
    [_lock unlock];

    return isEqual;
#else
    if ([obj isKindOfClass:[self class]]) {
        [_lock lock];
        if (![my->identifier isEqual:[obj calendarIdentifier]]) {
            [_lock unlock];
            return NO;
        }
        if (![my->localeID isEqual:[obj localeIdentifier]]) {
            [_lock unlock];
            return NO;
        }
        if (![my->tz isEqual:[obj timeZone]]) {
            [_lock unlock];
            return NO;
        }
        if (my->firstWeekday != [obj firstWeekday]) {
            [_lock unlock];
            return NO;
        }
        if (my->minimumDaysInFirstWeek != [obj minimumDaysInFirstWeek]) {
            [_lock unlock];
            return NO;
        }
        [_lock unlock];
        return YES;
    }

    return NO;
#endif
}


- (void) getEra: (NSInteger *)eraValuePointer
           year: (NSInteger *)yearValuePointer
          month: (NSInteger *)monthValuePointer
            day: (NSInteger *)dayValuePointer
       fromDate: (NSDate *)date
{
#if GS_USE_ICU == 1
    UErrorCode err = U_ZERO_ERROR;
    UDate udate;
    void *cal;

    [_lock lock];
    cal = [self _locked_cloneCalendar:&err];
    [_lock unlock];
    
    if (U_FAILURE(err))
      {
        return;
      }

    ucal_clear(cal);

    udate = (UDate)floor([date timeIntervalSince1970] * 1000.0);
    ucal_setMillis(cal, udate, &err);

    if (U_FAILURE(err))
      {
        ucal_close(cal);
        return;
      }

    if (eraValuePointer != NULL)
      {
        *eraValuePointer = ucal_get(cal, UCAL_ERA, &err);
      }

    if (yearValuePointer != NULL)
      {
        *yearValuePointer = ucal_get(cal, UCAL_YEAR, &err);
      }

    if (monthValuePointer != NULL)
      {
        *monthValuePointer = ucal_get(cal, UCAL_MONTH, &err) + 1;
      }
    
    if (dayValuePointer != NULL)
      {
        *dayValuePointer = ucal_get(cal, UCAL_DAY_OF_MONTH, &err);
      }
      
      ucal_close(cal);
#endif
}

- (void) getHour: (NSInteger *)hourValuePointer
          minute: (NSInteger *)minuteValuePointer
          second: (NSInteger *)secondValuePointer
      nanosecond: (NSInteger *)nanosecondValuePointer
        fromDate: (NSDate *)date
{
#if GS_USE_ICU == 1
    UErrorCode err = U_ZERO_ERROR;
    UDate udate;
    void *cal;

    [_lock lock];
    cal = [self _locked_cloneCalendar:&err];
    [_lock unlock];

    if (U_FAILURE(err))
      {
        ucal_close(cal);
        return;
      }

    ucal_clear(cal);

    udate = (UDate)floor([date timeIntervalSince1970] * 1000.0);
    ucal_setMillis(cal, udate, &err);

    if (U_FAILURE(err))
      {
        ucal_close(cal);
        return;
      }

    if (hourValuePointer != NULL)
      {
        *hourValuePointer = ucal_get(cal, UCAL_HOUR_OF_DAY, &err);
      }

    if (minuteValuePointer != NULL)
      {
        *minuteValuePointer = ucal_get(cal, UCAL_MINUTE, &err);
      }

    if (secondValuePointer != NULL)
      {
        *secondValuePointer = ucal_get(cal, UCAL_SECOND, &err);
      }

    if (nanosecondValuePointer != NULL)
      {
        *nanosecondValuePointer = ucal_get(cal, UCAL_MILLISECOND, &err) * 1000;
      }

    ucal_close(cal);
#endif
}

- (void) getEra: (NSInteger *)eraValuePointer
yearForWeekOfYear: (NSInteger *)yearValuePointer
     weekOfYear: (NSInteger *)weekValuePointer
        weekday: (NSInteger *)weekdayValuePointer
       fromDate: (NSDate *)date
{
#if GS_USE_ICU == 1
    UErrorCode err = U_ZERO_ERROR;
    UDate udate;
    void *cal;

    [_lock lock];
    cal = [self _locked_cloneCalendar:&err];
    [_lock unlock];

    if (U_FAILURE(err))
      {
        ucal_close(cal);
        return;
      }

    ucal_clear(cal);

    udate = (UDate)floor([date timeIntervalSince1970] * 1000.0);
    ucal_setMillis(cal, udate, &err);

    if (U_FAILURE(err))
      {
        ucal_close(cal);
        return;
      }

    if (eraValuePointer != NULL)
      {
        *eraValuePointer = ucal_get(cal, UCAL_ERA, &err);
      }

    if (yearValuePointer != NULL)
      {
        *yearValuePointer = ucal_get(cal, UCAL_YEAR_WOY, &err);
      }

    if (weekValuePointer != NULL)
      {
        *weekValuePointer = ucal_get(cal, UCAL_WEEK_OF_YEAR, &err);
      }

    if (weekdayValuePointer != NULL)
      {
        *weekdayValuePointer = ucal_get(cal, UCAL_DAY_OF_WEEK, &err);
      }
#endif
}

- (void) encodeWithCoder: (NSCoder*)encoder
{
    [_lock lock];
    [encoder encodeObject:my->identifier];
    [encoder encodeObject:my->localeID];
    [encoder encodeObject:my->tz];
    [_lock unlock];
}

- (id) initWithCoder: (NSCoder*)decoder
{
    NSString *s = [decoder decodeObject];

    [self initWithCalendarIdentifier:s];
    [self _setLocaleIdentifier:[decoder decodeObject]];
    [self setTimeZone:[decoder decodeObject]];

    return self;
}

- (id) copyWithZone: (NSZone*)zone
{
  NSCalendar *result;

  [_lock lock];

  result = [[[self class] allocWithZone:zone] initWithCalendarIdentifier:my->identifier];
  [result _setLocaleIdentifier:my->localeID];
  [result setTimeZone:my->tz];
  [_lock unlock];

  return result;
}

@end

#undef  my


@implementation NSDateComponents

typedef struct {
  NSInteger era;
  NSInteger year;
  NSInteger month;
  NSInteger day;
  NSInteger hour;
  NSInteger minute;
  NSInteger second;
  NSInteger week;
  NSInteger weekday;
  NSInteger weekdayOrdinal;
  NSInteger quarter;
  NSInteger weekOfMonth;
  NSInteger yearForWeekOfYear;
  BOOL leapMonth;
  NSInteger nanosecond;
  NSCalendar *cal;
  NSTimeZone *tz;
} DateComp;

#define my ((DateComp*)_NSDateComponentsInternal)

- (void) dealloc
{
  if (0 != _NSDateComponentsInternal)
    {
      RELEASE(my->cal);
      RELEASE(my->tz);
      NSZoneFree([self zone], _NSDateComponentsInternal);
    }

  [super dealloc];
}

- (id) init
{
  if (nil != (self = [super init]))
    {
      _NSDateComponentsInternal = NSZoneCalloc([self zone], sizeof(DateComp), 1);

      if (_NSDateComponentsInternal != NULL)
        {
          my->era = NSDateComponentUndefined;
          my->year = NSDateComponentUndefined;
          my->month = NSDateComponentUndefined;
          my->day = NSDateComponentUndefined;
          my->hour = NSDateComponentUndefined;
          my->minute = NSDateComponentUndefined;
          my->second = NSDateComponentUndefined;
          my->week = NSDateComponentUndefined;
          my->weekday = NSDateComponentUndefined;
          my->weekdayOrdinal = NSDateComponentUndefined;
          my->quarter = NSDateComponentUndefined;
          my->weekOfMonth = NSDateComponentUndefined;
          my->yearForWeekOfYear = NSDateComponentUndefined;
          my->leapMonth = NO;
          my->nanosecond = NSDateComponentUndefined;
          my->cal = NULL;
          my->tz = NULL;
        }
      else
        {
          RELEASE(self);
          self = nil;
        }
    }

  return self;
}

- (NSInteger) day
{
  return my->day;
}

- (NSInteger) era
{
  return my->era;
}

- (NSInteger) hour
{
  return my->hour;
}

- (NSInteger) minute
{
  return my->minute;
}

- (NSInteger) month
{
  return my->month;
}

- (NSInteger) quarter
{
  return my->quarter;
}

- (NSInteger) second
{
  return my->second;
}

- (NSInteger) nanosecond
{
  return my->nanosecond;
}

- (NSInteger) week
{
  return my->week;
}

- (NSInteger) weekday
{
  return my->weekday;
}

- (NSInteger) weekdayOrdinal
{
  return my->weekdayOrdinal;
}

- (NSInteger) year
{
  return my->year;
}

- (NSInteger) weekOfMonth
{
  return my->weekOfMonth;
}

- (NSInteger) weekOfYear
{
  return my->week;
}

- (NSInteger) yearForWeekOfYear
{
  return my->yearForWeekOfYear;
}

- (BOOL) leapMonth
{
  return my->leapMonth;
}

- (NSCalendar *) calendar
{
  return my->cal;
}

- (NSTimeZone *) timeZone
{
  return my->tz;
}

- (NSDate *) date
{
  NSCalendar* cal = [self calendar];

  return [cal dateFromComponents: self];
}


- (void) setDay: (NSInteger) v
{
  my->day = v;
}

- (void) setEra: (NSInteger) v
{
  my->era = v;
}

- (void) setHour: (NSInteger) v
{
  my->hour = v;
}

- (void) setMinute: (NSInteger) v
{
  my->minute = v;
}

- (void) setMonth: (NSInteger) v
{
  my->month = v;
}

- (void) setQuarter: (NSInteger) v
{
  my->quarter = v;
}

- (void) setSecond: (NSInteger) v
{
  my->second = v;
}

- (void) setNanosecond: (NSInteger) v
{
  my->nanosecond = v;
}

- (void) setWeek: (NSInteger) v
{
  my->week = v;
}

- (void) setWeekday: (NSInteger) v
{
  my->weekday = v;
}

- (void) setWeekdayOrdinal: (NSInteger) v
{
  my->weekdayOrdinal = v;
}

- (void) setYear: (NSInteger) v
{
  my->year = v;
}

- (void) setWeekOfYear: (NSInteger) v
{
  my->week = v;
}

- (void) setWeekOfMonth: (NSInteger) v
{
  my->weekOfMonth = v;
}

- (void) setYearForWeekOfYear: (NSInteger) v
{
  my->yearForWeekOfYear = v;
}

- (void) setLeapMonth: (BOOL) v
{
  my->leapMonth = v;
}

- (void) setCalendar: (NSCalendar *) cal
{
  ASSIGN(my->cal, cal);
}

- (void) setTimeZone: (NSTimeZone *) tz
{
  ASSIGN(my->tz, tz);
}

- (BOOL) isValidDate
{
  if (my->cal == nil)
    {
      return NO;
    }
  return [self isValidDateInCalendar: my->cal];
}

- (BOOL) isValidDateInCalendar: (NSCalendar *) calendar
{
  return [calendar dateFromComponents: self] != nil;
}

- (NSInteger) valueForComponent: (NSCalendarUnit) unit
{
  switch (unit)
    {
      case NSCalendarUnitEra: return my->era;
      case NSCalendarUnitYear: return my->year;
      case NSCalendarUnitMonth: return my->month;
      case NSCalendarUnitDay: return my->day;
      case NSCalendarUnitHour: return my->hour;
      case NSCalendarUnitMinute: return my->minute;
      case NSCalendarUnitSecond: return my->second;
      case NSCalendarUnitWeekday: return my->weekday;
      case NSCalendarUnitWeekdayOrdinal: return my->weekdayOrdinal;
      case NSCalendarUnitQuarter: return my->quarter;
      case NSCalendarUnitWeekOfMonth: return my->weekOfMonth;
      case NSCalendarUnitWeekOfYear: return my->week;
      case NSWeekCalendarUnit: return my->week;
      case NSCalendarUnitYearForWeekOfYear: return my->yearForWeekOfYear;
      case NSCalendarUnitNanosecond: return my->nanosecond;
      default: return 0;
    }
}

- (void) setValue: (NSInteger) value
     forComponent: (NSCalendarUnit) unit
{
  switch (unit)
    {
      case NSCalendarUnitEra:
        my->era = value;
        break;
      case NSCalendarUnitYear:
        my->year = value;
        break;
      case NSCalendarUnitMonth:
        my->month = value;
        break;
      case NSCalendarUnitDay:
          my->day = value;
        break;
      case NSCalendarUnitHour:
        my->hour = value;
        break;
      case NSCalendarUnitMinute:
        my->minute = value;
        break;
      case NSCalendarUnitSecond:
        my->second = value;
        break;
      case NSCalendarUnitWeekday:
        my->weekday = value;
        break;
      case NSCalendarUnitWeekdayOrdinal:
        my->weekdayOrdinal = value;
        break;
      case NSCalendarUnitQuarter:
        my->quarter = value;
        break;
      case NSCalendarUnitWeekOfMonth:
        my->weekOfMonth = value;
        break;
      case NSCalendarUnitWeekOfYear:
        my->week = value;
        break;
      case NSWeekCalendarUnit:
        my->week = value;
        break;
      case NSCalendarUnitYearForWeekOfYear:
        my->yearForWeekOfYear = value;
        break;
      case NSCalendarUnitNanosecond:
        my->nanosecond = value;
        break;
      default:
        break;
    }
}

- (id) copyWithZone: (NSZone*)zone
{
  NSDateComponents *c = [[NSDateComponents allocWithZone: zone] init];

  if (c != nil)
    {
      if (c->_NSDateComponentsInternal != NULL)
        {
          ((DateComp *)c->_NSDateComponentsInternal)->era = my->era;
          ((DateComp *)c->_NSDateComponentsInternal)->year = my->year;
          ((DateComp *)c->_NSDateComponentsInternal)->month = my->month;
          ((DateComp *)c->_NSDateComponentsInternal)->day = my->day;
          ((DateComp *)c->_NSDateComponentsInternal)->hour = my->hour;
          ((DateComp *)c->_NSDateComponentsInternal)->minute = my->minute;
          ((DateComp *)c->_NSDateComponentsInternal)->second = my->second;
          ((DateComp *)c->_NSDateComponentsInternal)->week = my->week;
          ((DateComp *)c->_NSDateComponentsInternal)->weekday = my->weekday;
          ((DateComp *)c->_NSDateComponentsInternal)->weekdayOrdinal = my->weekdayOrdinal;
          ((DateComp *)c->_NSDateComponentsInternal)->quarter = my->quarter;
          ((DateComp *)c->_NSDateComponentsInternal)->weekOfMonth = my->weekOfMonth;
          ((DateComp *)c->_NSDateComponentsInternal)->yearForWeekOfYear = my->yearForWeekOfYear;
          ((DateComp *)c->_NSDateComponentsInternal)->leapMonth = my->leapMonth;
          ((DateComp *)c->_NSDateComponentsInternal)->nanosecond = my->nanosecond;
          ((DateComp *)c->_NSDateComponentsInternal)->cal = [my->cal copy];
          ((DateComp *)c->_NSDateComponentsInternal)->tz = [my->tz copy];
        }
      else
        {
            RELEASE(c);
            c = nil;
        }
    }

  return c;
}

- (BOOL)isEqual:(id)object
{
    if ([object isKindOfClass:[NSDateComponents class]]) {
        if ([self era] != [object era] ||
            [self year] != [object year] ||
            [self quarter] != [object quarter] ||
            [self month] != [object month] ||
            [self day] != [object day] ||
            [self hour] != [object hour] ||
            [self minute] != [object minute] ||
            [self second] != [object second] ||
            [self weekday] != [object weekday] ||
            [self weekdayOrdinal] != [object weekdayOrdinal] ||
            [self weekOfMonth] != [object weekOfMonth] ||
            [self weekOfYear] != [object weekOfYear] ||
            [self yearForWeekOfYear] != [object yearForWeekOfYear] ||
            [self nanosecond] != [object nanosecond]) {
            return NO;
        }

        if ([self leapMonth] != [object leapMonth]) {
            return NO;
        }

        // != test first to handle nil
        if ([self calendar] != [object calendar] && ![[self calendar] isEqual:[object calendar]]) { return NO; }
        // != test first to handle nil
        if ([self timeZone] != [object timeZone] && ![[self timeZone] isEqual:[object timeZone]]) { return NO; }

        return YES;
    }

    return [super isEqual:object];
}

@end
