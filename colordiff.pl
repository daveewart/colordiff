#!/usr/bin/perl -w

########################################################################
#                                                                      #
# ColorDiff - a wrapper/replacment for 'diff' producing                #
#             colourful output                                         #
#                                                                      #
# Copyright (C)2002-2012 Dave Ewart (davee@sungate.co.uk)              #
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
use IPC::Open2;

my $app_name     = 'colordiff';
my $version      = '1.0.13';
my $author       = 'Dave Ewart';
my $author_email = 'davee@sungate.co.uk';
my $app_www      = 'http://www.colordiff.org/';
my $copyright    = '(C)2002-2012';
my $show_banner  = 1;
my $color_patch  = 0;
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
my $cvs_stuff  = $colour{green};

# Locations for personal and system-wide colour configurations
my $HOME   = $ENV{HOME};
my $etcdir = '/etc';
my ($setting, $value);
my @config_files = ("$etcdir/colordiffrc");
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

    while (my $arg = shift) {
        if ($arg eq "--") {
            $ddash = 1;
            next;
        }
        if ($ddash) {
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
    #    $isref       is reference to @inputstream
    #    $allow_diffy is flag indicating whether diffy is a
    #                   permitted diff type
    my $isref = shift;
    my $allow_diffy = shift;
    my @is = @$isref;

    # This may not be perfect - should identify most reasonably
    # formatted diffs and patches

    foreach my $record (@is) {
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
    }
    $diff_type = 'unknown';
}

my $enable_verifymode;
my $specified_difftype;
my $enable_fakeexitcode;
my $colormode = "auto";
GetOptions(
    # --enable-verifymode option is for testing behaviour of colordiff
    # against standard test diffs
    "verifymode" => \$enable_verifymode,
    "fakeexitcode" => \$enable_fakeexitcode,
    "difftype=s" => \$specified_difftype,
    "color=s" => \$colormode
    # TODO - check that specified type is valid, issue warning if not
);

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
                    $colourval = "\033[0;9${value}m";
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

# --color=yes and --color=no will override the color_patches setting
if ($colormode eq "yes") {
    $color_patch = 1;
} elsif ($colormode eq "no") {
    $color_patch = 0;
}

# If output is not a terminal, switch off colours, unless 'color_patch' is set
# Relates to http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=378563
if ((! -t 1) && ($color_patch == 0)) {
    $plain_text  = '';
    $file_old    = '';
    $file_new    = '';
    $diff_stuff  = '';
    $cvs_stuff   = '';
    $plain_text  = '';
    $colour{off} = '';
}


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

my $exitcode = 0;
if ($operating_methodology == 1) {
    # Run diff and then post-process the output
    my $pid = open2(\*INPUTSTREAM, undef, "$diff_cmd", @ARGV);
    @inputstream = <INPUTSTREAM>;
    close INPUTSTREAM;
    waitpid $pid, 0;
    $exitcode=$? >> 8;
}
else {
    # No need to call diff, just process standard input
    @inputstream = <STDIN>;
}

# Input stream has been read - need to examine it
# to determine type of diff we have.

my $record;
my $longest_record = 0;

if (defined $specified_difftype) {
    $diff_type = $specified_difftype;
}
else {
    # Detect diff type, diffy is permitted
    $diff_type = detect_diff_type(\@inputstream, 1);
}

my $inside_file_old = 1;

# ------------------------------------------------------------------------------
# Special pre-processing for side-by-side diffs
# Figure out location of central markers: these will be a consecutive set of
# three columns where the first and third always consist of spaces and the
# second consists only of spaces, '<', '>' and '|'
# This is not a 100% certain match, but should be good enough

my %separator_col  = ();
my %candidate_col  = ();
my $diffy_sep_col  = 0;
my $mostlikely_sum = 0;

if ($diff_type eq 'diffy') {
    # Not very elegant, but does the job
    # Unfortunately requires parsing the input stream multiple times
    foreach (@inputstream) {
        $record = expand_tabs_to_spaces $_;
        $longest_record = length ($record) if (length ($record) > $longest_record);
    }
    for (my $i = 0 ; $i <= $longest_record ; $i++) {
        $separator_col{$i} = 1;
        $candidate_col{$i} = 0;
    }

    foreach (@inputstream) {
        $_ = expand_tabs_to_spaces $_;
        for (my $i = 0 ; $i < (length ($_) - 2) ; $i++) {
            next if (!defined $separator_col{$i});
            next if ($separator_col{$i} == 0);
            my $subsub = substr ($_, $i, 2);
            if ($subsub !~ / [ |<>]/) {
                $separator_col{$i} = 0;
            }
            if ($subsub =~ / [|<>]/) {
                $candidate_col{$i}++;
            }
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
        $diff_type = detect_diff_type(\@inputstream, 0);
    }
}
# ------------------------------------------------------------------------------

foreach (@inputstream) {
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
            print "$diff_stuff";
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
            print "$diff_stuff";
        }
        elsif (/^Only in/) {
            print "$diff_stuff";
        }
        elsif (/^\*\*\* [0-9]+,[0-9]+/) {
            print "$diff_stuff";
            $inside_file_old = 1;
        }
        elsif (/^\*\*\* /) {
            print "$file_old";
        }
        elsif (/^--- [0-9]+,[0-9]+/) {
            print "$diff_stuff";
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
        if (/^-/) {
            print "$file_old";
        }
        elsif (/^\+/) {
            print "$file_new";
        }
        elsif (/^\@/) {
            print "$diff_stuff";
        }
        elsif (/^Only in/) {
            print "$diff_stuff";
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
            print "$diff_stuff";
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
if (defined $enable_fakeexitcode) {
    exit 0;
}
else {
    exit $exitcode;
}
