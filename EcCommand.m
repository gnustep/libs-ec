
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
static BOOL                     launchSuspended = NO;
static NSMutableDictionary	*launchInfo = nil;
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
  NSString		*name;	// The name of this process
  NSDictionary		*conf;	// The configuration from Control.plist
  NSTask		*task;	// The current task (if launched by us)
  EcClientI		*client;	// The connected client (or nil)
  BOOL                  clientLost;
  BOOL                  clientQuit;
  int			identifier;     // The current process ID or zero
  NSDate		*when;	// The timestamp we want to launch/stop at/by
  NSTimeInterval	fib0;	// fibonacci sequence for delays
  NSTimeInterval	fib1;	// fibonacci sequence for delays
  Desired		desired;	// If process *should* be live/dead
  NSTimer		*starting;	// The process is starting up
  NSTimeInterval	startingTime;
  BOOL			startingAlarm;
  NSTimer		*stopping;	// The process is shutting down
  NSTimeInterval	stoppingTime;
  BOOL			stoppingAlarm;
  NSTimeInterval        terminationTime;        // Time of process termination
  unsigned              terminationCount;       // Terminations during startup
  int                   terminationStatus;      // Last exit status
  BOOL			stable;	                // Has been running for a while
  NSString              *restartReason;         // Reason for restart or nil
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
- (BOOL) checkActive;
- (BOOL) checkAlive;
- (void) clearClient: (EcClientI*)c unregistered: (BOOL)didQuit;
- (EcClientI*) client;
- (NSDictionary*) configuration;
- (NSTimeInterval) delay;
- (Desired) desired;
- (BOOL) disabled;
- (BOOL) isActive;
- (BOOL) isStarting;
- (BOOL) isStopping;
- (BOOL) launch;
- (BOOL) mayCoreDump;
- (NSString*) name;
- (int) processIdentifier;
- (void) progress;
- (NSString*) reasonToPreventLaunch;
- (void) resetDelay;
- (void) setClient: (EcClientI*)c;
- (void) setConfiguration: (NSDictionary*)c;
- (void) setDesired: (Desired)state;
- (void) setProcessIdentifier: (int)p;
- (void) setStable: (BOOL)s;
- (void) setWhen: (NSDate*)w;
- (BOOL) stable;
- (NSTask*) task;
- (NSDate*) when;
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
  NSArray               *launchOrder;
  NSDictionary		*environment;
  unsigned		pingPosition;
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
- (void) clear: (NSString*)name addText: (NSString*)additional;
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
- (NSData*) registerClient: (id<CmdClient>)c
		      name: (NSString*)n
		 transient: (BOOL)t;
- (void) reply: (NSString*) msg to: (NSString*)n from: (NSString*)c;
- (void) terminate: (NSDate*)by;
- (void) _terminate: (NSTimer*)t;
- (void) tryLaunch: (NSTimer*)t;
- (void) _tryLaunch: (NSTimer*)t;
- (void) tryLaunchSoon;
- (NSMutableArray*) unconfiguredClients;
- (void) unregisterByObject: (id)obj;
- (void) unregisterClient: (EcClientI*)o;
- (void) update;
- (void) updateConfig: (NSData*)data;
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
  unsigned		suspended = 0;
  unsigned		alive = 0;

  while (nil != (l = [e nextObject]))
    {
      if ([l isStarting])
        {
          starting++;
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
    @" disabled:%u, suspended:%u, launchable:%u (auto:%u)\n",
    starting, alive, disabled, suspended, launchable, autolaunch];
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
      if (l->starting != nil && l->task != nil)
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
                  [l starting: nil];
                }
            }
        }
    }
  LEAVE_POOL
}

+ (void) remove: (NSString*)name
{
  [launchInfo removeObjectForKey: name];
}

