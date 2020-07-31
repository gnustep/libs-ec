
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
#import "EcAlarm.h"
#import "EcClientI.h"
#import "EcHost.h"
#import "NSFileHandle+Printf.h"

#import "config.h"

#define	DLY	300.0
#define	FIB	0.1

static NSCalendarDate *
date(NSTimeInterval t)
{
  NSCalendarDate	*d;

  d = [NSCalendarDate dateWithTimeIntervalSinceReferenceDate: t];
  [d setCalendarFormat: @"%Y-%m-%d %H:%M:%S.%F %z"];
  return d;
}

static const NSTimeInterval   day = 24.0 * 60.0 * 60.0;

static int	tStatus = 0;

static NSTimeInterval	pingDelay = 240.0;

static int	comp_len = 0;

static int	comp(NSString *s0, NSString *s1)
{
  if ([s0 length] > [s1 length])
    {
      comp_len = -1;
      return -1;
    }
  if ([s1 compare: s0
	  options: NSCaseInsensitiveSearch|NSLiteralSearch
	    range: NSMakeRange(0, [s0 length])] == NSOrderedSame)
    {
      comp_len = [s0 length];
      if (comp_len == (int)[s1 length])
	{
	  return 0;
	}
      else
	{
	  return 1;
	}
    }
  else
    {
      comp_len = -1;
      return -1;
    }
}

static NSString*
cmdWord(NSArray* a, unsigned int pos)
{
  if (a != nil && [a count] > pos)
    {
      return [a objectAtIndex: pos];
    }
  else
    {
      return @"";
    }
}

/* When this control process needs to shut down *all* clients,
 * we set the date for the shutdown to end.
 */
static NSDate                   *terminateBy = nil;

static NSUInteger               launchLimit = 0;
static BOOL                     launchEnabled = NO;
static NSMutableDictionary	*launchInfo = nil;
static NSArray                  *launchOrder = nil;
static NSMutableArray	        *launchQueue = nil;

typedef enum {
  ACLaunchFailed,       // Must be first
  ACProcessHung,        
  ACProcessLost         // Must be last
} AlarmCode;

static void
ACStrings(AlarmCode ac, NSString **problem, NSString **repair)
{
  *problem = nil;
  *repair = nil;
  switch (ac)
    {
      case ACLaunchFailed:
        *problem = @"Launch failed";
        *repair = @"Check logs and correct launch/startup failure";
        break;

      case ACProcessHung:
        *problem = @"Process hung";
        *repair = @"Check logs and deal with cause of unresponsiveness";
        break;

      case ACProcessLost:
        *problem = @"Process lost";
        *repair = @"Check logs and deal with cause of shutdown/crash";
        break;
    }
}

typedef enum {
  Dead,         // The process should be stopped if it is live
  Live,         // The process should be started if it is dead
  None          // The process is free to start/stop
} Desired;

static NSString *
desiredName(Desired state)
{
  switch (state)
    {
      case Live: return @"Live";
      case Dead: return @"Dead";
      default: return @"None";
    }
}

/** 
 * starting	means that the server has attempted to start the process
 * 		(or is waiting for some precondition of launching) but the
 * 		process has not yet established a connection to the server
 * 		and registered itself.
 * stopping	means that the server has attempted to shut down the process
 * 		(or the process has told the server it is shutting down), so
 * 		the connection between the process and the server may not
 * 		exist (and should not be used).
 * desired	defines whether the steady state of this process should
 * 		be running/live or shut down.  When the process reaches
 * 		a steady state (ie is not starting or stopping) that does
 * 		not match the desired state, the server shold initiate a
 * 		change of state.
 * identifier	If the process is shut down, this should be zero.
 * 		Otherwise it is the process ID used by the operating system
 * 		and indicates that the process is starting, stopping, or in
 * 		a steady live state (in which case it should also be
 * 		connected as a client of the server).
 *
 * If while starting, the process dies, we should schedule relaunches at
 * increasing intervals until a process survives and connects.
 * If starting takes too long (because launch attempts fail, the processes
 * die, or they stay alive but fail to connect to the server),
 * we should raise an alarm.
 * If stopping takes too long, we should forcibly terminate the process
 * if we can, and raise an alarm if we fail to kill it.
 */
@interface	LaunchInfo : NSObject
{
  /** The name of this process
   */
  NSString		*name;

  /** The configuration from Control.plist
   */
  NSDictionary		*conf;

  /** The current process ID (or zero if there isn't one).
   *  This is set when we launch the process or when the process is launched
   *  externally and connects and registers itself with the Command server.
   */
  int			identifier;

  /** The current task (if launched by us).  
   */
  NSTask		*task;

  /** The client instance representing a registered distributed objects
   * connection from the process into the Command server.
   */ 
  EcClientI		*client;

  /* Set at the point when a previously registered process is shutting
   * down and drops the connection to the Command server.  It indicates
   * an unintentional shutdown of the process (a failure).
   */
  NSTimeInterval	clientLostDate;

  /* Set at the point when a previously registered process is shutting
   * down and cleanly unregisters with the Command server.  It indicates
   * an intentional shutdown of the process.
   */
  NSTimeInterval        clientQuitDate;

  NSTimeInterval	fib0;	// fibonacci sequence for delays
  NSTimeInterval	fib1;	// fibonacci sequence for delays

  /** Records the desired state for this process (usually when a command
   * is issued at the Console).  This is needed for situations where the
   * system can no respond immediately to an instruction.  For instance
   * the process is shutting down and a start command is given: we must
   * continue to complete the clean shutdown, and then start up again.
   */
  Desired		desired;	// If process *should* be live/dead

  /** The timestamp at which the current startup operation began, or zero
   * if the process is not currently starting.
   */
  NSTimeInterval	startingDate;

  /** A timer to progress the startup process.  When it fires the -starting:
   * method is called to check on progress and raise an alarm if startup is
   * taking too long.
   */
  NSTimer		*startingTimer;	// Not retained

  /* A flag set, during the startup process, if an alarm has been raised
   * because startup is taking too long.  This prevents re-raising of the
   * alarm.
   */
  BOOL			startingAlarm;

  /** A timestamp set if an alarm has been raised because the process is not
   * responding to pings.  This is cleared if/when the process re-registers.
   */
  NSTimeInterval	hungDate;

  /** A timestamp set when a ping response is received.
   */
  NSTimeInterval	pingDate;

  /** The timestamp at which the process began shutting down, or zero
   * if the process is not currently stopping.
   */
  NSTimeInterval	stoppingDate;

  /** A timer to progress the stopping process.  When it fires the -stopping:
   * method is called to check on progress and, if stopping has taken too long,
   * attempt to forcibly terminate the process.
   */
  NSTimer		*stoppingTimer; // Not retained

  /** When a process termination is detected, this variable records it.
   */
  NSTimeInterval        terminationDate;

  /** If, during startup, the process terminates and has to be relaunched,
   * we record the count of attempts here.
   */
  unsigned              terminationCount;

  /** Where the Command server launched the process and is able to get the
   * process termination status, this variqable is used to record it.
   */
  int                   terminationStatus;      // Last exit status
  BOOL			terminationStatusKnown;

  /** The timestamp at which the process registered with the Command server.
   * or zero if it has not registered.
   */
  NSTimeInterval        registrationDate;       // Time of process registration

  /** The timestamp at which the process told the Command server it had
   * completely awakend (was ready to handle requests) or zero if it has
   * not woken.
   */
  NSTimeInterval        awakenedDate;           // When the process was awakened

  /** If there is a problem causing processes to fail repeatedly and autostart
   * to retry, we impose a slightly longer delay between each successive
   * relaunch.  In that case the deferredDate tells us when the queued
   * starting process can next be launched.
   */
  NSTimeInterval        deferredDate;           // Deferred re-launch interval

  /** If a starting process cannt be launched immediately, this records the
   * timestamp at which it was added to the queue of processes awaiting launch.
   */
  NSTimeInterval        queuedDate;             // When queued for launch

  /** Once a process has been active for a while it is considered stable.
   * A stable process will, if it terminates without shutting down cleanly,
   * be elegible for immediate autolaunch.
   */
  NSTimeInterval	stableDate;	        // Has been running for a while

  /* On process registration this is set to the timestamp at which the
   * process may be considered stable.  Normally this is a short while
   * after the startup, but if the process was lost it will be set to
   * a later date.
   */
  NSTimeInterval	nextStableDate;

  /** The timestamp at which we last launched this process.
   */
  NSTimeInterval	launchDate;	        // When we launched process

  /** The timestamp at which we will aborting a process (if it fails to shut
   * down as quickly as we need it to).
   */
  NSTimeInterval	abortDate;	        // When we abort process

  /** If we want the process to restart, this reason is why, and is passed
   * to the process so that it can log why it was restarted.
   */
  NSString              *restartReason;         // Reason for restart or nil

  /** Records the reason we desire the process to be started.
   */
  NSString		*startedReason;

  /** Records the reason we desire the process to be stopped.
   */
  NSString		*stoppedReason;

  /** Records the names of other processes which must be active in order for
   * this process to work.  Any attempt to start this process will result in
   * it remaining in a queue of starting processes until all the dependencies
   * have been met.
   */
  NSArray               *dependencies;
}
+ (NSString*) description;
+ (LaunchInfo*) existing: (NSString*)name;
+ (LaunchInfo*) find: (NSString*)abbreviation;
+ (LaunchInfo*) launchInfo: (NSString*)name;
+ (NSUInteger) launching;
+ (NSArray*) names;
+ (void) processQueue;
+ (void) remove: (NSString*)name;
- (BOOL) autolaunch;
- (void) awakened;
- (BOOL) checkActive;
- (BOOL) checkAlive;
- (void) clearClient: (EcClientI*)c cleanly: (BOOL)unregisteredOrTransient;
- (void) clearHung;
- (EcClientI*) client;
- (NSDictionary*) configuration;
- (NSTimeInterval) delay;
- (Desired) desired;
- (BOOL) disabled;
- (BOOL) isActive;
- (BOOL) isHung;
- (BOOL) isStarting;
- (BOOL) isStopping;
- (BOOL) launch;
- (BOOL) mayBecomeStable;
- (BOOL) mayCoreDump;
- (NSString*) name;
- (int) processIdentifier;
- (void) progress;
- (NSString*) reasonToPreventLaunch;
- (void) resetDelay;
- (void) setClient: (EcClientI*)c;
- (void) setConfiguration: (NSDictionary*)c;
- (void) setDesired: (Desired)state reason: (NSString*)reason;
- (void) setHung;
- (void) setPing;
- (void) setProcessIdentifier: (int)p;
- (void) setStable: (BOOL)s;
- (BOOL) stable;

/** Initiates the startup of a process.  This will either add the receiver to
 * the queue of processes to be started (if it can't be started immediately)
 * or launch the process using the configuration set for it.  The startup
 * will then continue until the launched process registers itself with the
 * Command server, at which point the -started method will be called.
 */
- (void) start;

/** Called automatically when startup of a process completes, either as a
 * result of an internal -start or as a result of an externally launched
 * process connectin to and registering with the Command server.
 */
- (void) started;

/** internal timer mathos for handling the progression of a startup.  If the
 * startup takes too long, this method will raise an alarm.
 */ 
- (void) starting: (NSTimer*)t;

/** Returns a human readble description of the current process status.
 */
- (NSString*) status;

/** Initiates the shut down of a process.  This will use the DO connection to
 * a registered process to tell it to shut itself down.
 * The shutdown will continue until the process no longer exists, but if it
 * goes on longer than the time limit, the process will be killed.
 */
- (void) stop;

/** Called at the point when a stopping process finally ceases to exist.
 */
- (void) stopped;

- (void) stopping: (NSTimer*)t;
- (NSTask*) task;
- (NSArray*) unfulfilled;
@end

/* Special configuration options are:
 *
 * CompressLogsAfter
 *   A positive integer number of days after which logs should be compressed
 *   defaults to 7.
 *
 * DeleteLogsAfter
 *   A positive integer number of days after which logs should be deleted.
 *   Constrained to be at least as large as CompressLogsAfter.
 *   Defaults to 180, but logs may still be deleted as if this were set
 *   to CompressLogsAfter if NodesFree or SpaceFree is reached.
 *
 * Environment
 *   A dictionary setting the default environment for launched processes.
 *
 * Launch
 *   A dictionary describing the processes which the server is responsible
 *   for launching.
 *
 * NodesFree
 *   A string giving a percentage of the total nodes on the disk below
 *   which an alert should be raised. Defaults to 10.
 *   Minimum 2, Maximum 90.
 *
 * SpaceFree
 *   A string giving a percentage of the total space on the disk below
 *   which an alert should be raised. Defaults to 10.
 *   Minimum 2, Maximum 90.
 *
 */
@interface	EcCommand : EcProcess <Command>
{
  NSString		*host;
  id<Control>		control;
  NSMutableArray	*clients;
  NSTimer		*timer;
  NSString		*logname;
  NSMutableDictionary	*config;
  NSDictionary		*environment;
  NSTimer		*terminating;
  NSDate		*outstanding;
  unsigned		fwdSequence;
  unsigned		revSequence;
  float			nodesFree;
  float			spaceFree;
  NSTimeInterval        debUncompressed;
  NSTimeInterval        debUndeleted;
  NSTimeInterval        logUncompressed;
  NSTimeInterval        logUndeleted;
  NSInteger		compressAfter;
  NSInteger		deleteAfter;
  BOOL                  sweeping;
}
- (void) alarmCode: (AlarmCode)ac
          procName: (NSString*)name
           addText: (NSString*)additional;
- (void) auditState: (LaunchInfo*)l reason: (NSString*)additional;
- (void) clearAll: (NSString*)name addText: (NSString*)additional;
- (void) clearCode: (AlarmCode)ac
          procName: (NSString*)name
           addText: (NSString*)additional;
- (oneway void) cmdGnip: (id <CmdPing>)from
               sequence: (unsigned)num
                  extra: (NSData*)data;
- (oneway void) cmdPing: (id <CmdPing>)from
               sequence: (unsigned)num
                  extra: (NSData*)data;
- (oneway void) cmdQuit: (NSInteger)sig;
- (void) command: (NSData*)dat
	      to: (NSString*)t
	    from: (NSString*)f;
- (NSData *) configurationFor: (NSString *)name;
- (BOOL) connection: (NSConnection*)ancestor
  shouldMakeNewConnection: (NSConnection*)newConn;
- (id) connectionBecameInvalid: (NSNotification*)notification;
- (NSDictionary*) environment;
- (NSArray*) findAll: (NSArray*)a
      byAbbreviation: (NSString*)s;
- (EcClientI*) findIn: (NSArray*)a
       byAbbreviation: (NSString*)s;
- (EcClientI*) findIn: (NSArray*)a
               byName: (NSString*)s;
- (EcClientI*) findIn: (NSArray*)a
             byObject: (id)s;
- (NSString*) host;
- (void) housekeeping: (NSTimer*)t;
- (void) _housekeeping: (NSTimer*)t;
- (void) information: (NSString*)inf
		from: (NSString*)s
		type: (EcLogType)t;
- (void) information: (NSString*)inf
		from: (NSString*)s
		  to: (NSString*)d
		type: (EcLogType)t;
- (void) killAll;
- (NSFileHandle*) logFile;
- (void) logChange: (NSString*)change for: (NSString*)name;
- (void) logMessage: (NSString*)msg
	       type: (EcLogType)t
	        for: (id<CmdClient>)o;
- (void) logMessage: (NSString*)msg
	       type: (EcLogType)t
	       name: (NSString*)c;
- (NSString*) makeSpace;
- (void) newConfig: (NSMutableDictionary*)newConfig;
- (NSFileHandle*) openLog: (NSString*)lname;
- (void) pingControl;
- (void) quitAll;
- (void) quitAll: (NSDate*)by;
- (void) requestConfigFor: (id<CmdConfig>)c;
- (NSData*) registerClient: (id)c
                identifier: (int)p
		      name: (NSString*)n
		 transient: (BOOL)t;
- (void) reply: (NSString*) msg to: (NSString*)n from: (NSString*)c;
- (void) terminate: (NSDate*)by;
- (void) _terminate: (NSTimer*)t;
- (NSMutableArray*) unconfiguredClients;
- (void) unregisterByObject: (id)obj;
- (void) unregisterClient: (EcClientI*)o;
- (void) update;
- (void) updateConfig: (NSData*)data;
- (void) woken: (id)obj;
@end



@implementation	LaunchInfo

+ (NSString*) description
{
  NSEnumerator		*e = [launchInfo objectEnumerator];
  LaunchInfo		*l;
  unsigned		autolaunch = 0;
  unsigned		disabled = 0;
  unsigned		launchable = 0;
  unsigned		starting = 0;
  unsigned		stopping = 0;
  unsigned		suspended = 0;
  unsigned		alive = 0;

  while (nil != (l = [e nextObject]))
    {
      if ([l isStarting])
        {
          starting++;
        }
      else if ([l isStopping])
        {
          stopping++;
        }
      else if ([l processIdentifier] > 0)
	{
	  alive++;
	}
      else if ([l disabled])
	{
	  disabled++;
	}
      else
	{
	  if ([l autolaunch])
	    {
              if (Dead == l->desired)
                {
                  suspended++;
                }
              else
                {
                  autolaunch++;
                }
	    }
          else
            {
              launchable++;
            }
	}
    }
  return [NSString stringWithFormat: @"LaunchInfo alive:%u, starting:%u,"
    @" stopping:%u disabled:%u, suspended:%u, launchable:%u (auto:%u)\n",
    alive, starting, stopping, disabled, suspended, launchable, autolaunch];
}

+ (LaunchInfo*) existing: (NSString*)name
{
  LaunchInfo	*l = RETAIN([launchInfo objectForKey: name]);

  return AUTORELEASE(l);
}

