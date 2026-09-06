#!/bin/sh
# Charge limiter for the Xiaomi Mi A3 (laurel_sprout). Started by
# battery-charge-limit.service.
#
# Writes /sys/class/power_supply/battery/charging_enabled (the one qpnp-smb5
# writeable prop that stops the cell without cycling the pack). The value is
# never read back: the getter is the effective result across all voters, so it
# can't tell our vote from thermal/JEITA. We just assert want=0/1 from capacity
# every poll; vote() is idempotent.
#
# USER_CONF is written by the unprivileged user and read by this root script, so
# it is parsed by hand with a digits-only sed and range-checked -- never sourced
# and never an EnvironmentFile (both would be privilege escalation). See
# DEVELOPMENT.md.

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

    # CHARGE_ENABLED is independent of the rest: honour an off switch even if
    # the limit beside it is garbage.
    case "$ue" in
        0|1) enabled=$ue; source=$USER_CONF ;;
    esac

    is_num "$ul" || return 0
    [ "$ul" -ge 50 ] && [ "$ul" -le 100 ] || return 0

    # A hand-written CHARGE_LIMIT of 100 means "no limit".
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

    # Switched off -> hand the charger back and exit 0 (the clean exit sticks;
    # battery-charge-limit.path restarts us when the file changes again).
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
    # Between resume and limit neither branch fires and $want carries over
    # (hysteresis).

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
