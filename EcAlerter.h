
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
@class	GSMimeSMTPClient;
@class	NSArray;
@class	NSLock;
@class	NSMutableArray;
@class	NSMutableDictionary;
@class	NSString;
@class	NSTimer;


/**
 * <p>This class handles delivery and logging of error and alert messages
 * to the people who should be monitoring the system.  It is used by the
 * Control server (to which all these messages are delivered) and
 * implements a simple rule based mechanism for managing final
 * delivery of the messages.<br />
 * The Control server also feeds alarm events (see [EcAlarm]) into the
 * system as alerts.
 * </p>
 * <p>The configured rules are compared against each message and any
 * actions associated with a matching rule are performed.<br />
 * The matching fields in each rule are -
 * </p>
 * <deflist>
 *   <term>Host</term>
 *   <desc>An extended regular expression to match the name of the host
 *   machine on which the message originated (possibly just the host name).
 *   If this is not specified, messages from any host may match.
 *   </desc>
 *   <term>Server</term>
 *   <desc>An extended regular expression to match the name of the server
 *   process from which the message originated (possibly just the server
 *   name).
 *   If this is not specified, messages from any server may match.
 *   </desc>
 *   <term>Type</term>
 *   <desc>The type of message ... <em>Error</em>, <em>Alert</em>,
 *   <em>Alarm</em>, <em>Raise</em> or <em>Clear</em>.<br />
 *   If this is not specified, messages of any type may match.<br />
 *   NB. Alarm alerts have one of three types.  The type <em>Raise</em>
 *   matches only the initial raising of an alarm while <em>Clear</em>
 *   matches only the final clearing of the alarm.  The type <em>Alarm</em>
 *   will match raising, clearing, and also reminders about the alarm.
 *   </desc>
 *   <term>Component</term>
 *   <desc>For [EcAlarm] messages, this may be used to match messages by
 *   the alarm component.  Specifying an empty value matches only alarms
 *   with an empty component part.
 *   If this is not specified, alarms with any component may match.
 *   </desc>
 *   <term>DurationAbove</term>
 *   <desc>For [EcAlarm] messages, this may be used to match only messages
 *   whose duration in minutes is greater than the supplied integer value.
 *   </desc>
 *   <term>DurationBelow</term>
 *   <desc>For [EcAlarm] messages, this may be used to match only messages
 *   whose duration in minutes is less than the supplied integer value.
 *   </desc>
 *   <term>ReminderAbove</term>
 *   <desc>For [EcAlarm] messages, this may be used to match only messages
 *   whose reminder count is greater than the specified number (a zero or
 *   negative value will match all reminders). 
 *   </desc>
 *   <term>ReminderBelow</term>
 *   <desc>For [EcAlarm] messages, this may be used to match only messages
 *   whose reminder count is less than the specified number (a zero or
 *   negative value will never match). 
 *   </desc>
 *   <term>ReminderInterval</term>
 *   <desc>For [EcAlarm] messages, this may be used to match every Nth
 *   reminder (where the value N is a positive integer).<br />
 *   Setting a value of 1 matches all reminders.<br />
 *   Setting a value of 0 or below never matches.
 *   </desc>
 *   <term>SeverityCode</term>
 *   <desc>For [EcAlarm] messages, this may be used to match an integer alarm
 *   severity code (one of the EcAlarmSeverity enumerated type values).
 *   If this is not specified, messages of any severity (including alerts
 *   which are not alarms) may match.
 *   </desc>
 *   <term>SeverityText</term>
 *   <desc>For [EcAlarm] messages, this may be used to match a string alarm
 *   severity value. The value of this field must be an extended regular
 *   expression pattern.<br />
 *   If this is not specified, messages of any severity may match (including
 *   messages which are not alarms).
 *   </desc>
 *   <term>Pattern</term>
 *   <desc>An extended regular expression used to match the main text
 *   of the message.  See the posix regcomp documentation for details
 *   of enhanced posix regular expressions.  If this is not present,
 *   any message text will match.
 *   </desc>
 *   <term>ActiveFrom</term>
 *   <desc>A date/time specifying the earliest point at which this rule
 *   may match any alarm.  If the current date/time is earlier than
 *   this (optional) value then the rule simply can't match.
 *   </desc>
 *   <term>ActiveTo</term>
 *   <desc>A date/time specifying the latest point at which this rule
 *   may match any alarm.  If the current date/time is later than
 *   this (optional) value then the rule simply can't match.
 *   </desc>
 *   <term>ActiveTimes</term>
 *   <desc>Either a string containing a comma separated list of ranges
 *   of times specified using a 24 hour clock, or a dictionary of such 
 *   strings keyed on the days of the week (Monday, Tuesday, Wednesday,
 *   Thursday, Friday, Saturday, Sunday), possibly with an asterisk used
 *   as the key for a default string to be used for any day not listed. <br />
 *   If a simple string, the list applies to all days of the week
 *   (equivalent to a dictionary containing a single string keyed on
 *   an asterisk).<br />
 *   The times are in HH:MM format or may simply be the hours (HH) with
 *   a minute value of zero implied.<br />
 *   The range separator is a dash/minus, and the range includes the
 *   first value and excludes the second one.<br />
 *   eg. 10:45-11 means that the rule is active in the 15 minute interval
 *   from 10:45 until 11:00 but becomes inactive again at 11:00<br />
 *   The end of each range must be later than the start of the range,
 *   and the starts of each successive range must be later than or equal
 *   to the end of the preceding range.<br />
 *   As a special case the time 24:00 may be used as the end of the
 *   last range in a list.<br />
 *   If this field is simply omitted, the rule is active all day every day.
 *   </desc>
 *   <term>ActiveTimezone</term>
 *   <desc>The formal name of the time zone in which the system checks
 *   active date/time information.  If omitted, the GMT timezone is assumed.
 *   </desc>
 *   <term>Stop</term>
 *   <desc>A boolean (YES or NO) saying whether rule matching should
 *   stop if this rule is matched.  If this is NO (the default) then
 *   after any action associated with this rule is performed, matching
 *   continues at the next rule.<br />
 *   <em>Don't use this option injudiciusly.  Try to write your pattern
 *   matching rules so that most messages match a single rule to map
 *   them to a nice readable version, and also match a default rule to
 *   log full details to the technical team.</em>
 *   </desc>
 *   <term>Tag</term>
 *   <desc>Specifies a tag to be associated with this event during execution
 *   of any subsequent rules (until/unless the event is re-tagged).<br />
 *   The tag actually associated with the event is obtained by treating
 *   the tag value as a template and substituting in any values (as for
 *   the Replace and Rewrite fields).
 *   </desc>
 *   <term>Tagged</term>
 *   <desc>The message is matched if (and only if) it has been tagged
 *   with a value exactly equal to the value of this field.
 *   </desc>
 *   <term>Flush</term>
 *   <desc>A boolean (YES or NO) saying whether stored messages due to
 *   be sent out later should be sent out immediately after processing
 *   this rule.  This is useful in the event that some time critical
 *   message must be sent, but should not normally be used.<br />
 *   As a special case, instead of the boolean value, this may take
 *   the value <em>Email</em> or <em>Sms</em> indicating that a flush
 *   should be performed, but only on the specified type of messages.<br />
 *   <strong>beware</strong> The batching mechanism exists to prevent
 *   a single problem triggering floods of messages.  You should only
 *   override it using <em>Flush</em> where you are <strong>sure</strong>
 *   that messages triggering the flush will be infrequent.
 *   </desc>
 * </deflist>
 * <p>There are two additional fields <em>Extra1</em> and <em>Extra2</em>
 * which are matched against the message.  These patterns do not effect
 * whether the action of the rule is executed or not, but the text matched
 * is made available for substitution into replacement messages.<br />
 * In addition to the full matched text being made available as Extra1/Extra2,
 * any text matching capture groups within the patterns is made available
 * (for up to nine capture groups) as Extra1_N/Extra2_N where N is the
 * position of the capture group (from 1 to 9) within the pattern.<br />
 * A capture group is a sequence starting with '\(' and ending with '\)'.
 * </p>
 * <p>When a match is found a text message based on the alert is normally
 * sent to all the destinations listed in the <em>Email</em> and <em>Sms</em>
 * arrays in the rule, and logged to all the destinations in the <em>Log</em>
 * array.  The alert information is also passed to a method where a subclass
 * may send it to the destinations listed in the <em>other</em> array.<br />
 * Before the text message is sent, the <em>Rewrite</em> field may be used to
 * change the message in the event (rewriting it for the current rule and
 * for all subsequent rules).<br />
 * Once any rewriting has been done the actual message sent out will be
 * the most recently rewritten value (or a value determined by any
 * <em>Replacement</em> field in the current rule).<br />
 * The <em>Replacement</em> field comes in three variants which may be
 * used instead of the general field, depending on the kind of message
 * actually being sent out.  These variants are:<br />
 * <em>EmailReplacement</em>, <em>LogReplacement</em>
 * and <em>SmsReplacement</em>.<br/>
 * Rewrite and a Replacement fields are handled by using the text value of
 * the fields as templates with string values enclosed in curly brackets
 * being substituted as follows -
 * </p>
 * <deflist>
 *   <term>Extra1</term>
 *   <desc>The text in the message matched by the Extra1 pattern (if any)</desc>
 *   <term>Extra1_1 to Extra1_9</term>
 *   <desc>The text from up to nine capture groups within Extra1</desc>
 *   <term>Extra2</term>
 *   <desc>The text in the message matched by the Extra2 pattern (if any)</desc>
 *   <term>Extra2_1 to Extra2_9</term>
 *   <desc>The text from up to nine capture groups within Extra2</desc>
 *   <term>Host</term>
 *   <desc>The host name of the original message</desc>
 *   <term>Server</term>
 *   <desc>The server name of the original message</desc>
 *   <term>Type</term>
 *   <desc>The type of the original message</desc>
 *   <term>Timestamp</term>
 *   <desc>The timestamp of the original message</desc>
 *   <term>Message</term>
 *   <desc>The text of the latest rewritten message or the original
 *   message if no rewriting has been done.</desc>
 *   <term>Match</term>
 *   <desc>The text matched by the latest <em>Pattern</em> if any</desc>
 *   <term>Original</term>
 *   <desc>The text of the original message.</desc>
 *   <term>RuleID</term>
 *   <desc>The identifier (if any) of the matched rule.</desc>
 *   <term>Position</term>
 *   <desc>The position of the matched rule in the list of rules.</desc>
 *   <term>Identifier</term>
 *   <desc>The identifier of any alarm.</desc>
 *   <term>IsClear</term>
 *   <desc>YES if the alert was an alarm clear, NO otherwise.</desc>
 *   <term>SeverityCode</term>
 *   <desc>The numeric severity level of any alarm.
 *   Zero if this alert is not an alarm, five if it is a clear.</desc>
 *   <term>SeverityText</term>
 *   <desc>The text severity level of any alarm.
 *   An empty string if this alert is not an alarm</desc>
 *   <term>AlarmComponent</term>
 *   <desc>The managed object component part if the alert is an alarm</desc>
 *   <term>AlarmProbableCause</term>
 *   <desc>The probable cause if the alert is an alarm</desc>
 *   <term>AlarmSpecificProblem</term>
 *   <desc>The specific problem if the alert is an alarm</desc>
 *   <term>AlarmProposedRepairAction</term>
 *   <desc>The proposed repair action if the alert is an alarm</desc>
 *   <term>AlarmAdditionalText</term>
 *   <desc>The additional text if the alert is an alarm</desc>
 *   <term>Duration</term>
 *   <desc>The duration (minutes) if the event is an alarm.</desc>
 *   <term>Hours</term>
 *   <desc>The number of hours for which an alarm has been active.</desc>
 *   <term>Minutes</term>
 *   <desc>The number of minutes in the hour for.</desc>
 *   <term>Reminder</term>
 *   <desc>The count of alerts previously sent for the alarm represented
 *   by this message (not present if this is not an alarm).</desc>
 * </deflist>
 * <p>The <em>Log</em> array specifies a list of log destinations which are
 * normally treated as filenames (stored in the standard log directory).<br />
 * The values logged in separate fields are the Timestamp, Type, Server, Host,
 * Extra1, Extra2, and full log text (as produced by the Replacement config)
 * is written into the Message field of the table after having been truncated
 * to 200 chars.  Because of the truncation limit, it is recommended that
 * if you are trying to include the original alert {Message} (rather
 * than rewriting it) the Replacement does not include Timestamp,
 * Type, Server, Host, Extra1, Extra2 which are already saved in
 * separate fields, and would take up a lot of the 200 chars, which would
 * be better used to log the actual message.
 *
 * </p>
 * <p>The <em>Sms</em> value is a single phone number or an array of phone
 * numbers to which Sms alerts are to be sent (if the alerter has been
 * subclassed to implement SMS delivery).
 * </p>
 * <p>The <em>Email</em> value is a single email address or an array of
 * email addresses to which email alert messages are to be sent.<br />
 * An address with the prefix '{ResponsibleEmail}' may be used as a
 * special case.  It means that if an alarm has a ResponsibleEmail value
 * set in its userInfo dictionary, that value is used as the address,
 * otherwise the text after '{ResponsibleEmail}' is used as a fallback.<br />
 * An optional <em>Subject</em> field may be present in the rule ...
 * this is used to specify that the email is to be tagged with the given
 * subject line.  This <em>defeats</em> batching of messages in that
 * only messages with the same subject may be batched in the same email.<br />
 * NB. The value of the <em>Subject</em> field is used as a template
 * in the same way as the <em>Replacement</em> fields.
 * </p>
 * <p>The <em>Threaded</em> value is just like the Email value except that
 * it is only used for alarm messages, and the messages sent to the
 * addresses in this array form a chain of linke messages referring
 * back to each other rather than all being versions of the same
 * message.  This may give a better effect for people using mail
 * clients which don't support the message-ID header well.
 * </p>
 * <p>The <em>Other</em> value is a single string or an array of string
 * values that a subclass may treat as destination addresses for sending
 * the alerts via some other mechanism.  In this case no <em>Replacement</em>
 * processing is performed, but the alert information dictionary contains
 * all the information required to generate a message, and additionally
 * contains Throttled set to say whether further alerts are suppressed.
 * </p>
 *
 * <p>Configuration of the alerter is done by the 'Alerter' key in the user
 * defaults system.  The value for this key must be a dictionary configuring
 * the Email setup and the rules as follows:
 * </p>
 * <deflist>
 *   <term>Debug</term>
 *   <desc>A boolean saying whether extra debug data should be logged.
 *     If YES, all outgoing Email messages are logged.</desc>
 *   <term>Quiet</term>
 *   <desc>A boolean saying whether standard debug logs should be suppressed.
 *     If YES, the handling of alarm messages is not logged.</desc>
 *   <term>EmailFrom</term>
 *   <desc>The sender address to use for outgoing alert Email messages.
 *     By default 'alerter@host' where 'host' is the value defined in
 *     the EmailHost config, or any name of the local host.</desc>
 *   <term>EmailHost</term>
 *   <desc>The name or address of the host to use as an Email gateway.
 *     By default the local host.</desc>
 *   <term>EmailPort</term>
 *   <desc>The port number of the MTA to connect to on the EmailHost.
 *     By default this is port 25.</desc>
 *   <term>Rules</term>
 *   <desc>An array of rule dictionaries as defined above.</desc>
 *   <term>Supersede</term>
 *   <desc>A boolean saying whether a clear alert should supersede the
 *     original message or simply act as a new version with the same
 *     message identifier.</desc>
 *   <term>ThrottleAt</term>
 *   <desc>An integer in the range 1 to 3600 saying how many alerts may
 *     be sent to an <em>Other</em> destination per hour.  Any configuration
 *     outside this range results in the default of 12 being used.</desc>
 * </deflist>
 *
 * <p>When an EcAlerter instance is used by a Control server process,
 *  The 'Alerter' configuration dictionary may contain some extra
 *  configuration used to define the way the Control server uses the
 *  alerter.<br />
 *  The Control server integrates the alarm system (EcAlarm etc) with
 *  the alerting system (used by alert and error level logging from
 *  EcProcess) by generating alerter events when alarms of a severity
 *  above a certain threshold are raised, and sending alerter 'clear'
 *  messages when those alarms are cleared.<br />
 *  The Control server may also be configured to generate reminder
 *  alerts when alarms have not been dealt with (cleared) in a timely
 *  manner.  
 * </p>
 * <deflist>
 *   <term>AlertBundle</term>
 *   <desc>An optional class/bundle name for a subclass of EcAlerter
 *     to be loaded into the Control server instead of the standard
 *     EcAlerter class.</desc>
 *   <term>AlertAlarmThreshold</term>
 *   <desc>An integer indicating the threshold at which alarms are to
 *     be mapped to alerts. This is restricted to lie in the range from
 *     EcAlarmSeverityCritical to EcAlarmSeverityWarning and defaults
 *     to the value for EcAlarmSeverityMajor.</desc>
 *   <term>AlertReminderInterval</term>
 *   <desc>An integer number of minutes between generating alerts
 *     reminding about alarms.  If this is negative or not
 *     set then it defaults to zero ... meaning that no reminders
 *     are sent.</desc>
 * </deflist>
 */
