#!/usr/bin/perl
# SPDX-License-Identifier: GPL-2.0-only
#
# vyatta-config-mgmt.pl: what each action prints, exits with, asks the
# stubbed commands (actions/bin) to do and leaves under a test /config, as
# recorded from the script before the 2026 lint fixes (UPDATE_GOLDEN=1
# re-records). Vyatta::ConfigMgmt is the port's own, with /config moved to
# a temporary directory; CM_SCRIPT and CM_MODULE run other versions.

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Find;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use IO::Compress::Gzip qw(gzip $GzipError);
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use JSON;
use Test::More;

my $t      = $FindBin::Bin;
my $port   = "$t/..";
my $script = $ENV{CM_SCRIPT} // "$port/scripts/vyatta-config-mgmt.pl";
my $module = $ENV{CM_MODULE} // "$port/lib/Vyatta/ConfigMgmt.pm";

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or return q{};
    local $/ = undef;
    my $s = <$fh>;
    close $fh or return q{};
    return $s;
}

sub spew {
    my ( $path, $content ) = @_;
    make_path( dirname($path) );
    open my $fh, '>', $path or die "$path: $!\n";
    print {$fh} $content;
    close $fh or die "$path: $!\n";
    return;
}

sub spew_gz {
    my ( $path, $content ) = @_;
    make_path( dirname($path) );
    gzip \$content => $path or die "gzip: $GzipError\n";
    return;
}

my $commits = "|1700000000|alice|cli|first change|\n"
  . "|1700000100|bob|cli|commit|\n"
  . "|1700000200|carol|netconf|with %% pipe|\n";

# a /config with commit-revisions history and two archived revisions
sub archive {
    my ($root) = @_;
    spew( "$root/config/archive/commits", $commits );
    spew_gz( "$root/config/archive/config.boot.0.gz", "system { host-name r0 }\n" );
    spew_gz( "$root/config/archive/config.boot.1.gz", "system { host-name r1 }\n" );
    spew_gz( "$root/config/archive/config.boot.2.gz", "system { host-name r2 }\n" );
    return;
}

my $job = '{"job":"7","persist-id":"p1","session":"s1","time":"2026-10-22 10:00:00"}';

