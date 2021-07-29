
/** Enterprise Control Configuration and Logging

   Copyright (C) 2012 Free Software Foundation, Inc.

   Written by: Richard Frith-Macdonald <rfm@gnu.org>
   Date: Febrary 2010
   Originally developed from 1996 to 2012 by Brainstorm, and donated to
   the FSF.

   This file is part of the GNUstep project.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 3 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Library General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this library; if not, write to the Free
   Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
   Boston, MA 02111 USA.

   */

#import <Foundation/Foundation.h>
#import <GNUstepBase/GSMime.h>

#import "EcHost.h"
#import "EcProcess.h"
#import "EcAlarm.h"
#import "EcAlerter.h"
#import "NSFileHandle+Printf.h"

static unsigned	throttleAt = 12;

@interface EcAlertRegex: NSObject
{
  NSRegularExpression	*regex;
}
- (id) initWithString: (NSString*)pattern;
- (NSString*) match: (NSString*)string;
- (NSArray*) matches: (NSString*)string;
@end

@implementation	EcAlertRegex
- (void) dealloc
{
  [regex release];
  [super dealloc];
}

- (id) initWithString: (NSString*)pattern
{
  if ((self = [super init]) != nil)
    {
      regex = [[NSRegularExpression alloc]
        initWithPattern: pattern
                options: NSRegularExpressionDotMatchesLineSeparators
                  error: NULL];
      if (regex == nil)
        {
          NSLog(@"Failed to compile regex - '%@'", pattern);
          DESTROY(self);
        }
    }
  return self;
}

- (NSString*) match: (NSString*)string
{
  NSRange r = NSMakeRange(0, [string length]);

  r = [regex rangeOfFirstMatchInString: string options: 0 range: r];
  return r.length != 0 ? [string substringWithRange: r] : nil;
}

- (NSArray*) matches: (NSString*)string
{
  NSRange 		r = NSMakeRange(0, [string length]);
  NSTextCheckingResult	*match;
  NSUInteger		numberOfRanges;
  NSUInteger		index;
  NSMutableArray	*matches;

  match = [regex firstMatchInString: string options: 0 range: r];
  if (0 == (numberOfRanges = [match numberOfRanges]))
    {
      return nil;
    }
  matches = [NSMutableArray arrayWithCapacity: numberOfRanges];
  for (index = 0; index < numberOfRanges; index++)
    {
      r = [match rangeAtIndex: index];
      if (0 == r.length)
	{
	  [matches addObject: @""];
	}
      else
	{
	  [matches addObject: [string substringWithRange: r]];
	}
    }
  return matches;
}
@end

#define	MINUTES	60

@interface	EcAlertThrottle : NSObject
{
  uint32_t	mins[MINUTES];
  uint64_t	base;
  BOOL		throttled;
}
/** Tracks actions performed agains a limit per hour.
 * Returns YES if the current alert must not be sent, NO otherwise.
 * If the limit is with the current alert or an earlier one, returns
 * the time at which alerting may resume.
 */
- (BOOL) shouldThrottle: (NSDate**)until;
@end

@implementation	EcAlertThrottle

- (NSString*) description
{
  char		buf[BUFSIZ];
  unsigned	minute;
  unsigned	i;

  minute = (((uint64_t)[NSDate timeIntervalSinceReferenceDate]) - base) / 60;
  if (minute >= MINUTES)
    {
      minute = MINUTES-1;
    }
  buf[0] = '\0';
  for (i = 0; i <= minute; i++)
    {
      if (i > 0)
	{
	  if (i%6 == 0)
	    {
	      strcat(buf, "\n");
	    }
	  else
	    {
	      strcat(buf, ", ");
	    }
	}
      sprintf(buf + strlen(buf), "%u", (unsigned)mins[i]);
    }
  return [[super description] stringByAppendingFormat:
    @"Base: %@, Throttled: %@, Counts:\n%s\n",
    [NSDate dateWithTimeIntervalSinceReferenceDate: (NSTimeInterval)base],
    throttled ? @"Yes" : @"No", buf];
}

- (BOOL) shouldThrottle: (NSDate**)until
{
  uint64_t	now = (uint64_t)[NSDate timeIntervalSinceReferenceDate];
  uint32_t	sum = 0;
  uint32_t	minute;
  uint32_t	index;
  BOOL		wasThrottled;

  if (0 == base)
    {
      base = now;		// Starting throttling period.
    }

  /* The number of minutes since the base time gives us the minute
   * into which we should be recording the new event.
   */
  minute = (now - base) / 60;

  if (minute >= 2*MINUTES)
    {
      /* As it's at least an hour since the last event, we can simply
       * start a new recording period.
       */ 
      base = now;
      memset(mins, '\0', MINUTES * sizeof(*mins));
      minute = 0;
    }
  else if (minute > (MINUTES-1))
    {
      int	move = minute - (MINUTES-1);
      
      /* The recording period started over an hour ago, so we must adjust
       * it forward so that the current time is in its 59th minute.
       */
      memmove(mins, mins + move, (MINUTES - move) * sizeof(*mins));
      memset(mins + (MINUTES - move), '\0', move * sizeof(*mins));
      base += move * 60;
      minute = (MINUTES-1);
    }
  for (index = 0; index <= minute; index++)
    {
      sum += mins[index];
    }
  if (NO == (wasThrottled = throttled))
    {
      mins[minute]++;
      sum++;
    }

  if (sum >= throttleAt)
    {
      throttled = YES;
      /* The time at which unthrottling occurs is MINUTES after the
       * first alert in the current recording period.
       */
      for (index = 0; index <= minute; index++)
	{
	  if (mins[index] > 0)
	    {
	      break;
	    }
	}
      *until = [NSDate dateWithTimeIntervalSinceReferenceDate:
	(NSTimeInterval)(base + 60*(index+1) + 60*MINUTES)];
    }
  else
    {
      throttled = NO;
      *until = nil;
    }
  return wasThrottled;
}
@end


@interface      EcAlerterEvent : NSObject
{
  @public
  NSMutableDictionary   *m;
  NSString              *hostName;
  NSString              *identifier;
  NSString              *serverName;
  NSString              *severityText;
  NSString              *text;
  NSString              *component;
  NSDate                *timestamp;
  NSString              *type;
  int                   duration;
  int                   reminder;
  int                   severity;
  BOOL                  isAlarm;
  BOOL                  isClear;
}
- (NSString*) alarmText;
@end
@implementation EcAlerterEvent
- (NSString*) alarmText
{
  if (NO == isAlarm)
    {
      return nil;
    }
  if (YES == isClear)
    {
      return [identifier stringByAppendingString: @"(clear)"];
    }
  return [identifier stringByAppendingString: @"(alarm)"];
}
- (void) dealloc
{
  RELEASE(hostName);
  RELEASE(identifier);
  RELEASE(m);
  RELEASE(serverName);
  RELEASE(severityText);
  RELEASE(text);
  RELEASE(timestamp);
  RELEASE(component);
  RELEASE(type);
  [super dealloc];
}
@end

