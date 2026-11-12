#!/bin/sh
# Usage: sh tests/check-file.sh <path>
# Feeds one text file to hooks/stop-check.pl as the last assistant message
# and prints the raw output. Empty output means the text is fine.
# Dev tool: uses sh and perl (core JSON::PP) only.
if [ $# -ne 1 ] || [ ! -f "$1" ]; then
  echo "usage: sh tests/check-file.sh <path>" >&2
  exit 2
fi
root=$(cd "$(dirname "$0")/.." && pwd) || exit 1

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
' "$1" | perl "$root/hooks/stop-check.pl"
