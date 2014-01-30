#!/usr/bin/perl
#
# codename "Valen": a Wesnoth facilities status page
# valen.pl: Web status poll script
#
# Copyright (C) 2012 - 2014 by Ignacio Riquelme Morelle <shadowm2006@gmail.com>
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice is present in all copies.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
# STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
# IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#

#
# Usage:
#   valen.pl [-d | --debug] report_file_path
#

use 5.010;
use strict;
use warnings;

package valen;

use JSON;
use LWP::UserAgent;
use Socket;

$| = 1;

my $VERSION = '0.0.2';

my $debug = 0;

################################################################################
#                                CONFIGURATION                                 #
################################################################################

my %config = (
	output_path				=> '/var/lib/valen/report.json',
);

use constant {
	IP_ASHEVIERE		=> '65.18.193.12',		# asheviere.wesnoth.org
	IP_BALDRAS			=> '144.76.5.6',		# baldras.wesnoth.org
	IP_GONZO			=> '193.7.178.1',		# server2.wesnoth.org [gonzo.dicp.de]
	IP_BASILIC			=> '212.85.158.134',	# server3.wesnoth.org [basilic.tuxfamily.org]
	IP_AI0867			=> '109.237.218.218',	# status.wesnoth.org [ai0867.net]
};

use constant {
	PROBE_NONE				=>  0,
	PROBE_HTTP				=>  1,
	PROBE_GZC_CAMPAIGND		=> 10,
	PROBE_GZC_WESNOTHD		=> 11,
};

my %campaignd_standard_ports = (
	'1.8'   => 15001,
	'1.10'  => 15002,
	'1.11'  => 15006,
	'trunk' => 15004,
);

my %wesnothd_standard_ports = (
	'1.8'   => 14998,
	'1.10'  => 14999,
	'1.11'  => 14997,
	'trunk' => 15000,
);

my @facilities = (
	'wesnoth.org', {
		ip					=> IP_BALDRAS,
		desc				=> "Main server",
		hidden				=> 1,
		probe				=> PROBE_NONE,
	},
	'www.wesnoth.org', {
		ip					=> IP_BALDRAS,
		desc				=> "Wesnoth.org HTTP server and front page",
		probe				=> PROBE_HTTP,
	},
	'wiki.wesnoth.org', {
		ip					=> IP_BALDRAS,
		desc				=> "Wesnoth.org wiki (MediaWiki)",
		stats_url			=> "http://wiki.wesnoth.org/Special:Statistics",
		probe				=> PROBE_HTTP,
	},
	'forums.wesnoth.org', {
		ip					=> IP_BALDRAS,
		desc				=> "Wesnoth.org forums board (phpBB)",
		probe				=> PROBE_HTTP,
	},
	'add-ons.wesnoth.org', {
		ip					=> IP_BALDRAS,
		desc				=> "Official add-ons server instances (campaignd)",
		probe				=> PROBE_GZC_CAMPAIGND,
		instances			=> { %campaignd_standard_ports },
	},
	'server.wesnoth.org', {
		ip					=> IP_BALDRAS,
		desc				=> "Official main multiplayer games server (wesnothd)",
		stats_url			=> "http://wesnothd.wesnoth.org/",
		probe				=> PROBE_GZC_WESNOTHD,
		instances			=> { '1.6' => 14995, %wesnothd_standard_ports },
	},
	'server2.wesnoth.org', {
		ip					=> IP_GONZO,
		desc				=> "Official alternate multiplayer games server #2 (wesnothd)",
		probe				=> PROBE_GZC_WESNOTHD,
		instances			=> { %wesnothd_standard_ports },
	},
	'server3.wesnoth.org', {
		ip					=> IP_BASILIC,
		desc				=> "Official alternate multiplayer games server #3 (wesnothd)",
		probe				=> PROBE_GZC_WESNOTHD,
		instances			=> { %wesnothd_standard_ports },
	},
	'status.wesnoth.org', {
		ip					=> IP_AI0867,
		desc				=> "Wesnoth.org status monitoring facility",
		probe				=> PROBE_NONE,
	},
);

################################################################################
#                                   LIBRARY                                    #
################################################################################

# Various timeouts (in seconds).
use constant {
	HTTP_TIMEOUT			=> 10,
	GZCLIENT_TIMEOUT		=> 10,
};

# A status of 0 indicates that the facility isn't working properly;
# 1 indicates that it is. A status of 2 indicates that the facility
# is not completely functional, but still working. A status of -1
# indicates that the test failed for some other reason (e.g. the
# add-ons client isn't installed on this machine).
use constant {
	STATUS_UNKNOWN			=> -1,
	STATUS_FAIL				=>  0,
	STATUS_GOOD				=>  1,
	STATUS_INCOMPLETE		=>  2,
	STATUS_DNS_IS_BAD		=>  3,
};

