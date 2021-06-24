
/** Enterprise Control Configuration and Logging

   Copyright (C) 2014 Free Software Foundation, Inc.

   Written by: Richard Frith-Macdonald <rfm@gnu.org>
   Date: March 2014
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

#if     !defined(EC_DEFAULTS_PREFIX)
#define EC_DEFAULTS_PREFIX nil
#endif
#if     !defined(EC_EFFECTIVE_USER)
#define EC_EFFECTIVE_USER nil
#endif

#import "EcProcess.h"
#import "EcUserDefaults.h"
#import "EcHost.h"
#import "EcTest.h"

static void
setup()
{
  static BOOL   beenHere = NO;

  if (NO == beenHere)
    {
      beenHere = YES;
      /* Enable encrypted DO if supported bu the base library.
       */
      if ([NSSocketPort respondsToSelector: @selector(setClientOptionsForTLS:)])
        {
          [NSSocketPort performSelector: @selector(setClientOptionsForTLS:)
                             withObject: [NSDictionary dictionary]];
        }
    }
}

static NSUserDefaults*
defaults()
{
  static NSUserDefaults   *defs = nil;

  if (nil == defs)
    {
      NSString              *pref;
      NSDictionary          *dict;

      [EcProcess class];    // Force linker to provide library

      pref = EC_DEFAULTS_PREFIX;
      if (nil == pref)
        {
          pref = @"";
        }
      ASSIGN(defs, [NSUserDefaults userDefaultsWithPrefix: pref]);
      dict = [defs dictionaryForKey: @"WellKnownHostNames"];
      if (nil != dict)
        {
          [NSHost setWellKnownNames: dict];
        }
    }
  return defs;
}

id<EcTest>
EcTestConnect(NSString *name, NSString *host, NSTimeInterval timeout)
{
  setup();
  CREATE_AUTORELEASE_POOL(pool);
  BOOL                  triedLaunching = NO;
  NSUserDefaults        *defs = defaults();
  id<EcTest>            proxy = nil;
  NSDate                *when;

  if (nil == host) host = @"";
  if (timeout > 0)
    {
      when = [NSDate dateWithTimeIntervalSinceNow: timeout];
    }
  else
    {
      when = [NSDate distantFuture];
    }

  while (nil == proxy && [when timeIntervalSinceNow] > 0.0)
    {
      NS_DURING
        {
          proxy = (id<EcTest>)[NSConnection
            rootProxyForConnectionWithRegisteredName: name
            host: host
            usingNameServer: [NSSocketPortNameServer sharedInstance]];
        }
      NS_HANDLER
        {
          proxy = nil;
        }
      NS_ENDHANDLER
      if (nil == proxy)
        {
          /* Where the initial contact attempt failed,
           * try launching the process.
           */
          if (NO == triedLaunching)
            {
              NS_DURING
                {
                  id<Command>           cmd;
                  NSString              *cmdName;

                  cmdName = [defs stringForKey: @"CommandName"];
                  if (nil == cmdName)
                    {
                      cmdName = @"Command";
                    }
                  cmd = (id<Command>)[NSConnection
                    rootProxyForConnectionWithRegisteredName: cmdName
                    host: host
                    usingNameServer: [NSSocketPortNameServer sharedInstance]];
                  [cmd launch: name];
                }
              NS_HANDLER
                {
                  NSLog(@"Failed to get 'Command' on '%@' to launch '%@': %@",
                    host, name, localException);
                }
              NS_ENDHANDLER
              triedLaunching = YES;
            }
          [NSThread sleepForTimeInterval: 0.1];
        }
      NS_DURING
        {
          if (YES == [(EcProcess*)proxy cmdIsClient])
            {
              if (NO == [(EcProcess*)proxy ecDidAwaken])
                {
                  /* We must wait for the connected process to register
                   * with the Command server (if it's not transient) and
                   * configure itself and wake up.
                   */
                  proxy = nil;
                  [NSThread sleepForTimeInterval: 0.1];
                }
            }
        }
      NS_HANDLER
        {
          NSLog(@"Failed to communicate with '%@': %@",
            name, localException);
        }
      NS_ENDHANDLER
    }
  [proxy retain];
  DESTROY(pool);
  return [proxy autorelease];
}

