#!/usr/bin/perl

# See the POD at the end of the file.

use 5.008_000;
use warnings;
use strict;
use diagnostics;
use English qw( -no_match_vars );
use Getopt::Long qw( GetOptions :config pass_through );
use Pod::Usage qw( pod2usage );
use IPC::Open2;
use Term::ANSIColor qw(:constants color colorvalid);
use Module::Load::Conditional qw( can_load );
use Carp qw( carp croak );

package main;

#pull in Perl 6 given/when
use feature qw(:5.10);

if ( $PERL_VERSION < v5.12 ) {
    can_load( modules => { 'Switch' => '2.09', }, verbose => 1 )
        or die "$ERRNO Cannot load module Switch.\n";
}

# This may not be perfect - should identify most reasonably
# formatted diffs and patches
sub determine_diff_type {
    my $input_ref = shift;
    my $diff_type = 'unknown';

DIFF_TYPE: foreach my $record ( @{$input_ref} ) {
        given ($record) {

            # Unified diffs are the only flavour having '+++' or '---'
            # at the start of a line
            when (m/^(?:[+]{3}|---|@@)/xms) { $diff_type = 'diffu'; }

            # Context diffs are the only flavour having '***'
            # at the start of a line
            when (m/^[*]{3}/xms) { $diff_type = 'diffc'; }

            # Plain diffs have NcN, NdN and NaN etc.
            when (m/^\d+[acd]\d+$/xms) { $diff_type = 'diff'; }

            # FIXME - This is not very specific, since the regex matches
            # could easily match non-diff output.  However, given that we
            # have not yet matched any of the *other* diff types, this might
            # be good enough
            when (m/(?:\s[|]\s|\s<$|\s>\s)/xms) { $diff_type = 'diffy'; }

            # wdiff deleted/added patterns
            # should almost always be pairwaise?
            when (m/\[-.*?-\]/xs)   { $diff_type = 'wdiff'; }
            when (m/\{\+.*?\+\}/xs) { $diff_type = 'wdiff'; }
        }

        if ( $diff_type ne 'unknown' ) {
            last DIFF_TYPE;
        }
    }

    return $diff_type;
}

sub show_banner {
    my $display = shift;

    return if ( $display == 0 );

    my $app_name     = 'colordiff';
    my $version      = '2.0.0';
    my $author       = 'Dave Ewart';
    my $author_email = 'davee@sungate.co.uk';
    my $app_www      = 'http://colordiff.sourceforge.net/';
    my $copyright    = '(C)2002-2011';

    print {*STDERR} "$app_name $version ($app_www)\n";
    print {*STDERR} "$copyright $author, $author_email\n\n";

    return 0;
}

