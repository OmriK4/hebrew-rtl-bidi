# Stop hook: checks the last assistant message of a Claude Code session.
# Reads the Stop event JSON on stdin. Prints nothing when the message is fine,
# or one JSON line asking Claude to fix it. Always exits 0 and never writes to
# stderr. Run as: perl hooks/stop-check.pl
#
# Verdicts, first match wins:
#   english        the message has no Hebrew word and has an English word.
#   english-lines  a line (or table cell) has no Hebrew word, 4+ English words,
#                  and at least 2 of them start with a lowercase letter (a line of
#                  names such as "Visual Studio Code Insiders Edition" is not prose).
#   bidi           a line contains Hebrew but its first letter is Latin, so the
#                  chat UI lays it out left-to-right and the Hebrew comes out
#                  scrambled.
#
# Kept simple on purpose (plain regexes, one line loop) so it is easy to port.
# This file is ASCII only: Hebrew is written as \x{05D0}-\x{05EA}.

# Old Perls keep "." in @INC, and the working directory is the user's project:
# drop it before any module is loaded.
BEGIN { pop @INC if @INC && $INC[-1] eq '.' }

use strict;
use warnings;

BEGIN {
    $SIG{__WARN__} = sub { };
    $SIG{PIPE}     = 'IGNORE';
}

my $TEXT_ENGLISH = '[hebrew-rtl-bidi:english] Your last message was written in English, '
    . 'and the user reads Hebrew. Write the same message again in Hebrew, following '
    . 'the Hebrew and mixed-text rules from the start of the session. Output only '
    . 'the rewritten message, with no apology and no explanation of the correction.';

my $TEXT_ENGLISH_LINES_HEAD = '[hebrew-rtl-bidi:english-lines] These lines in your last message '
    . 'are in English, and the user reads Hebrew:';

my $TEXT_ENGLISH_LINES_TAIL = 'Write only these lines again in Hebrew. Text that has to stay in '
    . 'English, such as a command, a path, an error message or text the user asked for '
    . 'in English, goes inside backticks or a code block. '
    . 'Output only the corrected lines, with no apology and no explanation of the correction.';

my $TEXT_BIDI_HEAD = '[hebrew-rtl-bidi:bidi] These lines in your last message contain Hebrew '
    . 'but start with an English word, so the interface lays them out left-to-right '
    . 'and the Hebrew comes out scrambled:';

my $TEXT_BIDI_TAIL = 'Write only these lines again, rephrased so that each one opens with a '
    . 'Hebrew word and still reads as natural Hebrew. Usually a Hebrew noun that '
    . 'describes the term goes first, such as the Hebrew word for command, library or '
    . 'file. Do not just attach a Hebrew prefix letter to the English word when that '
    . 'makes the sentence ungrammatical. '
    . 'Output only the corrected lines, with no apology and no explanation of the correction.';

my $MAX_QUOTES    = 3;     # at most this many offending units are quoted
my $MAX_QUOTE_LEN = 80;    # each quote is cut to this many characters

# What may come before a fence or a quoted line: spaces, blockquote markers
# (">") and list markers ("-", "*", "+", "1.", "1)") followed by a space.
my $CONTAINER = qr/(?:\s|>|(?:[-*+]|\d+[.)])\s)*/;

