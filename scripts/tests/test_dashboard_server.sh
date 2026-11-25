#!/usr/bin/env bash
# scripts/dashboard/server.mjs (docs/catalog.md → The server): only the platform's relay and only
# loopback names; the catalog data and its "have" hash; a picture only from under work/catalog/thumbs
# or work/design; a report's video only from under work/suite/.e2e/runs, in parts; the operator's own
# settings written at once, a viewer's refused; the chat's questions and answers; the live status; a command only of the page's own patterns, recorded with its
# caller, rate-limited, and handed back as the ping; the caller's own commands only.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
W="$WORK_DIR"
mkdir -p "$W/catalog/thumbs" "$W/design/crops" "$W/env"
printf 'x' > "$W/catalog/thumbs/a.jpg"; printf 'secret' > "$W/env/credentials.env"
ln -s "$W/env/credentials.env" "$W/catalog/thumbs/link.jpg"
mkdir -p "$W/suite/.e2e/runs/r1"; head -c 2000000 /dev/zero > "$W/suite/.e2e/runs/r1/v.webm"; printf 'x' > "$W/env/v.webm"
ln -s "$W/env/v.webm" "$W/suite/.e2e/runs/r1/link.webm"
jq -n '{schema:"qi-catalog/v1", hash:"h1", items:[],
  runs:[{type:"issue", ref:"#42", utc:"2026-11-16T09:00:00Z", analysis:{problems:[{title:"The upload | never ends", where:"/upload"}]}},
        {type:"issue", ref:"#43", utc:"2026-11-15T09:00:00Z", analysis:{problems:[{title:"First seen", where:null}]}}], images:{r0:"catalog/thumbs/a.jpg", r1:"env/credentials.env", r2:"catalog/thumbs/link.jpg", r3:"../etc/passwd.jpg"},
  videos:{v0:"suite/.e2e/runs/r1/v.webm", v1:"env/v.webm", v2:"suite/.e2e/runs/r1/link.webm", v3:"catalog/thumbs/a.jpg"}}' > "$W/catalog/data.json"
printf 'agent 2026-11-16T10:00:00Z sess\n' > "$W/env/LOCK"
printf '| 42 | abc | c1 | b1 | - | in_progress | 2026-11-16T10:00:00Z |\n' >> "$W/QA.md"

PORT="$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
QI_DASHBOARD_PORT="$PORT" node "$SCRIPTS/dashboard/server.mjs" 2>"$W/server.log" &
PID=$!
trap 'kill $PID 2>/dev/null' EXIT
# One request (curl is a stub in these tests): call [-H 'name: value']… [-X METHOD] [-d BODY] URL → the body;
# CODE=1 → the status. A Host header given with -H replaces the loopback one.
call() {
  node --input-type=module -e '
    const a = process.argv.slice(1); const headers = {}; let method = "GET", body, url;
    for (let i = 0; i < a.length; i++) {
      if (a[i] === "-H") { const [k, ...v] = a[++i].split(":"); headers[k.trim().toLowerCase()] = v.join(":").trim(); }
      else if (a[i] === "-X") method = a[++i]; else if (a[i] === "-d") body = a[++i]; else url = a[i];
    }
    const u = new URL(url); const http = await import("node:http");
    const r = await new Promise((ok, no) => { const q = http.request({ host: u.hostname, port: u.port, path: u.pathname + u.search, method, headers: { host: headers.host || u.host, ...headers } }, (res) => {
      let t = ""; res.on("data", (c) => (t += c)); res.on("end", () => ok({ s: res.statusCode, t })); }); q.on("error", no); if (body !== undefined) q.write(body); q.end(); });
    process.stdout.write(process.env.CODE ? String(r.s) : r.t);' -- "$@" 2>/dev/null
}
code() { CODE=1 call "$@"; }
U="http://127.0.0.1:$PORT"
for _ in $(seq 1 50); do [ "$(code "$U/health")" = 200 ] && break; sleep 0.1; done
OP=(-H 'x-platform-caller-role: owner' -H 'x-platform-caller-email: Op@Example.com')
VW=(-H 'x-platform-caller-role: viewer' -H 'x-platform-caller-email: pat@example.com')