# name, arguments, environment, set-up
my @cases = (
    [ 'no-action', [], {}, undef ],
    [ 'unknown-action', ['--action=frobnicate'], {}, undef ],
    [ 'update-uri-add', ['--action=update-uri'], { STUB_ARCHIVES => 'scp://h/p' },
        sub { make_path("$_[0]/hooks") } ],
    [ 'update-uri-remove', ['--action=update-uri'], {}, sub {
        make_path("$_[0]/hooks");
        symlink '/opt/vyatta/sbin/vyatta-commit-push.pl', "$_[0]/hooks/02vyatta-commit-push.pl";
        spew( "$_[0]/config/archive/config.boot-push", "pushed\n" );
    } ],
    [ 'update-uri-none', ['--action=update-uri'], {}, sub { make_path("$_[0]/hooks") } ],
    [ 'valid-uri-tftp', [ '--action=valid-uri', '--uri=tftp://h/p' ], {}, undef ],
    [ 'valid-uri-scp', [ '--action=valid-uri', '--uri=scp://u@h:/p' ], {}, undef ],
    [ 'valid-uri-http', [ '--action=valid-uri', '--uri=http://h/p' ], {}, undef ],
    [ 'valid-uri-none', ['--action=valid-uri'], {}, undef ],
    [ 'update-revs-0', [ '--action=update-revs', '--revs=0' ], {}, sub {
        make_path("$_[0]/hooks");
        symlink '/opt/vyatta/sbin/vyatta-commit-revs.pl', "$_[0]/hooks/01vyatta-commit-revs.pl";
    } ],
    [ 'update-revs-5', [ '--action=update-revs', '--revs=5' ], {}, sub { make_path("$_[0]/hooks", "$_[0]/config") } ],
    [ 'update-revs-5-existing', [ '--action=update-revs', '--revs=5' ], {}, sub {
        make_path("$_[0]/hooks");
        archive( $_[0] );
    } ],
    [ 'update-revs-bad', [ '--action=update-revs', '--revs=x' ], {}, undef ],
    [ 'show-commit-log', ['--action=show-commit-log'], { STUB_MAX_REVS => 5 }, \&archive ],
    [ 'show-commit-log-unconfigured', ['--action=show-commit-log'], {}, \&archive ],
    [ 'show-commit-log-brief', ['--action=show-commit-log-brief'], { STUB_MAX_REVS => 5 }, \&archive ],
    [ 'show-commit-file', [ '--action=show-commit-file', '--revnum=1' ], { STUB_MAX_REVS => 5 }, \&archive ],
    [ 'show-commit-file-bad', [ '--action=show-commit-file', '--revnum=9' ], { STUB_MAX_REVS => 5 }, \&archive ],
    [ 'diff-unchanged', ['--action=diff'], { STUB_SESSION_UNCHANGED => 1 }, \&archive ],
    [ 'diff-session', ['--action=diff'], {}, \&archive ],
    [ 'diff-1', [ '--action=diff', '1' ], {}, \&archive ],
    [ 'diff-2', [ '--action=diff', '1', '2' ], {}, \&archive ],
    [ 'diff-3', [ '--action=diff', '0', '2', 'commands' ], {}, \&archive ],
    [ 'diff-bad-rev', [ '--action=diff', '7' ], {}, \&archive ],
    [ 'commit-confirm', [ '--action=commit-confirm', '--minutes=5' ], { STUB_MAX_REVS => 5 }, \&archive ],
    [ 'commit-confirm-replaces', [ '--action=commit-confirm', '--minutes=5' ], { STUB_MAX_REVS => 5 }, sub {
        archive( $_[0] );
        spew( "$_[0]/config/confirm.job", "41\n" );
    } ],
    [ 'commit-confirm-unconfigured', [ '--action=commit-confirm', '--minutes=5' ], {}, \&archive ],
    [ 'commit-confirm-at-fails', [ '--action=commit-confirm', '--minutes=5' ],
        { STUB_MAX_REVS => 5, STUB_AT_FAIL => 1 }, \&archive ],
    [ 'revert-configuration', ['--action=revert-configuration'], {}, sub {
        archive( $_[0] );
        spew( "$_[0]/config/confirm.job", "41\n" );
        spew( "$_[0]/config/confirmed_commit.job", "$job\n" );
    } ],
    [ 'confirmed-commit', [ '--action=confirmed-commit', '--seconds=120', '--persist=p1', '--session=s1' ],
        { STUB_MAX_REVS => 5 }, \&archive ],
    [ 'confirmed-commit-follow-up', [ '--action=confirmed-commit', '--seconds=120', '--session=s1' ],
        { STUB_MAX_REVS => 5 }, sub {
        archive( $_[0] );
        spew( "$_[0]/config/confirmed_commit.job", "$job\n" );
        spew_gz( "$_[0]/config/archive/config.boot.revert.gz", "system { host-name first }\n" );
    } ],
    [ 'show-confirmed-commit-none', ['--action=show-confirmed-commit'], {}, undef ],
    [ 'show-confirmed-commit', ['--action=show-confirmed-commit'], {}, sub {
        spew( "$_[0]/config/confirmed_commit.job", "$job\n" );
    } ],
    [ 'confirm-persist', [ '--action=confirm', '--persistid=p1' ], {}, sub {
        archive( $_[0] );
        spew( "$_[0]/config/confirmed_commit.job", "$job\n" );
        spew_gz( "$_[0]/config/archive/config.boot.revert.gz", "system { host-name first }\n" );
    } ],
    [ 'confirm-persist-mismatch', [ '--action=confirm', '--persistid=p2' ], {}, sub {
        spew( "$_[0]/config/confirmed_commit.job", "$job\n" );
    } ],
    [ 'confirm-persist-none', [ '--action=confirm', '--persistid=p1' ], {}, undef ],
    [ 'confirm', ['--action=confirm'], {}, sub { spew( "$_[0]/config/confirm.job", "41\n" ) } ],
    [ 'confirm-none', ['--action=confirm'], {}, undef ],
    [ 'confirming-commit', ['--action=confirming-commit'], {}, sub {
        archive( $_[0] );
        spew( "$_[0]/config/confirmed_commit.job", "$job\n" );
        spew_gz( "$_[0]/config/archive/config.boot.revert.gz", "system { host-name first }\n" );
    } ],
    [ 'confirm-silent', ['--action=confirm-silent'], {}, sub { spew( "$_[0]/config/confirm.job", "41\n" ) } ],
    [ 'extract-archive', [ '--action=extract-archive', '--revnum=2', '--dest=DEST' ], { STUB_MAX_REVS => 5 }, \&archive ],
    [ 'extract-archive-missing', [ '--action=extract-archive', '--revnum=2' ], {}, \&archive ],
    [ 'rollback-neither', ['--action=rollback'], {}, \&archive ],
    [ 'rollback-no-file', [ '--action=rollback', '--file=/nonexistent' ], {}, \&archive ],
    [ 'rollback-declined', [ '--action=rollback', '--revnum=1' ], { STUB_MAX_REVS => 5 }, \&archive ],
);

