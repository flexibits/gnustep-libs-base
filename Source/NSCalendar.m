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

#if !GS_USE_ICU
#error "NSCalendar without ICU is unsupported"
#endif // !GS_USE_ICU

#define TZ_NAME_LENGTH 1024
#define SECOND_TO_MILLI 1000.0
#define MILLI_TO_NANO 1000000

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


static NSString * _LocaleIDWithCalendarIdentifier(NSString *calendarIdentifier, NSLocale *locale)
{
  NSString *result;
  NSString *localeId;

  localeId = RETAIN([locale localeIdentifier]);

  if (calendarIdentifier != nil)
    {
      NSMutableDictionary *tmpDict = [[NSLocale componentsFromLocaleIdentifier:localeId] mutableCopyWithZone: NULL];

      [tmpDict removeObjectForKey: NSLocaleCalendar];
      [tmpDict setObject: calendarIdentifier forKey: NSLocaleCalendarIdentifier];
      result = [NSLocale localeIdentifierFromComponents: tmpDict];
      RELEASE(tmpDict);
      RELEASE(localeId);
      localeId = nil;
    }
  else
    {
      result = AUTORELEASE(localeId);
    }

  return result;
}

static UCalendar *_OpenIcuCal(NSString *calendarIdentifier, NSLocale *locale, NSTimeZone *timeZone)
{
  UCalendar *cal;
  UCalendarType type;
  NSString *tzName = [timeZone name];
  NSUInteger tzLen = [tzName length];
  unichar cTzId[TZ_NAME_LENGTH];
  NSString *localeID = _LocaleIDWithCalendarIdentifier(calendarIdentifier, locale);
  const char *cLocaleId = [localeID UTF8String];
  UErrorCode err = U_ZERO_ERROR;

  if (tzLen > TZ_NAME_LENGTH)
    {
      tzLen = TZ_NAME_LENGTH;
    }

  [tzName getCharacters:cTzId range:NSMakeRange(0, tzLen)];

  if ([NSGregorianCalendar isEqualToString:calendarIdentifier])
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

  cal = ucal_open((const UChar *)cTzId, tzLen, cLocaleId, type, &err);

  if (cal != NULL)
    {
      ucal_clear(cal);
    }

  return cal;
}

@interface GSCalendarData: NSObject

@property(readonly, copy, nonatomic) NSString *identifier;
@property(readonly, copy, nonatomic) NSLocale *locale;
@property(readonly, copy, nonatomic) NSTimeZone *timeZone;
@property(readonly, nonatomic) UCalendar *icuCal;

- (instancetype) initWithIdentifier: (NSString *) identifier
                             locale: (NSLocale *) locale
                           timeZone: (NSTimeZone *) timeZone;

- (instancetype) initWithCalendarData: (GSCalendarData *) calendarData
                         firstWeekday: (NSInteger) firstWeekday;

- (instancetype) initWithCalendarData: (GSCalendarData *) calendarData
               minimumDaysInFirstWeek: (NSInteger) minimumDaysInFirstWeek;

- (NSInteger) firstWeekday;
- (NSInteger) minimumDaysInFirstWeek;
- (UCalendar *) icuCalWithTimeZone: (NSTimeZone *)timeZone;

@end

@implementation GSCalendarData {
  NSInteger _firstWeekday;
  NSInteger _minimumDaysInFirstWeek;
}

- (instancetype) initWithIdentifier: (NSString *) identifier
                             locale: (NSLocale *) locale
                           timeZone: (NSTimeZone *) timeZone
{
  if (self = [super init])
    {
      _identifier = [identifier copy];
      _locale = [locale copy];
      _timeZone = [timeZone copy];
      _firstWeekday = NSNotFound;
      _minimumDaysInFirstWeek = NSNotFound;
      _icuCal = _OpenIcuCal(_identifier, _locale, _timeZone);

      if (_icuCal == NULL)
        {
          DESTROY(self);
        }
    }

  return self;
}

- (instancetype) initWithCalendarData: (GSCalendarData *) calendarData
                         firstWeekday: (NSInteger) firstWeekday
{
  if (self = [super init])
    {
      UErrorCode err = U_ZERO_ERROR;
      ASSIGN(_identifier, calendarData->_identifier);
      ASSIGN(_locale, calendarData->_locale);
      ASSIGN(_timeZone, calendarData->_timeZone);
      _firstWeekday = firstWeekday;
      _minimumDaysInFirstWeek = calendarData->_minimumDaysInFirstWeek;
      _icuCal = ucal_clone(calendarData->_icuCal, &err);

      if (_icuCal == NULL || U_FAILURE(err))
        {
          DESTROY(self);
        }
      else if (_firstWeekday != NSNotFound)
        {
          ucal_setAttribute(_icuCal, UCAL_FIRST_DAY_OF_WEEK, (int32_t)_firstWeekday);
        }
    }

  return self;
}

