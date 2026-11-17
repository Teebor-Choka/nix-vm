#!/usr/bin/env bash
# linux-host-suite.sh — live acceptance suite for running qemu microVMs from a Linux host that is
# not managed by this module (lib.mkStandaloneHost) — and, equally, from NixOS.
#
# Builds a throwaway fixture flake (one qemu VM, one read-only + one read-write extraShare,
# forwardSshAgent = false), then boots it via the `nix-vm` helper and asserts the Linux-host contract:
#   1  mkStandaloneHost + mkMicrovmFleet export a runnable `nix-vm` package that lists the VM
#   2  `vm run` propagates exit codes over repeated boots (the late-digits race is intermittent)
#   3  readOnly share: guest writes fail, even after a guest-root remount rw; the host dir is untouched
#   4  read-write share: guest writes land on the host owned by the invoking user (uid squash)
#   5  virtiofsd runs per share; --readonly on the ro share only; every guest uid is squashed
#   6  the helper falls back to python3/socat from nixpkgs when the host has neither on PATH
#   7  a virtiofsd that cannot start: clear error with the log tail, no hang, nothing left behind
#   8  a python3 already on the host PATH wins over the nixpkgs fallback
#   9  two concurrent instances of one VM: both work, one's teardown leaves the other's helpers alone
#  10  teardown leaves no virtiofsd/qemu process, run dir or socket behind
#  11  SIGTERM to the launcher never leaves a half-torn-down instance (virtiofsd xor qemu alive)
#  Also in 3-5: an explicit-tag ro share, and the /nix/store share served --readonly.
#  Not covered: blocked unprivileged user namespaces (needs root to flip the sysctl; shows up as the
#  7 error path), and the per-share cache/extraArgs options the helper ignores (documented limit).
#
# Needs a REAL host: /dev/kvm, unprivileged user namespaces, network for the first guest build. Like
# vm-smoke-suite.sh it is not a `nix flake check` derivation; the flake only `bash -n`-checks it.
#
# Params (env):
#   SRC    nix-vm source tree to test            (default: this repo)
#   VM     fixture VM name                       (default: lhs-test; its state dir is deleted on exit)
#   REPS   boots for the exit-code check, per code  (default: 3)
#   ONLY   space-separated section numbers to run (default: all; 1 always runs, it builds the helper)
#
# Usage: linux-host-suite.sh
set -uo pipefail

