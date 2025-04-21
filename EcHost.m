
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

#import	<Foundation/NSArray.h>
#import	<Foundation/NSDictionary.h>
#import	<Foundation/NSEnumerator.h>
#import	<Foundation/NSLock.h>
#import <Foundation/NSObjCRuntime.h>
#import	<Foundation/NSRunLoop.h>
#import	<Foundation/NSString.h>
#import	<Foundation/NSThread.h>

#import	"EcUserDefaults.h"
#import	"EcHost.h"

static NSRecursiveLock		*lock = nil;
static NSMutableDictionary	*aliases = nil;
static NSMutableDictionary	*fromWellKnown = nil;
static NSMutableDictionary	*toWellKnown = nil;
static NSString			*controlName = nil;

@implementation	NSHost (EcHost)

typedef NSHost	*(*hwnType)(Class c, SEL s, NSString *n);
static IMP	hwnImp;		// Original +hostWithName: implementation

/* This method is used to replace +[NSHost hostWithName:]
 * First it checks to see if the supplied name is an alias (replacing it if
 * necessary).  Then it checks to see if it has a well known name for
 * a host. Then it performs the host lookup using the original method.
 */
+ (NSHost*) _hostWithName: (NSString*)aName
{
  NSHost	*found = nil;

  if (YES == [aName isKindOfClass: [NSString class]])
    {
      NSString	*rep;

      [lock lock];
      if (nil != (rep = [aliases objectForKey: aName]))
	{
	  aName = [[rep retain] autorelease];
	}
      if (nil != (rep = [fromWellKnown objectForKey: aName]))
	{
	  aName = [[rep retain] autorelease];
	}
      [lock unlock];
      if ([aName length] > 0)
	{
          found = ((hwnType)hwnImp)(self, @selector(hostWithName:), aName); 
	}
    }
  return found;
}

+ (void) _EcHostSetup
{
  if (nil == lock)
    {
      if (YES == [NSThread isMainThread])
	{
	  NSUserDefaults	*defs;
	  NSString		*name;
	  NSHost		*host;
	  NSRecursiveLock	*l;

	  /* Create the lock locked ... until it is unlocked all other
	   * threads are waiting for this method to complete, and we
	   * can do what we like.
	   */
	  l = [NSRecursiveLock new];
	  [l lock];
	  lock = l;
	  aliases = [NSMutableDictionary new];
	  fromWellKnown = [NSMutableDictionary new];
	  toWellKnown = [NSMutableDictionary new];

	  /* We need to override the class method of NSHost so that it
	   * knows about well known host names.
	   */
	  Method	m;
	  IMP		r;

	  m = class_getClassMethod(self, @selector(_hostWithName:));
	  r = method_getImplementation(m);
	  m = class_getClassMethod([NSHost class], @selector(hostWithName:));
	  hwnImp = method_setImplementation(m, r);

	  /* Perform initial setup of control host and current host
	   * from user defaults system.
	   */
	  defs = [NSUserDefaults prefixedDefaults];
	  if (nil == defs)
	    {
	      defs = [NSUserDefaults userDefaultsWithPrefix: nil];
	    }
	  name = [defs stringForKey: @"ControlHost"];
	  if (nil != name)
	    {
              controlName = [name copy];

              /* Use mapping from domain name to well known name.
               */
              name = [defs stringForKey: @"ControlDomain"];
	    }
	  else if (nil != (name = [defs stringForKey: @"ControlDomain"]))
	    {
	      /* Use domain name as the known name.
	       */
	      controlName = [name copy];
	    }
	  if (nil != name)
	    {
	      host = ((hwnType)hwnImp)(self, @selector(hostWithName:), name); 
	      if (nil == host)
		{
		  /* No such host ... set up name mapping in case
		   * the host becomes available later.
		   */
		  [toWellKnown setObject: controlName forKey: name];
		  [fromWellKnown setObject: name forKey: controlName];
		}
	      else
		{
	          [host setWellKnownName: controlName];
		}
	    }
	  host = [self currentHost];
	  name = [defs stringForKey: @"CurrentHost"];
	  if (nil == name)
	    {
	      /* If the current host is the control host, we may have the
	       * well known name set already, but if we don't this method
	       * will select an arbitrary name that we can use.
	       */
	      name = [host wellKnownName];
	    }
	  [host setWellKnownName: name];

	  [lock unlock];
	}
      else
	{
	  NSArray	*modes;

	  modes = [NSArray arrayWithObject: NSDefaultRunLoopMode];
	  [self performSelectorOnMainThread: _cmd
				 withObject: nil
			      waitUntilDone: YES
				      modes: modes];
	}
    }
}