assert "health answers" '.ok == true and .data == true' "$(call "$U/health")"
assert_eq "no caller headers: refused" 401 "$(code "$U/api/catalog")"
assert_eq "a forged role: refused" 401 "$(code -H 'x-platform-caller-role: admin' "$U/api/catalog")"
assert_eq "another host name: refused" 421 "$(code -H 'Host: evil.example' "${OP[@]}" "$U/api/catalog")"
assert "me: the owner is an admin" '.role == "admin" and .owner == true and .email == "op@example.com"' "$(call "${OP[@]}" "$U/api/me")"
assert "me: anyone not in the roster is a viewer" '.role == "viewer" and .owner == false' "$(call "${VW[@]}" "$U/api/me")"
# Roles (docs/dashboard-page.md → Roles): an admin keeps the roster; a role comes only from it.
DV=(-H 'x-platform-caller-role: viewer' -H 'x-platform-caller-email: Dev@Example.com')
AD=(-H 'x-platform-caller-role: viewer' -H 'x-platform-caller-email: ada@example.com')
assert_eq "a viewer gives no roles" 403 "$(code "${VW[@]}" -X POST -d '{"email":"pat@example.com","role":"admin"}' "$U/api/people")"
assert "the owner gives a developer's role" '.ok == true and .role == "developer" and .old == null' "$(call "${OP[@]}" -X POST -d '{"email":"dev@example.com","role":"developer"}' "$U/api/people")"
assert "and an admin's" '.role == "admin"' "$(call "${OP[@]}" -X POST -d '{"email":"ada@example.com","role":"admin"}' "$U/api/people")"
assert_eq "a role that is not one: refused" 400 "$(code "${OP[@]}" -X POST -d '{"email":"x@example.com","role":"owner"}' "$U/api/people")"
assert_eq "not an email: refused" 400 "$(code "${OP[@]}" -X POST -d '{"email":"x | admin","role":"admin"}' "$U/api/people")"
assert "me: the roster's role, the email in any case" '.role == "developer" and .owner == false' "$(call "${DV[@]}" "$U/api/me")"
assert "a developer sees the roles, not the emails" '.people == [] and .counts.developer == 1 and .counts.admin == 1' "$(call "${DV[@]}" "$U/api/people")"
assert "an admin sees the roster" '[.people[].email] | sort == ["ada@example.com","dev@example.com"]' "$(call "${AD[@]}" "$U/api/people")"
grep -q '^| dev@example.com | developer | ' "$W/dashboard/PEOPLE.md"; assert_eq "the row is in PEOPLE.md" 0 "$?"
assert_eq "a forged role header still counts as none" 401 "$(code -H 'x-platform-caller-role: developer' -H 'x-platform-caller-email: dev@example.com' "$U/api/me")"
assert "catalog: the data and its hash" '.hash == "h1" and .data.schema == "qi-catalog/v1"' "$(call "${VW[@]}" "$U/api/catalog")"
assert "catalog: unchanged for the same hash" '.unchanged == true and (has("data") | not)' "$(call "${VW[@]}" "$U/api/catalog?have=h1")"
assert "a picture under thumbs" '.uri | startswith("data:image/jpeg;base64,")' "$(call "${VW[@]}" "$U/api/images/r0")"
assert_eq "a picture outside the roots: refused" 404 "$(code "${VW[@]}" "$U/api/images/r1")"
assert_eq "a link out of the roots: refused" 404 "$(code "${VW[@]}" "$U/api/images/r2")"
assert_eq "a path that climbs out: refused" 404 "$(code "${VW[@]}" "$U/api/images/r3")"
assert_eq "an id the data does not name: refused" 404 "$(code "${VW[@]}" "$U/api/images/constructor")"
assert "a video: its first part, its type and size" '.mime == "video/webm" and .size == 2000000 and .parts == 2 and .part == 0 and (.b64 | length) == 2097152' "$(call "${VW[@]}" "$U/api/videos/v0")"
assert "a video: its last part" '.part == 1 and (.b64 | length) > 0 and (.b64 | length) < 2097152' "$(call "${VW[@]}" "$U/api/videos/v0?part=1")"
assert_eq "a video: a part past its end, refused" 400 "$(code "${VW[@]}" "$U/api/videos/v0?part=2")"
assert_eq "a video outside the e2e runs: refused" 404 "$(code "${VW[@]}" "$U/api/videos/v1")"
assert_eq "a video's link out of the runs: refused" 404 "$(code "${VW[@]}" "$U/api/videos/v2")"
assert_eq "a picture as a video: refused" 404 "$(code "${VW[@]}" "$U/api/videos/v3")"
assert_eq "a video id the data does not name: refused" 404 "$(code "${VW[@]}" "$U/api/videos/constructor")"
# The operator's own settings: written at once by modules.sh, as the server's child (docs/modules.md → Control).
S='{"module":"stress","key":"stress_checks","value":"weekly"}'
assert_eq "a viewer's setting: refused" 403 "$(code "${VW[@]}" -X POST -d "$S" "$U/api/settings")"
assert_eq "a developer's setting: refused" 403 "$(code "${DV[@]}" -X POST -d "$S" "$U/api/settings")"
assert "the operator's setting: written by the server, checked by modules.sh valid" '.ok == true and (.done | fromjson | .set[0].new == "weekly")' "$(call "${OP[@]}" -X POST -d "$S" "$U/api/settings")"
grep -q '^- stress_checks: weekly$' "$W/CONFIG.md"; assert_eq "the bullet is in CONFIG.md" 0 "$?"
assert "the data shows it at once: a new hash" '.hash != "h1"' "$(call "${VW[@]}" "$U/api/catalog")"
assert_eq "a value outside the setting: refused" 400 "$(code "${OP[@]}" -X POST -d '{"module":"stress","key":"stress_checks","value":"hourly"}' "$U/api/settings")"
assert_eq "a key of another module: refused" 400 "$(code "${OP[@]}" -X POST -d '{"module":"stress","key":"ui_sweep","value":"weekly"}' "$U/api/settings")"
assert_eq "not a setting: refused" 400 "$(code "${OP[@]}" -X POST -d '{"module":"stress"}' "$U/api/settings")"
assert "the operator's focus: queued" '.ok == true' "$(call "${OP[@]}" -X POST -d '{"focus":"Upload"}' "$U/api/settings")"
grep -q '| Upload |' "$W/FOCUS.md"; assert_eq "the area is in FOCUS.md" 0 "$?"
# The page's chat: a question recorded with who asked, its ping; the asker's own questions only; the
# agent's answer through asks.mjs, once.
assert "a question: recorded, its ping" '.id == "A-1" and .ping == "answer dashboard question A-1"' "$(call "${VW[@]}" -X POST -d '{"text":"Why does it fail?","context":{"tab":"tests","item":"issue-42/AC-1","label":"#42 AC-1"}}' "$U/api/asks")"
assert_eq "an empty question: refused" 400 "$(code "${VW[@]}" -X POST -d '{"text":"  "}' "$U/api/asks")"
assert "the asker's own, still without an answer" '(.asks | length) == 1 and .asks[0].answer == null and .asks[0].context.item == "issue-42/AC-1"' "$(call "${VW[@]}" "$U/api/asks")"
assert "another person sees none of it" '.asks == []' "$(call "${OP[@]}" "$U/api/asks")"
assert "the agent sees the question, the role and never the email" '.text == "Why does it fail?" and .role == "viewer" and (has("email") | not)' "$(WORK_DIR="$W" node "$SCRIPTS/dashboard/asks.mjs" show A-1)"
printf 'It fails because the product does not check the size.\n' > "$W/answer.txt"
WORK_DIR="$W" node "$SCRIPTS/dashboard/asks.mjs" answer A-1 "$W/answer.txt" >/dev/null; assert_eq "the answer is recorded" 0 "$?"
WORK_DIR="$W" node "$SCRIPTS/dashboard/asks.mjs" answer A-1 "$W/answer.txt" >/dev/null 2>&1; assert_eq "a second answer: refused" 2 "$?"
assert "the asker sees the answer" '.asks[0].answer.text == "It fails because the product does not check the size."' "$(call "${VW[@]}" "$U/api/asks")"
# A page command through the chat: its ping is the command itself; the agent finds its row to answer.
assert "a command in the chat: its ping is the command" '.id == "A-2" and .ping == "run #42 AC-1"' "$(call "${OP[@]}" -X POST -d '{"text":"Run it again.","command":"run #42 AC-1"}' "$U/api/asks")"
assert_eq "a viewer's command in the chat: refused" 403 "$(code "${VW[@]}" -X POST -d '{"text":"Run it again.","command":"run #42 AC-1"}' "$U/api/asks")"
assert_eq "a job's ping as a chat command: refused" 400 "$(code "${OP[@]}" -X POST -d '{"text":"x","command":"do dashboard job J-1"}' "$U/api/asks")"
assert_eq "a command the page does not have: refused" 400 "$(code "${OP[@]}" -X POST -d '{"text":"x","command":"rm -rf /"}' "$U/api/asks")"
# The command comes in a file, never on the command line: a scenario's words are a person's free text.
printf 'run #42 AC-1\n' > "$W/find.txt"
assert "the agent finds the command's row" '.id == "A-2"' "$(WORK_DIR="$W" node "$SCRIPTS/dashboard/asks.mjs" find --command-file "$W/find.txt")"
printf 'run #43' > "$W/find.txt"
assert "a command with no row: none" '.id == null' "$(WORK_DIR="$W" node "$SCRIPTS/dashboard/asks.mjs" find --command-file "$W/find.txt")"
WORK_DIR="$W" node "$SCRIPTS/dashboard/asks.mjs" find --command "run #42 AC-1" >/dev/null 2>&1; assert_eq "a command on the command line: refused" 2 "$?"
# Each page its own session (docs/dashboard-page.md → The chat): the ping's conversation is the item,
# else the tab's page, in the platform's key shape; a scenario request is its own page and session.
assert "a question's session: its item" '.ping_conversation | test("^item\\.issue-42-AC-1\\.[0-9a-f]{8}$")' "$(call "${VW[@]}" -X POST -d '{"text":"And now?","context":{"tab":"tests","item":"issue-42/AC-1"}}' "$U/api/asks")"
assert "a page's session: the tab and its page" '.ping_conversation | test("^page\\.tests-nightly\\.[0-9a-f]{8}$")' "$(call "${VW[@]}" -X POST -d '{"text":"What is this?","context":{"tab":"tests","page":"tests/nightly"}}' "$U/api/asks")"
assert "a plain tab: its name" '.ping_conversation == "page.settings"' "$(call "${VW[@]}" -X POST -d '{"text":"What is this?","context":{"tab":"settings","page":"settings"}}' "$U/api/asks")"
SC='test this scenario: On the page /projects: Rename a project and see the new name in the list.'
assert_eq "a viewer's scenario request: refused" 403 "$(code "${VW[@]}" -X POST -d "$(jq -nc --arg c "$SC" '{text:"Test this scenario, please.", command:$c, request:true}')" "$U/api/asks")"
R="$(call "${DV[@]}" -X POST -d "$(jq -nc --arg c "$SC" '{text:"Test this scenario, please.", command:$c, request:true, context:{tab:"problems"}}')" "$U/api/asks")"
RID="$(jq -r .id <<<"$R")"
assert "a scenario request: its own page and session, the command as the ping" ".ping == \"$SC\" and .ping_conversation == \"$RID\"" "$R"
assert "its page: the request, not what was open" ".asks | map(select(.id == \"$RID\")) | .[0] | .context.item == \"$RID\" and .request == {scenario: null}" "$(call "${DV[@]}" "$U/api/asks")"
assert "request with another command: a plain chat row" '.ping_conversation != .id' "$(call "${OP[@]}" -X POST -d '{"text":"x","command":"run #42 AC-1","request":true,"context":{"tab":"runs"}}' "$U/api/asks")"
WORK_DIR="$W" node "$SCRIPTS/dashboard/asks.mjs" link A-2 S-9 >/dev/null 2>&1; assert_eq "a link from a row that is no scenario request: refused" 2 "$?"
printf '%s\n' "$SC" > "$W/find.txt"
assert "the agent finds the request's row from the file" ".id == \"$RID\"" "$(WORK_DIR="$W" node "$SCRIPTS/dashboard/asks.mjs" find --command-file "$W/find.txt")"
WORK_DIR="$W" node "$SCRIPTS/dashboard/asks.mjs" link "$RID" S-9 >/dev/null; assert_eq "the agent links the request to its scenario" 0 "$?"
WORK_DIR="$W" node "$SCRIPTS/dashboard/asks.mjs" link "$RID" S-9 >/dev/null; assert_eq "the same link again: fine" 0 "$?"
WORK_DIR="$W" node "$SCRIPTS/dashboard/asks.mjs" link "$RID" S-8 >/dev/null 2>&1; assert_eq "another scenario: refused" 2 "$?"
assert "linked, nothing written yet" ".asks | map(select(.id == \"$RID\")) | .[0].request.scenario | .id == \"S-9\" and .status == null and .criteria == []" "$(call "${DV[@]}" "$U/api/asks")"
mkdir -p "$W/scenarios/S-9"; printf '# S-9 — Rename\n\n## AC-1 — The new name shows\nquote: x\n\n## AC-2 — The old name is gone\n' > "$W/scenarios/S-9/criteria-abc123.md"
printf '| id | source | requester | thread | spec_hash | build | verdict | status | updated_utc |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n| S-9 | dashboard | - | - | abc123 | - | - | queued | 2026-11-25T10:00:00Z |\n' > "$W/SCENARIOS.md"
assert "its progress: the row and the frozen criteria" ".asks | map(select(.id == \"$RID\")) | .[0].request.scenario | .status == \"queued\" and .build == null and (.criteria | map(.id)) == [\"AC-1\",\"AC-2\"] and .test == false and .ran == false" "$(call "${DV[@]}" "$U/api/asks")"
assert "another person sees none of the request" ".asks | map(select(.id == \"$RID\")) == []" "$(call "${OP[@]}" "$U/api/asks")"
# The operator's direct actions (POST /api/act): done by a script, as the server's child; never for a viewer.
A='{"command":"add #42 AC-1 to the collection Smoke"}'
assert_eq "a viewer's action: refused" 403 "$(code "${VW[@]}" -X POST -d "$A" "$U/api/act")"
assert "a test into a collection" '.ok == true and (.data.collections | map(select(.name == "Smoke")) | .[0].members) == ["#42 AC-1"]' "$(call "${OP[@]}" -X POST -d "$A" "$U/api/act")"
grep -q '^| Smoke | #42 AC-1 |$' "$W/CATALOG.md"; assert_eq "the row is in CATALOG.md" 0 "$?"
assert "out of it again: the emptied collection goes" '.ok == true and ((.data.collections // []) | map(select(.name == "Smoke")) | length) == 0' "$(call "${OP[@]}" -X POST -d '{"command":"remove #42 AC-1 from the collection Smoke"}' "$U/api/act")"
assert_eq "work for the agent is no direct action" 400 "$(code "${OP[@]}" -X POST -d '{"command":"run #42 AC-1"}' "$U/api/act")"
WORK_DIR="$W" QI_DASHBOARD_WRITE=operator node "$SCRIPTS/collections.mjs" add Smoke '#42' >/dev/null 2>&1
assert_eq "outside the direct session collections.mjs writes nothing, whatever the variables" 2 "$?"
assert_eq "a blocker's retry is work for the agent, no direct action" 400 "$(code "${OP[@]}" -X POST -d '{"command":"retry B-1"}' "$U/api/act")"
mkdir -p "$W/design"
assert "the operator's dismissal: written by the server" '.ok == true' "$(call "${OP[@]}" -X POST -d '{"command":"dismiss D-7 as by-design"}' "$U/api/act")"
grep -q '^| D-7 | .* | by-design |$' "$W/design/DISMISSED.md"; assert_eq "the row is in DISMISSED.md, as modules.sh writes it" 0 "$?"
assert "reopened again" '.ok == true and (.done | fromjson | .reopened) == true' "$(call "${OP[@]}" -X POST -d '{"command":"reopen D-7"}' "$U/api/act")"
grep -q '^| D-7 ' "$W/design/DISMISSED.md"; assert_eq "its row is gone" 1 "$?"
assert "a category, then none" '(.done | fromjson | .category) == "layout"' "$(call "${OP[@]}" -X POST -d '{"command":"categorize D-7 layout"}' "$U/api/act")"
# A problem's dismissal (docs/dashboard-page.md → Problems): F-<k> numbered as the page numbers it, kept by its words.
assert "a developer's dismissal of a design finding: written" '.ok == true' "$(call "${DV[@]}" -X POST -d '{"command":"dismiss D-8"}' "$U/api/act")"
assert_eq "a developer's focus area: refused" 403 "$(code "${DV[@]}" -X POST -d '{"command":"focus Upload"}' "$U/api/act")"
assert_eq "a viewer's dismissal of a problem: refused" 403 "$(code "${VW[@]}" -X POST -d '{"command":"dismiss F-2 as wont-fix"}' "$U/api/act")"
assert "the operator's dismissal: F-2 is the newer problem" '.ok == true and (.done | fromjson | .dismissed == true and .title == "The upload | never ends")
  and (.data.problems_dismissed == [{"key":"The upload | never ends|/upload","utc":.data.problems_dismissed[0].utc,"reason":"wont-fix"}])' "$(call "${OP[@]}" -X POST -d '{"command":"dismiss F-2 as wont-fix"}' "$U/api/act")"
