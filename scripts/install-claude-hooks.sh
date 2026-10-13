#!/bin/bash
# Adds Notch Island's hooks to Claude Code's settings (~/.claude/settings.json), or takes them
# out again with --uninstall.
#
#   scripts/install-claude-hooks.sh              add them
#   scripts/install-claude-hooks.sh --uninstall  remove them
#
# It backs the file up first, keeps everything already in it (other hooks included), never adds
# an entry twice, and only ever adds or removes entries that run notch-island-hook. It needs
# nothing that macOS does not already have. Claude Code picks the change up in new sessions.
set -euo pipefail

SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
case "${1:-}" in
    "") ACTION=install ;;
    --uninstall) ACTION=uninstall ;;
    *) echo "usage: $0 [--uninstall]" >&2; exit 2 ;;
esac

# Work on the real file: many people keep settings.json as a symlink into a dotfiles folder,
# and writing to the link's path would replace the link with a plain file.
while [ -L "$SETTINGS" ]; do
    LINK="$(readlink "$SETTINGS")"
    case "$LINK" in
        /*) SETTINGS="$LINK" ;;
        *) SETTINGS="$(dirname "$SETTINGS")/$LINK" ;;
    esac
done

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || { echo '{}' > "$SETTINGS"; chmod 600 "$SETTINGS"; }
MODE="$(stat -f %Lp "$SETTINGS")"
BACKUP="$SETTINGS.bak-notchisland-$(date +%Y%m%d-%H%M%S)"
n=1
while [ -e "$BACKUP" ]; do BACKUP="$SETTINGS.bak-notchisland-$(date +%Y%m%d-%H%M%S)-$n"; n=$((n + 1)); done
cp -p "$SETTINGS" "$BACKUP"

RESULT="$(/usr/bin/osascript -l JavaScript - "$SETTINGS" "$ACTION" <<'JS'
function run(argv) {
    ObjC.import('Foundation');
    const path = argv[0], action = argv[1];
    const text = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null));
    let settings;
    try { settings = JSON.parse(text && text.trim() ? text : '{}'); }
    catch (e) { throw new Error('settings.json is not valid JSON, so it was left alone: ' + e.message); }

    const command = '"$HOME/Library/Application Support/NotchIsland/notch-island-hook"';
    const ours = (h) => h && typeof h.command === 'string' && h.command.indexOf('notch-island-hook') >= 0;
    const events = ['UserPromptSubmit', 'PreToolUse', 'PermissionRequest', 'PostToolUse', 'PostToolUseFailure',
                    'Notification', 'SubagentStop', 'Stop', 'StopFailure', 'SessionEnd'];
    settings.hooks = settings.hooks || {};
    const changed = [];

    for (const event of (action === 'uninstall' ? Object.keys(settings.hooks) : events)) {
        let groups = settings.hooks[event] || [];
        if (action === 'uninstall') {
            const before = JSON.stringify(groups);
            groups = groups
                .map((g) => Object.assign({}, g, { hooks: (g.hooks || []).filter((h) => !ours(h)) }))
                .filter((g) => g.hooks.length > 0);
            if (JSON.stringify(groups) !== before) changed.push(event);
        } else if (!groups.some((g) => (g.hooks || []).some(ours))) {
            // PermissionRequest waits for your answer; everything else runs in the background.
            const entry = event === 'PermissionRequest'
                ? { type: 'command', command: command, timeout: 600 }
                : { type: 'command', command: command, async: true };
            groups.push({ hooks: [entry] });
            changed.push(event);
        }
        if (groups.length > 0) settings.hooks[event] = groups; else delete settings.hooks[event];
    }
    if (Object.keys(settings.hooks).length === 0) delete settings.hooks;

    const out = $(JSON.stringify(settings, null, 2) + '\n');
    if (!out.writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)) {
        throw new Error('could not write ' + path);
    }
    return changed.length ? changed.join(', ') : 'none';
}
JS
)"
chmod "$MODE" "$SETTINGS"

if [ "$RESULT" = none ]; then
    rm -f "$BACKUP"
    if [ "$ACTION" = install ]; then echo "Notch Island's hooks were already there; nothing changed."
    else echo "Notch Island's hooks were not there; nothing changed."; fi
else
    if [ "$ACTION" = install ]; then echo "Added Notch Island to: $RESULT"
    else echo "Removed Notch Island from: $RESULT"; fi
    echo "Backup of the previous file: $BACKUP"
    echo "New Claude Code sessions will use the change."
fi

HOOK="$HOME/Library/Application Support/NotchIsland/notch-island-hook"
if [ "$ACTION" = install ] && [ ! -x "$HOOK" ]; then
    echo
    echo "One more step: open Notch Island once. It puts its hook at"
    echo "  $HOOK"
    echo "and until it is there, Claude Code shows a hook error on each event."
fi
