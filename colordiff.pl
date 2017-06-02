#!/usr/bin/perl -w

########################################################################
#                                                                      #
# ColorDiff - a wrapper/replacement for 'diff' producing               #
#             colourful output                                         #
#                                                                      #
# Copyright (C)2002-2017 Dave Ewart (davee@sungate.co.uk)              #
#                                                                      #
########################################################################
#                                                                      #
# This program is free software; you can redistribute it and/or modify #
# it under the terms of the GNU General Public License as published by #
# the Free Software Foundation; either version 2 of the License, or    #
# (at your option) any later version.                                  #
#                                                                      #
# This program is distributed in the hope that it will be useful,      #
# but WITHOUT ANY WARRANTY; without even the implied warranty of       #
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the        #
# GNU General Public License for more details.                         #
#                                                                      #
########################################################################

use strict;
use Getopt::Long qw(:config pass_through no_auto_abbrev);

my $app_name     = 'colordiff';
my $version      = '1.0.17';
my $author       = 'Dave Ewart';
my $author_email = 'davee@sungate.co.uk';
my $app_www      = 'http://www.colordiff.org/';
my $copyright    = '(C)2002-2017';
my $show_banner  = 1;
my $color_patch  = undef;
my $diff_cmd     = "diff";

# ANSI sequences for colours
my %colour;
$colour{white}       = "\033[1;37m";
$colour{yellow}      = "\033[1;33m";
$colour{green}       = "\033[1;32m";
$colour{blue}        = "\033[1;34m";
$colour{cyan}        = "\033[1;36m";
$colour{red}         = "\033[1;31m";
$colour{magenta}     = "\033[1;35m";
$colour{black}       = "\033[1;30m";
$colour{darkwhite}   = "\033[0;37m";
$colour{darkyellow}  = "\033[0;33m";
$colour{darkgreen}   = "\033[0;32m";
$colour{darkblue}    = "\033[0;34m";
$colour{darkcyan}    = "\033[0;36m";
$colour{darkred}     = "\033[0;31m";
$colour{darkmagenta} = "\033[0;35m";
$colour{darkblack}   = "\033[0;30m";
$colour{off}         = "\033[0;0m";

# Default colours if /etc/colordiffrc or ~/.colordiffrc do not exist
my $plain_text = $colour{white};
my $file_old   = $colour{red};
my $file_new   = $colour{blue};
my $diff_stuff = $colour{magenta};
my $diff_file  = $diff_stuff;
my $cvs_stuff  = $colour{green};

# Locations for personal and system-wide colour configurations
my $HOME   = $ENV{HOME};
my $etcdir = '/etc';
my ($setting, $value);
my @config_files = ("$etcdir/colordiffrc");
if (defined $ENV{XDG_CONFIG_HOME} && $ENV{XDG_CONFIG_HOME} ne '') {
    push (@config_files, "$ENV{XDG_CONFIG_HOME}/colordiff/colordiffrc")
}
elsif (defined $ENV{HOME}) {
    push (@config_files, "$ENV{HOME}/.config/colordiff/colordiffrc")
}
push (@config_files, "$ENV{HOME}/.colordiffrc") if (defined $ENV{HOME});
my $config_file;
my $diff_type = 'unknown';

# Convert tabs to spaces
sub expand_tabs_to_spaces ($) {
    my ($s) = @_;
    while ((my $i = index ($s, "\t")) > -1) {
        substr (
            $s, $i, 1,    # range to replace
            (' ' x (8 - ($i % 8))),    # string to replace with
            );
    }
    $s;
}

sub check_for_file_arguments {
    my $nonopts = 0;
    my $ddash = 0;

    while (defined(my $arg = shift)) {
        if ($arg eq "--") {
            $ddash = 1;
            next;
        }
        if ($ddash || $arg eq "-") {
            $nonopts++;
            next;
        }
        if ($arg !~ /^-/) {
            $nonopts++;
        }
        if ($arg eq "--help" || $arg eq "--version" || $arg eq "-v") {
            $nonopts++;
        }
    }
    return $nonopts;
}

