package Vyatta::Utils;
use strict;
use warnings;

use parent qw(Exporter);

## no critic (Modules::ProhibitAutomaticExportation) reason: vyatta-config-mgmt.pl and the tests take it by default
our @EXPORT = qw(parse_version_string);
## use critic

sub parse_version_string {
    my $string  = shift;
    my @words   = split( ' ', $string );
    my @version = ();

    while ( my $word = pop(@words) ) {
        last if @version = ( $word =~ /^(\d+\.)(\d+\.)?(.*|\d+)$/x );
    }

    # e.g. ( "1.", undefined, "2" )
    @version = grep { defined } @version;

    return join( '', @version );
}

1;