+ (LaunchInfo*) find: (NSString*)abbreviation
{
  LaunchInfo	*l = [launchInfo objectForKey: abbreviation];

  if (nil == l)
    {
      NSEnumerator	*e = [launchInfo keyEnumerator];
      NSString		*s;
      NSInteger 	bestLength = 0;
      NSString		*bestName = nil;

      while (nil != (s = [e nextObject]))
	{
	  if (comp(abbreviation, s) == 0)
	    {
	      bestName = s;
	      break;
	    }
	  if (comp_len > bestLength)
	    {
	      bestLength = comp_len;
	      bestName = s;
	    }
	}
      if (bestName != nil)
	{
	  l = [launchInfo objectForKey: bestName];
	}
    }
  return l;
}

+ (LaunchInfo*) findTask: (NSTask*)t
{
  LaunchInfo	*l = nil;
  NSEnumerator	*e = [launchInfo objectEnumerator];

  while (nil != (l = [e nextObject]))
    {
      if (l->task == t)
	{
	  return l;
	}
    }
  return nil;
}

+ (void) initialize
{
  if (nil == launchInfo)
    {
      launchInfo = [NSMutableDictionary new];
      launchQueue = [NSMutableArray new];
    }
}

+ (LaunchInfo*) launchInfo: (NSString*)name
{
  LaunchInfo	*l = [launchInfo objectForKey: name];

  if (nil == RETAIN(l))
    {
      l = [self new];
      l->desired = None;
      ASSIGNCOPY(l->name, name);
      [launchInfo setObject: l forKey: l->name];
    }
  return AUTORELEASE(l);
}

/* Return the number of processes actually launching (ie with a task running
 * but starting not finished.
 */
+ (NSUInteger) launching
{
  NSUInteger    found = 0;

  ENTER_POOL
  NSEnumerator  *e = [launchInfo objectEnumerator];
  LaunchInfo    *l;

  while (nil != (l = [e nextObject]))
    {
      if ([l isStarting] && l->task != nil)
        {
          found++;
        }
    }
  LEAVE_POOL
  return found;
}

+ (NSArray*) names
{
  return [launchInfo allKeys];
}

/* Check each process in the queue to see if it may now be launched.
 * Launch each process which may do so (removing it from the queue).
 */
+ (void) processQueue
{
  ENTER_POOL
  NSUInteger            count;

  /* We work with a copy of the queue in case the process of launching
   * causes the queue contents to be changed.
   */
  if ((count = [launchQueue count]) > 0)
    {
      NSArray           *q = AUTORELEASE([launchQueue copy]);
      NSUInteger        index;

      for (index = 0; index < count; index++)
        {
          LaunchInfo        *l = [q objectAtIndex: index];

          if ([launchQueue containsObject: l])
            {
              NSString  *r = [l reasonToPreventLaunch];

              if (nil == r)
                {
                  [launchQueue removeObject: l];
                  l->queuedDate = 0.0;
                  [l starting: nil];
                }
            }
        }
    }
  LEAVE_POOL
}

+ (void) remove: (NSString*)name
{
  LaunchInfo	*l = [launchInfo objectForKey: name];

  if (l != nil)
    {
      /* Detach the removed object from its client, destroy the task,
       * and cancel timers/notifications so that the removed object
       * will not try to manage anything before it is deallocated.
       */
      [[NSNotificationCenter defaultCenter] removeObserver: l];
      l->client = nil;
      DESTROY(l->task);
      [l->startingTimer invalidate];
      l->startingTimer = nil;
      [l->stoppingTimer invalidate];
      l->stoppingTimer = nil;
      [launchInfo removeObjectForKey: name];
    }
}

- (BOOL) autolaunch
{
  return [[conf objectForKey: @"Auto"] boolValue];
}

- (void) awakened
{
  awakenedDate = [NSDate timeIntervalSinceReferenceDate];
}

/* Check to see if there is an active process connected (or which connects
 * when we contact it and ask it to).
 */
- (BOOL) checkActive
{
  if (nil == client)
    {
      ENTER_POOL

      /* When the Command server starts up, or on other rare occasions, we may
       * have processes which are running but unknown to the Command server.
       * To handle that we try, as part of the launch process, to establish a
       * Distributed Objects connection to a process before we try to launch
       * the executable.
       * If a DO connection is established, we ask the process to reconnect to
       * the command server, and that incoming connection will cause the client
       * ivar to be set (and the instance ivar to be set to the process ID), so
       * we know we don't have to start a subtask.
       */ 
      NS_DURING
        {
          NSConnection	*c;

          c = [NSConnection
            connectionWithRegisteredName: name
            host: @""
            usingNameServer: [NSSocketPortNameServer sharedInstance]];
          NS_DURING
            {
              id<CmdClient>	proxy;

              /* Do not hang waiting for the other end to respond.
               */
              [c setRequestTimeout: 10.0];
              [c setReplyTimeout: 10.0];
              proxy = (id<CmdClient>)[c rootProxy];

              /* Sending an ecReconnect message to thge client process should
               * result in our 'client' ivar beng set.
               */
              [proxy ecReconnect];
              [c setRequestTimeout: 0.0];
              [c setReplyTimeout: 0.0];
            }
          NS_HANDLER
            {
              [c setRequestTimeout: 0.0];
              [c setReplyTimeout: 0.0];
            }
          NS_ENDHANDLER
        }
      NS_HANDLER
        {
          NSLog(@"Problem with connection for %@: %@", name, localException);
        }
      NS_ENDHANDLER
      LEAVE_POOL
    }
  return (nil == client) ? NO : YES;
}

- (BOOL) checkAlive
{
  if (identifier > 0)
    {
      if (kill(identifier, 0) == 0)
	{
	  return YES;
	}
      else
	{
	  identifier = 0;	// Process has terminated
	}
    }
  return NO;
}

- (void) clearClient: (EcClientI*)c cleanly: (BOOL)unregisteredOrTransient
{
  NSAssert(client == c, NSInternalInconsistencyException);
  DESTROY(client);
  if (unregisteredOrTransient)
    {
      clientQuitDate = [NSDate timeIntervalSinceReferenceDate];
      clientLostDate = 0.0;
    }
  else
    {
      clientQuitDate = 0.0;
      clientLostDate = [NSDate timeIntervalSinceReferenceDate];
    }
  registrationDate = 0.0;
  awakenedDate = 0.0;
  stableDate = 0.0;
  /* The connection to the client went away, which implies that the process
   * was connected/registered and we must either be stopping already or need
   * to stop (expect the process to die soon).
   * So either way we should trigger the -stopping: timeout handler to
   * check for the end of the process and to ensure that we try again if
   * it has not yet ended.
   */
  [self stopping: nil];
}

- (void) clearHung
{
  hungDate = 0.0;
}

- (EcClientI*) client
{
  return client;
}

- (NSDictionary*) configuration
{
  return AUTORELEASE(RETAIN(conf));
}

- (void) dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver: self];
  [startingTimer invalidate];
  [stoppingTimer invalidate];
  RELEASE(startedReason);
  RELEASE(stoppedReason);
  RELEASE(restartReason);
  RELEASE(dependencies);
  RELEASE(client);
  RELEASE(name);
  RELEASE(conf);
  RELEASE(task);
  [super dealloc];
}

/* The next delay for launching this process.  If Time is configured,
 * we use it (a value in seconds), otherwise we generate a fibonacci
 * sequence of increasingly larger delays each time a launch attempt
 * needs to be made.
 */
- (NSTimeInterval) delay
{
  NSTimeInterval	delay;
  NSString		*t;

  if (nil != (t = [conf objectForKey: @"Time"]) && [t doubleValue] > 0)
    {
      delay = [t doubleValue];
    }
  else
    {
      if (fib1 <= 0.0)
	{
	  fib0 = fib1 = delay = FIB;
	}
      else
	{
	  delay = fib0 + fib1;
	  fib0 = fib1;
	  fib1 = delay;
	}
    }
  deferredDate = [NSDate timeIntervalSinceReferenceDate] + delay;
  return delay;
}

- (NSString*) description
{
  NSMutableString	*m = [[super description] mutableCopy];
  NSString	*status = [self status];

  [m appendFormat: @" for process '%@'\n", name];
  if (startingDate > 0.0)
    {
      [m appendFormat: @"  Starting since %@ next check at %@\n",
	date(startingDate), [startingTimer fireDate]];
    }
  if (queuedDate > 0.0)
    {
      [m appendFormat: @"  Queued to launch since %@\n",
	date(queuedDate)];
    }
  if (launchDate > 0.0)
    {
      [m appendFormat: @"  Launched at %@\n",
	date(launchDate)];
    }
  if (registrationDate > 0.0)
    {
      [m appendFormat: @"  Registered since %@\n",
	date(registrationDate)];
      if (awakenedDate > 0.0)
	{
	  [m appendFormat: @"  Awakened since %@\n",
	    date(awakenedDate)];
	}
      if (stableDate > 0.0)
	{
	  [m appendFormat: @"  Stable since %@\n",
	    date(stableDate)];
	}
      else if (nextStableDate > 0.0)
	{
	  [m appendFormat: @"  Will be considered stable at %@\n",
	    date(nextStableDate)];
	}
    }
  if (hungDate > 0.0)
    {
      [m appendFormat: @"  Unresponsive since %@\n",
	date(hungDate)];
    }
  if (clientLostDate > 0.0)
    {
      [m appendFormat: @"  Last lost/crashed at %@\n",
	date(clientLostDate)];
    }
  if (clientQuitDate > 0.0)
    {
      [m appendFormat: @"  Last unregistered at %@\n",
	date(clientQuitDate)];
    }
  if (pingDate > 0.0)
    {
      [m appendFormat: @"  Last ping response at %@\n",
	date(pingDate)];
    }
  if (stoppingDate > 0.0)
    {
      [m appendFormat: @"  Stopping since %@ next check at %@\n",
	date(stoppingDate), [stoppingTimer fireDate]];
    }
  [m appendFormat: @"  %@\n", status];
  [m appendFormat: @"  %@\n", conf];
  return AUTORELEASE(m);
}

- (Desired) desired
{
  return desired;
}

- (BOOL) disabled
{
  return [[conf objectForKey: @"Disabled"] boolValue];
}

/* Returns YES if the client is in a state where it can be sent commands.
 */
- (BOOL) isActive
{
  return (client != nil && NO == [self isStopping]) ? YES : NO;
}

- (BOOL) isHung
{
  return (hungDate > 0.0) ? YES : NO;
}

- (BOOL) isStarting
{
  return (startingDate > 0.0) ? YES : NO;
}

- (BOOL) isStopping
{
  return (stoppingDate > 0.0) ? YES : NO;
}

/* This method should only ever be called from the -starting: method (when
 * the instance has permission to launch).  To initiate the startup process
 * the -start method is called, and to progress startup the -starting: method
 * is called.
 */
- (BOOL) launch
{
  EcCommand		*command = (EcCommand*)EcProc;
  NSMutableDictionary	*env;
  NSMutableArray	*args;
  NSString		*home = [conf objectForKey: @"Home"];
  NSString		*prog = [conf objectForKey: @"Prog"];
  NSDictionary		*addE = [conf objectForKey: @"AddE"];
  NSDictionary		*setE = [conf objectForKey: @"SetE"];
  NSString      	*failed = nil;
  NSString		*m;

  NSAssert(NO == [self checkAlive], NSInvalidArgumentException);

  if (YES == [self checkActive])
    {
      return YES;       // Client registered; no need to launch
    }

  ENTER_POOL
  if (nil == (env = AUTORELEASE([[command environment] mutableCopy])))
    {
      NSProcessInfo	*pi = [NSProcessInfo processInfo];

      if (nil == (env = AUTORELEASE([[pi environment] mutableCopy])))
	{
	  env = [NSMutableDictionary dictionary];
	}
    }
  if (nil == (args = AUTORELEASE([[conf objectForKey: @"Args"] mutableCopy])))
    {
      args = [NSMutableArray array];
    }

  /* As a convenience, the 'Home' option sets the -HomeDirectory
   * for the process.
   */
  if ([home length] > 0)
    {
      [args addObject: @"-HomeDirectory"];
      [args addObject: home];
    }

  /* If we do not want the process to core-dump, we need to add
   * the argument to tell it.
   */
  if ([self mayCoreDump] == NO)
    {
      [args addObject: @"-CoreSize"];
      [args addObject: @"0"];
    }

  if (prog != nil && [prog length] > 0)
    {
      NS_DURING
	{
	  NSFileHandle	*hdl;

	  if (setE != nil)
	    {
	      [env removeAllObjects];
	      [env addEntriesFromDictionary: addE];
	    }
	  if (addE != nil)
	    {
	      [env addEntriesFromDictionary: addE];
	    }

	  task = [NSTask new];
	  [task setEnvironment: env];
	  hdl = [NSFileHandle fileHandleWithNullDevice];
	  [task setLaunchPath: prog];

	  if ([task validatedLaunchPath] == nil)
	    {
	      failed = @"failed to launch (not executable)";
	      m = [NSString stringWithFormat: cmdLogFormat(LT_CONSOLE,
		@"failed to launch (not executable) %@"), name];
	      [command information: m from: nil to: nil type: LT_CONSOLE];
	      prog = nil;
	    }
	  if (prog != nil)
	    {
	      NSString  *s;

	      s = [conf objectForKey: @"KeepStandardInput"];
	      if (NO == [s respondsToSelector: @selector(boolValue)]
		|| NO == [s boolValue])
		{
		  [task setStandardInput: hdl];
		}
	      s = [conf objectForKey: @"KeepStandardOutput"];
	      if (NO == [s respondsToSelector: @selector(boolValue)]
		|| NO == [s boolValue])
		{
		  [task setStandardOutput: hdl];
		}
	      s = [conf objectForKey: @"KeepStandardError"];
	      if (NO == [s respondsToSelector: @selector(boolValue)]
		|| NO == [s boolValue])
		{
		  [task setStandardError: hdl];
		}
	      if (home != nil && [home length] > 0)
		{
		  [task setCurrentDirectoryPath: home];
		}
	      if (args != nil)
		{
		  [task setArguments: args];
		}

	      /* Record time of launch start
	       */
	      [[NSNotificationCenter defaultCenter]
		addObserver: self
		   selector: @selector(taskTerminated:)
		       name: NSTaskDidTerminateNotification
		     object: task];
              launchDate = [NSDate timeIntervalSinceReferenceDate];
	      [task launch];
	      identifier =  [task processIdentifier];
	      [[command logFile]
		printf: @"%@ launched %@ with %@ at %@\n",
		[NSDate date], prog, args,
		[NSThread callStackSymbols]];
	    }
	}
      NS_HANDLER
	{
	  identifier = 0;
	  [[NSNotificationCenter defaultCenter]
	    removeObserver: self
		      name: NSTaskDidTerminateNotification
		    object: task];
          launchDate = 0.0;
	  DESTROY(task);
	  failed = @"failed to launch";
	  m = [NSString stringWithFormat: cmdLogFormat(LT_CONSOLE,
	    @"failed to launch (%@) %@"), localException, name];
	  [command information: m from: nil to: nil type: LT_CONSOLE];
	}
      NS_ENDHANDLER
    }
  else
    {
      failed = @"bad program name to launch";
      m = [NSString stringWithFormat: cmdLogFormat(LT_CONSOLE,
	@"bad program name to launch %@"), name];
      [command information: m from: nil to: nil type: LT_CONSOLE];
    }

  if (nil != failed)
    {
      startingAlarm = YES;
      [command alarmCode: ACLaunchFailed
                procName: name
                 addText: failed];
    }
  LEAVE_POOL
  return [self checkAlive];  // On failure return NO
}

- (NSDate*) launchDate
{
  return (launchDate > 0.0) ? date(launchDate) : (NSDate*)nil;
}

- (BOOL) mayCoreDump
{
  if (fib1 > FIB)
    {
      /* If fib1 is greater than the base value, we must have already done
       * one restart due to a failure in launch or crash in early life.
       * We therefore want to suppress core dumps from subsequent crashes
       * in order to avoid filling the disk too quickly.
       */
      return NO;
    }
  return YES;
}

/* Checks the receiver to see if it is eligible to be removed from the
 * queue and launched.  If the receiver should not be in the queue it
 * is removed.
 */
- (NSString*) reasonToPreventLaunch
{
  EcCommand	*command = (EcCommand*)EcProc;
  NSArray       *unfulfilled;
  NSString      *reason = nil;

  if (NO == [self isStarting])
    {
      if ([launchQueue containsObject: self])
        {
          NSLog(@"Found object which is not starting in queue: %@", self);
          [launchQueue removeObject: self];
          queuedDate = 0.0;
        }
    }
  else if ([self isStopping])
    {
      if ([launchQueue containsObject: self])
        {
          NSLog(@"Found object which is stopping in queue: %@", self);
          [launchQueue removeObject: self];
          queuedDate = 0.0;
        }
    }
  else if (deferredDate > 0.0
    && [NSDate timeIntervalSinceReferenceDate] < deferredDate)
    {
      reason = [NSString stringWithFormat: @"waiting for retry at %@",
        date(deferredDate)];
    }
  else if ([command ecIsQuitting])
    {
      reason = @"system shutting down";
    }
  else if (terminateBy != nil)
    {
      reason = @"all servers shutting down";
    }
  else if (NO == launchEnabled)
    {
      reason = @"launching suspended";
    }
  else if (launchLimit > 0 && [LaunchInfo launching] >= launchLimit)
    {
      reason = [NSString stringWithFormat: @"%u launches in progress",
        (unsigned)launchLimit];
    }
  else if ([(unfulfilled = [self unfulfilled]) count] > 0)
    {
      reason = [NSString stringWithFormat: @"waiting for %@", unfulfilled];
    }
  return reason;
}

- (BOOL) mayBecomeStable
{
  if (nextStableDate <= 0.0
    || nextStableDate <= [NSDate timeIntervalSinceReferenceDate])
    {
      return YES;
    }
  return NO;
}

- (NSString*) name
{
  return name;
}

- (int) processIdentifier
{
  return identifier;
}