sub detect_diff_type {
    # Two parameters:
    #    $record      is line in which a diff format has to be detected
    #    $allow_diffy is flag indicating whether diffy is a
    #                   permitted diff type
    my $record = shift;
    my $allow_diffy = shift;

    # This may not be perfect - should identify most reasonably
    # formatted diffs and patches

    # Unified diffs are the only flavour having '+++ ' or '--- '
    # at the start of a line
    if ($record =~ /^(\+\+\+ |--- |@@ )/) {
        return 'diffu';
    }
    # Context diffs are the only flavour having '***'
    # at the start of a line
    elsif ($record =~ /^\*\*\*/) {
        return 'diffc';
    }
    # Plain diffs have NcN, NdN and NaN etc.
    elsif ($record =~ /^[0-9,]+[acd][0-9,]+$/) {
        return 'diff';
    }
    # FIXME - This is not very specific, since the regex matches could
    # easily match non-diff output.
    # However, given that we have not yet matched any of the *other* diff
    # types, this might be good enough
    #
    # Only pick diffy if our flag parameter indicates so
    elsif ( ($allow_diffy == 1) && ($record =~ /(\s\|\s|\s<$|\s>\s)/) ) {
        return 'diffy';
    }
    # wdiff deleted/added patterns
    # should almost always be pairwise?
    elsif ($record =~ /\[-.*?-\]/s
            || $record =~ /\{\+.*?\+\}/s) {
        return 'wdiff';
    }
    # FIXME - This is a bit risky, but if we haven't matched any other
    # diff type by this stage, this line usually indicates we have
    # debdiff output
    elsif ($record =~ /^Control files: lines which differ/) {
        return 'debdiff';
    }

    return 'unknown';
}

my $enable_verifymode;
my $specified_difftype;
my $enable_fakeexitcode;
my $color_mode = "auto";
my $color_term_output_only = "no";
GetOptions(
    # --enable-verifymode option is for testing behaviour of colordiff
    # against standard test diffs
    "verifymode" => \$enable_verifymode,
    "fakeexitcode" => \$enable_fakeexitcode,
    "difftype=s" => \$specified_difftype,
    "color=s" => \$color_mode,
    "color-term-output-only=s" => \$color_term_output_only
);

$_ = $specified_difftype;
if (defined $_ and not /^diff[cuy]?|(deb|w)diff$/) {
    print STDERR "Invalid --difftype value\n";
}

if (defined $enable_verifymode) {
    # When in verify mode, to ensure consistent output we don't source
    # any external config files, so we use built-in defaults
    # and we add colour to our patches
    @config_files = ();
    $color_patch  = 1;
    $show_banner  = 0;
}

