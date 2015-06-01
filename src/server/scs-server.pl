#!/usr/bin/perl -w
# @(#) SerialCS
#
# Copyright (C) 2015 Pierre Wieser (see AUTHORS)
#
# SerialCS is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation; either version 2 of
# the License, or (at your option) any later version.
#
# SerialCS is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with SerialCS; if not, see # # <http://www.gnu.org/licenses/>.

use strict;
use Device::SerialPort;
use File::Basename;
use Getopt::Long;
use IO::Socket::INET;
use Proc::Daemon;
use Sys::Syslog qw(:standard :macros);

my $me = basename( $0 );
use constant { true => 1, false => 0 };

# auto-flush on socket
$| = 1;

my $errs = 0;
my $nbopts = $#ARGV;
my $opt_help_def = "no";
my $opt_help = false;
my $opt_version_def = "no";
my $opt_version = false;
my $opt_verbose_def = "no";
my $opt_verbose = false;

my $opt_serial_name_def = "/dev/ttyUSB0";
my $opt_serial_name = $opt_serial_name_def;
my $opt_serial_bauds_def = 19200;
my $opt_serial_bauds = $opt_serial_bauds_def;
my $opt_serial_def = "yes";
my $opt_serial = true;
my $opt_listen_ip_def = "127.0.0.1";
my $opt_listen_ip = $opt_listen_ip_def;
my $opt_listen_port_def = 7777;
my $opt_listen_port = $opt_listen_port_def;
my $opt_serial_timeout_def = 5;
my $opt_serial_timeout = $opt_serial_timeout_def;
my $opt_daemon_def = "yes";
my $opt_daemon = true;

my $socket = undef;
my $serial = undef;
my $background = false;

# ---------------------------------------------------------------------
# standard format the message 
sub msg_format( $ ){
	my $instr = shift;
	my $outstr = "[${me}] ${instr}";
	return( ${outstr} );
}

# ---------------------------------------------------------------------
# Display the specified message, either on stdout or in syslog, 
# depending if we are running in the foreground or in the background 
sub msg( $ ){
	my $str = shift;
	if( $opt_daemon && $background ){
		syslog( LOG_INFO, $str );
	} else {
		print msg_format( $str )."\n";
	}
}

# ---------------------------------------------------------------------
sub msg_help(){
	msg_version();
	print " Usage: $0 [options]
  --[no]help              print this message, and exit [${opt_help_def}]
  --[no]version           print script version, and exit [${opt_version_def}]
  --[no]verbose           run verbosely [$opt_verbose_def]
  --[no]serial            whether to try to talk with a serial bus [${opt_serial_def}]
  --serial=/bus/name      name the serial bus to talk with [${opt_serial_name_def}]
  --baudrate=baudrate     baud rate of the serial bus [${opt_serial_bauds_def}]
  --timeout=timeout       timeout when reading the serial bus [${opt_serial_timeout_def}]
  --listen=ip             IP address to listen to [${opt_listen_ip_def}]
  --port=port             port number to listen to [${opt_listen_port_def}]
  --[no]daemon            fork in the background and run as a daemon [${opt_daemon_def}]
";
}

# ---------------------------------------------------------------------
sub msg_version(){
	print ' SerialCS v2015.1
 Copyright (C) 2015, Pierre Wieser <pwieser@trychlos.org>
';
}

# ---------------------------------------------------------------------
# open the communication stream with the client
# returns the newly created handle
sub open_socket(){

	# create a new TCP socket
	my $socket = new IO::Socket::INET (
		LocalHost => $opt_listen_ip,
		LocalPort => $opt_listen_port,
		Proto => 'tcp',
		Listen => 5,
		Reuse => 1 ) or	die "cannot create socket $!\n";
	msg( "server waiting for client connection on ${opt_listen_ip}:${opt_listen_port}" )
			if $opt_verbose;
	
	return( $socket );
}

