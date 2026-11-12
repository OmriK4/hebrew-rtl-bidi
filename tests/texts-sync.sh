#!/bin/sh
# Checks that hooks/stop-check.pl and hooks/stop-check.ps1 carry the same three
# tags and the same correction texts, word for word. This is the drift guard
# for machines without PowerShell. Both files lay each text out as one
# assignment of single-quoted pieces joined by "." (Perl) or "+" (PowerShell):
#   $TEXT_NAME = '...' . '...';        $script:TEXT_NAME = '...' +
#                                          '...'
# so the texts must not contain an apostrophe or a backslash. Prints one line
# per failed check, then a summary line.
# Dev tool: uses sh and perl (core modules only).
cd "$(dirname "$0")/.." || exit 1

out=$(perl -e '
  use strict;
  use warnings;
  my ($pl, $ps) = @ARGV;
  my @names = qw(TEXT_ENGLISH TEXT_ENGLISH_LINES_HEAD TEXT_ENGLISH_LINES_TAIL
                 TEXT_BIDI_HEAD TEXT_BIDI_TAIL);
  my %tag_of = (TEXT_ENGLISH => "english", TEXT_ENGLISH_LINES_HEAD => "english-lines",
                TEXT_BIDI_HEAD => "bidi");
  my $fails = 0;
  sub fail { print "FAIL: $_[0]\n"; $fails++; }

  sub texts_of {
    my ($file) = @_;
    my %t;
    open my $fh, "<:raw", $file or do { fail("cannot read $file"); return \%t; };
    local $/;
    my $src = <$fh>;
    close $fh;
    while ($src =~ /\$(?:script:)?(TEXT_[A-Z_]+)\s*=\s*((?:\x27[^\x27]*\x27\s*[.+]?\s*)+)/g) {
      my ($name, $body) = ($1, $2);
      fail("$file assigns $name more than once") if exists $t{$name};
      $t{$name} = join "", $body =~ /\x27([^\x27]*)\x27/g;
    }
    return \%t;
  }

  my %src = (pl => texts_of($pl), ps => texts_of($ps));
  for my $name (@names) {
    my ($x, $y) = ($src{pl}{$name}, $src{ps}{$name});
    unless (defined $x && length $x) { fail("$pl has $name"); next; }
    unless (defined $y && length $y) { fail("$ps has $name"); next; }
    fail("$name is the same in both files") unless $x eq $y;
    if (my $tag = $tag_of{$name}) {
      my $want = "[hebrew-rtl-bidi:$tag]";
      fail("$name starts with the tag $want in $pl") unless index($x, $want) == 0;
      fail("$name starts with the tag $want in $ps") unless index($y, $want) == 0;
    }
  }
  exit($fails > 0 ? 1 : 0);
' hooks/stop-check.pl hooks/stop-check.ps1 2>&1)
code=$?

[ -z "$out" ] || printf '%s\n' "$out"
if [ "$code" -eq 0 ]; then
  echo "texts-sync: all checks passed"
  exit 0
fi
fails=$(printf '%s\n' "$out" | grep -c '^FAIL:')
[ "$fails" -gt 0 ] || fails=1
echo "texts-sync: $fails check(s) failed"
exit 1