@interface	EcAlerter : NSObject
{
  NSArray		*rules; /** Rules for handling alerts */
  NSMutableDictionary	*email; /** Batching Email alerts */
  NSMutableDictionary	*other;	/** Throttling other alerts */
  NSMutableDictionary	*sms;   /** Batching SMS alerts */
  NSTimer		*timer; /** Timer for batch flush */
  NSString		*eBase; /** Sender host name for message ID */
  NSString		*eDflt; /** Default sender address */
  NSString		*eFrom; /** Sender address in use */
  NSString		*eHost; /** Host with SMTP MTA */
  NSString		*ePort; /** Port of SMTP MTA */
  GSMimeSMTPClient	*smtp;  /** Client connection to MTA */
  uint64_t            	sentEmail;
  uint64_t            	failEmail;
  uint64_t            	sentOther;
  uint64_t            	failOther;
  uint64_t            	sentSms;
  uint64_t            	failSms;
  BOOL                  debug;  /** Debug enabled in config */
  BOOL                  supersede;  /** If a clear should replace original */
  BOOL                  eThreaded;  /** alarm reminder emails threaded */
  BOOL                  quiet;  /** Quiet enabled in config */
  NSLock                *lock;  /** Protect rule update */
}

/** Called when user defaults are updated, this fetches the dictionary
 * 'Alerter' from the defaults system, and passes it to the
 * -configureWithDefaults: method.
 */
