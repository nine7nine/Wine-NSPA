#!/usr/bin/env bash

set -euo pipefail

postprocess_one() {
    local html="$1"
    local tmp

    tmp=$(mktemp)
    perl -0pe '
        our %seen_ids;

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

    mv "$tmp" "$html"
}

for html in "$@"; do
    [[ -f "$html" ]] || continue
    postprocess_one "$html"
done