id
EcTestGetConfig(id<EcTest> process, NSString *key)
{
  setup();
  id    val;

  NSCAssert([key isKindOfClass: [NSString class]], NSInvalidArgumentException);
  val = [process ecTestConfigForKey: key];
  if (nil != val)
    {
      val = [NSPropertyListSerialization
        propertyListWithData: val
        options: NSPropertyListMutableContainers
        format: 0
        error: 0];
    }
  return val;
}

void
EcTestSetConfig(id<EcTest> process, NSString *key, id value)
{
  setup();
  NSCAssert([key isKindOfClass: [NSString class]], NSInvalidArgumentException);
  if (nil != value)
    {
      value = [NSPropertyListSerialization
        dataFromPropertyList: value
        format: NSPropertyListBinaryFormat_v1_0
        errorDescription: 0];
    }
  [process ecTestSetConfig: value forKey: key];

}

BOOL
EcTestShutdown(id<EcTest> process, NSTimeInterval timeout)
{
  setup();
  int           pid;
  NSConnection  *conn;
  NSDate        *when;

  conn = [(NSDistantObject*)process connectionForProxy];
  if (NO == [conn isValid])
    {
      [[conn sendPort] invalidate];
      return NO;
    }
  pid = [(id<CmdClient>)process processIdentifier];
  [(id<CmdClient>)process cmdQuit: 0];
  if (timeout > 0)
    {
      when = [NSDate dateWithTimeIntervalSinceNow: timeout];
    }
  else
    {
      when = [NSDate distantFuture];
    }

  while ([conn isValid] && [when timeIntervalSinceNow] > 0.0)
    {
      NS_DURING
        [(id<CmdClient>)process processIdentifier];
        [NSThread sleepForTimeInterval: 0.1];
      NS_HANDLER
        if ([conn isValid])
          {
            [localException raise];
          }
      NS_ENDHANDLER
    }
  if ([conn isValid])
    {
      kill(pid, 9);
      [[conn sendPort] invalidate];
      [conn invalidate];
      return NO;
    }
  return YES;
}

 
BOOL
EcTestShutdownByName(NSString *name, NSString *host, NSTimeInterval timeout)
{
  setup();
  NSPortNameServer      *ns;
  NSPort                *port;
  id<EcTest>            proxy = nil;
  NSConnection          *conn;
  NSDate                *when;
  int                   pid;

  if (nil == host) host = @"";
  if (timeout > 0)
    {
      when = [NSDate dateWithTimeIntervalSinceNow: timeout];
    }
  else
    {
      when = [NSDate distantFuture];
    }

  ns = [NSSocketPortNameServer sharedInstance];
  port = [ns portForName: name onHost: host];
  if (nil == port)
    {
      return YES;
    }

  NS_DURING
    {
      proxy = (id<EcTest>)[NSConnection
        rootProxyForConnectionWithRegisteredName: name
        host: host
        usingNameServer: ns];
    }
  NS_HANDLER
    {
      proxy = nil;
    }
  NS_ENDHANDLER
  if (nil == proxy)
    {
      NSLog(@"Unable to contact %@ found on %@", name, port);
      return NO;
    }

  conn = [(NSDistantObject*)proxy connectionForProxy];
  if (NO == [conn isValid])
    {
      [[conn sendPort] invalidate];
      return NO;
    }
  pid = [(id<CmdClient>)proxy processIdentifier];
  [(id<CmdClient>)proxy cmdQuit: 0];

  while ([conn isValid] && [when timeIntervalSinceNow] > 0.0)
    {
      NS_DURING
        [(id<CmdClient>)proxy processIdentifier];
        [NSThread sleepForTimeInterval: 0.1];
      NS_HANDLER
        if ([conn isValid])
          {
            [localException raise];
          }
      NS_ENDHANDLER
    }
  if ([conn isValid])
    {
      kill(pid, 9);
      [[conn sendPort] invalidate];
      [conn invalidate];
      return NO;
    }
  return YES;
}
