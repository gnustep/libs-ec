
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
#import <Foundation/NSDebug.h>

#import "EcProcess.h"
#import "EcLogger.h"

NSString* const EcLoggersDidChangeNotification
  = @"EcLoggersDidChangeNotification";

@implementation	EcLogger

static Class            loggersClass;
static NSLock           *loggersLock;
static NSMutableArray	*loggers;
static NSArray          *modes;

+ (void) initialize
{
  if (self == [EcLogger class])
    {
      id	objects[1];

      loggersLock = [NSLock new];
      loggers = [[NSMutableArray alloc] initWithCapacity: 6];
      objects[0] = NSDefaultRunLoopMode;
      modes = [[NSArray alloc] initWithObjects: objects count: 1];
      [self setFactory: self];
    }
}

+ (EcLogger*) loggerForType: (EcLogType)t
{
  unsigned	count;
  EcLogger	*logger;

  [loggersLock lock];
  count = [loggers count];
  while (count-- > 0)
    {
      logger = [loggers objectAtIndex: count];

      if (logger->type == t)
	{
          [loggersLock unlock];
	  return logger;
	}
    }
  logger = [[loggersClass alloc] init];
  if (logger != nil)
    {
      logger->lock = [NSRecursiveLock new];
      logger->type = t;
      logger->key = [cmdLogKey(t) copy];
      logger->flushKey
	= [[NSString alloc] initWithFormat: @"%@Flush", logger->key];
      logger->serverKey
	= [[NSString alloc] initWithFormat: @"%@Server", logger->key];
      logger->interval = 10.0;
      logger->size = 8 * 1024;
      logger->message = [[NSMutableString alloc] initWithCapacity: 2048];
      if (LT_ERROR == t || LT_AUDIT == t || LT_ALERT == t)
        {
          logger->shouldForward = YES;
        }

      [[NSNotificationCenter defaultCenter]
	addObserver: logger
	selector: @selector(update)
	name: NSUserDefaultsDidChangeNotification
	object: [EcProc cmdDefaults]];
      [logger update];
      [loggers addObject: logger];
      RELEASE(logger);
    }
  [loggersLock unlock];
  return logger;
}

+ (void) setFactory: (Class)c
{
  NSMutableArray        *old = nil;

  if (Nil == c) c = [self class];
  NSAssert([c isSubclassOfClass: self], NSInvalidArgumentException);
  [loggersLock lock];
  if (loggersClass != c)
    {
      old = loggers;
      loggers = [NSMutableArray new];
      loggersClass = c;
    }
  [loggersLock unlock];
  if (nil != old)
    {
      [old makeObjectsPerformSelector: @selector(flush)];
      [old release];
      [[NSNotificationCenter defaultCenter] postNotificationName:
	EcLoggersDidChangeNotification object: self];
    }
}

/* Should only be called on main thread, but doesn't matter.
 */
- (oneway void) cmdGnip: (id <CmdPing>)from
               sequence: (unsigned)num
                  extra: (NSData*)data
{
  return;
}

/*
 * When connecting to a logging server, we need to register so it
 * knows who we are.
 * Should only be called on main thread.
 */
- (void) cmdMadeConnectionToServer: (NSString*)name
{
  id<CmdLogger>	server;

  server = (id<CmdLogger>)[EcProc server: name];
  [server registerClient: self
              identifier: [[NSProcessInfo processInfo] processIdentifier]
                    name: cmdLogName()
               transient: NO];
}

/* Should only be called on main thread, but doesn't matter.
 */
- (oneway void) cmdPing: (id <CmdPing>)from
               sequence: (unsigned)num
                  extra: (NSData*)data
{
  [from cmdGnip: self sequence: num extra: nil];
}

/* Should only be called on main thread.
 */
- (oneway void) cmdQuit: (NSInteger)status
{
  [EcProc cmdQuit: status];
}

- (void) dealloc
{
  [self flush];
  [timer invalidate];
  [[NSNotificationCenter defaultCenter] removeObserver: self];
  RELEASE(key);
  RELEASE(flushKey);
  RELEASE(serverKey);
  RELEASE(serverName);
  RELEASE(message);
  RELEASE(lock);
  [super dealloc];
}

- (NSString*) description
{
  NSMutableString	*s = [NSMutableString stringWithCapacity: 256];

  [lock lock];
  if (NO == shouldForward)
    {
      [s appendFormat: @"%@ output to file only.\n", key];
    }
  else if (size == 0)
    {
      [s appendFormat: @"%@ output is immediate.\n", key];
    }
  else if (interval > 0.0)
    {
      [s appendFormat: @"%@ flushed every %g seconds", key, interval];
      [s appendFormat: @" or with a %u byte buffer.\n", size];
      if (timer != nil)
	{
	  [s appendFormat: @"Next flush - %@\n", [timer fireDate]];
	}
    }
  else
    {
      [s appendFormat: @"%@ flushed with a %u byte buffer.\n", key, size];
    }
  [lock unlock];
  return s;
}

