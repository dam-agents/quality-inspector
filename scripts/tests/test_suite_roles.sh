#!/usr/bin/env bash
# suite.sh roles: lists the e2e identities with a non-empty username, never a value.
. "$(dirname "$0")/lib.sh"
seed_work
mkdir -p "$WORK_DIR/env"
cat > "$WORK_DIR/env/credentials.env" <<'E'
E2E_USER_OWNER_USERNAME=admin@example.com
E2E_USER_OWNER_PASSWORD=s3cret-owner
export E2E_USER_MEMBER_USERNAME="member@example.com"
E2E_USER_MEMBER_PASSWORD='s3cret-member'
E2E_USER_VIEWER_USERNAME=
E2E_USER_OUTSIDER_USERNAME=""
E
out="$(bash "$SCRIPTS/suite.sh" roles)"
assert "owner and member provided, empty roles left out" '. == ["member","owner"]' "$out"
case "$out" in *s3cret*|*example.com*) echo "  roles printed a credential value"; FAILED=1;; esac
rm "$WORK_DIR/env/credentials.env"
bash "$SCRIPTS/suite.sh" roles >/dev/null 2>&1 && { echo "  a missing credentials.env must fail"; FAILED=1; }
exit $FAILED
