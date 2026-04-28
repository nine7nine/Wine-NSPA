#!/usr/bin/env bash

set -euo pipefail

postprocess_one() {
    local html="$1"
    local tmp

    tmp=$(mktemp)
    perl -0pe '
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