static NSMutableString *
replaceFields(NSDictionary *fields, NSString *template)
{
  NSMutableString	*m;

  m = [[template mutableCopy] autorelease];
  if (nil != m)
    {
      NSEnumerator	*e;
      NSString		*k;

      e = [fields keyEnumerator];
      while (nil != (k = [e nextObject]))
	{
	  if (NO == [k isEqualToString: @"Replacement"])
	    {
	      NSString	*v;

	      v = [[fields objectForKey: k] description];
	      k = [NSString stringWithFormat: @"{%@}", k];
	      [m replaceOccurrencesOfString: k
				 withString: v
				    options: NSLiteralSearch
				      range: NSMakeRange(0, [m length])];
	    }
	}
    }
  return m;
}

@implementation	EcAlerter : NSObject

- (void) _setEFrom: (NSString*)s
{
  if (nil == s)
    {
      /* Can't have a nil sender ... use (generate if needed) default.
       */
      if (nil == eDflt)
        {
          eDflt = [[NSString alloc] initWithFormat: @"alerter@%@",
            [[NSHost currentHost] wellKnownName]];
        }
      s = eDflt;
    }
  if (s != eFrom && NO == [s isEqual: eFrom])
    {
      NSRange   r;

      ASSIGNCOPY(eFrom, s);
      r = [s rangeOfString: @"@"];
      if (r.length > 0)
        {
          s = [s substringFromIndex: NSMaxRange(r)];
        }
      ASSIGNCOPY(eBase, s);
    }
}

- (void) smtpClient: (GSMimeSMTPClient*)client mimeFailed: (GSMimeDocument*)doc
{
  failEmail++;
  NSLog(@"Message failed: %@", doc);
}

- (void) smtpClient: (GSMimeSMTPClient*)client mimeSent: (GSMimeDocument*)doc
{
  sentEmail++;
  if (YES == debug)
    {
      NSLog(@"Message sent: %@", doc);
    }
}

- (void) smtpClient: (GSMimeSMTPClient*)client mimeUnsent: (GSMimeDocument*)doc
{
  failEmail++;
  NSLog(@"Message dropped: %@", doc);
}

- (GSMimeSMTPClient*) _smtp
{
  if (nil == smtp)
    {
      smtp = [GSMimeSMTPClient new];
    }
  [lock lock];
  if (nil == eFrom)
    {
      [self _setEFrom: nil];
    }
  if (nil != eHost)
    {
      [smtp setHostname: eHost];
    }
  if (nil != ePort)
    {
      [smtp setPort: ePort];
    }
  [lock unlock];
  [smtp setDelegate: self];
  return smtp;
}

- (BOOL) configure: (NSNotification*)n
{
  NSUserDefaults	*d;
  NSDictionary		*c;
  BOOL                  ok;

  d = [EcProc cmdDefaults];
  c = [d dictionaryForKey: @"Alerter"];
  ok = [self configureWithDefaults: c];
  return ok;
}

- (BOOL) configureWithDefaults: (NSDictionary*)c
{
  int	i = [[c objectForKey: @"ThrottleAt"] intValue];

  if (i <= 0 || i > 3600) i = 12;
  throttleAt = i;
  debug = [[c objectForKey: @"Debug"] boolValue];
  quiet = [[c objectForKey: @"Quiet"] boolValue];
  supersede = [[c objectForKey: @"Supersede"] boolValue];
  [lock lock];
  [self _setEFrom: [c objectForKey: @"EmailFrom"]];
  ASSIGNCOPY(eHost, [c objectForKey: @"EmailHost"]);
  if (nil == eHost) eHost = @"localhost";
  ASSIGNCOPY(ePort, [c objectForKey: @"EmailPort"]);
  if (nil == ePort) ePort = @"25";
  [lock unlock];
  [self setRules: [c objectForKey: @"Rules"]];
  return YES;
}

