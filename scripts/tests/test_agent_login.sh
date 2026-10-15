#!/usr/bin/env bash
# lib/config.sh → agent_login: github_login when set (a GitHub App token cannot answer
# `gh api user`), else the token's identity; nothing when neither answers.
. "$(dirname "$0")/lib.sh"
export CONFIG="$WORK_DIR/CONFIG.md"
login() { ( . "$SCRIPTS/lib/config.sh"; agent_login "$@" ); }
printf -- '- target_repo: acme/widgets\n' > "$CONFIG"
assert_eq "unset: the token's identity" "qa-bot" "$(login)"
assert_eq "unset, gh fails: nothing" "" "$(STUB_GH_FAIL=1 login)"
mkdir -p "$SANDBOX/b403"; printf '#!/usr/bin/env bash\necho "{\\"message\\":\\"Resource not accessible by integration\\"}"; exit 1\n' > "$SANDBOX/b403/gh"
chmod +x "$SANDBOX/b403/gh"
assert_eq "unset, a GitHub App token (403 body on stdout): nothing" "" "$(PATH="$SANDBOX/b403:$PATH" login)"
printf -- '- github_login: `widgets-qa[bot]`  # the app\n' >> "$CONFIG"
assert_eq "set: the configured login" "widgets-qa[bot]" "$(login)"
assert_eq "set: no gh call needed" "widgets-qa[bot]" "$(STUB_GH_FAIL=1 login --hostname ghe.example.com)"
exit $FAILED
