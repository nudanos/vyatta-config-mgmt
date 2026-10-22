#
# Module: ConfigMgmt.pm
#
# Copyright (c) 2019-2020, AT&T Intellectual Property.
# All rights reserved.
#
# Copyright (c) 2007-2017 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only
#
package Vyatta::ConfigMgmt;

use strict;
use warnings;

## no critic (Modules::ProhibitAutomaticExportation) reason: this package's scripts take these by default
our @EXPORT = qw(cm_commit_add_log cm_commit_get_log cm_get_archive_dir
  cm_get_lr_conf_file cm_get_lr_state_file
  cm_get_commit_hook_dir cm_write_file cm_read_file
  cm_commit_get_file cm_commit_get_file_name cm_commit_get_file_raw
  cm_get_max_revs cm_get_num_revs cm_get_last_commit_file
  cm_get_last_push_file cm_get_boot_config_file
  cm_get_config_rb cm_get_config_dir
  cm_get_commit_archive_uris
  cm_get_commit_history
);
## use critic
use parent qw(Exporter);

use Vyatta::Config;
use POSIX;
use IO::Zlib;

# the output of a command run without a shell, as backticks gave it
sub command_output {
    my @cmd = @_;
    my $pid = open( my $out, '-|' );
    return if !defined $pid;
    if ( $pid == 0 ) {
        exec { $cmd[0] } @cmd or exit 127;
    }
    my @lines = <$out>;
    close $out;
    return wantarray ? @lines : join q{}, @lines;
}

my $commit_hook_dir = command_output( 'cli-shell-api', 'getPostCommitHookDir' );

# Previously /opt/vyatta/etc/config' but BVNOS switched to the new location
# a while back and while the former is bind mounted to the latter, it allows
# us to call functions here from GRUB only if we use the new location (or
# perhaps if we did some further mounting in the standalone config recovery
# script!)
my $config_dir       = '/config';
my $archive_dir      = "$config_dir/archive";
my $config_file      = "$config_dir/config.boot";
my $lr_conf_file     = "$archive_dir/lr.conf";
my $lr_state_file    = "$archive_dir/lr.state";
my $commit_log_file  = "$archive_dir/commits";
my $last_commit_file = "$archive_dir/config.boot";
my $last_push_file   = "$archive_dir/config.boot-push";
my $config_file_rb   = "$archive_dir/config.boot-rollback";

sub cm_get_boot_config_file {
    return $config_file;
}

sub cm_get_config_rb {
    return $config_file_rb;
}

sub cm_get_commit_hook_dir {
    return "$commit_hook_dir/";
}

sub cm_get_archive_dir {
    return $archive_dir;
}

sub cm_get_config_dir {
    return $config_dir;
}

sub cm_get_lr_conf_file {
    return $lr_conf_file;
}

sub cm_get_lr_state_file {
    return $lr_state_file;
}

sub cm_get_last_commit_file {
    return $last_commit_file;
}

sub cm_get_last_push_file {
    return $last_push_file;
}

sub cm_read_file {
    my ($file) = @_;
    my @lines;
    if ( -e $file ) {
        open( my $FILE, '<', $file ) or die "Error: read $!\n";
        @lines = <$FILE>;
        close($FILE);
        chomp @lines;
    }
    return @lines;
}

sub cm_write_file {
    my ( $file, $data ) = @_;

    open( my $fh, '>', $file ) || die "Couldn't open $file - $!\n";
    print $fh $data;
    close $fh;
    return 1;
}

sub cm_get_max_revs {
    my $config = Vyatta::Config->new();
    $config->setLevel('system config-management');
    my $revs = $config->returnOrigValue('commit-revisions');
    return $revs;
}

sub cm_get_num_revs {
    return -1 if !-e $commit_log_file;
    my @lines    = cm_read_file($commit_log_file);
    my $num_revs = scalar(@lines);
    $num_revs-- if $num_revs > 0;    # rev files start at 0
    return $num_revs;
}

sub cm_commit_add_log {
    my ( $user, $via, $comment ) = @_;

    my $time = time();
    $comment =~ s/[|]/%%/gx;
    $comment =~ s/\n/\\n/gx;

    my $new_line = "|$time|$user|$via|$comment|";
    my @lines    = cm_read_file($commit_log_file);

    my $revs = cm_get_max_revs();
    unshift( @lines, $new_line );    # head push()
    if ( defined $revs and scalar(@lines) > $revs ) {
        $#lines = $revs - 1;
    }
    my $log = join( "\n", @lines );
    cm_write_file( $commit_log_file, $log );
    return;
}