foreach $config_file (@config_files) {
    if (open (COLORDIFFRC, "<$config_file")) {
        while (<COLORDIFFRC>) {
            my $colourval;

            chop;
            next if (/^#/ || /^$/);
            s/\s+//g;
            ($setting, $value) = split ('=');
            if (!defined $value) {
                print STDERR "Invalid configuration line ($_) in $config_file\n";
                next;
            }
            if ($setting eq 'banner') {
                if ($value eq 'no') {
                    $show_banner = 0;
                }
                next;
            }
            if ($setting eq 'color_patches') {
                if ($value eq 'yes') {
                    $color_patch = 1;
                } elsif ($value eq 'no') {
                    $color_patch = 0;
                }
                next;
            }
            if ($setting eq 'diff_cmd') {
                $diff_cmd = $value;
                next;
            }
            $setting =~ tr/A-Z/a-z/;
            $value   =~ tr/A-Z/a-z/;
            if (($value eq 'normal') || ($value eq 'none')) {
                $value = 'off';
            }
            if ($value =~ m/[0-9]+/ && $value >= 0 && $value <= 255) {
                # Numeric color
                if( $value < 8 ) {
                    $colourval = "\033[0;3${value}m";
                }
                elsif( $value < 15 ) {
                    $colourval = "\033[0;9" . (${value} - 8) . "m";
                }
                else {
                    $colourval = "\033[0;38;5;${value}m";
                }
            }
            elsif (defined($colour{$value})) {
                $colourval = $colour{$value};
            }
            else {
                print STDERR "Invalid colour specification for setting $setting ($value) in $config_file\n";
                next;
            }
            if ($setting eq 'plain') {
                $plain_text = $colourval;
            }
            elsif ($setting eq 'oldtext') {
                $file_old = $colourval;
            }
            elsif ($setting eq 'newtext') {
                $file_new = $colourval;
            }
            elsif ($setting eq 'diffstuff') {
                $diff_stuff = $colourval;
            }
            elsif ($setting eq 'difffile') {
                $diff_file = $colourval;
            }
            elsif ($setting eq 'cvsstuff') {
                $cvs_stuff = $colourval;
            }
            else {
                print STDERR "Unknown option in $config_file: $setting\n";
            }
        }
        close COLORDIFFRC;
    }
}

# --color=(yes|no|auto) will override the color_patches setting
if ($color_mode eq "yes") {
    $color_patch = 1;
} elsif ($color_mode eq "no") {
    $color_patch = 0;
} elsif ($color_mode eq "auto") {
    $color_patch = undef;
}

# If output is to a file, switch off colours unless overriden by $color_patch.
# Relates to http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=378563
# Relates to http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=862878
if ( (!$color_patch && (defined $color_patch || -f STDOUT)) ||
     ($color_term_output_only && !-t STDOUT) )
{
    $plain_text  = '';
    $file_old    = '';
    $file_new    = '';
    $diff_file   = '';
    $diff_stuff  = '';
    $cvs_stuff   = '';
    $plain_text  = '';
    $colour{off} = '';
}

# Disable output buffering. This allows "producer | colordiff | less" to output
# earlier without having to wait for 'producer' to finish.
select STDOUT;
$| = 1;

# ----------------------------------------------------------------------------

if ($show_banner == 1) {
    print STDERR "$app_name $version ($app_www)\n";
    print STDERR "$copyright $author, $author_email\n\n";
}

my $operating_methodology;

if (check_for_file_arguments (@ARGV)) {
    $operating_methodology = 1; # we have files as arg, so we act as diff
} else {
    $operating_methodology = 2; # no files as args, so operate as filter
}

my @inputstream;

my $inputhandle;
my $pid;
if ($operating_methodology == 1) {
    # Feed stdin of colordiff with output from the diff program
    $pid = open($inputhandle, "-|", "$diff_cmd", @ARGV);
} else {
    $inputhandle = \*STDIN;
}

# Input stream has been read - need to examine it
# to determine type of diff we have.

# $lastline is false if the input is EOF. If true, then either more data is
# available, or the last read succeeded (and the next read may return EOF).
# Initially assume that the input is not EOF (for obvious reasons).
my $lastline = 1;
my $record;

if (defined $specified_difftype) {
    $diff_type = $specified_difftype;
    # diffy needs at least one line to look at
    if ($diff_type eq 'diffy') {
        if (defined($_ = <$inputhandle>)) {
            push @inputstream, $_;
        }
        $lastline = $_;
    }
}
else {
    # Detect diff type, diffy is permitted
    while (<$inputhandle>) {
        push @inputstream, $_;
        $diff_type = detect_diff_type($_, 1);
        last if $diff_type ne 'unknown';
    }
    $lastline = $_;
}

my $inside_file_old = 1;

# ------------------------------------------------------------------------------
# Special pre-processing for side-by-side diffs
# Figure out location of central markers: these will be a consecutive set of
# three columns where the first and third always consist of spaces and the
# second consists only of spaces, '<', '>' and '|'
# This is not a 100% certain match, but should be good enough
my $diffy_sep_col  = 0;
my $mostlikely_sum = 0;

if ($diff_type eq 'diffy') {
    # Not very elegant, but does the job

    my $longest_record = -1;
    my %separator_col  = ();
    my %candidate_col  = ();
    my $possible_cols = 0;
    my @checkbuffer;

    (@checkbuffer, @inputstream) = (@inputstream, @checkbuffer);

    while (@checkbuffer) {
        $_ = shift @checkbuffer;
        push @inputstream, $_;
        $_ = expand_tabs_to_spaces $_;

        if (length ($_) > $longest_record) {
            my $i = $longest_record + 1;

            $longest_record = length ($_);
            while ($i <= $longest_record) {
                $separator_col{$i} = 1;
                $candidate_col{$i} = 0;
                $i++;
            }
        }

        for (my $i = 0 ; $i < (length ($_) - 2) ; $i++) {
            next if ($separator_col{$i} == 0);
            next if ($_ =~ /^(Index: |={4,}|RCS file: |retrieving |diff )/);
            my $subsub = substr ($_, $i, 2);
            if ($subsub !~ / [ (|<>]/) {
                $separator_col{$i} = 0;
                if ($candidate_col{$i} > 0) {
                    $possible_cols--;
                }
            }
            if ($subsub =~ / [|<>]/) {
                $candidate_col{$i}++;
                if ($candidate_col{$i} == 1) {
                    $possible_cols++;
                }
            }
        }

        if ( !@checkbuffer ) {
            if (! (defined $specified_difftype) and
                $possible_cols == 0 && detect_diff_type($_, 0) ne 'unknown') {
                $diff_type = detect_diff_type($_, 0);
                last;
            }
            if (defined ($_ = <$inputhandle>)) {
                push @checkbuffer, $_;
            }
            $lastline = $_;
        }
    }

    for (my $i = 0 ; $i < $longest_record - 2 ; $i++) {
        if ($separator_col{$i} == 1) {
            if ($candidate_col{$i} > $mostlikely_sum) {
                $diffy_sep_col  = $i;
                $mostlikely_sum = $i;
            }
        }
    }
    # If we don't find a suitable separator column then
    # we've probably misidentified the input as diffy
    # Search stream again, this time excluding diffy
    # as a possible outcome
    if ($diffy_sep_col == 0) {
        # Detect diff type, diffy is NOT permitted
        foreach (@inputstream) {
            $diff_type = detect_diff_type($_, 0);
            last if $diff_type ne 'unknown';
        }
    }
}
# ------------------------------------------------------------------------------

while (defined( $_ = @inputstream ? shift @inputstream : ($lastline and <$inputhandle>) )) {
    if (/^Binary files (.*) and (.*) differ$/) {
        print "Binary files $file_old$1$plain_text and $file_new$2$plain_text differ\n";
        next;
    }
    if ($diff_type eq 'diff') {
        if (/^</) {
            print "$file_old";
        }
        elsif (/^>/) {
            print "$file_new";
        }
        elsif (/^[0-9]/) {
            print "$diff_stuff";
        }
        elsif (/^(Index: |={4,}|RCS file: |retrieving |diff )/) {
            print "$cvs_stuff";
        }
        elsif (/^Only in/) {
            print "$diff_file";
        }
        else {
            print "$plain_text";
        }
    }
    elsif ($diff_type eq 'diffc') {
        if (/^- /) {
            print "$file_old";
        }
        elsif (/^\+ /) {
            print "$file_new";
        }
        elsif (/^\*{4,}/) {
            print "$diff_file";
        }
        elsif (/^Only in/) {
            print "$diff_file";
        }
        elsif (/^\*\*\* [0-9]+,[0-9]+/) {
            print "$diff_file";
            $inside_file_old = 1;
        }
        elsif (/^\*\*\* /) {
            print "$file_old";
        }
        elsif (/^--- [0-9]+,[0-9]+/) {
            print "$diff_file";
            $inside_file_old = 0;
        }
        elsif (/^--- /) {
            print "$file_new";
        }
        elsif (/^!/) {
            if ($inside_file_old == 1) {
                print "$file_old";
            }
            else {
                print "$file_new";
            }
        }
        elsif (/^(Index: |={4,}|RCS file: |retrieving |diff )/) {
            print "$cvs_stuff";
        }
        else {
            print "$plain_text";
        }
    }
    elsif ($diff_type eq 'diffu') {
        if (/^(---|\+\+\+) /) {
            print "$diff_file";
        }
        elsif (/^-/) {
            print "$file_old";
        }
        elsif (/^\+/) {
            print "$file_new";
        }
        elsif (/^\@/) {
            print "$diff_stuff";
        }
        elsif (/^Only in/) {
            print "$diff_file";
        }
        elsif (/^(Index: |={4,}|RCS file: |retrieving |diff )/) {
            print "$cvs_stuff";
        }
        else {
            print "$plain_text";
        }
    }
    # Works with previously-identified column containing the diff-y
    # separator characters
    elsif ($diff_type eq 'diffy') {
        $_ = expand_tabs_to_spaces $_;
        if (length ($_) > ($diffy_sep_col + 2)) {
            my $sepchars = substr ($_, $diffy_sep_col, 2);
            if ($sepchars eq ' <') {
                print "$file_old";
            }
            elsif ($sepchars eq ' |') {
                print "$diff_stuff";
            }
            elsif ($sepchars eq ' >') {
                print "$file_new";
            }
            else {
                print "$plain_text";
            }
        }
        elsif (/^Only in/) {
            print "$diff_file";
        }
        else {
            print "$plain_text";
        }
    }
    elsif ($diff_type eq 'wdiff') {
        $_ =~ s/(\[-.+?-\])/$file_old$1$colour{off}/g;
        $_ =~ s/(\{\+.+?\+\})/$file_new$1$colour{off}/g;
    }
    elsif ($diff_type eq 'debdiff') {
        $_ =~ s/(\[-.+?-\])/$file_old$1$colour{off}/g;
        $_ =~ s/(\{\+.+?\+\})/$file_new$1$colour{off}/g;
    }
    s/$/$colour{off}/;
    print "$_";
}

my $exitcode = 0;
if ($operating_methodology == 1) {
    waitpid $pid, 0;
    $exitcode=$? >> 8;
}
if (defined $enable_fakeexitcode) {
    exit 0;
}
else {
    exit $exitcode;
}
