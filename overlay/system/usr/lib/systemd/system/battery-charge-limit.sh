#!/bin/sh
# Charge limiter for the Xiaomi Mi A3 (laurel_sprout).
#
# Keeps the pack below a configurable state of charge so it does not spend its
# life sitting at 4.4 V, which is what actually ages a lithium cell. Started by
# battery-charge-limit.service.
#
# --- WHICH KNOB, AND WHY ------------------------------------------------------
#
# The charger is a PMI632 driven by qpnp-smb5. Its battery power_supply exposes
# a lot of charging properties but smb5_batt_prop_is_writeable() only accepts a
# handful, and of those exactly two can stop a charge:
#
#   charging_enabled  -> vote(chg->chg_disable_votable, USER_VOTER, ...)
#                        Stops charging the cell. The input path stays up, so
#                        the phone runs off the charger instead of the battery.
#   input_suspend     -> smblib_set_prop_input_suspend()
#                        Cuts the input entirely. The phone then discharges the
#                        battery even though it is plugged in -- the opposite of
#                        what we want, and it cycles the pack.
#
# So charging_enabled. VOLTAGE_MAX (float voltage) would be the better lever --
# capping at ~4.1 V ages the cell far less than cycling between 75% and 80% at
# 4.4 V -- but POWER_SUPPLY_PROP_VOLTAGE_MAX is absent from the writeable list,
# so voltage_max returns -EPERM. That needs a kernel change; this does not.
#
# --- WHY WE NEVER READ charging_enabled BACK ----------------------------------
#
# The getter is  val->intval = !get_effective_result(chg->chg_disable_votable)
# (qpnp-smb5.c:1800) -- the EFFECTIVE result across every voter, not just the
# USER_VOTER this script writes. A read of 0 therefore cannot distinguish "we
# stopped it" from "the thermal / JEITA / FCC-stepper voter stopped it".
# Branching on it would couple this loop to voters it knows nothing about.
#
# Instead we decide want=0/1 from capacity alone and assert it every poll.
# vote() is idempotent, so re-writing the same value costs nothing, and if
# another voter is independently holding charging off our vote simply sits
# behind theirs and takes effect when they release.
#
# --- CONFIGURATION ------------------------------------------------------------
#
# Two layers, in increasing precedence:
#
#   1. Unit defaults, and root-owned EnvironmentFiles. See the .service file.
#   2. USER_CONF, re-read on every poll so edits apply within POLL_INTERVAL
#      with no restart and no root. This is the layer a person actually uses.
#
# USER_CONF is owned and written by the unprivileged desktop user, while this
# script runs as root -- so it is deliberately NOT an EnvironmentFile and NOT
# sourced. systemd's EnvironmentFile would let anything in that file set any
# environment variable on a root process (LD_PRELOAD being the obvious one), and
# `.` would execute it outright. Both are privilege escalation from a
# user-writable path.
#
# It is parsed instead with a sed that can only ever emit 1-3 digits, and the
# result is range-checked before use. The worst a malformed or hostile file can
# do is be ignored, and the worst a valid one can do is pick a charge threshold,
# which is the entire point of the feature.

B=/sys/class/power_supply/battery

DEF_ENABLED=${CHARGE_ENABLED:-1}
DEF_LIMIT=${CHARGE_LIMIT:-80}
DEF_RESUME=${CHARGE_RESUME:-75}
INTERVAL=${CHARGE_POLL_INTERVAL:-30}
USER_CONF=${CHARGE_USER_CONF:-/home/phablet/.config/battery-charge-limit}

log() { echo "battery-charge-limit: $*"; }

is_num() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Extract one integer key from USER_CONF. The capture group is [0-9]{1,3} and
# nothing else is ever printed, so the value cannot carry shell metacharacters.
conf_get() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([0-9]\{1,3\}\)[[:space:]]*\$/\1/p" \
        "$USER_CONF" 2>/dev/null | tail -1
}