- (instancetype) initWithCalendarData: (GSCalendarData *)calendarData
               minimumDaysInFirstWeek: (NSInteger) minimumDaysInFirstWeek
{
  if (self = [super init])
    {
      UErrorCode err = U_ZERO_ERROR;
      ASSIGN(_identifier, calendarData->_identifier);
      ASSIGN(_locale, calendarData->_locale);
      ASSIGN(_timeZone, calendarData->_timeZone);
      _firstWeekday = calendarData->_firstWeekday;
      _minimumDaysInFirstWeek = minimumDaysInFirstWeek;
      _icuCal = ucal_clone(calendarData->_icuCal, &err);

      if (_icuCal == NULL || U_FAILURE(err))
        {
          DESTROY(self);
        }
      else if (_minimumDaysInFirstWeek != NSNotFound)
        {
          ucal_setAttribute(_icuCal, UCAL_MINIMAL_DAYS_IN_FIRST_WEEK, (int32_t)_minimumDaysInFirstWeek);
        }
    }

  return self;
}

- (void) dealloc
{
  DESTROY(_identifier);
  DESTROY(_locale);
  DESTROY(_timeZone);

  if (_icuCal != NULL)
    {
      ucal_close(_icuCal);
      _icuCal = NULL;
    }

  [super dealloc];
}

- (UCalendar *) icuCalWithTimeZone: (NSTimeZone *) timeZone
{
  UCalendar *cal = _OpenIcuCal(_identifier, _locale, timeZone);

  if (cal == NULL)
    {
      return NULL;
    }

  if (_firstWeekday != NSNotFound)
    {
      ucal_setAttribute(cal, UCAL_FIRST_DAY_OF_WEEK, (int32_t)_firstWeekday);
    }

  if (_minimumDaysInFirstWeek != NSNotFound)
    {
      ucal_setAttribute(cal, UCAL_MINIMAL_DAYS_IN_FIRST_WEEK, (int32_t)_minimumDaysInFirstWeek);
    }

  return cal;
}

- (NSInteger) firstWeekday
{
  return ucal_getAttribute(_icuCal, UCAL_FIRST_DAY_OF_WEEK);
}

- (NSInteger) minimumDaysInFirstWeek
{
  return ucal_getAttribute(_icuCal, UCAL_MINIMAL_DAYS_IN_FIRST_WEEK);
}

@end

@interface GSAutoupdatingCurrentCalendar: NSCalendar

- (instancetype) init;

- (void) _refreshAutoupdatingCalendarWithCalendar: (NSString *) calendar
                                           locale: (NSString *) localeID
                                         timeZone: (NSTimeZone *) timeZone;

- (void) setFirstWeekday: (NSInteger) firstWeekday;
- (void) setMinimumDaysInFirstWeek: (NSInteger) firstWeekday;

@end

static NSCalendar *currentCalendar = nil;
static GSAutoupdatingCurrentCalendar *autoupdatingCurrentCalendar = nil;
static NSRecursiveLock *classLock = nil;

@implementation NSCalendar

+ (void) initialize
{
    if (self == [NSCalendar class])
      {
        classLock = [[NSRecursiveLock alloc] init];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_refreshCurrentCalendarFromDefaultsDidChange:)
                                                     name:NSUserDefaultsDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_refreshCurrentCalendarFromDefaultsDidChange:)
                                                     name:NSCurrentLocaleDidChangeNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_refreshCurrentCalendarFromDefaultsDidChange:)
                                                     name:NSSystemTimeZoneDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_refreshCurrentCalendarFromDefaultsDidChange:)
                                                     name:GSDefaultTimeZoneDidChangeNotification
                                                   object:nil];
      }
}

+ (void) _refreshCurrentCalendarFromDefaultsDidChange: (NSNotification*) n
{
  if (currentCalendar != nil || autoupdatingCurrentCalendar != nil)
    {
      BOOL needToRefreshCurrentCalendar = NO;
      NSLocale *locale = [NSLocale currentLocale];
      // This identifier may be nil
      NSString *calendarIdentifier = [locale objectForKey: NSLocaleCalendarIdentifier];
      NSString *localeID = _LocaleIDWithCalendarIdentifier(calendarIdentifier, locale);
      NSTimeZone *timeZone = [NSTimeZone defaultTimeZone];

      [classLock lock];

      if (currentCalendar != nil || autoupdatingCurrentCalendar != nil)
        {
            NSCalendar *referenceCalendar = currentCalendar != nil ? currentCalendar : autoupdatingCurrentCalendar;

            needToRefreshCurrentCalendar = [referenceCalendar _needsRefreshForCalendarIdentifier: calendarIdentifier
                                                                                          locale: localeID
                                                                                        timeZone: timeZone];

            if (needToRefreshCurrentCalendar)
              {
                NSCalendar *previousCurrentCalendar = currentCalendar;

                currentCalendar = nil;
                RELEASE(previousCurrentCalendar);

                if (autoupdatingCurrentCalendar)
                  {
                    [autoupdatingCurrentCalendar _refreshAutoupdatingCalendarWithCalendar: calendarIdentifier
                                                                                   locale: localeID
                                                                                 timeZone: timeZone];
                  }
              }
        }

      [classLock unlock];
    }
}