- (void) setRules: (NSArray*)ra
{
  NSMutableArray        *r = AUTORELEASE([ra mutableCopy]); 
  NSUInteger            i;

  for (i = 0; i < [r count]; i++)
    {
      NSMutableDictionary	*md;
      NSObject                  *obj;
      NSString			*str;
      EcAlertRegex		*val;

      md = [[r objectAtIndex: i] mutableCopy];
      [r replaceObjectAtIndex: i withObject: md];
      [md release];

      str = [md objectForKey: @"Host"];
      [md removeObjectForKey: @"HostRegex"];
      if (str != nil)
        {
	  val = [[EcAlertRegex alloc] initWithString: str];
	  if (nil == val)
	    {
	      [r removeObjectAtIndex: i--];
	      continue;
	    }
	  [md setObject: val forKey: @"HostRegex"];
	  [val release];
	}

      str = [md objectForKey: @"Pattern"];
      [md removeObjectForKey: @"PatternRegex"];
      if (str != nil)
        {
	  val = [[EcAlertRegex alloc] initWithString: str];
	  if (val == nil)
	    {
	      [r removeObjectAtIndex: i--];
	      continue;
	    }
	  [md setObject: val forKey: @"PatternRegex"];
	  RELEASE(val);
	}

      str = [md objectForKey: @"Server"];
      [md removeObjectForKey: @"ServerRegex"];
      if (str != nil)
        {
	  val = [[EcAlertRegex alloc] initWithString: str];
	  if (val == nil)
	    {
	      [r removeObjectAtIndex: i--];
	      continue;
	    }
	  [md setObject: val forKey: @"ServerRegex"];
	  RELEASE(val);
	}

      str = [md objectForKey: @"SeverityText"];
      [md removeObjectForKey: @"SeverityTextRegex"];
      if (str != nil)
        {
	  val = [[EcAlertRegex alloc] initWithString: str];
	  if (val == nil)
	    {
	      [r removeObjectAtIndex: i--];
	      continue;
	    }
	  [md setObject: val forKey: @"SeverityTextRegex"];
	  RELEASE(val);
	}

      str = [md objectForKey: @"Extra1"];
      [md removeObjectForKey: @"Extra1Regex"];
      if (str != nil)
        {
	  val = [[EcAlertRegex alloc] initWithString: str];
	  if (val == nil)
	    {
	      [r removeObjectAtIndex: i--];
	      continue;
	    }
	  [md setObject: val forKey: @"Extra1Regex"];
	  RELEASE(val);
	}

      str = [md objectForKey: @"Extra2"];
      [md removeObjectForKey: @"Extra2Regex"];
      if (str != nil)
        {
	  val = [[EcAlertRegex alloc] initWithString: str];
	  if (val == nil)
	    {
	      [r removeObjectAtIndex: i--];
	      continue;
	    }
	  [md setObject: val forKey: @"Extra2Regex"];
	  RELEASE(val);
	}

      str = [md objectForKey: @"ActiveFrom"];
      if (nil != str)
        {
          NSDate        *d = [NSDate dateWithString: str];

          if (nil == d)
            {
              NSLog(@"ActiveFrom='%@' is not a valid date/time", str);
              [r removeObjectAtIndex: i--];
              continue;
            }
          else
            {
              [md setObject: d forKey: @"ActiveFrom"];
            }
        }
      str = [md objectForKey: @"ActiveTo"];
      if (nil != str)
        {
          NSDate        *d = [NSDate dateWithString: str];

          if (nil == d)
            {
              NSLog(@"ActiveTo='%@' is not a valid date/time", str);
              [r removeObjectAtIndex: i--];
              continue;
            }
          else
            {
              [md setObject: d forKey: @"ActiveTo"];
            }
        }
      str = [md objectForKey: @"ActiveTimezone"];
      if (nil != str)
        {
          NSTimeZone    *d = [NSTimeZone timeZoneWithName: str];

          if (nil == d)
            {
              NSLog(@"ActiveTimezone='%@' is not a valid time zone", str);
              [r removeObjectAtIndex: i--];
              continue;
            }
          [md setObject: d forKey: @"ActiveTimeZone"];
        }
      obj = [md objectForKey: @"ActiveTimes"];
      if ([obj isKindOfClass: [NSString class]])
        {
          obj = (NSString*)[NSDictionary dictionaryWithObjectsAndKeys:
            obj, @"*", nil];
        }
      if ([obj isKindOfClass: [NSDictionary class]])
        {
          NSMutableDictionary   *t = [[obj mutableCopy] autorelease];
          NSEnumerator          *e = [[t allKeys] objectEnumerator];

          while (nil != (str = [e nextObject]))
            {
              NSString          *k = [str stringByTrimmingSpaces];
              NSMutableArray    *a;
              NSUInteger        j;
              NSInteger         lastMinute = 0;

              if (YES == [k isEqual: @"*"])
                {
                  k = @"*";
                }
              else if (YES == [k caseInsensitiveCompare: @"Monday"])
                {
                  k = @"Monday";
                }
              else if (YES == [k caseInsensitiveCompare: @"Tuesday"])
                {
                  k = @"Tuesday";
                }
              else if (YES == [k caseInsensitiveCompare: @"Wednesday"])
                {
                  k = @"Wednesday";
                }
              else if (YES == [k caseInsensitiveCompare: @"Thursday"])
                {
                  k = @"Thursday";
                }
              else if (YES == [k caseInsensitiveCompare: @"Friday"])
                {
                  k = @"Friday";
                }
              else if (YES == [k caseInsensitiveCompare: @"Saturday"])
                {
                  k = @"Saturday";
                }
              else if (YES == [k caseInsensitiveCompare: @"Sunday"])
                {
                  k = @"Sunday";
                }
              else
                {
                  NSLog(@"ActiveTimes='%@' with bad day of week", obj);
                  [r removeObjectAtIndex: i--];
                  continue;
                }
              a = [[[[t  objectForKey: str] componentsSeparatedByString: @","]
                mutableCopy] autorelease];
              j = [a count];
              while (j-- > 0)
                {
                  NSMutableArray        *r;
                  int                   from;
                  int                   to;
                  int                   h;
                  int                   m;
                  int                   c;

                  str = [[a objectAtIndex: j] stringByTrimmingSpaces];
                  if ([str length] == 0)
                    {
                      [a removeObjectAtIndex: j];
                      continue;
                    }
                  r = [[[str componentsSeparatedByString: @"-"]
                    mutableCopy] autorelease];
                  if ([r count] != 2)
                    {
                      NSLog(@"ActiveTimes='%@' with missing '-' in time range",
                        obj);
                      [r removeObjectAtIndex: i--];
                      continue;
                    }
                  str = [r objectAtIndex: 0];
                  c = sscanf([str UTF8String], "%d:%d", &h, &m);
                  if (0 == c)
                    {
                      NSLog(@"ActiveTimes='%@' with missing HH:MM", obj);
                      [r removeObjectAtIndex: i--];
                      continue;
                    }
                  if (1 == c) m = 0;
                  if (h < 0 || h > 23)
                    {
                      NSLog(@"ActiveTimes='%@' with hour out of range", obj);
                    }
                  if (m < 0 || m > 59)
                    {
                      NSLog(@"ActiveTimes='%@' with minute out of range", obj);
                      [r removeObjectAtIndex: i--];
                      continue;
                    }
                  from = (h * 60) + m;
                  
                  str = [r objectAtIndex: 1];
                  c = sscanf([str UTF8String], "%d:%d", &h, &m);
                  if (0 == c)
                    {
                      NSLog(@"ActiveTimes='%@' with missing HH:MM", obj);
                      [r removeObjectAtIndex: i--];
                      continue;
                    }
                  if (1 == c) m = 0;
                  if (h < 0 || h > 24 || (24 == h && 0 != m))
                    {
                      NSLog(@"ActiveTimes='%@' with hour out of range", obj);
                    }
                  if (m < 0 || m > 59)
                    {
                      NSLog(@"ActiveTimes='%@' with minute out of range", obj);
                      [r removeObjectAtIndex: i--];
                      continue;
                    }
                  if (0 == h && 0 == m)
                    {
                      h = 24;
                    }
                  to = (h * 60) + m;
 
                  if (to <= from)
                    {
                      NSLog(@"ActiveTimes='%@' range end earlier than start",
                        obj);
                      [r removeObjectAtIndex: i--];
                      continue;
                    }
                  if (from < lastMinute)
                    {
                      NSLog(@"ActiveTimes='%@' range start earlier than"
                        @" preceding one", obj);
                      [r removeObjectAtIndex: i--];
                      continue;
                    }
                  lastMinute = to;
                  [r replaceObjectAtIndex: 0
                               withObject: [NSNumber numberWithInt: from]];
                  [r replaceObjectAtIndex: 1
                               withObject: [NSNumber numberWithInt: to]];
                  [a replaceObjectAtIndex: j withObject: r];
                }
              if (0 == [a count])
                {
                  NSLog(@"ActiveTimes='%@' with empty time range", obj);
                  [r removeObjectAtIndex: i--];
                  continue;
                }
              [t setObject: a forKey: k];
            }
          [md setObject: obj forKey: @"ActiveTimes"];
        }
      else if (obj != nil)
        {
          NSLog(@"ActiveTimes='%@' is not valid", obj);
          [r removeObjectAtIndex: i--];
          continue;
        }
    }
  [lock lock];
  ASSIGN(rules, r);
  [lock unlock];
  if (YES == debug)
    {
      NSLog(@"Installed Rules: %@", r);
    }
}

- (void) dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver: self];
  [timer invalidate];
  [self flushSms];
  [self flushEmail];
  [smtp flush: [NSDate dateWithTimeIntervalSinceNow: 30.0]];
  RELEASE(smtp);
  RELEASE(email);
  RELEASE(other);
  RELEASE(sms);
  RELEASE(rules);
  RELEASE(eBase);
  RELEASE(eDflt);
  RELEASE(eFrom);
  RELEASE(eHost);
  RELEASE(ePort);
  RELEASE(lock);
  [super dealloc];
}