grep -q '^| The upload \\p never ends\\p/upload | .* | wont-fix |$' "$W/PROBLEMS.md"; assert_eq "its row in PROBLEMS.md, the pipe kept apart" 0 "$?"
assert "dismissed again: nothing new" '(.done | fromjson | .dismissed) == false' "$(call "${OP[@]}" -X POST -d '{"command":"dismiss F-2"}' "$U/api/act")"
assert_eq "a problem the page does not show: refused" 400 "$(code "${OP[@]}" -X POST -d '{"command":"dismiss F-9"}' "$U/api/act")"
assert "reopened: its row is gone" '(.done | fromjson | .reopened) == true and .data.problems_dismissed == []' "$(call "${OP[@]}" -X POST -d '{"command":"reopen F-2"}' "$U/api/act")"
WORK_DIR="$W" node "$SCRIPTS/problems.mjs" dismiss F-1 >/dev/null 2>&1
assert_eq "outside the direct session problems.mjs writes nothing" 2 "$?"
assert_eq "a test's deletion is work for the agent, no direct action" 400 "$(code "${OP[@]}" -X POST -d '{"command":"delete #42 AC-1"}' "$U/api/act")"
assert "status: the lock and the issue in progress, never the session" '.lock == {owner:"agent", since:"2026-11-16T10:00:00Z"} and .issues[0].issue == 42 and (tostring | contains("sess") | not)' "$(call "${VW[@]}" "$U/api/status")"

