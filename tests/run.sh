#!/bin/sh
# Usage: sh tests/run.sh [command ...]
# Runs every example under tests/cases/{ok,english,bidi} through the stop-check
# command (default: perl hooks/stop-check.pl) and a few special cases.
# Prints FAIL: <case> for each failure and PASS: <n>/<total>. Exit 1 on failure.
# Dev tool: uses sh and perl (core JSON::PP) only.
cd "$(dirname "$0")/.." || exit 1

if [ $# -eq 0 ]; then
  set -- perl hooks/stop-check.pl
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/rtl-bidi.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
trap 'rm -rf "$tmp"; exit 1' INT TERM

TAG_EN='[hebrew-rtl-bidi:english]'
TAG_LINES='[hebrew-rtl-bidi:english-lines]'
TAG_BIDI='[hebrew-rtl-bidi:bidi]'
total=0
passed=0

# make_input <file> <true|false>: wraps a text file as a Stop event JSON.
make_input() {
  perl -MJSON::PP -e '
    local $/;
    open my $fh, "<:raw", $ARGV[0] or exit 1;
    my $msg = <$fh>;
    utf8::decode($msg);
    print JSON::PP->new->utf8->encode({
      hook_event_name => "Stop",
      stop_hook_active => ($ARGV[1] eq "true" ? JSON::PP::true : JSON::PP::false),
      last_assistant_message => $msg,
    });
  ' "$1" "$2"
}

# verdict <name> <silent|english|english-lines|bidi>: judges the last run, using $code and
# the files $tmp/out and $tmp/err. The tag is looked up in the raw output.
verdict() {
  total=$((total + 1))
  name=$1
  want=$2
  ok=1
  [ "$code" -eq 0 ] || ok=0
  [ ! -s "$tmp/err" ] || ok=0
  case "$want" in
    silent)
      [ ! -s "$tmp/out" ] || ok=0
      ;;
    english)
      grep -qF "$TAG_EN" "$tmp/out" || ok=0
      ! grep -qF "$TAG_LINES" "$tmp/out" || ok=0
      ! grep -qF "$TAG_BIDI" "$tmp/out" || ok=0
      ;;
    english-lines)
      grep -qF "$TAG_LINES" "$tmp/out" || ok=0
      ! grep -qF "$TAG_EN" "$tmp/out" || ok=0
      ! grep -qF "$TAG_BIDI" "$tmp/out" || ok=0
      ;;
    bidi)
      grep -qF "$TAG_BIDI" "$tmp/out" || ok=0
      ! grep -qF "$TAG_EN" "$tmp/out" || ok=0
      ! grep -qF "$TAG_LINES" "$tmp/out" || ok=0
      ;;
  esac
  if [ "$ok" -eq 1 ]; then
    passed=$((passed + 1))
  else
    echo "FAIL: $name"
  fi
}

for kind in ok english english-lines bidi; do
  case "$kind" in
    ok) want=silent ;;
    *) want=$kind ;;
  esac
  for f in tests/cases/"$kind"/*.md; do
    [ -f "$f" ] || continue
    make_input "$f" false > "$tmp/in"
    "$@" < "$tmp/in" > "$tmp/out" 2> "$tmp/err"
    code=$?
    verdict "$kind/$(basename "$f")" "$want"
  done
done

# Special case: stop_hook_active is true, so nothing is checked.
make_input tests/cases/english/full-answer.md true > "$tmp/in"
"$@" < "$tmp/in" > "$tmp/out" 2> "$tmp/err"
code=$?
verdict "special/stop-hook-active" silent

# Special case: input that is not JSON.
printf 'not json' > "$tmp/in"
"$@" < "$tmp/in" > "$tmp/out" 2> "$tmp/err"
code=$?
verdict "special/not-json" silent

# Special case: empty input.
: > "$tmp/in"
"$@" < "$tmp/in" > "$tmp/out" 2> "$tmp/err"
code=$?
verdict "special/empty-input" silent

# Special case: JSON without last_assistant_message.
printf '{"hook_event_name":"Stop","stop_hook_active":false}' > "$tmp/in"
"$@" < "$tmp/in" > "$tmp/out" 2> "$tmp/err"
code=$?
verdict "special/missing-field" silent

# Special case: last_assistant_message is not a string.
printf '{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":123}' > "$tmp/in"
"$@" < "$tmp/in" > "$tmp/out" 2> "$tmp/err"
code=$?
verdict "special/non-string-message" silent

# Special case: a UTF-8 byte order mark before the JSON is ignored.
printf '\357\273\277{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"OK"}' > "$tmp/in"
"$@" < "$tmp/in" > "$tmp/out" 2> "$tmp/err"
code=$?
verdict "special/utf8-bom" english

# Special case: stdout is closed. Still exit 0, nothing on stderr.
make_input tests/cases/english/two-letters.md false > "$tmp/in"
"$@" < "$tmp/in" >&- 2> "$tmp/err"
code=$?
: > "$tmp/out"
verdict "special/closed-stdout" silent

# Special case: the reader of stdout is gone (broken pipe).
{ "$@" < "$tmp/in" 2> "$tmp/err"; echo $? > "$tmp/code"; } | true
code=$(cat "$tmp/code")
: > "$tmp/out"
verdict "special/broken-pipe" silent

# Special case: at most three offending lines are quoted.
make_input tests/cases/bidi/many-lines.md false > "$tmp/in"
"$@" < "$tmp/in" > "$tmp/out" 2> "$tmp/err"
code=$?
total=$((total + 1))
quoted=$(grep -o '\\n- ' "$tmp/out" | wc -l | tr -d ' ')
if [ "$quoted" -eq 3 ] && [ "$code" -eq 0 ] && [ ! -s "$tmp/err" ]; then
  passed=$((passed + 1))
else
  echo "FAIL: special/quote-limit"
fi

# Special case: a valid Hebrew message of at least 200,000 characters must be
# accepted without output, in under two seconds.
perl -e '
  local $/;
  open my $fh, "<:raw", $ARGV[0] or exit 1;
  my $unit = <$fh>;
  utf8::decode($unit);
  my $msg = "";
  $msg .= $unit while length($msg) < 200000;
  binmode STDOUT, ":utf8";
  print $msg;
' tests/cases/ok/change-summary.md > "$tmp/big.md"
make_input "$tmp/big.md" false > "$tmp/in"
start=$(perl -MTime::HiRes=time -e 'print time')
"$@" < "$tmp/in" > "$tmp/out" 2> "$tmp/err"
code=$?
stop=$(perl -MTime::HiRes=time -e 'print time')
verdict "special/big-hebrew-message" silent
total=$((total + 1))
if perl -e 'exit(($ARGV[1] - $ARGV[0]) < 2 ? 0 : 1)' "$start" "$stop"; then
  passed=$((passed + 1))
else
  echo "FAIL: special/big-hebrew-message-under-2s"
fi

echo "PASS: $passed/$total"
[ "$passed" -eq "$total" ]
