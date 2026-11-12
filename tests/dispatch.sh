#!/bin/sh
# Checks that the Stop command string in hooks/hooks.json runs under sh, with
# CLAUDE_PLUGIN_ROOT set to the repo, to a copy in a path with a space and
# Hebrew letters (the copy prints a marker, so the test proves that the copy
# was the one that ran), and to a directory that does not exist (the command
# must end silently with exit 0). Prints one line per failed check, then a
# summary line.
# Dev tool: uses sh and perl (core JSON::PP) only.
root=$(cd "$(dirname "$0")/.." && pwd) || exit 1
cd "$root" || exit 1

tmp=$(mktemp -d "${TMPDIR:-/tmp}/rtl-dispatch.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
trap 'rm -rf "$tmp"; exit 1' INT TERM

fails=0
fail() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}

# The Stop command string, decoded from hooks.json.
perl -MJSON::PP -e '
  open my $fh, "<:raw", $ARGV[0] or exit 1;
  local $/;
  my $d = eval { JSON::PP->new->decode(<$fh>) } or exit 1;
  my $cmd = eval { $d->{hooks}{Stop}[0]{hooks}[0]{command} };
  exit 1 unless defined $cmd && length $cmd;
  print $cmd;
' hooks/hooks.json >"$tmp/command" 2>/dev/null
if [ ! -s "$tmp/command" ]; then
  fail "hooks/hooks.json has a Stop command"
  echo "dispatch: $fails check(s) failed"
  exit 1
fi

# make_input <file>: wraps a text file as a Stop event JSON.
make_input() {
  perl -MJSON::PP -e '
    local $/;
    open my $fh, "<:raw", $ARGV[0] or exit 1;
    my $msg = <$fh>;
    utf8::decode($msg);
    print JSON::PP->new->utf8->encode({
      hook_event_name => "Stop",
      stop_hook_active => JSON::PP::false,
      last_assistant_message => $msg,
    });
  ' "$1"
}

# An input that cannot be built must fail the whole test. Without this, a
# missing case file would give an empty input and the "ok" checks would pass
# without testing anything.
build_input() {
  if ! make_input "$1" >"$2" || [ ! -s "$2" ]; then
    fail "build the test input from $1"
    echo "dispatch: $fails check(s) failed"
    exit 1
  fi
}
build_input tests/cases/bidi/list-item-latin-start.md "$tmp/in-bidi"
build_input tests/cases/ok/short.md "$tmp/in-ok"

# check_root <label> <plugin root> <marker|nomarker>: runs the Stop command
# twice with that root. With "marker" the bidi output must contain COPYMARK
# (the copy ran); with "nomarker" it must not (the repo script ran).
check_root() {
  label=$1
  plugin_root=$2
  marker=$3
  CLAUDE_PLUGIN_ROOT=$plugin_root sh -c "$(cat "$tmp/command")" <"$tmp/in-bidi" >"$tmp/out" 2>"$tmp/err"
  code=$?
  [ "$code" -eq 0 ] || fail "$label: bidi input exits 0 (got $code)"
  grep -qF '[hebrew-rtl-bidi:bidi]' "$tmp/out" || fail "$label: bidi input prints the bidi tag"
  [ ! -s "$tmp/err" ] || fail "$label: bidi input prints nothing to stderr"
  if [ "$marker" = marker ]; then
    grep -qF COPYMARK "$tmp/out" || fail "$label: the copy under this path is the script that ran"
  else
    ! grep -qF COPYMARK "$tmp/out" || fail "$label: the repo script is the script that ran"
  fi

  CLAUDE_PLUGIN_ROOT=$plugin_root sh -c "$(cat "$tmp/command")" <"$tmp/in-ok" >"$tmp/out" 2>"$tmp/err"
  code=$?
  [ "$code" -eq 0 ] || fail "$label: ok input exits 0 (got $code)"
  [ ! -s "$tmp/out" ] || fail "$label: ok input prints nothing"
  [ ! -s "$tmp/err" ] || fail "$label: ok input prints nothing to stderr"
}

check_root "repo root" "$root" nomarker

# A copy of the plugin in a path with a space and Hebrew letters. The copy of
# stop-check.pl is changed so that its bidi correction text carries a marker.
copy_parent="$tmp/תיקייה עם רווח"
mkdir -p "$copy_parent/plugin" || fail "create the copy directory"
cp -R hooks "$copy_parent/plugin/hooks" || fail "copy hooks/ to the test path"
perl -pi -e 's/\[hebrew-rtl-bidi:bidi\] These lines/[hebrew-rtl-bidi:bidi] COPYMARK These lines/' \
  "$copy_parent/plugin/hooks/stop-check.pl" || fail "mark the copy"
grep -qF COPYMARK "$copy_parent/plugin/hooks/stop-check.pl" || fail "the copy carries the marker"
if grep -qF COPYMARK hooks/stop-check.pl; then
  fail "the repo script must not carry the marker"
fi
check_root "path with space and Hebrew" "$copy_parent/plugin" marker

# A plugin root that does not exist: exit 0, no output, no stderr.
CLAUDE_PLUGIN_ROOT="$tmp/no-such-directory" sh -c "$(cat "$tmp/command")" <"$tmp/in-bidi" >"$tmp/out" 2>"$tmp/err"
code=$?
[ "$code" -eq 0 ] || fail "missing plugin root: exits 0 (got $code)"
[ ! -s "$tmp/out" ] || fail "missing plugin root: prints nothing"
[ ! -s "$tmp/err" ] || fail "missing plugin root: prints nothing to stderr"

if [ "$fails" -eq 0 ]; then
  echo "dispatch: all checks passed"
  exit 0
fi
echo "dispatch: $fails check(s) failed"
exit 1