sub parse_config_file {
    my %colour   = %{ (shift) };
    my %settings = %{ (shift) };
    my $location = shift;

    return %settings if ( !-e $location || !-r $location );

    open my $fh, '<', $location || croak "Cannot open $location: $OS_ERROR";
    my @contents = <$fh>;
    close $fh || croak "Cannot open $location: $OS_ERROR";

LINE_CONTENT: foreach my $line (@contents) {
        my $colourval;
        chomp $line;
        $line =~ s/\s+//gxms;
        next if ( $line =~ m/^[#]/xms || $line =~ m/^$/xms );
        $line = lc $line;

        my ( $option, $value ) = split /=/xms, $line;

        given ($value) {
            when (m/yes|no/xms)   { }
            when (m/normal/xms)   { next LINE_CONTENT; }
            when (m/none|off/xms) { $colourval = $settings{off}; }

            #256 color support via specifiying the number in colordiffrc
            when ( $value =~ m/\d+/xms && $value >= 0 && $value <= 255 ) {
                $colourval = "\033[0;38;5;${value}m";
                if ( $value < 8 ) {
                    $colourval = "\033[0;3${value}m";
                }
                elsif ( $value < 15 ) {
                    $colourval = "\033[0;9${value}m";
                }
            }

           #when ( defined $colour{$value} ) { $colourval = $colour{$value}; }

            when ( colorvalid($value) ) { $colourval = $colour{$value}; }
            default {
                print {
                    *STDERR
                }
                "Invalid colour specification for setting '$option'='$value' in $location\n";
                next LINE_CONTENT;
            }
        }

        given ($option) {
            when ('banner') {
                if ( $value =~ m/yes|no/xms ) {
                    $settings{banner} = $value eq 'yes' ? 1 : 0;
                }
            }
            when ('color_patches') {
                if ( $value =~ m/yes|no/xms ) {
                    $settings{color_patches} = $value eq 'yes' ? 1 : 0;
                }
            }

            when ('plain')     { $settings{plain}     = $colourval; }
            when ('oldtext')   { $settings{oldtext}   = $colourval; }
            when ('newtext')   { $settings{newtext}   = $colourval; }
            when ('diffstuff') { $settings{diffstuff} = $colourval; }
            when ('cvsstuff')  { $settings{cvsstuff}  = $colourval; }
            default {
                print {
                    *STDERR
                }
                "Unknown option '$option' in $location\n";
            }
        }
    }

    return %settings;
}

sub preprocess_input {
    my $input_ref = shift;

  # Special pre-processing for side-by-side diffs
  # Figure out location of central markers: these will be a consecutive set of
  # three columns where the first and third always consist of spaces and the
  # second consists only of spaces, '<', '>' and '|'
  # This is not a 100% certain match, but should be good enough

    my %separator_col  = ();
    my %candidate_col  = ();
    my $diffy_sep_col  = 0;
    my $mostlikely_sum = 0;
    my $longest_record = 0;

    # Not very elegant, but does the job
    # Unfortunately requires parsing the input stream multiple times
    foreach my $line ( @{$input_ref} ) {

        # Convert tabs to spaces
        while ( ( my $i = index $line, "\t" ) > -1 ) {
            substr $line, $i, 1,    # range to replace
                ( q{ } x ( 8 - ( $i % 8 ) ) );    # string to replace with
        }
        if ( length($line) > $longest_record ) {
            $longest_record = length $line;
        }
    }

    for my $i ( 0 .. $longest_record ) {
        $separator_col{$i} = 1;
        $candidate_col{$i} = 0;
    }

    foreach ( @{$input_ref} ) {

        # Convert tabs to spaces
        while ( ( my $i = index $_, "\t" ) > -1 ) {
            substr $_, $i, 1,    # range to replace
                ( q{ } x ( 8 - ( $i % 8 ) ) );    # string to replace with
        }
        for my $i ( 0 .. ( length($_) - 3 ) ) {
            next if ( !defined $separator_col{$i} );
            next if ( $separator_col{$i} == 0 );
            my $subsub = substr $_, $i, 2;
            if (   ( $subsub ne q{  } )
                && ( $subsub ne ' |' )
                && ( $subsub ne ' >' )
                && ( $subsub ne ' <' ) )
            {
                $separator_col{$i} = 0;
            }
            if (   ( $subsub eq ' |' )
                || ( $subsub eq ' >' )
                || ( $subsub eq ' <' ) )
            {
                $candidate_col{$i}++;
            }
        }
    }

    for my $i ( 0 .. ( $longest_record - 3 ) ) {
        if ( $separator_col{$i} == 1 ) {
            if ( $candidate_col{$i} > $mostlikely_sum ) {
                $diffy_sep_col  = $i;
                $mostlikely_sum = $i;
            }
        }
    }

    return $diffy_sep_col;
}

sub parse_and_print {
    my %settings = %{ (shift) };
    my @input    = @{ (shift) };
    my $type     = shift;
    my $diffy_sep_col  = shift;
    my $inside_oldtext = 1;

    $type eq 'wdiff' and @input = (join '', @input);

    foreach (@input) {
        if ( $type eq 'diff' ) {
            given ($_) {
                when (m/^</xms)  { print $settings{oldtext}; }
                when (m/^>/xms)  { print $settings{newtext}; }
                when (m/^\d/xms) { print $settings{diffstuff}; }
                when (
                    m/^(?:Index:[ ]|={4,}|RCS[ ]file:[ ]|retrieving[ ]|diff[ ])/xms
                    )
                {
                    print $settings{cvsstuff};
                }
                when (m/^Only[ ]in/xms) { print $settings{diffstuff}; }
                default                 { print $settings{plain}; }
            }
        }
        elsif ( $type eq 'diffc' ) {
            given ($_) {
                when (m/^-[ ]/xms)      { print $settings{oldtext}; }
                when (m/^[+][ ]/xms)    { print $settings{newtext}; }
                when (m/^[*]{4,}/xms)   { print $settings{diffstuff}; }
                when (m/^Only[ ]in/xms) { print $settings{diffstuff}; }
                when (m/^[*]{3}[ ]\d+,\d+/xms) {
                    print $settings{diffstuff};
                    $inside_oldtext = 1;
                }
                when (m/^[*]{3}[ ]/xms) { print $settings{oldtext}; }
                when (m/^---[ ]\d+,\d+/xms) {
                    print $settings{diffstuff};
                    $inside_oldtext = 0;
                }
                when (m/^---[ ]/xms) { print $settings{newtext}; }
                when (m/^!/xms) {
                    $inside_oldtext == 1
                        ? print $settings{oldtext}
                        : print $settings{newtext};
                }
                when (
                    m/^(?:Index:[ ]|={4,}|RCS[ ]file:[ ]|retrieving[ ]|diff[ ])/xms
                    )
                {
                    print $settings{cvsstuff};
                }
                default { print $settings{plain}; }
            }
        }
        elsif ( $type eq 'diffu' ) {
            given ($_) {
                when (m/^-/xms)         { print $settings{oldtext}; }
                when (m/^[+]/xms)       { print $settings{newtext}; }
                when (m/^[@]/xms)       { print $settings{diffstuff}; }
                when (m/^Only[ ]in/xms) { print $settings{diffstuff}; }
                when (
                    m/^(?:Index:[ ]|={4,}|RCS[ ]file:[ ]|retrieving[ ]|diff[ ])/xms
                    )
                {
                    print $settings{cvsstuff};
                }
                default { print $settings{plain}; }
            }
        }

        # Works with previously-identified column containing the diff-y
        # separator characters
        elsif ( $type eq 'diffy' ) {
            if ( length($_) > ( $diffy_sep_col + 2 ) ) {
                my $sepchars = substr $_, $diffy_sep_col, 2;
                if ( $sepchars eq ' <' ) {
                    print $settings{oldtext};
                }
                elsif ( $sepchars eq ' |' ) {
                    print $settings{diffstuff};
                }
                elsif ( $sepchars eq ' >' ) {
                    print $settings{newtext};
                }
                else {
                    print $settings{plain};
                }
            }
            elsif (m/^Only[ ]in/xms) {
                print $settings{diffstuff};
            }
            else {
                print $settings{plain};
            }
        }
        elsif ( $type eq 'wdiff' ) {
            $_ =~ s/(\[-[^]]*?-\])/$settings{oldtext}$1$settings{off}/gms;
            $_
                =~ s/([{][+][^]]*?[+][}])/$settings{newtext}$1$settings{off}/gms;
        }
        elsif ( $type eq 'debdiff' ) {
            $_ =~ s/(\[-[^]]*?-\])/$settings{oldtext}$1$settings{off}/gms;
            $_
                =~ s/([{][+][^]]*?[+][}])/$settings{newtext}$1$settings{off}/gms;
        }

        print $_, color('reset');
    }
    return;
}