- (NSString*) description
{
  NSString      *s;
  NSString	*err;

  if (nil == (err = [[[self _smtp] lastError] description]))
    {
      err = @"";
    }
  [lock lock];
  s = [NSString stringWithFormat: @"%@ -\nConfigured with %u rules\n"
    @"With SMTP %@:%@ as %@\n"
    @"Email sent: %"PRIu64", fail: %"PRIu64", pending:%@ %@\n"
    @"Other sent: %"PRIu64", fail: %"PRIu64", throttle:%u\n"
    @"SMS   sent: %"PRIu64", fail: %"PRIu64", pending:%@\n",
    [super description], (unsigned)[rules count],
    eHost, ePort, eFrom,
    sentEmail, failEmail, email ? email : @"none", err,
    sentOther, failOther, throttleAt,
    sentSms, failSms, sms ? sms : @"none"];
  [lock unlock];
  return s;
}

- (void) flushEmailForAddress: (NSString*)address
		      subject: (NSString*)subject
		      	 text: (NSString*)text
{
  NS_DURING
    {
      GSMimeDocument	*doc;

      doc = AUTORELEASE([GSMimeDocument new]);
      [doc setHeader: @"Subject" value: subject parameters: nil];
      [doc setHeader: @"To" value: address parameters: nil];
      [doc setContent: text type: @"text/plain" name: nil];
      [lock lock];
      [doc setHeader: @"From" value: eFrom parameters: nil];
      [lock unlock];
      [[self _smtp] send: doc];
    }
  NS_HANDLER
    {
      NSLog(@"Problem flushing email for address: %@, subject: %@, %@",
	address, subject, localException);
    }
  NS_ENDHANDLER
}

- (void) flushEmail
{
  NSDictionary		*destinations;

  NS_DURING
    {
      if ((destinations = email) != nil)
	{
	  NSEnumerator	*addressEnumerator = [destinations keyEnumerator];
	  NSString	*address;

	  DESTROY(email);
	  while ((address = [addressEnumerator nextObject]) != nil)
	    {
	      NSDictionary	*items = [destinations objectForKey: address];
	      NSEnumerator	*itemEnumerator = [items keyEnumerator];
	      NSString		*subject;

	      while ((subject = [itemEnumerator nextObject]) != nil)
		{
		  NSString	*text = [items objectForKey: subject];

		  [self flushEmailForAddress: address
				     subject: subject
					text: text];
		}
	    }
	}
    }
  NS_HANDLER
    {
      NSLog(@"Problem flushing email: %@", localException);
    }
  NS_ENDHANDLER
}

- (void) flushSms
{
  [sms removeAllObjects];
}

