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

        s{<pre><code>}{<pre><code class="code-block">}g;
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

    mv "$tmp" "$html"
}

for html in "$@"; do
    [[ -f "$html" ]] || continue
    postprocess_one "$html"
done