/* Check the current state, and if it's not the same as the desired state
 * start moving towards that desired state (unless already moving).
 */
- (void) progress
{
  if (NO == [self isStarting] && NO == [self isStopping])
    {
      if (Live == desired && nil == client)
        {
	  /* Possibly the client is already running (if the Command server
	   * has just started) or has been started externally and not yet
	   * connected ... if so see if we can get it to connect.
	   */
	  if (NO == [self checkActive])
	    {
	      [self start];
	    }
        }
      else if (Dead == desired && nil != client)
        {
          [self stop];
        }
      else
        {
          /* We reached the desired state, so we clear the desire
           * and decide if we need to change state normally.
           */
          desired = None;
          if ([self disabled])
            {
              /* If the config says we are disabled, we should stop.
               */
              if (nil != client)
                {
                  [self stop];
                }
            }
          else if ([self autolaunch] && 0.0 == clientQuitDate)
            {
	      ASSIGN(startedReason, @"autolaunch");
              /* If the config says we autolaunch and the last process
               * didn't shut down cleanly, we should start.
               */
              if (nil == client)
                {
                  [self start];
                }
            }
        }
    }
}

- (void) resetDelay
{
  deferredDate = 0.0;
  fib0 = fib1 = 0.0;
}

- (void) restart: (NSString*)reason
{
  if ([self checkActive])
    {
      if (NO == [self isStopping])
        {
          ASSIGNCOPY(restartReason, reason);
          ASSIGNCOPY(stoppedReason, @"Console restart command");
          [self stop];
        }
    }
  if (desired != Live)
    {
      [self setDesired: Live reason: @"Console restart command"];
    }
}

- (void) started
{
  EcCommand	*command = (EcCommand*)EcProc;
  NSString	*reason = AUTORELEASE(startedReason);

  startedReason = nil;
  if (nil == reason)
    {
      reason = @"started externally";
    }

  terminationCount = 0;
  terminationDate = 0.0;
  terminationStatusKnown = NO;
  nextStableDate = [NSDate timeIntervalSinceReferenceDate] + 10.0;
  if (clientLostDate > 0.0)
    {
      nextStableDate += 250.0;
    }
  clientLostDate = 0.0;
  clientQuitDate = 0.0;
  [launchQueue removeObject: self];
  pingDate = 0.0;
  hungDate = 0.0;
  queuedDate = 0.0;
  if ([self isStarting])
    {
      /* The client has connected and registered itself ... startup of
       * this process has completed.  Alarms will be cleared when the
       * new process becomes stable.
       */
      [startingTimer invalidate];
      startingTimer = nil;
      startingDate = 0.0;
    }

  [command auditState: self reason: reason];

  if (Dead == desired)
    {
      /* It is not desired that this process should be running:
       * initiate a shutdown.
       */
      [self stop];
    }
  [self progress];
  [LaunchInfo processQueue];    // Maybe we can launch more now
}

/* When process startup has completed and the client has registered itself
 * with the Command server, the registration process will call this method.
 * Here we should do all the work associated with completion of the startup
 * process.
 */
- (void) setClient: (EcClientI*)c
{
  int   newPid;

  NSAssert([c isKindOfClass: [EcClientI class]],
    NSInternalInconsistencyException);
  ASSIGN(client, c);

  newPid = [c processIdentifier];
  if (task != nil && [task processIdentifier] != newPid)
    {
      /* This could happen if someone manually launches the process
       * before the Command server launches it.  In that case we
       * need to cancel the handling of the task and depends on
       * the excess process to shut itself down.
       */ 
      NSLog(@"LaunchInfo(%@) new pid(%d) from client connection"
        @" differs from old pid(%d) from task launch",
        name, [task processIdentifier], newPid);
      [[NSNotificationCenter defaultCenter]
        removeObserver: self
                  name: NSTaskDidTerminateNotification
                object: task];
      launchDate = 0.0;
      DESTROY(task);
    }
  registrationDate = [NSDate timeIntervalSinceReferenceDate];
  identifier = newPid;
  [self started];
}

- (void) setConfiguration: (NSDictionary*)c
{
  BOOL	wasDisabled = [self disabled];

  ASSIGNCOPY(conf, c);
  if ([self disabled])
    {
      if (NO == wasDisabled)
	{
          EcCommand	*command = (EcCommand*)EcProc;

	  [command clearAll: name addText: @"process disabled in config"];
	}
      if (desired != Dead)
	{
	  [self setDesired: Dead reason: @"process disabled in config"];
	}
    }
  else if ([self autolaunch])
    {
      if (desired != Live)
	{
	  [self setDesired: Live reason: @"autolaunch"];
	}
    }
  else
    {
      if (desired != None)
	{
	  [self setDesired: None reason: nil];
	}
    }
}

/* Called when a manual change is made to specify what state a process should
 * be in (also called to set configured state).
 */
- (void) setDesired: (Desired)state reason: (NSString*)reason
{
  Desired       old = desired;

  desired = state;
  if (Live == desired)
    {
      ASSIGNCOPY(startedReason, reason);
    }
  if (Dead == desired)
    {
      ASSIGNCOPY(stoppedReason, reason);
    }
  if (terminateBy != nil && desired != Dead)
    {
      desired = Dead;
      NSLog(@"-setDesired:Dead forced by termination in progress for %@", self);
    }
  if (Live == desired && [self disabled])
    {
      desired = Dead;
      NSLog(@"-setDesired:Live overridden by Disabled config of %@", self);
    }
  if (old == desired)
    {
      NSLog(@"-setDesired:%@ unchanged of %@",
        desiredName(desired), self);
      if (terminateBy != nil && [self isStopping]
        && [[stoppingTimer fireDate] earlierDate: terminateBy] == terminateBy)
        {
          /* Force timer reset to match terminateBy
           */
          [self stopping: nil];
        }
    }
  else if ([self isStarting])
    {
      NSLog(@"-setDesired:%@ deferred pending startup of %@",
        desiredName(desired), self);
    }
  else if ([self isStopping])
    {
      NSLog(@"-setDesired:%@ deferred pending shutdown of %@",
        desiredName(desired), self);
    }
  else
    {
      if (Live == desired)
	{
          if ([self checkAlive])
            {
              NSLog(@"-setDesired:Live when already started of %@", self);
            }
	  else
	    {
              NSLog(@"-setDesired:Live requests startup of %@", self);
	    }
	}
      else if (Dead == desired)
	{
	  if ([self checkAlive])
	    {
              NSLog(@"-setDesired:Dead requests shutdown of %@", self);
	    }
          else
            {
              NSLog(@"-setDesired:Dead when already stopped of %@", self);
            }
	}
    }
  [self progress];
}

- (void) setHung
{
  if (hungDate <= 0.0)
    {
      hungDate = [NSDate timeIntervalSinceReferenceDate];
    }
}

- (void) setPing
{
  pingDate = [NSDate timeIntervalSinceReferenceDate];
}

- (void) setProcessIdentifier: (int)p
{
  identifier = p;
}

- (void) setStable: (BOOL)s
{
  if (NO == s)
    {
      stableDate = 0.0;
    }
  else if (s && 0.0 == stableDate)
    {
      stableDate = [NSDate timeIntervalSinceReferenceDate];
      [self resetDelay];
    }
}

- (BOOL) stable
{
  return stableDate > 0.0 ? YES : NO;
}

/* This method may be called to initiate startup of a server.
 * If called when a server is already starting or shutting down
 * it has no effect.
 */
- (void) start
{
  if ([self isStarting])
    {
      EcExceptionMajor(nil, @"-start when already starting of %@", self);
    }
  else if (startingTimer)
    {
      EcExceptionMajor(nil, @"-start when timer already set of %@", self);
    }
  else if (nil != client)
    {
      EcExceptionMajor(nil, @"-start when already active of %@", self);
    }
  else if (YES == [self checkAlive])
    {
      EcExceptionMajor(nil, @"-start when already alive of %@", self);
    }
  else
    {
      NSLog(@"-start called for %@", self);
      [self resetDelay];
      startingAlarm = NO;
      startingDate = [NSDate timeIntervalSinceReferenceDate];
      startingTimer = [NSTimer
        scheduledTimerWithTimeInterval: 0.01
        target: self
        selector: @selector(starting:)
        userInfo: name
        repeats: NO];
    }
}

- (BOOL) checkAbandonedStartup
{
  BOOL  abandon = NO;

  [self checkAlive];
  if (NO == [self isStarting] || client != nil)
    {
      return NO;        // Not starting
    }
  /* We will only abandon startup if we want the process to be dead
   */
  if (Dead == desired)
    {
      if (0 == identifier)
        {
          abandon = YES;        //  No process, easy to abandon
        }
      else
        {
          NSTimeInterval        now = [NSDate timeIntervalSinceReferenceDate];

          if (now - launchDate >= 30.0)
            {
              abandon = YES;            // One process taking too long to start
            }
          else if (now - startingDate >= 120.0)
            {
              abandon = YES;            // Multiple attempts taking too long
            }
        }
    }
  if (YES == abandon)
    {
      [startingTimer invalidate];
      startingTimer = nil;
      startingDate = 0.0;
      [launchQueue removeObject: self];
      if (identifier > 0)
        {
          if (task != nil)
            {
              [[NSNotificationCenter defaultCenter]
                removeObserver: self
                          name: NSTaskDidTerminateNotification
                        object: task];
              launchDate = 0.0;
              DESTROY(task);
            }
          kill(identifier, SIGKILL);
          identifier = 0;
        }
      if (startingAlarm)
        {
          EcCommand	*command = (EcCommand*)EcProc;

          startingAlarm = NO;
          [command clearAll: name addText: @"process manually stopped"];
        }
      [self progress];
    }
  return abandon;
}

- (void) starting: (NSTimer*)t
{
  EcCommand	        *command = (EcCommand*)EcProc;
  NSTimeInterval	ti = 0.0;

  /* On entry t is either a one-shot timer which will automatically
   * be invalidated after the method completes, or nil (method called
   * explicitly, so the timer must be invalidated here).
   * Either way the timer is no longer valid and a new one will need
   * to be created unless startup has completed.
   */
  [startingTimer invalidate];
  startingTimer = nil;
  if (NO == [self isStarting])
    {
      EcExceptionMajor(nil, @"-starting: when not starting for %@", self);
      return;
    }
  if (client != nil)
    {
      EcExceptionMajor(nil, @"-starting: when already registered for %@", self);
      return;
    }
  if ([self checkAbandonedStartup])
    {
      return;
    }
  if (0 == identifier)
    {
      NSString  *r = [self reasonToPreventLaunch];

      if (nil == r)
        {
          /* We are able to launch now
           */
          [launchQueue removeObject: self];
          queuedDate = 0.0;
	  terminationDate = 0.0;
	  terminationStatusKnown = NO;
          if (NO == [self launch])
            {
              ti = [self delay];        // delay between launch attempts
              [launchQueue addObject: self];
              queuedDate = [NSDate timeIntervalSinceReferenceDate];
              [command logChange: @"queued (launch failed)" for: name];
            }
          else
            {    
              if (client != nil)
                {
                  return;       // Connection established.
                }
              ti = 0.0;         // Calculate the time to wait below
              [command logChange: @"launched" for: name];
            }
        }
      else
        {
          BOOL  alreadyQueued = [launchQueue containsObject: self];
          NSTimeInterval        now = [NSDate timeIntervalSinceReferenceDate];

          if (deferredDate > 0.0 && now < deferredDate)
            {
              /* We are waiting for a retry at a specific time.
               * If we are not already queued, add to queue.
               */
              ti = deferredDate - now;
              if (NO == alreadyQueued)
                {
                  [launchQueue addObject: self];
                  queuedDate = [NSDate timeIntervalSinceReferenceDate];
                }
            }
          else
            {
              /* Launching is prevented for a non-time-based reason,
               * so we reset the time from which we count launching as
               * started and specify a timer for checking again.
               */
              startingDate = [NSDate timeIntervalSinceReferenceDate];
              ti = 1.0;
              if (NO == alreadyQueued)
                {
                  [launchQueue addObject: self];
                  queuedDate = [NSDate timeIntervalSinceReferenceDate];
                }
            }
          if (NO == alreadyQueued)
            {
              r = [NSString stringWithFormat: @"queued (%@)", r];
              [command logChange: r for: name];
            }
        }
    }
  if (0.0 == ti)
    {
      ti = [NSDate timeIntervalSinceReferenceDate];
      if (ti - startingDate < 30.0)
        {
          /* We need to raise an alarm if it takes longer than 30 seconds
           * to start up the process.
           */
          ti = 30.0 - (ti - startingDate);
        }
      else
        {
          if (NO == startingAlarm)
            {
              startingAlarm = YES;
              [command alarmCode: ACLaunchFailed
                        procName: name
                         addText: @"Client not active after launch attempt"];
            }
          ti = 60.0;
        }
    }
  if (nil != startingTimer)
    {
      [startingTimer invalidate];
      EcExceptionMajor(nil, @"startingTimer reset %@", self);
    }
  if (startingDate > 0.0)
    {
      startingTimer = [NSTimer scheduledTimerWithTimeInterval: ti
						       target: self
						     selector: _cmd
						     userInfo: name
						      repeats: NO];
    }
  else
    {
      NSLog(@"Startup cancelled in -starting: for %@", self);
    }
}

- (NSDate*) startingDate
{
  return (startingDate > 0.0) ? date(startingDate) : (NSDate*)nil;
}

- (NSString*) status
{
  NSString	*status;

  if ([self isStarting])
    {
      status = [NSString stringWithFormat: @"Starting since %@",
        date(startingDate)];
    }
  else if ([self isStopping])
    {
      status = [NSString stringWithFormat: @"Stopping since %@",
        date(stoppingDate)];
    }
  else if (nil == client)
    {
      status = @"Not active";
    }
  else
    {
      if ([self stable])
        {
          status = @"Active (stable)";
        }
      else
        {
          status = [NSString stringWithFormat: @"Active since %@",
            date(registrationDate)];
        }
    }
  return status;
}

- (void) stop
{
  if (NO == [self isStopping] && YES == [self checkAlive])
    {
      [self resetDelay];
      stoppingDate = [NSDate timeIntervalSinceReferenceDate];
      abortDate = stoppingDate + 120.0;
      if (nil == client)
        {
          /* No connection to client established ... try to shut it down
           * using a signal.
           */
          kill(identifier, SIGTERM);
        }
      else
        {
          NS_DURING
            {
              if (nil == restartReason)
                {
                  [[client obj] cmdQuit: 0];
                }
              else
                {
                  [[client obj] ecRestart: restartReason];
                  DESTROY(restartReason);
                }
            }
          NS_HANDLER
            {
              /* Client failed to respond.
               */
              if (nil != client)
                {
                  [self clearClient: client cleanly: NO];
                }
              NSLog(@"Exception sending command to %@", localException);
            }
          NS_ENDHANDLER
        }
      [self stopping: nil];
    }
}

- (void) stopped
{
  EcCommand	*command = (EcCommand*)EcProc;

  [stoppingTimer invalidate];
  stoppingTimer = nil;
  stoppingDate = 0.0;
  registrationDate = 0.0;
  awakenedDate = 0.0;
  stableDate = 0.0;
  abortDate = 0.0;
  DESTROY(terminateBy);         // Termination completed

  if (clientLostDate > 0.0 || clientQuitDate > 0.0)
    {
      NSString	*reason = AUTORELEASE(stoppedReason);

      stoppedReason = nil;
      if (nil == reason)
	{
	  if (terminationStatusKnown && terminationStatus != 0)
	    {
	      reason = [NSString stringWithFormat:
		@"stopped (died with signal %d)", terminationStatus];
	    }
	  else if (clientLostDate > 0.0)
	    {
	      reason = @"stopped (process lost)";
	    }
	  else
	    {
	      reason = @"stopped externally";
	    }
	}

      if (clientLostDate > 0.0)
	{
	  NSString      *text;

	  if (terminationStatusKnown)
	    {
	      text = [NSString stringWithFormat: @"termination status %d",
		terminationStatus];
	    }
	  else
	    {
	      text = @"termination status unknown";
	    }
	  [command alarmCode: ACProcessLost
		    procName: name
		     addText: text];
	  [command auditState: self reason: reason];
	}
      else if (clientQuitDate > 0.0)
	{
	  /* Clean shutdown (process unregistered itself).
	   */
	  [self resetDelay];
	  [command auditState: self reason: reason];
	}
    }
  else
    {
      /* Loss of a process which hadn't connected/registered.
       * This should not be audited as a stop since it did not start.
       */
    }

  [self progress];
  [LaunchInfo processQueue];
}

- (void) stopping: (NSTimer*)t
{
  NSTimeInterval	now;
  NSTimeInterval	ti;

  [stoppingTimer invalidate];
  stoppingTimer = nil;

  /* Still alive if:
   * a. we still have a DO network connection to the process
   * or
   * b. the process which registered with us is still alive
   */
  if (nil == client && NO == [self checkAlive])
    {
      if (nil == task)
        {
          [self stopped];
        }
      else
        {
          /* Gets subprocess exit status and then recursively calls
           * this method.
           */
          [task waitUntilExit];
        }
      return;
    }

  now = [NSDate timeIntervalSinceReferenceDate];
  if (stoppingDate <= 0.0)
    {
      stoppingDate = now;
    }
  if (abortDate <= 0.0)
    {
      abortDate = stoppingDate + 120.0;
    }
  if (nil != terminateBy)
    {
      ti = [terminateBy timeIntervalSinceReferenceDate];
      if (ti < abortDate)
        {
          abortDate = ti;
        }
    }
  ti = abortDate;
  if (ti <= now)
    {
      /* Maximum time for clean shutdown has passed.
       */
      [[NSNotificationCenter defaultCenter]
        removeObserver: self
                  name: NSTaskDidTerminateNotification
                object: task];
      launchDate = 0.0;
      if (identifier > 0)
        {
          kill(identifier, SIGKILL);
          identifier = 0;
        }
      if (client != nil)
        {
          [self clearClient: client cleanly: NO];
        }
      else if (nil == task)
        {
          [self stopped];
        }
      else
        {
          /* Gets subprocess exit status and then recursively calls
           * this method.
           */
          [task waitUntilExit];
        }
      return;
    }
  else
    {
      if (nil == client && nil == task)
        {
          /* This can happen if a process was launched externally and
           * connected to the Command server (so we know its PID).
           * We will not be notified when the process dies so we must
           * poll frequently for it.
           */
          ti = 0.1;
        }
      stoppingTimer = [NSTimer scheduledTimerWithTimeInterval: ti
                                                       target: self
                                                     selector: _cmd
                                                     userInfo: name
                                                      repeats: NO];
    }
}