SRC=$(cd "${SRC:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd)
VM=${VM:-lhs-test}
BAD=$VM-bad # second fixture VM whose share source cannot be served (section 7)
REPS=${REPS:-3}
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/microvm"
STATE=$STATE_ROOT/$VM
want() { [ -z "${ONLY:-}" ] || [[ " $ONLY " == *" $1 "* ]]; }

PASS=0
FAIL=0
SKIP=0
pass() { echo "✓ PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "✗ FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "- SKIP: $1"; SKIP=$((SKIP + 1)); }

[ "$(uname -s)" = Linux ] || { echo "linux-host-suite: needs a Linux host" >&2; exit 2; }
[ -w /dev/kvm ] || { echo "linux-host-suite: /dev/kvm missing or not writable" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/lhs.XXXXXX")
RO=$WORK/ro RO2=$WORK/docs RW=$WORK/rw FIX=$WORK/fixture
mkdir -p "$RO" "$RO2" "$RW" "$FIX"
echo "seed-$$" > "$RO/seed"
echo "docs-$$" > "$RO2/seed"

# Nothing may outlive the suite: stop whatever still references the fixture, then drop its files.
# Patterns carry the fixture VM names, so another VM on the same host is never touched.
cleanup() {
  pkill -f -- "$WORK" 2>/dev/null
  pkill -f -- "microvm/$VM/" 2>/dev/null
  pkill -f -- "$VM-virtiofs" 2>/dev/null
  pkill -f -- "qemu.*$VM" 2>/dev/null
  rm -rf "$WORK" "$STATE" "$STATE_ROOT/$BAD"
  # The helper creates $STATE_ROOT/logs on first use; drop our logs, and the dirs if nothing else is in them.
  rm -f "$STATE_ROOT"/logs/"$VM"-*.log "$STATE_ROOT"/logs/"$BAD"-*.log
  rmdir "$STATE_ROOT/logs" "$STATE_ROOT" 2>/dev/null
}
trap cleanup EXIT

# vm_run <label> <timeout-s> <cmd…> — sets RC and OUT (stdout only; stderr to $WORK/err)
NIXVM=
vm_run() {
  local t=$1; shift
  OUT=$(VM_RUN_TIMEOUT=$t timeout $((t + 60)) "$NIXVM" run "$VM" "$@" 2>"$WORK/err")
  RC=$?
}

# Command lines of the fixture VM's virtiofsd processes (one per share, plus /nix/store). The socket
# name `<vm>-virtiofs-<tag>.sock` carries the VM name, so a VM already running on the host is not matched.
vfsd_procs() { ps -eo args= | grep -F -- "$VM-virtiofs" | grep '[v]irtiofsd'; }
# Number of the fixture VM's qemu processes.
qemu_count() { pgrep -fc -- "qemu.*$VM"; }

echo "=== Linux-host suite (SRC=$SRC VM=$VM) ==="

# ── fixture flake ─────────────────────────────────────────────────────────────
cat > "$FIX/flake.nix" <<EOF
{
  inputs.nix-vm.url = "path:$SRC";
  outputs = { self, nix-vm }:
    let
      inputs = nix-vm.inputs // { inherit nix-vm; };
      host = nix-vm.lib.mkStandaloneHost {
        inherit inputs;
        modules = [{
          custom.username = "$(id -un)";
          custom.flakeDir = "$FIX";
          custom.microvms.$VM = {
            hypervisor = "qemu";
            forwardSshAgent = false;
            extraShares = [
              { source = "$RO"; mountPoint = "/mnt/ro"; readOnly = true; }
              # explicit tag that differs from basename(mountPoint): host and guest must agree on it
              { source = "$RO2"; mountPoint = "/mnt/ro-two"; tag = "docs"; readOnly = true; }
              { source = "$RW"; mountPoint = "/mnt/rw"; }
            ];
          };
          # a share whose source does not exist: virtiofsd cannot start (section 7)
          custom.microvms.$BAD = {
            hypervisor = "qemu";
            forwardSshAgent = false;
            extraShares = [{ source = "$WORK/does-not-exist"; mountPoint = "/mnt/gone"; }];
          };
        }];
      };
      fleet = nix-vm.lib.mkMicrovmFleet {
        inherit inputs;
        hosts.linux = { system = "x86_64-linux"; class = "nixos"; };
        builtHosts.linux = host;
        includeBuilder = false;
      };
    in { inherit (fleet) packages; };
}
EOF

# ── 1) export + list ──────────────────────────────────────────────────────────
echo "── 1) nix-vm package exported and lists the VM"
if NIXVM_OUT=$(nix build --no-link --print-out-paths "$FIX#nix-vm" 2>"$WORK/build.err") \
  && [ -x "$NIXVM_OUT/bin/nix-vm" ]; then
  NIXVM=$NIXVM_OUT/bin/nix-vm
  LIST=$("$NIXVM" list 2>&1)  # not piped into grep -q: pipefail + SIGPIPE would flag a match as failure
  if grep -q "$VM" <<<"$LIST"; then
    pass "1) nix-vm exported by the fleet and lists '$VM'"
  else
    fail "1) nix-vm list does not show '$VM'"
  fi
else
  fail "1) could not build .#nix-vm: $(tail -n 5 "$WORK/build.err")"
  echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
  exit 1
fi

# ── 2) exit codes over repeated boots ─────────────────────────────────────────
if want 2; then
echo "── 2) exit-code propagation x$REPS per code"
codes_bad=""
for i in $(seq "$REPS"); do
  vm_run 300 true;      [ "$RC" = 0 ] || codes_bad="$codes_bad true#$i=$RC"
  vm_run 300 'exit 3';  [ "$RC" = 3 ] || codes_bad="$codes_bad exit3#$i=$RC"
done
[ -z "$codes_bad" ] && pass "2) exit 0 and exit 3 propagated on every boot" || fail "2) wrong exit codes:$codes_bad"
fi

# ── 3-5) shares: one boot, inspected from the host while the guest is alive ─
if want 3; then
echo "── 3-5) read-only and read-write shares, virtiofsd flags"
GUEST='
echo "DOCS_SEED=$(cat /mnt/ro-two/seed)"
touch /mnt/ro-two/guest-wrote 2>/dev/null && echo DOCS_WRITE_OK || echo DOCS_WRITE_DENIED
echo "RO_SEED=$(cat /mnt/ro/seed)"
touch /mnt/ro/guest-wrote 2>/dev/null && echo RO_WRITE_OK || echo RO_WRITE_DENIED
if sudo -n mount -o remount,rw /mnt/ro 2>/dev/null; then
  echo REMOUNT_OK
  touch /mnt/ro/guest-wrote2 2>/dev/null && echo RO_REMOUNT_WRITE_OK || echo RO_REMOUNT_WRITE_DENIED
else
  echo REMOUNT_UNAVAILABLE
fi
echo guest > /mnt/rw/from-guest && echo RW_WRITE_OK || echo RW_WRITE_DENIED
echo HOLD; sleep 40
'
( VM_RUN_TIMEOUT=300 timeout 360 "$NIXVM" run "$VM" "$GUEST" >"$WORK/shares.out" 2>"$WORK/shares.err"; echo $? > "$WORK/shares.rc" ) &
runner=$!

# Wait for the guest to reach its sleep, then read the host's process table.
for _ in $(seq 300); do [ -f "$WORK/shares.rc" ] && break; [ -f "$RW/from-guest" ] && break; sleep 1; done
PROCS=$(vfsd_procs)
ro_line=$(grep -F -- "--shared-dir=$RO " <<<"$PROCS")
docs_line=$(grep -F -- "--shared-dir=$RO2 " <<<"$PROCS")
rw_line=$(grep -F -- "--shared-dir=$RW " <<<"$PROCS")
store_line=$(grep -F -- "--shared-dir=/nix/store" <<<"$PROCS")
if [ -n "$ro_line" ] && [ -n "$docs_line" ] && [ -n "$rw_line" ]; then
  pass "5a) one virtiofsd per extraShare"
else
  fail "5a) missing virtiofsd for ro='${ro_line:+yes}' docs='${docs_line:+yes}' rw='${rw_line:+yes}'"
fi
grep -q -- '--readonly' <<<"$ro_line" && pass "5b) ro share served with --readonly" || fail "5b) ro share without --readonly"
grep -q -- '--readonly' <<<"$rw_line" && fail "5c) rw share wrongly served --readonly" || pass "5c) rw share served read-write"
grep -q -- '--readonly' <<<"$docs_line" \
  && pass "5e) ro share with an explicit tag served --readonly (host and guest agree on the tag)" \
  || fail "5e) explicit-tag ro share not served --readonly: $docs_line"
grep -q -- '--readonly' <<<"$store_line" \
  && pass "5f) /nix/store share served --readonly" || fail "5f) /nix/store share not read-only: '$store_line'"
if [ -n "$PROCS" ] && ! grep -v -- 'squash-guest' <<<"$PROCS" | grep -q .; then
  pass "5d) every virtiofsd squashes guest uid/gid"
else
  fail "5d) a virtiofsd runs without squash-guest translation"
fi
wait "$runner"
SH_OUT=$(cat "$WORK/shares.out"); SH_RC=$(cat "$WORK/shares.rc" 2>/dev/null || echo "?")

[ "$SH_RC" = 0 ] || fail "3) share boot exited $SH_RC: $(tail -n 5 "$WORK/shares.err")"
grep -q "RO_SEED=seed-$$" <<<"$SH_OUT" && pass "3a) host file readable through the ro share" || fail "3a) ro share seed not readable: $SH_OUT"
grep -q RO_WRITE_DENIED <<<"$SH_OUT" && pass "3b) guest write to the ro share denied" || fail "3b) guest wrote to the ro share"
if grep -q REMOUNT_OK <<<"$SH_OUT"; then
  grep -q RO_REMOUNT_WRITE_DENIED <<<"$SH_OUT" \
    && pass "3c) write denied after a guest remount rw (host-side --readonly holds)" \
    || fail "3c) guest write succeeded after remounting the ro share rw"
else
  skip "3c) guest has no passwordless sudo, remount defence not exercised (5b still covers the flag)"
fi
if ls "$RO" | grep -q guest-wrote; then fail "3d) host ro dir changed: $(ls "$RO")"; else pass "3d) host ro dir untouched"; fi
grep -q "DOCS_SEED=docs-$$" <<<"$SH_OUT" && grep -q DOCS_WRITE_DENIED <<<"$SH_OUT" \
  && pass "3e) explicit-tag ro share: readable, guest write denied" \
  || fail "3e) explicit-tag ro share misbehaves: $SH_OUT"
if ls "$RO2" | grep -q guest-wrote; then fail "3f) host docs dir changed: $(ls "$RO2")"; else pass "3f) host docs dir untouched"; fi

grep -q RW_WRITE_OK <<<"$SH_OUT" && pass "4a) guest write to the rw share succeeds" || fail "4a) guest write to the rw share failed: $SH_OUT"
if [ "$(cat "$RW/from-guest" 2>/dev/null)" = guest ] && [ "$(stat -c %u "$RW/from-guest" 2>/dev/null)" = "$(id -u)" ]; then
  pass "4b) host sees the file, owned by the invoking user"
else
  fail "4b) host file missing or wrong owner: $(ls -ln "$RW" 2>&1)"
fi
fi

# ── 6) PATH without python3/socat ─────────────────────────────────────────────
if want 6; then
echo "── 6) helper falls back to python3/socat from nixpkgs"
SHIM=$WORK/shim; mkdir -p "$SHIM"
IFS=: read -ra dirs <<<"$PATH"
for d in "${dirs[@]}"; do
  for f in "$d"/*; do
    n=${f##*/}
    case $n in python | python3 | python3.* | socat) continue ;; esac
    [ -x "$f" ] && [ ! -e "$SHIM/$n" ] && ln -s "$f" "$SHIM/$n"
  done