sub dprint { print @_ if $debug }

sub dwarn { warn @_ if $debug }

################################################################
# Small operation timer used to check how much time individual #
# operations took when $debug is set to 1.                     #
################################################################

{
	package otimer;

	use Time::HiRes qw(gettimeofday tv_interval);

	sub new
	{
		my $class = shift;
		my $self = { _start_ts => [gettimeofday()] };

		bless $self, $class;

		return $self;
	}

	sub ellapsed
	{
		my ($self) = @_;

		return tv_interval($self->{_start_ts}, [gettimeofday()]);
	}

	sub DESTROY
	{
		my ($self) = @_;

		printf("<took %.2f seconds>\n", $self->ellapsed())
			if $debug;
	}
}

################################################################
# A minimalistic networked gzip packets client.                #
################################################################

{
	package gzclient;

	use IO::Socket;

	use IO::Compress::Gzip qw(gzip $GzipError);
	use IO::Uncompress::Gunzip qw(gunzip $GunzipError);

	##
	# Constructor.
	##
	sub new
	{
		my ($class, $addr, $port) = @_;

		my $self = {
			_addr		=> $addr,
			_port		=> $port,
			_timeout	=> valen::GZCLIENT_TIMEOUT,
			_sock		=> 0,
			_conn_num	=> 0,
		};

		bless $self, $class;

		return $self->connect() ? $self : undef;
	}

	##
	# Print a warning on stderr when debug mode is active.
	##
	sub dwarn
	{
		my $self = shift;

		warn ("gzclient (" . $self->{_addr} . ':' . $self->{_port} . ') ', @_)
			if $debug;
	}

	##
	# Print a diagnostic message on stdout when debug mode is active.
	##
	sub dprint
	{
		my $self = shift;

		print STDOUT ("gzclient (" . $self->{_addr} . ':' . $self->{_port} . ') ', @_)
			if $debug;
	}

	##
	# Establish connection.
	#
	# This is called by the constructor and does nothing once the
	# connection is already established.
	##
	sub connect
	{
		my $self = shift;

		return if $self->{_sock};

		my $sock = new IO::Socket::INET(
				PeerAddr => $self->{_addr}, PeerPort => $self->{_port},
				Proto => 'tcp', Timeout => $self->{_timeout});

		if(!$sock) {
			$self->dwarn("could not establish connection\n");
			return 0;
		}

		# The Timeout option in the IO::Socket::INET constructor
		# is only good when establishing the connection, so we
		# must set read/send timeouts ourselves.

		my $timeout_timeval = pack('L!L!', $self->{_timeout}, 0);

		unless($sock->sockopt(SO_SNDTIMEO, $timeout_timeval) &&
			$sock->sockopt(SO_RCVTIMEO, $timeout_timeval)) {
			$self->dwarn("socket layer smells funny\n");
			return 0;
		}

		#
		# Initial handshake.
		#

		if(!print $sock pack('N', 0)) {
			$self->dwarn("could not send to server\n");
			return 0;
		}

		my $buf = '';
		my $nread = read $sock, $buf, 4;

		if(!defined $nread) {
			$self->dwarn("handshake failed: $!\n");
			return 0;
		} elsif($nread != 4) {
			$self->dwarn("short read during handshake\n");
			return 0;
		}

		my $conn_num = unpack('N', $buf);

		$self->dprint("handshake succeeded ($conn_num)\n");

		$self->{_sock} = $sock;
		$self->{_conn_num} = $conn_num;

		return 1;
	}

	##
	# Read a compressed packet.
	##
	sub recv
	{
		my $self = shift;

		$self->{_sock} or return undef;

		my $buf = '';
		my $nread = read($self->{_sock}, $buf, 4);

		if(!defined $nread || !$nread) {
			$self->dwarn("connection broke during read\n");
			return undef;
		}

		if($nread != 4) {
			$self->dwarn("read error\n");
			return undef;
		}

		#
		# Read the compressed packet.
		#

		$nread = 0;

		my $zpacket = '';
		my $zpacket_length = unpack('N', $buf);
		my $zread_length = 0;

		while($zread_length < $zpacket_length) {
			my $zremaining_length = $zpacket_length - $nread;

			$buf = '';

			$nread = read($self->{_sock}, $buf, $zremaining_length);
			$zread_length += $nread
				if $nread == length($buf);

			$zpacket .= $buf;
		}

		my $text = '';

		unless(gunzip(\$zpacket => \$text)) {
			$self->dwarn("gunzip failed: $GunzipError\n");
			return undef;
		}

		return $text;
	}

	##
	# Send a compressed packet.
	##
	sub send
	{
		my $self = shift;
		my $text = shift;

		$self->{_sock} or return undef;

		my $ztext = '';

		unless(gzip \$text => \$ztext) {
			$self->dwarn("gzip failed: $GzipError\n");
			return 0;
		}

		if(!print { $self->{_sock} } pack('N', length $ztext) . $ztext) {
			$self->dwarn("could not send compressed packet to server\n");
			return 0;
		}

		return 1;
	}
}

