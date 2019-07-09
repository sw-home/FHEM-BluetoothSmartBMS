##############################################################################
#
# 70_GenericSmartBMS.pm
#
# A FHEM module to read stats from generic Bluetooth BMS units based around the 
# TI BQ76940 BMS controller with a number of different configurations. 
# The thing they have in common is that they can be used with an Android app called 
# xiaoxiang and with a Windows program called JBDTools.
#
# written 2018 by Stefan Willmeroth <swi@willmeroth.com>
# based on research by Simon Richard Matthews https://github.com/simat/BatteryMonitor
#
##############################################################################
#
# usage:
# define <name> MppSolarPip <host> <port> [<interval> [<timeout>]]
#
# example: 
# define sv GenericSmartBMS raspibox 2001 15000 60
#
# If <interval> is positive, new values are read every <interval> seconds.
# If <interval> is 0, new values are read whenever a get request is called 
# on <name>. The default for <interval> is 300 (i.e. 5 minutes).
#
##############################################################################
#
# Copyright notice
#
# (c) 2018 Stefan Willmeroth <swi@willmeroth.com>
#
# This script is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# The GNU General Public License can be found at
# http://www.gnu.org/copyleft/gpl.html.
#
# This script is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# This copyright notice MUST APPEAR in all copies of the script!
#
##############################################################################

package main;

use strict;
use warnings;

use IO::Socket::INET;

my @GenericSmartBMS_gets = (
            'batteryVoltage',               # V
            'batteryCurrent',               # A
            'batterySoC',                   # % (state of charge)
            'batteryBalance',               # V
            'temp1','temp2',                # C
            'cellVoltage1',                 # V
            'cellVoltage2',                 # V
            'cellVoltage3',                 # V
            'cellVoltage4',                 # V
            'cellVoltage5',                 # V
            'cellVoltage6',                 # V
            'cellVoltage7'                  # V
            );

sub
GenericSmartBMS_Initialize($)
{
  my ($hash) = @_;

  $hash->{DefFn}    = "GenericSmartBMS_Define";
  $hash->{UndefFn}  = "GenericSmartBMS_Undef";
#  $hash->{SetFn}    = "GenericSmartBMS_Set";
  $hash->{GetFn}    = "GenericSmartBMS_Get";
  $hash->{AttrList} = "loglevel:0,1,2,3,4,5 event-on-update-reading event-on-change-reading event-min-interval stateFormat";
}

sub
GenericSmartBMS_Define($$)
{
  my ($hash, $def) = @_;

  my @args = split("[ \t]+", $def);

  if (int(@args) < 3)
  {
    return "GenericSmartBMS_Define: too few arguments. Usage:\n" .
           "define <name> GenericSmartBMS <host> <port> [<interval> [<timeout>]]";
  }

  $hash->{Host} = $args[2];
  $hash->{Port} = $args[3];

  $hash->{Interval} = int(@args) >= 5 ? int($args[4]) : 300;
  $hash->{Timeout}  = int(@args) >= 6 ? int($args[5]) : 4;

  # config variables
  $hash->{Invalid}    = -1;    # default value for invalid readings

  GenericSmartBMS_Update($hash);

  Log3 $hash->{NAME}, 2, "$hash->{NAME} will read from GenericSmartBMS at $hash->{Host}:$hash->{Port} " .
         ($hash->{Interval} ? "every $hash->{Interval} seconds" : "for every 'get $hash->{NAME} <key>' request");

  return undef;
}

