#!/usr/bin/env bash
# md2html.sh — Convert .md specs to styled HTML with Tokyo Night theme
#
# Usage:
#   ./md2html.sh file.md              # outputs file.html
#   ./md2html.sh *.md                 # batch convert
#   ./md2html.sh                      # convert all .md in current dir
#
# Requires: discount markdown (markdown(1)) — `pacman -S discount`

set -euo pipefail

CSS='<style>
  :root {
    --bg: #1a1b26; --fg: #c0caf5; --accent: #7aa2f7;
    --green: #9ece6a; --red: #f7768e; --yellow: #e0af68;
    --surface: #24283b; --border: #3b4261; --muted: #8c92b3;
    --purple: #bb9af7; --orange: #ff9e64; --cyan: #7dcfff;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: "JetBrains Mono", "Fira Code", "Cascadia Code", monospace;
    background: var(--bg); color: var(--fg);
    max-width: 1100px; margin: 0 auto; padding: 2rem 1.5rem;
    line-height: 1.7;
  }
  h1 { color: var(--accent); font-size: 1.5rem; margin: 1.5rem 0 0.5rem; }
  h2 { color: var(--accent); font-size: 1.2rem; margin: 2rem 0 0.75rem;
       border-bottom: 1px solid var(--border); padding-bottom: 0.3rem; }
  h3 { color: var(--yellow); font-size: 1rem; margin: 1.25rem 0 0.5rem; }
  h4 { color: var(--cyan); font-size: 0.95rem; margin: 1rem 0 0.4rem; }
  p, li { font-size: 0.85rem; margin-bottom: 0.5rem; }
  ul, ol { padding-left: 1.5rem; margin-bottom: 0.75rem; }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }
  table {
    width: 100%; border-collapse: collapse;
    margin: 0.75rem 0 1rem; font-size: 0.8rem;
  }
  th, td {
    padding: 0.4rem 0.75rem; text-align: left;
    border: 1px solid var(--border);
  }
  th { background: var(--surface); color: var(--accent); font-weight: 600; }
  td { background: var(--bg); }
  code {
    background: var(--surface); padding: 0.15rem 0.4rem;
    border-radius: 3px; font-size: 0.82rem; color: var(--cyan);
  }
  pre {
    background: var(--surface); padding: 1rem 1.1rem; border-radius: 8px;
    overflow-x: auto; margin: 0.75rem 0 1rem;
    border: 1px solid var(--border);
  }
  pre code {
    display: block; background: transparent; padding: 0;
    font-size: 0.8rem; color: inherit;
  }
  pre code.hljs,
  code.hljs {
    background: transparent;
    padding: 0;
  }
  blockquote {
    background: var(--surface); border-left: 3px solid var(--accent);
    padding: 0.75rem 1rem; margin: 1rem 0; border-radius: 0 4px 4px 0;
    font-size: 0.82rem;
  }
  blockquote strong { color: var(--yellow); }
  hr { border: none; border-top: 1px solid var(--border); margin: 2rem 0; }
  strong { color: var(--fg); }
  em { color: var(--muted); font-style: italic; }
  .diagram-container {
    display: flex; justify-content: center;
    margin: 1.25rem auto 1.5rem; padding: 0.75rem;
    background: rgba(36, 40, 59, 0.55);
    border: 1px solid var(--border); border-radius: 10px;
    overflow-x: auto;
  }
  .diagram-container svg {
    display: block;
    width: 100% !important;
    max-width: 100%;
    height: auto !important;
    margin: 0 auto;
    flex: 0 0 auto;
  }
</style>'

HIGHLIGHT_HEAD='
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.11.1/styles/tokyo-night-dark.min.css">
<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.11.1/highlight.min.js"></script>'

HIGHLIGHT_TAIL='
<script>
document.addEventListener("DOMContentLoaded", function () {
  document.querySelectorAll("pre code").forEach(function (block) {
    hljs.highlightElement(block);
  });
});
</script>'

convert_one() {
    local md="$1"
    local html="${md%.md}.gen.html"  # .gen.html to avoid clobbering hand-crafted HTML
    local script_dir
    local title

    script_dir=$(cd "$(dirname "$0")" && pwd)
    title=$(head -5 "$md" | grep -m1 '^#' | sed 's/^#\+ *//' || basename "$md" .md)

    {
        echo "<!DOCTYPE html>"
        echo "<html lang=\"en\"><head>"
        echo "<meta charset=\"UTF-8\">"
        echo "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">"
        echo "<title>$title</title>"
        echo "$CSS"
        echo "$HIGHLIGHT_HEAD"
        echo "</head><body>"
        markdown "$md"
        echo "$HIGHLIGHT_TAIL"
        echo "</body></html>"
    } > "$html"

    bash "$script_dir/postprocess-html.sh" "$html"

    echo "  $md -> $html"
}

files=("$@")
if [[ ${#files[@]} -eq 0 ]]; then
    files=(*.md)
fi

echo "md2html: converting ${#files[@]} file(s)"
for f in "${files[@]}"; do
    [[ -f "$f" ]] || { echo "  skip: $f (not found)"; continue; }
    convert_one "$f"
done
echo "done"
