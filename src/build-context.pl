#!/usr/bin/perl
# Builds hooks/context/*.json from the readable sources in src/*.txt.
#   perl src/build-context.pl          rewrite both JSON files
#   perl src/build-context.pl --check  exit 0 if they match the sources, 1 if not
# Dev tool only. Runtime hooks just `cat` the generated files.
use strict;
use warnings;
use JSON::PP;
use File::Basename qw(dirname);
use File::Spec;

my $root = File::Spec->catdir(dirname(__FILE__), '..');
my $check = (@ARGV && $ARGV[0] eq '--check');

my @targets = (
    [ 'session-start', 'SessionStart' ],
    [ 'user-prompt',   'UserPromptSubmit' ],
);

my $json = JSON::PP->new->ascii->canonical;
my $bad = 0;

for my $t (@targets) {
    my ($name, $event) = @$t;
    my $src = "$root/src/$name.txt";
    my $out = "$root/hooks/context/$name.json";

    open my $in, '<:encoding(UTF-8)', $src or die "cannot read $src: $!\n";
    local $/;
    my $text = <$in>;
    close $in;
    $text =~ s/\n\z//;

    my $doc = $json->encode({
        hookSpecificOutput => {
            hookEventName     => $event,
            additionalContext => $text,
        },
    }) . "\n";

    if ($check) {
        my $current = '';
        if (open my $fh, '<:raw', $out) {
            $current = <$fh>;
            close $fh;
        }
        if ($current ne $doc) {
            print "out of date: hooks/context/$name.json\n";
            $bad = 1;
        }
    } else {
        open my $fh, '>:raw', $out or die "cannot write $out: $!\n";
        print $fh $doc;
        close $fh;
    }
}

exit($bad);