- (BOOL) ecDidAwaken
{
  return YES;
}

/**
 * Internal flush operation ... writes data out from us, but
 * doesn't try any further.  Only called in main thread.
 */
- (void) _flush
{
  NSString      *str = nil;

  if (inFlush == YES)
    {
      return;
    }

  [lock lock];
  if (NO == inFlush && [message length] > 0)
    {
      inFlush = YES;
      str = [message copy];
      [message setString: @""];
    }
  [lock unlock];

  if (nil != str)
    {
      BOOL	ok = YES;

      if (LT_DEBUG != type)
        {
          if (nil == serverName)
            {
              id<CmdLogger>	server;

              NS_DURING
                {
                  server = (id<CmdLogger>)[EcProc cmdNewServer];
                }
              NS_HANDLER
                {
                  server = nil;
                  NSLog(@"Exception contacting Command server: %@\n",
                    localException);
                }
              NS_ENDHANDLER
              if (server != nil)
                {
                  NS_DURING
                    {
                      [server logMessage: str
                                    type: type
                                     for: EcProc];
                    }
                  NS_HANDLER
                    {
                      NSLog(@"Exception sending info to logger: %@",
                        localException);
                      ok = NO;
                    }
                  NS_ENDHANDLER
                }
              else
                {
                  ok = NO;
                }
            }
          else
            {
              id<CmdLogger>	server;

              NS_DURING
                {
                  server = (id<CmdLogger>)
                    [EcProc server: serverName];
                }
              NS_HANDLER
                {
                  server = nil;
                  NSLog(@"Exception contacting logging server: %@\n",
                    localException);
                }
              NS_ENDHANDLER
              if (server != nil)
                {
                  NS_DURING
                    {
                      [server logMessage: str
                                    type: type
                                     for: self];
                    }
                  NS_HANDLER
                    {
                      NSLog(@"Exception sending info to %@: %@",
                        serverName, localException);
                      ok = NO;
                    }
                  NS_ENDHANDLER
                }
              else
                {
                  ok = NO;
                }
            }
        }
      if (NO == ok)
        {
          if (nil == serverName)
            {
              NSLog(@"%@", str);
            }
          else
            {
              NSLog(@"Unable to log to %@ - %@", serverName, str);
            }
          DESTROY(str);
          /*
           * Flush any messages that might have been generated by
           * (or during) our failed attempt to contact server.
           */
          [lock lock];
          if ([message length] > 0)
            {
              str = [message copy];
              [message setString: @""];
            }
          [lock unlock];
          if (nil != str)
            {
              NSLog(@"%@", str);
            }
        }
      RELEASE(str);

      [lock lock];
      inFlush = NO;
      [lock unlock];
    }
}

/* ONLY called in main thread.
 */
- (void) _externalFlush: (id)dummy
{
  if (externalFlush == NO)
    {
      externalFlush = YES;

      [self _flush];
      if (LT_DEBUG != type)
	{
	  id<CmdLogger>	server;

	  if (serverName == nil)
	    {
	      NS_DURING
		{
		  server = (id<CmdLogger>)[EcProc cmdNewServer];
		}
	      NS_HANDLER
		{
		  server = nil;
		  NSLog(@"Exception contacting Command server: %@\n",
		    localException);
		}
	      NS_ENDHANDLER
	    }
	  else
	    {
	      NS_DURING
		{
		  server = (id<CmdLogger>)
		    [EcProc server: serverName];
		}
	      NS_HANDLER
		{
		  server = nil;
		  NSLog(@"Exception contacting logging server: %@\n",
		    localException);
		}
	      NS_ENDHANDLER
	    }
	  if (server != nil)
	    {
	      NS_DURING
		{
		  [server flush];	// Force round trip.
		}
	      NS_HANDLER
		{
		  NSLog(@"Exception flushing info to %@: %@",
		    serverName, localException);
		}
	      NS_ENDHANDLER
	    }
	}
      externalFlush = NO;
    }
}

/**
 * External flush operation ... writes out data and asks any server
 * we write to to flush its data out too.
 */
- (void) flush
{
  [self performSelectorOnMainThread: @selector(_externalFlush:)
                         withObject: nil
                      waitUntilDone: YES
                              modes: modes];
}

/* This is ONLY called in the main thread.
 */