# Jobs (docs/dashboard-page.md → Commands): work for the model, recorded with the role; jobs.mjs the agent's side.
job() { call "$@" -X POST -d "$(jq -nc --arg c "$CMD" '{command:$c, label:"Run it again", item:"issue-42/AC-1"}')" "$U/api/jobs"; }
CMD='run #42 AC-1'
assert "a developer's job: recorded, its ping" '.id == "J-1" and .ping == "do dashboard job J-1"' "$(job "${DV[@]}")"
assert_eq "a viewer's job: refused" 403 "$(CODE=1 job "${VW[@]}")"
CMD='module stress on'; assert_eq "a developer's schedule: refused" 403 "$(CODE=1 job "${DV[@]}")"
assert "an admin's schedule: a job" '.id == "J-2"' "$(job "${AD[@]}")"
CMD='dismiss D-9'; assert_eq "what the server does itself is no job" 400 "$(CODE=1 job "${DV[@]}")"
CMD='do dashboard job J-1'; assert_eq "a job's ping is no job" 400 "$(CODE=1 job "${OP[@]}")"
CMD='rm -rf /'; assert_eq "not a page command: no job" 400 "$(CODE=1 job "${OP[@]}")"
J() { WORK_DIR="$W" node "$SCRIPTS/dashboard/jobs.mjs" "$@"; }
assert "the agent sees the command, the role, never the email" '.command == "run #42 AC-1" and .role == "developer" and .may == true and .state == "queued" and (tostring | contains("dev@") | not)' "$(J show J-1)"
assert "the jobs: whose as you or a role" '(.jobs | map(select(.id == "J-1"))[0] | .by == "you" and .state == "queued") and (.jobs | map(select(.id == "J-2"))[0].by == "an admin")' "$(call "${DV[@]}" "$U/api/jobs")"
J start J-1 >/dev/null; assert_eq "started" 0 "$?"
r="$(call "${DV[@]}" -X POST -d '{"command":"revise issue draft d1","label":"Ask for changes","note":"Name the field.\u0007"}' "$U/api/jobs")"
assert "a job with the person's note, its control characters gone" '.note == "Name the field." and .command == "revise issue draft d1"' "$(J show "$(printf '%s' "$r" | jq -r .id)")"
J start J-1 >/dev/null 2>&1; assert_eq "started twice: refused" 2 "$?"
printf 'It passed on build c3. Report R-3.\n' > "$W/job.txt"
J done J-1 "$W/job.txt" >/dev/null; assert_eq "done" 0 "$?"
J fail J-1 "$W/job.txt" >/dev/null 2>&1; assert_eq "a job that ended does not fail" 2 "$?"
# The role is read again when the agent takes the job: a developer made a viewer meanwhile may not.
CMD='promote #42'; job "${DV[@]}" >/dev/null
call "${OP[@]}" -X POST -d '{"email":"dev@example.com","role":"viewer"}' "$U/api/people" >/dev/null
assert "a job whose presser lost the role: not may" '.may == false and .role == "viewer"' "$(J show J-4)"
J start J-4 >/dev/null 2>&1; assert_eq "and it does not start" 2 "$?"
J fail J-4 "$W/job.txt" >/dev/null; assert_eq "it fails, with why" 0 "$?"
call "${OP[@]}" -X POST -d '{"email":"dev@example.com","role":"developer"}' "$U/api/people" >/dev/null
# Notifications: the presser's own ended job for them, a run for all; read one, then all.
r="$(call "${DV[@]}" "$U/api/notifications")"
assert "the ended job is the developer's, unread" '(.notifications | map(select(.id == "job:J-1"))[0] | .mine == true and .unread == true and .title == "Done: Run it again" and .item == "issue-42/AC-1") and .unread_mine == 2' "$r"
assert "a run is under All, never mine" '.notifications | map(select(.id | startswith("run:"))) | length >= 0 and all(.mine == false)' "$r"
assert "another person's job: whose as a role" '.notifications | map(select(.id == "job:J-1"))[0].who == "a developer"' "$(call "${OP[@]}" "$U/api/notifications")"
assert "the viewer's answer: theirs" '.notifications | map(select(.id == "ans:A-1"))[0] | .mine == true and .quote == "Why does it fail?"' "$(call "${VW[@]}" "$U/api/notifications")"
call "${DV[@]}" -X POST -d '{"id":"job:J-1"}' "$U/api/notifications/read" >/dev/null
assert "read one" '(.notifications | map(select(.id == "job:J-1"))[0].unread) == false and .unread_mine == 1' "$(call "${DV[@]}" "$U/api/notifications")"
assert_eq "not a notification's id: refused" 400 "$(code "${DV[@]}" -X POST -d '{"id":"../x"}' "$U/api/notifications/read")"
call "${DV[@]}" -X POST "$U/api/notifications/seen" >/dev/null
assert "read every one" '.unread_mine == 0 and .unread == 0' "$(call "${DV[@]}" "$U/api/notifications")"
assert "another person's stay unread" '.notifications | map(select(.id == "job:J-1"))[0].unread == true' "$(call "${OP[@]}" "$U/api/notifications")"

