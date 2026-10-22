#!/usr/bin/perl
#
# Copyright (c) 2019-2021, AT&T Intellectual Property. All rights reserved.
#
# Copyright (c) 2014, 2017 Brocade Communications Systems, Inc.
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
use Vyatta::Utils;
use Vyatta::RebootReason;
use Sort::Versions;
use Getopt::Long;
use File::Basename;
use File::Copy;
use IPC::Open3 qw(open3);
use URI;
use IO::Prompt;
use Sys::Syslog qw(:standard :macros);
use JSON;
use Time::Piece;

my $commit_uri_script  = '/opt/vyatta/sbin/vyatta-commit-push.pl';
my $commit_revs_script = '/opt/vyatta/sbin/vyatta-commit-revs.pl';

my $commit_hook_dir            = cm_get_commit_hook_dir();
my $archive_dir                = cm_get_archive_dir();
my $config_file                = "$archive_dir/config.boot";
my $lr_conf_file               = cm_get_lr_conf_file();
my $config_dir                 = cm_get_config_dir();
my $confirm_job_file           = "$config_dir/confirm.job";
my $confirmed_commit_job_file  = "$config_dir/confirmed_commit.job";
my $confirmed_persist_job_file = "$config_dir/confirmed_persist.job";
my $revert_file                = "$archive_dir/config.boot.revert.gz";

my $debug = 0;

# The stdout of @cmd, run without a shell, as backticks gave it: its lines
# in list context, one string otherwise.
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

# The lines @cmd writes to stdout and stderr, given $stdin, as
# "echo ... | cmd 2>&1" gave them; none if it cannot run
sub command_merged_output {
    my ( $stdin, @cmd ) = @_;
    my ( $in, $out );
    my $pid = eval { open3( $in, $out, undef, @cmd ) };
    return             if !$pid;
    print {$in} $stdin if defined $stdin;
    close $in;
    my @lines = <$out>;
    close $out;
    waitpid $pid, 0;
    return @lines;
}

# Run @cmd without a shell, its stderr discarded ("cmd 2> /dev/null")
sub run_quietly {
    my @cmd = @_;
    my $pid = fork;
    return if !defined $pid;
    if ( $pid == 0 ) {
        open( STDERR, '>', '/dev/null' ) or exit 127;
        exec { $cmd[0] } @cmd            or exit 127;
    }
    waitpid $pid, 0;
    return $?;
}

# cfgdiff -ctxdiff of the outputs of two bash commands, each given the
# @args as $1..: bash for the <(...) process substitutions
sub cfgdiff {
    my ( $old_cmd, $new_cmd, @args ) = @_;
    return
      scalar command_output( 'bash', '-c', "cfgdiff -ctxdiff <($old_cmd) <($new_cmd)", 'bash',
        @args );
}

sub slurp {
    my ($file) = @_;
    open( my $fh, '<', $file ) or return q{};
    local $/ = undef;
    my $text = <$fh> // q{};
    close $fh;
    return $text;
}

sub get_link {
    my ($path) = @_;

    my $script = basename($path);
    if ( $script =~ /revs/x ) {
        $script = "01" . $script;
    }
    elsif ( $script =~ /push/x ) {
        $script = "02" . $script;
    }
    my $link = $commit_hook_dir . $script;
    return $link;
}

sub check_integer {
    my ($num) = @_;

    if ( $num !~ /^\d+$/x ) {
        print "Invalid number [$num]\n";
        exit 1;
    }
    return 1;
}

sub check_valid_rev {
    my ($rev) = @_;

    check_integer($rev);
    my $num_revs = cm_get_num_revs();
    return 1 if $rev <= $num_revs;
    print "Invalid revision [$rev]\n";
    exit 1;
}

sub parse_at_output {
    my @lines = @_;
    foreach my $line (@lines) {
        if ( $line =~ /error/x ) {
            return ( 1, '', '' );
        }
        elsif ( $line =~ /job[ ](\d+)[ ](.*)$/x ) {
            return ( 0, $1, $2 );
        }
    }
    return ( 1, '', '' );
}