- (BOOL) autolaunch
{
  return [[conf objectForKey: @"Auto"] boolValue];
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

- (void) clearClient: (EcClientI*)c unregistered: (BOOL)didQuit
{
  NSAssert(client == c, NSInternalInconsistencyException);
  DESTROY(client);
  if (didQuit)
    {
      clientQuit = YES;
      clientLost = NO;
    }
  else
    {
      clientQuit = NO;
      clientLost = YES;
    }
  /* The connection to the client went away, which implies that the process
   * was connected/registred and we must either be stopping already or need
   * to stop (expect the process to die soon).
   * So either way we should trigger the -stopping: timeout handler to
   * check for the end of the process and to ensure that we try again if
   * it has not yet ended.
   */
  [self stopping: nil];
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
  [starting invalidate];
  [stopping invalidate];
  RELEASE(restartReason);
  RELEASE(client);
  RELEASE(name);
  RELEASE(conf);
  RELEASE(when);
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
  [self setWhen: [NSDate dateWithTimeIntervalSinceNow: delay]];
  return delay;
}

- (NSString*) description
{
  NSString	*status;

  if (nil != starting)
    {
      status = [NSString stringWithFormat: @"Starting since %@",
        [NSDate dateWithTimeIntervalSinceReferenceDate: startingTime]];
    }
  else if (nil != stopping)
    {
      status = [NSString stringWithFormat: @"Stopping since %@",
        [NSDate dateWithTimeIntervalSinceReferenceDate: stoppingTime]];
    }
  else if (nil == client)
    {
      status = @"Not active";
    }
  else
    {
      status = @"Active";
    }
  return [NSString stringWithFormat: @"%@ for process '%@'\n"
    @"  %@\n"
    @"  Configuration %@\n",
    [super description], name, status, conf];
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
  return (client != nil && stopping == nil) ? YES : NO;
}

- (BOOL) isStarting
{
  return starting ? YES : NO;
}

- (BOOL) isStopping
{
  return stopping ? YES : NO;
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
	      [self setWhen: [NSDate date]];
	      [[NSNotificationCenter defaultCenter]
		addObserver: self
		   selector: @selector(taskTerminated:)
		       name: NSTaskDidTerminateNotification
		     object: task];
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
      [command alarmCode: ACLaunchFailed
                procName: name
                 addText: failed];
    }
  LEAVE_POOL
  return [self checkAlive];  // On failure return NO
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
  NSString      *reason = nil;

  if (nil == starting)
    {
      if ([launchQueue containsObject: self])
        {
          NSLog(@"Found object which is not starting in queue: %@", self);
          [launchQueue removeObject: self];
        }
    }
  else if (nil != stopping)
    {
      if ([launchQueue containsObject: self])
        {
          NSLog(@"Found object which is stopping in queue: %@", self);
          [launchQueue removeObject: self];
        }
    }
  else if (YES == [self checkAlive])
    {
      if ([launchQueue containsObject: self])
        {
          NSLog(@"Found object which is already alive in queue: %@", self);
          [launchQueue removeObject: self];
        }
    }
  else if (nil != when && [when timeIntervalSinceNow] > 0.0)
    {
      reason = [NSString stringWithFormat: @"waiting for retry at %@", when];
    }
  else if ([command ecIsQuitting])
    {
      reason = @"system shutting down";
    }
  else if (terminateBy != nil)
    {
      reason = @"all servers shutting down";
    }
  else if (launchSuspended)
    {
      reason = @"launching suspended";
    }
  else if (launchLimit > 0 && [LaunchInfo launching] >= launchLimit)
    {
      reason = [NSString stringWithFormat: @"%u launches in progress",
        (unsigned)launchLimit];
    }
  else
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
      if ([d count] > 0)
        {
          reason = [NSString stringWithFormat: @"waiting for %@", d];
        }
    }
  return reason;
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
  if (nil == starting && nil == stopping)
    {
      if (Live == desired && nil == client)
        {
          [self start];
        }
      else if (Dead == desired && nil != client)
        {
          [self stop];
        }
    }
}

- (void) resetDelay
{
  fib0 = fib1 = 0.0;
}

- (void) restart: (NSString*)reason
{
  if ([self checkActive])
    {
      if (nil == stopping)
        {
          ASSIGNCOPY(restartReason, reason);
          [self stop];
        }
    }
  if (desired != Live)
    {
      [self setDesired: Live];
    }
}

/* When process startup has completed and the client has registered itself
 * with the Command server, the registration process will call this method.
 * Here we should do all the work associated with completion of the startup
 * process.
 */
