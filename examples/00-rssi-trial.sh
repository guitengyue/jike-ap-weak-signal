#!/bin/sh
# For an administrator-controlled AP. /sbin/wifi sources /lib/wifi/*.sh.
# Use a subshell so variables, traps and failures never alter the caller.
(
    base=/etc/gecoos/rssi-policy-trial
    [ -f "$base/armed" ] && [ ! -d /sys/module/umac ] || exit 0
    mkdir /tmp/rssi-policy-trial.lock 2>/dev/null || exit 0
    trap 'rmdir /tmp/rssi-policy-trial.lock 2>/dev/null' EXIT
    [ ! -d /sys/module/umac ] && [ -f "$base/armed" ] || exit 0

    # Consume the single-use marker before touching the loader path.
    mv "$base/armed" "$base/consumed" || exit 1
    sync
    [ "$(uname -r)" = 4.4.60 ] || exit 1
    module=/lib/modules/4.4.60/umac.ko
    digest() { sha256sum "$1" | cut -d ' ' -f 1; }
    stock=$(digest "/rom$module") || exit 1
    case "$stock" in
        54171772269e778d3133174dcb6e5d677539e501a1cef2c975ca6a61fbda2319|f8f83ac4c34a3eacbd32126785ed0cf61ff945eda09044335192c9fd2e25e0cc|9ece3e2c6bef524d0ee78fdc4af8363f44618e2b22978ad135631ca9b926cb50) ;;
        *) exit 1 ;;
    esac
    [ "$stock" = "$(cat "$base/stock.sha256")" ] && [ "$stock" = "$(digest "$module")" ] || exit 1
    expected=$(cat "$base/patched.sha256") || exit 1
    case "$expected" in ''|*[!0-9a-f]*) exit 1 ;; esac
    [ "${#expected}" -eq 64 ] && [ -f "$base/patched.ko" ] &&
        [ "$expected" != "$stock" ] && [ "$expected" = "$(digest "$base/patched.ko")" ] || exit 1

    mount -o bind "$base/patched.ko" "$module" || exit 1
    printf '%s\n' "$expected" > /tmp/rssi-policy-trial.bound
) || logger -t rssi-policy-trial 'Trial hook failed; check the hashes and mount status.'