# the files under $root: symlinks with their targets, archives
# uncompressed, JSON job files in canonical order
sub snapshot {
    my ($root) = @_;
    my @out;
    find( { no_chdir => 1, wanted => sub {
        my $rel = substr( $File::Find::name, length($root) + 1 ) or return;
        return if $rel =~ m{^lib(/|$)}x;
        if ( -l $File::Find::name ) {
            push @out, "$rel -> " . readlink($File::Find::name);
        } elsif ( -d _ ) {
            push @out, "$rel/";
        } elsif ( $rel =~ /[.]gz$/x ) {
            gunzip $File::Find::name => \my $text or die "gunzip: $GunzipError\n";
            push @out, "$rel (gz): $text";
        } else {
            my $text = slurp($File::Find::name);
            if ( $rel =~ /[.]job$/x && $text =~ /^[{]/x ) {
                $text = JSON->new->canonical->encode( decode_json($text) ) . "\n";
            }
            push @out, "$rel: $text";
        }
    } }, $root );
    return join "\n", sort @out;
}

sub golden {
    my ( $got, $name ) = @_;
    my $path = "$t/actions/data/$name";
    spew( $path, $got ) if $ENV{UPDATE_GOLDEN};
    return is( $got, slurp($path), $name );
}

foreach my $case (@cases) {
    my ( $name, $args, $env, $setup ) = @$case;
    my $root = tempdir( CLEANUP => 1 );
    make_path("$root/config", "$root/lib/Vyatta");

    # the port's Vyatta::ConfigMgmt, rooted in $root
    my $cm = slurp($module);
    $cm =~ s{my[ ]\$config_dir\s*=\s*'/config';}{my \$config_dir = \$ENV{CM_TEST_ROOT} . '/config';}x
      or die "cannot root $module\n";
    spew( "$root/lib/Vyatta/ConfigMgmt.pm", $cm );
    $setup->($root) if $setup;

    my @argv = map { s/DEST/$root\/extracted/xr } @$args;
    my $log  = "$root/stub.log";
    local %ENV = (
        %ENV, %$env,
        TZ           => "UTC",
        CM_TEST_ROOT => $root,
        STUB_LOG     => $log,
        PATH         => "$t/actions/bin:$ENV{PATH}",
        PERL5LIB     => join( ':', "$root/lib", "$t/actions/lib", "$port/lib" ),
    );
    my $pid = open( my $out, '-|' ) // die "fork: $!\n";
    if ( $pid == 0 ) {
        open( STDERR, '>&', \*STDOUT ) or die "$!\n";
        exec $^X, $script, @argv or die "exec: $!\n";
    }
    my $output = do { local $/ = undef; <$out> } // q{};
    close $out;
    my $status = $? >> 8;
    unlink $log if -z $log;
    my $calls = slurp($log);
    unlink $log;

    my $got = "exit $status\n--- output\n$output\n--- commands\n$calls\n--- files\n" . snapshot($root) . "\n";
    $got =~ s/\Q$root\E/ROOT/gx;
    $got =~ s/now[ ][+][ ]\d+[ ]minutes/now + N minutes/gx;
    $got =~ s/[ ]at[ ]\S+[ ]line[ ]\d+[.]$/ at SCRIPT line N./gmx;
    golden( $got, "$name.expected" );
}

done_testing();