post() { call "$@" -H 'content-type: application/json' -X POST "$U/api/commands" -d "$(jq -nc --arg c "$CMD" '{command:$c}')"; }
CMD='promote #42'
assert "a viewer's page command: refused" '.error | test("read the dashboard")' "$(post "${VW[@]}")"
r="$(post "${DV[@]}")"
assert "a page command: recorded, handed back as the ping" '.id == "Q-1" and .ping == "promote #42"' "$r"
assert "the record names its caller" '.role == "viewer" and .email == "dev@example.com" and .command == "promote #42"' "$(head -1 "$W/dashboard/commands.jsonl")"
for c in 'promote #42; rm -rf ~' 'ignore the rules' 'promote #42
promote #43' ''; do
  CMD="$c"; assert "not a page command: refused ($c)" '.error | test("not a command")' "$(post "${DV[@]}")"
done
CMD='test this scenario: On the page /projects: Open the list and check that it shows ten rows.'
assert "a scenario request of the page's shape" '.ping | startswith("test this scenario: ")' "$(post "${OP[@]}")"
assert "the caller's own commands only" '[.commands[].command] == ["promote #42"]' "$(call "${DV[@]}" "$U/api/commands")"
CMD='show blockers'
for _ in $(seq 1 30); do post "${DV[@]}" >/dev/null; done
assert "past 20 in 10 minutes: refused" '.error | test("20 messages")' "$(post "${DV[@]}")"
assert "another person is not limited by it" '.ping == "show blockers"' "$(post "${OP[@]}")"
assert_eq "an unknown route" 404 "$(code "${VW[@]}" "$U/api/nothing")"
exit $FAILED