- (BOOL) configure: (NSNotification*)n;

/** Called to set up or modify the configuration of the alerter.<br />
 * The dictionary c must contain (keyed on <code>Rules</code> an
 * array of dictionaries, each of which provides a rule for
 * delivering some form of alert.<br />
 * Other values in the configuration are used for standard configuration
 * of message delivery to the queueing system etc.
 */
- (BOOL) configureWithDefaults: (NSDictionary*)c;

/** This method is called to flush any batched email messages.
 */
- (void) flushEmail;

/** This method is called to flush any batched SMS messages.
 */
- (void) flushSms;

/** This method handles an audit event.<br />
 * The default implementation does nothing (an audit event is automatically
 * written to the debug log before it reaches this point).
 */
- (void) handleAudit: (NSString*)text
            withHost: (NSString*)hostName
           andServer: (NSString*)serverName
           timestamp: (NSDate*)timestamp;

/** <p>This method handles an error/alert event (an 'error' is one which may
 * be buffered, while an 'alert' must be sent immediately).<br />
 * If the identifier field is non-nil then the event is an alert which is
 * identified by the value of the field.<br />
 * An 'alert' may be due to an alarm (persistent problem), in which case
 * the alarm argument must contain the original alarm details including
 * its perceived severity.  However, the value returned by [EcAlarm-extra]
 * may be used to specify that an event is a clear (the end of the alarm),
 * (the value of the field must be 'Clear').<br />
 * The reminder field counts the number of copies of an alarm previously
 * sent to the alerting system, and should be set to -1 if the alert is
 * not an alarm, reminder of an alarm, or clear of an alarm.<br />
 * The use of an empty string as an identifier is permitted for events which
 * should not be buffered, but which will never be matched by a clear.
 * </p>
 * <p>Each event must consist of text associated with a host name,
 * server name (usually the process on the host) and timestamp.
 * </p>
 * <p>Each alert is matched against each rule in the <em>Rules</em>
 * configuration in turn, and the first match found is used.  The
 * alert is sent to the people listed in the <code>Email</code> and
 * <code>Sms</code> entries in the rule (which may be either single
 * names or arrays of names).
 * </p>
 */