sub
GenericSmartBMS_Update($)
{
  my ($hash) = @_;

  if ($hash->{Interval} > 0) {
    InternalTimer(gettimeofday() + $hash->{Interval}, "GenericSmartBMS_Update", $hash, 0);
  }

  Log3 $hash->{NAME}, 4, "$hash->{NAME} tries to contact BMS at $hash->{Host}:$hash->{Port}";

  my $success = 0;
  my %readings = ();
  my @vals;

  eval {
    local $SIG{ALRM} = sub { die 'timeout'; };
    alarm $hash->{Timeout};

    my $socket = IO::Socket::INET->new(PeerAddr => $hash->{Host},
                                         PeerPort => $hash->{Port},
                                         Timeout  => $hash->{Timeout});

    if ($socket and $socket->connected())
    {
      $socket->autoflush(1);

      # request battery pack data
      my $res = GenericSmartBMS_Request($hash, $socket, "\xDD\xA5\x03\x00\xFF\xFD\x77");
      my $l = length($res);
      if ($res and ord($res) == 0xDD and
            ord(substr($res,1)) == 0x03 and
            ord(substr($res,$l-1)) == 0x77 and
            unpack("n",substr($res,$l-3,2)) == GenericSmartBMS_crc(substr($res,2,$l-5)) and
            length($res) == 7+unpack("n",substr($res,2,2)))
      {
        $readings{batteryVoltage} = unpack("n",substr($res,4,2))/100;
        $readings{batteryCurrent} = unpack("n!",substr($res,4+2,2))/100;
        $readings{batteryBalance} = unpack("n",substr($res,4+12,2));
        $readings{batterySoC} = ord(substr($res,4+19));

        my $t1 = GenericSmartBMS_Temp(unpack("n",substr($res,4+23,2)));
        my $t2 = GenericSmartBMS_Temp(unpack("n",substr($res,4+25,2)));
        $readings{temp1} = $t1 if defined $t1;
        $readings{temp2} = $t2 if defined $t2;

      } else {
        Log3 $hash->{NAME}, 4, "Invalid BMS response: " . unpack( 'H*', $res);
      }

      # request cell voltages
      $res = GenericSmartBMS_Request($hash, $socket, "\xDD\xA5\x04\x00\xFF\xFC\x77");
      $l = length($res);
      if ($res and
            ord($res) == 0xDD and
            ord(substr($res,1)) == 0x04 and
            ord(substr($res,$l-1)) == 0x77 and
            unpack("n",substr($res,$l-3,2)) == GenericSmartBMS_crc(substr($res,2,$l-5)) and
            length($res) == 7+unpack("n",substr($res,2,2)))
      {
        for (my $i=0;$i<7;$i++) {
          my $v = unpack("n",substr($res,4+$i*2,2));
          $readings{"cellVoltage".($i+1)}=$v/1000;
        }
        $success = 1;

      } else {
        Log3 $hash->{NAME}, 4, "Invalid BMS response: " . unpack( 'H*', $res);
      }
    } # socket okay
  }; # eval
  alarm 0;

  # update Readings
  readingsBeginUpdate($hash);
  if ($success) {
    Log3 $hash->{NAME}, 4, "$hash->{NAME} got fresh values from GenericSmartBMS";
    for my $get (@GenericSmartBMS_gets)
    {
      readingsBulkUpdate($hash, $get, $readings{$get});
    }
    readingsBulkUpdate($hash, "state", "Online");
  } else {
    Log3 $hash->{NAME}, 4, "$hash->{NAME} was unable to get fresh values from GenericSmartBMS";
    readingsBulkUpdate($hash, "state", "Offline");
  }
  readingsEndUpdate($hash, $init_done);

  return undef;
}

sub GenericSmartBMS_Temp($) {
  my ($temp) = @_;
  return undef if ($temp < 2731 || $temp > 3731);
  my $last = substr($temp,-1);
  my $base = substr($temp,0,3);
  return ((($base+2)*10+7) - $temp + ($base*10+6) - 2731) / 10 if ($last > 7);
  return ((($base+1)*10+7) - $temp + (($base-1)*10+6) - 2731) / 10 if ($last < 7);
  return undef;
}

sub GenericSmartBMS_crc($) {
  my ($str) = @_;
  my $crc = 0x10000;
  for (my $i=0;$i < length($str);$i++) {
    $crc = $crc - ord(substr($str,$i));
  }
  return $crc;
}

sub
GenericSmartBMS_Request($@)
{
  my ($hash, $socket, $cmd) = @_;

  Log3 $hash->{NAME}, 4, "BMS command: " . unpack( 'H*', $cmd );
  $socket->send($cmd);

  return GenericSmartBMS_Reread($hash, $socket);
}

sub
GenericSmartBMS_Reread($@)
{
  my ($hash, $socket) = @_;

  my $singlechar;
  my $res;

  do {
      $socket->read($singlechar,1);
      $res = $res . $singlechar;
  } while (ord($singlechar) != 0x77);

  Log3 $hash->{NAME}, 4, "BMS returned: " . unpack( 'H*', $res );
  return $res;
}

sub
GenericSmartBMS_Get($@)
{
  my ($hash, @args) = @_;

  return 'GenericSmartBMS_Get needs two arguments' if (@args != 2);

  GenericSmartBMS_Update($hash) unless $hash->{Interval};

  my $get = $args[1];
  my $val = $hash->{Invalid};

  if (defined($hash->{READINGS}{$get})) {
    $val = $hash->{READINGS}{$get}{VAL};
  } else {
    return "GenericSmartBMS_Get: no such reading: $get";
  }

  Log3 $hash->{NAME}, 3, "$args[0] $get => $val";

  return $val;
}

sub
GenericSmartBMS_Undef($$)
{
  my ($hash, $args) = @_;

  RemoveInternalTimer($hash) if $hash->{Interval};

  return undef;
}

1;