sub write_hash_to_file(\%$)
{
	my ($hash_ref, $out_path) = @_;

	# In order to avoid someone else reading $out_path mid-write,
	# write the intermediate results to a new file that will later
	# clobber $out_path.
	my $int_path = $out_path . '.new';

	open(my $out, '>', $int_path)
		or die("Could not open '" . $int_path . "' for writing: " . $!);

	# Save a timestamp for reference when reporting in the front-end.
	my $envelope = { ts => time(), facilities => $hash_ref };

	#print $out encode_json($hash_ref);
	print $out to_json($envelope, { utf8 => 1, pretty => 1 });

	close $out;

	rename($int_path, $out_path)
		or die("Could not replace '" . $out_path . "': " . $!);
}

sub check_url($;$)
{
	my $otimer = otimer->new();

	my ($url, $http_host) = @_;

	my $ua = LWP::UserAgent->new();

	$ua->agent(sprintf('codename Valen/%s %s', $VERSION, $ua->_agent()));
	# 30 seconds should really be enough in the worst case.
	$ua->timeout(HTTP_TIMEOUT);
	# Don't follow redirects, they are used by the wesnoth.org admins to
	# redirect users to status pages when things break.
	$ua->max_redirect(0);
	# A maximum of 100 KiB is a stretch, but whatever.
	$ua->max_size(102400);
	# No, we don't really want any extra processing here, just the HTTP
	# response code.
	$ua->parse_head(0);
	# Set the HTTP hostname explicitly in case we are querying a plain IP
	# address.
	$ua->default_header('Host' => $http_host) if defined $http_host;

	my $resp = $ua->head($url);

	# Really, we should only get 200 OK unless there's something unusual
	# going on with the HTTP server.
	# MediaWiki also throws a 301 on the / path because it wants to show
	# a permalink for the user under any circumstances or something.
	my $ret = $resp->code() == 200 || $resp->code() == 301 ? STATUS_GOOD : STATUS_FAIL;

	dprint "HTTP ($url): $ret (" . $resp->status_line() . ")\n";

	return $ret;
}

sub empty_wml_node($)
{
	return '[' . $_[0] . "]\n[/" . $_[0] . "]\n";
}

sub check_campaignd($$)
{
	my $addr = shift;
	my $port = shift;

	my $client = gzclient->new($addr, $port);

	if(!$client) {
		dwarn "campaignd ($addr:$port): gzclient connection failed\n";
		return STATUS_FAIL;
	}

	if(!$client->send(empty_wml_node 'request_terms')) {
		dwarn "campaignd ($addr:$port): could not send [request_terms] probe\n";
	}

	my $wml = $client->recv();

	if(!defined $wml) {
		dwarn "campaignd ($addr:$port): no server response\n";
		return STATUS_FAIL;
	}

	if($wml !~ m|^\[message]\n\s*message=\".*\"\n\[/message\]\n|) {
		dwarn "campaignd ($addr:$port): server response is not a proper [message]\n";
		dwarn "--cut here--\n" . $wml . "--cut here--\n";
		return STATUS_FAIL;
	}

	dprint "campaignd ($addr:$port): OK\n";

	return STATUS_GOOD;
}

sub check_wesnothd($$)
{
	my $otimer = otimer->new();

	my $addr = shift;
	my $port = shift;

	my $client = gzclient->new($addr, $port);

	if(!$client) {
		dwarn "wesnothd ($addr:$port): gzclient connection failed\n";
		return STATUS_FAIL;
	}

	my $wml = $client->recv();

	if(!defined $wml) {
		dwarn "wesnothd ($addr:$port): no server response\n";
		return STATUS_FAIL;
	}

	# We now have the WML. According to Gambit and the MultiplayerServerWML
	# wiki page, we should get an optional empty [version] WML node (asking
	# us to send our own [version] response) after the handshake. It is not
	# currently known what the response would be when the server doesn't
	# care about the client version, but since the normal next step is the
	# [mustlogin] request, that's probably the alternative in this case
	# too.
	if($wml !~ m.^\[(version|mustlogin)\]\n\[/\1\]\n.) {
		dwarn "wesnothd ($addr:$port): got something other than [version] or [mustlogin]\n";
		dwarn "--cut here--\n" . $wml . "--cut here--\n";
		return 0;
	}

	dprint "wesnothd ($addr:$port): OK ($1)\n";

	return STATUS_GOOD;
}