# Schedule $cmd, as configd's user (lu, as configd.service does), with at
# "now" or "now + $mins minutes"; returns at's job number and time, or
# exits on failure
sub schedule {
    my ( $cmd, $mins ) = @_;
    my @when = defined($mins) ? ( 'now', '+', $mins, 'minutes' ) : ('now');
    my @lines =
      command_merged_output( "/opt/vyatta/sbin/lu -user configd \"$cmd\"\n", 'at', @when );
    my ( $err, $job, $time ) = parse_at_output(@lines);
    if ($err) {
        print "Error: unable to schedule rollback\n";
        exit 1;
    }
    return ( $job, $time );
}

# The whole minutes, rounded up past a full minute, that at needs to run
# no sooner than $seconds from now: at only schedules on minute
# boundaries, so up to an extra 59 seconds may be included.
sub at_minutes {
    my ($seconds) = @_;
    my $current_seconds = (localtime)[0];
    return int( ( $seconds + $current_seconds + 60 ) / 60 );
}

sub max_revs_configured {
    my $max_revs = cm_get_max_revs();
    return defined($max_revs) && $max_revs > 0;
}

sub remove_confirm_job_file {
    return if !-e $confirm_job_file;
    my $job = slurp($confirm_job_file);
    chomp $job;

    # Silence 'deleting running job' warning which we will get once sleep
    # kicks in.
    run_quietly( 'atrm', $job );
    unlink $confirm_job_file;
    return;
}

sub remove_confirmed_commit_job_file {
    return if !-e $confirmed_commit_job_file;
    my %cmt = %{ decode_json( slurp($confirmed_commit_job_file) ) };

    run_quietly( 'atrm', $cmt{'job'} );
    unlink $confirmed_commit_job_file;
    return;
}

my (
    $action,  $uri,       $revs,    $revnum,   $minutes, $seconds,
    $persist, $persistid, $session, $filename, $dest
);

sub update_uri {
    print "update-uri\n" if $debug;

    # reference to a hash
    my $uris_ref = cm_get_commit_archive_uris();
    my $link     = get_link($commit_uri_script);
    print "update-uri: %$uris_ref, $link\n" if $debug;
    if ( %$uris_ref && !-e $link ) {
        print "add link [$link]\n" if $debug;

        # the exit status, not system's wait status (exit 256 was exit 0)
        return system( 'ln', '-s', $commit_uri_script, $link ) == 0 ? 0 : 1;
    }
    elsif ( !%$uris_ref ) {
        my $last_push_file = cm_get_last_push_file();
        if ( -e $last_push_file ) {
            print "unlink last_push_file [$last_push_file]\n" if $debug;
            unlink $last_push_file;
        }
        if ( -e $link ) {
            print "remove link [$link]\n" if $debug;
            return system( 'rm', '-f', $link ) == 0 ? 0 : 1;
        }
    }
    return 0;
}

sub valid_uri {
    die "Error: no uri\n"      if !defined $uri;
    print "valid-uri [$uri]\n" if $debug;
    my $u = URI->new($uri);
    return 1 if !defined $u;
    my $scheme = $u->scheme();
    my $path   = $u->path();

    return 1 if !defined $scheme || !defined $path;
    if ( !grep { $scheme eq $_ } qw(tftp ftp scp) ) {
        print "Unsupported URI scheme\n";
        return 1;
    }
    return 0;
}