- (NSDate*) stoppingDate
{
  return (stoppingDate > 0.0) ? date(stoppingDate) : (NSDate*)nil;
}

- (NSTask*) task
{
  return AUTORELEASE(RETAIN(task));
}

- (void) taskTerminated: (NSNotification*)n
{
  NSTask        *t = (NSTask*)[n object];

  if (nil == t)
    {
      /* For a fake termination, use existing task, if any.
       */
      t = task;
    }

  if (nil != t)
    {
      /* If we have a task, stop observing notifications for it.
       */
      [[NSNotificationCenter defaultCenter]
        removeObserver: self
                  name: NSTaskDidTerminateNotification
                object: t];
    }

  if (t == task)
    {
      terminationCount++;
      terminationStatus = [task terminationStatus];
      terminationStatusKnown = YES;
      terminationDate = [NSDate timeIntervalSinceReferenceDate];
      launchDate = 0.0;
      DESTROY(task);
      if (terminationStatus != 0)
        {
          NSLog(@"Termination status %d for %@ (pid %d)",
            terminationStatus, name, identifier);
        }
      identifier = 0;
      [self stopping: nil];
    }
}

- (NSArray*) unfulfilled
{
  NSMutableArray    *d = [[conf objectForKey: @"Deps"] mutableCopy];
  NSUInteger        c = [d count];

  while (c-- > 0)
    {
      NSString      *n = [d objectAtIndex: c];
      LaunchInfo    *l = [LaunchInfo existing: n];

      if ([l client] != nil)
        {
          [d removeObjectAtIndex: c];
        }
    }
  return d;
}

@end



@implementation	EcCommand

- (unsigned) activeCount
{
  return (unsigned)[clients count];
}

- (oneway void) alarm: (in bycopy EcAlarm*)alarm
{
  NS_DURING
    {
      [control alarm: alarm];
    }
  NS_HANDLER
    {
      NSLog(@"Exception sending alarm to Control: %@", localException);
    }
  NS_ENDHANDLER
}

/* Raise an alarm for a named process.
 */
- (void) alarmCode: (AlarmCode)ac
          procName: (NSString*)name
           addText: (NSString*)additional
{
  NSString	*managedObject;
  NSString      *problem;
  NSString      *repair;
  EcAlarm	*a;

  ENTER_POOL
  managedObject = EcMakeManagedObject(host, @"Command", name);
  ACStrings(ac, &problem, &repair);
  a = [EcAlarm alarmForManagedObject: managedObject
    at: nil
    withEventType: EcAlarmEventTypeProcessingError
    probableCause: EcAlarmSoftwareProgramError
    specificProblem: problem
    perceivedSeverity: EcAlarmSeverityCritical
    proposedRepairAction: repair
    additionalText: additional];
  [self alarm: a];
  LEAVE_POOL
}

- (void) auditState: (LaunchInfo*)l reason: (NSString*)additional
{
  NSString	*managedObject;
  NSString	*problem;
  EcAlarm	*a;

  /* For audit purposes we generate alarm clears without a corresponding
   * alarm raise.  The SpecificProblem field therefore does not describe
   * a problem in these cases.
   */
  if ([l isActive])
    {
      problem = @"Started (audit information)";
      NSLog(@"Started %@", l);
    }
  else
    {
      problem = @"Stopped (audit information)";
      NSLog(@"Stopped %@", l);
    }
  managedObject = EcMakeManagedObject(host, @"Command", [l name]);
  a = [EcAlarm alarmForManagedObject: managedObject
    at: nil
    withEventType: EcAlarmEventTypeProcessingError
    probableCause: EcAlarmSoftwareProgramError
    specificProblem: problem
    perceivedSeverity: EcAlarmSeverityCleared
    proposedRepairAction: @"none"
    additionalText: additional];
  [a setAudit: YES];
  [self alarm: a];
  [self update];
}

- (void) clearAll: (NSString*)name addText: (NSString*)additional
{
  NSString      *managedObject;
  NSString      *problem;
  NSString      *repair;
  EcAlarm       *a;
  AlarmCode     c;

  ENTER_POOL
  managedObject = EcMakeManagedObject(host, @"Command", name);
  for (c = ACLaunchFailed; c <= ACProcessLost; c++)
    {
      ACStrings(c, &problem, &repair);
      repair = @"cleared";
      a = [EcAlarm alarmForManagedObject: managedObject
        at: nil
        withEventType: EcAlarmEventTypeProcessingError
        probableCause: EcAlarmSoftwareProgramError
        specificProblem: problem
        perceivedSeverity: EcAlarmSeverityCleared
        proposedRepairAction: repair
        additionalText: additional];
      [self alarm: a];
    }
  LEAVE_POOL
}

/* Clear an  alarm for a named process.
 */
- (void) clearCode: (AlarmCode)ac
          procName: (NSString*)name
           addText: (NSString*)additional
{
  NSString	*managedObject;
  NSString      *problem;
  NSString      *repair;
  EcAlarm	*a;

  ENTER_POOL
  managedObject = EcMakeManagedObject(host, @"Command", name);
  ACStrings(ac, &problem, &repair);
  a = [EcAlarm alarmForManagedObject: managedObject
    at: nil
    withEventType: EcAlarmEventTypeProcessingError
    probableCause: EcAlarmSoftwareProgramError
    specificProblem: problem
    perceivedSeverity: EcAlarmSeverityCleared
    proposedRepairAction: repair
    additionalText: additional];
  [self alarm: a];
  LEAVE_POOL
}

- (EcClientI*) alive: (NSString*)name
{
  EcClientI		*found = nil;

  found = [self findIn: clients byName: name];
  if (nil == found)
    {
      CREATE_AUTORELEASE_POOL(pool);
      id<CmdClient>	proxy = nil;

      NS_DURING
	{
	  NSConnection	*c;

	  c = [NSConnection
	    connectionWithRegisteredName: name
	    host: @""
	    usingNameServer: [NSSocketPortNameServer sharedInstance]];
	  NS_DURING
	    {
	      /* Do not hang waiting for the other end to respond.
	       */
	      [c setRequestTimeout: 120.0];
	      [c setReplyTimeout: 120.0];
	      proxy = (id<CmdClient>)[c rootProxy];
	      [c setRequestTimeout: 0.0];
	      [c setReplyTimeout: 0.0];
	    }
	  NS_HANDLER
	    {
	      [c setRequestTimeout: 0.0];
	      [c setReplyTimeout: 0.0];
	    }
	  NS_ENDHANDLER
	  if (nil != proxy)
	    {
	      [proxy ecReconnect];
	      [[self logFile]
		printf: @"%@ requested reconnect %@\n", [NSDate date], name];
	    }
	}
      NS_HANDLER
	{
NSLog(@"Problem %@", localException);
	  proxy = nil;
	}
      NS_ENDHANDLER

      if (nil != proxy)
	{
	  NSDate	*when = [NSDate dateWithTimeIntervalSinceNow: 1.0];

	  while (nil == (found = [self findIn: clients byName: name])
	    && [when timeIntervalSinceNow] > 0.0)
	    {
	      NSDate	*next = [NSDate dateWithTimeIntervalSinceNow: 0.1];
	      [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
				       beforeDate: next];
	    }
	}
      DESTROY(pool);
    }
  return found;
}

- (void) disableLaunching
{
  launchEnabled = NO;
}

- (oneway void) domanage: (in bycopy NSString*)managedObject
{
  NS_DURING
    {
      [control domanage: managedObject];
    }
  NS_HANDLER
    {
      NSLog(@"Exception sending domanage: to Control: %@", localException);
    }
  NS_ENDHANDLER
}

- (void) ecAwaken
{
  [self contactControl];
  [super ecAwaken];
  [[self ecAlarmDestination] setCoalesce: NO];
  if (NO == [[self cmdDefaults] boolForKey: @"LaunchStartSuspended"])
    {
      [self enableLaunching];
    }
  /* Start housekeeping timer.
   */
  [self _housekeeping: nil];
}

- (void) enableLaunching
{
  launchEnabled = YES;
  [LaunchInfo processQueue];
}

- (oneway void) unmanage: (in bycopy NSString*)managedObject
{
  NS_DURING
    {
      [control unmanage: managedObject];
    }
  NS_HANDLER
    {
      NSLog(@"Exception sending unmanage: to Control: %@", localException);
    }
  NS_ENDHANDLER
}

- (NSFileHandle*) openLog: (NSString*)lname
{
  NSFileManager	*mgr = [NSFileManager defaultManager];
  NSFileHandle	*lf;

  if ([mgr isWritableFileAtPath: lname] == NO)
    {
      if ([mgr createFileAtPath: lname
		       contents: nil
		     attributes: nil] == NO)
	{
	  NSLog(@"Log file '%@' is not writable and can't be created", lname);
	  return nil;
	}
    }

  lf = [NSFileHandle fileHandleForUpdatingAtPath: lname];
  if (lf == nil)
    {
      NSLog(@"Unable to log to %@", lname);
      return nil;
    }
  [lf seekToEndOfFile];
  return lf;
}

- (void) newConfig: (NSMutableDictionary*)newConfig
{
  NSString	*diskCache;
  NSData	*data;

  diskCache = [[self cmdDataDirectory]
    stringByAppendingPathComponent: @"CommandConfig.cache"];

  if (NO == [newConfig isKindOfClass: [NSMutableDictionary class]]
    || 0 == [newConfig count])
    {
      /* If we are called with a nil argument, we must obtain the config
       * from local disk cache (if available).
       */
      if (nil != (data = [NSData dataWithContentsOfFile: diskCache]))
	{
	  newConfig = [NSPropertyListSerialization
	    propertyListWithData: data
	    options: NSPropertyListMutableContainers
	    format: 0
	    error: 0];
	}
      if (NO == [newConfig isKindOfClass: [NSMutableDictionary class]]
	|| 0 == [newConfig count])
	{
	  return;
	}
    }
  else
    {
      data = nil;
    }

  if (nil == config || [config isEqual: newConfig] == NO)
    {
      NSDictionary	*d;
      NSArray		*a;
      unsigned		i;

      ASSIGN(config, newConfig);
      d = [config objectForKey: [self cmdName]];
      launchLimit = 0;
      if ([d isKindOfClass: [NSDictionary class]] == YES)
	{
	  NSMutableArray	*missing;
	  NSDictionary		*conf;
	  NSEnumerator		*e;
          id                    o;
          NSInteger             i;
          NSMutableArray        *newOrder;
	  NSString              *k;
          NSString              *err = nil;

          NS_DURING
            {
              NSMutableDictionary       *m = AUTORELEASE([d mutableCopy]);

              [self cmdUpdate: m];
              d = m;
            }
          NS_HANDLER
            {
              NSLog(@"Problem before updating config (in cmdUpdate:) %@",
                localException);
              err = @"the -cmdUpdate: method raised an exception";
            }
          NS_ENDHANDLER
          if (nil == err)
            {
              NS_DURING
                err = [self cmdUpdated];
              NS_HANDLER
                NSLog(@"Problem after updating config (in cmdUpdated) %@",
                  localException);
                err = @"the -cmdUpdated method raised an exception";
              NS_ENDHANDLER
            }
          if ([err length] > 0)
            {
              EcAlarm       *a;

              /* Truncate additional text to fit if necessary.
               */
              err = [err stringByTrimmingSpaces];
              if ([err length] > 255)
                {
                  err = [err substringToIndex: 255];
                  while (255 < strlen([err UTF8String]))
                    {
                      err = [err substringToIndex: [err length] - 1];
                    }
                }
              a = [EcAlarm alarmForManagedObject: nil
                at: nil
                withEventType: EcAlarmEventTypeProcessingError
                probableCause: EcAlarmConfigurationOrCustomizationError
                specificProblem: @"configuration error"
                perceivedSeverity: EcAlarmSeverityMajor
                proposedRepairAction:
                _(@"Correct config or software (check log for details).")
                additionalText: err];
              [self alarm: a];
            }
          else
            {
              EcAlarm       *a;

              a = [EcAlarm alarmForManagedObject: nil
                at: nil
                withEventType: EcAlarmEventTypeProcessingError
                probableCause: EcAlarmConfigurationOrCustomizationError
                specificProblem: @"configuration error"
                perceivedSeverity: EcAlarmSeverityCleared
                proposedRepairAction: nil
                additionalText: nil];
              [self alarm: a];
            }

          /* We may not have more than this number of tasks launching at
           * any one time.  Once the launch limit is reached we should
           * launch new tasks as and when launching tasks complete their
           * startup and register with this process.
           */
	  i = [[[d objectForKey: @"LaunchLimit"] description] intValue];
          if (i <= 0)
            {
              launchLimit = 20;
            }
          else
            {
              launchLimit = (NSUInteger)i;
            }

	  missing = AUTORELEASE([[LaunchInfo names] mutableCopy]);
          o = [d objectForKey: @"LaunchOrder"];
          if ([o isKindOfClass: [NSArray class]])
            {
              newOrder = AUTORELEASE([o mutableCopy]);
            }
          else
            {
              if (nil != o)
                {
                  NSLog(@"bad 'LaunchOrder' config (not an array) ignored");
                }
              newOrder = nil;
            }

	  conf = [d objectForKey: @"Launch"];
	  if ([conf isKindOfClass: [NSDictionary class]] == NO)
	    {
	      NSLog(@"No 'Launch' information in latest config update");
              newOrder = nil;
	    }
	  else
	    {
              NSMutableDictionary       *md = [NSMutableDictionary dictionary];
              NSUInteger                entryCount = 0;

	      e = [conf keyEnumerator];
	      while ((k = [e nextObject]) != nil)
		{
                  NSMutableDictionary   *d;
		  id		        o = [conf objectForKey: k];

		  if ([o isKindOfClass: [NSDictionary class]] == NO)
		    {
		      NSLog(@"bad 'Launch' information for %@", k);
		      continue;
		    }
                  d = AUTORELEASE([o mutableCopy]);
                  
		  o = [d objectForKey: @"Auto"];
		  if (o != nil && [o isKindOfClass: [NSString class]] == NO)
		    {
		      NSLog(@"bad 'Launch' Auto for %@", k);
		      continue;
		    }
		  o = [d objectForKey: @"Time"];
		  if (o != nil && ([o isKindOfClass: [NSString class]] == NO
                    || [o intValue] < 1 || [o intValue] > 600))
		    {
		      NSLog(@"bad 'Launch' Time for %@", k);
		      continue;
		    }
		  o = [d objectForKey: @"Disabled"];
		  if (o != nil && [o isKindOfClass: [NSString class]] == NO)
		    {
		      NSLog(@"bad 'Launch' Disabled for %@", k);
		      continue;
		    }
		  o = [d objectForKey: @"Args"];
		  if (o != nil && [o isKindOfClass: [NSArray class]] == NO)
		    {
		      NSLog(@"bad 'Launch' Args for %@", k);
		      continue;
		    }
		  o = [d objectForKey: @"Home"];
		  if (o != nil && [o isKindOfClass: [NSString class]] == NO)
		    {
		      NSLog(@"bad 'Launch' Home for %@", k);
		      continue;
		    }
		  o = [d objectForKey: @"Prog"];
		  if (o == nil || [o isKindOfClass: [NSString class]] == NO)
		    {
		      NSLog(@"bad 'Launch' Prog for %@", k);
		      continue;
		    }
		  o = [d objectForKey: @"AddE"];
		  if (o != nil && [o isKindOfClass: [NSDictionary class]] == NO)
		    {
		      NSLog(@"bad 'Launch' AddE for %@", k);
		      continue;
		    }
		  o = [d objectForKey: @"SetE"];
		  if (o != nil && [o isKindOfClass: [NSDictionary class]] == NO)
		    {
		      NSLog(@"bad 'Launch' SetE for %@", k);
		      continue;
		    }
		  o = [d objectForKey: @"Deps"];
		  if (o != nil)
		    {
                      if ([o isKindOfClass: [NSArray class]] == NO)
                        {
                          NSLog(@"bad 'Launch' Deps for %@ (not an array)", k);
                          continue;
                        }
                      o = AUTORELEASE([o mutableCopy]);
                      [d setObject: o forKey: @"Deps"];
                    }
                  [md setObject: d forKey: k];
		}

              while (entryCount != [md count])
                {
                  entryCount = [md count];
                  e = [[md allKeys] objectEnumerator];
                  while (nil != (k = [e nextObject]))
                    {
                      NSDictionary	*d = [md objectForKey: k];
                      NSArray           *a = [d objectForKey: @"Deps"];
                      NSUInteger        c = [a count];

                      while (c-- > 0)
                        {
                          NSString  *name = [a objectAtIndex: c];

                          if ([name isEqual: k])
                            {       
                              NSLog(@"bad 'Launch' Deps for %@"
                                @" (depends on self)", k);
                              [md removeObjectForKey: k];
                            }
                          if (nil == [md objectForKey: name])
                            {       
                              NSLog(@"bad 'Launch' Deps for %@"
                                @" (depends on %@)", k, name);
                              [md removeObjectForKey: k];
                            }
                        }
                    }
                }
              conf = md;

              /* Validate the LaunchOrder array.
               */
              if (newOrder != nil)
                {
                  NSUInteger    c;

                  c = [newOrder count];
                  while (c-- > 0)
                    {
                      o = [newOrder objectAtIndex: c];
                      if (NO == [o isKindOfClass: [NSString class]])
                        {
                          NSLog(@"bad 'LaunchOrder' item ('%@' at %u) ignored"
                            @" (not a server name)", o, (unsigned)c);
                          [newOrder removeObjectAtIndex: c];
                        }
                      else if ([newOrder indexOfObject: o] != c)
                        {
                          NSLog(@"bad 'LaunchOrder' item ('%@' at %u) ignored"
                            @" (repeat of earlier item)", o, (unsigned)c);
                          [newOrder removeObjectAtIndex: c];
                        }
                      else if (nil == [conf objectForKey: o])
                        {
                          NSLog(@"bad 'LaunchOrder' item ('%@' at %u) ignored"
                            @" (not in 'Launch' dictionary)", o, (unsigned)c);
                          [newOrder removeObjectAtIndex: c];
                        }
                    }
                }

              /* Now that we have validated the config, we update
               * (creating if necessary) the LaunchInfo object.
               */
              e = [conf keyEnumerator];
              while (nil != (k = [e nextObject]))
                {
                  LaunchInfo	*l;

                  if ((l = [LaunchInfo launchInfo: k]) != nil)
                    {
		      if (nil == [l client])
			{
			  EcClientI	*c;

			  /* Due to the config change, we may have a new
			   * LaunchInfo object.  There is also a possibility
			   * that the process has already been launched
			   * manually (or the config for the process was
			   * removed and then restored).  We must therefore
			   * check and associate any existing registration
			   * with the new launch info.
			   */
			  c = [self findIn: clients byName: [l name]];
			  if (c != nil)
			    {
			      [l setClient: c];
			    }
			}
                      [l setConfiguration: [conf objectForKey: k]];
                      [missing removeObject: k];
                    }
                }
            }

	  /* Now any process names which have no configuration must be
	   * removed from the list of launchable processes and have any
	   * alarms cleared.
	   */
	  e = [missing objectEnumerator];
	  while (nil != (k = [e nextObject]))
	    {
	      [self clearAll: k addText: @"process removed from config"];
	      [LaunchInfo remove: k];
	    }

          if ([newOrder count] == 0)
            {
              /* The default launch order is alphabetical by server name.
               */
              o = [[LaunchInfo names] sortedArrayUsingSelector:
                @selector(compare:)];
              ASSIGN(launchOrder, o);
            }
          else
            {
              NSEnumerator      *e;
              NSString          *k;

              /* Any missing servers are launched after others
               * they are in lexicographic order.
               */
              o = [[LaunchInfo names] sortedArrayUsingSelector:
                @selector(compare:)];
              e = [o objectEnumerator];
              while (nil != (k = [e nextObject]))
                {
                  if (NO == [newOrder containsObject: k])
                    {
                      [newOrder addObject: k];
                    }
                }
              ASSIGNCOPY(launchOrder, newOrder);
            }

	  o = [d objectForKey: @"Environment"];
	  if ([o isKindOfClass: [NSDictionary class]] == NO)
	    {
	      NSLog(@"No 'Environment' information in latest config update");
	      o = nil;
	    }
	  ASSIGN(environment, o);

	  k = [d objectForKey: @"NodesFree"];
	  if (YES == [k isKindOfClass: [NSString class]])
	    {
	      nodesFree = [k floatValue];
	      nodesFree /= 100.0;
	    }
	  else
	    {
	      nodesFree = 0.0;
	    }
	  if (nodesFree < 0.02 || nodesFree > 0.9)
	    {
	      NSLog(@"bad or missing minimum disk 'NodesFree' ... using 10%%");
	      nodesFree = 0.1;
	    }
	  k = [d objectForKey: @"SpaceFree"];
	  if (YES == [k isKindOfClass: [NSString class]])
	    {
	      spaceFree = [k floatValue];
	      spaceFree /= 100.0;
	    }
	  else
	    {
	      spaceFree = 0.0;
	    }
	  if (spaceFree < 0.02 || spaceFree > 0.9)
	    {
	      NSLog(@"bad or missing minimum disk 'SpaceFree' ... using 10%%");
	      spaceFree = 0.1;
	    }
	}
      else
	{
	  NSLog(@"No '%@' information in latest config update", [self cmdName]);
	}

      a = [NSArray arrayWithArray: clients];
      i = [a count];
      while (i-- > 0)
	{ 
	  EcClientI	*c = [a objectAtIndex: i];

	  if ([clients indexOfObjectIdenticalTo: c] != NSNotFound)
	    {
	      NS_DURING
		{
		  NSData	*d = [self configurationFor: [c name]];

		  if (nil != d)
		    {
		      [c setConfig: d];
		      [[c obj] updateConfig: d];
		    }
		}
	      NS_HANDLER
		{
		  NSLog(@"Setting config for client: %@", localException);
		}
	      NS_ENDHANDLER
	    }
	}
      if (nil == data)
	{
	  /* Need to update on-disk cache
	   */
	  data = [NSPropertyListSerialization
	    dataFromPropertyList: newConfig
	    format: NSPropertyListBinaryFormat_v1_0
	    errorDescription: 0];
	  [data writeToFile: diskCache atomically: YES];
	}
    }
}

