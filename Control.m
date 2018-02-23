
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
#include <termios.h>
#include <stdio.h>

static size_t
trim(char *str)
{
  size_t        len = 0;
  char          *frontp = str - 1;
  char          *endp = NULL;

  if (NULL == str || '\0' == str[0])
    {
      return 0;
    }

  len = strlen(str);
  endp = str + len;

  while (isspace(*(++frontp)))
    ;

  while (isspace(*(--endp)) && endp != frontp)
    ;

  if (str + len - 1 != endp)
    {
      *(endp + 1) = '\0';
    }
  else if (frontp != str && endp == frontp)
    {
      *str = '\0';
    }

  if (frontp != str)
    {
      endp = str;
      while (*frontp)
        {
          *endp++ = *frontp++;
        }
      *endp = '\0';
    }

  return endp - str;
}

static BOOL
getkey(NSString **key)
{
  FILE  *stream;
  struct termios old;
  struct termios new;
  char          *one = NULL;
  char          *two = NULL;

#define MINKEY  16

  /* Open the terminal
   */
  if ((stream = fopen("/dev/tty", "r+")) == NULL)
    {
      return NO;
    }
  /* Turn echoing off 
   */
  if (tcgetattr(fileno(stream), &old) != 0)
    {
      fclose(stream);
      return NO;
    }
  new = old;
  new.c_lflag &= ~ECHO;
  if (tcsetattr (fileno(stream), TCSAFLUSH, &new) != 0)
    {
      fclose(stream);
      return NO;
    }

  while (NULL == one || NULL == two)
    {
      int       olen = 0;
      int       tlen = 0;

      while (olen < MINKEY)
        {
          size_t    len = 0;

          fprintf(stream, "\nPlease enter EcControlKey: ");
          if (one != NULL) { free(one); one = NULL; }
          olen = getline(&one, &len, stream);
          if (olen < 0)
            {
              if (one != NULL) { free(one); one = NULL; }
              fclose(stream);
              return NO;
            }
          olen = trim(one);
          if (olen < MINKEY)
            {
              fprintf(stream, "\nKey must be at least %u characters\n", MINKEY);
            }
        }
  
      while (0 == tlen)
        {
          size_t    len = 0;

          fprintf(stream, "\nPlease re-enter to confirm: ");
          if (two != NULL) { free(two); two = NULL; }
          tlen = getline(&two, &len, stream);
          if (tlen < 0)
            {
              if (one != NULL) { free(one); one = NULL; }
              if (two != NULL) { free(two); two = NULL; }
              fclose(stream);
              return NO;
            }
          tlen = trim(two);
        }

      if (strcmp(one, two) != 0)
        {
          free(one); one = NULL;
          free(two); two = NULL;
          fprintf(stream, "\nKeys do not match, please try again.");
        }
    }
  
  /* Restore terminal. */
  (void) tcsetattr(fileno(stream), TCSAFLUSH, &old);

  *key = [NSString stringWithUTF8String: one];
  free(one);
  free(two);
  fprintf(stream, "\nEcControlKey accepted.\n");
  fclose(stream);
  return YES;
}

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
      int               status = 0;
      NSTask	        *t;

      [args removeObjectAtIndex: 0];

      if ([pArgs containsObject: @"--Watcher"] == NO)
        {
          /* In the top level task ... set flags to create a subtask
           * to act as a watcher for other tasks, and once that has
           * been created, exit to leave it running as a daemon.
           */
          if ([[NSUserDefaults standardUserDefaults] boolForKey:
            @"EcControlKey"] == YES)
            {
              if (getkey(&key) == NO)
                {
                  NSLog(@"Failed to read EcControlKey from terminal ... abort");
                  exit(1);
                }
            }

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
      [args addObject: @"-Daemon"];
      [args addObject: @"NO"];

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