# ---------------------------------------------------------------------
# open the communication stream with the serial bus
# handshake with the serial Bus to make sure it is ready
# returns the newly created handle
sub open_serial(){
	
	# create a new socket on the serial bus
	my $serial = Device::SerialPort->new( $opt_serial_name )
			or die "unable to connect to serial port: $!\n";
	$serial->databits( 8 );
	$serial->baudrate( $opt_serial_bauds );
	$serial->parity( "none" );
	$serial->stopbits( true );
	$serial->dtr_active( false );
	$serial->write_settings()
			or die "unable to set serial bus settings: $!\n";
	
	return( $serial );
}

# ---------------------------------------------------------------------
# handle Ctrl-C
sub catch_int(){
	msg( "exiting on Ctrl-C" ) if $opt_verbose;
	$errs = 1;
	catch_term();
}

# ---------------------------------------------------------------------
# program termination
sub catch_term(){
	msg( "exiting with code $errs" ) if $opt_verbose;
	$serial->close() if defined( $serial ); 
	$socket->close() if defined( $socket );
	msg( "SerialCS server terminating..." ) if $opt_verbose || $background;
	exit $errs;
}

# ---------------------------------------------------------------------
# this is the actual code
# isolated in a function to be used by the child when in daemon mode
sub run_server(){

	$socket = open_socket(); 
	$serial = open_serial() if $opt_serial; 
	
	while( true ){
	    # waiting for a new client connection
	    my $client = $socket->accept();
	 
	    # get information about the newly connected client
	    my $client_address = $client->peerhost();
	    my $client_port = $client->peerport();
	    msg( "connection from $client_address:$client_port" ) if $opt_verbose;
	 
	    # read up to 4096 characters from the connected client
	    my $data = "";
	    $client->recv( $data, 4096 );
	    msg( "received data: '$data'" ) if $opt_verbose;
		my $answer = "";

		if( $opt_serial ){
		    my $out_count = $serial->write( "${data}\n" );
		    msg( "${out_count} written to ${opt_serial_name}" ) if $opt_verbose;
		
			# read answer from the serial bus
			# no answer if the timeout expires
			$serial->read_char_time(0);     # don't wait for each character
			$serial->read_const_time(100);  # 100 ms per unfulfilled "read" call
			my $chars = 0;
			my $timeout = $opt_serial_timeout;
			while( $timeout>0 ){
				my ( $count,$saw ) = $serial->read( 255 ); # will read _up to_ 255 chars
				if( $count > 0 ){
					$chars += $count;
					$answer .= $saw;
				} else {
					$timeout--;
				}
		 	}
		} else {
	    	$answer = msg_format( "${data}\n" );
		}
	 
	    # write response data to the connected client
	    $client->send( $answer );
	 
	    # notify client that response has been sent
	    shutdown( $client, true );
	}
}

# =====================================================================
# MAIN
# =====================================================================

$SIG{INT} = \&catch_int;
$SIG{TERM} = \&catch_term;

if( !GetOptions(
	"help!"			=> \$opt_help,
	"version!"		=> \$opt_version,
	"verbose!"		=> \$opt_verbose,
	"serial!"		=> \$opt_serial,
	"name=s"		=> \$opt_serial_name,
	"baudrate=i"	=> \$opt_serial_bauds,
	"timeout=i"		=> \$opt_serial_timeout,
	"listen=s"		=> \$opt_listen_ip,
	"port=i"		=> \$opt_listen_port,
	"daemon!"		=> \$opt_daemon )){
		
		print "try '${0} --help' to get full usage syntax\n";
		$errs = 1;
		exit;
}

$opt_help = true if $nbopts < 0;

if( $opt_help ){
	msg_help();
	exit;
}

if( $opt_version ){
	msg_version();
	exit;
}

my $child_pid = Proc::Daemon::Init() if $opt_daemon;
msg( "child_pid=${child_pid}" ) if $opt_daemon && $opt_verbose;
# specific daemon code
if( !$child_pid ){
	$background = true;
	openlog( $me, "nofatal,pid", LOG_DAEMON );
	msg( "SerialCS server starting..." );
}
run_server() if !$opt_daemon or !$child_pid;

exit;
