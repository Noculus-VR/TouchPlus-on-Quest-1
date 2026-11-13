#!/system/bin/sh
# q1_ruby_advert_probe.sh v3 - see how the Quest 1 reacts to a Touch Plus (RUBY) pairing advert.
#
# Starts a normal pairing scan (the same binder call q2ctrl's pair.sh uses) and records what happens.
# It does NOT run q2addr.sh, set props, or restart services; the only state it changes is the scan itself
# and, in SPOOF mode, a pairing attempt (which clears whatever is in the slot being paired).
#
# It detects which libsyncboss is live:
#   q2ctrl v2.5 (hash 7611d69f...)       ADVERT mode: the Touch Plus is rejected, nothing pairs.
#   libsyncboss_ruby_test.so (d2b1994e)  SPOOF mode: the HAL accepts type 23 as hardware type 4 (Jedi).
#   libsyncboss_ruby_test2.so (83296ccc) SPOOF mode too; additionally sends a Jedi-style type byte in the pair command.
#   libsyncboss_ruby_test3.so (227ebf6d) SPOOF mode too; treats a non-zero firmware status in the pair reply as success and goes on to the controller reset step.
#   stock Quest 1 (85a17881...)          refused: stock does not stub the controller firmware-update code.
#
#   adb push q1_ruby_advert_probe.sh /data/local/tmp/ && adb shell chmod 755 /data/local/tmp/q1_ruby_advert_probe.sh
#   adb shell su -c '/data/local/tmp/q1_ruby_advert_probe.sh left'      # or: right   [timeout_ms]
#   adb pull /data/local/tmp/q1_advert_probe.log
#   adb pull /data/local/tmp/q1_advert_probe_full.log
#   adb pull /data/local/tmp/q1_probe_tombstones          (only exists if something crashed during the run)
#
# v3 changes: saves the FULL unfiltered logcat (all buffers) because the filtered view can hide the one
# line that explains a failure; stops waiting when the scan ends instead of after the full timeout;
# copies any tombstone created during the run and prints which process crashed.
#
# Do NOT use q2ctrl's pair.sh for a Touch Plus. It ends by running q2addr.sh detect, which treats any
# calibration blob over 4096 bytes as a Quest 2; a Touch Plus blob is 8168 bytes.
# When you are done, re-pair a Quest 2 controller with q2ctrl's own pair.sh if the slot was cleared.

HAND=${1:-left}
TMO=${2:-60000}
OUT=/data/local/tmp
LOG=$OUT/q1_advert_probe.log
FULL=$OUT/q1_advert_probe_full.log
TOMB=$OUT/q1_probe_tombstones
STAMP=$OUT/q1_probe_start
STOCK_SB=85a1788113f1faff2af91cd204f9d59a01e1040a
PATCHED_SB=7611d69f15101a06369753d8c8edec8161be59cb
RUBY_SB=d2b1994e204c0118694b8630940fcc208965b309
RUBY2_SB=83296ccc9973ef187a8e3112a35398e16f0c270d
RUBY3_SB=227ebf6d77182a8b349e9b60a7c4350d867d35fc

case "$HAND" in
  left)  DEVTYPE=1 ;;
  right) DEVTYPE=0 ;;
  *) echo "usage: $0 [left|right] [timeout_ms]"; exit 1 ;;
esac
[ "$DEVTYPE" = "0" ] || [ "$DEVTYPE" = "1" ] || exit 1

[ "$(id -u)" = "0" ] || { echo "run as root: su -c $0 $HAND"; exit 1; }

: > "$LOG"
rm -rf "$TOMB"
say() { echo "$*" | tee -a "$LOG"; }

