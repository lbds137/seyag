#!/bin/bash
# Fixture check for plugins/seyag/bin/pin-actions: a stub gh answers the commit and tag lookups, so the probe
# pins the rewrite (moving major -> SHA + most specific tag, full version kept, subpath actions
# resolved by their repo, already pinned / local / docker / commented lines untouched), --check
# listing and its exit code, and an unresolvable ref left as it was with exit 1.
# Usage: tests/pin-actions.probe.sh   (writes only in a temp dir)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PA="$REPO/plugins/seyag/bin/pin-actions"
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
A=$(printf 'a%.0s' {1..40}); B=$(printf 'b%.0s' {1..40}); C=$(printf 'c%.0s' {1..40})
cat >"$tmp/gh" <<EOF
#!/bin/bash
echo "\$*" >>"$tmp/calls"
case "\$2" in
  repos/actions/checkout/commits/v7) echo '{"sha":"$A"}' ;;
  repos/actions/checkout/tags*) echo '[[{"name":"v7.0.0","commit":{"sha":"$C"}},{"name":"v7","commit":{"sha":"$A"}}],[{"name":"v7.0.1","commit":{"sha":"$A"}},{"name":"v8.0.0","commit":{"sha":"$C"}}]]' ;;
  repos/github/codeql-action/commits/v4) echo '{"sha":"$B"}' ;;
  repos/github/codeql-action/tags*) echo '[[{"name":"v4.31.9","commit":{"sha":"$B"}},{"name":"v4.31.10","commit":{"sha":"$B"}},{"name":"v4.40.0","commit":{"sha":"$C"}}]]' ;;
  repos/pnpm/action-setup/commits/v6.1.0) echo '{"sha":"$C"}' ;;
  *) echo "Not Found" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/gh"
export SYG_PIN_ACTIONS_GH=$tmp/gh

wf=$tmp/ci.yml
cat >"$wf" <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@v7
      - name: init
        uses: github/codeql-action/init@v4
      - uses: github/codeql-action/analyze@v4
      - uses: pnpm/action-setup@v6.1.0
      - uses: actions/setup-node@$A # v7.1.0
      - uses: ./.github/actions/local
      - uses: docker://alpine:3
      - uses: actions/cache@v4 # keep
      # uses: read is prose, not a key
      - uses: 'actions/checkout@v7'
EOF

out=$("$PA" --check "$wf"); rc=$?
[ $rc = 1 ] && ok "--check exits 1 on unpinned uses" || bad "--check rc=$rc"
n=$(grep -c . <<<"$out")
[ "$n" = 6 ] && ok "--check lists the 6 unpinned uses (a quoted one too)" || bad "--check listed $n: $out"
grep -q "ci.yml:4 actions/checkout@v7" <<<"$out" && ok "--check names file:line ref" || bad "--check format: $out"
[ ! -e "$tmp/calls" ] && ok "--check makes no API call" || bad "--check called gh"

before=$(cat "$wf")
err=$("$PA" "$wf" 2>&1 >/dev/null); rc=$?
[ $rc = 1 ] && ok "a line it could not pin exits 1" || bad "rewrite rc=$rc"
grep -q "      - uses: actions/checkout@$A # v7.0.1$" "$wf" && ok "moving major pinned with the highest tag on its own commit, across tag pages" || bad "checkout: $(grep checkout "$wf")"
grep -q "      - uses: 'actions/checkout@$A' # v7.0.1$" "$wf" && ok "quoted value pinned inside its quotes" || bad "quoted: $(grep "'" "$wf")"
grep -q -- '--paginate' "$tmp/calls" && ok "tag lookup paginates" || bad "tags not paginated: $(cat "$tmp/calls")"
grep -q "        uses: github/codeql-action/init@$B # v4.31.10$" "$wf" && ok "subpath action resolved by its repo, highest version tag" || bad "init: $(grep init@ "$wf")"
grep -q "      - uses: github/codeql-action/analyze@$B # v4.31.10$" "$wf" && ok "second subpath of the same ref pinned" || bad "analyze: $(grep analyze "$wf")"
[ "$(grep -c 'repos/github/codeql-action/commits/v4' "$tmp/calls")" = 1 ] && ok "a repeated ref is looked up once" || bad "codeql lookups: $(cat "$tmp/calls")"
grep -q "      - uses: pnpm/action-setup@$C # v6.1.0$" "$wf" && ok "full version kept as the comment" || bad "pnpm: $(grep pnpm "$wf")"
! grep -q 'repos/pnpm/action-setup/tags' "$tmp/calls" && ok "full version skips the tag lookup" || bad "pnpm tags looked up"
for keep in "actions/setup-node@$A # v7.1.0" "./.github/actions/local" "docker://alpine:3" "actions/cache@v4 # keep" "# uses: read is prose"; do
  grep -qF "$keep" "$wf" && ok "untouched: $keep" || bad "changed: $keep"
done
grep -q "actions/cache@v4 has a comment; pin it by hand" <<<"$err" && ok "commented line reported" || bad "stderr: $err"
[ "$(wc -l <"$wf")" = "$(wc -l <<<"$before")" ] && ok "line count kept" || bad "line count changed"
[ "$(tail -c1 "$wf" | od -An -c | tr -d ' ')" = '\n' ] && ok "trailing newline kept" || bad "trailing newline lost"

crlf=$tmp/crlf.yml
printf 'steps:\r\n      - uses: pnpm/action-setup@v6.1.0\r\n      - run: echo\r\n' >"$crlf"
"$PA" "$crlf" >/dev/null 2>&1
[ "$(od -An -c "$crlf" | grep -o '\\r' | wc -l)" = 3 ] && grep -q "action-setup@$C # v6.1.0"$'\r'"$" "$crlf" \
  && ok "CRLF file stays CRLF, pinned line included" || bad "crlf: $(od -c "$crlf" | head -5)"

bad_wf=$tmp/bad.yml
printf '      - uses: nobody/missing@v1\n' >"$bad_wf"
err=$("$PA" "$bad_wf" 2>&1); rc=$?
[ $rc = 1 ] && grep -q 'did not resolve' <<<"$err" && ok "unresolvable ref: exit 1 with a message" || bad "unresolvable: rc=$rc $err"
grep -qx '      - uses: nobody/missing@v1' "$bad_wf" && ok "unresolvable line left as it was" || bad "bad.yml changed"

"$PA" --check "$tmp/none.yml" >/dev/null 2>&1; rc=$?
[ $rc != 0 ] && ok "missing file is an error" || bad "missing file rc=0"
"$PA" >/dev/null 2>&1; [ $? = 2 ] && ok "no files: usage error 2" || bad "no-arg rc"

exit $fail