- (void) applyRules: (NSArray*)rulesArray
            toEvent: (EcAlerterEvent*)event
{
  NSAutoreleasePool     *pool = nil;
  NSTimeZone            *tz = nil;
  BOOL                  found = NO;
  NSCalendarDate        *now = [NSCalendarDate date];
  NSUInteger            minuteOfDay = 0;
  NSUInteger            dayOfWeek = 0;
  NSUInteger            i;

  if (YES == debug)
    {
      NSLog(@"Apply %u rules to %@", (unsigned)[rulesArray count], event);
    }
  for (i = 0; i < [rulesArray count]; i++)
    {
      NSDictionary	*times;
      NSDictionary	*d;
      NSString	        *match = nil;
      EcAlertRegex	*e;
      NSString	        *s;
      id		o;
      BOOL		isReminder;

      RELEASE(pool);
      pool = [NSAutoreleasePool new];
      d = [rulesArray objectAtIndex: i];

      times = [d objectForKey: @"ActiveTimes"];
      if (nil != times)
        {
          NSDate        *from = [d objectForKey: @"ActiveFrom"];
          NSDate        *to = [d objectForKey: @"ActiveTo"];
          BOOL          match = NO;

          if ((nil == from || [from earlierDate: now] == from)
            && (nil == to || [to laterDate: now] == to))
            {
              NSTimeZone        *z = [d objectForKey: @"ActiveTimezone"];
              NSArray           *ranges;
              NSUInteger        index;

              if (nil == z)
                {
                  static NSTimeZone *gmt = nil;

                  if (nil == gmt)
                    {
                      gmt = [[NSTimeZone timeZoneWithName: @"GMT"] retain];
                    }
                  z = gmt;
                }
              if (NO == [z isEqual: tz])
                {
                  ASSIGN(tz, z);
                  [now setTimeZone: tz];
                  minuteOfDay = [now hourOfDay] * 60 + [now minuteOfHour];
                  dayOfWeek = [now dayOfWeek];
                }

              switch (dayOfWeek)
                {
                  case 0: ranges = [times objectForKey: @"Sunday"]; break;
                  case 1: ranges = [times objectForKey: @"Monday"]; break;
                  case 2: ranges = [times objectForKey: @"Tuesday"]; break;
                  case 3: ranges = [times objectForKey: @"Wednesday"]; break;
                  case 4: ranges = [times objectForKey: @"Thursday"]; break;
                  case 5: ranges = [times objectForKey: @"Friday"]; break;
                  default: ranges = [times objectForKey: @"Saturday"]; break;
                }
              if (nil == ranges)
                {
                  ranges = [times objectForKey: @"*"];
                }
              index = [ranges count];
              while (index-- > 0)
                {
                  NSArray           *range;
                  NSUInteger        start;
                  
                  range = [ranges objectAtIndex: index];
                  start = [[range objectAtIndex: 0] unsignedIntegerValue];

                  if (minuteOfDay >= start)
                    {
                      NSUInteger    end;

                      end = [[range objectAtIndex: 1] unsignedIntegerValue];
                      if (minuteOfDay < end)
                        {
                          match = YES;
                        }
                      break;
                    }
                }
            }
          if (NO == match)
            {
              continue;
            }
        }

      s = [d objectForKey: @"Tagged"];
      if (s != nil && NO == [s isEqual: [event->m objectForKey: @"Tag"]])
        {
          continue;         // Not a match.
        }

      s = [d objectForKey: @"Type"];
      if (s != nil && [s isEqualToString: event->type] == NO)
        {
          /* Special case: the type 'Alarm' matches all three types
           * of alarm event (raise, reminder, and clear).
           */
          if (NO == event->isAlarm || [s isEqualToString: @"Alarm"] == NO)
            {
              continue;		// Not a match.
            }
        }

      /* The next set are matches only for alarms.
       */

      if (event->isAlarm && event->reminder > 0 && NO == event->isClear)
	{
	  int	ri;

	  isReminder = YES;
	  /* This is an alarm reminder (neither the initial alarm
	   * nor the clear), so we check the ReminderInterval.
	   * In order for a match to occur, the ReminderInterval
	   * must be set and must match the number of the reminder
	   * using division modulo the reminder interval value.
	   * NB, unlike other patterns, the absence of this one
	   * implies a match failure!
	   */
	  ri = [[d objectForKey: @"ReminderInterval"] intValue];
	  if (ri < 1 || (event->reminder % ri) != 0)
	    {
	      continue;		// Not a match.
	    }
	}
      else
	{
	  /* Not a reminder, so the ReminderInterval is ignored.
	   * Rules can match both alerts which are not reminders *and*
	   * alerts which are reminders, with the reminder interval
	   * being used only where applicable.
	   */
	  isReminder = NO;
	}

      if (nil != (s = [d objectForKey: @"DurationAbove"])
	&& (NO == isReminder || event->duration <= [s intValue]))
	{
	  continue;		// Not a match.
	}

      if (nil != (s = [d objectForKey: @"DurationBelow"])
	&& (NO == isReminder || event->duration >= [s intValue]))
	{
	  continue;		// Not a match.
	}

      if (nil != (s = [d objectForKey: @"ReminderAbove"])
	&& (NO == isReminder && event->reminder <= [s intValue]))
	{
	  continue;		// Not a match.
	}

      if (nil != (s = [d objectForKey: @"ReminderBelow"])
	&& (NO == isReminder || event->reminder >= [s intValue]))
	{
	  continue;		// Not a match.
	}

      if (nil != (s = [d objectForKey: @"Component"]))
	{
	  if (NO == [s isEqual: event->component])
	    {
	      continue;
	    }
	}

      if (nil != (e = [d objectForKey: @"SeverityTextRegex"])
	&& (NO == event->isAlarm || [e match: event->severityText] == nil))
	{
	  continue;		// Not a match.
	}

      if (nil != (s = [d objectForKey: @"SeverityCode"])
	&& (NO == event->isAlarm || [s intValue] != event->severity))
	{
	  continue;		// Not a match.
	}

      e = [d objectForKey: @"ServerRegex"];
      if (e != nil && [e match: event->serverName] == nil)
        {
          continue;		// Not a match.
        }
      e = [d objectForKey: @"HostRegex"];
      if (e != nil && [e match: event->hostName] == nil)
        {
          continue;		// Not a match.
        }

      e = [d objectForKey: @"PatternRegex"];
      if (nil != e)
        {
          [event->m removeObjectForKey: @"Match"];
          if (nil == (match = [e match: event->text]))
            {
              continue;		// Not a match.
            }
          [event->m setObject: match forKey: @"Match"];
        }

      found = YES;
      s = [NSString stringWithFormat: @"%u", (unsigned)i];
      [event->m setObject: s forKey: @"Position"];
      if (YES == debug)
        {
	  if (nil == (s = [event->m objectForKey: @"RuleID"]))
	    {
	      NSLog(@"Rule (pos %u) matched %@ with %@",
		(unsigned)i, d, event->m);
	    }
	  else
	    {
	      NSLog(@"Rule %@ (pos %u) matched %@ with %@",
		s, (unsigned)i, d, event->m);
	    }
        }

      /*
       * If the Extra1 or Extra2 patterns are matched,
       * The matching strings are made available for
       * substitution into the replacement message.
       */
      e = [d objectForKey: @"Extra1Regex"];
      if (nil != e)
        {
	  NSArray	*matches = [e matches: event->text];
	  int		i;

          [event->m removeObjectForKey: @"Extra1"];
	  if (nil != matches)
	    {
              [event->m setObject: [matches objectAtIndex: 0]
			   forKey: @"Extra1"];
	    }
	  for (i = 1; i <= 9; i++)
	    {
	      NSString	*key = [NSString stringWithFormat: @"Extra1_%d", i];

	      [event->m removeObjectForKey: key];
	      if (i < [matches count])
		{
		  [event->m setObject: [matches objectAtIndex: i] forKey: key];
		}
            }
        }

      e = [d objectForKey: @"Extra2Regex"];
      if (nil != e)
        {
	  NSArray	*matches = [e matches: event->text];
	  int		i;

          [event->m removeObjectForKey: @"Extra2"];
	  if (nil != matches)
	    {
              [event->m setObject: [matches objectAtIndex: 0]
			   forKey: @"Extra2"];
	    }
	  for (i = 1; i <= 9; i++)
	    {
	      NSString	*key = [NSString stringWithFormat: @"Extra2_%d", i];

	      [event->m removeObjectForKey: key];
	      if (i < [matches count])
		{
		  [event->m setObject: [matches objectAtIndex: i] forKey: key];
		}
            }
        }

      s = [d objectForKey: @"Rewrite"];
      if (nil != s)
        {
          s = replaceFields(event->m, s);
          [event->m setObject: s forKey: @"Message"];
        }

      s = [d objectForKey: @"Subject"];
      if (s != nil)
        {
          s = replaceFields(event->m, s);
          [event->m setObject: s forKey: @"Subject"];
        }

      /* Set the tag for this event if necessary ... done *after*
       * all matching, but before sending out the alerts.
       */
      if (nil != [d objectForKey: @"Tag"])
        {
          NSString  *s = replaceFields(event->m, [d objectForKey: @"Tag"]);

          [event->m setObject: s forKey: @"Tag"];
        }

      NS_DURING
        {
          o = [d objectForKey: @"Log"];
          if ([o isKindOfClass: [NSString class]] == YES)
            {
              if ([o hasPrefix: @"("])
                {
                  o = [(NSString*)o propertyList];
                }
              else
                {
                  o = [NSArray arrayWithObject: o];
                }
            }
          if (o != nil)
            {
              NSString *s = [d objectForKey: @"LogReplacement"];

              if (nil == s)
                {
                  s = [d objectForKey: @"Replacement"];
                  if (nil == s)
                    {
                      s = @"{Message}";
                    }
                }
              [event->m setObject: s forKey: @"Replacement"];
              [self log: event->m to: o];
            }
        }
      NS_HANDLER
        {
          NSLog(@"Exception handling log for rule: %@",
            localException);
        }
      NS_ENDHANDLER
      [event->m removeObjectForKey: @"Replacement"];

      NS_DURING
        {
          o = [d objectForKey: @"Email"];
          if ([o isKindOfClass: [NSString class]] == YES)
            {
              if ([o hasPrefix: @"("])
                {
                  o = [(NSString*)o propertyList];
                }
              else
                {
                  o = [NSArray arrayWithObject: o];
                }
            }
          if (o != nil)
            {
              NSString	*s;

              s = [d objectForKey: @"EmailReplacement"];
              if (nil == s)
                {
                  s = [d objectForKey: @"Replacement"];
                  if (nil == s)
                    {
                      /* Full details.  */
                      s = @"{Server}({Host}): {Timestamp} {Type}"
                        @" - {Message}";
                    }
                }
              [event->m setObject: s forKey: @"Replacement"];
              if (YES == event->isAlarm && NO == quiet)
                {
                  NSLog(@"Send Email for %@ to %@", [event alarmText], o);
                }
              [self mail: event->m to: o];
            }
        }
      NS_HANDLER
        {
          NSLog(@"Exception handling Email send for rule: %@",
            localException);
        }
      NS_ENDHANDLER
      [event->m removeObjectForKey: @"Replacement"];

      NS_DURING
        {
          o = [d objectForKey: @"Threaded"];
          if ([o isKindOfClass: [NSString class]] == YES)
            {
              if ([o hasPrefix: @"("])
                {
                  o = [(NSString*)o propertyList];
                }
              else
                {
                  o = [NSArray arrayWithObject: o];
                }
            }
          if (o != nil)
            {
              NSString	*s;

              if (event->reminder > 0)
                {
                  NSString      *s;

                  /* Pass the reminder value to the email code so it
                   * can generate In-Reply-To and References headers
                   * for threading.
                   */
                  s = [NSString stringWithFormat: @"%d", event->reminder];
                  [event->m setObject: s forKey: @"EmailThreading"];
                }

              s = [d objectForKey: @"EmailReplacement"];
              if (nil == s)
                {
                  s = [d objectForKey: @"Replacement"];
                  if (nil == s)
                    {
                      /* Full details.  */
                      s = @"{Server}({Host}): {Timestamp} {Type}"
                        @" - {Message}";
                    }
                }
              [event->m setObject: s forKey: @"Replacement"];
              if (YES == event->isAlarm && NO == quiet)
                {
                  NSLog(@"Send Email for %@ to %@", [event alarmText], o);
                }
              [self mail: event->m to: o];
            }
        }
      NS_HANDLER
        {
          NSLog(@"Exception handling Email send for rule: %@",
            localException);
        }
      NS_ENDHANDLER
      [event->m removeObjectForKey: @"Replacement"];
      [event->m removeObjectForKey: @"ReminderInterval"];

      NS_DURING
        {
          o = [d objectForKey: @"Other"];
          if ([o isKindOfClass: [NSString class]] == YES)
            {
              if ([o hasPrefix: @"("])
                {
                  o = [(NSString*)o propertyList];
                }
              else
                {
                  o = [NSArray arrayWithObject: o];
                }
            }
          if ([o isKindOfClass: [NSArray class]])
            {
	      NSEnumerator	*e = [o objectEnumerator];
	      NSString		*s;

	      while (nil != (s = [e nextObject]))
		{
		  EcAlertThrottle	*t;
		  NSDate		*until;
		  BOOL			throttled;
		  NSString		*before = nil;

		  s = [s description];
		  if (YES == event->isAlarm && NO == quiet)
		    {
		      NSLog(@"Other alert for %@ to %@", [event alarmText], s);
		    }
		  if (nil == other)
		    {
		      other = [NSMutableDictionary new];
		    }
		  if (nil == (t = [other objectForKey: s]))
		    {
		      t = [EcAlertThrottle new];
		      [other setObject: t forKey: s];
		      RELEASE(t);
		    }
		  if (debug)
		    {
		      before = [t description];
		    }
		  throttled = [t shouldThrottle: &until];
		  if (debug)
		    {
		      NSLog(@"Other destination: %@\nBefore %@\nAfter %@",
			s, before, [t description]);
		    }
		  if (throttled)
		    {
		      failOther++;
		    } 
		  else
		    {
		      if (nil != until)
			{
			  [event->m setObject: until forKey: @"Throttled"];
			}
		      if ([self other: event->m to: s])
			{
			  sentOther++;
			}
		      else
			{
			  failOther++;
			}
		      [event->m removeObjectForKey: @"Throttled"];
		    }
		}
	    }
        }
      NS_HANDLER
        {
          NSLog(@"Exception handling Other action for rule: %@",
            localException);
        }
      NS_ENDHANDLER
      [event->m removeObjectForKey: @"Replacement"];

      NS_DURING
        {
          o = [d objectForKey: @"Sms"];
          if ([o isKindOfClass: [NSString class]] == YES)
            {
              if ([o hasPrefix: @"("])
                {
                  o = [(NSString*)o propertyList];
                }
              else
                {
                  o = [NSArray arrayWithObject: o];
                }
            }
          if (o != nil)
            {
              NSString *s = [d objectForKey: @"SmsReplacement"];

              if (nil == s)
                {
                  s = [d objectForKey: @"Replacement"];
                  if (nil == s)
                    {
                      /* Use few spaces so that more of the
                       * message fits into an Sms. Omit Timestamp */
                      s = @"{Server}({Host}) {Type}-{Message}";
                    }
                }
              [event->m setObject: s forKey: @"Replacement"];
              if (YES == event->isAlarm && NO == quiet)
                {
                  NSLog(@"Send SMS for %@ to %@", [event alarmText], o);
                }
              [self sms: event->m to: o];
            }
        }
      NS_HANDLER
        {
          NSLog(@"Exception handling Sms send for rule: %@",
            localException);
        }
      NS_ENDHANDLER
      [event->m removeObjectForKey: @"Replacement"];

      s = [d objectForKey: @"Flush"];
      if (s != nil)
        {
          if ([s caseInsensitiveCompare: @"Email"] == NSOrderedSame)
            {
              [self flushEmail];
            }
          else if ([s caseInsensitiveCompare: @"Sms"] == NSOrderedSame)
            {
              [self flushSms];
            }
          else if ([s boolValue] == YES)
            {
              [self flushSms];
              [self flushEmail];
            }
        }

      if ([[d objectForKey: @"Stop"] boolValue] == YES)
        {
          if (YES == event->isAlarm && NO == quiet)
            {
              NSLog(@"Stop %@ with %@", [event alarmText], d);
            }
          break;	// Don't want to perform any more matches.
        }
    }
  if (NO == found)
    {
      if (YES == event->isAlarm && NO == quiet)
        {
          NSLog(@"No match of %@ with %@", [event alarmText], rulesArray);
        }
      else if (YES == debug)
        {
          NSLog(@"No match of %@ with %@", event->m, rulesArray);
        }
    }
  DESTROY(tz);
  RELEASE(pool);
}