################################################################################
#                                                                              #
# COMMAND LINE CONFIGURATION                                                   #
#                                                                              #
################################################################################

foreach(@ARGV) {
	if($_ eq '--debug' || $_ eq '-d') {
		$debug = 1;
	}
}

if(@ARGV && $ARGV[-1] !~ m{^-+}) {
	$config{output_path} = $ARGV[-1];
}


sub drep($$$)
{
	my ($hostname, $operation, $text) = @_;
	dprint "*** $hostname [$operation]: $text\n";
}

sub hvalue($$$)
{
	my ($hash_ref, $key, $default) = @_;

	defined $default or $default = '';

	defined($hash_ref) &&
	exists($hash_ref->{$key}) &&
	defined($hash_ref->{$key})
		? $hash_ref->{$key}
		: $default;
}


my %status;

for(my $k = 0; $k < @facilities; ++$k)
{
	# The @facilities structure is an array of host/struct pairs in order to
	# keep it sorted a certain way without adding a 'priority' struct item or
	# such, so we need to grab the element pair and advance the iteration by
	# two each time.
	my ($host, $def) = @facilities[$k++, $k];

	my $st = {
		dns			=> STATUS_UNKNOWN,
		dns_ip		=> undef,
		# Information for the front-end.
		hidden		=> hvalue($def, 'hidden', 0),
		name		=> hvalue($def, 'name', $host),
		desc		=> hvalue($def, 'desc', 'No description provided.'),
		expected_ip	=> hvalue($def, 'ip', '0.0.0.0'),
		stats_url	=> hvalue($def, 'stats_url', ''),
	};

	#
	# DNS CHECK.
	#

	$st->{dns} = STATUS_UNKNOWN;

	my (undef, undef, undef, undef, @addr) = gethostbyname($host);

	if(@addr > 0) {
		my $ip = inet_ntoa($addr[0]);
		$st->{dns} = $ip ne $def->{ip} ? STATUS_DNS_IS_BAD : STATUS_GOOD;
		$st->{dns_ip} = $ip;
	} else {
		$st->{dns} = STATUS_FAIL;
	}

	drep($host, "DNS", $st->{dns} . " (expected " . $st->{expected_ip} . ", got " . hvalue($st, 'dns_ip', '<NXDOMAIN>') .")");

	#
	# FACILITY PROBING.
	#

	if($def->{probe} != PROBE_NONE) {
		my ($inhost, $inhttphost) = ();

		if($st->{dns} == STATUS_GOOD) {
			$inhost = $host;
		} else {
			$inhost = $def->{ip};
			$inhttphost = $host;
			drep($host, 'PROBE', 'DNS is bad, proceeding with IP and hostname from configuration: ' . $inhost . ' ' . $inhttphost);
		}

		# Create an artificial stand-alone instance if the facility doesn't have
		# multiple instances, so we don't need to have two versions of the probe
		# selection and call below.

		my $instances = exists($def->{instances})
			? $def->{instances}
			: { '*' => '*' };

		foreach my $iname (keys %$instances)
		{
			my $instatus = STATUS_UNKNOWN;
			my $inport = $instances->{$iname}; # Ignored for non GZC probes.

			if($def->{probe} == PROBE_HTTP) {
				$instatus = check_url('http://' . $inhost . '/', $inhttphost);
			}
			elsif($def->{probe} == PROBE_GZC_WESNOTHD) {
				$instatus = check_wesnothd($inhost, $inport);
			}
			elsif($def->{probe} == PROBE_GZC_CAMPAIGND) {
				$instatus = check_campaignd($inhost, $inport);
			}
			else {
				drep($host, 'PROBE', 'Invalid probe type ' . $def->{probe});
			}

			if($iname eq '*') {
				$st->{status} = $instatus;
			} else {
				if(!exists $st->{instances}) {
					$st->{instances} = {};
				}

				$st->{instances}->{$iname}->{status} = $instatus;
				$st->{instances}->{$iname}->{port} = $inport;
			}
		}
	}

	$status{$host} = $st;
}

################################################################################
#                                                                              #
# FINISHING                                                                    #
#                                                                              #
################################################################################

dprint "*** Writing report to " . $config{output_path} . "\n";

write_hash_to_file(%status, $config{output_path});

dprint "*** Finished\n";

# kate: indent-mode normal; encoding utf-8;