sub cm_get_commit_history {
    my @lines = cm_read_file($commit_log_file);

    my @commit_log = ();
    my $count      = 0;

    my %history   = ();
    my @revisions = ();
    foreach my $line (@lines) {
        my ($fields) = ( $line =~ /^[|](.*)[|]$/x );
        if ( !defined $fields ) {

            # ignore bad lines
            $count++;
            next;
        }
        my %entry = ();
        my ( $time, $user, $via, $comment ) = split( /[|]/x, $fields );
        $comment =~ s/%%/|/gx if defined $comment;
        my $time_str = strftime( "%Y-%m-%dT%H:%M:%S%z", localtime($time) );
        $time_str =~ s/(.*)(\d{2})/$1:$2/x;
        $entry{'comment'}     = $comment if defined $comment;
        $entry{'timestamp'}   = $time_str;
        $entry{'user-id'}     = $user;
        $entry{'revision-id'} = $count;
        $count++;
        push @revisions, \%entry;
    }

    $history{'revision'} = \@revisions;

    return %history;
}

sub cm_commit_get_log {
    my ($brief) = @_;

    my @lines = cm_read_file($commit_log_file);

    my @commit_log = ();
    my $count      = 0;
    foreach my $line (@lines) {
        my ($fields) = ( $line =~ /^[|](.*)[|]$/x );
        if ( !defined $fields ) {
            print "Invalid log format [$line]\n";
            next;
        }
        my ( $time, $user, $via, $comment ) = split( /[|]/x, $fields );
        $comment =~ s/%%/|/gx if defined $comment;
        if ( defined $brief ) {
            my $time_str = strftime( "%Y-%m-%d_%H:%M:%S", localtime($time) );
            $comment = '' if !defined $comment;
            my $new_line = sprintf( "%s %s", $time_str, $user );
            push @commit_log, $new_line;
        }
        else {
            my $time_str = strftime( "%Y-%m-%d %H:%M:%S", localtime($time) );
            my $new_line = sprintf( "%-2s  %s by %s\n", $count, $time_str, $user );
            push @commit_log, $new_line;
            if ( defined $comment && $comment ne '' && $comment ne 'commit' ) {
                push @commit_log, "    $comment\n";
            }
        }
        $count++;
    }
    return @commit_log;
}

sub cm_commit_get_file_name {
    my ($revnum) = @_;

    my $filename = $archive_dir . "/config.boot." . $revnum . ".gz";
    return $filename;
}

sub cm_commit_get_file_internal {
    my ( $revnum, $raw ) = @_;

    my $max_revs = cm_get_max_revs();
    if ( defined $max_revs and $revnum > $max_revs ) {
        print "Error: Invalid config revision number\n";
        exit 1;
    }

    my $filename = cm_commit_get_file_name($revnum);
    die "File [$filename] not found.\n" if !-e $filename;

    if ( defined($raw) ) {
        return command_output( 'cfgread', '-raw', $filename );
    }

    return command_output( 'cfgread', $filename );
}

sub cm_commit_get_file {
    my ($revnum) = @_;

    return cm_commit_get_file_internal($revnum);
}

# Return the commit file, unprocessed, to preserve the release
# version information
sub cm_commit_get_file_raw {
    my ($revnum) = @_;

    return cm_commit_get_file_internal( $revnum, 'raw' );
}

# returns a reference to a hash of arrays.
# key is vrf-name, value is array of uris for that vrf,
# empty vrf-name means default vrf
sub cm_get_commit_archive_uris {
    my $config = Vyatta::Config->new();
    my %uris;

    my $returnValues;
    my $returnValue;
    my $listNodes;
    if ( $config->inSession() ) {
        $returnValues = sub { $config->returnValues(@_) };
        $returnValue  = sub { $config->returnValue(@_) };
        $listNodes    = sub { $config->listNodes(@_) };
    }
    else {
        $returnValues = sub { $config->returnOrigValues(@_) };
        $returnValue  = sub { $config->returnOrigValue(@_) };
        $listNodes    = sub { $config->listOrigNodes(@_) };
    }

    my $getarchives = sub {
        my ($baselevel) = @_;

        $config->setLevel($baselevel);
        my @uris     = $returnValues->('location');
        my @archives = $listNodes->('archive');

        foreach my $arch (@archives) {
            my $pass = $returnValue->("archive $arch password");
            my $user = $returnValue->("archive $arch username");
            my $uri  = $arch;
            if ( defined($user) ) {
                my @words = split m{://}x, $arch, 2;
                $uri = sprintf( "%s://%s:%s@%s", $words[0], $user, $pass, $words[1] );
            }
            push @uris, $uri;
        }
        return @uris;
    };

    my @default_uris = $getarchives->("system config-management commit-archive");

    if (@default_uris) {
        $uris{""} = \@default_uris;
    }

    $config->setLevel('routing routing-instance');
    my @vrfs             = $listNodes->();
    my $vrf_level_format = 'routing routing-instance %s system config-management commit-archive';
    foreach my $vrf (@vrfs) {
        my $vrf_level = sprintf( $vrf_level_format, $vrf );
        my @vrf_uris  = $getarchives->($vrf_level);
        if (@vrf_uris) {
            $uris{$vrf} = \@vrf_uris;
        }
    }
    return \%uris;
}

1;