# Sets $enabled, $limit and $resume for this poll. Falls back to the unit
# defaults whenever the user file is absent, unreadable, unparseable or
# self-contradictory.
resolve_limits() {
    enabled=$DEF_ENABLED
    limit=$DEF_LIMIT
    resume=$DEF_RESUME
    source=defaults

    [ -r "$USER_CONF" ] || return 0

    ue=$(conf_get CHARGE_ENABLED)
    ul=$(conf_get CHARGE_LIMIT)
    ur=$(conf_get CHARGE_RESUME)

    # CHARGE_ENABLED is deliberately independent of the rest: an off switch must
    # still be honoured even if the limit value alongside it is garbage.
    case "$ue" in
        0|1) enabled=$ue; source=$USER_CONF ;;
    esac

    is_num "$ul" || return 0
    [ "$ul" -ge 50 ] && [ "$ul" -le 100 ] || return 0

    # A hand-written CHARGE_LIMIT of 100 means "no limit", which is the same
    # thing the switch expresses. The UI never writes it -- its slider stops at
    # 95 and it uses CHARGE_ENABLED instead -- but people edit this file.
    if [ "$ul" -ge 100 ]; then
        enabled=0
    fi

    if ! is_num "$ur"; then
        ur=$((ul - 5))
        [ "$ur" -lt 0 ] && ur=0
    fi
    [ "$ur" -lt "$ul" ] || return 0

    limit=$ul
    resume=$ur
    source=$USER_CONF
}

for v in "$DEF_LIMIT" "$DEF_RESUME" "$INTERVAL"; do
    is_num "$v" || {
        log "non-numeric unit setting ($DEF_LIMIT/$DEF_RESUME/$INTERVAL); refusing to run"
        exit 1
    }
done

if [ "$DEF_RESUME" -ge "$DEF_LIMIT" ]; then
    log "CHARGE_RESUME ($DEF_RESUME) must be below CHARGE_LIMIT ($DEF_LIMIT); refusing to run"
    exit 1
fi

if [ ! -w "$B/charging_enabled" ]; then
    log "$B/charging_enabled is not writable; is qpnp-smb5 up?"
    exit 1
fi

log "started; defaults enabled=${DEF_ENABLED} ${DEF_LIMIT}%/${DEF_RESUME}%, user config $USER_CONF, poll ${INTERVAL}s"

want=1
last_want=
last_desc=

while :; do
    resolve_limits

    # Switched off -> hand the charger back and exit 0. Restart=on-failure means
    # a clean exit stays exited, so `systemctl status` genuinely reads inactive
    # rather than "running but doing nothing".
    #
    # Getting started again is battery-charge-limit.path's job: it watches this
    # same config file, so flipping the switch back on rewrites the file and
    # systemd starts us. That is the whole reason an unprivileged settings page
    # can stop and start a root service without a polkit rule or a helper.
    if [ "$enabled" = "0" ]; then
        log "optimisation off (${source}); charging unrestricted, exiting"
        echo 1 > "$B/charging_enabled" 2>/dev/null
        exit 0
    fi

    desc="${limit}/${resume} (${source})"
    if [ "$desc" != "$last_desc" ]; then
        log "limits now ${limit}% stop, ${resume}% resume -- from ${source}"
        last_desc=$desc
    fi

    cap=$(cat "$B/capacity" 2>/dev/null)
    if ! is_num "$cap"; then
        sleep "$INTERVAL"
        continue
    fi

    if [ "$cap" -ge "$limit" ]; then
        want=0
    elif [ "$cap" -le "$resume" ]; then
        want=1
    fi
    # Between resume and limit neither branch fires and $want carries over.
    # That is the hysteresis: without it the charger would toggle continuously
    # at the threshold.

    if [ "$want" != "$last_want" ]; then
        if [ "$want" = "0" ]; then
            log "at ${cap}%, charging off (limit ${limit}%)"
        else
            log "at ${cap}%, charging on (resume ${resume}%)"
        fi
        last_want=$want
    fi

    echo "$want" > "$B/charging_enabled" 2>/dev/null

    sleep "$INTERVAL"
done