done 2>/dev/null
if PATH=$SHIM command -v python3 >/dev/null || PATH=$SHIM command -v socat >/dev/null; then
  skip "6) could not hide python3/socat from PATH"
else
  OUT=$(PATH=$SHIM VM_RUN_TIMEOUT=300 timeout 360 "$NIXVM" run "$VM" 'echo fallback-ok' 2>"$WORK/err"); RC=$?
  { [ "$RC" = 0 ] && grep -q fallback-ok <<<"$OUT"; } \
    && pass "6) vm run works with python3/socat absent from PATH" \
    || fail "6) vm run without python3/socat (rc=$RC): $(tail -n 5 "$WORK/err")"
fi
fi

# ── 7) a virtiofsd that cannot start ──────────────────────────────────────────
if want 7; then
echo "── 7) virtiofsd that cannot start: clear error, no hang, nothing left behind"
t0=$SECONDS
OUT=$(VM_RUN_TIMEOUT=120 timeout 180 "$NIXVM" run "$BAD" true 2>"$WORK/bad.err"); RC=$?
{ [ "$RC" != 0 ] && [ "$RC" != 124 ] && [ $((SECONDS - t0)) -lt 120 ]; } \
  && pass "7a) launch fails fast (rc=$RC)" \
  || fail "7a) rc=$RC after $((SECONDS - t0))s (0 = failure ignored, 124 = hang)"
