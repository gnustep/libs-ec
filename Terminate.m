
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

#if     !defined(EC_DEFAULTS_PREFIX)
#define EC_DEFAULTS_PREFIX nil
#endif
#if     !defined(EC_DEFAULTS_STRICT)
#define EC_DEFAULTS_STRICT NO
#endif
#if     !defined(EC_EFFECTIVE_USER)
#define EC_EFFECTIVE_USER nil
#endif

#import "EcProcess.h"
#import "EcUserDefaults.h"
#import "EcHost.h"

@protocol	EcCommandOld
- (oneway void) terminate;
@end

int
main()
{
  CREATE_AUTORELEASE_POOL(arp);
  NSUserDefaults	*defs;
  NSDictionary          *dict;
  NSString              *pref;
  NSString		*host;
  NSString		*name;
  id			proxy;
  BOOL                  any = NO;
  int			res = 0;

  [EcProcess class];            // Force linker to provide library

  pref = EC_DEFAULTS_PREFIX;
  if (nil == pref)
    {
      pref = @"";
    }
  defs = [NSUserDefaults userDefaultsWithPrefix: pref
                                         strict: EC_DEFAULTS_STRICT];

  if ([defs boolForKey: @"Help"] || [defs boolForKey: @"help"]
    || [[[NSProcessInfo processInfo] arguments] containsObject: @"--Help"]
    || [[[NSProcessInfo processInfo] arguments] containsObject: @"--help"])
    {
      printf("Terminate the Command server and its client processes.\n");
      printf("  -CommandHost N\tuse alternative Command server host.\n");
      printf("  -CommandName N\tuse alternative Command server name.\n");
      printf("  -Wait seconds\tWait with completion time limit.\n");
      printf("  -WellKnownHostNames '{...}'\tprovide a host name map.\n");
      printf("\n");
      printf("  By default a 30 second shutdown is requested and the\n");
      printf("  command finishes without waiting for it to complete.\n");
      printf("  Possible exit statuses are:\n");
      printf("  0 termination requested (completed if -Wait was used).\n");
      printf("  1 termination had not completed by end of -Wait timeout.\n");
      printf("  2 the Command server was not found (maybe not running).\n");
      printf("  3 this help was provided and no termination was requested.\n");
      fflush(stdout);
      exit(3);
    }

  dict = [defs dictionaryForKey: @"WellKnownHostNames"];
  if (nil != dict)
    {
      [NSHost setWellKnownNames: dict];
    }

  /*
   * Shut down the local command server.
   */
  name = [defs stringForKey: @"CommandName"];
  if (name == nil)
    {
      name = @"Command";
    }

  host = [defs stringForKey: @"CommandHost"];
  if ([host length] == 0)
    {
      any = YES;
      host = [[NSHost currentHost] name];
    }

  proxy = [NSConnection rootProxyForConnectionWithRegisteredName: name
							    host: host
    usingNameServer: [NSSocketPortNameServer sharedInstance]];

  if (nil == proxy && YES == any)
    {
      host = @"*";
      proxy = [NSConnection rootProxyForConnectionWithRegisteredName: name
                                                                host: host
        usingNameServer: [NSSocketPortNameServer sharedInstance]];
    }

  if (nil == proxy)
    {
      NSLog(@"Unable to contact %@ on %@", name, host);
      res = 2;
    }
  else
    {
      NSConnection	*c = [proxy connectionForProxy];
      unsigned		active;
      NSDate		*by;

      if (nil == [defs objectForKey: @"Wait"])
	{
	  by = nil;		// No waiting, default grace period
	}
      else
	{
	  NSTimeInterval	seconds = [defs doubleForKey: @"Wait"];

	  if (isnan(seconds) || 0.0 == seconds)
	    {
	      by = nil;
	    }
	  else if (seconds < 0.5)
	    {
	      seconds = 0.5;
	    } 
	  else if (seconds > 900.0)
	    {
	      seconds = 900.0;
	    } 
	  by = [NSDate dateWithTimeIntervalSinceNow: seconds];
	}
      if ([proxy respondsToSelector: @selector(activeCount)])
	{
	  active = [(id<Command>)proxy activeCount];
	  [(id<Command>)proxy terminate: by];
	}
      else
	{
	  by = nil;		// Waiting not supported with this API.
	  active = 0;
	  [(id<EcCommandOld>)proxy terminate];
	}
      if (nil == by)
	{
	  [c invalidate];	// No waiting
	}
      else
	{
	  NSAutoreleasePool	*pool = [NSAutoreleasePool new];

	  /* Allow a second more than the requested shutdown time,
	   * so minor timing differences do not cause us to report
	   * the shutdown as having failed.
	   */
	  while ([c isValid] && [by timeIntervalSinceNow] > -1.0)
	    {
	      NSDate	*delay;

	      [pool release];
	      pool = [NSAutoreleasePool new];
	      delay = [NSDate dateWithTimeIntervalSinceNow: 0.2];
	      [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
				       beforeDate: delay];
	      if ([c isValid])
		{
		  NS_DURING
		    {
		      unsigned	remaining = [proxy activeCount];

		      if (remaining != active)
			{
			  printf("clients remaining: %u\n", remaining);
			  active = remaining;
			  fflush(stdout);
			}
		    }
		  NS_HANDLER
		    {
		      /* An exception could occur if we lost the connection
		       * while trying to check the active count.  In that
		       * case we can assume the Command server terminated.
		       */
		      [c invalidate];
		      active = 0;
		    }
		  NS_ENDHANDLER
		}
	    }
	  [pool release];
	}
      if (YES == [c isValid])
	{
	  res = 1;	// Command did not shut down in time.
	}
    }
  RELEASE(arp);
  return res;
}