- (void) setClient: (EcClientI*)c
{
  NSAssert([c isKindOfClass: [EcClientI class]],
    NSInternalInconsistencyException);
  if (client != c)
    {
      int	newPid = [c processIdentifier];

      ASSIGN(client, c);
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
          DESTROY(task);
	}
      identifier = newPid;
    }
  clientLost = NO;
  clientQuit = NO;
  if (starting)
    {
      /* The client has connected and registered itself ... startup of
       * this process has completed.  Alarms will be cleared when the
       * new process becomes stable.
       */
      [launchQueue removeObject: self];
      [starting invalidate];
      starting = nil;
      startingTime = 0.0;
      if (Dead == desired)
        {
          /* It is not desired that this process should be running:
           * initiate a shutdown.
           */
          [self stop];
        }
    }
  [LaunchInfo processQueue];    // Maybe we can launch more now
}

- (void) setConfiguration: (NSDictionary*)c
{
  ASSIGNCOPY(conf, c);
  if ([self disabled])
    {
      [self setDesired: Dead];
    }
  else if ([self autolaunch])
    {
      [self setDesired: Live];
    }
  else
    {
      [self setDesired: None];
    }
}

/* Called when a manual change is made to specify what state a process should
 * be in.
 */
- (void) setDesired: (Desired)state
{
  Desired       old = desired;

  desired = state;
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
      if (terminateBy != nil && stopping != nil
        && [when earlierDate: terminateBy] == terminateBy)
        {
          /* Force timer reset to match terminateBy
           */
          [self stopping: nil];
        }
    }
  else if (starting)
    {
      NSLog(@"-setDesired:%@ deferred pending startup of %@",
        desiredName(desired), self);
    }
  else if (stopping)
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

- (void) setProcessIdentifier: (int)p
{
  identifier = p;
}

- (void) setStable: (BOOL)s
{
  stable = s ? YES : NO;
}

- (void) setWhen: (NSDate*)w
{
  ASSIGNCOPY(when, w);
}

- (BOOL) stable
{
  return stable;
}

/* This method may be called to initiate startup of a server.
 * If called when a server is already starting or shutting down
 * it has no effect.
 */
