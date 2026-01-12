#!/usr/bin/perl

########################################################################
#                                                                      #
# ColorDiff - a wrapper/replacement for 'diff' producing               #
#             colourful output                                         #
#                                                                      #
# Copyright (C)2002-2020 Dave Ewart (davee@sungate.co.uk)              #
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

use warnings;
use strict;
use Getopt::Long qw(:config pass_through no_auto_abbrev);

my $app_name     = 'colordiff';
my $version      = '1.0.22';
my $author       = 'Dave Ewart';
my $author_email = 'davee@sungate.co.uk';
my $app_www      = 'http://www.colordiff.org/';
my $copyright    = '(C)2002-2026';
my $show_banner  = 1;
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

# Config options controlling presence or absence of colour in output
# cfg_* options come from config files
# cmd_* options come from the command line
my $cfg_color_mode   = 1;
my $cfg_color_patch  = 0;
my $cmd_color_mode   = undef;
my $cmd_color_patch  = undef;
my $color_mode       = undef;
my $color_patch      = undef;

# Locations for personal and system-wide colour configurations
my $HOME = (grep { defined && length }
        @ENV{qw/HOME USERPROFILE/})[0] || '';
my $etcdir = (grep { defined && length && -d }
	'/etc', $ENV{ALLUSERSPROFILE})[0] || '/etc';
my ($setting, $value);
my @config_files = ("$etcdir/colordiffrc");
my $USER_CONFIG_DIR = (grep { defined && length }
        @ENV{qw/XDG_CONFIG_HOME LOCALAPPDATA APPDATA/})[0] || '';
if (length $USER_CONFIG_DIR) {
    push (@config_files, "${USER_CONFIG_DIR}/colordiff/colordiffrc")
}
elsif (length $HOME) {
    push (@config_files, "${HOME}/.config/colordiff/colordiffrc")
}
push (@config_files, "${HOME}/.colordiffrc") if length $HOME;
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
my $color_term_output_only = "no";
my $cmd_banner;
my $cmd_help;

# Command-line options may over-ride config files
GetOptions(
    # --enable-verifymode option is for testing behaviour of colordiff
    # against standard test diffs
    "verifymode" => \$enable_verifymode,
    "fakeexitcode" => \$enable_fakeexitcode,
    "difftype=s" => \$specified_difftype,
    "color=s" => \$cmd_color_mode,
    "color-patches=s" => \$cmd_color_patch,
    "color-term-output-only=s" => \$color_term_output_only,
    "help" => \$cmd_help,
    "banner!" => \$cmd_banner
);

if (defined $cmd_help) {
    print "colordiff:\n";
    print "    --help                   : Displays this help\n";
    print "    --color=(yes|no)         : Force (or suppress) display of colours in output\n";
    print "    --color=patches=(yes|no) : Force (or suppress) inclusion of colour codes in patch output\n";
    print "    --color-term-output-only : Force (or suppress) colour to only appear in terminal output\n";
    print "    --difftype=DIFFTYPE      : Force difftype detection to specified format\n";
    print "    --(no)banner             : Show (or suppress) the colordiff banner\n";
    print "\n";
    print "    DIFFTYPE is usually auto-detected, but can be set to:\n";
    print "          diff, diffc, diffu, diffy, debdiff or wdiff\n";
    exit(0);
}

$_ = $specified_difftype;
if (defined $_ and not /^diff[cuy]?|(deb|w)diff$/) {
    print STDERR "Invalid --difftype value\n";
}

if (defined $enable_verifymode) {
    # When in verify mode, to ensure consistent output we don't source
    # any external config files
    @config_files = ();
}

