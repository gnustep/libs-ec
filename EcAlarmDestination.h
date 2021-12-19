
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

#import <Foundation/NSObject.h>

@class	EcAlarm;
@class	NSRecursiveLock;
@class	NSMutableArray;
@class	NSMutableSet;
@class	NSString;
@class	NSTimer;

/** The EcAlarmDestination protocol describes the interface which must be
 * provided by an object which handles alarms.<br />
 * <p>The sender expects to be able to 'fire and forget', sending the
 * messages in this protocol without having to wait for a response or deal
 * with any error conditions, so the destination must <em>not</em> block
 * for a long time or raise an exception.
 * </p>
 */
@protocol	EcAlarmDestination <NSObject>

/** Passes an alarm to the destination.
 */
- (oneway void) alarm: (in bycopy EcAlarm*)event;

/** Inform the destination of the existence of a managed object.<br />
 * This is an indicator of a 'cold start' of that object ... meaning that the
 * object has just started up afresh, and all outstanding alarms for the object
 * are to be cleared.
 */
- (oneway void) domanage: (in bycopy NSString*)managedObject;

/** Inform the destination of the removal of a managed object.<br />
 * This is an indicator of a graceful shutdown of that object ... meaning that
 * the object has been stopped intentionally and all outstanding alarms for the
 * object are to be cleared.
 */
- (oneway void) unmanage: (in bycopy NSString*)managedObject;

@end

/** These methods are called to inform an object monitoring the alarm
 * destination about changes to its state.
 */
@protocol	EcAlarmMonitor <NSObject>
- (void) activePut: (EcAlarm*)alarm;
- (void) activeRemove: (EcAlarm*)alarm;
- (void) clearsPut: (EcAlarm*)alarm;
- (void) clearsRemove: (EcAlarm*)alarm;
- (void) managePut: (NSString*)name;
- (void) manageRemove: (NSString*)name;
@end



/**
 * <p>The EcAlarmDestination class provides an object to act as an alarm
 * destination which is capable of buffering, coalescing, and forwarding
 * alarms to another destination (usually in a separate process).
 * </p>
 * <p>The buffering and coalescing mechanism is important to prevent floods
 * of alarms being sent over network connections.
 * </p>
 * <p>An EcAlarmDestination instance can also be set to forward alarm
 * information to a number of other instances as backups for the main
 * destination.
 * </p>
 */
@interface	EcAlarmDestination : NSObject
  <EcAlarmDestination,EcAlarmMonitor>
{
  NSRecursiveLock		*_alarmLock;
  NSMutableArray		*_alarmQueue;
  NSMutableSet			*_alarmsActive;
  NSMutableSet			*_alarmsCleared;
  NSMutableSet			*_managedObjects;
  NSTimer			*_timer;
  BOOL				_isRunning;
  BOOL				_shouldStop;
  BOOL				_coalesceOff;
  BOOL				_inTimeout;
  NSString			*_host;
  NSString			*_name;
  id<EcAlarmDestination>	_destination;
  id<EcAlarmMonitor>		_monitor;
  NSArray			*_backups;
  BOOL                          _debug;
}

/** Internal use only.
 */
- (void) activePut: (EcAlarm*)alarm;

/** Internal use only.
 */
- (void) activeRemove: (EcAlarm*)alarm;

/** Passes an alarm to the destination by adding it to a queue of alarm
 * events which will be processed in the receivers running thread.
 */
- (oneway void) alarm: (in bycopy EcAlarm*)event;

/** Returns an array containing all the currently active alarms.
 */
- (NSArray*) alarms;

/** Returns an array of backup destinations (if set).<br />
 * See -setBackups: for more information.
 */
- (NSArray*) backups;

/** Returns an array containing all the latest cleared alarms.
 */
- (NSArray*) clears;

/** Internal use only.
 */
- (void) clearsPut: (EcAlarm*)alarm;

/** Internal use only.
 */
- (void) clearsRemove: (EcAlarm*)alarm;

/** Inform the destination of the existence of a managed object.<br />
 * This is an indicator of a 'cold start' of that object ... meaning that the
 * object has just started up afresh, and all outstanding alarms for the object
 * are to be cleared.<br />
 * The managedObject information is added to a queue which is processed by
 * the receiver's running thread in order to pass the information on to the
 * destination.<br />
 * If managedObject is nil, the default managed object for the current
 * process is used.<br />
 * Processes using the [EcProcess] class call this method automatically
 * when they have registered with the Command server, so you don't usually
 * need to call it explicity for the default managed object.
 */