# An inline code span: a run of N backticks, up to the next run of exactly N.
# Used with s///: the whole span is $1 and its opening run is $2.
my $CODE_SPAN = qr/((?<!`)(`+)(?!`).*?(?<!`)\2(?!`))/;

# Returns true when the unit (one line, or one table cell) contains Hebrew but
# its first letter is Latin. Anything that is not a letter is skipped.
sub is_bidi_problem {
    my ($unit) = @_;
    # A task-list box "[ ]" or "[x]" after the list marker is not text.
    $unit =~ s/^((?:\s*>)*\s*(?:(?:[-*+]|\d+[.)])\s+)?)\[[ xX]\]/$1/;
    my ($first) = $unit =~ /([A-Za-z\x{05D0}-\x{05EA}])/;
    return 0 unless defined $first && $first =~ /[A-Za-z]/;
    return $unit =~ /[\x{05D0}-\x{05EA}]/ ? 1 : 0;
}

# Cuts a unit down to a one-line quote for the correction request: no leading
# list or blockquote marker, at most $MAX_QUOTE_LEN characters.
sub make_quote {
    my ($unit) = @_;
    $unit =~ tr/\x01/|/;
    $unit =~ s/^$CONTAINER//;
    $unit =~ s/\s+\z//;
    $unit = substr($unit, 0, $MAX_QUOTE_LEN) if length($unit) > $MAX_QUOTE_LEN;
    return $unit;
}

# Hides "|" inside `code` so that it does not split a table cell.
sub mask_pipes_in_code {
    my ($row) = @_;
    $row =~ s/$CODE_SPAN/my $c = $1; $c =~ tr{|}{\x01}; $c/ge;
    return $row;
}

# A Markdown link or image, inline "[title](target)" or reference "[title][ref]",
# is a name, not prose: its title is dropped, unless the title has Hebrew.
sub link_title {
    my ($title) = @_;
    return $title =~ /[\x{05D0}-\x{05EA}]/ ? $title : '';
}

# Counts the tokens of a unit after removing code, Markdown links and images
# and URLs. This is for the english rules only; the bidi rule keeps link text.
# Returns (Hebrew tokens, English words, lowercase English words). A Hebrew token
# has a Hebrew letter. An English word is a token that, without the
# non-alphanumeric characters at both ends, is 2+ ASCII letters (inner ' and -
# allowed): "Done." yes, "index.tsx", "v2", "foo_bar" and "x" no. A lowercase
# English word is one that starts with [a-z]. A Markdown reference definition
# line, "[1]: https://... \"Title\"", is not prose and has no tokens.
sub count_tokens {
    my ($unit) = @_;
    return (0, 0, 0) if $unit =~ /^\s*\[[^\]]+\]:\s/;
    $unit =~ s/$CODE_SPAN//g;
    $unit =~ s/!?\[([^\]]*)\](?:\([^)]*\)|\[[^\]]*\])/link_title($1)/ge;
    $unit =~ s{https?://\S+}{}g;
    my ($hebrew, $words, $lower) = (0, 0, 0);
    for my $token (split ' ', $unit) {
        if ($token =~ /[\x{05D0}-\x{05EA}]/) {
            $hebrew++;
            next;
        }
        $token =~ s/^[^A-Za-z0-9]+//;
        $token =~ s/[^A-Za-z0-9]+\z//;
        next unless $token =~ /^[A-Za-z]{2,}(?:['-][A-Za-z]+)*\z/;
        $words++;
        $lower++ if $token =~ /^[a-z]/;
    }
    return ($hebrew, $words, $lower);
}

# Returns the correction text, or undef when the message is fine.
sub check_message {
    my ($msg) = @_;

    my ($hebrew, $words) = (0, 0);   # totals for the whole message
    my @english_lines;               # units with no Hebrew, 4+ English words, 2+ lowercase
    my @bad;                         # bidi offenders
    my ($fence_char, $fence_len) = ('', 0);

    for my $line (split /\n/, $msg) {
        $line =~ s/\r\z//;

        # Fenced code blocks are skipped. An unclosed fence runs to the end.
        if ($fence_char ne '') {
            if ($line =~ /^$CONTAINER(`{3,}|~{3,})\s*\z/
                && substr($1, 0, 1) eq $fence_char
                && length($1) >= $fence_len)
            {
                $fence_char = '';
            }
            next;
        }
        if ($line =~ /^$CONTAINER(`{3,})[^`]*\z/ || $line =~ /^$CONTAINER(~{3,})/) {
            $fence_char = substr($1, 0, 1);
            $fence_len  = length($1);
            next;
        }

        # Units: the whole line, or each cell of a table row.
        my @units = ($line);
        if ($line =~ /^\s*\|/) {
            @units = split /\|/, mask_pipes_in_code($line);
        }
        for my $unit (@units) {
            my ($h, $w, $lc) = count_tokens($unit);
            $hebrew += $h;
            $words  += $w;
            if ($h == 0 && $w >= 4 && $lc >= 2 && @english_lines < $MAX_QUOTES) {
                push @english_lines, make_quote($unit);
            }
            # The bidi rule keeps inline code: it does set the line direction.
            if (@bad < $MAX_QUOTES && is_bidi_problem($unit)) {
                push @bad, make_quote($unit);
            }
        }
    }

    return $TEXT_ENGLISH if $hebrew == 0 && $words >= 1;
    return join("\n", $TEXT_ENGLISH_LINES_HEAD, (map { "- $_" } @english_lines), $TEXT_ENGLISH_LINES_TAIL)
        if @english_lines;
    return join("\n", $TEXT_BIDI_HEAD, (map { "- $_" } @bad), $TEXT_BIDI_TAIL) if @bad;
    return undef;
}

sub main {
    local $/;
    my $raw = <STDIN>;
    return unless defined $raw && length $raw;
    $raw =~ s/\A\xEF\xBB\xBF//;    # UTF-8 byte order mark

    require JSON::PP;
    my $event = JSON::PP->new->utf8->decode($raw);
    return unless ref $event eq 'HASH';
    return if $event->{stop_hook_active};

    my $msg = $event->{last_assistant_message};
    return unless defined $msg && !ref $msg && length $msg;

    my $text = check_message($msg);
    return unless defined $text;

    my $out = { hookSpecificOutput => { hookEventName => 'Stop', additionalContext => $text } };
    print JSON::PP->new->ascii->canonical->encode($out), "\n";
    # Close here so that a failing flush (closed stdout, broken pipe) happens
    # inside the eval, not later at exit.
    close STDOUT;
}

eval { main(); 1 };
exit 0;