- (void) handleAudit: (NSString*)text
            withHost: (NSString*)hostName
           andServer: (NSString*)serverName
           timestamp: (NSDate*)timestamp
{
  return;
}

- (void) handleEvent: (NSString*)text
            withHost: (NSString*)hostName
           andServer: (NSString*)serverName
           timestamp: (NSDate*)timestamp
          identifier: (NSString*)identifier
               alarm: (EcAlarm*)alarm
            reminder: (int)reminder
{
  NS_DURING
    {
      NSMutableDictionary	*m;
      NSString                  *str;
      NSArray                   *array;
      EcAlerterEvent            *event;
      
      event = AUTORELEASE([EcAlerterEvent new]);
      ASSIGN(event->text, text);
      ASSIGN(event->hostName, hostName);
      ASSIGN(event->serverName, serverName);
      ASSIGN(event->timestamp, timestamp);
      ASSIGN(event->identifier, identifier);

      if (nil == alarm)
        {
          event->severity = EcAlarmSeverityIndeterminate;
          event->severityText = @"";
          event->isAlarm = NO;
          event->isClear = NO;
          event->reminder = -1;
	  event->component = nil;
          if (nil != identifier)
            {
              event->type = @"Alert";
            }
          else
            {
              event->type = @"Error";
            }
        }
      else
        {
          event->severity = [alarm perceivedSeverity];
          ASSIGN(event->severityText,
            [EcAlarm stringFromSeverity: event->severity]);
          event->isAlarm = YES;
          event->reminder = reminder;
	  ASSIGN(event->component, [alarm moComponent]);
          if ([@"Clear" isEqual: [alarm extra]])
            {
              event->isClear = YES;
              event->type = @"Clear";
            }
          else
            {
              event->isClear = NO;
              if (0 == event->reminder)
                {
                  event->type = @"Raise";
                }
              else
                {
                  event->type = @"Alarm";
                }
            }
        }
      event->duration = (0.0 - [timestamp timeIntervalSinceNow]) / 60.0;

      m = event->m = [[NSMutableDictionary alloc] initWithCapacity: 20];
      [m setObject: event->serverName forKey: @"Server"];
      [m setObject: event->hostName forKey: @"Host"];
      [m setObject: event->type forKey: @"Type"];
      [m setObject: [NSString stringWithFormat: @"%d", event->severity]
            forKey: @"SeverityCode"];
      [m setObject: event->severityText forKey: @"SeverityText"];
      [m setObject: [event->timestamp description] forKey: @"Timestamp"];
      [m setObject: (event->isClear ? @"YES" : @"NO") forKey: @"IsClear"];
      if (event->reminder >= 0)
        {
          [m setObject: [NSString stringWithFormat: @"%d", event->reminder]
                forKey: @"Reminder"];
        }
      /* If the alarm has a responsible person/entity email address set,
       * make it available.
       */
      str = [[alarm userInfo] objectForKey: @"ResponsibleEmail"];
      if (nil != str)
        {
          [m setObject: str forKey: @"ResponsibleEmail"];
        }
      if ([event->identifier length] > 0)
        {
          [m setObject: event->identifier forKey: @"Identifier"];
        }
      [m setObject: [NSString stringWithFormat: @"%d", event->duration]
            forKey: @"Duration"];
      [m setObject: [NSString stringWithFormat: @"%d", event->duration / 60]
            forKey: @"Hours"];
      [m setObject: [NSString stringWithFormat: @"%02d", event->duration % 60]
            forKey: @"Minutes"];
      [m setObject: event->text forKey: @"Message"];
      [m setObject: event->text forKey: @"Original"];

      if (alarm)
	{
	  [m setObject: [alarm moComponent]
		forKey: @"AlarmComponent"];
	  [m setObject: [EcAlarm stringFromProbableCause: [alarm probableCause]]
		forKey: @"AlarmProbableCause"];
	  [m setObject: [alarm specificProblem]
		forKey: @"AlarmSpecificProblem"];
	  [m setObject: [alarm proposedRepairAction]
		forKey: @"AlarmProposedRepairAction"];
	  [m setObject: [alarm additionalText]
		forKey: @"AlarmAdditionalText"];
	}

      if (YES == event->isAlarm && NO == quiet)
        {
          NSLog(@"Handling %@ ... %@", [event alarmText], alarm);
        }
      [lock lock];
      array = RETAIN(rules);
      [lock unlock];
      [self applyRules: AUTORELEASE(array) toEvent: event];
    }
  NS_HANDLER
    {
      NSLog(@"Problem in handleInfo:'%@' ... %@", text, localException);
    }
  NS_ENDHANDLER
}

