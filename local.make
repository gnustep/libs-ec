#
# This makefile is intended to allow site-local customisation of certain
# hard-coded defaults.  Edit it to suit your system if necessary and place
# it in the directory above the ECCL package.  Then do a 'make clean' to
# remove any existing uncustomised build before you build again.
#

# ECCL_CPPFLAGS ...
#
# EC_DEFAULTS_PREFIX
#   May be used to define an Objective-C string literal to be used as the
#   prefix when looking up keys in the defaults/configuration system.
#
# EC_EFFECTIVE_USER
#   May be used to define an Objective-C string literal to be used to
#   specify the name of the user to run all EcProcess programs.
#
# EC_REGISTRATION_DOMAIN
#   May be used to define a comma separated sequence of keys and values
#   to be used to populate the NSUserDefaults registration domain for the
#   tools built in this package.
#

ECCL_CPPFLAGS += \
	'-DEC_DEFAULTS_PREFIX=@"XX"'\
	'-DEC_EFFECTIVE_USER=@"dummy"'\

# Command_CPPFLAGS ...
# Allow an alternative base class to be specified ...
# The file containing that class will also need to be added to the build/link
# flags if it's not in the standard libraries.
Command_CPPFLAGS += \
	'-DEC_BASE_CLASS=EcCommand'\

# Console_CPPFLAGS ...
# Allow an alternative base class to be specified ...
# The file containing that class will also need to be added to the build/link
# flags if it's not in the standard libraries.
# The EC_LOGIN_NAME flag allows login via the Console to be done by name given
# at a login prompt.  If this is not set the name of the owner of the Console
# process is used. 
Console_CPPFLAGS += \
	'-DEC_BASE_CLASS=EcConsole'\
	'-DEC_LOGIN_NAME=1'\

# Control_CPPFLAGS ...
# Allow an alternative base class to be specified ...
# The file containing that class will also need to be added to the build/link
# flags if it's not in the standard libraries.
# The Control server contains the SNMP alarming support, so we may want to
# define the OID settings for that.
Control_CPPFLAGS += \
	'-DEC_BASE_CLASS=EcControl'\
	'-DEC_REGISTRATION_DOMAIN=@"1.3.6.1.4.1.39543.3.0.1",@"TrapOID",@"1.3.6.1.4.1.39543.1",@"AlarmsOID",@"1.3.6.1.4.1.39543.2",@"ObjectsOID",'\