+ (NSCalendar *) currentCalendar
{
  NSCalendar *activeCurrentCalendar;
  NSCalendar *result;

  [classLock lock];

  if (currentCalendar == nil)
    {
      // This identifier may be nil
      NSString *identifier = [[NSLocale currentLocale] objectForKey:NSLocaleCalendarIdentifier];

      currentCalendar = [[NSCalendar alloc] initWithCalendarIdentifier:identifier];
    }

  activeCurrentCalendar = RETAIN(currentCalendar);
  [classLock unlock];

  result = AUTORELEASE([activeCurrentCalendar copy]);
  RELEASE(activeCurrentCalendar);

  return result;
}

+ (NSCalendar *) autoupdatingCurrentCalendar
{
  GSAutoupdatingCurrentCalendar *activeAutoupdatingCurrentCalendar;

  [classLock lock];

  if (autoupdatingCurrentCalendar == nil)
    {
      autoupdatingCurrentCalendar = [[GSAutoupdatingCurrentCalendar alloc] init];
    }

  activeAutoupdatingCurrentCalendar = RETAIN(autoupdatingCurrentCalendar);
  [classLock unlock];

  return AUTORELEASE(activeAutoupdatingCurrentCalendar);
}

+ (NSCalendar *) calendarWithIdentifier: (NSString *)identifier
{
    return AUTORELEASE([[self alloc] initWithCalendarIdentifier:identifier]);
}

- (GSCalendarData *) _calendarData
{
  return ((GSCalendarData *)_NSCalendarInternal);
}

- (void) _setCalendarData: (GSCalendarData *) calendarData
{
  GSCalendarData *prevCalendarData = (__bridge GSCalendarData *)_NSCalendarInternal;

  _NSCalendarInternal = (__bridge void *)calendarData;
  RELEASE(prevCalendarData);
}

- (UCalendar *)_clonedICUCal
{
  UErrorCode err = U_ZERO_ERROR;

  return ucal_clone([[self _calendarData] icuCal], &err);
}

- (BOOL) _needsRefreshForCalendarIdentifier: (NSString *)calendarIdentifier
                                     locale: (NSString *)localeID
                                   timeZone: (NSTimeZone *)timeZone
{
  BOOL needsToRefresh = NO;
  GSCalendarData *calendarData = [self _calendarData];

  if (!needsToRefresh)
    {
      NSString *myIdentifier = [calendarData identifier];

      if (calendarIdentifier != myIdentifier)
        {
          if (calendarIdentifier == nil || myIdentifier == nil)
            {
              needsToRefresh = YES;
            }
          else
            {
              needsToRefresh = ![calendarIdentifier isEqualToString:myIdentifier];
            }
        }
    }

  if (!needsToRefresh)
    {
      NSString *myLocaleID = [[calendarData locale] localeIdentifier];

      if (localeID != myLocaleID)
        {
          if (localeID == nil || myLocaleID == nil)
            {
              needsToRefresh = YES;
            }
          else
            {
              needsToRefresh = ![localeID isEqualToString:myLocaleID];
            }
        }
    }

  if (!needsToRefresh)
    {
      NSTimeZone *myTz = [calendarData timeZone];

      if (timeZone != myTz)
        {
          if (timeZone == nil || myTz == nil)
            {
              needsToRefresh = YES;
            }
          else
            {
              needsToRefresh = ![timeZone isEqualToTimeZone:myTz];
            }
        }
    }

  return needsToRefresh;
}

- (instancetype) init
{
    return [self initWithCalendarIdentifier:nil];
}

- (instancetype) initWithCalendarData: (GSCalendarData *) calendarData
{
  if (self = [super init])
    {
      _NSCalendarInternal = (__bridge void *)RETAIN(calendarData);

      if (_NSCalendarInternal == NULL)
        {
          DESTROY(self);
        }
    }

    return self;
}


