/** Enterprise Control Configuration and Logging

   Copyright (C) 2014 Free Software Foundation, Inc.

   Written by: Richard Frith-Macdonald <rfm@gnu.org>
   Date: March 2014
   Originally developed from 1996 to 2014 by Brainstorm, and donated to
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

#import	<Foundation/NSObject.h>

@class  NSData;
@class  NSString;


/* The EcTest protocol provides remote diagnostic tools to use from
 * one program to test the operation of an EcProcess based server.
 */
@protocol	EcTest <NSObject>

/** Sends a command to the remote process and returns the string output.<br />
 * Similar to issueing the command string at the console.
 */
- (bycopy NSString*) ecTestCommand: (in bycopy NSString*)command;

/* Gets the current configuration value in use by the process for the
 * specified key.
 */
- (bycopy NSData*) ecTestConfigForKey: (in bycopy NSString*)key;

/* Sets a configuration value to be used by the remote process, overriding
 * any existing value.  Changes to the process configuration in Control.plist
 * will NOT override this for the running process, though changes explicitly
 * made from the Console may.<br />
 * The supplied data is a serialised property list.<br />
 * NB. This method is NOT oneway, it waits for the remote process to handle
 * the configuration change before it returns, so the caller knows that the
 * configuration update has taken place.
 */
- (void) ecTestSetConfig: (in bycopy NSData*)data
                  forKey: (in bycopy NSString*)key;

@end

/** This function obtains a Distributed Objects proxy to the EcProcess
 * instance controlling the server with the specified name and host.<br />
 * A nil or empty string for the host is taken to mean the local host,
 * while an asterisk denotes any host on the local network.<br />
 * The timeout is a time limit on how long it may take to get the
 * connection (a value less than or equal to zero will cause the
 * function to keep on trying indefinitely).<br />
 * If an immediate connection is not possible, the function will attempt
 * to contact the Command server on the specified host and ask it to
 * launch the process before trying to connect again.
 */
extern id<EcTest>
EcTestConnect(NSString *name, NSString *host, NSTimeInterval timeout);

/** This function gets process configuration for the specified key
 * and deserialises it to a property list object (returned) or nil
 * if no value is configured for the specified key.
 */
extern id
EcTestGetConfig(id<EcTest> process, NSString *key);

/** This function sets process configuration by serialising the property
 * list value and passing the resulting data to the remote process.<br />
 * If the value is nil then the configuration for the remote process
 * reverts to its default setting.
 */
extern void
EcTestSetConfig(id<EcTest> process, NSString *key, id value);

/** This function shuts down the remote process, gracefully if possible,
 * but then with a kill if graceful shutdown fails.<br />
 * Returns YES on graceful shutdown, NO on timeout (or if the connection
 * had already been invalidated).
 */
extern BOOL
EcTestShutdown(id<EcTest> process, NSTimeInterval timeout);

/** This function shuts down the remote process, gracefully if possible,
 * but then with a kill if graceful shutdown fails.<br />
 * Returns YES on graceful shutdown (or if the process was not running),
 * NO on timeout.
 */
extern BOOL
EcTestShutdownByName(NSString *name, NSString *host, NSTimeInterval timeout);

