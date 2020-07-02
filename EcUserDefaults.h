
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

#import	<Foundation/NSUserDefaults.h>

@class	NSString;

/**
 * This category simply provides an easy way to work with user defaults
 * where you want all keys to share a common prefix.
 */
@interface	NSUserDefaults (EcUserDefaults)

/** Returns the latest prefixed version of the shared user defaults,
 * or nil if none has been set up.
 */
+ (NSUserDefaults*) prefixedDefaults;

/** Sets the default lifetime for command values set using the
 * -setCommand:forKey: method.
 */
+ (void) setDefaultLifetime: (NSTimeInterval)t;

/** Returns a proxy to the shared user defaults instance, which will use
 * aPrefix at the start of every key.<br />
 * If aPrefix is nil, the string given by the EcUserDefaultsPrefix user
 * default is used.<br />
 * If the enforcePrefix flag is YES, the prefix is strictly enforced,
 * otherwise the system will read defaults using the unprefixed key
 * if no value is found for the prefixed key.  Similary, when setting
 * values, this flag will force the prefix to be prepended to any key
 * where it is not already present.
 */
+ (NSUserDefaults*) userDefaultsWithPrefix: (NSString*)aPrefix
				    strict: (BOOL)enforcePrefix;

/** Returns a dictionary listing all the command override keys for which
 * values are currently set.  The values in the dictionary are the timestamps
 * after which those values may be purged.
 */
- (NSDictionary*) commandExpiries;

/** Returns the last value set for the specified key using the
 * -setCommand:forKey: method.  This returns nil if no value is
 * currently set.
 */
- (id) commandObjectForKey: (NSString*)aKey;

/** Returns the current configuration settings dictionary (as set using
 * the -setConfiguration: method).
 */
- (NSDictionary*) configuration;

/** Returns the prefix used by the receiver, or nil if no prefix is in use.
 */
- (NSString*) defaultsPrefix;

/** returns YES if this is a proxy which enforces the use of the prefix on
 * defaults keys.
 */
- (BOOL) enforcePrefix;

/** Convenience method to prepend the pefix to the supplied aKey value
 * if it is not already present.
 */
- (NSString*) key: (NSString*)aKey;

/** Removes all settings whose lifetime has passed.  Those settings must
 * previously have been set up using the -setCommand:forKey:lifetime: method.
 */
- (void) purgeSettings;

/** Removes all settings previously set up using the -setCommand:forKey:
 * method.
 */
- (void) revertSettings;

/** Sets a value to take precedence over others (in the volatile domain
 * reserved for commands issued to the current process by an operator).<br />
 * Values set using this method will use the default lifetime.<br />
 * This operates by using the -setCommand:forKey:lifetime: method.
 */
- (BOOL) setCommand: (id)val forKey: (NSString*)key;

/** Sets a value to take precedence over others (in the volatile domain
 * reserved for commands issued to the current process by an operator).<br />
 * Specifying a non-zero lifetime will adjust the lifetime of an existing
 * setting irresepective of whether the value is changed or not.<br />
 * Specifying a zero or negative lifetime will remove the value for the
 * setting (as will setting a nil value).<br />
 * Returns YES if the configuration (actual value set) was changed,
 * NO otherwise (may have changed lifetime of setting).
 */
- (BOOL) setCommand: (id)val forKey: (NSString*)key lifetime: (NSTimeInterval)t;

/** Replaces the system central configuration information for this process
 * with the contents of the dictionary. Values in this dictionary take
 * precedence over other configured values except for those set using the
 * -setCommand:forKey: method.<br />
 * Returns YES if the configuration changed, NO otherwise.
 */
- (BOOL) setConfiguration: (NSDictionary*)config;

@end