- (oneway void) domanage: (in bycopy NSString*)managedObject;

/* <init />
 * Initialises the receiver and starts up a secondary thread to manage
 * alarms for it.
 */
- (id) init;

/** Sets the name/host of the object in a remote process to which
 * alarms should be forwarded.  If this information is set then the
 * forwarder will attempt to maintain a Distributed Objects connection
 * to the remote object.<br />
 * The host may be nil for a local connection (current machine and account),
 * or an empty string for a network connection to the local machine, or a
 * host name for a network connection to another machine, or an asterisk
 * for a network connection to any available machine.
 */
- (id) initWithHost: (NSString*)host name: (NSString*)name;

/** Returns a flag indicating whether the receiver is actually operating.
 */
- (BOOL) isRunning;

/** Finds and returns the most recent alarm in the system which matches
 * (is equal to) toFind.  This searches the queue of alarms to be processed,
 * the set of active alarms, and the set of cleared alarms (in that order)
 * returning the first match found.  If no match is found the method
 * returns nil.
 */
- (EcAlarm*) latest: (EcAlarm*)toFind;

/** Returns an array containing the known managed objects.
 */
- (NSArray*) managed;

/** Internal use only.
 */
- (void) managePut: (NSString*)name;

/** Internal use only.
 */
- (void) manageRemove: (NSString*)name;

/** This method is called from -init in a secondary thread to start handling
 * of alarms by the receiver.  Do not call it yourself.
 */
- (void) run;

/** Sets an array containing EcAlarmDestination objects as backups to receive
 * copies of the alarm and domanage/unmanage information sent to this
 * destination.<br />
 * You may set nil or an empty array to turn off backups, and may use the
 * -backups method to get the currently set values.<br />
 * Do not set up loops causing a destination to be its own backup either
 * directly or indirectly, as this will cause alarms to be forwarded endlessly.
 */
- (void) setBackups: (NSArray*)backups;

/** Sets coalescing behavior for the queue of alarms and managed object
 * changes.  The default behavior is for coalescing to be turned on
 * (so new values replace those in the queue), but setting this to NO
 * will cause all events to be passed on (apart from repeated alarms at
 * the same perceivedSeverity level, which are never passed one).
 */
- (BOOL) setCoalesce: (BOOL)coalesce;

/** Sets debug on/off.  When debugging is on, we generate logs of
 * forwarding to the destination and of coalescing of alarms.<br />
 * Any non-zero value sets debug to YES, zero sets it to NO.<br />
 * Returns the previous value of the setting.
 */
- (int) setDebug: (int)debug;

/** Sets the destination to which alarms should be forwarded.<br />
 * If nil this turns off forwarding until it is re-set to a non-nil
 * destination.<br />
 * The destination object is retained by the receiver.<br />
 * Returns the previously set destination.
 */
- (id<EcAlarmDestination>) setDestination: (id<EcAlarmDestination>)destination;

/** Sets the monitoring object to which state changes are sent.<br />
 * If nil this turns off monitoring.<br />
 * The monitoring object is retained by the receiver.<br />
 * Returns the previously set monitor.
 */
- (id<EcAlarmMonitor>) setMonitor: (id<EcAlarmMonitor>)monitor;

/** Requests that the receiver's running thread should shut down.  This method
 * waits for a short while for the thread to shut down, but the process of
 * shutting down is not guaranteed to have completed by the time the method
 * returns.
 */
- (void) shutdown;

/** Inform the destination of the removal of a managed object.<br />
 * This is an indicator of a graceful shutdown of that object ... meaning that
 * the object has been stopped intentionally and all outstanding alarms for the
 * object are to be cleared.<br />
 * The managedObject information is added to a queue which is processed by
 * the receiver's running thread in order to pass the information on to the
 * destination.<br />
 * If managedObject is nil, the default managed object for the current
 * process is used.<br />
 * Processes using the [EcProcess] class call this method automatically
 * when they are shut down normally (with a quit status of zero), so you
 * don't usually need to call it explicity for the default managed object.
 */
- (oneway void) unmanage: (in bycopy NSString*)managedObject;

@end

/** Methods called internally to forward events to the remote target of
 * the receiver.
 * These methods must perform themselves in the main thread.
 */
@interface	EcAlarmDestination (Forwarding)
/** Forward an alarm event. */
- (void) alarmFwd: (EcAlarm*)event;
/** Forward a domanage event. */
- (void) domanageFwd: (NSString*)managedObject;
/** Forward an unmanage event. */
- (void) unmanageFwd: (NSString*)managedObject;
@end