- (void) pingControl
{
  if (control == nil)
    {
      return;
    }
  if (fwdSequence == revSequence)
    {
      outstanding = RETAIN([NSDate date]);
      NS_DURING
	{
	  [control cmdPing: self sequence: ++fwdSequence extra: nil];
	}
      NS_HANDLER
	{
	  NSLog(@"Ping to control server - %@", localException);
	}
      NS_ENDHANDLER
    }
  else
    {
      NSLog(@"Ping to control server when one is already in progress.");
    }
}

- (oneway void) cmdGnip: (id <CmdPing>)from
               sequence: (unsigned)num
                  extra: (NSData*)data
{
  if (from == control)
    {
      if (num != revSequence + 1 && revSequence != 0)
	{
	  NSLog(@"Gnip from control server seq: %u when expecting %u",
	    num, revSequence);
	  if (num == 0)
	    {
	      fwdSequence = 0;	// Reset
	    }
	}
      revSequence = num;
      if (revSequence == fwdSequence)
	{
	  DESTROY(outstanding);
	}
    }
  else
    {
      EcClientI	*r;

      /* See if we have a fitting client - and update records.
       * A client is considered to be stable one it has been up for 
       * at least three pings.  The -setStable: method sets the client
       * as being stable and the -stable method returns a boolean to let
       * us know if a client is already stable.
       */
      r = [self findIn: clients byObject: (id)from];
      [r gnip: num];
      if (r != nil)
	{
          NSString      *n = [r name];
	  LaunchInfo	*l = [LaunchInfo existing: n];

	  [l setPing];	// Record the fact that we have a ping response.
	  if ([l isHung])
	    {
	      /* Had a ping response, so the process is no longer hung.
	       */
	      [l clearHung];
	    }
	  if (num > 2)
	    {
	      /* This was a successful launch so we don't need to impose
	       * a delay between launch attempts.
	       */
	      [l resetDelay];
	      if (NO == [l stable] && [l mayBecomeStable])
		{
		  /* After the first few ping responses from a client we assume
		   * that client has completed startup and is running OK.
		   * We can therefore clear any loss of client alarm, any
		   * alarm for being unable to register, and launch failure
		   * or fatal configuration alarms.
		   */
		  [l setStable: YES];
		  [self clearAll: [l name] addText: @"process is now stable"];
		}
	    }
	}
    }
}

- (BOOL) cmdIsClient
{
  return NO;	// Not a client of the Command server.
}

- (oneway void) cmdPing: (id <CmdPing>)from
               sequence: (unsigned)num
                  extra: (NSData*)data
{
  /* Send back a response to let the other party know we are alive.
   */
  [from cmdGnip: self sequence: num extra: nil];
}

- (oneway void) cmdQuit: (NSInteger)sig
{
  [[NSNotificationCenter defaultCenter]
    removeObserver: self
              name: NSConnectionDidDieNotification
            object: nil];
  [[NSNotificationCenter defaultCenter]
    removeObserver: self
              name: NSTaskDidTerminateNotification
            object: nil];

  if (sig == tStatus && control != nil)
    {
      NS_DURING
	{
	  [control unregister: self];
	}
      NS_HANDLER
	{
	  NSLog(@"Exception unregistering from Control: %@", localException);
	}
      NS_ENDHANDLER
    }
  exit(sig);
}

