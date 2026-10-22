# Test stub: commit-revisions from STUB_MAX_REVS, archive locations from
# STUB_ARCHIVES (space separated); no routing instances.
package Vyatta::Config;
use strict;
use warnings;

sub new       { return bless {}, shift; }
sub setLevel  { my ( $self, $level ) = @_; $self->{level} = $level; return; }
sub inSession { return 0; }

sub returnOrigValue {
    my ( $self, $node ) = @_;
    return $ENV{STUB_MAX_REVS} if $node eq 'commit-revisions';
    return;
}

sub returnOrigValues {
    my ( $self, $node ) = @_;
    return if ( $self->{level} // q{} ) !~ /^system/x || $node ne 'location';
    return split /[ ]/x, ( $ENV{STUB_ARCHIVES} // q{} );
}

sub listOrigNodes { return; }
1;