- (instancetype) initWithCalendarIdentifier: (NSString *) identifier
{
  if (self = [super init])
    {
      _NSCalendarInternal = (__bridge void *)[[GSCalendarData alloc] initWithIdentifier: identifier locale: [NSLocale currentLocale] timeZone: [NSTimeZone defaultTimeZone]];

      if (_NSCalendarInternal == NULL)
        {
          DESTROY(self);
        }
    }

  return self;
}

- (void) dealloc
{
  if (_NSCalendarInternal != NULL)
    {
      GSCalendarData *calendarData = (__bridge GSCalendarData *)_NSCalendarInternal;

      _NSCalendarInternal = NULL;
      RELEASE(calendarData);
    }

  [super dealloc];
}

- (NSString *) calendarIdentifier
{
  return [[self _calendarData] identifier];
}

- (NSInteger) component: (NSCalendarUnit)unit
               fromDate: (NSDate *)date
{
  NSDateComponents *comps = [self components:unit fromDate:date];
  NSInteger val = 0;

  switch (unit)
    {
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
  NSDateComponents *comps;
  UErrorCode err = U_ZERO_ERROR;
  UDate udate;
  UCalendar *cal = [self _clonedICUCal];

  if (cal == NULL)
    {
	    return nil;
    }

  udate = (UDate)floor([date timeIntervalSince1970] * SECOND_TO_MILLI);
  ucal_setMillis(cal, udate, &err);

  if (U_FAILURE(err))
    {
      ucal_close(cal);
      return nil;
    }

  comps = [[NSDateComponents alloc] init];

  if (unitFlags & NSCalendarUnitEra)
    {
      [comps setEra:ucal_get(cal, UCAL_ERA, &err)];
    }

  if (unitFlags & NSCalendarUnitYear)
    {
      [comps setYear:ucal_get(cal, UCAL_YEAR, &err)];
    }

  if (unitFlags & NSCalendarUnitMonth)
    {
      [comps setMonth:ucal_get(cal, UCAL_MONTH, &err) + 1];
    }

  if (unitFlags & NSCalendarUnitDay)
    {
      [comps setDay:ucal_get(cal, UCAL_DAY_OF_MONTH, &err)];
    }

  if (unitFlags & NSCalendarUnitHour)
    {
      [comps setHour:ucal_get(cal, UCAL_HOUR_OF_DAY, &err)];
    }

  if (unitFlags & NSCalendarUnitMinute)
    {
      [comps setMinute:ucal_get(cal, UCAL_MINUTE, &err)];
    }

  if (unitFlags & NSCalendarUnitSecond)
    {
      [comps setSecond:ucal_get(cal, UCAL_SECOND, &err)];
    }

  if (unitFlags & (NSWeekCalendarUnit | NSCalendarUnitWeekOfYear))
    {
      [comps setWeek:ucal_get(cal, UCAL_WEEK_OF_YEAR, &err)];
    }

  if (unitFlags & NSCalendarUnitWeekday)
    {
      [comps setWeekday:ucal_get(cal, UCAL_DAY_OF_WEEK, &err)];
    }

  if (unitFlags & NSCalendarUnitWeekdayOrdinal)
    {
      [comps setWeekdayOrdinal:ucal_get(cal, UCAL_DAY_OF_WEEK_IN_MONTH, &err)];
    }

  if (unitFlags & NSCalendarUnitQuarter)
    {
      [comps setQuarter:(ucal_get(cal, UCAL_MONTH, &err) + 3) / 3];
    }

  if (unitFlags & NSCalendarUnitWeekOfMonth)
    {
      [comps setWeekOfMonth:ucal_get(cal, UCAL_WEEK_OF_MONTH, &err)];
    }

  if (unitFlags & NSCalendarUnitYearForWeekOfYear)
    {
      [comps setYearForWeekOfYear:ucal_get(cal, UCAL_YEAR_WOY, &err)];
    }

  if (unitFlags & NSCalendarUnitNanosecond)
    {
      [comps setNanosecond:ucal_get(cal, UCAL_MILLISECOND, &err) * MILLI_TO_NANO];
    }

  ucal_close(cal);

  return AUTORELEASE(comps);
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
                ucal_close(cal);                                                     \
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
  NSDateComponents *comps;
  UErrorCode err = U_ZERO_ERROR;
  UDate udateFrom;
  UDate udateTo;
  UCalendar *cal = [self _clonedICUCal];

  if (cal == NULL)
    {
      return nil;
    }

  udateFrom = (UDate)floor([startingDate timeIntervalSince1970] * SECOND_TO_MILLI);
  udateTo = (UDate)floor([resultDate timeIntervalSince1970] * SECOND_TO_MILLI);

  ucal_setMillis(cal, udateFrom, &err);

  comps = [[NSDateComponents alloc] init];

  /*
   * Since the ICU field difference function automatically advances
   * the calendar as appropriate, we need to process the units from
   * the largest to the smallest.
   */
  COMPONENT_DIFF(cal, unitFlags, comps, udateTo, NSCalendarUnitEra, setEra:, UCAL_ERA, err);
  COMPONENT_DIFF(cal, unitFlags, comps, udateTo, NSCalendarUnitYear, setYear:, UCAL_YEAR, err);
  COMPONENT_DIFF(cal, unitFlags, comps, udateTo, NSCalendarUnitMonth, setMonth:, UCAL_MONTH, err);
  COMPONENT_DIFF(cal, unitFlags, comps, udateTo, NSCalendarUnitWeekOfYear, setWeek:, UCAL_WEEK_OF_YEAR, err);

  if (!(unitFlags & NSCalendarUnitWeekOfYear))
    {
      /* We must avoid setting the same unit twice (it would be zero because
       * of the automatic advancement.
       */
      COMPONENT_DIFF(cal, unitFlags, comps, udateTo, NSWeekCalendarUnit, setWeek:, UCAL_WEEK_OF_YEAR, err);
    }

  COMPONENT_DIFF(cal, unitFlags, comps, udateTo, NSCalendarUnitWeekOfMonth, setWeekOfMonth:, UCAL_WEEK_OF_MONTH, err);
  COMPONENT_DIFF(cal, unitFlags, comps, udateTo, NSCalendarUnitDay, setDay:, UCAL_DAY_OF_MONTH, err);
  COMPONENT_DIFF(cal, unitFlags, comps, udateTo, NSCalendarUnitWeekdayOrdinal, setWeekdayOrdinal:, UCAL_DAY_OF_WEEK_IN_MONTH, err);
  COMPONENT_DIFF(cal, unitFlags, comps, udateTo, NSCalendarUnitWeekday, setWeekday:, UCAL_DAY_OF_WEEK, err);
  COMPONENT_DIFF(cal, unitFlags, comps, udateTo, NSCalendarUnitHour, setHour:, UCAL_HOUR_OF_DAY, err);
  COMPONENT_DIFF(cal, unitFlags, comps, udateTo, NSCalendarUnitMinute, setMinute:, UCAL_MINUTE, err);
  COMPONENT_DIFF(cal, unitFlags, comps, udateTo, NSCalendarUnitSecond, setSecond:, UCAL_SECOND, err);

  if (unitFlags & NSCalendarUnitNanosecond)
    {
      int32_t ms = ucal_getFieldDifference(cal, udateTo, UCAL_MILLISECOND, &err);

      if (U_FAILURE(err))
        {
          RELEASE(comps);
          ucal_close(cal);
          return nil;
        }

      [comps setNanosecond:ms * MILLI_TO_NANO];
  }

  ucal_close(cal);

  return AUTORELEASE(comps);
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
  NSInteger amount;
  UErrorCode err = U_ZERO_ERROR;
  UDate udate;
  UCalendar *cal = [self _clonedICUCal];

  if (cal == NULL)
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
}

#undef _ADD_COMPONENT

- (NSDateComponents *) components: (NSCalendarUnit) unitFlags fromDateComponents: (NSDateComponents *) startingDateComp toDateComponents: (NSDateComponents *) resultDateComp options: (NSCalendarOptions) options
{
  NSDate *startDate;
  NSDate *toDate;
  NSCalendar *startCalendar;
  NSCalendar *toCalendar;

  startCalendar = [startingDateComp calendar];

  if (startCalendar)
    {
      startDate = [startCalendar dateFromComponents: startingDateComp];
    }
  else
    {
      startDate = [self dateFromComponents: startingDateComp];
    }

  toCalendar = [resultDateComp calendar];

  if (toCalendar)
    {
      toDate = [toCalendar dateFromComponents: resultDateComp];
    }
  else
    {
      toDate = [self dateFromComponents: resultDateComp];
    }

  if (startDate && toDate)
    {
      return [self components: unitFlags fromDate: startDate toDate: toDate options: options];
    }

  return nil;
}

- (NSDate *)dateByAddingUnit: (NSCalendarUnit) unit value: (NSInteger) value toDate: (NSDate *) date options: (NSCalendarOptions) options
{
  NSDateComponents *components = [[NSDateComponents alloc] init];
  NSDate *result;

  [components setValue: value forComponent: unit];
  result = [self dateByAddingComponents: components toDate: date options: options];
  RELEASE(components);
  return result;
}

static inline UCalendarDateFields NSCalendarUnitToUCalendarDateField(NSCalendarUnit unit, BOOL *out_success)
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

- (NSDate *) dateBySettingUnit: (NSCalendarUnit) unit value: (NSInteger) value ofDate: (NSDate *) date options: (NSCalendarOptions) opts
{
  UErrorCode err = U_ZERO_ERROR;
  BOOL ok;
  UCalendarDateFields ucalField;
  NSTimeInterval epochTime;
  NSTimeInterval newEpochTime;
  UCalendar *cal = [self _clonedICUCal];

  if (cal == NULL)
    {
      return nil;
    }

  // Convert to ICU-equivalent calendar unit
  ucalField = NSCalendarUnitToUCalendarDateField(unit, &ok);
  NSAssert(ok, @"GNUStep does not implement the given date field.");

  // Set the ICU calendar to this date
  epochTime = [date timeIntervalSince1970] * SECOND_TO_MILLI;
  ucal_setMillis(cal, epochTime, &err);
  NSAssert(!U_FAILURE(err), ([NSString stringWithFormat: @"Couldn't setMillis to calendar: %s", u_errorName(err)]));

  // Set the field on the ICU calendar
  ucal_set(cal, ucalField, value);

  // Get the date back from the ICU calendar
  newEpochTime = ucal_getMillis(cal, &err);
  ucal_close(cal);
  NSAssert(!U_FAILURE(err), ([NSString stringWithFormat: @"Couldn't getMillis from calendar: %s", u_errorName(err)]));

  return [NSDate dateWithTimeIntervalSince1970:(newEpochTime / SECOND_TO_MILLI)];
}

- (NSDate *) dateBySettingHour: (NSInteger) h minute: (NSInteger) m second: (NSInteger) s ofDate: (NSDate *) date options: (NSCalendarOptions) opts
{
  NSDateComponents *components = [self components:AllCalendarUnits fromDate:date];

  [components setHour:h];
  [components setMinute:m];
  [components setSecond:s];

  return [self dateFromComponents:components];
}

- (NSDate *) dateWithEra: (NSInteger) eraValue
                    year: (NSInteger) yearValue
                   month: (NSInteger) monthValue
                     day: (NSInteger) dayValue
                    hour: (NSInteger) hourValue
                  minute: (NSInteger) minuteValue
                  second: (NSInteger) secondValue
              nanosecond: (NSInteger) nanosecondValue
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

- (NSDate *) dateWithEra: (NSInteger) eraValue
       yearForWeekOfYear: (NSInteger) yearValue
              weekOfYear: (NSInteger) weekValue
                 weekday: (NSInteger) weekdayValue
                    hour: (NSInteger) hourValue
                  minute: (NSInteger) minuteValue
                  second: (NSInteger) secondValue
              nanosecond: (NSInteger) nanosecondValue
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

- (NSDate *) startOfDayForDate: (NSDate *) date
{
    NSDateComponents *components = [self components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:date];

    return [self dateFromComponents:components];
}

- (BOOL) isDate: (NSDate *) date1 inSameDayAsDate: (NSDate *) date2
{
  NSDateComponents *components1 = [self components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:date1];
  NSDateComponents *components2 = [self components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:date2];

  return [components1 year] == [components2 year] &&
      [components1 month] == [components2 month] &&
      [components1 day] == [components2 day];
}

- (BOOL) isDate: (NSDate *) date1 equalToDate: (NSDate *) date2 toUnitGranularity: (NSCalendarUnit) unit
{
  return [self compareDate:date1 toDate:date2 toUnitGranularity:unit] == NSOrderedSame;
}

- (NSComparisonResult)compareDate:(NSDate *)date1 toDate:(NSDate *)date2 toUnitGranularity:(NSCalendarUnit)unit
{
  NSDateComponents *components1 = [self components:unit fromDate:date1];
  NSDateComponents *components2 = [self components:unit fromDate:date2];

  NSInteger value1 = [components1 valueForComponent:unit];
  NSInteger value2 = [components2 valueForComponent:unit];

  if (value1 == value2)
    {
      return NSOrderedSame;
    }
  else if (value1 < value2)
    {
      return NSOrderedAscending;
    }
  else
    {
      return NSOrderedDescending;
    }
}

- (BOOL) isDateInWeekend: (NSDate *) date
{
  NSInteger day = [self component:NSCalendarUnitWeekday fromDate:date];

  return (day == 1 || day == 7);
}

- (BOOL)nextWeekendStartDate:(out NSDate * _Nullable *)datep interval:(out NSTimeInterval *)tip options:(NSCalendarOptions)options afterDate:(NSDate * _Nonnull)date
{
  NSInteger day = [self component:NSCalendarUnitWeekday fromDate:date];
  NSInteger daysUntil;
  BOOL back = (options & NSCalendarSearchBackwards) == NSCalendarSearchBackwards;
  NSDate *next;

  if (back)
    {
      // previous Monday
      daysUntil = day == 1 ? -5 : 1 - day;
    }
  else
    {
      // next Saturday
      daysUntil = 7 - (day % 7);
    }

  next = [self dateByAddingUnit:NSDayCalendarUnit value:daysUntil toDate:date options:0];
  next = [self startOfDayForDate:next];

  if (back)
    {
      // 1 second before monday starts
      next = [self dateByAddingUnit:NSSecondCalendarUnit value:-1 toDate:next options:0];
    }

  if (datep)
   {
      *datep = next;
   }

  if (tip)
   {
      *tip = [next timeIntervalSinceDate:date];
   }

  return YES;
}

- (BOOL) isDateInToday: (NSDate *) date
{
  return [self isDate:date inSameDayAsDate:[NSDate date]];
}

- (BOOL) isDateInTomorrow: (NSDate *) date
{
  NSDate *tomorrow = [self dateByAddingUnit:NSDayCalendarUnit value:1 toDate:[NSDate date] options:0];

  return [self isDate:date inSameDayAsDate:tomorrow];
}

- (NSDate *) dateFromComponents: (NSDateComponents *) comps
{
  NSInteger amount;
  UDate udate;
  UErrorCode err = U_ZERO_ERROR;
  UCalendar *cal;
  NSTimeZone *compsTimeZone = [comps timeZone];
  NSTimeZone *myTimeZone = [self timeZone];
  BOOL reuseOurCalendar = compsTimeZone == nil || [compsTimeZone isEqualToTimeZone:myTimeZone];

  if (reuseOurCalendar)
    {
      // Reuse our already opened calendar
      cal = [self _clonedICUCal];
    }
  else
    {
      // Need to open a new calendar with the same identifier/locale, but different time zone
      GSCalendarData *calendarData = [self _calendarData];

      cal = [calendarData icuCalWithTimeZone: compsTimeZone];
    }

  if (cal == NULL)
    {
      return nil;
    }

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
}

- (NSLocale *) locale
{
  return [[self _calendarData] locale];
}

- (void) setLocale: (NSLocale *) locale
{
  GSCalendarData *prevCalendarData = [self _calendarData];

  [self _setCalendarData: [[GSCalendarData alloc] initWithIdentifier: [prevCalendarData identifier] locale: locale timeZone: [prevCalendarData timeZone]]];
}

- (NSUInteger) firstWeekday
{
  return [[self _calendarData] firstWeekday];
}

- (void) setFirstWeekday: (NSUInteger)weekday
{
  if ([self firstWeekday] != weekday)
    {
      GSCalendarData *prevCalendarData = [self _calendarData];

      [self _setCalendarData: [[GSCalendarData alloc] initWithCalendarData: prevCalendarData firstWeekday: weekday]];
    }
}

- (NSUInteger) minimumDaysInFirstWeek
{
  return [[self _calendarData] minimumDaysInFirstWeek];
}

- (void) setMinimumDaysInFirstWeek: (NSUInteger)minimumDaysInFirstWeek
{
  if ([self minimumDaysInFirstWeek] != minimumDaysInFirstWeek)
    {
      GSCalendarData *prevCalendarData = [self _calendarData];

      [self _setCalendarData: [[GSCalendarData alloc] initWithCalendarData: prevCalendarData minimumDaysInFirstWeek: minimumDaysInFirstWeek]];
    }
}

- (NSTimeZone *) timeZone
{
    return [[self _calendarData] timeZone];
}

- (void) setTimeZone: (NSTimeZone *) timeZone
{
  if (![[self timeZone] isEqualToTimeZone: timeZone])
    {
      GSCalendarData *prevCalendarData = [self _calendarData];

      [self _setCalendarData: [[GSCalendarData alloc] initWithIdentifier: [prevCalendarData identifier] locale: [prevCalendarData locale] timeZone: timeZone]];
    }
}

- (NSRange) maximumRangeOfUnit: (NSCalendarUnit) unit
{
  NSRange result = NSMakeRange(0, 0);
  UCalendarDateFields dateField;
  UErrorCode err = U_ZERO_ERROR;

  dateField = _NSCalendarUnitToDateField(unit);

  if (dateField != (UCalendarDateFields)-1)
    {
      UCalendar *cal = [self  _clonedICUCal];

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

  return result;
}

- (NSRange) minimumRangeofUnit: (NSCalendarUnit) unit
{
  NSRange result = NSMakeRange(0, 0);
  UCalendarDateFields dateField;
  UErrorCode err = U_ZERO_ERROR;

  dateField = _NSCalendarUnitToDateField(unit);

  if (dateField != (UCalendarDateFields)-1)
    {
      UCalendar *cal = [self  _clonedICUCal];

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
            interval: (NSTimeInterval *) tip
             forDate: (NSDate *) date
{
  return NO;
}

- (BOOL) isEqual: (id)obj
{
  if (obj == nil || ![obj isKindOfClass: [NSCalendar class]])
    {
      return NO;
    }
  else
    {
      GSCalendarData *calendarData1 = [self _calendarData];
      GSCalendarData *calendarData2 = [(NSCalendar *)obj _calendarData];
      UCalendar *cal1 = [calendarData1 icuCal];
      UCalendar *cal2 = [calendarData2 icuCal];
      BOOL isEqual = (BOOL)ucal_equivalentTo(cal1, cal2);

      return isEqual;
    }
}


- (void) getEra: (NSInteger *) eraValuePointer
           year: (NSInteger *) yearValuePointer
          month: (NSInteger *) monthValuePointer
            day: (NSInteger *) dayValuePointer
       fromDate: (NSDate *) date
{
  UErrorCode err = U_ZERO_ERROR;
  UDate udate;
  UCalendar *cal = [self _clonedICUCal];

  if (cal == NULL)
    {
      return;
    }

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
}

- (void) getHour: (NSInteger *)hourValuePointer
          minute: (NSInteger *)minuteValuePointer
          second: (NSInteger *)secondValuePointer
      nanosecond: (NSInteger *)nanosecondValuePointer
        fromDate: (NSDate *)date
{
  UErrorCode err = U_ZERO_ERROR;
  UDate udate;
  UCalendar *cal = [self _clonedICUCal];

  if (cal == NULL)
    {
      return;
    }

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
}

- (void) getEra: (NSInteger *) eraValuePointer
yearForWeekOfYear: (NSInteger *) yearValuePointer
     weekOfYear: (NSInteger *) weekValuePointer
        weekday: (NSInteger * )weekdayValuePointer
       fromDate: (NSDate *)date
{
  UErrorCode err = U_ZERO_ERROR;
  UDate udate;
  UCalendar *cal = [self _clonedICUCal];

  if (cal == NULL)
    {
      return;
    }

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

  ucal_close(cal);
}

- (void) encodeWithCoder: (NSCoder*) encoder
{
  GSCalendarData *calendarData = [self _calendarData];

  [encoder encodeObject: [calendarData identifier]];
  [encoder encodeObject: [[calendarData locale] localeIdentifier]];
  [encoder encodeObject: [calendarData timeZone]];
}

- (id) initWithCoder: (NSCoder*)decoder
{
  NSString *identifier = [decoder decodeObject];

  if (self = [self initWithCalendarIdentifier: identifier])
    {
      NSString *localeIdentifier = [decoder decodeObject];
      NSTimeZone *timeZone = [decoder decodeObject];

      [self setLocale: [NSLocale localeWithLocaleIdentifier: localeIdentifier]];
      [self setTimeZone: timeZone];
    }

  return self;
}

- (instancetype) copyWithZone: (NSZone*)zone
{
  NSCalendar *result = [[[self class] alloc] initWithCalendarData: [self _calendarData]];

  return result;
}

@end

@implementation GSAutoupdatingCurrentCalendar {
  // Because we may update our _calendarData at any
  // time, we need to lock read/writes to maintain thread safety
  NSLock *_lock;
}

- (instancetype) init
{
  // This identifier may be nil
  NSString *identifier = [[NSLocale currentLocale] objectForKey:NSLocaleCalendarIdentifier];

  if (self = [super initWithCalendarIdentifier: identifier])
    {
      _lock = [[NSLock alloc] init];
    }

  return self;
}

- (GSCalendarData *) _calendarData
{
  GSCalendarData *calendarData;

  [_lock lock];
  calendarData = AUTORELEASE(RETAIN([super _calendarData]));
  [_lock unlock];

  return calendarData;
}

- (void) _setCalendarData: (GSCalendarData *) calendarData
{
  [_lock lock];
  [super _setCalendarData: calendarData];
  [_lock unlock];
}

- (void) dealloc
{
  DESTROY(_lock);
  [super dealloc];
}

- (void) _refreshAutoupdatingCalendarWithCalendar: (NSString *)calendar
                                           locale: (NSString *)localeID
                                         timeZone: (NSTimeZone *)timeZone
{
  NSLocale *currentLocale = [NSLocale currentLocale];

  [self _setCalendarData: [[GSCalendarData alloc] initWithIdentifier: calendar locale: currentLocale timeZone: timeZone]];
}

@end


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
  if ([object isKindOfClass:[NSDateComponents class]])
    {
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
            [self nanosecond] != [object nanosecond])
        {
          return NO;
        }

      if ([self leapMonth] != [object leapMonth])
        {
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