# Read config file options
foreach $config_file (@config_files) {
    if (open (COLORDIFFRC, "<$config_file")) {
        while (<COLORDIFFRC>) {
            my $colourval;

            chop;
            next if (/^#/ || /^$/);
            s/\s+//g;
            ($setting, $value) = split ('=');
            if (!defined $value) {
                print STDERR "Ignored invalid configuration line ($_) in $config_file\n";
                next;
            }
            if ($setting eq 'banner') {
                if ($value eq 'yes') {
                    $show_banner = 1;
                } elsif ($value eq 'no') {
                    $show_banner = 0;
                }
                next;
            }
            if ($setting eq 'color_mode') {
                if ($value eq 'yes') {
                    $cfg_color_mode = 1;
                } elsif ($value eq 'no') {
                    $cfg_color_mode = 0;
                }
                next;
            }
            if ($setting eq 'color_patches') {
                if ($value eq 'yes') {
                    $cfg_color_patch = 1;
                } elsif ($value eq 'no') {
                    $cfg_color_patch = 0;
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
            # Find full 24-bit colour spec string
            if (( $value =~ m/^([0-9];)*([34]8);2;([0-9]+);([0-9]+);([0-9]+)$/) &&
                    ($3 >= 0) && ($3 <= 255) &&
                    ($4 >= 0) && ($4 <= 255) &&
                    ($5 >= 0) && ($5 <= 255)
                    ) {
                $colourval = "\033[$1$2;2;$3;$4;$5m";
            }
            # 256 colour single value
            elsif ($value =~ m/^[0-9]+$/ && $value >= 0 && $value <= 255) {
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
# Default color_mode is 1, over-ridden by config files
# All over-ridden by command line options
$color_mode = 1;
if ($cfg_color_mode == 0) {
    $color_mode = 0;
}
if (defined $cmd_color_mode) {
    if ($cmd_color_mode eq 'yes' 
            || $cmd_color_mode eq 'always'
            || $cmd_color_mode eq 'auto') {
        $color_mode = 1;
    }
    elsif ($cmd_color_mode eq 'no'
            || $cmd_color_mode eq 'never') {
        $color_mode = 0;
    }
}

# Default color_patch is 0, over-ridden by config files
# All over-ridden by command line options
$color_patch = 0;
if (defined $cfg_color_patch) {
    if ($cfg_color_patch == 1) {
        $color_patch = 1;
    }
}
if (defined $cmd_color_patch) {
    if ($cmd_color_patch eq 'yes' 
            || $cmd_color_patch eq 'always'
            || $cmd_color_patch eq 'auto') {
        $color_patch = 1;
    }
    elsif ($cmd_color_patch eq 'no'
            || $cmd_color_patch eq 'never') {
        $color_patch = 0;
    }
}

if (defined $enable_verifymode) {
    # When in verify mode, to ensure consistent output we use built-in defaults
    # and we add colour to our patches
    $color_patch  = 1;
    $show_banner  = 0;
}

# Switch off colours if any of these are true:
#  - color_mode is no
#  - output to a file unless overriden by $color_patch.
#  - color_term_output_only is set and output not to a terminal
if ( (!$color_mode) ||
     (-f STDOUT && ($color_patch != 1)) ||
     ($color_term_output_only eq 'yes' && !-t STDOUT) )
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

# If command-line option refers to banner, honour this ahead of config files
if (defined $cmd_banner) {
    if ($cmd_banner) {
        $show_banner = 1;
    }
    if (!$cmd_banner) {
        $show_banner = 0;
    }
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
            if ($subsub !~ / [ (|<>\\\/]/) {
                $separator_col{$i} = 0;
                if ($candidate_col{$i} > 0) {
                    $possible_cols--;
                }
            }
            if ($subsub =~ / [|<>\\\/]/) {
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
my $count_marks = 1;

while (defined( $_ = @inputstream ? shift @inputstream : ($lastline and <$inputhandle>) )) {
    if (($diffy_sep_col == 0) && (/^Binary files (.*) and (.*) differ$/)) {
        print "Binary files $file_old$1$plain_text and $file_new$2$plain_text differ$colour{off}\n";
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
            print "$diff_file";
        }
        elsif (/^--- [0-9]+,[0-9]+/) {
            print "$diff_file";
            $inside_file_old = 0;
        }
        elsif (/^--- /) {
            print "$diff_file";
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
        elsif (/^([-\+ ]{$count_marks})/) {
            my $diff_marks = $1;
            if ($diff_marks =~ /-/) {
                print $file_old;
            }
            elsif ($diff_marks =~ /\+/) {
                print $file_new;
            }
        }
        elsif (/^(\@+)/) {
            $count_marks = length($1) - 1;
            print "$diff_stuff";
        }
        elsif (/^Only in/) {
            print "$diff_file";
        }
        elsif (/^(Index: |={4,}|RCS file: |retrieving |diff |old |new |deleted |copy |rename |similarity |dissimilarity |index |reverted:$|unchanged:$|only in patch2:$)/) {
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
            elsif ($sepchars eq ' |' || $sepchars eq ' /' || $sepchars eq ' \\') {
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
