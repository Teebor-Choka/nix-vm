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
#   7  teardown leaves no virtiofsd/qemu process, run dir or socket behind
#
# Needs a REAL host: /dev/kvm, unprivileged user namespaces, network for the first guest build. Like
# vm-smoke-suite.sh it is not a `nix flake check` derivation; the flake only `bash -n`-checks it.
#
# Params (env):
#   SRC    nix-vm source tree to test            (default: this repo)
#   VM     fixture VM name                       (default: lhs-test; its state dir is deleted on exit)
#   REPS   boots for the exit-code check, per code  (default: 3)
#
# Usage: linux-host-suite.sh
set -uo pipefail

SRC=$(cd "${SRC:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd)
VM=${VM:-lhs-test}
REPS=${REPS:-3}
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/microvm/$VM"

PASS=0
FAIL=0
SKIP=0
pass() { echo "✓ PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "✗ FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "- SKIP: $1"; SKIP=$((SKIP + 1)); }

[ "$(uname -s)" = Linux ] || { echo "linux-host-suite: needs a Linux host" >&2; exit 2; }
[ -w /dev/kvm ] || { echo "linux-host-suite: /dev/kvm missing or not writable" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/lhs.XXXXXX")
RO=$WORK/ro RW=$WORK/rw FIX=$WORK/fixture
mkdir -p "$RO" "$RW" "$FIX"
echo "seed-$$" > "$RO/seed"

# Nothing may outlive the suite: stop whatever still references the fixture, then drop its files.
cleanup() {
  pkill -f -- "$WORK" 2>/dev/null
  pkill -f -- "microvm/$VM/" 2>/dev/null
  rm -rf "$WORK" "$STATE"
}
trap cleanup EXIT

# vm_run <label> <timeout-s> <cmd…> — sets RC and OUT (stdout only; stderr to $WORK/err)
NIXVM=
vm_run() {
  local t=$1; shift
  OUT=$(VM_RUN_TIMEOUT=$t timeout $((t + 60)) "$NIXVM" run "$VM" "$@" 2>"$WORK/err")
  RC=$?
}

# virtiofsd processes serving the fixture shares: "<shared-dir>|<args>" lines
vfsd_procs() { ps -eo args= | grep -F "$WORK" | grep '[v]irtiofsd' | grep -- '--shared-dir'; }

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
              { source = "$RW"; mountPoint = "/mnt/rw"; }
            ];
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
echo "── 2) exit-code propagation x$REPS per code"
bad=""
for i in $(seq "$REPS"); do
  vm_run 300 true;      [ "$RC" = 0 ] || bad="$bad true#$i=$RC"
  vm_run 300 'exit 3';  [ "$RC" = 3 ] || bad="$bad exit3#$i=$RC"
done
[ -z "$bad" ] && pass "2) exit 0 and exit 3 propagated on every boot" || fail "2) wrong exit codes:$bad"

# ── 3-5) shares: one boot, inspected from the host while the guest is alive ─
echo "── 3-5) read-only and read-write shares, virtiofsd flags"
GUEST='
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
ro_line=$(grep -- "--shared-dir=$RO" <<<"$PROCS")
rw_line=$(grep -- "--shared-dir=$RW" <<<"$PROCS")
if [ -n "$ro_line" ] && [ -n "$rw_line" ]; then
  pass "5a) one virtiofsd per extraShare"
else
  fail "5a) missing virtiofsd for ro='${ro_line:+yes}' rw='${rw_line:+yes}'"
fi
grep -q -- '--readonly' <<<"$ro_line" && pass "5b) ro share served with --readonly" || fail "5b) ro share without --readonly"
grep -q -- '--readonly' <<<"$rw_line" && fail "5c) rw share wrongly served --readonly" || pass "5c) rw share served read-write"
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

grep -q RW_WRITE_OK <<<"$SH_OUT" && pass "4a) guest write to the rw share succeeds" || fail "4a) guest write to the rw share failed: $SH_OUT"
if [ "$(cat "$RW/from-guest" 2>/dev/null)" = guest ] && [ "$(stat -c %u "$RW/from-guest" 2>/dev/null)" = "$(id -u)" ]; then
  pass "4b) host sees the file, owned by the invoking user"
else
  fail "4b) host file missing or wrong owner: $(ls -ln "$RW" 2>&1)"
fi

# ── 6) PATH without python3/socat ─────────────────────────────────────────────
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

# ── 7) teardown ───────────────────────────────────────────────────────────────
echo "── 7) teardown leaves nothing behind"
for _ in $(seq 20); do [ -z "$(vfsd_procs)" ] && break; sleep 0.5; done
left=$(ps -eo pid=,args= | grep -F "$WORK" | grep -v grep | grep -v "$0")
runs=$(ls -d "$STATE"/run.* 2>/dev/null)
[ -z "$left" ] && pass "7a) no virtiofsd/qemu process left" || fail "7a) leftover processes: $left"
[ -z "$runs" ] && pass "7b) no per-instance run dir left" || fail "7b) leftover run dirs: $runs"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = 0 ]
