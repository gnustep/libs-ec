
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

#ifndef INCLUDED_ECPROCESS_H
#define INCLUDED_ECPROCESS_H

#import	<Foundation/Foundation.h>

#import	"EcAlarm.h"
#import	"EcAlarmDestination.h"

/** Convenience macros to raise unique alarms (which do not clear automatically)
 * for exceptions or unexpected code/data errors.  The unique specificProblem
 * for each alarm is derived from the file and line at which it is raised.
 * These macros should only be used when it's impossible/impractical to have
 * the code automatically detect that a problem has gone away, and clear the
 * alarm.
 */
#define EcExceptionCritical(cause, format, args...) \
  [EcProc ecException: (cause) \
      specificProblem: [NSString stringWithFormat: @"%s at %@ line %d", \
    (nil == (cause) ? "Code/Data Error" : "Exception"), \
    [[NSString stringWithUTF8String: __FILE__] lastPathComponent], __LINE__] \
    perceivedSeverity: EcAlarmSeverityCritical \
	      message: (format), ##args ]

#define EcExceptionMajor(cause, format, args...) \
  [EcProc ecException: (cause) \
      specificProblem: [NSString stringWithFormat: @"%s at %@ line %d", \
    (nil == (cause) ? "Code/Data Error" : "Exception"), \
    [[NSString stringWithUTF8String: __FILE__] lastPathComponent], __LINE__] \
    perceivedSeverity: EcAlarmSeverityMajor \
	      message: (format), ##args ]

#define EcExceptionMinor(cause, format, args...) \
  [EcProc ecException: (cause) \
      specificProblem: [NSString stringWithFormat: @"%s at %@ line %d", \
    (nil == (cause) ? "Code/Data Error" : "Exception"), \
    [[NSString stringWithUTF8String: __FILE__] lastPathComponent], __LINE__] \
    perceivedSeverity: EcAlarmSeverityMinor \
	      message: (format), ##args ]


@class	NSFileHandle;

typedef enum    {
  LT_DEBUG,             /* Debug message - internal info.       */
  LT_WARNING,           /* Warning - possibly a real problem.   */
  LT_ERROR,             /* Error - needs dealing with.          */
  LT_AUDIT,             /* Not a problem but needs logging.     */
  LT_ALERT,             /* Severe - needs immediate attention.  */
  LT_CONSOLE,           /* For Console (implicit audit).        */
} EcLogType;


/**
 * A 'ping' can be sent from or to any process to check that it is alive.
 * A 'gnip' should be sent in response to each 'ping'
 * Each 'ping' carries a sequence number which should be echoed in its 'gnip'.
 * Optionally, the 'ping' can also transport a serialized property-list
 * to provide additional data or instructions - the value of which is
 * dependent on the program being pinged - normally this value is nil.
 */
@protocol	CmdPing
- (oneway void) cmdGnip: (id <CmdPing>)from
	       sequence: (unsigned)num
		  extra: (in bycopy NSData*)data;
- (oneway void) cmdPing: (id <CmdPing>)from
	       sequence: (unsigned)num
		  extra: (in bycopy NSData*)data;
@end

/** The CmdConfig protocol is needed by objects that send and receive
 * configuarion information.
 */
@protocol	CmdConfig
- (oneway void) requestConfigFor: (id<CmdConfig>)c;
- (oneway void) updateConfig: (in bycopy NSData*)info;
@end

/** Messages that the Command server may send to clients.
 */
@protocol	CmdClient <CmdPing,CmdConfig>
- (oneway void) cmdMesgData: (in bycopy NSData*)dat from: (NSString*)name;
- (oneway void) cmdQuit: (NSInteger)status;
- (int) processIdentifier;
- (oneway void) ecReconnect;
@end

/** Messages a Command logging process can be expected to handle.
 */
@protocol	CmdLogger <CmdClient>
- (void) flush;
- (oneway void) logMessage: (NSString*)msg
		      type: (EcLogType)t
                      name: (NSString*)c;
- (oneway void) logMessage: (NSString*)msg
		      type: (EcLogType)t
		       for: (id)o;
- (bycopy NSData*) registerClient: (id)c
			     name: (NSString*)n;
- (void) unregisterByObject: (id)obj;
- (void) unregisterByName: (NSString*)n;
@end

@protocol	Console <NSObject>
- (oneway void) information: (NSString*)txt;
@end

/** Messages that clients may send to the server.
 * NB. The -registerClient:name:transient: method must be sent before
 * the -command:to:from: or -reply:to:from: methods.
 */
@protocol	Command <CmdLogger,CmdConfig,EcAlarmDestination>

/** Request a count of the active clients of the Command server
 */
- (unsigned) activeCount;

/** Pass an alarm to the Command server for forwarding to the Control
 * server for central handling to send alerts or SNMP integration.
 */
- (oneway void) alarm: (in bycopy EcAlarm*)alarm;

/** Send a text command to a process owned by the Command server.
 */
- (oneway void) command: (in bycopy NSData*)dat
		     to: (NSString*)t
		   from: (NSString*)f;

/** Request immediate launch of the named process.<br />
 * Returns NO if the process cannot be launched.<br />
 * Returns YES if the process is already running or launching has started.
 */
- (BOOL) launch: (NSString*)name;

/** Registers as a client process of the Command server.
 */
- (bycopy NSData*) registerClient: (id<CmdClient>)c
			     name: (NSString*)n
			transient: (BOOL)t;

/** Replies to a text command sent by another process.
 */
- (oneway void) reply: (NSString*)msg
		   to: (NSString*)n
		 from: (NSString*)c;

/** Shut down the Command server and all its clients.<br />
 * Clients which fail to shut down gracefully before the specified timestamp
 * will be forcibly killed. The timestamp is constrained to be at least half
 * a second in the future and not more than 15 minutes in the future. 
 */
- (oneway void) terminate: (NSDate*)byDate;

/** This is meant to be used remotely by all sorts of software running
 * on the machine and which is *not* a full Command client (ie, not a
 * subclass of EcProcess) but which still wants to retrieve
 * configuration from a central location (the Control/Command servers).<br />
 * The returned value is a a serialized property list ... you need to
 * deserialize using the standard GNUstep property list APIs.<br />
 * NB: The configuration might change later on, so you must not cache
 * the configuration after asking for it, but rather ask for it each
 * time your software needs it.
 */
- (bycopy NSData *) configurationFor: (NSString *)name;
@end

/*
 *	Messages that clients may send to the server.
 */
@protocol	Control <CmdPing,CmdConfig,EcAlarmDestination>
- (oneway void) alarm: (in bycopy EcAlarm*)alarm;
- (oneway void) command: (in bycopy NSData*)cmd
		   from: (NSString*)f;
- (oneway void) domanage: (NSString*)name;
- (oneway void) information: (NSString*)msg
		       type: (EcLogType)t
		         to: (NSString*)to
		       from: (NSString*)from;
- (bycopy NSData*) registerCommand: (id<Command>)c
			      name: (NSString*)n;
- (bycopy NSString*) registerConsole: (id<Console>)c
				name: (NSString*)n
				pass: (NSString*)p;
- (oneway void) reply: (NSString*)msg
		   to: (NSString*)n
		 from: (NSString*)c;
- (oneway void) servers: (in bycopy NSData*)a
		     on: (id<Command>)s;
- (oneway void) unmanage: (NSString*)name;
- (void) unregister: (id)o;
@end

/*
 *	Useful functions -
 */
extern void		cmdSetHome(NSString *home);
extern NSString*	cmdDataDir();
extern NSString*	cmdLogsDir(NSString *date);
extern NSString*	cmdLogKey(EcLogType t);
extern NSString*	cmdLogName();
extern NSString*	cmdLogFormat(EcLogType t, NSString *fmt);
extern void             ecSetLogsSubdirectory(NSString *pathComponent);

/** Return the native thread ID of the current thread, or NSNotFound if
 * that is not available.
 */
extern NSUInteger       ecNativeThreadID();

/* Set/get version/compilation date.
 */
extern NSString*	cmdVersion(NSString *ver);

/**
 *	Command line arguments -
 *
 *
 * <p>On startup, these are taken from the command line, or from the
 * local user defaults database of the person running the program.<br />
 * If the EcEffectiveUser specifies an alternative user, or the
 * program is able to read the database for the 'ecuser' user, then
 * the other values are read from the defaults database of that user.
 * </p>
 * <p>After startup, the command line arguments still take precedence,
 * but values retrieved from the network configuration system will
 * then override any read from the local user defaults database.
 * </p>
 * <p>Settings in the network configuration system will have no effect on
 * the following defaults which are used BEFORE the network configuration
 * can be read.
 * </p>
 * <deflist>
 *   <term>EcCoreSize</term>
 *   <desc>
 *     Specifies the maximum size (in MB) for any core-dump of the
 *     process.<br />
 *     If this is not set, the default size of 2GB is used.<br />
 *     If this is negative, the size is unlimited.<br />
 *     If this is zero then no core dumping is performed.
 *   </desc>
 *   <term>EcDaemon</term>
 *   <desc>To specify whether the program should run in the background
 *     (boolean, YES if the program is to run as a daemon, NO otherwise).<br />
 *     The value in the network configuration has no effect.
 *   </desc>
 *   <term>EcEffectiveUser</term>
 *   <desc>To tell the server to change to being this user on startup.
 *     defaults to 'ecuser', but the default can be overridden by specifying
 *     '-DEC_EFFECTIVE_USER+@"username"' in the local.make make file.<br />
 *     Set a value of '*' to remain whoever runs the program
 *     rather than changing.
 *   </desc>
 *   <term>EcInstance</term>
 *   <desc>To set the program instance ID (a non-negative integer value).<br />
 *     If this is specified, the program name has a hyphen and the
 *     id appended to it by the '-initWithDefaults:' method.
 *   </desc>
 *   <term>EcKeepStandardError</term>
 *   <desc>
 *     This boolean value determines whether the standard error output
 *     should be kept as it is on process startup, or should be merged
 *     with the local debug log to file.<br />
 *     The default (EcKeepStandardError set to NO) is to merge the
 *     standard error logging with the debug logging.
 *   </desc>
 *   <term>EcKillDebugOutput</term>
 *   <desc>
 *     This boolean value determines whether debug output (including anything
 *     written to the standard error output if that is merged with debug)
 *     should be discarded (sent to the null device).<br />
 *     This setting cannot e controlled from the Console command line.<br />
 *     The default (EcKillDebugOutput set to NO) is to write debug output to
 *     file.
 *   </desc>
 *   <term>EcTransient</term>
 *   <desc>
 *     This boolean option is used to specify that the program
 *     should not be restarted automatically by the Command
 *     server if/when it disconnects from that server.
 *   </desc>
 * </deflist>
 * <p>The following settings will be revised after startup to include the
 * values from the network configuration system.
 * </p>
 * <deflist>
 *   <term>EcAuditFlush</term>
 *   <desc>A flush interval in seconds (optionally followed by a colon
 *     and a buffer size in KiloBytes) to control flushing of audit logs.<br />
 *     Setting an interval of zero or less disables flushing by timer.<br />
 *     Setting a size of zero or less, disables buffering (so logs are
 *     flushed immediately).
 *   </desc>
 *   <term>EcDebug-</term>
 *   <desc>
 *     Any key of the form EcDebug-xxx turns on the xxx debug level
 *     on program startup.<br />
 *     The value of 'XXX' must match the name of a debug mode used
 *     by the program!
 *   </desc>
 *   <term>EcDescriptorsMaximum</term>
 *   <desc>
 *     To protect against file descriptor leaks, a process will
 *     check for the ability to create a pipe once a minute.<br />
 *     If it can't do so, it will shut down with an error message.<br />
 *     To increase the chances of a successful shutdown, two
 *     descriptors are reserved on the first check, and closed
 *     when a shutdown is attempted.<br />
 *     If EcDescriptorsMaximum is defined to a positive integer value,
 *     it is used to trigger earlier shutdown once the specified
 *     number of open file descriptors has been reached, rather
 *     than waiting for the operating system imposed limit.
 *   </desc>
 *   <term>EcMemory</term>
 *   <desc>
 *     This boolean value determines whether statistics on creation
 *     and destruction of objects are maintained.<br />
 *     This may be set in the NSUserDefaults system or in Control.plist,
 *     but may be overridden by using the 'memory' command in the
 *     Console program.
 *   </desc>
 *   <term>EcMemoryAllowed</term>
 *   <desc>
 *     This may be used to specify the total process memory usage
 *     (in megabytes) before memory usage alerting may begin.<br />
 *     Memory usage warning logs are then generated every time
 *     the average (over ten minutes) memory usage (adjusted by the
 *     average memory known not leaked) exceeds a warning
 *     threshold (the threshold is then increased).<br />
 *     If this setting is not specified (or a negative or excessive value
 *     is specified) then memory is monitored for ten minutes and
 *     the threshold is set at the peak during that period plus a
 *     margin to allow further memory growth before warning.<br />
 *     The minimum margin is determined by the EcMemoryIncrement and
 *     EcMemoryPercentage settings.<br />
 *     This may be set in the NSUserDefaults system or in Control.plist,
 *     but may be overridden by using the 'memory' command in the
 *     Console program.
 *   </desc>
 *   <term>EcMemoryIncrement</term>
 *   <desc>
 *     This integer value controls the (KBytes) increment (from
 *     current peak value) in process memory usage (adjusted by the
 *     average memory known not leaked) after which
 *     an alert is generated.<br />
 *     If this is not set (or is set to a value less than 100KB or
 *     greater than 1GB) then a value of 50MB is used.<br />
 *     Setting a higher value makes memory leak detection less
 *     sensitive (but reduces unnecessary alerts).<br />
 *     If used in conjunction with EcMemoryPercentage, the greater
 *     of the two allowed memory values is used.<br />
 *     This may be set in the NSUserDefaults system or in Control.plist,
 *     but may be overridden by using the 'memory' command in the
 *     Console program.
 *   </desc>
 *   <term>EcMemoryMaximum</term>
 *   <desc>
 *     This may be used to specify the total process memory allowed
 *     (in megabytes) before the process is forced to quit due to
 *     excessive memory usage.<br />
 *     If the total memory usage of the process reaches this threshold,
 *     the -cmdQuit: method will be called with an argument of -1.<br />
 *     If this is not specified (or a negative value is specified)
 *     the process will never shut down due to excessive memory usage.<br />
 *     This may be set in the NSUserDefaults system or in Control.plist,
 *     but may be overridden by using the 'memory' command in the
 *     Console program.
 *   </desc>
 *   <term>EcMemoryPercentage</term>
 *   <desc>
 *     This integer value controls the increase in the alerting
 *     threshold (adjusted by the average memory known not leaked)
 *     after which a memory usage alert is generated.<br />
 *     The increase is calculated as a percentage of the current
 *     peak memory usage value when an alert is generated.<br />
 *     If this is not set (or is set to a value less than 1 or
 *     greater than 100) then a value of 5 is used.<br />
 *     Setting a higher value make memory leak detection less
 *     sensitive (but reduces unnecessary alerts).<br />
 *     If used in conjunction with EcMemoryIncrement, the greater
 *     of the two allowed memory values is used.<br />
 *     This may be set in the NSUserDefaults system or in Control.plist,
 *     but may be overridden by using the 'memory' command in the
 *     Console program.
 *   </desc>
 *   <term>EcRelease</term>
 *   <desc>
 *     This boolean value determines whether checks for memory problems
 *     caused by release an object too many times are done.  Turning
 *     this on has a big impact on program performance and is not
 *     recommended except for debugging crashes and other memory
 *     issues.<br />
 *     This may be set in the NSUserDefaults system or in Control.plist,
 *     but may be overridden by using the 'release' command in the
 *     Console program.
 *   </desc>
 *   <term>EcTesting</term>
 *   <desc>
 *     This boolean value determines whether the server is running in
 *     test mode (which may enable extra logging or prevent the server
 *     from communicating with live systems etc ... the actual
 *     behavior is server dependent).<br />
 *     This may be set on the command line or in Control.plist, but
 *     may be overridden by using the 'testing' command in the
 *     Console program.
 *   </desc>
 *   <term>EcWellKnownHostNames</term>
 *   <desc>A dictionary mapping host names/address values to well known
 *     names (the canonical values used by Command and Control).
 *   </desc>
 * </deflist>
 * Alarm mechanism
 * <p>
 *   The EcProcess class conforms to the EcAlarmDestination protocol
 *   to allow sending alarm information to a centralised alarm system
 *   via the Command server (the Control server acts as a sink for
 *   those alarms and provides SNMP integration).
 * </p>
 * <p>
 *   In addition to the standard alarm destination behavior, the
 *   process automates some thngs:<br />
 *   On successful startup and registration with the Command server,
 *   a -domanage: message is automatically sent for the default
 *   managed object, clearing any outrstanding alarms.<br />
 *   On successful shutdown (ie when -cmdQuit: is called with zero
 *   as its argument), an -unmanage: message is automatically sent
 *   to clear any outstanding alarms for the default managed object.<br />
 *   If you want to raise alarms which will persist after a successful
 *   shutdown you should therefore do so by creating a different managed
 *   object for which to raise those alarms.
 * </p>
 * <p>As a convenience, the class provides various methods to raise different
 * kinds of alarms for specific common purposes:
 * </p>
 * <deflist>
 *   <term>Configuration problems</term>
 *   <desc>-alarmConfigurationFor:specificProblem:additionalText:critical:
 *   </desc>
 *   <term>Exceptions and unexpected errors</term>
 *   <desc>-ecException:specificProblem:perceivedSeverity:message:,...
 *   </desc>
 * </deflist>
 * <p>
 *   To further aid with logging/alarming about unexpected code and data
 *   problems, there are macros to provide detailed logs as well as
 *   specific alarms of different severity.
 * </p>
 */
@interface EcProcess : NSObject <CmdClient,EcAlarmDestination>
{
  /** Any method which is executing in the main thread (and needs to
   * return before a quit can be handled in the main thread) must
   * increment this counter on entry and decrement it again before exit.
   * This allows the process to ensure that it calls -ecHandleQuit when
   * no such method is in progress.
   */
  NSUInteger    ecDeferQuit;
}

/** This method is provided to prompt for an encryption key using the
 * specified key name and read in a value from the terminal.<br />
 * The entered value must be an even numbered sequence of hexadecimal
 * digits, each pair representing one byte of the key.<br />
 * The key length (number of bytes) must be the specified size, a value
 * between 16 and 128, which is exactly half the number of hexadecimal
 * digits that must be entered.<br />
 * If the digest is not supplied, the user will be required to
 * enter the value twice (and the two values must match) for
 * confirmation.<br />
 * If the digest is supplied, the md5 digest of the entered key must
 * match it (but the user does not need to enter the value twice).
 */
+ (NSString*) ecGetKey: (const char*)name
                  size: (unsigned)size
                   md5: (NSData*)digest;

/** Provides initial configuration.
 * This method is used by -init and its return value is passed to
 * -initWithDefaults: method.<br />
 * The default implementation simply sets the ProgramName and
 * HomeDirectory defaults (with the default prefix configured
 * when the library was built) to the current program name and
 * the current directory ('.').<br />
 * Subclasses may override this method to provide additional
 * default configuration for processes using them. The returned
 * dictionary is mutable so that a subclass may simply modify
 * the configuration provided by the superclass implementation.
 */
+ (NSMutableDictionary*) ecInitialDefaults;

/** Returns the lock used by the -ecDoLock and -ecUnLock methods.
 */
+ (NSRecursiveLock*) ecLock;

/** Registers an NSUserDefaults key that the receiver understands.<br />
 * This is primarily intended for user defaults which can reasonably
 * be supplied at the command line when a process is started (and for
 * which the process should therefore supply help information).<br />
 * The type text must be a a short string saying what kind of value
 * must be provided (eg 'YES/NO') for the default, or nil if no help
 * is to be provided for the default.<br />
 * The help text should be a description of what the default does,
 * or nil if no help is to be provided for the default.<br />
 * The action may either be NULL or a selector for a message to be sent
 * to the EcProc instance with a single argument (the new default value)
 * when the value of the user default changes.<br />
 * The value may either be NULL, or be an object to be set in the registration
 * domain of the defaults system (as long as this method is called before
 * the EcProcess instance is initialized).<br />
 * If the same default name is registered more than once, the values
 * from the last registration are used, except for the case where the
 * cmd argument is NULL, in that case the previous selector is kept
 * in the new registration.<br />
 * This method should be called in your +initialize method, so that all
 * supported defaults are already registered by the time your process
 * tries to respond to being started with a --help command line argument.<br />
 * NB. defaults keys do not have to be registered (and can still be updated
 * using the 'defaults' command), but registration provides a more user
 * friendly interface.
 */
+ (void) ecRegisterDefault: (NSString*)name
              withTypeText: (NSString*)type
               andHelpText: (NSString*)help
                    action: (SEL)cmd
                     value: (id)value;

/** Convenience method to create the singleton EcProcess instance
 * using the initial configuration provided by the +ecInitialDefaults
 * method.<br />
 * Raises NSGenericException if the singleton instance has already
 * been created.
 */
+ (void) ecSetup;

/** Convenience method to produce a generic configuration alarm and send
 * it via the -alarm: method.<br />
 * The managed object may be nil (in which case it's the default managed object
 * for the current process).<br />
 * The implied event type is EcAlarmEventTypeProcessingError.<br />
 * The implied probable cause is EcAlarmConfigurationOrCustomizationError.<br />
 * The implied severity is EcAlarmSeverityMajor unless isCritical is YES.<br />
 * The implied trend is EcAlarmTrendNone.<br />
 * The implied proposed repair action is to check/correct the config.<br />
 * The specific problem and additional text should be used to suggest
 * what is wrong with the config and where the config error should be
 * found/corrected.
 */
- (EcAlarm*) alarmConfigurationFor: (NSString*)managedObject
                   specificProblem: (NSString*)specificProblem
                    additionalText: (NSString*)additionalText
                          critical: (BOOL)isCritical;

/** Returns the array of current alarms.
 */
- (NSArray*) alarms;

/** Convenience method to clear an alarm as produced by the
 * -alarmConfigurationFor:specificProblem:additionalText:critical:
 * method.
 */
- (void) clearConfigurationFor: (NSString*)managedObject
               specificProblem: (NSString*)specificProblem
                additionalText: (NSString*)additionalText;

/** Returns the alarm destination for this process.
 */
- (EcAlarmDestination*) ecAlarmDestination;

/** Return a short copyright notice ... subclasses should override.
 */
- (NSString*) ecCopyright;

/** Obtain a lock on the shared EcProcess for thread-safe updates to
 * process-wide variables.
 */
- (void) ecDoLock;

/** Called once other stages of a graceful shutdown has completed in
 * order to perform final cleanup and have the process exit with the
 * expected status.<br />
 * Called automatically but subclasses overriding -ecHandleQuit may
 * call it explicitly at the end of the handling process.
 */
- (oneway void) ecDidQuit;

/** Called by -ecQuitFor:with: or -cmdQuit: (after the -ecWillQuit and
 * before the -ecDidQuit methods) as a method for subclasses to use to
 * implement their own behaviors.<br />
 * Subclass implementations should call the superclass implementation
 * as the last thing they do.<br />
 * This method is always called in the main thread of the process and
 * when the ecDeferQuit instance variable is zero.
 */
- (void) ecHandleQuit;

/** Returns YES if the process is attempting a graceful shutdown,
 * NO otherwise.  This also checks to see if the process has been
 * attempting to shut down for too long, and if it has been going
 * on for over three minutes, aborts the process.<br />
 * Subclasses must not override this method.
 */
- (BOOL) ecIsQuitting;

/** This method is designed for handling an orderly shutdown by calling
 * -ecWillQuit: with the supplied reason, then -ecHandleQuit, and finally
 * calling -ecDidQuit: passing the supplied status.<br />
 * Subclasses should not normally override this method. Instead override
 * the -ecHandleQuit method.<br />
 * For backward compatibility, this will call the -cmdQuit: method if a
 * subclass has overriden it.
 */
- (oneway void) ecQuitFor: (NSString*)reason with: (NSInteger)status; 

/** Returns the quit reason supplied to the -ecQuitFor:with method.
 */
- (NSString*) ecQuitReason;

/** Returns the quit status supplied to the -ecQuitFor:with or -cmdQuit:
 * method.
 */
- (NSInteger) ecQuitStatus;

/** This method may be called to prompt the process to connect to the
 * Command server if it is not already connected.
 */
- (oneway void) ecReconnect;

/** This method is designed for handling an orderly restart.<br />
 * The default implementation calls -ecQuitFor:status: with minus one as
 * the status code so that the Command server will start the process
 * again.<br />
 * The method is called automatically when the MemoryMaximum limit is
 * exceeded (to gracefully handle memory leaks by restarting).<br />
 * Subclasses may override this method to allow the shutdown process to be
 * handled differently.
 */
- (oneway void) ecRestart: (NSString*)reason;

/** Return the timestamp at which this process started up (when the
 * receiver was initialised).
 */
- (NSDate*) ecStarted;

/** Release a lock on the shared EcProcess after thread-safe updates to
 * process-wide variables.
 */
- (void) ecUnLock;

/** This aborts immediately if the process is already quitting,
 * otherwise it returns after setting the start time used by the
 * -ecIsQuitting method and (if -ecQuitReason is not nil/empty)
 * generating a log of why quitting was started.<br />
 * Called automatically when the process starts shutting down.
 */
- (void) ecWillQuit;

/* Call these methods during initialisation of your instance
 * to set up automatic management of connections to servers. 
 * You then access the servers by calling -(id)server: (NSString*)serverName.
 */

/** This is a convenience method equivalent to calling
 * -addServerToList:for: passing nil as the second argument.
 */
- (void) addServerToList: (NSString*)serverName;

/** Adds the specified serverName to the list of named servers to which
 * we make automatic distributed object connections.<br />
 * By default the supplied serverName is taken as the name of the server to
 * which the distributed objects connection is made, and the connection
 * is to any host on the local network.  However configuration in the
 * user defaults system (using keys derived from the serverName) may
 * be used to modify this behavior:
 * <deflist>
 *  <term>serverNameName</term>
 *  <desc>Specifies the actual distributed objects port name to which the
 *  connection is made, instead of using serverName.</desc>
 *  <term>serverNameHost</term>
 *  <desc>Specifies the actual distributed objects host name to which the
 *  connection is made, instead of using an asterisk (any host).</desc>
 *  <term>serverNameBroadcast</term>
 *  <desc>Specifies that the server should actually be configured to be
 *  a broadcast proxy (see [EcBroadcastProxy]).<br />
 *  The value of this field must be an array containing the configuration
 *  information for the [EcBroadcastProxy] instance.<br />
 *  If this is defined then the serverNameName and serverNameHost values
 *  (if present) are ignored, and the connections are made to the
 *  individual servers listed in the elements of this array.</desc>
 * </deflist>
 * The argument anObject is an object which will be messaged when the
 * connection to the server is established (or lost).  The messages
 * sent are those in the <em>RemoteServerDelegate</em> informal
 * protocol.<br />
 * If no object is specified, the receiver is used.<br />
 * Once a server has been added to the list, it can be accessed using
 * the -server: or -server:forNumber: method.
 */
- (void) addServerToList: (NSString*)serverName for: (id)anObject;

/** Removes the serverName from the list of server processes for which
 * we automatically maintain distributed object connections.<br />
 * See the addServerToList:for: metho for more details.
 */
- (void) removeServerFromList: (NSString*)serverName;


/** Deprecated; do not use.
 */
- (void) cmdAlert: (NSString*)fmt arguments: (va_list)args;

/** Deprecated; do not use.
 */
- (void) cmdAlert: (NSString*)fmt, ... NS_FORMAT_FUNCTION(1,2);

/** Archives debug log files into the appropriate subdirectory for the
 * supplied date (or the files last modification date if when is nil).<br />
 * Returns a text description of any archiving actually done.<br />
 * The subdirectory is created if necessary.
 */
- (NSString*) ecArchive: (NSDate*)when;

/** Send a log message to the server.
 */
- (void) cmdAudit: (NSString*)fmt arguments: (va_list)args;

/** Send a log message to the server by calling the -cmdAudit:arguments: method.
 */
- (void) cmdAudit: (NSString*)fmt, ... NS_FORMAT_FUNCTION(1,2);

/** Handles loss of connection to the server.
 */
- (id) cmdConnectionBecameInvalid: (NSNotification*)notification;

/** Returns the path to the data storage directory used by this process
 * to store files containing persistent information.
 */
- (NSString*) cmdDataDirectory;

/** Send a debug message - as long as the debug mode specified as 'type'
 * is currently set.
 */
- (void) cmdDbg: (NSString*)type msg: (NSString*)fmt arguments: (va_list)args;

/** Send a debug message - as long as the debug mode specified as 'type'
 * is currently set.  Operates by calling the -cmdDbg:msg:arguments: method.
 */
- (void) cmdDbg: (NSString*)type
            msg: (NSString*)fmt, ... NS_FORMAT_FUNCTION(2,3);

/** Send a debug message with debug mode 'basicMode'.<br />
 * Calls the -cmdDbg:msg:arguments: method.
 */
- (void) cmdDebug: (NSString*)fmt arguments: (va_list)args;

/** Send a debug message with debug mode 'basicMode'.<br />
 * Operates by calling the -cmdDebug:arguments: method.
 */
- (void) cmdDebug: (NSString*)fmt, ... NS_FORMAT_FUNCTION(1,2);

/** Called automatically in response to a local NSUserDefaults database change
 * or in response to a configuration update from the Control server.<br />
 * This is automatically called after -cmdUpdate: (even if the user defaults
 * database has not actually changed), in which case the notification
 * argument is nil.<br />
 * An automatic call to this method is (if it does not raise an exception)
 * immediately followed by a call to the -cmdUpdated method.<br />
 * This method deals with the updates for any defaults registered using
 * the +ecRegisterDefault:withTypeText:andHelpText:action:value: method, so
 * if you override this to handle configuration changes, don't forget
 * to call the superclass implementation.<br />
 * If you wish to manage updates from the central database in a specific
 * order, you may wish to override the -cmdUpdate: and/or -cmdUpdated method.
 */
- (void) cmdDefaultsChanged: (NSNotification*)n;

/** Deprecated; do not use.
 */
- (void) cmdError: (NSString*)fmt arguments: (va_list)args;

/** Deprecated; do not use.
 */
- (void) cmdError: (NSString*)fmt, ... NS_FORMAT_FUNCTION(1,2);

/** Flush logging information.
 */
- (void) cmdFlushLogs;

/** This message returns YES if the receiver is intended to be a client
 * of a Command server, and NO if it is a standalone process which does
 * not need to contact the Command server.<br />
 * The default implementation returns YES, but subclasses may override
 * this method to return NO if they do not wish to contact the Command
 * server.
 */
- (BOOL) cmdIsClient;

/** Returns a flag indicating whether this process is currently connected
 * it its Command server.
 */
- (BOOL) cmdIsConnected;

/** Returns YES is the process is running in test mode, NO otherwise.<br />
 * Test mode is defined by the EcTesting user default.
 */
- (BOOL) cmdIsTesting;

/** Closes a file previously obtained using the -cmdLogFile: method.<br />
 * Returns a description of any file archiving done, or nil if the file
 * dis not exist.<br />
 * You should not close a logging handle directly, use this method.
 */
- (NSString*) cmdLogEnd: (NSString*)name;

/** Obtain a file handle for logging purposes.  The file will have the
 * specified name and will be created (if necessary) in the processes
 * logging directory.<br />
 * If there is already a handle for the specified file, this method
 * returns the existing handle rather than creating a new one.<br />
 * Do not close this file handle other than by calling the -cmdLogEnd: method.
 */
- (NSFileHandle*) cmdLogFile: (NSString*)name;

/** Used by the Command server to send messages to your application.
 */
- (void) cmdMesgData: (NSData*)dat from: (NSString*)name;

/** This method is called whenever the Command server sends an instruction
 * for your Command client process to act upon.  Often the command has been
 * entered by an operator and you need to respond with a text string.<br />
 * To implement support for an operator command, you must write a method
 * whose name is of the form -cmdMesgXXX: where XXX is the command (a
 * lowercase string) that the operator will enter.  This method must accept
 * a single NSArray object as an argument and must return a readable string
 * as a result.<br />
 * The array argument will contain the words in the command line entered
 * by the operator (with the command itsself as the first item in the
 * array).<br />
 * There are two special cases ... when the operator types 'help XXX' your
 * method will be called with 'help'as the first element of the array and
 * you should respond with some useful help text, and when the operator
 * simply wants a short description of what the command does, the array
 * argument will be nil (and your method should respond with a short 
 * description of the command).
 */
- (NSString*) cmdMesg: (NSArray*)msg;

/** Attempt to establish connection to Command server etc.
 * Return a proxy to that server if it is available.
 */
- (id) cmdNewServer;

/** Return dictionary giving info about specified operator.  If the
 * password string matches the password of the operator (or the operator
 * has no password) then the dictionary field @"Password" will be set to
 * @"yes", otherwise it will be @"no".
 * If the named operator does not exist, the method will return nil.
 */
- (NSMutableDictionary*)cmdOperator: (NSString*)name password: (NSString*)pass;

/** This method calls -ecWillQuit: with a nil argument, then -ecHandleQuit,
 * and finally calls -ecDidQuit: with the supplied value for the process
 * exit status.<br />
 * Subclasses should override -ecHandleQuit rather than this method.
 */
- (oneway void) cmdQuit: (NSInteger)status;

/** Returns non-zero (a signal) if the process has received a unix signal.
 */
- (int) cmdSignalled;

/** Used to tell your application about central configuration changes.<br />
 * This is called before the NSUserDefaults system is updated with the
 * changes, so you may use it to update internal state in the knowledge
 * that code watching for user defaults change notifications will not
 * have updated yet.<br />
 * The base class implementation is responsible for updating the user
 * defaults system ... so be sure that your implementation calls the
 * superclass implementation (unless you wish to suppress the configuration
 * update) after performing any pre-update operations.<br />
 * You may alter the info dictionary prior to passing it to the superclass
 * implementation if you wish to adjust the new configuration before it
 * takes effect.<br />
 * The order of execution of a configuration update is therefore as follows:
 * <list>
 * <item>Any subclass implementation of -cmdUpdate: is entered.
 * </item>
 * <item>The base implementation of -cmdUpdate: is entered, the stored
 *   configuration is changed as necessary, the user defaults database is
 *   updated.
 * </item>
 * <item>Any subclass implementation of the -cmdDefaultsChanged: method is
 *   entered (either as a result of an NSUserDefaults notification,
 *   or directly after the -cmdUpdate: method).
 * </item>
 * <item>The base implementation of the -cmdDefaultsChanged: method is
 *   entered, and any messages registered using the
 *   +ecRegisterDefault:withTypeText:andHelpText:action:value: method are
 *   sent if the corresponding default value has changed.
 * </item>
 * <item>The base implementation of the -cmdDefaultsChanged: method ends.
 * </item>
 * <item>Any subclass implementation of the -cmdDefaultsChanged: method ends.
 * </item>
 * <item>Once all NSUserDefaults notifications have completed (ie in a
 *   succeeding run loop itermation), the -cmdUpdated method is called.
 * </item>
 * </list>
 * You should usually override the -cmdUpdated method to handle changes
 * to particular defaults values (whether from the central database used
 * by the Control sarver or from local NSUserDefaults changes).<br />
 * Use this method only when you want to check/override changes
 * before they take effect.
 */
- (void) cmdUpdate: (NSMutableDictionary*)info;

/** Used to tell your application about configuration changes (including
 * changes to the NSUserDefaults system).<br />
 * NB. This method will be called even if your implementation of
 * -cmdUpdate: suppresses the actual update.  In this situation this
 * method will find the configuration unchanged since the previous
 * time that it was called.<br />
 * This method is called in a run loop iteration of the main thread after
 * any NSUserDefaults notifications so that it can check the state of things
 * after any code dealing with the notifications has run.<br />
 * The return value of this method is used to control automatic generation
 * of alarms for fatal configuration errors by passing it to the
 * -ecConfigurationError: method.<br />
 * When you implement this method, you must ensure that your implementation
 * calls the superclass implementation, and if that returns a non-nil
 * result, you should pass that on as the return value from your own
 * implementation.
 */
- (NSString*) cmdUpdated;

- (void) log: (NSString*)message type: (EcLogType)t;

/** Send a warning message to the server.
 */
- (void) cmdWarn: (NSString*)fmt arguments: (va_list)args;

/** Send a warning message to the server.
 */
- (void) cmdWarn: (NSString*)fmt, ... NS_FORMAT_FUNCTION(1,2);

/* Return interval between timeouts.
 */
- (NSTimeInterval) cmdInterval;

- (void) cmdUnregister;
/*
 *	All this to unregister from the server.
 */

/** Register a debug mode 'mode'
 */
- (void) setCmdDebug: (NSString*)mode withDescription: (NSString*)desc;

/** Sets the interval between timeouts while the runloop is running.<br />
 * Any value below 0.001 is ignored and 10 is used.<br />
 * Any value above 300 is ignored and 60 is used.<br />
 * The default value is 60 seconds.
 */
- (void) setCmdInterval: (NSTimeInterval)interval;

/** Specify a handler method to be invoked after each timeout to let you
 * perform additional tasks.
 */
- (void) setCmdTimeout: (SEL)sel;

/** Schedule a timeout to go off as soon as possible ... subsequent timeouts
 * go off at the normal interval after that one.<br />
 * This method is called automatically near the start of -ecRun.
 */
- (void) triggerCmdTimeout;

/** Returns the base name for this process (before any instance ID was
 * added). If the process has no instance ID, this returns the same as
 * the -cmdName method.
 */
- (NSString*) cmdBase;

/** Deprecated ... use -cmdDefaults instead.
 */
- (id) cmdConfig: (NSString*)key;

/** Check to see if a debug mode is active.
 */
- (BOOL) cmdDebugMode: (NSString*)mode;

/** Set a particular (named) debug mode to be active or inactive.
 */
- (void) cmdDebugMode: (NSString*)mode active: (BOOL)flag;

/** Returns the NSUserDefaults instance containing the configuration
 * information for this process.
 */
- (NSUserDefaults*) cmdDefaults;

/** Returns the instance ID used for this process, or nil if there is none.
 */
- (NSString*) cmdInstance;

/** Utility method to perform partial (case insensitive) matching of
 * an abbreviated command word (val) to a keyword (key)
 */
- (BOOL) cmdMatch: (NSString*)val toKey: (NSString*)key;

/** Handle with care - this method invokes the cmdMesg... methods.
 */
- (NSString*) cmdMesg: (NSArray*)msg;

/** Returns the name by which this process is known to the Command server.
 */
- (NSString*) cmdName;

/** May be used withing cmdMesg... methods to return formatted text to
 * the Console.
 */
- (void) cmdPrintf: (NSString*)fmt arguments: (va_list)args;

/** May be used withing cmdMesg... methods to return formatted text to
 * the Console.
 */
- (void) cmdPrintf: (NSString*)fmt, ... NS_FORMAT_FUNCTION(1,2);

/** Should be over-ridden to perform extra tidy up on shutdown of the
 * process - should call [super cmdQuit:...] at the end of the method.
 */
- (oneway void) cmdQuit: (NSInteger)status;

/** Used to tell your application about configuration changes (the
 * default implementation merges the configuration change into the
 * NSUserDefaults system and sends the defaults change notification).<br />
 * If you want to deal with configuration changes actively - override
 * this and call [super cmdUpdate:...] to install the changed
 * configuration before anything else.
 * NB.  This method WILL be called before your application is
 * initialised.  Make sure it is safe.
 */
- (void) cmdUpdate: (NSMutableDictionary*)info;

/** This calls the designated initialiser (-initWithDefaults:) passing
 * the results of a call to +ecInitialDefaults as its argument.
 */
- (id) init;

/** [-initWithDefaults:] is the Designated initialiser<br />
 * It adds the defaults specified to the defaults system.<br />
 * It sets the process name to be that specified in the
 * 'EcProgramName' default with an '-id' affix if EcInstance is used
 * to provide an instance id.<br />
 * Moves to the directory (relative to the current user's home directory)
 * given in 'EcHomeDirectory'.<br />
 * If 'EcHomeDirectory' is not present in the defaults system (or is
 * an empty string) then no directory change is done.<br />
 * Please note, that the base implementation of this method may
 * cause other methods (eg -cmdUpdated and -cmdDefaultsChanged:) to be called,
 * so you must take care that when you override those methods, your own
 * implementations do not depend on initialisation having completed.
 * It's therefore recommended that you use 'lazy' initialisation of subclass
 * instance variables as/when they are needed, rather than initialising
 * them in the -initWithDefaults: method.<br />
 * For a normal process, the recommended place to perform initialisation is
 * immediately after initialisation (when configuration information has been
 * retrieved from the Command server), typically by overriding the
 * -ecAwaken method.
 */
- (id) initWithDefaults: (NSDictionary*)defs;

/*
 *	How commands sent to the client via cmdMesg: are invoked -
 *
 *	If a method exists whose name is 'cmdMesgfoo:' where 'foo' is the
 *	command given, then that method is registered when the receiver
 *      is initialised (or -cmdMesgCache is called) and invoked.
 *
 *	The action methods should use the [-cmdPrintf:] method repeatedly to
 *	add text to be returned to the caller.
 *
 *	By default the method 'cmdMesghelp:' is defined to handle the 'help'
 *	command.  To extend the help facility - invoke [super cmdMesghelp:]
 *	at the start of your own implementation.
 *	NB. This method may call any other 'cmdMesg...:' method passing it
 *	an array with the first parameter set to be the string 'help'.
 *	In this case the method should use 'cmdLine:' to return it's help
 *	information.
 *
 *	We also have 'cmdMesgdebug:' to activate debug logging and
 *	'cmdMesgnodebug:' to deactivate it.  The known debug modes may
 *	be extended by using the 'setCmdDebug:withDescription:' method.
 *
 *	'cmdMesgmemory:' is for reporting process memory allocation stats -
 *	it should be overridden to give detailed info.
 *
 *	'cmdMesgstatus:' is for reporting process status information and
 *	should be overridden to give detailed info.
 *
 *	'cmdMesgarchive:' forces an archive of the debug log.
 */
- (void) cmdMesgCache;
- (void) cmdMesgarchive: (NSArray*)msg;
- (void) cmdMesgdebug: (NSArray*)msg;
- (void) cmdMesghelp: (NSArray*)msg;
- (void) cmdMesgmemory: (NSArray*)msg;
- (void) cmdMesgnodebug: (NSArray*)msg;
- (void) cmdMesgstatus: (NSArray*)msg;

/** Returns the system process identifier for the client process.
 */
- (int) processIdentifier;

/**
 * Returns a proxy object to a[n automatically managed] server process.<br />
 * The serverName must previously have been registered using the
 * -addServerToList:for: -addServerToList: method.
 */
- (id) server: (NSString *)serverName;

/**
 * Like -server:, but if the configuration contains a multiple servers,
 * this tries to locate the specific server that is set up to deal with
 * cases where the last two digits of an identifer as as specified.<br />
 * This mechanism permits work to be balanced/shared over up to 100 separate
 * server processes.
 */
- (id) server: (NSString *)serverName forNumber: (NSString*)num;

/**
 * Standard servers return NO to the following.  But if we are using 
 * a multiple/broadcast server, this returns YES.
 */
- (BOOL) isServerMultiple: (NSString *)serverName;

/** This method is called at the start of -ecRun in order to allow a subclass
 * to perform initialisation after configuration information has been received
 * from the Command server, but before the process has become a registered DO
 * server and has entered the run loop with a regular timer set up.<br />
 * This is the recommended location to perform any initialisation of your
 * subclass which needs configuration information from the Command server;
 * override this method to perform your initialisation.<br />
 * If you are not using -ecRun you should call this method explicitly in your
 * own code.<br />
 * The default implementation does nothing but record the fact that it has
 * been called (for -ecDidAwaken).<br />
 */
- (void) ecAwaken;

/** Called to handle fatal configuration problems (or with a nil argument,
 * to clear any outstanding alarm about a configuration problem).<br />
 * If err is not nil, a configuration error alarm will be raised (using the
 * err string as the 'additional text' of the alarm), and the process
 * will be terminated by a call to -cmdQuit: with an argument of 1.<br />
 * If you override this method, you should ensure that your implementation
 * calls the superclass implementation.<br />
 * This method is called automatically with the result of -cmdUpdated when
 * process configuration changes.
 */
- (void) ecConfigurationError: (NSString*)err;

/** Returns YES if the base implementation of -ecAwaken has been called,
 * NO otherwise.  You may use this in conjunction with -ecDoLock and
 * -ecUnLock to ensure that you have thread-safe initialisation of your
 * program (though the locking is normally unnecessary if -ecAwaken is
 * only called from -ecRun).
 */
- (BOOL) ecDidAwaken;

/** Records the timestamp of the latest significant input for this process.
 * If when is nil the current timestmp is used.
 */
- (void) ecHadIP: (NSDate*)when;

/** Records the timestamp of the latest significant output for this process.
 * If when is nil the current timestmp is used.
 */
- (void) ecHadOP: (NSDate*)when;

/** Called on the first timeout of a new day.<br />
 * The argument 'when' is the timestamp of the timeout.<br />
 * If you override this, don't forget to call the superclass
 * implementation in order to perform regular housekeeping.
 */
- (void) ecNewDay: (NSCalendarDate*)when;

/** Called on the first timeout of a new hour.<br />
 * The argument 'when' is the timestamp of the timeout.<br />
 * If you override this, don't forget to call the superclass
 * implementation in order to perform regular housekeeping.
 */
- (void) ecNewHour: (NSCalendarDate*)when;

/** Called on the first timeout of a new minute.<br />
 * The argument 'when' is the timestamp of the timeout.<br />
 * If you override this, don't forget to call the superclass
 * implementation in order to perform regular housekeeping.
 */
- (void) ecNewMinute: (NSCalendarDate*)when;

/** Return heap memory known not to be leaked ... for use in internal
 * monitoring of memory usage.  You should override this to add in any
 * heap store you have used and know is not leaked.<br />
 * When generating warning messages about possible memory leaks,
 * this value is taken into consideration.
 */
- (NSUInteger) ecNotLeaked;

/** This method calls -ecAwaken, establishes the receiver as a DO server,
 * calls -triggerCmdTimeout, and then repeatedly runs the runloop.<br />
 * Returns zero when the run loop completes.<br />
 * Returns one (immediately) if the receiver is transient.<br />
 * Returns two if unable to register as a DO server.<br />
 */
- (int) ecRun;

/** Logs a message iff the process is running in test mode
 * (that is, when EcTesting is set).
 */
- (void) ecTestLog: (NSString*)fmt arguments: (va_list)args;

/** Logs a message iff the process is running in test mode.<br />
 * Operates by calling the -ecTestLog:arguments: method.
 */
- (void) ecTestLog: (NSString*)fmt, ... NS_FORMAT_FUNCTION(1,2);

/** Returns the directory set as the root for files owned by the ECCL user
 */
- (NSString*) ecUserDirectory;

/** Method to log an exception (or other unexpected error) and raise an
 * alarm about it, providing a unique specificProblem value to identify
 * the location in the code, and a perceivedSeverity to let people know
 * how serious the problem is likely to be.  Use EcAlarmSeverityMajor
 * if you really do not know.<br />
 * This method serves a dual purpose, as it generates an alarm to alert
 * people about an unexpected problem, but it also logs detailed information
 * about that problem (including a stack trace) as an aid to debugging and
 * analysis.
 */
- (EcAlarm*) ecException: (NSException*)cause
	 specificProblem: (NSString*)specificProblem
       perceivedSeverity: (EcAlarmSeverity)perceivedSeverity
		 message: (NSString*)format, ... NS_FORMAT_FUNCTION(4,5);

/** Supporting code called by the -ecException:message:... method.
 */
- (EcAlarm*) ecException: (NSException*)cause
	 specificProblem: (NSString*)specificProblem
       perceivedSeverity: (EcAlarmSeverity)perceivedSeverity
		 message: (NSString*)format
	       arguments: (va_list)args;

@end

@interface NSObject (RemoteServerDelegate)
- (void) cmdMadeConnectionToServer: (NSString *)serverName;
- (void) cmdLostConnectionToServer: (NSString *)serverName;
@end

extern EcProcess	*EcProc;	/* Single instance or nil */

extern NSString         *cmdBasicDbg;	/* Debug normal stuff.		*/
extern NSString         *cmdConnectDbg;	/* Debug connection attempts.	*/
extern NSString         *cmdDetailDbg;	/* Debug stuff in more detail.	*/

/* Deprecated synonym for cmdBasicDbg.	*/
extern NSString         *cmdDefaultDbg;


#endif /* INCLUDED_ECPROCESS_H */
