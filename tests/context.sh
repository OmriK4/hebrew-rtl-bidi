#!/bin/sh
# Checks the context files of layers 1 and 2. Prints one line per failed check.
# Dev tool: uses sh and perl (core JSON::PP) only.
cd "$(dirname "$0")/.." || exit 1

fails=0
fail() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}

perl src/build-context.pl --check >/dev/null 2>&1 || fail "build-context --check exits 0"

for f in session-start user-prompt; do
  file="hooks/context/$f.json"
  if [ ! -f "$file" ]; then
    fail "$file exists"
    continue
  fi
  if LC_ALL=C grep -q '[^ -~	]' "$file"; then
    fail "$file is ASCII only"
  fi
  case "$f" in
    session-start) event=SessionStart ;;
    user-prompt) event=UserPromptSubmit ;;
  esac
  perl -MJSON::PP -e '
    my ($file, $event, $kind) = @ARGV;
    open my $fh, "<:raw", $file or exit 1;
    local $/;
    my $d = eval { JSON::PP->new->decode(<$fh>) } or exit 1;
    my $o = $d->{hookSpecificOutput} or exit 1;
    exit 1 unless $o->{hookEventName} eq $event;
    my $t = $o->{additionalContext};
    exit 1 unless defined $t && length $t;
    if ($kind eq "session-start") {
      exit 1 unless length($t) < 4000;
      my $needle = "\x{05D4}\x{05E1}\x{05E4}\x{05E8}\x{05D9}\x{05D9}\x{05D4} React";
      exit 1 unless index($t, $needle) >= 0;
    }
    exit 0;
  ' "$file" "$event" "$f" 2>/dev/null || fail "$file parses, event is $event, context is valid"
done

if [ ! -f hooks/hooks.json ]; then
  fail "hooks/hooks.json exists"
else
  perl -MJSON::PP -e '
    open my $fh, "<:raw", $ARGV[0] or exit 1;
    local $/;
    my $d = eval { JSON::PP->new->decode(<$fh>) } or exit 1;
    my $h = $d->{hooks} or exit 1;
    exit 1 unless ref $h eq "HASH" && $h->{SessionStart} && $h->{UserPromptSubmit} && $h->{Stop};
    exit 0;
  ' hooks/hooks.json 2>/dev/null || fail "hooks/hooks.json has hooks.SessionStart, hooks.UserPromptSubmit and hooks.Stop"
fi

if [ "$fails" -eq 0 ]; then
  echo "context: all checks passed"
  exit 0
fi
echo "context: $fails check(s) failed"
exit 1
