#!/usr/bin/perl
#
# Copyright (c) 2019, AT&T Intellectual Property. All rights reserved.
#
# Copyright (c) 2014-2016 Brocade Communications Systems, Inc.
# All Rights Reserved.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2010 Vyatta, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#

use strict;
use warnings;
use lib '/opt/vyatta/share/perl5/';

use Vyatta::Config;
use Vyatta::ConfigMgmt;
use POSIX;
use File::Compare;
use File::Copy;
use URI;
use URI::Escape;
use Sys::Hostname;

my $debug = 0;

print "commit-push: enter\n" if $debug;

sub curl_to {
    my ( $uri, $push_file, $save_file, $vrf ) = @_;
    my $u      = URI->new($uri);
    my $scheme = $u->scheme();
    my $auth   = $u->authority();
    my $path   = $u->path();
    my ( $host, $remote, $user, $pass ) = ( '', '', '', '' );
    if ( defined $auth && $auth =~ /(.*)\@(.*)/x ) {
        $host = $2;
        my $userinfo = uri_unescape($1);
        if ( $userinfo =~ /(.*):(.*)/x ) {
            $user = $1;
            $pass = $2;
        }
        else {
            $user = $userinfo;
        }
    }
    else {
        $host = $auth if defined $auth;
    }
    $remote .= "$scheme://$host";
    $remote .= "$path" if defined $path;

    my $save_url = $remote;
    $save_url .= "/" unless substr( $remote, -1 ) eq "/";
    $save_url .= $save_file;

    # for vyatta-curl-wrapper, run below
    local $ENV{'VYATTA_CURL_USER'} = "$user";
    local $ENV{'VYATTA_CURL_PASS'} = "$pass";

    my @cmd = ( "vyatta-curl-wrapper", "-s", "-T", $push_file, "$save_url" );
    my $rc;
    if ($vrf) {
        print "  vrf:$vrf $remote ";
        unshift( @cmd, ( "chvrf", $vrf ) );
    }
    else {
        print "  $remote ";
    }
    print "cmd [@cmd]\n" if $debug;
    $rc = system(@cmd);
    if ( $rc == 0 ) {
        print " OK\n";
    }
    else {
        print " failed\n";
    }
    return;
}

my $uris_ref = cm_get_commit_archive_uris();

if ( not %$uris_ref ) {
    print "No URI's configured\n";
    exit 0;
}

my $last_push_file = cm_get_last_push_file();
my $tmp_push_file  = "/tmp/config.boot.$$";

my $cmd = 'cli-shell-api showCfg --show-active-only';
system("$cmd > $tmp_push_file");

if ( -e $last_push_file and compare( $last_push_file, $tmp_push_file ) == 0 ) {
    print "commit-push: No differences\n" if $debug;
    exit 0;
}

my $timestamp = strftime( ".%Y%m%d_%H%M%S", localtime );
my $hostname  = hostname();
$hostname = 'vyatta' if !defined $hostname;
my $save_file = "config.boot-$hostname" . $timestamp;

print "Archiving config...\n";
foreach my $vrf ( keys %$uris_ref ) {
    my $vrf_uris_ref = %$uris_ref{$vrf};
    foreach my $uri (@$vrf_uris_ref) {
        curl_to( $uri, $tmp_push_file, $save_file, $vrf );
    }
}
move( $tmp_push_file, $last_push_file );

exit 0;