- (void) command: (NSData*)dat
	      to: (NSString*)t
	    from: (NSString*)f
{
  NSMutableArray	*cmd = [NSPropertyListSerialization
    propertyListWithData: dat
    options: NSPropertyListMutableContainers
    format: 0
    error: 0];

  if (cmd == nil || [cmd count] == 0)
    {
      [self information: cmdLogFormat(LT_ERROR, @"bad command array")
		   from: nil
		     to: f
		   type: LT_ERROR];
    }
  else if (t == nil)
    {
      NSString	*m = @"";
      NSString	*wd = cmdWord(cmd, 0);

      if ([wd length] == 0)
	{
	  /* Quietly ignore.	*/
	}
      else if (comp(wd, @"archive") >= 0)
	{
	  NSCalendarDate	*when;

	  m = [NSString stringWithFormat: @"\n%@\n", [self ecArchive: nil]];
	  when = [NSCalendarDate date];
	}
      else if (comp(wd, @"help") >= 0)
	{
	  wd = cmdWord(cmd, 1);
	  if ([wd length] == 0)
	    {
	      m = @"Commands are -\n"
	      @"Help\tArchive\tControl\tLaunch\tList\tMemory\t"
              @"Quit\tRestart\tStatus\tTell\n\n"
	      @"Type 'help' followed by a command word for details.\n"
	      @"A command line consists of a sequence of words, "
	      @"the first of which is the command to be executed. "
	      @"A word can be a simple sequence of non-space characters, "
	      @"or it can be a 'quoted string'. "
	      @"Simple words are converted to lower case before "
	      @"matching them against commands and their parameters. "
	      @"Text in a 'quoted string' is NOT converted to lower case "
	      @"but a '\\' character is treated in a special manner -\n"
	      @"  \\b is replaced by a backspace\n"
	      @"  \\f is replaced by a formfeed\n"
	      @"  \\n is replaced by a linefeed\n"
	      @"  \\r is replaced by a carriage-return\n"
	      @"  \\t is replaced by a tab\n"
	      @"  \\0 followed by up to 3 octal digits is replaced"
	      @" by the octal value\n"
	      @"  \\x followed by up to 2 hex digits is replaced"
	      @" by the hex value\n"
	      @"  \\ followed by any other character is replaced by"
	      @" the second character.\n"
	      @"  This permits use of quotes and backslashes inside"
	      @" a quoted string.\n";
	    }
	  else
	    {
	      if (comp(wd, @"Archive") >= 0)
		{
		  m = @"Archive\nArchives the log file. The archived log "
		      @"file is stored in a subdirectory whose name is of "
		      @"the form YYYYMMDDhhmmss being the date and time at "
		      @"which the archive was created.\n";
		}
	      else if (comp(wd, @"Control") >= 0)
		{
		  m = @"Control ...\nPasses the command to the Control "
		      @"process.  You may disconnect from this host by "
		      @"typing 'control host'\n";
		}
	      else if (comp(wd, @"Launch") >= 0)
		{
		  m = @"Launch <name>\nAdds the named program to the list "
		      @"of programs to be launched as soon as possible.\n"
		      @"Launch all\nAdds all unlaunched programs which do "
		      @"not have autolaunch disabled.\n";
		}
	      else if (comp(wd, @"List") >= 0)
		{
		  m = @"List\nLists all the connected clients.\n"
		      @"List launches\nLists the programs we can launch.\n"
		      @"List limit\nReports concurrent launch attempt limit.\n"
		      @"List order\nReports launch attempt order.\n"
		      @"List process name\nReports detail on named process.\n";
		}
	      else if (comp(wd, @"Memory") >= 0)
		{
		  m = @"Memory\nDisplays recent memory allocation stats.\n"
		      @"Memory all\nDisplays all memory allocation stats.\n";
		}
	      else if (comp(wd, @"Quit") >= 0)
		{
		  m = @"Quit 'name'\n"
		      @"Shuts down the named client process(es).\n"
		      @"Quit all\n"
		      @"Shuts down all client processes.\n"
		      @"Quit self\n"
		      @"Shuts down the Command server for this host.\n";
		}
	      else if (comp(wd, @"Restart") >= 0)
		{
		  m = @"Restart 'name'\n"
		      @"Shuts down and starts the named client process(es).\n"
		      @"Restart all\n"
		      @"Shuts down and starts all client processes.\n"
		      @"Restart self\n"
		      @"Shuts down and starts Command server for this host.\n";
		}
              else if (comp(wd, @"Resume") >= 0)
                {
                  m = @"Resumes the launching/relaunching of tasks.\n"
                      @"Has no effect if launching has not been suspended.\n";
                }
	      else if (comp(wd, @"Status") >= 0)
		{
		  m = @"Status\nReports the status of the Command server.\n"
		      @"Status name\nReports launch status of the process.\n";
		}
              else if (comp(wd, @"Suspend") >= 0)
                {
                  m = @"Suspends the launching/relaunching of tasks.\n"
                      @"Has no effect if this has already been suspended.\n";
                }
	      else if (comp(wd, @"Tell") >= 0)
		{
		  m = @"Tell 'name' 'command'\n"
		      @"Sends the command to the named client(s).\n"
		      @"You may use 'tell all ...' to send to all clients.\n";
		}
	    }
	}
      else if (comp(wd, @"launch") >= 0)
	{
          if (NO == launchEnabled)
            {
              m = @"Launching of tasks is suspended.\n"
                  @"Use the Resume command to resume launching.\n";
            }
	  else if ([cmd count] > 1)
	    {
              NSString	        *nam = [cmd objectAtIndex: 1];
              NSMutableString   *s = [NSMutableString string];
              BOOL              all = NO;

              if ([nam caseInsensitiveCompare: @"all"] == NSOrderedSame)
                {
                  all = YES;
                }

	      if ([launchOrder count] > 0)
		{
                  NSArray       *names;
		  NSEnumerator	*enumerator;
		  NSString	*key;

                  /* Build array of process names matching request.
                   */
                  if (YES == all)
                    {
                      names = launchOrder;
                    }
                  else
                    {
                      NSMutableArray    *a = [NSMutableArray array];
                      enumerator = [launchOrder objectEnumerator];
                      while ((key = [enumerator nextObject]) != nil)
                        {
                          if (comp(nam, key) >= 0)
                            {
                              [a addObject: key];
                            }
                        }
                      names = a;
                    }

                  enumerator = [names objectEnumerator];
                  while ((key = [enumerator nextObject]) != nil)
                    {
                      LaunchInfo	*l = [LaunchInfo existing: key];

                      if ([l disabled] == YES)
                        {
                          if (NO == all)
                            {
                              [s appendFormat:
                                @"  %-32.32s disabled in config\n",
                                [key UTF8String]];
                            }
                        }
                      else if ([l isActive])
                        {
                          if (NO == all)
                            {
                              [s appendFormat:
                                @"  %-32.32s is already running\n",
                                [key UTF8String]];
                            }
                        }
                      else if ([l isStarting])
                        {
                          NSArray       *u = [l unfulfilled];

                          if (NO == all || [u count] > 0)
                            {
                              if ([u count] > 0)
                                {
                                  [s appendFormat:
                                    @"  %-32.32s is queued waiting for %@\n",
                                    [key UTF8String], u];
                                }
                              else
                                {
                                  [s appendFormat:
                                    @"  %-32.32s is already starting\n",
                                    [key UTF8String]];
                                }
                            }
                        }
                      else if ([l isStopping])
                        {
                          [s appendFormat:
                            @"  %-32.32s is stopping (will restart)\n",
                            [key UTF8String]];
                          [l setDesired: Live
			         reason: @"Console launch command"];
                        }
                      else
                        {
                          [s appendFormat:
                            @"  %-32.32s will be started\n",
                            [key UTF8String]];
                          [l resetDelay];
                          [l setDesired: Live
				 reason: @"Console launch command"];
                        }
                    }

		  if ([names count] == 0)
		    {
                      /* May happen if the name given doesn't match
                       * anything in the launch array.
                       */
                      [s appendString:
                         @"I don't know how to launch that program.\n"];
		    }
                  else if ([s length] == 0)
                    {
                      /* May happen if we were looking for all the
                       * launchable processes and there weren't any.
                       */
                      [s appendString:
                         @"Nothing found to start.\n"];
                    }
		}
	      else
		{
		  [s appendString: @"There are no programs we can launch.\n"];
		}
              m = s;
	    }
	  else
	    {
	      m = @"I need the name of a program to launch.\n";
	    }
	}
      else if (comp(wd, @"list") >= 0)
	{
	  wd = cmdWord(cmd, 1);
	  if ([wd length] == 0 || comp(wd, @"clients") >= 0)
	    {
	      if ([clients count] == 0)
		{
		  m = @"No clients currently connected.\n";
		}
	      else
		{
		  unsigned	i;

		  m = @"Current client processes -\n";
		  for (i = 0; i < [clients count]; i++)
		    {
		      EcClientI	*c = [clients objectAtIndex: i];

		      m = [NSString stringWithFormat:
			@"%@%2d.   %-32.32s (pid:%d)\n",
			m, i, [[c name] cString], [c processIdentifier]];
		    }
		}
	    }
	  else if (comp(wd, @"launches") >= 0)
	    {
	      NSArray	*names = [LaunchInfo names];

	      if ([names count] > 0)
		{
		  NSEnumerator	*enumerator;
		  NSString	*key;

		  m = @"Programs we can launch -\n";
		  enumerator = [[names sortedArrayUsingSelector:
		    @selector(compare:)] objectEnumerator];
		  while ((key = [enumerator nextObject]) != nil)
		    {
		      LaunchInfo	*l = [LaunchInfo existing: key];
                      NSString          *status = [l status];

		      m = [m stringByAppendingFormat: @"  %-32.32s ",
			[key cString]];
                      if ([l disabled] == YES)
                        {
                          m = [m stringByAppendingString: 
                            @"disabled in config\n"];
                        }
                      else
                        {
                          m = [m stringByAppendingFormat: @"%@\n", status]; 
                        }
		    }
		}
	      else
		{
		  m = @"There are no programs we can launch.\n";
		}
              if (NO == launchEnabled)
                {
                  m = [m stringByAppendingString:
                    @"\nLaunching is suspended.\n"];
                }
	    }
	  else if (comp(wd, @"limit") >= 0)
	    {
	      m = [NSString stringWithFormat:
		@"Limit of concurrent launch attempts is: %u\n",
		(unsigned)launchLimit]; 	
	    }
	  else if (comp(wd, @"order") >= 0)
	    {
	      m = [NSString stringWithFormat: @"Launch order is: %@\n",
		launchOrder]; 	
	    }
	  else if (comp(wd, @"process") >= 0)
	    {
	      NSEnumerator	*enumerator;
	      NSString		*key;

	      wd = cmdWord(cmd, 2);
	
	      enumerator = [launchOrder objectEnumerator];
	      while ((key = [enumerator nextObject]) != nil)
		{
		  if (comp(wd, key) >= 0)
		    {
		      LaunchInfo	*l = [LaunchInfo existing: key];

		      m = [m stringByAppendingFormat: @"%@\n", l];
		    }
		}
	    }
	}
      else if (comp(wd, @"memory") >= 0)
	{
	  if (GSDebugAllocationActive(YES) == NO)
	    {
	      m = @"Memory statistics were not being gathered.\n"
		  @"Statistics Will start from NOW.\n";
	    }
	  else
	    {
	      const char*	list;

	      wd = cmdWord(cmd, 1);
	      if ([wd length] > 0 && comp(wd, @"all") >= 0)
		{
		  list = GSDebugAllocationList(NO);
		}
	      else
		{
		  list = GSDebugAllocationList(YES);
		}
	      m = [NSString stringWithCString: list];
	    }
	}
      else if (comp(wd, @"quit") >= 0)
	{
	  wd = cmdWord(cmd, 1);
	  if ([wd length] > 0)
	    {
	      if (comp(wd, @"self") == 0)
		{
		  if (terminating == nil)
		    {
		      NS_DURING
			{
			  [control unregister: self];
			}
		      NS_HANDLER
			{
			  NSLog(@"Exception unregistering from Control: %@",
			    localException);
			}
		      NS_ENDHANDLER
		      exit(0);
		    }
		  else
		    {
		      m = @"Already terminating!\n";
		    }
		}
	      else if (comp(wd, @"all") == 0)
		{
		  [self quitAll];

		  if ([clients count] == 0)
		    {
		      m = @"All clients have been shut down.\n";
		    }
		  else if ([clients count] == 1)
		    {
		      m = @"One client did not shut down.\n";
		    }
		  else
		    {
		      m = @"Some clients did not shut down.\n";
		    }
		}
	      else
		{
		  NSArray	*a;
		  unsigned	i;
		  BOOL		found = NO;

		  a = [self findAll: clients byAbbreviation: wd];
		  for (i = 0; i < [a count]; i++)
		    {
		      EcClientI	*c = [a objectAtIndex: i];

		      NS_DURING
			{
			  LaunchInfo	*l;

			  m = [m stringByAppendingFormat: 
			    @"Sending 'quit' to '%@'\n", [c name]];
			  m = [m stringByAppendingString:
			    @"  Please wait for this to be 'removed' before "
			    @"proceeding.\n"];
			  l = [LaunchInfo existing: [c name]];
                          if (nil == l)
                            {
                              [[c obj] cmdQuit: 0];
                            }
                          else
                            {
                              [l setDesired: Dead
				     reason: @"Console quit command"];
                              [l checkAbandonedStartup];
                            }
			  [self clearAll: [c name]
				 addText: @"manually stopped"];
			  found = YES;
			}
		      NS_HANDLER
			{
			  NSLog(@"Caught exception: %@", localException);
			}
		      NS_ENDHANDLER
		    }
		  if (NO == found && [launchInfo count] > 0)
		    {
		      NSEnumerator	*enumerator;
		      NSString		*key;

		      enumerator = [launchOrder objectEnumerator];
		      while ((key = [enumerator nextObject]) != nil)
			{
			  if (comp(wd, key) >= 0)
			    {
			      LaunchInfo	*l;

                              found = YES;
			      l = [LaunchInfo existing: key];
                              if ([l desired] == Dead)
				{
				  m = [m stringByAppendingFormat:
				    @"Suspended %@ already\n", key];
				}
			      else
				{
                                  [l setDesired: Dead
					 reason: @"Console quit command"];
				  m = [m stringByAppendingFormat:
				    @"Suspended %@\n", key];
				}
                              [l checkAbandonedStartup];
			      [self clearAll: [l name]
				     addText: @"manually stopped"];
			    }
			}
		    }
		  if (NO == found)
		    {
		      m = [NSString stringWithFormat: 
			@"Nothing to shut down as '%@'\n", wd];
		    }
		}
	    }
	  else
	    {
	      m = @"Quit what?.\n";
	    }
	}
      else if (comp(wd, @"restart") >= 0)
	{
	  wd = cmdWord(cmd, 1);
	  if ([wd length] > 0)
	    {
              NSString  *reason = nil;
              NSArray   *a = nil;

	      if (comp(wd, @"self") == 0)
		{
		  if (terminating == nil)
		    {
		      NS_DURING
			{
                          [self information: @"Re-starting Command server\n"
                                       from: t
                                         to: f
                                       type: LT_CONSOLE];
			  [control unregister: self];
			}
		      NS_HANDLER
			{
			  NSLog(@"Exception unregistering from Control: %@",
			    localException);
			}
		      NS_ENDHANDLER
		      exit(-1);          // Watcher should restart us
		    }
		  else
		    {
		      m = @"Already terminating!\n";
		    }
		}
	      else if (comp(wd, @"all") == 0)
		{
		  a = clients;
                  reason = [NSString stringWithFormat:
                    @"Console 'restart all' from '%@'", f];
                }
	      else
		{
		  a = [self findAll: clients byAbbreviation: wd];
                  reason = [NSString stringWithFormat:
                    @"Console 'restart ...' from '%@'", f];
                }
              if (a != nil)
                {
		  unsigned	i;
		  BOOL		found = NO;
                  NSDate        *when;

                  when = [NSDate dateWithTimeIntervalSinceNow: 30.0];
		  for (i = 0; i < [a count]; i++)
		    {
		      EcClientI	*c = [a objectAtIndex: i];

		      NS_DURING
			{
			  LaunchInfo	*l;

			  m = [m stringByAppendingFormat: 
			    @"  The process '%@' should restart shortly.\n",
			    [c name]];
			  l = [LaunchInfo existing: [c name]];
                          [l restart: reason];
			  found = YES;
			}
		      NS_HANDLER
			{
			  NSLog(@"Caught exception: %@", localException);
			}
		      NS_ENDHANDLER
		    } 
		  if (NO == found)
		    {
		      m = [NSString stringWithFormat: 
			@"Nothing to restart as '%@'\n", wd];
		    }
		}
	    }
	  else
	    {
	      m = @"Restart what?.\n";
	    }
	}
      else if (comp(wd, @"resume") >= 0)
        {
          if (NO == launchEnabled)
            {
              [self enableLaunching];
              m = @"Launching is now resumed.\n";
            }
          else
            {
              m = @"Launching was/is not suspended.\n";
            }
        }
      else if (comp(wd, @"status") >= 0)
        {
          m = [self description];
	  if ([(wd = cmdWord(cmd, 1)) length] > 0)
	    {
	      LaunchInfo	*l = [LaunchInfo find: wd];

	      if (nil == l)
		{
		  m = [m stringByAppendingFormat:
		    @"\nUnable to find '%@' in the launchable processes.\n",
		    wd];
		}
	      else
		{
		  NSString	*n = [l name];

		  if ([self findIn: clients byName: n] != nil)
		    {
		      m = [m stringByAppendingFormat:
			@"\nProcess '%@' is running.", n];
		    }
		  else if ([l isStarting])
		    {
		      m = [m stringByAppendingFormat:
			@"\nProcess '%@' is starting since %@",
                        n, [l startingDate]];
                      if ([l processIdentifier] > 0)
                        {
                          m = [m stringByAppendingFormat:
                            @" (last launch at %@)", [l launchDate]];
                        }
                      else
                        {
                          NSArray       *u = [l unfulfilled];

                          if ([u count] > 0)
                            {
                              m = [m stringByAppendingFormat:
                                @", waiting for %@", u];
                            }
                        }
                      m = [m stringByAppendingString: @"."];
		    }
		  m = [m stringByAppendingFormat: @"\n%@\n", l];
		}
	    }
        }
      else if (comp(wd, @"suspend") >= 0)
        {
          if (NO == launchEnabled)
            {
              m = @"Launching was/is already suspended.\n";
            }
          else
            {
              [self disableLaunching];
              m = @"Launching is now suspended.\n";
            }
        }
      else if (comp(wd, @"tell") >= 0)
	{
	  wd = cmdWord(cmd, 1);
	  if ([wd length] > 0)
	    {
	      NSString	*dest = AUTORELEASE(RETAIN(wd));

	      [cmd removeObjectAtIndex: 0];
	      [cmd removeObjectAtIndex: 0];
	      if (comp(dest, @"all") == 0)
		{
		  unsigned	i;
		  NSArray	*a = [[NSArray alloc] initWithArray: clients];

		  for (i = 0; i < [a count]; i++)
		    {
		      EcClientI*	c = [a objectAtIndex: i];

		      if ([clients indexOfObjectIdenticalTo: c]!=NSNotFound)
			{
			  NS_DURING
			    {
			      NSData	*dat = [NSPropertyListSerialization
				dataFromPropertyList: cmd
				format: NSPropertyListBinaryFormat_v1_0
				errorDescription: 0];
			      [[c obj] cmdMesgData: dat from: f];
			      m = @"Sent message.\n";
			    }
			  NS_HANDLER
			    {
			      NSLog(@"Caught exception: %@", localException);
			    }
			  NS_ENDHANDLER
			}
		    }
		}
	      else
		{
		  NSArray	*a;

		  a = [self findAll: clients byAbbreviation: dest];
		  if ([a count] == 0)
		    {
		      m = [NSString stringWithFormat: 
			@"No such client as '%@' on '%@'\n", dest, host];
		    }
		  else
		    {
		      unsigned	i;

		      m = nil;

		      for (i = 0; i < [a count]; i++)
			{
			  EcClientI	*c = [a objectAtIndex: i];

			  NS_DURING
			    {
			      NSData	*dat = [NSPropertyListSerialization
				dataFromPropertyList: cmd
				format: NSPropertyListBinaryFormat_v1_0
				errorDescription: 0];

			      [[c obj] cmdMesgData: dat from: f];
			      if (m == nil)
				{
				  m = [NSString stringWithFormat:
				    @"Sent message to %@", [c name]];
				}
			      else
				{
				  m = [m stringByAppendingFormat:
				    @", %@", [c name]];
				}
			    }
			  NS_HANDLER
			    {
			      NSLog(@"Caught exception: %@", localException);
			      if (m == nil)
				{
				  m = @"Failed to send message!";
				}
			      else
				{
				  m = [m stringByAppendingFormat:
				    @", failed to send to %@", [c name]];
				}
			    }
			  NS_ENDHANDLER
			}
		      if (m != nil)
			m = [m stringByAppendingString: @"\n"];
		    }
		}
	    }
	  else
	    {
	      m = @"Tell where?.\n";
	    }
	}
      else
	{
	  m = [NSString stringWithFormat: @"Unknown command - '%@'\n", wd];
	}

      [self information: m from: t to: f type: LT_CONSOLE];
    }
  else
    {
      EcClientI	*client = [self findIn: clients byName: t];

      if (client)
	{
	  NS_DURING
	    {
	      NSData	*dat = [NSPropertyListSerialization
		dataFromPropertyList: cmd
		format: NSPropertyListBinaryFormat_v1_0
		errorDescription: 0];
	      [[client obj] cmdMesgData: dat from: f];
	    }
	  NS_HANDLER
	    {
	      NSLog(@"Caught exception: %@", localException);
	    }
	  NS_ENDHANDLER
	}
      else
	{
	  NSString	*m;

	  m = [NSString stringWithFormat:
            @"command to unregistered client '%@'", t];
	  [self information: cmdLogFormat(LT_ERROR, m)
		       from: nil
			 to: f
		       type: LT_ERROR];
	}
    }
}

- (NSData *) configurationFor: (NSString *)name
{
  NSMutableDictionary *dict;
  NSString	*base;
  NSRange	r;
  id		o;
  
  if (nil == config || 0 == [name length])
    {
      return nil;	// Not available
    }

  r = [name rangeOfString: @"-"
		  options: NSBackwardsSearch | NSLiteralSearch];
  if (r.length > 0)
    {
      base = [name substringToIndex: r.location];
    }
  else
    {
      base = nil;
    }

  dict = [NSMutableDictionary dictionaryWithCapacity: 2];
  o = [config objectForKey: @"*"];
  if (o != nil)
    {
      [dict setObject: o forKey: @"*"];
    }

  o = [config objectForKey: name];		// Lookup config
  if (base != nil)
    {
      if (nil == o)
	{
	  /* No instance specific config found for process,
	   * try using the base process name without instance ID.
	   */
	  o = [config objectForKey: base];
	}
      else
	{
	  id	tmp;

	  /* We found instance specific configuration for the process,
	   * so we merge by taking values from generic process config
	   * (if any) and overwriting them with instance specific values.
	   */
	  tmp = [config objectForKey: base];
	  if ([tmp isKindOfClass: [NSDictionary class]]
	    && [o isKindOfClass: [NSDictionary class]])
	    {
	      tmp = [[tmp mutableCopy] autorelease];
	      [tmp addEntriesFromDictionary: o];
	      o = tmp;
	    }
	}
    }
  if (o != nil)
    {
      [dict setObject: o forKey: name];
    }

  o = [config objectForKey: @"Operators"];
  if (o != nil)
    {
      [dict setObject: o forKey: @"Operators"];
    }

  return [NSPropertyListSerialization
    dataFromPropertyList: dict
    format: NSPropertyListBinaryFormat_v1_0
    errorDescription: 0];
}

- (BOOL) connection: (NSConnection*)ancestor
  shouldMakeNewConnection: (NSConnection*)newConn
{
  [[NSNotificationCenter defaultCenter]
    addObserver: self
       selector: @selector(connectionBecameInvalid:)
	   name: NSConnectionDidDieNotification
         object: (id)newConn];
  [newConn setDelegate: self];
  return YES;
}

- (id) connectionBecameInvalid: (NSNotification*)notification
{
  id conn = [notification object];

  [[NSNotificationCenter defaultCenter]
    removeObserver: self
	      name: NSConnectionDidDieNotification
	    object: conn];
  if ([conn isKindOfClass: [NSConnection class]])
    {
      NSMutableArray	*c;
      NSMutableString	*l = [NSMutableString stringWithCapacity: 20];
      NSMutableString	*e = [NSMutableString stringWithCapacity: 20];
      NSMutableString	*m = [NSMutableString stringWithCapacity: 20];
      BOOL		lostClients = NO;
      NSUInteger	i;

      if (control && [(NSDistantObject*)control connectionForProxy] == conn)
	{
	  [[self logFile]
	    puts: @"Lost connection to control server.\n"];
	  DESTROY(control);
	}

      /* Remove any clients using this connection from the active list.
       * Clients which have not been registered (or which have been
       * unregistered) will not be in the list.
       */
      c = AUTORELEASE([clients mutableCopy]);
      i = [c count];
      while (i-- > 0)
	{
	  EcClientI     *o = [c objectAtIndex: i];

	  if ([(id)[o obj] connectionForProxy] == conn)
	    {
              LaunchInfo	*l = [LaunchInfo existing: [o name]];
              BOOL              failedToUnregister = NO;

              /* Unless this is a transient process, it should have
               * unregistered.
               */
              if (NO == [o unregistered] && NO == [o transient])
                {
                  failedToUnregister = YES;
                }
              lostClients = YES;
	      [self unregisterClient: o];
              [l clearClient: o cleanly: failedToUnregister ? NO : YES];
	    }
	}
      [c removeAllObjects];

      if ([l length] > 0)
	{
	  [[self logFile] puts: l];
	}
      if ([m length] > 0)
	{
	  [self information: m from: nil to: nil type: LT_ALERT];
	}
      if ([e length] > 0)
	{
	  [self information: e from: nil to: nil type: LT_ERROR];
	}
      if (lostClients)
	{
	  [self update];
	}
    }
  else
    {
      [self error: "non-Connection sent invalidation"];
    }
  return self;
}