# ----------------------------------------------------------------------------

# ANSI sequences for colours
my %colour = (
    'white'   => "\033[1;37m",
    'yellow'  => "\033[1;33m",
    'green'   => "\033[1;32m",
    'blue'    => "\033[1;34m",
    'cyan'    => "\033[1;36m",
    'red'     => "\033[1;31m",
    'magenta' => "\033[1;35m",
    'black'   => "\033[1;30m",

    'darkwhite'   => "\033[0;37m",
    'darkyellow'  => "\033[0;33m",
    'darkgreen'   => "\033[0;32m",
    'darkblue'    => "\033[0;34m",
    'darkcyan'    => "\033[0;36m",
    'darkred'     => "\033[0;31m",
    'darkmagenta' => "\033[0;35m",
    'darkblack'   => "\033[0;30m",
    'off'         => "\033[0;0m",
);

sub run {
    my $specified_difftype;

    # Default settings if /etc/colordiffrc and ~/.colordiffrc do not exist.
    my %settings = (
        'plain'         => $colour{white},
        'oldtext'       => $colour{red},
        'newtext'       => $colour{blue},
        'diffstuff'     => $colour{magenta},
        'cvsstuff'      => $colour{green},
        'banner'        => 1,
        'color_patches' => 0,
        'off'           => $colour{off},
    );

    GetOptions(
        'difftype=s' => \$specified_difftype,
        'help|?'     => sub { pod2usage( -verbose => 1 ) },
        'man'        => sub { pod2usage( -verbose => 2 ) },
        'usage'      => sub { pod2usage( -verbose => 0 ) },
        'version'    => sub { show_banner(1); exit 1; },
    );


    %settings = parse_config_file( \%colour, \%settings, '/etc/colordiffrc' );

    if ( defined $ENV{HOME} ) {
        %settings = parse_config_file( \%colour, \%settings,
            "$ENV{HOME}/.colordiffrc" );
    }

   # If output is to a file, switch off colours, unless 'color_patches' is set
   # Relates to http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=378563
    if ( ( -f STDOUT ) && ( $settings{color_patches} == 0 ) ) {
        $settings{plain}     = q{};
        $settings{oldtext}   = q{};
        $settings{newtext}   = q{};
        $settings{diffstuff} = q{};
        $settings{cvsstuff}  = q{};
        $settings{off}       = q{};
    }

    show_banner( $settings{banner} );

    my @inputstream;

    my $exitcode = 0;
    if ( ( defined $ARGV[0] ) || ( -t STDIN ) ) {

        # More reliable way of pulling in arguments
        my $pid = open2( \*INPUTSTREAM, undef, 'diff', @ARGV );
        @inputstream = <INPUTSTREAM>;
        close INPUTSTREAM;
        waitpid $pid, 0;
        $exitcode = $CHILD_ERROR >> 8;
    }
    else {
        @inputstream = <STDIN>;
    }

    my $diff_type;
    if (   $specified_difftype
        && $specified_difftype =~ m/diffu | diffc | diff | diffy | wdiff/xms )
    {
        $diff_type = $specified_difftype;
    }
    else {
        $diff_type = determine_diff_type( \@inputstream );
    }

    my $diffy_sep_col = 0;

    if ( $diff_type eq 'diffy' ) {
        $diffy_sep_col = preprocess_input( \@inputstream );
    }

    parse_and_print( \%settings, \@inputstream, $diff_type, $diffy_sep_col );

    exit $exitcode;
}