- (void) handleInfo: (NSString*)str
{
  NSString      *info = str;

  NS_DURING
    {
      NSArray		*a;
      NSUInteger	i;

      a = [str componentsSeparatedByString: @"\n"];
      for (i = 0; i < [a count]; i++)
	{
	  NSString		*inf = [a objectAtIndex: i];
	  NSRange		r;
          NSString              *tsString;
	  NSCalendarDate	*timestamp;
	  NSString		*serverName;
	  NSString		*hostName;
	  BOOL  		immediate;
	  BOOL  		isAudit;
	  unsigned		pos;

          inf = [inf stringByTrimmingSpaces];
	  str = inf;
	  if ([str length] == 0)
	    {
	      continue;	// Nothing to do
	    }

	 /* Record format is -
	  * serverName(hostName): timestamp Alert - message
	  * or
	  * serverName(hostName): timestamp Error - message
	  * or
	  * serverName(hostName): timestamp Audit - message
	  */
	  r = [str rangeOfString: @":"];
	  if (r.length == 0)
	    {
	      continue;		// Not an audit, alert or error
	    }
	  serverName = [str substringToIndex: r.location];
	  str = [str substringFromIndex: NSMaxRange(r)];
	  r = [serverName rangeOfString: @"("];
	  if (r.length == 0)
	    {
	      continue;		// Not an alert or error
	    }
	  pos = NSMaxRange(r);
	  hostName = [serverName substringWithRange:
	    NSMakeRange(pos, [serverName length] - pos - 1)];
	  serverName = [serverName substringToIndex: r.location];

          r = [str rangeOfString: @" Audit - "];
          if (r.length == 0)
            {
              isAudit = NO;
              r = [str rangeOfString: @" Alert - "];
              if (r.length == 0)
                {
                  r = [str rangeOfString: @" Error - "];
                  if (r.length == 0)
                    {
                      continue;		// Not an alert or error
                    }
                  immediate = NO;
                }
              else
                {
                  immediate = YES;
                }
            }
          else
            {
              isAudit = YES;
            }

          tsString = [str substringToIndex: r.location];
          tsString = [tsString stringByTrimmingSpaces];
	  timestamp = [NSCalendarDate
            dateWithString: tsString
            calendarFormat: @"%Y-%m-%d %H:%M:%S.%F %z"];
          if (nil == timestamp)
            {
              /* Old style.
               */
              timestamp = [NSCalendarDate
                dateWithString: tsString
                calendarFormat: @"%Y-%m-%d %H:%M:%S %z"];
            }

	  str = [str substringFromIndex: NSMaxRange(r)];

          if (nil == timestamp)
            {
              NSLog(@"Bad timestamp (%@) in handleInfo:'%@'", tsString, inf);
            }
          else if (YES == isAudit)
            {
              [self handleAudit: str
                       withHost: hostName
                      andServer: serverName
                      timestamp: timestamp];
            }
          else
            {
              [self handleEvent: str
                       withHost: hostName
                      andServer: serverName
                      timestamp: timestamp
                     identifier: (YES == immediate) ? (id)@"" : (id)nil
                          alarm: nil
                       reminder: -1];
            }
	}
    }
  NS_HANDLER
    {
      NSLog(@"Problem in handleInfo:'%@' ... %@", info, localException);
    }
  NS_ENDHANDLER
}

- (id) init
{
  if (nil != (self = [super init]))
    {
      lock = [NSLock new];
      timer = [NSTimer scheduledTimerWithTimeInterval: 240.0
					       target: self
					     selector: @selector(timeout:)
					     userInfo: nil
					      repeats: YES];
      [[NSNotificationCenter defaultCenter]
	addObserver: self
	selector: @selector(configure:)
	name: NSUserDefaultsDidChangeNotification
	object: [NSUserDefaults standardUserDefaults]];
      [self configure: nil];
    }
  return self;
}

- (void) log: (NSMutableDictionary*)m to: (NSArray*)destinations
{
  NSEnumerator	*e = [destinations objectEnumerator];
  NSString	*d;
  NSString	*s;

  /*
   * Perform {field-name} substitutions ...
   */
  s = replaceFields(m, [m objectForKey: @"Replacement"]);
  while ((d = [e nextObject]) != nil)
    {
      d = [d lastPathComponent];
      [[EcProc cmdLogFile: d] printf: @"%@\n", s];
    }
}

