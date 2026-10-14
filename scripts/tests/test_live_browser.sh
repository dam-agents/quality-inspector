#!/usr/bin/env bash
# lib/config.sh → live_cdp: the live browser only in a direct session whose transcript is
# found and holds no Slack frame, with no fresh run marker, and only while it answers.
. "$(dirname "$0")/lib.sh"
export HOME="$SANDBOX/home" CLAUDE_CONFIG_DIR="$SANDBOX/claude"
mkdir -p "$HOME" "$WORK_DIR/env" "$CLAUDE_CONFIG_DIR/projects/p" "$SANDBOX/cbin"
printf '#!/usr/bin/env bash\nexit "${STUB_CURL_RC:-0}"\n' > "$SANDBOX/cbin/curl"; chmod +x "$SANDBOX/cbin/curl"
export PATH="$SANDBOX/cbin:$PATH" CONFIG="$WORK_DIR/CONFIG.md"
printf -- '- live_browser: http://127.0.0.1:9222/\n- lock_ttl_min: 180\n' > "$CONFIG"
T="$CLAUDE_CONFIG_DIR/projects/p/sess-1.jsonl"
printf '{"type":"user","message":{"content":"explore #7"}}\n' > "$T"
cdp() { ( . "$SCRIPTS/lib/config.sh"; live_cdp 2>/dev/null ); }

assert_eq "direct session: attaches" "http://127.0.0.1:9222" "$(CLAUDE_CODE_SESSION_ID=sess-1 cdp)"
assert_eq "no session id: headless" "" "$(CLAUDE_CODE_SESSION_ID= cdp)"
assert_eq "no transcript for the session: headless" "" "$(CLAUDE_CODE_SESSION_ID=sess-2 cdp)"
assert_eq "the browser does not answer: headless" "" "$(STUB_CURL_RC=7 CLAUDE_CODE_SESSION_ID=sess-1 cdp)"
printf 'scheduled %s -\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WORK_DIR/env/RUN_MODE"
assert_eq "fresh run marker: headless" "" "$(CLAUDE_CODE_SESSION_ID=sess-1 cdp)"
rm -f "$WORK_DIR/env/RUN_MODE"
printf '{"type":"user","message":{"content":"<how-to-respond>\\nreply …\\n</how-to-respond>"}}\n' >> "$T"
assert_eq "channel turn: headless" "" "$(CLAUDE_CODE_SESSION_ID=sess-1 cdp)"
printf -- '- live_browser: http://example.com:9222\n' > "$CONFIG"
assert_eq "an endpoint off this VM: headless" "" "$(CLAUDE_CODE_SESSION_ID=sess-1 cdp)"
exit $FAILED
