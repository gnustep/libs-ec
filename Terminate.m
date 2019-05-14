
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
      printf("Terminate processes and Command server\n");
      printf("  -CommandHost N\tuse alternative Command server host.\n");
      printf("  -CommandName N\tuse alternative Command server name.\n");
      printf("  -Wait YES\tWait until termination completes.\n");
      printf("  -WellKnownHostNames '{...}'\tprovide a host name map.\n");
      fflush(stdout);
      exit(0);
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
    }
  else
    {
      unsigned		active = [proxy activeCount];

      [(id<Command>)proxy terminate];
      if ([defs boolForKey: @"Wait"])
	{
	  NS_DURING
	    {
	      NSConnection	*c = [proxy connectionForProxy];
	      NSAutoreleasePool	*pool = [NSAutoreleasePool new];

	      while ([c isValid])
		{
		  NSDate	*delay;

		  [pool release];
		  pool = [NSAutoreleasePool new];
		  delay = [NSDate dateWithTimeIntervalSinceNow: 0.2];
		  [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
					   beforeDate: delay];
		  if ([c isValid])
		    {
		      unsigned	remaining = [proxy activeCount];

		      if (remaining != active)
			{
			  printf("clients remaining: %u\n", remaining);
			  active = remaining;
			  fflush(stdout);
			}
		    }
		}
	      [pool release];
	    }
	  NS_HANDLER
	    {
	      NSLog(@"%@", localException);
	    }
	  NS_ENDHANDLER
	}
    }
  RELEASE(arp);
  return 0;
}

