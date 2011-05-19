#!/usr/bin/perl -w

# cmpVERSION - compare the current Perl source tree and a given tag
# for modules that have identical version numbers but different contents.
#
# with -d option, output the diffs too
# with -x option, exclude files from modules where blead is not upstream
#
# (after all, there are tools like core-cpan-diff that can already deal with
# them)
#
# Original by slaven@rezic.de, modified by jhi and matt.w.johnson@gmail.com.
# Adaptation to produce TAP by Abigail, folded back into this file by Nicholas

use strict;

use ExtUtils::MakeMaker;
use File::Compare;
use File::Spec::Functions qw(devnull);
use Getopt::Long;

my ($diffs, $exclude_upstream, $tag_to_compare, $tap);
unless (GetOptions('diffs' => \$diffs,
		   'exclude|x' => \$exclude_upstream,
		   'tag=s' => \$tag_to_compare,
		   'tap' => \$tap,
		   ) && @ARGV == 0) {
    die "usage: $0 [ -d -x --tag TAG --tap]";
}

die "$0: This does not look like a Perl directory\n"
    unless -f "perl.h" && -d "Porting";
die "$0: 'This is a Perl directory but does not look like Git working directory\n"
    unless -d ".git";

my $null = devnull();

unless (defined $tag_to_compare) {
    # Thanks to David Golden for this suggestion.

    $tag_to_compare = `git describe --abbrev=0`;
    chomp $tag_to_compare;
}

my $tag_exists = `git --no-pager tag -l $tag_to_compare 2>$null`;
chomp $tag_exists;

unless ($tag_exists eq $tag_to_compare) {
    die "$0: '$tag_to_compare' is not a known Git tag\n" unless $tap;
    print "1..0 # SKIP: '$tag_to_compare' is not a known Git tag\n";
    exit 0;
}

my %upstream_files;
if ($exclude_upstream) {
    unshift @INC, 'Porting';
    require Maintainers;

    for my $m (grep {!defined $Maintainers::Modules{$_}{UPSTREAM}
			 or $Maintainers::Modules{$_}{UPSTREAM} ne 'blead'}
	       keys %Maintainers::Modules) {
	$upstream_files{$_} = 1 for Maintainers::get_module_files($m);
    }
}

# Files to skip from the check for one reason or another,
# usually because they pull in their version from some other file.
my %skip;
@skip{
    'lib/Carp/Heavy.pm',
    'lib/Config.pm',		# no version number but contents will vary
    'lib/Exporter/Heavy.pm',
    'win32/FindExt.pm',
} = ();

# Files to skip just for particular version(s),
# usually due to some # mix-up

my %skip_versions;
if ($tap) {
    %skip_versions
	= (
	   # 'some/sample/file.pm' => [ '1.23', '1.24' ],
	   'dist/threads/lib/threads.pm' => [ '1.83' ],
	  );
}

my $skip_dirs = qr|^t/lib|;

my @all_diffs = `git --no-pager diff --name-only $tag_to_compare`;
chomp @all_diffs;

my @module_diffs = grep {
    my $this_dir;
    $this_dir = $1 if m/^(.*)\//;
    /\.pm$/ &&
    (!defined($this_dir) || ($this_dir !~ $skip_dirs)) &&
    !exists $skip{$_} &&
    !exists $upstream_files{$_}
} @all_diffs;

unless (@module_diffs) {
    print "1..1\nok 1 - No difference found\n" if $tap;
    exit;
}

printf "1..%d\n" => scalar @module_diffs if $tap;

my $count;
my $diff_cmd = "git --no-pager diff $tag_to_compare ";
my (@diff);

foreach my $pm_file (sort @module_diffs) {
    # --tap does diff inline, --diff does it at the end.
    @diff = () if $tap;
    (my $xs_file = $pm_file) =~ s/\.pm$/.xs/;
    my $pm_eq = compare_git_file($pm_file, $tag_to_compare);
    next unless defined $pm_eq;
    my $xs_eq = 1;
    if (-e $xs_file) {
        $xs_eq = compare_git_file($xs_file, $tag_to_compare);
        next unless defined $xs_eq;
    }
    next if ($pm_eq && $xs_eq);
    my $pm_version = eval {MM->parse_version($pm_file)};
    my $orig_pm_content = get_file_from_git($pm_file, $tag_to_compare);
    my $orig_pm_version = eval {MM->parse_version(\$orig_pm_content)};
    next if ( ! defined $pm_version || ! defined $orig_pm_version );
    next if ( $pm_version eq 'undef' || $orig_pm_version eq 'undef' ); # sigh
    next if $pm_version ne $orig_pm_version;
    next if exists $skip_versions{$pm_file}
	 and grep $pm_version eq $_, @{$skip_versions{$pm_file}};
    push @diff, $pm_file unless $pm_eq;
    push @diff, $xs_file unless $xs_eq;
}
continue {
    if (@diff) {
	if ($tap) {
	    foreach (@diff) {
		print "# $_" for `$diff_cmd '$_'`;
	    }
	    printf "not ok %d - %s\n", ++$count, $pm_file;
	} else {
	    print "$pm_file\n";
	}
    }
    elsif ($tap) {
        printf "ok %d - %s\n", ++$count, $pm_file;
    }
}

sub compare_git_file {
    my ($file, $tag) = @_;
    open(my $orig_fh, "-|", "git --no-pager show $tag:$file 2>$null");
    return undef if eof($orig_fh);
    my $is_eq = compare($file, $orig_fh) == 0;
    close($orig_fh);
    return $is_eq;
}

sub get_file_from_git {
    my ($file, $tag) = @_;
    local $/ = undef;
    my $file_content = `git --no-pager show $tag:$file 2>$null`;
    return $file_content;
}

if ($diffs) {
    for (sort @diff) {
	print "\n";
	system "$diff_cmd '$_'";
    }
}