- (BOOL) contactControl
{
  if (nil == control)
    {
      NSUserDefaults	*defs;
      NSString		*ctlName;
      NSString		*ctlHost;
      id		c;

      defs = [self cmdDefaults];
      ctlName = [defs stringForKey: @"ControlName"];
      if (ctlName == nil)
        {
          ctlName = @"Control";
        }
      if (nil != (ctlHost = [NSHost controlWellKnownName]))
        {
          /* Map to operating system host name.
           */
          ctlHost = [[NSHost hostWithWellKnownName: ctlHost] name];
        }
      if (nil == ctlHost)
        {
          ctlHost = @"*";
        }

      NS_DURING
        {
          NSLog(@"Connecting to %@ on %@", ctlName, ctlHost);
          control = (id<Control>)[NSConnection
              rootProxyForConnectionWithRegisteredName: ctlName
                                                  host: ctlHost
           usingNameServer: [NSSocketPortNameServer sharedInstance] ];
        }
      NS_HANDLER
        {
          NSLog(@"Connecting to control server: %@", localException);
          control = nil;
        }
      NS_ENDHANDLER
      c = control;
      if (RETAIN(c) != nil)
        {
          /* Re-initialise control server ping */
          DESTROY(outstanding);
          fwdSequence = 0;
          revSequence = 0;

          [(NSDistantObject*)c setProtocolForProxy: @protocol(Control)];
          c = [(NSDistantObject*)c connectionForProxy];
          [c setDelegate: self];
          [[NSNotificationCenter defaultCenter]
            addObserver: self
               selector: @selector(connectionBecameInvalid:)
                   name: NSConnectionDidDieNotification
                 object: c];
          NS_DURING
            {
              NSData		*dat;

              dat = [control registerCommand: self
                                        name: host];
              if (nil == dat)
                {
                  // Control server not yet ready.
                  DESTROY(control);
                }
              else
                {
                  NSMutableDictionary	*conf;

                  conf = [NSPropertyListSerialization
                    propertyListWithData: dat
                    options: NSPropertyListMutableContainers
                    format: 0
                    error: 0];
                  if ([conf objectForKey: @"rejected"] == nil)
                    {
                      [self updateConfig: dat];
                    }
                  else
                    {
                      NSLog(@"Registering %@ with Control server: %@",
                        host, [conf objectForKey: @"rejected"]);
                      DESTROY(control);
                    }
                }
            }
          NS_HANDLER
            {
              NSLog(@"Registering %@ with Control server: %@",
                host, localException);
              DESTROY(control);
            }
          NS_ENDHANDLER
          if (control != nil)
            {
              [self update];
            }
        }
    }
  return (nil == control) ? NO : YES;
}

- (void) dealloc
{
  [self cmdLogEnd: logname];
  if (timer != nil)
    {
      [timer invalidate];
    }
  DESTROY(control);
  RELEASE(host);
  RELEASE(clients);
  RELEASE(launchInfo);
  RELEASE(environment);
  RELEASE(outstanding);
  [super dealloc];
}

- (NSString*) description
{
  NSMutableString	*m;

  m = [NSMutableString stringWithFormat: @"%@ running since %@\n",
    [super description], [self ecStarted]];
  if (NO == launchEnabled)
    {
      [m appendString: @"  Launching is currently suspended.\n"];
    }
  [m appendFormat: @"  %@\n", [LaunchInfo description]];
  [m appendFormat: @"  Compress/Delete after %d/%d days.\n",
    (int)compressAfter, (int)deleteAfter];
  return m;
}

- (NSDictionary*) environment
{
  return environment;
}

- (NSArray*) findAll: (NSArray*)a
      byAbbreviation: (NSString*)s
{
  NSMutableArray	*r = [NSMutableArray arrayWithCapacity: 4];
  int			i;

  /*
   *	Special case - a numeric value is used as an index into the array.
   */
  if (isdigit(*[s cString]))
    {
      i = [s intValue];
      if (i >= 0 && i < (int)[a count])
	{
	  [r addObject: [a objectAtIndex: i]];
	}
    }
  else
    {
      EcClientI	*o;

      for (i = 0; i < (int)[a count]; i++)
	{
	  o = (EcClientI*)[a objectAtIndex: i];
	  if (comp(s, [o name]) == 0 || comp_len == (int)[s length])
	    {
	      [r addObject: o];
	    }
	}
    }
  return r;
}

- (EcClientI*) findIn: (NSArray*)a
       byAbbreviation: (NSString*)s
{
  EcClientI	*o;
  int		i;
  int		best_pos = -1;
  int		best_len = 0;

  /*
   *	Special case - a numeric value is used as an index into the array.
   */
  if (isdigit(*[s cString]))
    {
      i = [s intValue];
      if (i >= 0 && i < (int)[a count])
	{
	  return (EcClientI*)[a objectAtIndex: i];
	}
    }

  for (i = 0; i < (int)[a count]; i++)
    {
      o = (EcClientI*)[a objectAtIndex: i];
      if (comp(s, [o name]) == 0)
	{
	  return o;
	}
      if (comp_len > best_len)
	{
	  best_len = comp_len;
	  best_pos = i;
	}
    }
  if (best_pos >= 0)
    {
      return (EcClientI*)[a objectAtIndex: best_pos];
    }
  return nil;
}

- (EcClientI*) findIn: (NSArray*)a
		byName: (NSString*)s
{
  EcClientI	*o;
  int		i;

  for (i = 0; i < (int)[a count]; i++)
    {
      o = (EcClientI*)[a objectAtIndex: i];

      if (comp([o name], s) == 0)
	{
	  return o;
	}
    }
  return nil;
}

- (EcClientI*) findIn: (NSArray*)a
             byObject: (id)s
{
  EcClientI	*o;
  int		i;

  for (i = 0; i < (int)[a count]; i++)
    {
      o = (EcClientI*)[a objectAtIndex: i];

      if ([o obj] == s)
	{
	  return o;
	}
    }
  return nil;
}

- (void) flush
{
  /*
   * Flush logs to disk ... dummy method as we don't cache them at present.
   */
}

- (NSString*) host
{
  return host;
}

- (void) information: (NSString*)inf
		from: (NSString*)s
		type: (EcLogType)t
{
  [self information: inf from: s to: nil type: t];
}

- (void) information: (NSString*)inf
		from: (NSString*)s
		  to: (NSString*)d
		type: (EcLogType)t
{
  if (t != LT_DEBUG && inf != nil && [inf length] > 0)
    {
      if (NO == [self contactControl])
	{
	  NSLog(@"Information (from:%@ to:%@ type:%d) with no Control -\n%@",
	    s, d, t, inf);
	}
      else
	{
	  NS_DURING
	    {
	      [control information: inf type: t to: d from: s];
	    }
	  NS_HANDLER
	    {
	      NSLog(@"Sending %@ from %@ to %@ type %x exception: %@",
		inf, s, d, t, localException);
	    }
	  NS_ENDHANDLER
	}
    }
}

- (id) initWithDefaults: (NSDictionary*)defs
{
  ecSetLogsSubdirectory(@"Logs");
  if (nil != (self = [super initWithDefaults: defs]))
    {
      [LaunchInfo class];
      debUncompressed = 0.0;
      debUndeleted = 0.0;
      logUncompressed = 0.0;
      logUndeleted = 0.0;
      nodesFree = 0.1;
      spaceFree = 0.1;

      logname = [[self cmdName] stringByAppendingPathExtension: @"log"];
      RETAIN(logname);
      if ([self logFile] == nil)
	{
	  exit(0);
	}
      host = RETAIN([[NSHost currentHost] wellKnownName]);
      clients = [[NSMutableArray alloc] initWithCapacity: 10];
    }
  return self;
}

- (void) killAll
{
#ifndef __MINGW__
  NSEnumerator		*e;
  EcClientI             *c;
  LaunchInfo		*l;

  /* Kill any known clients which are *not* configured with launch info
   * This could be transient or manually launched processes.
   */
  e = [[self unconfiguredClients] objectEnumerator];
  while (nil != (c = [e nextObject]))
    {
      int       p = [c processIdentifier];

      if (p > 0)
        {
          kill(p, SIGKILL);
        }
    }

  /* Now mark all configured clients to be shut down (so we won't restart any)
   * and kill any running processes we know about.
   */
  e = [launchInfo objectEnumerator];
  while (nil != (l = [e nextObject]))
    {
      int       p = [l processIdentifier];

      [l setDesired: Dead reason: @"killed shutdown/remote"];
      if (p > 0)
        {
          kill(p, SIGKILL);
        }
    }
#endif
}

- (BOOL) launch: (NSString*)name
{
  LaunchInfo	*l = [LaunchInfo existing: name];

  if (nil == l)
    {
      NSString  *m;

      m = [NSString stringWithFormat: cmdLogFormat(LT_CONSOLE,
        @"unrecognized name to launch %@"), name];
      [self information: m from: nil to: nil type: LT_CONSOLE];
      return NO;
    }
  else
    {
      [l setDesired: Live reason: @"remote API request"];
    }
  return YES;
}

- (void) logChange: (NSString*)change for: (NSString*)name
{
  NSString      *s;

  NSLog(@"%@ process with name '%@' on %@", change, name, host);
  s = [NSString stringWithFormat: @"%@ %@ process with name '%@' on %@\n",
    [NSDate date], change, name, host];
  [[self logFile] puts: s];
  [self information: s from: nil to: nil type: LT_CONSOLE];
  [self update];
}

- (NSFileHandle*) logFile
{
  return [self cmdLogFile: logname];
}

- (void) logMessage: (NSString*)msg
	       type: (EcLogType)t
		for: (id<CmdClient>)o
{
  EcClientI	*r = [self findIn: clients byObject: o];
  NSString	*c;

  if (r == nil)
    {
      c = @"unregistered client";
    }
  else
    {
      c = [r name];
    }
  [self logMessage: msg
	      type: t
	      name: c];
}

- (void) logMessage: (NSString*)msg
	       type: (EcLogType)t
	       name: (NSString*)c
{
  NSString		*m;
  
  switch (t)
    {
      case LT_DEBUG: 
	  m = msg;
	  break;

      case LT_WARNING: 
	  m = msg;
	  break;

      case LT_ERROR: 
	  m = msg;
	  break;

      case LT_AUDIT: 
	  m = msg;
	  break;

      case LT_ALERT: 
	  m = msg;
	  break;

      case LT_CONSOLE: 
	  m = msg;
	  break;

      default: 
	  m = [NSString stringWithFormat: @"%@: Message of unknown type - %@",
		      c, msg];
	  break;
    }

  [[self logFile] puts: m];
  [self information: m from: c to: nil type: t];
}

- (void) quitAll
{
  [self quitAll: nil];
}

- (void) quitAll: (NSDate*)by
{
  NSEnumerator  *e;
  LaunchInfo    *l;
  EcClientI	*c;

  if (nil == by)
    {
      by = [NSDate dateWithTimeIntervalSinceNow: 35.0];
    }
  ASSIGN(terminateBy, by);

  e = [launchInfo objectEnumerator];
  while (nil != (l = [e nextObject]))
    {
      [l setDesired: Dead reason: @"quit all instruction"];
    }

  e = [[self unconfiguredClients] objectEnumerator];
  while (nil != (c = [e nextObject]))
    {
      NS_DURING
        {
          [[c obj] cmdQuit: 0];
        }
      NS_HANDLER
        {
          NSLog(@"Caught exception: %@", localException);
        }
      NS_ENDHANDLER
    }
/*
  while ([clients count] > 0 && [terminateBy timeIntervalSinceNow] > 0.0)
    {
      ENTER_POOL
      NSDate	*next = [NSDate dateWithTimeIntervalSinceNow: 0.1];
      [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
                               beforeDate: next];
      LEAVE_POOL
    }
*/
}

/*
 * Handle a request for re-config from a client.
 */
- (void) requestConfigFor: (id<CmdConfig>)c
{
  EcClientI	*info = [self findIn: clients byObject: (id<CmdClient>)c];
  NSData	*conf = [info config];

  if (nil != conf)
    {
      NS_DURING
	{
	  [[info obj] updateConfig: conf];
	}
      NS_HANDLER
	{
	  NSLog(@"Sending config to client: %@", localException);
	}
      NS_ENDHANDLER
    }
}

- (NSData*) registerClient: (id)c
                identifier: (int)p
		      name: (NSString*)n
		 transient: (BOOL)t
{
  LaunchInfo	        *l = [LaunchInfo existing: n];
  NSMutableDictionary	*dict;
  EcClientI		*obj;
  EcClientI		*old;

  [(NSDistantObject*)c setProtocolForProxy: @protocol(CmdClient)];

  if (nil == config)
    {
      [self logChange: @"back-off" for: n];
      dict = [NSMutableDictionary dictionaryWithCapacity: 1];
      [dict setObject: @"configuration data not yet available."
	       forKey: @"back-off"];
      return [NSPropertyListSerialization
	dataFromPropertyList: dict
	format: NSPropertyListBinaryFormat_v1_0
	errorDescription: 0];
    }

  /* Do we already have this registered?
   */
  if ([l processIdentifier] == p && (obj = [l client]) != nil)
    {
      [self logChange: @"re-registered" for: [l name]];
      if ([l stable] == YES)
        {
          [self clearAll: [l name] addText: @"process re-registered"];
        }
      return [obj config];
    }

  /*
   *	Create a new reference for this client.
   */
  obj = [[EcClientI alloc] initFor: c name: n with: self];

  if ((old = [self findIn: clients byName: n]) == nil)
    {
      NSData		*d;

      [clients addObject: obj];
      RELEASE(obj);
      [clients sortUsingSelector: @selector(compare:)];

      [obj setProcessIdentifier: p];

      if (nil == l)
	{
	  l = [LaunchInfo launchInfo: n];
	}
      if (t == YES)
	{
	  [obj setTransient: YES];
	}
      else
	{
	  [obj setTransient: NO];
	}
      [l setClient: obj];
      [self logChange: @"registered" for: [l name]];
      d = [self configurationFor: n];
      if (nil != d)
	{
	  [obj setConfig: d];
	}
      return [obj config];
    }
  else
    {
      /* Rejecting means the client is not registered (and therefore should
       * not be told to quit when the objct is deallocated.
       */
      [obj setUnregistered: YES];
      RELEASE(obj);
      [self logChange: @"rejected" for: n];
      dict = [NSMutableDictionary dictionaryWithCapacity: 1];
      [dict setObject: @"client with that name already registered."
	       forKey: @"rejected"];
      return [NSPropertyListSerialization
	dataFromPropertyList: dict
	format: NSPropertyListBinaryFormat_v1_0
	errorDescription: 0];
    }
  [self update];
}

- (void) reply: (NSString*) msg to: (NSString*)n from: (NSString*)c
{
  if ([self contactControl])
    {
      NS_DURING
	{
	  [control reply: msg to: n from: c];
	}
      NS_HANDLER
	{
	  NSLog(@"reply: %@ to: %@ from: %@ - %@", msg, n, c, localException);
	}
      NS_ENDHANDLER
    }
  else
    {
    }
}

- (NSString*) makeSpace
{
  NSInteger             purgeAfter;
  NSTimeInterval        latestDeleteAt;
  NSTimeInterval        now;
  NSTimeInterval        ti;
  NSFileManager         *mgr;
  NSCalendarDate        *when;
  NSString		*logs;
  NSString		*file;
  NSString              *gone;
  NSAutoreleasePool	*arp;

  gone = nil;
  arp = [NSAutoreleasePool new];
  when = [NSCalendarDate date];
  now = [when timeIntervalSinceReferenceDate];

  logs = [[self ecUserDirectory] stringByAppendingPathComponent: @"DebugLogs"];

  /* When trying to make space, we can delete up to the point when we
   * would start compressing but no further ... we don't want to delete
   * all logs!
   */
  purgeAfter = [[self cmdDefaults] integerForKey: @"CompressLogsAfter"];
  if (purgeAfter < 1)
    {
      purgeAfter = 7;
    }

  mgr = [NSFileManager defaultManager];

  if (0.0 == debUndeleted)
    {
      debUndeleted = now - 365.0 * day;
    }
  ti = debUndeleted;
  latestDeleteAt = now - day * purgeAfter;
  while (nil == gone && ti < latestDeleteAt)
    {
      when = date(ti);
      file = [[logs stringByAppendingPathComponent:
        [when descriptionWithCalendarFormat: @"%Y-%m-%d"]]
        stringByStandardizingPath];
      if ([mgr fileExistsAtPath: file])
        {
          [mgr removeFileAtPath: file handler: nil];
          gone = [when descriptionWithCalendarFormat: @"%Y-%m-%d"];
        }
      ti += day;
    }
  debUndeleted = ti;
  RETAIN(gone);
  DESTROY(arp);
  return AUTORELEASE(gone);
}