grep -q 'virtiofsd .* did not start' "$WORK/bad.err" \
  && pass "7b) error names the virtiofsd that failed" \
  || fail "7b) no 'did not start' error: $(tail -n 5 "$WORK/bad.err")"
# The log lives in the instance dir, which the exit trap wipes, so the helper must print its tail.
awk '/did not start/{f=1;next} f' "$WORK/bad.err" | grep -q . \
  && pass "7c) error carries the virtiofsd log tail" || fail "7c) no log lines after the error"
left=$(ps -eo args= | grep -F -- "$BAD-virtiofs" | grep '[v]irtiofsd')
[ -z "$left" ] && pass "7d) no virtiofsd left from the failed launch" || fail "7d) leftover virtiofsd: $left"
runs=$(ls -d "$STATE_ROOT/$BAD"/run.* 2>/dev/null)
[ -z "$runs" ] && pass "7e) no run dir left from the failed launch" || fail "7e) leftover run dirs: $runs"
fi

# ── 8) host python3 wins over the fallback ────────────────────────────────────
if want 8; then
echo "── 8) a python3 already on PATH wins over the nixpkgs fallback"
REAL_PY=$(command -v python3)
if [ -z "$REAL_PY" ]; then
  skip "8) host has no python3, nothing to take precedence"
else
  mkdir -p "$WORK/prec"
  printf '#!/bin/sh\necho hit >> "%s/py-hit"\nexec "%s" "$@"\n' "$WORK" "$REAL_PY" > "$WORK/prec/python3"
  chmod +x "$WORK/prec/python3"
  OUT=$(PATH="$WORK/prec:$PATH" VM_RUN_TIMEOUT=300 timeout 360 "$NIXVM" run "$VM" true 2>"$WORK/err"); RC=$?
  { [ "$RC" = 0 ] && [ -s "$WORK/py-hit" ]; } \
    && pass "8) the host's python3 ran the console driver, the fallback only appends" \
    || fail "8) host python3 not used (rc=$RC, hits=$(wc -l < "$WORK/py-hit" 2>/dev/null))"
