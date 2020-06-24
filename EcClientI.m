
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
#import "EcClientI.h"


@implementation EcClientI

- (NSComparisonResult) compare: (EcClientI*)other
{
  return [name compare: [other name]];
}

- (NSData*) config
{
  return config;
}

- (void) dealloc
{
  NSConnection	*c = [obj connectionForProxy];

  if (c != nil)
    {
      RETAIN(c);
      [[NSNotificationCenter defaultCenter]
	removeObserver: theServer
		  name: NSConnectionDidDieNotification
		object: (id)c];
      if (unregistered == NO && [c isValid] == YES)
	{
	  NS_DURING
	    {
	      [obj cmdQuit: 0];
	    }
	  NS_HANDLER
	    {
	      NSLog(@"cmdQuit: to %@ - %@", name, localException);
	    }
	  NS_ENDHANDLER
	}
      RELEASE(c);
    }
  DESTROY(outstanding);
  DESTROY(delayed);
  DESTROY(recovered);
  DESTROY(config);
  DESTROY(files);
  DESTROY(name);
  DESTROY(obj);
  [super dealloc];
}

- (NSDate*) delayed
{
  return delayed;
}

- (NSMutableSet*) files
{
  return files;
}

- (BOOL) gnip: (unsigned)s
{
  if (s != revSequence + 1 && revSequence != 0)
    {
      NSLog(@"Gnip from %@ seq: %u when expecting %u", name, s, revSequence);
      if (s == 0)
        {
	  fwdSequence = 0;	// Reset
	}
    }
  revSequence = s;
  if (nil == recovered && nil != delayed)
    {
      /* We were in a sequence of delayed pings, so we need to record
       * that we have ended that sequence.
       */
      ASSIGN(recovered, [NSDate date]);
    }
  DESTROY(outstanding);
  if (revSequence == fwdSequence)
    {
      return YES;				/* up to date	*/
    }
  else
    {
      return NO;
    }
}

- (id) initFor: (id)o
	  name: (NSString*)n
	  with: (id<CmdClient>)s
{
  self = [super init];
  if (self != nil)
    {
      files = [NSMutableSet new];
      [self setObj: o];
      [self setName: n];
      [self setServer: s];
    }
  return self;
}

- (NSDate*) outstanding
{
  return outstanding;
}

- (NSString*) name
{
  return name;
}

- (id) obj
{
  return obj;
}

- (void) ping
{
  if (fwdSequence == revSequence)
    {
      ASSIGN(outstanding, [NSDate date]);
      NS_DURING
	{
	  [obj cmdPing: theServer sequence: ++fwdSequence extra: nil];
	}
      NS_HANDLER
	{
	  NSLog(@"Ping to %@ - %@", name, localException);
	}
      NS_ENDHANDLER
    }
  else
    {
      if (recovered != nil)
	{
	  /* The connection had recovered from a late ping response,
	   * but now we have another delayed ping, so we discard the
	   * information about the previous delay/recovery sequence
	   * in order to start another.
	   */
	  DESTROY(recovered);
	  DESTROY(delayed);
	}
      if (nil == delayed)
	{
	  /* This ping is the first one delayed, so we need to record
	   * the timestamp at which the delay started.
	   */ 
	  ASSIGN(delayed, outstanding);
	}
      NSLog(@"Ping to %@ when one is already in progress.", name);
    }
}

- (int) processIdentifier
{
  return processIdentifier;
}

- (NSDate*) recovered
{
  return recovered;
}

- (void) setConfig: (NSData*)c
{
  ASSIGN(config, c);
}

- (void) setName: (NSString*)n
{
  ASSIGN(name, n);
}

- (void) setObj: (id)o
{
  ASSIGN(obj, o);
}

- (void) setProcessIdentifier: (int)p
{
  processIdentifier = p;
}

- (void) setServer: (id<CmdClient>)s
{
  theServer = s;
}

- (void) setTransient: (BOOL)flag
{
  transient = flag ? YES : NO;
}

- (void) setUnregistered: (BOOL)flag
{
  if (flag != unregistered)
    {
      unregistered = flag ? YES : NO;
    }
}

- (BOOL) transient
{
  return transient;
}

- (BOOL) unregistered
{
  return unregistered;
}
@end