- (void) _sweep: (BOOL)deb at: (NSCalendarDate*)when
{
  NSTimeInterval        uncompressed;
  NSTimeInterval        undeleted;
  NSTimeInterval        latestCompressAt;
  NSTimeInterval        latestDeleteAt;
  NSTimeInterval        now;
  NSTimeInterval        ti;
  NSFileManager         *mgr;
  NSString		*dir;
  NSString		*file;
  NSAutoreleasePool	*arp;

  arp = [NSAutoreleasePool new];
  now = [when timeIntervalSinceReferenceDate];

  /* get number of days after which to do log compression/deletion.
   */
  compressAfter = [[self cmdDefaults] integerForKey: @"CompressLogsAfter"];
  if (compressAfter < 1)
    {
      compressAfter = 7;
    }
  deleteAfter = [[self cmdDefaults] integerForKey: @"DeleteLogsAfter"];
  if (deleteAfter < 1)
    {
      deleteAfter = 180;
    }
  if (deleteAfter < compressAfter)
    {
      deleteAfter = compressAfter;
    }

  mgr = [[NSFileManager new] autorelease];

  dir = [self ecUserDirectory];
  if (YES == deb)
    {
      dir = [dir stringByAppendingPathComponent: @"DebugLogs"];
      uncompressed = debUncompressed;
      undeleted = debUndeleted;
    }
  else
    {
      dir = [dir stringByAppendingPathComponent: @"Logs"];
      uncompressed = logUncompressed;
      undeleted = logUndeleted;
    }
  if (0.0 == undeleted)
    {
      undeleted = now - 365.0 * day;
    }
  ti = undeleted;
  latestDeleteAt = now - day * deleteAfter;
  while (ti < latestDeleteAt)
    {
      NSAutoreleasePool *pool = [NSAutoreleasePool new];

      when = date(ti);
      file = [[dir stringByAppendingPathComponent:
        [when descriptionWithCalendarFormat: @"%Y-%m-%d"]]
        stringByStandardizingPath];
      if ([mgr fileExistsAtPath: file])
        {
          [mgr removeFileAtPath: file handler: nil];
        }
      ti += day;
      [pool release];
    }
  if (YES == deb) debUndeleted = ti;
  else logUndeleted = ti;

  if (uncompressed < undeleted)
    {
      uncompressed = undeleted;
    }
  ti = uncompressed;
  latestCompressAt = now - day * compressAfter;
  while (ti < latestCompressAt)
    {
      NSAutoreleasePool         *pool = [NSAutoreleasePool new];
      NSDirectoryEnumerator	*enumerator;
      BOOL	                isDirectory;
      NSString                  *base;

      when = date(ti);
      base = [[dir stringByAppendingPathComponent:
        [when descriptionWithCalendarFormat: @"%Y-%m-%d"]]
        stringByStandardizingPath];
      if ([mgr fileExistsAtPath: base isDirectory: &isDirectory] == NO
        || NO == isDirectory)
        {
          ti += day;
          [pool release];
          continue;     // No log directory for this date.
        }

      enumerator = [mgr enumeratorAtPath: base];
      while ((file = [enumerator nextObject]) != nil)
        {
          NSString	        *src;
          NSString	        *dst;
          NSFileHandle          *sh;
          NSFileHandle          *dh;
          NSDictionary          *a;
          NSData                *d;

          if (YES == [[file pathExtension] isEqualToString: @"gz"])
            {
              continue; // Already compressed
            }
          a = [enumerator fileAttributes];
          if (NSFileTypeRegular != [a fileType])
            {
              continue;	// Not a regular file ... can't compress
            }

          src = [base stringByAppendingPathComponent: file];

          if ([a fileSize] == 0)
            {
              [mgr removeFileAtPath: src handler: nil];
              continue; // Nothing to compress
            }
          if ([a fileSize] >= [[[mgr fileSystemAttributesAtPath: src]
            objectForKey: NSFileSystemFreeSize] integerValue])
            {
              [mgr removeFileAtPath: src handler: nil];
              EcExceptionMajor(nil,
		@"Unable to compress %@ (too big; deleted)", src);
              continue; // Not enough space free to compress
            }

          dst = [src stringByAppendingPathExtension: @"gz"];
          if ([mgr fileExistsAtPath: dst isDirectory: &isDirectory] == YES)
            {
              [mgr removeFileAtPath: dst handler: nil];
            }

          [mgr createFileAtPath: dst contents: nil attributes: nil];
          dh = [NSFileHandle fileHandleForWritingAtPath: dst];
          if (NO == [dh useCompression])
            {
              [dh closeFile];
              [mgr removeFileAtPath: dst handler: nil];
              EcExceptionMajor(nil,
		@"Unable to compress %@ to %@", src, dst);
              continue;
            }

          sh = nil;
          NS_DURING
            {
              NSAutoreleasePool *inner;

              sh = [NSFileHandle fileHandleForReadingAtPath: src];
              inner = [NSAutoreleasePool new];
              while ([(d = [sh readDataOfLength: 1000000]) length] > 0)
                {
                  [dh writeData: d];
                  [inner release];
                  inner = [NSAutoreleasePool new];
                }
              [inner release];
              [sh closeFile];
              [dh closeFile];
              [mgr removeFileAtPath: src handler: nil];
            }
          NS_HANDLER
            {
              [mgr removeFileAtPath: dst handler: nil];
              [sh closeFile];
              [dh closeFile];
            }
          NS_ENDHANDLER
        }
      ti += day;
      [pool release];
    }
  if (YES == deb) debUncompressed = ti;
  else logUncompressed = ti;

  DESTROY(arp);
}

/* Perform this one in another thread.
 * The sweep operation may compress really large logfiles and could be
 * very slow, so it's performed in a separate thread to avoid blocking
 * normal operations.
 */
- (void) sweep: (NSCalendarDate*)when
{
  if (nil == when)
    {
      when = [NSCalendarDate date];
    }
  [self _sweep: YES at: when];
  [self _sweep: NO at: when];
  sweeping = NO;
}

- (void) ecNewHour: (NSCalendarDate*)when
{
  if (sweeping == YES)
    {
      NSLog(@"Argh - nested hourly sweep attempt");
      return;
    }
  sweeping = YES;
  [NSThread detachNewThreadSelector: @selector(sweep:)
                           toTarget: self
                         withObject: when];
}


/*
 * Tell all our clients to quit, and wait for them to do so.
 * If called while already terminating ... force immediate shutdown.
 */
- (void) _terminate: (NSTimer*)t
{
  NSTimeInterval	ti = [terminateBy timeIntervalSinceNow];

  if ([clients count] == 0 && [LaunchInfo launching] == 0)
    {
      [self information: @"Final shutdown."
		   from: nil
		     to: nil
		   type: LT_CONSOLE];
      [terminating invalidate];
      terminating = nil;
      [self cmdQuit: tStatus];
    }
  else if (ti <= 0.0)
    {
      [[self logFile] puts: @"Final shutdown.\n"];
      [terminating invalidate];
      terminating = nil;
      [self killAll];
      [self cmdQuit: tStatus];
    }
  else
    {
      [self quitAll: terminateBy];
      terminating = [NSTimer scheduledTimerWithTimeInterval: ti + 1.0
						     target: self
						   selector: _cmd
						   userInfo: nil
						    repeats: NO];
    }
}

- (void) terminate: (NSDate*)by
{
  NSTimeInterval	ti = 30.0;

  if (nil != terminateBy)
    {
      NSString	*msg;

      msg = [NSString stringWithFormat: @"Terminate requested,"
	@" but already terminating by %@", terminateBy];
      [self information: msg
		   from: nil
		     to: nil
		   type: LT_CONSOLE];
      return;
    }
  if (nil != by)
    {
      ti = [by timeIntervalSinceNow];
      if (ti < 0.5)
	{
	  ti = 0.5;
	  by = nil;
	}
      else if (ti > 900.0)
	{
	  ti = 900.0;
	  by = nil;
	}
    }
  if (nil == by)
    {
      by = [NSDate dateWithTimeIntervalSinceNow: ti];
    }
  ASSIGN(terminateBy, by);
  [self information: @"Terminate initiated.\n"
               from: nil
                 to: nil
               type: LT_CONSOLE];
  terminating = [NSTimer scheduledTimerWithTimeInterval: 0.01
						 target: self
					       selector: @selector(_terminate:)
					       userInfo: nil
						repeats: NO];
}

- (void) terminate
{
  [self terminate: nil];
}

- (void) housekeeping: (NSTimer*)t
{
  static BOOL	inTimeout = NO;
  NSDate	*now = [t fireDate];

  if (t == timer)
    {
      timer = nil;
    }
  if (now == nil)
    {
      now = [NSDate date];
    }

  [[self logFile] synchronizeFile];
  if (inTimeout == NO)
    {
      static unsigned	pingControlCount = 0;
      NSFileManager	*mgr;
      NSDictionary	*d;
      NSMutableArray    *a;
      NSString          *s;
      float		f;
      unsigned		count;
      BOOL		lost = NO;

      inTimeout = YES;
      [self contactControl];

      a = AUTORELEASE([clients mutableCopy]);
      count = [a count];
      while (count-- > 0)
	{
	  EcClientI	*r = [a objectAtIndex: count];
	  LaunchInfo    *l = [LaunchInfo existing: [r name]];
	  NSDate	*d = [r outstanding];
	  
	  if ([clients indexOfObjectIdenticalTo: r] == NSNotFound)
	    {
	      continue;
	    }
	  if (d != nil && [d timeIntervalSinceDate: now] < -pingDelay)
	    {
	      if (nil == l || NO == [l isHung])
		{
		  NSString	*m;

		  [l setHung];
		  m = [NSString stringWithFormat:
		    @"failed to respond for over %d seconds", (int)pingDelay];
		  [self alarmCode: ACProcessHung
			 procName: [r name]
			  addText: m];
		  m = [NSString stringWithFormat: cmdLogFormat(LT_CONSOLE,
		    @"Client '%@' failed to respond for over %d seconds"),
		    [r name], (int)pingDelay];
		  [self information: m from: nil to: nil type: LT_CONSOLE];
		}
	    }
	}
      [a removeAllObjects];

      if (control != nil && outstanding != nil
	&& [outstanding timeIntervalSinceDate: now] < -pingDelay)
	{
	  NSString	*m;

	  m = [NSString stringWithFormat: cmdLogFormat(LT_CONSOLE,
	    @"Control server failed to respond for over %d seconds"),
	    (int)pingDelay];
	  [[(NSDistantObject*)control connectionForProxy] invalidate];
	  [self information: m from: nil to: nil type: LT_CONSOLE];
	  lost = YES;
	}
      if (lost == YES)
	{
	  [self update];
	}
      /* We ping each client in turn.
       */
      a = AUTORELEASE([clients mutableCopy]);
      count = [a count];
      while (count-- > 0)
	{
	  EcClientI	*r = [a objectAtIndex: count];

          if ([clients indexOfObjectIdenticalTo: r] != NSNotFound)
            {
              [r ping];
            }
	}
      // Ping the control server too - once every four times.
      pingControlCount++;
      if (pingControlCount >= 4)
	{
	  pingControlCount = 0;
	}
      if (pingControlCount == 0)
	{
	  [self pingControl];
	}

      /* See if the filesystem containing our logging directory has enough
       * space.
       */
      mgr = [NSFileManager defaultManager];

      s = [[self ecUserDirectory] stringByAppendingPathComponent: @"DebugLogs"];
      d = [mgr fileSystemAttributesAtPath: s];
      f = [[d objectForKey: NSFileSystemFreeSize] floatValue] 
        / [[d objectForKey: NSFileSystemSize] floatValue];
      if (f <= spaceFree)
	{
	  static NSDate	*last = nil;

	  if (nil == last || [last timeIntervalSinceNow] < -DLY)
	    {
	      NSString	*m;

	      m = [self makeSpace];
	      ASSIGN(last, [NSDate date]);
              if ([m length] == 0)
                {
                  m = [NSString stringWithFormat: cmdLogFormat(LT_ALERT,
                    @"Debug disk debug space at %02.1f percent"), f * 100.0];
                }
              else
                {
                  m = [NSString stringWithFormat: cmdLogFormat(LT_ALERT,
                    @"Debug disk space at %02.1f percent"
                    @" - deleted debug logs from %@ to make space"),
                    f * 100.0, m];
                }
	      [self information: m from: nil to: nil type: LT_ALERT];
	    }
	}
      f = [[d objectForKey: NSFileSystemFreeNodes] floatValue] 
        / [[d objectForKey: NSFileSystemNodes] floatValue];
      if (f <= nodesFree)
	{
	  static NSDate	*last = nil;

	  if (nil == last || [last timeIntervalSinceNow] < -DLY)
	    {
	      NSString	*m;

	      m = [self makeSpace];
	      ASSIGN(last, [NSDate date]);
              if ([m length] == 0)
                {
                  m = [NSString stringWithFormat: cmdLogFormat(LT_ALERT,
                    @"Debug disk nodes at %02.1f percent"), f * 100.0];
                }
              else
                {
                  m = [NSString stringWithFormat: cmdLogFormat(LT_ALERT,
                    @"Debug disk nodes at %02.1f percent"
                    @" - deleted debug logs from %@ to make space"),
                    f * 100.0, m];
                }
	      [self information: m from: nil to: nil type: LT_ALERT];
	    }
	}

      s = [[self ecUserDirectory] stringByAppendingPathComponent: @"Logs"];
      d = [mgr fileSystemAttributesAtPath: s];
      f = [[d objectForKey: NSFileSystemFreeSize] floatValue] 
        / [[d objectForKey: NSFileSystemSize] floatValue];
      if (f <= spaceFree)
	{
	  static NSDate	*last = nil;

	  if (nil == last || [last timeIntervalSinceNow] < -DLY)
	    {
	      NSString	*m;

	      ASSIGN(last, [NSDate date]);
              m = [NSString stringWithFormat: cmdLogFormat(LT_ALERT,
                @"Disk space at %02.1f percent"), f * 100.0];
	      [self information: m from: nil to: nil type: LT_ALERT];
	    }
        }
      f = [[d objectForKey: NSFileSystemFreeNodes] floatValue] 
        / [[d objectForKey: NSFileSystemNodes] floatValue];
      if (f <= nodesFree)
	{
	  static NSDate	*last = nil;

	  if (nil == last || [last timeIntervalSinceNow] < -DLY)
	    {
	      NSString	*m;

	      ASSIGN(last, [NSDate date]);
              m = [NSString stringWithFormat: cmdLogFormat(LT_ALERT,
                @"Disk nodes at %02.1f percent"), f * 100.0];
	      [self information: m from: nil to: nil type: LT_ALERT];
	    }
	}
    }
  inTimeout = NO;
}

- (void) _housekeeping: (NSTimer*)t
{
  NS_DURING
    [self housekeeping: t];
  NS_HANDLER
    NSLog(@"Problem in timeout: %@", localException);
  NS_ENDHANDLER

  if (NO == [timer isValid] && NO == [self ecIsQuitting])
    {
      timer = [NSTimer scheduledTimerWithTimeInterval: 5.0
					       target: self
					     selector: @selector(_housekeeping:)
					     userInfo: nil
					      repeats: NO];
    }
}


- (NSMutableArray*) unconfiguredClients
{
  NSUInteger	        i = [clients count];
  NSMutableArray        *a = nil;

  while (i-- > 0)
    {
      EcClientI	        *c = [clients objectAtIndex: i];
      LaunchInfo        *l = [LaunchInfo existing: [c name]];

      if (nil == l)
        {
          if (nil == a)
            {
              a = [NSMutableArray new];
            }
          [a addObject: c];
        }
    }
  return a;
}

- (void) unregisterClient: (EcClientI*)o
{
  NSString      *name = AUTORELEASE(RETAIN([o name]));
  NSUInteger	i;

  [o setUnregistered: YES];
  i = [clients indexOfObjectIdenticalTo: o];
  if (i != NSNotFound)
    {
      [clients removeObjectAtIndex: i];
    }
  [self logChange: @"unregistered" for: name];
}

- (void) unregisterByObject: (id)obj
{
  EcClientI	*o = [self findIn: clients byObject: obj];

  if (o != nil)
    {
      LaunchInfo	*l = [launchInfo objectForKey: [o name]];

      [l clearClient: o cleanly: YES];
      [self unregisterClient: o];
      [l progress];
    }
  [self update];
}

- (void) update
{
  if (control)
    {
      NS_DURING
	{
	  NSMutableArray	*a;
	  int			i;

	  a = [NSMutableArray arrayWithCapacity: [clients count]];
	  for (i = 0; i < (int)[clients count]; i++)
	    {
	      EcClientI	*c;

	      c = [clients objectAtIndex: i];
	      [a addObject: [c name]];
	    }
	  [control servers: [NSPropertyListSerialization
	    dataFromPropertyList: a
	    format: NSPropertyListBinaryFormat_v1_0
	    errorDescription: 0] on: self];
	}
      NS_HANDLER
	{
	  NSLog(@"Exception sending names to Control: %@", localException);
	}
      NS_ENDHANDLER
    }
  if (terminating != nil && [clients count] == 0)
    {
      [self information: @"Final shutdown."
		   from: nil
		     to: nil
		   type: LT_CONSOLE];
      [terminating invalidate];
      terminating = nil;
      [self cmdQuit: tStatus];
    }
}

- (void) updateConfig: (NSData*)data
{
  NSMutableDictionary	*info;
  NSMutableDictionary	*dict;
  NSMutableDictionary	*newConfig;
  NSDictionary		*operators;
  NSEnumerator		*enumerator;
  NSString		*key;

  /* Ignore invalid/empty configuration
   */
  if (nil == data)
    {
      return;
    }
  info = [NSPropertyListSerialization
    propertyListWithData: data
    options: NSPropertyListMutableContainers
    format: 0
    error: 0];
  if (NO == [info isKindOfClass: [NSMutableDictionary class]]
    || 0 == [info count])
    {
      return;
    }

  newConfig = [NSMutableDictionary dictionaryWithCapacity: 32];
  /*
   *	Put all values for this host in the config dictionary.
   */
  dict = [info objectForKey: host];
  if (dict)
    {
      [newConfig addEntriesFromDictionary: dict];
    }
  /*
   *	Add any default values to the config dictionary where we don't have
   *	host specific values.
   */
  dict = [info objectForKey: @"*"];
  if (dict)
    {
      enumerator = [dict keyEnumerator];
      while ((key = [enumerator nextObject]) != nil)
	{
	  NSMutableDictionary	*partial = [newConfig objectForKey: key];
	  NSMutableDictionary	*general = [dict objectForKey: key];
	  NSString		*app = key;

	  if (partial == nil)
	    {
	      /*
	       *	No host-specific info for this application -
	       *	Use the general stuff for the application.
	       */
	      [newConfig setObject: general forKey: key];
	    }
	  else
	    {
	      NSEnumerator	*another = [general keyEnumerator];

	      /*
	       *	Merge in any values for this application which
	       *	exist in the general stuff, but not in the host
	       *	specific area.
	       */
	      while ((key = [another nextObject]) != nil)
		{
		  if ([partial objectForKey: key] == nil)
		    {
		      id	obj = [general objectForKey: key];

		      [partial setObject: obj forKey: key];
		    }
		  else
		    {
		      [[self logFile]
			printf: @"General config for %@/%@ overridden by"
			@" host-specific version\n", app, key];
		    }
		}
	    }
	}
    }

  /*
   * Add the list of operators to the config.
   */
  operators = [info objectForKey: @"Operators"];
  if (operators != nil)
    {
      [newConfig setObject: operators forKey: @"Operators"];
    }

  /* Finally, replace old config with new if they differ.
   */
  [self newConfig: newConfig];
}

- (void) woken: (id)obj
{
  EcClientI     *o = [self findIn: clients byObject: obj];

  if (o != nil)
    {
      LaunchInfo        *l = [launchInfo objectForKey: [o name]];

      [l awakened];
    }
}

@end