# Set up commit-revisions: logrotate keeps $revs archived revisions
sub write_lr_conf {
    my ($lr_version_line) = command_merged_output( undef, '/usr/sbin/logrotate' );
    my $lr_version        = parse_version_string( $lr_version_line // q{} );
    my $lr_su_root_conf   = '';

    # since 3.8.0 logrotate ignores group writable directories not owned
    # by the 'root' group if the 'su' option is not configured
    if ( versioncmp( '3.8.0', $lr_version ) < 1 ) {
        $lr_su_root_conf = 'su root vyattacfg';
    }

    my $lr_conf = <<"END";
$config_file {
	rotate $revs
	start 0
	compress
	copy
	$lr_su_root_conf
}
END
    cm_write_file( $lr_conf_file, $lr_conf );
    system( 'chmod', '640', $lr_conf_file );
    return;
}

sub update_revs {
    die "Error: no revs\n"        if !defined $revs;
    print "update-revs [$revs]\n" if $debug;
    check_integer($revs);
    my $link = get_link($commit_revs_script);
    if ( $revs == 0 ) {
        print "remove link [$link]\n" if $debug;
        system( 'rm', '-f', $link );
        return 0;
    }

    if ( !-e $link ) {
        print "add link [$link]\n" if $debug;
        system( 'ln', '-s', $commit_revs_script, $link );
    }
    if ( !-e $archive_dir ) {
        system( 'mkdir', $archive_dir );
        system( 'chgrp', 'vyattacfg', $archive_dir );
        system( 'chmod', '775',       $archive_dir );
    }

    write_lr_conf();
    my $num_revs = cm_get_num_revs();
    if ( !-e "$archive_dir/commits" || $num_revs == 0 ) {

        # store a baseline config
        system( 'touch', "$archive_dir/commits" );
        system( 'chgrp', 'vyattacfg', "$archive_dir/commits" );
        system( 'chmod', '664',       "$archive_dir/commits" );
        system( 'sg', 'vyattacfg',
            "export COMMIT_VIA=init; $commit_revs_script baseline config.boot" );
    }
    return 0;
}

sub show_commit_log {
    print "show-commit-log\n" if $debug;
    if ( !max_revs_configured() ) {
        print "commit-revisions is not configured.\n\n";
    }
    print foreach cm_commit_get_log();
    return 0;
}

sub show_commit_log_brief {
    print "show-commit-log-brief\n" if $debug;
    foreach my $line ( cm_commit_get_log(1) ) {
        $line =~ s/\s/_/gx;
        print $line, ' ';
    }
    return 0;
}

sub show_commit_file {
    die "Error: no revnum\n"             if !defined $revnum;
    print "show-commit-file [$revnum]\n" if $debug;
    check_valid_rev($revnum);
    print scalar cm_commit_get_file($revnum);
    return 0;
}

# "show system commit diff": working against active with no revisions,
# working against a revision, two revisions, or two revisions printed as
# set commands
sub diff {
    print "diff\n" if $debug;
    my $args = $#ARGV;
    if ( $args < 0 ) {
        my $rc = system( 'cli-shell-api', 'sessionChanged' );
        if ( defined $rc && $rc > 0 ) {
            print "No changes between working and active configurations\n";
            return 0;
        }

        # default behavior for showConfig is @ACTIVE vs. @WORKING, so no
        # need to write to a file first
        my $diff =
          cfgdiff( 'cli-shell-api showConfig', 'cli-shell-api showCfg --show-active-only' );
        if ( defined $diff && length($diff) > 0 ) {
            print "$diff";
        }
        else {
            print "No changes between working and active configurations\n";
        }
        return 0;
    }

    # more than three revisions: nothing to compare (as before)
    return 0 if $args > 2;

    my ( $rev1, $rev2 ) = @ARGV;
    check_valid_rev($rev1);
    if ( $args == 0 ) {
        my $diff =
          cfgdiff( 'cli-shell-api showConfig', 'cfgread "$1"', cm_commit_get_file_name($rev1) );
        if ( defined $diff && length($diff) > 0 ) {
            print "$diff";
        }
        else {
            print "No changes between working and " . "revision $rev1 configurations\n";
        }
        return 0;
    }

    check_valid_rev($rev2);
    my $diff = cfgdiff(
        'cfgread "$1"', 'cfgread "$2"',
        cm_commit_get_file_name($rev1),
        cm_commit_get_file_name($rev2)
    );
    if ( !defined $diff || length($diff) == 0 ) {
        print "No changes between revision $rev1 and " . "revision $rev2 configurations\n";
    }
    elsif ( $args == 1 ) {
        print "$diff";
    }
    else {
        foreach my $line ( split( /\n/x, $diff ) ) {
            my @words    = split( q{ }, $line );
            my $elements = scalar(@words);
            my @non_leaf = @words[ 0 .. ( $elements - 2 ) ];
            my $path     = join( ' ', @non_leaf );
            $path =~ s/'//gx;
            print "$path " . $words[ ( $elements - 1 ) ] . "\n";
        }
    }
    return 0;
}

sub commit_confirm {
    die "Error: no minutes\n"           if !defined $minutes;
    print "commit-confirm [$minutes]\n" if $debug;

    # commit-confirm silently confirms any previous pending commit-confirm
    remove_confirm_job_file();

    if ( !max_revs_configured() ) {
        print "commit-revisions is not configured.\n\n";
        return 1;
    }

    check_integer($minutes);
    print "commit will rollback to previous version in $minutes"
      . " minutes unless you enter 'confirm'\n";

    # To acheive to-the-second scheduling of the rollback operation
    # will require an alternative to 'at', or new infrastructure
    # to allow scheduling the rollback to one second accuracy with
    # ability to cancel the scheduled job.
    # Always rollback to immediately preceding config version.
    my ($job) =
      schedule( "/opt/vyatta/sbin/revert_to_previous_config.sh", at_minutes( $minutes * 60 ) );
    cm_write_file( $confirm_job_file, "$job\n" );
    return 0;
}

sub revert_configuration {
    remove_confirm_job_file();
    remove_confirmed_commit_job_file();

    schedule("/opt/vyatta/sbin/revert_confirmed_commit.sh");
    return 0;
}

sub confirmed_commit {
    die "Error: no timeout\n"             if ( !defined $seconds );
    print "confirmed-commit [$seconds]\n" if $debug;
    print "confirmed-commit [$seconds]\n";

    # confirmed-commit silently confirms any previous pending commit-confirm
    remove_confirm_job_file();
    remove_confirmed_commit_job_file();

    if ( !max_revs_configured() ) {
        print "commit-revisions is not configured.\n\n";
        return 1;
    }

    check_integer($seconds);
    print "confirmed commit will be reverted in $seconds"
      . " seconds unless there is a confirming commit\n";

    # Always rollback to immediately preceding config version.
    my ( $job, $time ) =
      schedule( "/opt/vyatta/sbin/revert_confirmed_commit.sh", at_minutes($seconds) );

    $time =~ s/at[ ]//x;
    my $in_fmt  = '%a %b %d %H:%M:%S %Y';
    my $out_fmt = '%Y-%m-%d %H:%M:%S';
    my $date    = Time::Piece->strptime( $time, $in_fmt );
    $time = $date->strftime($out_fmt);

    my %confirmedinfo;
    $confirmedinfo{"job"}     = $job;
    $confirmedinfo{"session"} = $session;
    $confirmedinfo{"time"}    = $time;
    if ( defined $persist ) {
        $confirmedinfo{"persist-id"} = $persist;
    }
    cm_write_file( $confirmed_commit_job_file, encode_json( \%confirmedinfo ) . "\n" );

    # if a revert file already exists, must be a follow-up
    # confirmed-commit, leave in place to ensure config revert
    # reverts back to initial confirmed commit
    if ( !-e $revert_file ) {
        system( 'cp', "$archive_dir/config.boot.1.gz", $revert_file );
    }
    return 0;
}

sub show_confirmed_commit {
    if ( !-e $confirmed_commit_job_file ) {
        print "No pending confirmed commit\n";
        return 0;
    }
    my %cmt = %{ decode_json( slurp($confirmed_commit_job_file) ) };

    print " Session    Revert Time           Persist-Id\n";
    printf "%8s   %20s   %s\n", $cmt{'session'}, $cmt{'time'}, $cmt{'persist-id'} // '';
    return 0;
}

sub confirm {
    if ( defined $persistid && $persistid ne "" ) {
        if ( !-e $confirmed_commit_job_file ) {
            print "No confirmed commit pending\n";
            return 0;
        }
        my %cmt = %{ decode_json( slurp($confirmed_commit_job_file) ) };
        if ( !defined $cmt{"persist-id"} || $persistid ne $cmt{"persist-id"} ) {
            print "persist-id does not match pending confirmed commit\n";
            return 0;
        }
        unlink $revert_file if -e $revert_file;
        remove_confirmed_commit_job_file();
        return 0;
    }

    if ( !-e $confirm_job_file ) {
        print "No confirm pending\n";
        return 0;
    }
    remove_confirm_job_file();
    return 0;
}

sub confirming_commit {
    unlink $revert_file if -e $revert_file;
    remove_confirmed_commit_job_file();
    return 0;
}

# Not an advertised command.
#
# Used to ensure that if we run 'commit' after 'commit-confirm' that we cancel
# the pending rollback without the 'no commit pending' message being printed
# as that will only serve to confuse users.
#
sub confirm_silent {
    remove_confirm_job_file();
    return 0;
}

sub extract_archive {
    if ( !defined($revnum) || !defined($dest) ) {
        die "Error: must define revnum and destination\n";
    }

    check_valid_rev($revnum);
    cm_write_file( $dest, scalar cm_commit_get_file_raw($revnum) );
    return 0;
}

# The config to roll back to, from --revnum (after confirmation) or --file
sub rollback_config {
    my ( $method, $rollback_config );

    if ( defined $revnum ) {
        print "rollback [$revnum]\n" if $debug;
        check_valid_rev($revnum);
        $method = 'revnum';
        if ( !prompt( "Proceed with reboot? [confirm]", -y1d => "y" ) ) {
            print "Cancelling rollback\n";
            exit 0;
        }
        $rollback_config = cm_commit_get_file($revnum);
    }

    if ( defined $filename ) {
        print "rollback [$filename]\n" if $debug;
        if ( !-e $filename ) {
            die "Error: file [$filename] doesn't exist\n";
        }
        if ( defined $method ) {
            die "Error: can only define revnum or file\n";
        }
        $method = 'file';

        # Should have code to validate config, but for now only
        # called internally.  If we later expose this to cli
        # we'll need to prompt for confirmation.
        $rollback_config = join( "\n", cm_read_file($filename) ) . "\n";
    }
    if ( !defined $method ) {
        die "Error: must define either revnum or file\n";
    }
    return $rollback_config;
}

sub rollback {
    my $rollback_config = rollback_config();

    my $boot_config_file = cm_get_boot_config_file();
    my $last_commit_file = cm_get_last_commit_file();
    system( 'cp', $boot_config_file, "$archive_dir/config.boot-prerollback" );
    cm_write_file( $boot_config_file, $rollback_config );
    cm_write_file( $last_commit_file, $rollback_config );    # white lie
    system( 'sg', 'vyattacfg', "$commit_revs_script --rollback=1 rollback/reboot" );
    openlog( $0, "", LOG_USER );
    my $login = getpwuid($<) || "unknown";
    syslog( "warning", "Rollback reboot requested by $login" );
    closelog();
    log_reboot_reason("Rollback reboot: Config rollback requested by $login");
    exec("/sbin/reboot");
}

#
# main
#
Getopt::Long::Configure('pass_through');
GetOptions(
    "action=s"    => \$action,
    "uri=s"       => \$uri,
    "revs=s"      => \$revs,
    "revnum=s"    => \$revnum,
    "minutes=s"   => \$minutes,
    "file=s"      => \$filename,
    "dest=s"      => \$dest,
    "seconds=s"   => \$seconds,
    "persist=s"   => \$persist,
    "persistid=s" => \$persistid,
    "session=s"   => \$session,
);

die "Error: no action\n" if !defined $action;

my %actions = (
    'update-uri'            => \&update_uri,
    'valid-uri'             => \&valid_uri,
    'update-revs'           => \&update_revs,
    'show-commit-log'       => \&show_commit_log,
    'show-commit-log-brief' => \&show_commit_log_brief,
    'show-commit-file'      => \&show_commit_file,
    'diff'                  => \&diff,
    'commit-confirm'        => \&commit_confirm,
    'revert-configuration'  => \&revert_configuration,
    'confirmed-commit'      => \&confirmed_commit,
    'show-confirmed-commit' => \&show_confirmed_commit,
    'confirm'               => \&confirm,
    'confirming-commit'     => \&confirming_commit,
    'confirm-silent'        => \&confirm_silent,
    'extract-archive'       => \&extract_archive,
    'rollback'              => \&rollback,
);

# an unknown action exits 1
exit( $actions{$action} ? $actions{$action}->() : 1 );

# end of file