fi
fi

# ── 9) two concurrent instances ───────────────────────────────────────────────
if want 9; then
echo "── 9) two concurrent instances of one VM"
rm -f "$RW"/inst-a "$RW"/inst-b "$WORK/a.rc"
( VM_RUN_TIMEOUT=300 timeout 360 "$NIXVM" run "$VM" 'echo a > /mnt/rw/inst-a; sleep 45' >"$WORK/a.out" 2>"$WORK/a.err"; echo $? > "$WORK/a.rc" ) &
a=$!
for _ in $(seq 300); do { [ -f "$RW/inst-a" ] || [ -f "$WORK/a.rc" ]; } && break; sleep 1; done
before=$(vfsd_procs | wc -l)
vm_run 300 'echo b > /mnt/rw/inst-b'; b_rc=$RC
# B's helpers die asynchronously after its launcher exits; give them a moment before counting.
for _ in $(seq 20); do [ "$(vfsd_procs | wc -l)" = "$before" ] && break; sleep 0.5; done
after=$(vfsd_procs | wc -l)
wait "$a"; a_rc=$(cat "$WORK/a.rc" 2>/dev/null || echo "?")
{ [ "$b_rc" = 0 ] && [ -f "$RW/inst-b" ]; } \
  && pass "9a) second instance boots and writes while the first runs" \
  || fail "9a) second instance rc=$b_rc: $(tail -n 5 "$WORK/err")"
{ [ "$before" -gt 0 ] && [ "$after" = "$before" ]; } \
  && pass "9b) second instance's teardown left the first's $before virtiofsd alone" \
  || fail "9b) virtiofsd count $before before, $after after the second instance exited"
{ [ "$a_rc" = 0 ] && [ -f "$RW/inst-a" ]; } \
  && pass "9c) first instance unaffected, exit 0" \
  || fail "9c) first instance rc=$a_rc: $(tail -n 5 "$WORK/a.err")"
fi

# ── 10) teardown ──────────────────────────────────────────────────────────────
if want 10; then
echo "── 10) teardown leaves nothing behind"
for _ in $(seq 20); do [ -z "$(vfsd_procs)" ] && [ "$(qemu_count)" = 0 ] && break; sleep 0.5; done
[ -z "$(vfsd_procs)" ] && pass "10a) no virtiofsd left" || fail "10a) leftover virtiofsd: $(vfsd_procs)"
[ "$(qemu_count)" = 0 ] && pass "10b) no qemu left" || fail "10b) leftover qemu: $(qemu_count)"
runs=$(ls -d "$STATE"/run.* 2>/dev/null)
[ -z "$runs" ] && pass "10c) no per-instance run dir left" || fail "10c) leftover run dirs: $runs"
fi

# ── 11) SIGTERM to the launcher ───────────────────────────────────────────────
# _sandy_reap_box is a no-op while the guest lives (a stray TERM must not orphan a running box), so
# either outcome is fine: instance fully gone or fully alive. Virtiofsd without qemu, or qemu without
# virtiofsd, is a broken guest. Runs last: a live instance is killed by the exit trap, not torn down.
if want 11; then
echo "── 11) SIGTERM to the launcher leaves no half-torn-down instance"
"$NIXVM" run "$VM" 'sleep 120' >"$WORK/t.out" 2>"$WORK/t.err" &
hp=$!
for _ in $(seq 300); do [ "$(qemu_count)" -gt 0 ] && [ -n "$(vfsd_procs)" ] && break; sleep 1; done
kill -TERM "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
for _ in $(seq 40); do [ "$(qemu_count)" = 0 ] && [ -z "$(vfsd_procs)" ] && break; sleep 1; done
q=$(qemu_count); v=$(vfsd_procs | wc -l)
if [ "$q" = 0 ] && [ "$v" = 0 ]; then
  pass "11) instance fully torn down after SIGTERM"
elif [ "$q" -gt 0 ] && [ "$v" -gt 0 ]; then
  pass "11) instance fully alive after SIGTERM (launcher TERM is guarded by design)"
else
  fail "11) half-torn-down instance after SIGTERM: qemu=$q virtiofsd=$v"
fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = 0 ]
