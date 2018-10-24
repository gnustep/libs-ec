
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

#import "EcProcess.h"

#include <unistd.h>
#include <stdio.h>


#if     !defined(EC_DEFAULTS_PREFIX)
#define EC_DEFAULTS_PREFIX nil
#endif

#if	!defined(EC_BASE_CLASS)
#define	EC_BASE_CLASS	EcControl
#endif

/* Create a fake interface to satisfy compiler ...
 */
@interface	EC_BASE_CLASS : EcProcess
@end

int
main(int argc, char *argv[])
{
  NSString              *key = @"";
  NSProcessInfo		*pInfo;
  NSArray               *pArgs;
  NSString              *pName;
  NSDictionary		*defs;
  NSFileHandle	        *null;
  NSData                *data;
  CREATE_AUTORELEASE_POOL(pool);

  pInfo = [NSProcessInfo processInfo];
  pArgs = [pInfo arguments];
  pName = [pInfo processName];
  null = [NSFileHandle fileHandleWithNullDevice];

  if (NO == [pArgs containsObject: @"--Watched"])
    {
      NSMutableArray	*args = AUTORELEASE([pArgs mutableCopy]);
      NSString          *path = [[NSBundle mainBundle] executablePath];
      NSAutoreleasePool *inner = nil;
      BOOL              done = NO;
      NSUInteger        index = NSNotFound;
      int               status = 0;
      NSTask	        *t;

      [args removeObjectAtIndex: 0];

      if ([pArgs containsObject: @"--Watcher"] == NO)
        {
          NSUserDefaults        *defs;
          NSString              *str;

          defs = [NSUserDefaults standardUserDefaults];
          str = [defs stringForKey: @"EcControlKey"];
          if ([str length] == 32 || [str boolValue] == YES)
            {
              NSData    *digest = nil;

              if ([str length] == 32)
                {
                  /* Check that the 32 character value is hex digits,
                   * in which case it should be the MD5 digest of the
                   * actual key to be entered.
                   */
                  digest = AUTORELEASE([[NSData alloc]
                    initWithHexadecimalRepresentation: str]);
                  if ([digest length] != 16)
                    {
                      NSLog(@"Bad values specified in EcControlKey... abort");
                      exit(1);
                    }
                }
              key = [EcProcess ecGetKey: "master encryption key"
                                   size: 32
                                    md5: digest];
              if (nil == key)
                {
                  NSLog(@"Failed to read master key from terminal ... abort");
                  exit(1);
                }
            }

          /* In the top level task ... set flags to create a subtask
           * to act as a watcher for other tasks, and once that has
           * been created, exit to leave it running as a daemon.
           */
          [args addObject: @"--Watcher"];
          t = [NSTask new];
          NS_DURING
            {
              NSPipe            *pipe = [NSPipe pipe];
              NSFileHandle      *rh = [pipe fileHandleForReading];
              NSFileHandle      *wh = [pipe fileHandleForWriting];
               
              [t setLaunchPath: path];
              [t setArguments: args];
              [t setEnvironment: [pInfo environment]];
              [t setStandardInput: rh];
              [t setStandardOutput: null];
              [t launch];
              [rh closeFile];
              [wh writeData: [key dataUsingEncoding: NSUTF8StringEncoding]];
              [wh closeFile];
            }
          NS_HANDLER
            {
              NSLog(@"Problem creating %@ subprocess: %@",
                pName, localException);
              exit(1);
            }
          NS_ENDHANDLER
          [t release];
          exit(0);
        }

      /* This is the watcher ... its subtasks are those which are watched.
       * If we are a master key vended by the Control server, it can be
       * read on stdin (otherwise we should get an empty data object).
       */
      data = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
      if ([data length] > 0)
        {
          key = AUTORELEASE([[NSString alloc] initWithData: data
            encoding: NSUTF8StringEncoding]);
        }
      (void)dup2([null fileDescriptor], 0);

      /* Set args to tell subtask task not to make itself a daemon
       */
      if (EC_DEFAULTS_PREFIX != nil)
        {
          NSString      *str;

          str = [NSString stringWithFormat: @"-%@Daemon", EC_DEFAULTS_PREFIX];
          index = [args indexOfObject: str];
        }
      if (NSNotFound == index)
        {
          index = [args indexOfObject: @"-Daemon"];
        }
      if (NSNotFound != index)
        {
          [args replaceObjectAtIndex: index + 1 withObject: @"NO"];
        }
      else
        {
          [args addObject: @"-Daemon"];
          [args addObject: @"NO"];
        }

      /* Set args to tell task it is being watched.
       */
      [args removeObject: @"--Watcher"];
      [args addObject: @"--Watched"];

      while (NO == done)
        {
          DESTROY(inner);
          inner = [NSAutoreleasePool new];
          t = [[NSTask new] autorelease];
          NS_DURING
            {
              NSPipe            *pipe = [NSPipe pipe];
              NSFileHandle      *rh = [pipe fileHandleForReading];
              NSFileHandle      *wh = [pipe fileHandleForWriting];

              [t setLaunchPath: path];
              [t setArguments: args];
              [t setEnvironment: [pInfo environment]];
              [t setStandardInput: rh];
              [t setStandardOutput: null];
              [t launch];
              [rh closeFile];
              [wh writeData: [key dataUsingEncoding: NSUTF8StringEncoding]];
              [wh closeFile];
              [t waitUntilExit];
              if (0 == [t terminationStatus])
                {
                  done = YES;
                }
              else if (255 == ([t terminationStatus] & 255))
                {
                  /* Probably a restart. try to start after 0.5 seconds
                   */
                  [NSThread sleepForTimeInterval: 0.5];
                }
              else
                {
                  /* Subprocess died ... try to restart after 30 seconds
                   */
                  [NSThread sleepForTimeInterval: 30.0];
                }
            }
          NS_HANDLER
            {
              done = YES;
              status = 1;
              NSLog(@"Problem creating %@ subprocess: %@",
                pName, localException);
            }
          NS_ENDHANDLER
        }
      DESTROY(inner);
      DESTROY(pool);
      exit(status);
    }

  /* Read to end of standard input to get any encryption key we
   * should use, then get standard input from the null device.
   */
  data = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
  if ([data length] > 0)
    {
      key = AUTORELEASE([[NSString alloc] initWithData: data
        encoding: NSUTF8StringEncoding]);
    }
  (void)dup2([null fileDescriptor], 0);

  // cmdVersion(@"$Date: 2017-02-23 12:00:00 +0000 (Fri, 23 Feb 2012) $ $Revision: 66052 $");

  defs = [NSDictionary dictionaryWithObjectsAndKeys:
    @"Command", @"HomeDirectory",
    key, @"EcControlKey",
    @"YES", @"Daemon",
#if	defined(EC_REGISTRATION_DOMAIN)
    EC_REGISTRATION_DOMAIN
#endif
    nil];
    
  if (nil == [[EC_BASE_CLASS alloc] initWithDefaults: defs])
    {
      NSLog(@"Unable to create control object.\n");
      exit(1);
    }

  [EcProc ecRun];

  RELEASE(pool);
  exit(0);
}