- (void) start
{
  if (nil != starting)
    {
      NSLog(@"-start when already starting of %@", self);
    }
  else if (YES == [self checkAlive])
    {
      NSLog(@"-start when already alive of %@", self);
    }
  else
    {
      NSLog(@"-start called for %@", self);
      DESTROY(when);            // No limit on when we can start
      [self resetDelay];
      terminationCount = 0;
      terminationTime = 0.0;
      terminationStatus = -1;
      startingAlarm = NO;
      startingTime = [NSDate timeIntervalSinceReferenceDate];
      starting = [NSTimer scheduledTimerWithTimeInterval: 0.01
						  target: self
						selector: @selector(starting:)
						userInfo: name
						 repeats: NO];
    }
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
  if (t != starting)
    {
      [starting invalidate];
    }
  starting = nil;

  if (YES == [self checkAlive])
    {
      /* We are waiting for the client to connect and register.
       */
      ti = 0.0;         // Calculate the time we wait below
    }
  else
    {
      NSString  *r = [self reasonToPreventLaunch];

      if (nil == r)
        {
          /* We are able to launch now
           */
          [launchQueue removeObject: self];
          if (NO == [self launch])
            {
              ti = [self delay];        // delay between launch attempts
              [launchQueue addObject: self];
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
          if (nil != when && [when timeIntervalSinceNow] > 0.0)
            {
              /* We are waiting for a retry at a specific time.
               * If we are not already queued, add to queue.
               */
              ti = [when timeIntervalSinceNow];
              if (NO == [launchQueue containsObject: self])
                {
                  [launchQueue addObject: self];
                }
            }
          else
            {
              /* Launching is prevented for a non-time-based reason,
               * so we reset the time from which we count launching as
               * started and specify a timer for checking again.
               */
              startingTime = [NSDate timeIntervalSinceReferenceDate];
              DESTROY(when);
              ti = 1.0;
              if (NO == [launchQueue containsObject: self])
                {
                  [launchQueue addObject: self];
                }
            }
          r = [NSString stringWithFormat: @"queued (%@)", r];
          [command logChange: r for: name];
        }
    }
  if (0.0 == ti)
    {
      ti = [NSDate timeIntervalSinceReferenceDate];
      if (ti - startingTime < 30.0)
        {
          /* We need to raise an alarm if it takes longer than 30 seconds
           * to start up the process.
           */
          ti = 30.0 - (ti - startingTime);
        }
      else
        {
          if (NO == startingAlarm)
            {
              [command alarmCode: ACLaunchFailed
                        procName: name
                         addText: @"Client not active after launch attempt"];
            }
          ti = 60.0;
        }
    }
  starting = [NSTimer scheduledTimerWithTimeInterval: ti
					      target: self
					    selector: _cmd
					    userInfo: name
					     repeats: NO];
}

- (void) stop
{
  if (nil == stopping && YES == [self checkAlive])
    {
      [self resetDelay];
      DESTROY(when);
      stoppingAlarm = NO;
      stoppingTime = [NSDate timeIntervalSinceReferenceDate];
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
                  [self clearClient: client unregistered: NO];
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

  [stopping invalidate];
  stopping = nil;

  if (YES == clientLost)
    {
      NSString      *text;

      if (terminationStatus != 0)
        {
          text = [NSString stringWithFormat: @"process lost (termination"
            @" status %d)", terminationStatus];
        }
      else
        {
          text = @"process lost";
        }
      [command alarmCode: ACProcessLost
                procName: name
                 addText: text];
      [command update];
    }
  else if (YES == clientQuit)
    {
      /* Clean shutdown (process unregistered itself).
       */
      [command update];
    }
  else
    {
      /* Loss of a process which hadn't connected/registered.
       */
    }
  [self progress];
  [LaunchInfo processQueue];
}

- (void) stopping: (NSTimer*)t
{
  NSTimeInterval	ti = 0.0;
  NSDate                *final;

  [stopping invalidate];
  stopping = nil;

  if (nil == client && NO == [self checkAlive])
    {
      [self stopped];
      return;
    }

  if (nil == when)
    {
      /* We need to set a limit on how long the shutdown process can take.
       */
      ti = stoppingTime + 120.0;
      ASSIGN(when, [NSDate dateWithTimeIntervalSinceReferenceDate: ti]);
    }
  if (nil == terminateBy)
    {
      final = when;
    }
  else
    {
      final = [when earlierDate: terminateBy];
    }
  ti = [final timeIntervalSinceNow];
  if (ti <= 0.0)
    {
      /* Maximum time for clean shutdown has passed.
       */
      if (client != nil)
        {
          [self clearClient: client unregistered: NO];
        }
      DESTROY(task);
      if (identifier > 0)
        {
          kill(identifier, SIGKILL);
          identifier = 0;
        }
      [self stopped];
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
      stopping = [NSTimer scheduledTimerWithTimeInterval: ti
                                                  target: self
                                                selector: _cmd
                                                userInfo: name
                                                 repeats: NO];
    }
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
      terminationTime = [NSDate timeIntervalSinceReferenceDate];
      DESTROY(task);
      if (terminationStatus != 0)
        {
          NSLog(@"Termination status %d for %@ (pid %d)",
            terminationStatus, name, identifier);
        }
      identifier = 0;

      if (client != nil)
        {
          [self stopping: nil];
          return;               // Connection not yet lost
        }
      [self stopped];
    }
}

- (NSDate*) when
{
  return AUTORELEASE(RETAIN(when));
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

/* Raise or clear an alarm for a named process.
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
  managedObject = EcMakeManagedObject(host, name, nil);
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

- (void) clear: (NSString*)name addText: (NSString*)additional
{
  NSString	*managedObject;
  NSString      *problem;
  NSString      *repair;
  EcAlarm	*a;
  AlarmCode     c;

  ENTER_POOL
  managedObject = EcMakeManagedObject(host, name, nil);
  for (c = ACLaunchFailed; c < ACProcessLost; c++)
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
  [super ecAwaken];
  [[self ecAlarmDestination] setCoalesce: NO];
  launchSuspended = [[self cmdDefaults] boolForKey: @"LaunchStartSuspended"];
  [self _tryLaunch: nil];    // Simulate timeout to set timer going
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

              /* Validate the LaunchOrder array and use it to add
               * some dependncies.
               */
              if (newOrder != nil)
                {
                  NSUInteger    c;
                  NSUInteger    i;

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
                  /* Now we use an explicit launch order as a means of
                   * setting dependencies for all but the first item.
                   */
                  c = [newOrder count];
                  for (i = 1; i < c; i++)
                    {
                      NSMutableArray    *ma;

                      k = [newOrder objectAtIndex: i];
                      md = [conf objectForKey: k];
                      ma = [md objectForKey: @"Deps"];
                      if (nil == ma)
                        {
                          ma = [NSMutableArray arrayWithCapacity: 1];
                          [md setObject: ma forKey: @"Deps"];
                        }
                      k = [newOrder objectAtIndex: i - 1];
                      if (NO == [ma containsObject: k])
                        {
                          [ma addObject: k];
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
                      [l setConfiguration: [conf objectForKey: k]];
                      [missing removeObject: k];
                    }
                }
            }

	  /* Now any process names which have no configuration must be
	   * removed from the list of launchable processes.
	   */
	  e = [missing objectEnumerator];
	  while (nil != (k = [e nextObject]))
	    {
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
      if (r != nil && num > 2)
	{
          NSString      *n = [r name];
	  LaunchInfo	*l = [LaunchInfo existing: n];

	  /* This was a successful launch so we don't need to impose
	   * a delay between launch attempts.
	   */
	  [l resetDelay];
	  if (NO == [l stable])
	    {
	      /* After the first few ping responses from a client we assume
	       * that client has completed startup and is running OK.
	       * We can therefore clear any loss of client alarm, any
	       * alarm for being unable to register, and launch failure
	       * or fatal configuration alarms.
	       */
              [l setStable: YES];
              [self clear: [l name] addText: @"process is now stable"];
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
		      @"List order\nReports launch attempt order.\n";
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
          if (YES == launchSuspended)
            {
              m = @"Launching of tasks is suspended.\n"
                  @"Use the Resume command to resume launching.\n";
            }
	  else if ([cmd count] > 1)
	    {
              NSString	*nam = [cmd objectAtIndex: 1];
              BOOL      all = NO;

              if ([nam caseInsensitiveCompare: @"all"] == NSOrderedSame)
                {
                  all = YES;
                }

	      if ([[LaunchInfo names] count] > 0)
		{
		  NSEnumerator	*enumerator;
		  NSString	*key;
		  BOOL		found = NO;

		  enumerator = [launchOrder objectEnumerator];
                  if (YES == all)
                    {
                      NSMutableArray  *names = [NSMutableArray array];

                      while ((key = [enumerator nextObject]) != nil)
                        {
                          EcClientI	*r;
			  LaunchInfo	*l;
                          NSDictionary  *inf;

                          l = [LaunchInfo existing: key];
                          inf = [l configuration];
			  if ([l autolaunch] == NO)
                            {
                              continue;
                            }
                          r = [self findIn: clients byName: key];
                          if (nil != r)
                            {
                              continue;
                            }
                          found = YES;
			  if (nil != l)
			    {
			      [l resetDelay];
			      [l setDesired: Live];
			    }
                          [names addObject: key];
                        }
                      if (YES == found)
                        {
                          [names sortUsingSelector: @selector(compare:)];
                          m = [NSString stringWithFormat:
                            @"Ok - I will launch %@ when I get a chance.\n",
                            names];
                        }
                    }
                  else
                    {
                      while ((key = [enumerator nextObject]) != nil)
                        {
                          if (comp(nam, key) >= 0)
                            {
                              EcClientI	*r;

                              found = YES;
                              r = [self findIn: clients byName: key];
                              if (r == nil)
                                {
				  LaunchInfo	*l;

				  l = [LaunchInfo existing: key];
				  if (nil != l)
				    {
				      [l resetDelay];
				      [l setDesired: Live];
				    }
                                  m = @"Ok - I will launch that program "
                                      @"when I get a chance.\n";
                                }
                              else
                                {
                                  m = @"That program is already running\n";
                                }
                            }
                        }
                    }
		  if (found == NO)
		    {
		      m = @"I don't know how to launch that program.\n";
		    }
		}
	      else
		{
		  m = @"There are no programs we can launch.\n";
		}
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
		  NSDate	*date;
		  NSDate	*now = [NSDate date];

		  m = @"Programs we can launch -\n";
		  enumerator = [[names sortedArrayUsingSelector:
		    @selector(compare:)] objectEnumerator];
		  while ((key = [enumerator nextObject]) != nil)
		    {
		      EcClientI		*r;
		      LaunchInfo	*l = [LaunchInfo existing: key];

		      m = [m stringByAppendingFormat: @"  %-32.32s ",
			[key cString]];
		      r = [self findIn: clients byName: key];
		      if (nil != r)
			{
			  m = [m stringByAppendingString: @"running\n"];
			}
		      else if ([l isStarting])
			{
			  m = [m stringByAppendingString: 
			    @"launch attempt in progress\n"];
			}
		      else
			{
			  if ([l disabled] == YES)
			    {
			      m = [m stringByAppendingString: 
				@"disabled in config\n"];
			    }
			  else if ([l autolaunch] == NO)
			    {
			      date = [[LaunchInfo existing: key] when];
			      if (nil == date
				|| [NSDate distantFuture] == date)
				{
				  m = [m stringByAppendingString: 
				    @"may be launched manually\n"];
				}
			      else if ([now timeIntervalSinceDate: date] > 0.0)
				{
				  m = [m stringByAppendingString: 
				    @"will attempt launch ASAP\n"];
				}
			      else
				{
				  m = [m stringByAppendingFormat: 
				    @"will attempt launch at %@\n", date];
				}
			    }
			  else
			    {
			      LaunchInfo	*l;

			      l = [LaunchInfo existing: key];
			      date = [l when];
			      if (date == nil)
				{
				  date = now;
				  [l setWhen: date];
				}
			      if ([NSDate distantFuture] == date)
				{
				  m = [m stringByAppendingString: 
				    @"manually suspended\n"];
				}
			      else
				{
				  if ([now timeIntervalSinceDate: date] > 0.0)
				    {
				      m = [m stringByAppendingString: 
					@"will attempt autolaunch ASAP\n"];
				    }
				  else
				    {
				      m = [m stringByAppendingFormat: 
					@"will attempt autolaunch at %@\n",
					date];
				    }
				}
			    }
			}
		    }
		  if ([launchInfo count] == 0)
		    {
		      m = [m stringByAppendingString: @"nothing\n"];
		    }
		}
	      else
		{
		  m = @"There are no programs we can launch.\n";
		}
              if (YES == launchSuspended)
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
		  NSArray	*a = [self findAll: clients byAbbreviation: wd];
		  unsigned	i;
		  BOOL		found = NO;

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
                              [l setDesired: NO];
                            }
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

			      l = [LaunchInfo existing: key];
                              if ([l desired] == Dead)
				{
				  m = [m stringByAppendingFormat:
				    @"Suspended %@ already\n", key];
				}
			      else
				{
                                  [l setDesired: Dead];
				  m = [m stringByAppendingFormat:
				    @"Suspended %@\n", key];
				}
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
          if (YES == launchSuspended)
            {
              launchSuspended = NO;
              m = @"Launching is now resumed.\n";
              [self tryLaunchSoon];
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
			@"\nProcess '%@' is launching since %@.",
			n, [l when]];
		    }
		  m = [m stringByAppendingFormat: @"\n%@\n", l];
		}
	    }
        }
      else if (comp(wd, @"suspend") >= 0)
        {
          if (YES == launchSuspended)
            {
              m = @"Launching was/is already suspended.\n";
            }
          else
            {
              launchSuspended = YES;
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
	  /* No instance specific config found for server,
	   * try using the base server name without instance ID.
	   */
	  o = [config objectForKey: base];
	}
      else
	{
	  id	tmp;

	  /* We found instance specific configuration for the server,
	   * so we merge by taking values from generic server config
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

              if (NO == [o unregistered])
                {
                  [self alarmCode: ACProcessLost
                         procName: [l name]
                          addText: @"lost connection to process"];
                }
              lostClients = YES;
	      [self unregisterClient: o];
              [l clearClient: o unregistered: NO];
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
  RELEASE(launchOrder);
  RELEASE(environment);
  RELEASE(outstanding);
  [super dealloc];
}

- (NSString*) description
{
  NSMutableString	*m;

  m = [NSMutableString stringWithFormat: @"%@ running since %@\n",
    [super description], [self ecStarted]];
  if (launchSuspended)
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
      if (control == nil)
	{
	  [self tryLaunch: nil];
	}
      if (control == nil)
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

      [l setDesired: Dead];
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
      [l setDesired: Live];
    }
  return YES;
}

- (void) logChange: (NSString*)change for: (NSString*)name
{
  NSString      *s;

  NSLog(@"%@ server with name '%@' on %@", change, name, host);
  s = [NSString stringWithFormat: @"%@ %@ server with name '%@' on %@\n",
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
      [l setDesired: Dead];
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

- (NSData*) registerClient: (id<CmdClient>)c
		      name: (NSString*)n
		 transient: (BOOL)t
{
  LaunchInfo	        *l = [LaunchInfo existing: n];
  NSDate		*now = [NSDate date];
  int		        pid;
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

  pid = [c processIdentifier];

  /* Do we already have this registered?
   */
  if ([l processIdentifier] == pid && (obj = [l client]) != nil)
    {
      [self logChange: @"re-registered" for: [l name]];
      if ([l stable] == YES)
        {
          [self clear: [l name] addText: @"process re-registered"];
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

      [obj setProcessIdentifier: pid];

      if (nil == l)
	{
	  l = [LaunchInfo launchInfo: n];
	}
      [l setWhen: now];
      [l setClient: obj];

      if (t == YES)
	{
	  [obj setTransient: YES];
	}
      else
	{
	  [obj setTransient: NO];
	}
      [self logChange: @"registered" for: [l name]];
      d = [self configurationFor: n];
      if (nil != d)
	{
	  [obj setConfig: d];
	}
      [self tryLaunchSoon];
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
  if (control == nil)
    {
      [self tryLaunch: nil];
    }
  if (control != nil)
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
      when = [NSCalendarDate dateWithTimeIntervalSinceReferenceDate: ti];
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

      when = [NSCalendarDate dateWithTimeIntervalSinceReferenceDate: ti];
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

      when = [NSCalendarDate dateWithTimeIntervalSinceReferenceDate: ti];
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

- (void) tryLaunch: (NSTimer*)t
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
      if (control == nil)
	{
	  NSUserDefaults	*defs;
	  NSString		*ctlName;
	  NSString		*ctlHost;
	  id			c;

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

      a = AUTORELEASE([clients mutableCopy]);
      count = [a count];
      while (count-- > 0)
	{
	  EcClientI	*r = [a objectAtIndex: count];
	  NSDate	*d = [r outstanding];
	  
	  if ([clients indexOfObjectIdenticalTo: r] != NSNotFound
            && d != nil && [d timeIntervalSinceDate: now] < -pingDelay)
	    {
	      NSString		*m;

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
      /*
       * We ping each client in turn.  If there are fewer than 4 clients,
       * we skip timeouts so that clients get pinged no more frequently
       * than one per 4 timeouts.
       */
      count = [clients count];
      pingPosition++;
      if (pingPosition >= 4 && pingPosition >= count)
	{
	  pingPosition = 0;
	}
      if (pingPosition < count)
	{
	  [[clients objectAtIndex: pingPosition] ping];
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

- (void) _tryLaunch: (NSTimer*)t
{
  NS_DURING
    [self tryLaunch: t];
  NS_HANDLER
    NSLog(@"Problem in timeout: %@", localException);
  NS_ENDHANDLER

  if (NO == [timer isValid] && NO == [self ecIsQuitting])
    {
      timer = [NSTimer scheduledTimerWithTimeInterval: 5.0
					       target: self
					     selector: @selector(_tryLaunch:)
					     userInfo: nil
					      repeats: NO];
    }
}

- (void) tryLaunchSoon
{
  if (NO == [timer isValid] || [[timer fireDate] timeIntervalSinceNow] > 0.1)
    {
      [timer invalidate];
      timer = [NSTimer scheduledTimerWithTimeInterval: 0.1
        target: self
        selector: @selector(_tryLaunch:)
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
      if (i <= pingPosition && pingPosition > 0)
	{
	  pingPosition--;
	}
    }
  [self logChange: @"unregistered" for: name];
}

- (void) unregisterByObject: (id)obj
{
  EcClientI	*o = [self findIn: clients byObject: obj];

  if (o != nil)
    {
      LaunchInfo	*l = [launchInfo objectForKey: [o name]];

      [l clearClient: o unregistered: YES];
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
	  NSLog(@"Exception sending servers to Control: %@", localException);
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

@end