+ (NSString*) controlWellKnownName
{
  if (nil == lock) [self _EcHostSetup];
  return controlName;
}

+ (NSHost*) hostWithWellKnownName: (NSString*)aName
{
  NSHost	*found = nil;

  if (nil == lock) [self _EcHostSetup];
  if (YES == [aName isKindOfClass: [NSString class]])
    {
      [lock lock];
      aName = [[[fromWellKnown objectForKey: aName] retain] autorelease];
      [lock unlock];
      if (nil != aName)
	{
	  found = ((hwnType)hwnImp)(self, @selector(hostWithName:), aName); 
	}
    }
  return found;
}

+ (void) setWellKnownNames: (NSDictionary*)map
{
  if (nil == lock) [self _EcHostSetup];
  if ([map isKindOfClass: [NSDictionary class]])
    {
      NSEnumerator	*e;
      NSString		*k;

      e = [map keyEnumerator];
      while (nil != (k = [e nextObject]))
	{
	  NSString	*v = [map objectForKey: k];

	  if ([k isKindOfClass: [NSString class]]
	    && [v isKindOfClass: [NSString class]])
	    {
	      [lock lock];
	      if ([k isEqual: v])
		{
		  [aliases removeObjectForKey: k];
		}
	      else if ([toWellKnown objectForKey: k] != nil)
		{
		  NSLog(@"+setWellKnownNames: cannot create alias"
		    @" for existing well known name '%@'", k);
		}
	      else
		{
		  [aliases setObject: v forKey: k];
		}
	      [lock unlock];
	    }
	  else
	    {
	      NSLog(@"+setWellKnownNames: bad key/value pair:"
		@" '%@' / '%@'", k, v);
	    }
	}
    }
  else
    {
      NSLog(@"+setWellKnownNames: bad key/value map: '%@'", map);
    }
}

- (void) setWellKnownName: (NSString*)aName
{
  if (nil == lock) [[self class] _EcHostSetup];
  if ([aName isKindOfClass: [NSString class]])
    {
      NSEnumerator 	*e;
      NSString		*name;

      [lock lock];

      [aliases removeObjectForKey: aName];

      /* Set a mapping to this host from the well known name.
       */
      name = [self name];
      if (nil == name)
	{
	  name = [self address];
	}
      [fromWellKnown setObject: name forKey: aName];

      /* Remove any old mappings to this well known name.
       */
      e = [[toWellKnown allKeys] objectEnumerator];
      while (nil != (name = [e nextObject]))
	{
	  if ([[toWellKnown objectForKey: name] isEqualToString: aName])
	    {
	      [toWellKnown removeObjectForKey: name];
	    }
        }

      /* Add mappings to the well known name from any of our names.
       */
      e = [[self names] objectEnumerator];
      while (nil != (name = [e nextObject]))
	{
	  [toWellKnown setObject: aName forKey: name];
	}

      /* Add mappings to the well known name from any of our addresses.
       */
      e = [[self addresses] objectEnumerator];
      while (nil != (name = [e nextObject]))
	{
	  [toWellKnown setObject: aName forKey: name];
	}

      [lock unlock];
    }
}

- (NSString*) wellKnownName
{
  NSString	*found;

  if (nil == lock) [[self class] _EcHostSetup];
  [lock lock];
  found = [[[toWellKnown objectForKey: [self name]] retain] autorelease];
  if (nil == found)
    {
      NSEnumerator 	*e;
      NSString		*name;

      e = [[self names] objectEnumerator];
      while (nil == found && nil != (name = [e nextObject]))
	{
	  found = [[[toWellKnown objectForKey: name] retain] autorelease];
	}
      if (nil == found)
	{
	  e = [[self addresses] objectEnumerator];
	  while (nil == found && nil != (name = [e nextObject]))
	    {
	      found = [[[toWellKnown objectForKey: name] retain] autorelease];
	    }
	}
    }
  [lock unlock];
  if (nil == found)
    {
      found = [self name];
      if (nil == found)
	{
	  found = [self address];
	}
    }
  return found;
}
@end

