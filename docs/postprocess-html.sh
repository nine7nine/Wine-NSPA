#!/usr/bin/env bash

set -euo pipefail

postprocess_one() {
    local html="$1"
    local tmp

    tmp=$(mktemp)
        perl -0pe '
        our %seen_ids;

        sub normalize_svg_block {
            my ($svg) = @_;

            sub tighten_long_svg_text {
                my ($attrs, $content) = @_;
                my $plain = $content;
                $plain =~ s/\s+/ /g;
                $plain =~ s/^\s+//;
                $plain =~ s/\s+$//;

                my $len = length($plain);
                my $size = $len >= 116 ? "7px" : $len >= 100 ? "7.5px" : "8px";

                if ($attrs =~ /\bstyle="([^"]*)"/i) {
                    my $style = $1;
                    if ($style =~ /\bfont-size\s*:/i) {
                        $style =~ s/\bfont-size\s*:\s*[^;"]+/font-size:$size/i;
                    } else {
                        $style .= ";" if $style ne q{} && $style !~ /;\s*$/;
                        $style .= "font-size:$size; letter-spacing:-0.15px";
                    }
                    $attrs =~ s/\bstyle="[^"]*"/style="$style"/i;
                } else {
                    $attrs .= qq{ style="font-size:$size; letter-spacing:-0.15px"};
                }

                if ($len >= 90 && $plain =~ /\s/ &&
                    $plain !~ /&[A-Za-z#0-9]+;/ &&
                    $attrs =~ /\bx="([^"]+)"/i &&
                    $attrs =~ /\by="([^"]+)"/i)
                {
                    my ($x, $y) = ($1, $2);

                    if ($x =~ /^-?\d+(?:\.\d+)?$/ && $y =~ /^-?\d+(?:\.\d+)?$/) {
                        my $mid = int($len / 2);
                        my @spaces;
                        while ($plain =~ / /g) { push @spaces, pos($plain) - 1; }

                        my @window = grep { $_ >= int($len * 0.34) && $_ <= int($len * 0.68) } @spaces;
                        my @candidates = @window ? @window : @spaces;
                        my $best;

                        for my $pos (@candidates) {
                            my $score = abs($pos - $mid);
                            if (!defined $best || $score < $best->[1]) {
                                $best = [$pos, $score];
                            }
                        }

                        if ($best) {
                            my $split = $best->[0];
                            my $line1 = substr($plain, 0, $split);
                            my $line2 = substr($plain, $split + 1);

                            $line1 =~ s/\s+$//;
                            $line2 =~ s/^\s+//;

                            if ($line1 ne q{} && $line2 ne q{}) {
                                my $attrs1 = $attrs;
                                my $attrs2 = $attrs;
                                my $y1 = $y - 7;
                                my $y2 = $y + 9;

                                $attrs1 =~ s/\by="[^"]*"/y="$y1"/i;
                                $attrs2 =~ s/\by="[^"]*"/y="$y2"/i;

                                return qq{<text$attrs1>$line1</text><text$attrs2>$line2</text>};
                            }
                        }
                    }
                }

                return qq{<text$attrs>$content</text>};
            }

            $svg =~ s{
                (\.[A-Za-z0-9_-]*?(?:small|muted|dim|footnote|caption|lbl-mut|label-mut|subtle)[A-Za-z0-9_-]*\s*\{.*?\bfill:\s*)
                \#(?:8c92b3|565f89|545c7e|3b4261)
            }{$1 . "#a9b1d6"}egxsi;

            $svg =~ s~
                (\.[A-Za-z0-9_-]*?(?:lane|divider|axis|dash|rail|guide|boundary|region|timeline)[A-Za-z0-9_-]*\s*\{(?=[^}]*\bstroke-dasharray\b)[^}]*?\bstroke:\s*)
                \#(?:3b4261|565f89|545c7e|8c92b3)
            ~$1 . "#6b7398"~egxsi;

            $svg =~ s/(\.[A-Za-z0-9_-]*?(?:line|conn|arrow)[A-Za-z0-9_-]*\s*\{[^}]*?\bstroke-width:\s*)(?:2(?:\.0+)?|1\.[4-9][0-9]*)/$1 . "1.15"/egxsi;

            $svg =~ s/(\.[A-Za-z0-9_-]*?(?:lane|divider|axis|dash|rail)[A-Za-z0-9_-]*\s*\{[^}]*?\bstroke-width:\s*)(?:2(?:\.0+)?|1(?:\.[0-9]+)?)/$1 . "0.9"/egxsi;

            $svg =~ s{
                (<(?:text|tspan)\b[^>]*\bfill=")
                \#(?:8c92b3|565f89|545c7e|3b4261)
                (")
            }{$1 . "#a9b1d6" . $2}egxsi;

            $svg =~ s{
                (<(?:line|path|polyline|polygon|rect)\b(?=[^>]*\bstroke-dasharray=)[^>]*\bstroke=")
                \#(?:3b4261|565f89|545c7e|8c92b3)
                (")
            }{$1 . "#6b7398" . $2}egxsi;

            $svg =~ s{
                <rect\b
                (?![^>]*\brx=)
                (?![^>]*\bry=)
                ([^>]*?)
                (/?)>
            }{qq{<rect$1 rx="6"$2>}}egxsi;

            $svg =~ s{
                <(line|path|polyline|polygon)\b
                (?![^>]*\bstroke-linecap=)
                ([^>]*?)
                (/?)>
            }{qq{<$1 stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke"$2$3>}}egxsi;

            $svg =~ s{
                <(line|path|polyline|polygon)\b
                (?![^>]*\bvector-effect=)
                ([^>]*?)
                (/?)>
            }{qq{<$1 vector-effect="non-scaling-stroke"$2$3>}}egxsi;

            $svg =~ s/\smarker-(?:start|mid|end)="[^"]*"//gsi;

            # Last-resort overflow guard: shrink very long single-line
            # SVG text a little so diagrams degrade toward "fits" rather
            # than spilling out of the box entirely.
            $svg =~ s{
                <text\b([^>]*)>([^<\n]{88,})</text>
            }{tighten_long_svg_text($1, $2)}egxs;

            return $svg;
        }

        s{(<svg\b.*?</svg>)}{ normalize_svg_block($1) }egxs;

        s{
            <h([1-6])>
            (.*?)
            </h\1>
        }{
            my ($level, $inner) = ($1, $2);
            my $plain = $inner;

            $plain =~ s/<[^>]+>//g;
            $plain =~ s/&[^;]+;//g;
            $plain = lc $plain;
            $plain =~ s/[^a-z0-9 _-]//g;
            $plain =~ s/ /-/g;
            $plain =~ s/^-+//;
            $plain =~ s/-+$//;
            $plain = "section" if $plain eq q{};

            my $count = ++$seen_ids{$plain};
            my $id = $count > 1 ? "$plain-$count" : $plain;

            qq{<h$level id="$id">$inner</h$level>};
        }egxs;

        s{
            (<pre><code\b)
            ([^>]*)
            (>)
        }{
            my ($head, $attrs, $tail) = ($1, $2, $3);

            if ($attrs =~ /\bclass="([^"]*)"/) {
                my $classes = $1;
                unless ($classes =~ /\bcode-block\b/) {
                    $attrs =~ s/\bclass="([^"]*)"/class="$1 code-block"/;
                }
            } else {
                $attrs .= q{ class="code-block"};
            }

            $head . $attrs . $tail;
        }egxs;

        s{
            (<div\s+class="diagram-container">\s*<svg\b)
            ([^>]*)
            (>)
        }{
            my ($head, $attrs, $tail) = ($1, $2, $3);

            if ($attrs =~ /\bclass="([^"]*)"/) {
                my $classes = $1;
                unless ($classes =~ /\bdiagram-svg\b/) {
                    $attrs =~ s/\bclass="([^"]*)"/class="$1 diagram-svg"/;
                }
            } else {
                $attrs .= q{ class="diagram-svg"};
            }

            unless ($attrs =~ /\bpreserveAspectRatio=/) {
                $attrs .= q{ preserveAspectRatio="xMidYMid meet"};
            }

            $head . $attrs . $tail;
        }egxs;
    ' "$html" > "$tmp"

    if perl -0ne 'exit((/<p><code>[^<]*\n/s || /<p>`{3}/s || /`{3}<\/p>/s) ? 0 : 1)' "$tmp"; then
        echo "postprocess-html: suspicious broken code block markup in $html" >&2
        rm -f "$tmp"
        return 1
    fi

    if perl -0ne 'exit((/<svg\b[\s\S]*?(?:\.[A-Za-z0-9_-]*?(?:small|muted|dim|footnote|caption|lbl-mut|label-mut|subtle)[A-Za-z0-9_-]*\s*\{.*?\bfill:\s*#(?:8c92b3|565f89|545c7e|3b4261)|<(?:text|tspan)\b[^>]*\bfill="#(?:8c92b3|565f89|545c7e|3b4261)")/si) ? 0 : 1)' "$tmp"; then
        echo "postprocess-html: unreadable muted SVG text survived normalization in $html" >&2
        rm -f "$tmp"
        return 1
    fi

    perl -0ne '
        while (/<svg\b.*?<\/svg>/sg) {
            my $svg = $&;

            while ($svg =~ /<text\b[^>]*>([^<\n]{90,})<\/text>/g) {
                my $snippet = $1;
                $snippet =~ s/\s+/ /g;
                $snippet =~ s/^(.{0,110}).*$/$1.../ if length($snippet) > 110;
                print STDERR "postprocess-html: long single-line SVG text in $ARGV: $snippet\n";
            }

            while ($svg =~ /<line\b[^>]*\bx1="([0-9.]+)"[^>]*\by1="([0-9.]+)"[^>]*\bx2="([0-9.]+)"[^>]*\by2="([0-9.]+)"/g) {
                my ($x1, $y1, $x2, $y2) = ($1, $2, $3, $4);
                my $dx = abs($x2 - $x1);
                my $dy = abs($y2 - $y1);
                next unless $dx >= 200 && $dy >= 70;
                print STDERR "postprocess-html: long diagonal SVG connector in $ARGV: line($x1,$y1)->($x2,$y2)\n";
            }
        }
    ' "$tmp"

    mv "$tmp" "$html"
}

for html in "$@"; do
    [[ -f "$html" ]] || continue
    postprocess_one "$html"
done
