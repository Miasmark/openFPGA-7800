# Sourced by run_step7.sh and smoke/run_smoke.sh: lock_by_ancestor, the test
# that the Quartus lock $LOCK, already known to be held, is held by this
# process or one of its ancestors and not by some other job (one Quartus job
# at a time, docs/ENVIRONMENT.md 3.5).
#
# /proc/locks names the process that took a flock lock
# ("N: FLOCK ADVISORY WRITE <pid> <major>:<minor>:<inode> 0 EOF"; a waiter's
# line has "->"). It must be this process or one of its ancestors. When the
# process that took it has exited (exec 9>lock; flock 9; ...), the lock
# lives on in an open file, so then an ancestor holding the file open counts.
lock_by_ancestor() {
	local d ino id holders h p anc="" f lockp
	d=$(stat -L -c %d "$LOCK") && ino=$(stat -L -c %i "$LOCK") || return 1
	id=$(printf '%02x:%02x:%s' $(( (d >> 8) & 0xfff )) $(( (d & 0xff) | ((d >> 12) & 0xfff00) )) "$ino")
	holders=$(awk -v id="$id" '$2 == "FLOCK" && $6 == id { print $5 }' /proc/locks)
	p=$$
	while [ -n "$p" ] && [ "$p" -gt 0 ]; do
		anc="$anc $p"
		[ "$p" = 1 ] && break
		p=$(awk '/^PPid:/ { print $2 }' "/proc/$p/status" 2>/dev/null)
	done
	for h in $holders; do
		case " $anc " in *" $h "*) return 0 ;; esac
	done
	for h in $holders; do
		[ -d "/proc/$h" ] && { echo "$(basename "$0"): the Quartus lock is held by PID $h ($(tr '\0' ' ' < "/proc/$h/cmdline" 2>/dev/null | cut -c1-120)), not by an ancestor of this run" >&2; return 1; }
	done
	lockp=$(realpath "$LOCK")
	for p in $anc; do
		for f in /proc/"$p"/fd/*; do
			[ "$(readlink "$f" 2>/dev/null)" = "$lockp" ] && return 0
		done
	done
	echo "$(basename "$0"): the Quartus lock is held (by PID(s) ${holders:-none listed}, no longer running), and no ancestor of this run has it open" >&2
	return 1
}