- (void) _scheduleFlush: (id)reset
{
  /* A non-nil value of reset means that we should reset to do
   * a flush real soon.
   */
  [lock lock];
  pendingFlush = NO;
  if (reset != nil)
    {
      if (timer != nil && [[timer fireDate] timeIntervalSinceNow] > 0.001)
	{
	  [timer invalidate];
	  timer = nil;
	}
      if (timer == nil)
	{
	  timer = [NSTimer scheduledTimerWithTimeInterval: 0.0001
	    target: self selector: @selector(_timeout:)
	    userInfo: nil repeats: NO];
	}
    }
  else if ([message length] >= size)
    {
      /*
       * Buffer too large - schedule immediate flush.
       */
      if (timer != nil && [[timer fireDate] timeIntervalSinceNow] > 0.001)
	{
	  [timer invalidate];
	  timer = nil;
	}
      if (timer == nil)
	{
	  timer = [NSTimer scheduledTimerWithTimeInterval: 0.0001
	    target: self selector: @selector(_timeout:)
	    userInfo: nil repeats: NO];
	}
    }
  else if (interval > 0.0 && timer == nil)
    {
      /*
       * No timer running - so schedule one to output the debug info.
       */
      timer = [NSTimer scheduledTimerWithTimeInterval: interval
	target: self selector: @selector(_timeout:)
	userInfo: nil repeats: NO];
    }
  [lock unlock];
}

- (void) log: (NSString*)fmt arguments: (va_list)args
{
  NSString	*format;

  format = [[NSString alloc] initWithFormat: @"%@ - %@", cmdLogKey(type), fmt];
  NSLogv(format, args);
  RELEASE(format);

  if (YES == shouldForward)
    {
      CREATE_AUTORELEASE_POOL(arp);
      NSString  *text;
      BOOL      shouldFlush = NO;

      format = cmdLogFormat(type, fmt);
      text = [NSString stringWithFormat: format arguments: args];

      [lock lock];
      if (message == nil)
        {
          message = [[NSMutableString alloc] initWithCapacity: 1024];
        }
      [message appendString: text];
      if ([message length] >= size || (interval > 0.0 && timer == nil))
        {
          if (NO == pendingFlush)
            {
              shouldFlush = YES;
              pendingFlush = YES;
            }
        }
      [lock unlock];

      if (YES == shouldFlush)
        {
          [self performSelectorOnMainThread: @selector(_scheduleFlush:)
                                 withObject: nil
                              waitUntilDone: NO
                                      modes: modes];
        }
      RELEASE(arp);
    }
}

- (void) log: (NSString*)fmt, ...
{
  va_list ap;

  va_start (ap, fmt);
  [self log: fmt arguments: ap];
  va_end (ap);
}

/* Should only be called on main thread.
 */
- (void) _timeout: (NSTimer*)t
{
  if (t == nil)
    {
      [timer invalidate];
    }
  timer = nil;
  [self _flush];
}

/* Should only execute on main thread.
 */
- (void) update
{
  NSUserDefaults	*defs;
  NSString		*str;

  if (NO == [NSThread isMainThread])
    {
      [self performSelectorOnMainThread: @selector(update)
                             withObject: nil
                          waitUntilDone: NO
                                  modes: modes];
      return;
    }
  defs = [EcProc cmdDefaults];
  /*
   * If there is a server specified for this debug logger, we want it
   * registered so we can use it - otherwise we will default to using
   * the Command server for logging.
   */
  str = [defs stringForKey: serverKey];
  if ([str isEqual: @""] == YES)
    {
      str = nil;	// An empty string means no server is used.
    }
  if ([serverName isEqual: str] == NO)
    {
      if (serverName != nil)
	{
	  [EcProc removeServerFromList: serverName];
	}
      ASSIGN(serverName, str);
      if (serverName != nil)
	{
	  [EcProc addServerToList: serverName for: self];
	}
    }
      
  /* Is the program to flush at intervals or at
   * a particular buffer size (or both)?
   */
  str = [defs stringForKey: flushKey];
  if (str == nil)
    {
      str = [defs stringForKey: @"DefaultFlush"];	// Default settings.
    }
  if (str != nil)
    {
      NSScanner	*scanner = [NSScanner scannerWithString: str];
      float     f;
      int	i;

      if ([scanner scanFloat: &f] == YES)
	{
          interval = (floor(interval * 1000)) / 1000.0;
	  if (f < 0.0)
	    interval = 0.0;
	  else
	    interval = f;
	}
      if (([scanner scanString: @":" intoString: 0] == YES)
	&& ([scanner scanInt: &i] == YES))
	{
	  if (i < 0)
	    size = 0;
	  else
	    size = i*1024;
	}

      /*
       * Ensure new values take effect real soon.
       */
      if (NO == pendingFlush)
        {
          [self performSelectorOnMainThread: @selector(_scheduleFlush:)
                                 withObject: self
                              waitUntilDone: NO
                                      modes: modes];
        }
    }
}
@end