- (void) handleEvent: (NSString*)text
            withHost: (NSString*)hostName
           andServer: (NSString*)serverName
           timestamp: (NSDate*)timestamp
          identifier: (NSString*)identifier
               alarm: (EcAlarm*)alarm
            reminder: (int)reminder;

/** <p>This method handles error/alert/audit messages.  It is able to handle
 * multiple (newline separated messages.
 * </p>
 * <p>Each message must be a line of the format -<br />
 * serverName(hostName): YYYY-MM-DD hh:mm:ss.mmm szzzz type - text
 * </p>
 * <p>Each message is parsed and then the components are passed to the
 * -handleEvent:withHost:andServer:timestamp:identifier:alarm:reminder:
 * method or it the -handleAudit:withHost:andServer:timestamp: method
 * if it is an audit event.
 * </p>
 */
- (void) handleInfo: (NSString*)str;

/** Called by
 * -handleEvent:withHost:andServer:timestamp:identifier:alarm:reminder:
 * to log a message to an array of destinations.
 */
- (void) log: (NSMutableDictionary*)m to: (NSArray*)destinations;

/** Called by
 * -handleEvent:withHost:andServer:timestamp:identifier:alarm:reminder:
 * to pass an alert to an array of destinations.<br />
 * This method uses the EmailReplacement value or the Replacement value
 * from the alert dictionary
 * (or {Server}({Host}): {Timestamp} {Type} - {Message})
 * as a template into which it substitutes other information
 * from that dictionary to build an email message body.<br />
 * The message is actually appended to any cached messages for those
 * destinations ... and the cache is periodically flushed.
 */