LIVE=$(sha1sum /vendor/lib64/libsyncboss.so 2>/dev/null | cut -d' ' -f1)
say "live libsyncboss: $LIVE"
case "$LIVE" in
  $PATCHED_SB) MODE=advert
               say "  = q2ctrl v2.5 patched. ADVERT mode: expect rejection, no pairing." ;;
  $RUBY_SB|$RUBY2_SB|$RUBY3_SB)    MODE=spoof
               say "  = libsyncboss_ruby_test (Touch Plus advert accepted as Jedi, firmware-update functions stubbed)."
               say "  SPOOF mode: this scan will TRY TO PAIR the Touch Plus into the $HAND slot."
               say "  Whatever is paired in the $HAND slot will be cleared. Ctrl-C within 5 seconds to abort."
               sleep 5 ;;
  $STOCK_SB)   say "  = STOCK. The controller firmware-update code is NOT stubbed. Enable the q2ctrl module and reboot first."
               exit 1 ;;
  *)           say "  = unknown build; not proceeding"; exit 1 ;;
esac

say "device: $(getprop ro.product.device) build $(getprop ro.build.version.incremental)"
TP0=$(pidof trackingservice 2>/dev/null); TP0=${TP0%% *}
HP0=$(pidof vendor.oculus.hardware.sensors@1.0-service 2>/dev/null); HP0=${HP0%% *}
say "pids before: trackingservice=${TP0:-none} sensors-hal=${HP0:-none}"
say "paired devices before:"
dumpsys OVRRemoteService 2>/dev/null | grep 'Paired device:' | sed 's/^/  /' | tee -a "$LOG"

touch "$STAMP"
say "scan: hand=$HAND (service type $DEVTYPE) timeout=${TMO}ms - put the Touch Plus in pairing mode NOW"
logcat -b all -c 2>/dev/null
service call OVRRemoteService 13 i32 "$DEVTYPE" i32 "$TMO" >/dev/null 2>&1

secs=$((TMO / 1000)); [ "$secs" -lt 10 ] && secs=10
i=0
while [ $i -lt $secs ]; do
  L=$(logcat -d 2>/dev/null)
  if [ "$MODE" = "advert" ]; then
    echo "$L" | grep -q -E 'Unexpected pulsar hardware type|Hardware type from advertisement' && break
  else
    # the scan is over once management mode is left again (it is entered when the scan starts)
    echo "$L" | grep -q 'ControllerGlue: leave mode Management' && break
  fi
  sleep 2; i=$((i + 2))
done
say "scan ended after about ${i}s (timeout was ${secs}s)"
sleep 10

logcat -b all -d -v threadtime > "$FULL" 2>/dev/null
say "full log: $FULL ($(wc -l < "$FULL") lines)"

say
say "=== pairing / controller lines (filtered view; the full log has everything) ==="
grep -i -E 'pair|unpair|whitelist|bond|advertis|Controller [0-9a-f]{16}|ControllerGlue|ControllerTracking|RemoteService|SyncBossHAL|SyncBossInput|pulsar|hardware type|Successfully|Failed|ignore' "$FULL" | grep -v -E 'IMU [0-9]+ missed|binder' | tail -150 | tee -a "$LOG" | cut -c1-230

say
TP1=$(pidof trackingservice 2>/dev/null); TP1=${TP1%% *}
HP1=$(pidof vendor.oculus.hardware.sensors@1.0-service 2>/dev/null); HP1=${HP1%% *}
say "pids after:  trackingservice=${TP1:-none} sensors-hal=${HP1:-none}"
[ "$TP0" != "$TP1" ] && say "  >> trackingservice RESTARTED during the run"
[ "$HP0" != "$HP1" ] && say "  >> sensors HAL RESTARTED during the run"

say
say "=== tombstones created during the run ==="
NEW=$(find /data/tombstones -type f -newer "$STAMP" 2>/dev/null)
if [ -n "$NEW" ]; then
  mkdir -p "$TOMB"
  for t in $NEW; do
    cp "$t" "$TOMB/" 2>/dev/null
    say "  $t"
    grep -m1 -E '^Cmdline:' "$t" | sed 's/^/    /' | tee -a "$LOG"
    grep -m1 -E '^signal ' "$t" | sed 's/^/    /' | tee -a "$LOG"
    grep -m1 -E '^Abort message' "$t" | sed 's/^/    /' | tee -a "$LOG"
  done
  say "  copied to $TOMB"
else
  say "  none"
fi

say
say "=== paired devices after ==="
dumpsys OVRRemoteService 2>/dev/null | grep 'Paired device:' | tee -a "$LOG"
say
say "done. pull: $LOG  $FULL  $TOMB"