- (BOOL) other: (NSMutableDictionary*)m to: (NSString*)destination
{
  return NO;
}

- (void) mail: (NSMutableDictionary*)m to: (NSArray*)destinations
{
  NSEnumerator	*e = [destinations objectEnumerator];
  NSString	*identifier = [m objectForKey: @"Identifier"];
  BOOL		isClear = [[m objectForKey: @"IsClear"] boolValue];
  NSString	*d;
  NSString	*text;
  NSString	*subject;

  /*
   * Perform {field-name} substitutions ...
   */
  text = replaceFields(m, [m objectForKey: @"Replacement"]);

  subject = [m objectForKey: @"Subject"];
  if (nil == subject)
    {
      if ([identifier length] > 0)
        {
          if (YES == isClear)
            {
              subject = [NSString stringWithFormat: @"Clear %@", identifier];
            }
          else
            {
              subject = [NSString stringWithFormat: @"Alarm %@", identifier];
            }
        }
      else
        {
          subject = @"system alert";
        }
    }

  /* If we need to send immediately, don't buffer the message.
   */
  if (nil != identifier)
    {
      GSMimeDocument    *doc;
      NSString          *base;        

      [self _smtp];
      doc = AUTORELEASE([GSMimeDocument new]);
      [doc setHeader: @"Subject" value: subject parameters: nil];
      [doc setContent: text type: @"text/plain" name: nil];
      [lock lock];
      [doc setHeader: @"From" value: eFrom parameters: nil];
      base = RETAIN(eBase);
      [lock unlock];
      AUTORELEASE(base);

      if ([identifier length] > 0)
        {
          NSString      *mID;
          int           threadID;

          threadID = [[m objectForKey: @"EmailThreading"] intValue];
          if (threadID > 0)
            {
              NSString          *rep;
              NSMutableString   *ref;

              rep = [NSString stringWithFormat: @"<alrm%@@%@>",
                identifier, base];
              [doc setHeader: @"In-Reply-To" value: rep parameters: nil];
              ref = AUTORELEASE([rep mutableCopy]);
#if 0
              if (threadID > 1)
                {
                  int   index;

                  for (index = 1; index < threadID; index++)
                    {
                      [ref appendFormat: @"<alrm%@_%d@%@>",
                        identifier, index, base];
                    }
                }
#endif
              [doc setHeader: @"References" value: ref parameters: nil];
              mID = [NSString stringWithFormat: @"<alrm%@_%d@%@>",
                identifier, threadID, base];
            }
          else
            {
              mID = [NSString stringWithFormat: @"<alrm%@@%@>",
                identifier, base];
            }

          if (YES == isClear && threadID <= 0)
            {
              if (YES == supersede)
                {
                  /* Set all the headers likely to be used by clients to
                   * have this message supersede the original.
                   */
                  [doc setHeader: @"Obsoletes" value: mID parameters: nil];
                  [doc setHeader: @"Replaces" value: mID parameters: nil];
                  [doc setHeader: @"Supersedes" value: mID parameters: nil];
                }
              else
                {
                  /* Treat the clear as simply a repeat (new version) of the
                   * original message.
                   */
                  [doc setHeader: @"Message-ID" value: mID parameters: nil];
                }
            }
          else
            {
              [doc setHeader: @"Message-ID" value: mID parameters: nil];
            }
        }

      while ((d = [e nextObject]) != nil)
        {
          if (YES == [d hasPrefix: @"{ResponsibleEmail}"])
            {
              NSString  *s = [m objectForKey: @"ResponsibleEmail"];

              if ([s length] > 0)
                {
                  /* Use the ResponsibleEmail address from the alarm
                   */
                  d = s;
                }
              else
                {
                  /* Use the fallback (remaining text in the address)
                   */
                  d = [d substringFromIndex: 18];
                }
            }
          if (0 == [d length])
            {
              continue;
            }
          NS_DURING
            {
              GSMimeDocument    *msg;

              msg = AUTORELEASE([doc copy]);
              [msg setHeader: @"To" value: d parameters: nil];
              [smtp send: msg];
            }
          NS_HANDLER
            {
              NSLog(@"Problem flushing email for address: %@, subject: %@, %@",
                d, subject, localException);
            }
          NS_ENDHANDLER
        }
    }
  else
    {
      if (email == nil)
        {
          email = [NSMutableDictionary new];
        }
      while ((d = [e nextObject]) != nil)
        {
          NSMutableDictionary	*md;
          NSString		*msg;

          if (YES == [d hasPrefix: @"{ResponsibleEmail}"])
            {
              NSString  *s = [m objectForKey: @"ResponsibleEmail"];

              if ([s length] > 0)
                {
                  /* Use the ResponsibleEmail address from the alarm
                   */
                  d = s;
                }
              else
                {
                  /* Use the fallback (remaining text in the address)
                   */
                  d = [d substringFromIndex: 18];
                }
            }
          if (0 == [d length])
            {
              continue;
            }

          md = [email objectForKey: d];
          if (md == nil)
            {
              md = [NSMutableDictionary new];
              [email setObject: md forKey: d];
              RELEASE(md);
            }

          msg = [md objectForKey: subject];

          /* If adding the new text would take an existing message over the
           * size limit, send the existing stuff first.
           */
          if ([msg length] > 0 && [msg length] + [text length] + 2 > 20*1024)
            {
              AUTORELEASE(RETAIN(msg));
              [md removeObjectForKey: subject];
              [self flushEmailForAddress: d 
                                 subject: subject
                                    text: msg];
              msg = nil;
            }
          if (msg == nil)
            {
              msg = text;
            }
          else
            {
              msg = [msg stringByAppendingFormat: @"\n\n%@", text];
            }
          [md setObject: msg forKey: subject];
        }
    }
}

- (void) shutdown
{
  [self flushSms];
  [self flushEmail];
}

- (void) sms: (NSMutableDictionary*)m to: (NSArray*)destinations
{
  NSEnumerator	*e = [destinations objectEnumerator];
  NSString	*d;
  NSString	*s;

  /*
   * Perform {field-name} substitutions.
   */
  s = replaceFields(m, [m objectForKey: @"Replacement"]);
  if (sms == nil)
    {
      sms = [NSMutableDictionary new];
    }
  while ((d = [e nextObject]) != nil)
    {
      NSString	*msg = [sms objectForKey: d];

      if (nil == msg)
        {
	  msg = s;
	}
      else
        {
	  int	missed = 0;

	  failSms++;	// Replacing an existing message 
	  if ([msg hasPrefix: @"Missed("] == YES)
	    {
	      NSRange	r = [msg rangeOfString: @")"];

	      r = NSMakeRange(7, r.location - 7);
	      msg = [msg substringWithRange: r];
	      missed = [msg intValue];
	    }
	  missed++;
	  msg = [NSString stringWithFormat: @"Missed(%d)\n%@", missed, s];
	}
      [sms setObject: msg forKey: d];
    }
}

- (void) timeout: (NSTimer*)t
{
  [self flushSms];
  [self flushEmail];
}
@end