- (void) mail: (NSMutableDictionary*)m to: (NSArray*)destinations;

/** Called by
 * -handleEvent:withHost:andServer:timestamp:identifier:alarm:reminder:
 * to pass an alert to a single destination.
 * Should return YES if the alert was passed on to the destination,
 * NO if it was not (the default implementation simply returns NO).
 * The calling code records success/failure stats from this.
 */
- (BOOL) other: (NSMutableDictionary*)m to: (NSString*)destination;

/** Cache a copy of the Rules with modifications to store information
 * so we don't need to regenerate it every time we check a message.
 */
- (void) setRules: (NSArray*)ra;

/** Called to stop the alerter and shut it down.
 */
- (void) shutdown;

/** Called by
 * -handleEvent:withHost:andServer:timestamp:identifier:alarm:reminder:
 * to pass an alert to an array of destinations.<br />
 * This method uses the SmsReplacement value or the Replacement value
 * from the alert dictionary (or {Server}({Host}) {Type}-{Message})
 * as a template into which it substitutes other information
 * from that dictionary to build a text message.<br />
 * The message replaces any cached messages for those
 * destinations (and has a count of the lost messages noted) ... and
 * the cache is periodically flushed.<br />
 * Any replaced message is recorded as a failure, but other than that
 * it is the responsibility of a subclass to override the -smsFlush
 * method and record success/failure stats.
 */
- (void) sms: (NSMutableDictionary*)m to: (NSArray*)destinations;

/** Responsible for the periodic calling of -flushEmail and -flushSms
 */
- (void) timeout: (NSTimer*)t;
@end