run() unless caller;

__END__

#-----------------------------------------------------------------------------

=pod

=head1 NAME

C<colordiff> - a wrapper/replacment for 'diff' producing colourful output

=head1 VERSION

=head1 USAGE

  cmd_line_example [ options ]
  cmd_line_example [ -c | --config ]
  cmd_line_example { --help | --man | --usage | --version }

=head1 REQUIRED ARGUMENTS
=head1 ARGUMENTS

=head1 OPTIONS

  These are the application options.

=over

=item C<--difftype>

  Specify the diff type to use.

=item C<--help>

  Displays a brief summary of options and exits.

=item C<--man>

  Displays the complete manual and exits.

=item C<--usage>

  Displays the basic application usage.

=item C<--version>

  Displays the version number and exits.

=back

=head1 DESCRIPTION

  A wrapper to colorize the output from a diff program.

=head1 DIAGNOSTICS

=head1 EXIT STATUS

  1 - Program exited normally. --help, --man, and --version return 1.
  2 - Program exited normally. --usage returns 2.

=head1 CONFIGURATION
=head1 DEPENDENCIES
=head1 INCOMPATIBILITIES
=head1 BUGS AND LIMITATIONS

=head1 HOMEPAGE

=head1 AUTHOR

  Dave Ewart - davee@sungate.co.uk
  Kirk Kimmel - https://github.com/kimmel

=head1 LICENSE AND COPYRIGHT

  Copyright (C) 2002-2011 Dave Ewart
  Copyright (C) 2011 Kirk Kimmel

  This program is free software; you can redistribute it and/or modify it under the GPL v2+. The full text of this license can be found online at < http://opensource.org/licenses/GPL-2.0 >

=cut

