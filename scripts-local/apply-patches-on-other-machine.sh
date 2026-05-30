#!/usr/bin/env bash
# apply-patches-on-other-machine.sh
#
# Bringt eine zweite Maschine (z.B. Windows VM unter Git Bash) auf den
# gepatchten claude-brain-sync Stand (Fork omonien/claude-brain @ main).
#
# Was es tut:
#   1. Lokal laufende Fork-Bomben-Prozesse killen (claude -p Merge-Aufrufe)
#   2. Marketplace-Klon von toroleapinc → omonien umstellen und auf main holen
#   3. Plugin-Cache mit den gepatchten Scripts überschreiben
#      (das ist die Version, die der SessionStart-Hook tatsächlich ausführt)
#   4. Plugin-Data ebenso (falls vorhanden)
#   5. Brain-Daten-Remote auf omonien/my-claude-brain umhängen
#   6. Alle Sessions mit dem Merge-Prompt aus der History löschen
#
# Voraussetzungen auf der Windows VM:
#   - Git Bash (kommt mit Git for Windows)
#   - git, jq, bash (jq via choco install jq oder scoop install jq)
#   - Plugin claude-brain-sync ist installiert und aktiviert
#
# Ausführung:
#   bash apply-patches-on-other-machine.sh
#
# Sicher: macht keine destruktiven Aktionen ohne lokalen Backup-Marker.

set -euo pipefail

# ── Konfiguration ──────────────────────────────────────────────────────────────
FORK_OWNER="omonien"
FORK_REPO_PLUGIN="claude-brain"        # Plugin-Fork (Code)
FORK_REPO_DATA="my-claude-brain"       # Daten-Sync-Repo (privat)
TARGET_BRANCH="main"                   # Patches sind seit 66fb048 auf main

# Pfade — funktionieren unter macOS, Linux und Git Bash unter Windows.
# In Git Bash entspricht $HOME automatisch %USERPROFILE%.
CLAUDE_DIR="${HOME}/.claude"
MARKETPLACE="${CLAUDE_DIR}/plugins/marketplaces/claude-brain-sync"
CACHE_BASE="${CLAUDE_DIR}/plugins/cache/claude-brain-sync/claude-brain-sync"
DATA_BASE="${CLAUDE_DIR}/plugins/data/claude-brain-sync-claude-brain-sync"
BRAIN_REPO="${CLAUDE_DIR}/brain-repo"
BRAIN_CONFIG="${CLAUDE_DIR}/brain-config.json"
PROJECTS_DIR="${CLAUDE_DIR}/projects"

log()  { printf "\033[1;34m[*]\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m[ok]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n"  "$*"; }
err()  { printf "\033[1;31m[x]\033[0m %s\n"  "$*" >&2; }

# ── 1. Notbremse: laufende Fork-Bomben-Prozesse killen ────────────────────────
log "Suche laufende claude-brain-sync Spawns…"
killed=0
# Linux/macOS-Variante: ps -axww  | Windows Git Bash hat ps mit anderem Format,
# probiere zuerst die Linux-Form, dann die Cygwin/MSYS-Form.
if pids=$(ps -axww -o pid,command 2>/dev/null | grep -E "plugins/(cache|marketplaces)/claude-brain-sync|claude -p - --output-format json" | grep -v grep | awk '{print $1}'); then
  :
else
  pids=$(ps -W -ef 2>/dev/null | grep -E "merge-semantic|pull\.sh.*--auto-merge|claude.*-p .*--output-format json" | grep -v grep | awk '{print $2}' || true)
fi
for pid in $pids; do
  if kill -9 "$pid" 2>/dev/null; then killed=$((killed+1)); fi
done
if [ "$killed" -gt 0 ]; then
  ok "Getötet: $killed Prozess(e)"
  sleep 2
else
  ok "Keine laufenden Plugin-Prozesse"
fi

# ── 2. Marketplace-Klon auf Fork umhängen ─────────────────────────────────────
if [ ! -d "$MARKETPLACE/.git" ]; then
  err "Marketplace nicht gefunden unter $MARKETPLACE — ist das Plugin installiert?"
  exit 1
fi

log "Marketplace-Klon → Fork umhängen"
cd "$MARKETPLACE"
current_url=$(git remote get-url origin 2>/dev/null || echo "")
fork_url="https://github.com/${FORK_OWNER}/${FORK_REPO_PLUGIN}.git"
if [ "$current_url" != "$fork_url" ]; then
  log "  Remote war: $current_url"
  git remote set-url origin "$fork_url"
  ok "  Remote jetzt: $fork_url"
fi

# Refspec auf alle Branches erweitern (Default-Klon hat nur main)
git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'

log "Marketplace fetchen…"
git fetch origin --prune --quiet
git checkout "$TARGET_BRANCH" 2>/dev/null || git checkout -B "$TARGET_BRANCH" "origin/$TARGET_BRANCH"
git reset --hard "origin/$TARGET_BRANCH"
mp_head=$(git log --oneline -1)
ok "  Marketplace HEAD: $mp_head"

# Sanity check: enthält der Marketplace die Patches?
if ! grep -q -- "--bare" scripts/merge-semantic.sh; then
  err "Marketplace HEAD enthält kein --bare. Erwartete Commit 66fb048 oder neuer. Abbruch."
  exit 1
fi
ok "  Patches im Marketplace verifiziert (--bare + --no-session-persistence)"

# ── 3. Plugin-Cache mit Marketplace-Scripts überschreiben ─────────────────────
# Der Cache ist die Version, die der SessionStart-Hook tatsächlich ausführt
# (nicht der Marketplace selbst). Wir kopieren alle relevanten Files.
log "Plugin-Cache patchen…"
cache_dirs=()
if [ -d "$CACHE_BASE" ]; then
  # Es kann mehrere Versions-Subdirs geben (z.B. 0.2.0/) — alle patchen
  while IFS= read -r d; do cache_dirs+=("$d"); done < <(find "$CACHE_BASE" -maxdepth 2 -type d -name "scripts" -exec dirname {} \;)
fi
if [ -d "$DATA_BASE" ]; then
  if [ -d "$DATA_BASE/scripts" ]; then
    cache_dirs+=("$DATA_BASE")
  fi
fi

if [ "${#cache_dirs[@]}" -eq 0 ]; then
  warn "Kein Cache-Verzeichnis gefunden — das ist OK, wenn das Plugin frisch installiert ist."
else
  for d in "${cache_dirs[@]}"; do
    log "  Patche: $d"
    cp "$MARKETPLACE/scripts/common.sh"         "$d/scripts/common.sh"
    cp "$MARKETPLACE/scripts/merge-semantic.sh" "$d/scripts/merge-semantic.sh"
    cp "$MARKETPLACE/scripts/evolve.sh"         "$d/scripts/evolve.sh"
    cp "$MARKETPLACE/scripts/pull.sh"           "$d/scripts/pull.sh"
    if [ -f "$MARKETPLACE/skills/brain-log/SKILL.md" ] && [ -d "$d/skills/brain-log" ]; then
      cp "$MARKETPLACE/skills/brain-log/SKILL.md" "$d/skills/brain-log/SKILL.md"
    fi
    # Verifikation
    if grep -q -- "--bare" "$d/scripts/merge-semantic.sh" && grep -q -- "--bare" "$d/scripts/evolve.sh"; then
      ok "  ✓ Patches aktiv in $d/scripts/"
    else
      err "  Patch fehlgeschlagen in $d/scripts/"
      exit 1
    fi
  done
fi

# ── 4. Brain-Daten-Remote auf Fork umhängen ──────────────────────────────────
if [ -f "$BRAIN_CONFIG" ]; then
  log "brain-config.json: Daten-Remote prüfen"
  current_remote=$(jq -r '.remote // ""' "$BRAIN_CONFIG")
  fork_data_url="https://github.com/${FORK_OWNER}/${FORK_REPO_DATA}.git"
  if [ "$current_remote" != "$fork_data_url" ]; then
    tmp=$(mktemp)
    jq --arg url "$fork_data_url" '.remote = $url' "$BRAIN_CONFIG" > "$tmp" && mv "$tmp" "$BRAIN_CONFIG"
    ok "  brain-config.json remote → $fork_data_url"
  else
    ok "  brain-config.json remote bereits korrekt"
  fi

  if [ -d "$BRAIN_REPO/.git" ]; then
    cd "$BRAIN_REPO"
    current_origin=$(git remote get-url origin 2>/dev/null || echo "")
    if [ "$current_origin" != "$fork_data_url" ]; then
      git remote set-url origin "$fork_data_url"
      ok "  brain-repo origin → $fork_data_url"
    else
      ok "  brain-repo origin bereits korrekt"
    fi
  fi
else
  warn "brain-config.json nicht vorhanden — Plugin ggf. noch nicht initialisiert"
fi

# ── 5. Verseuchte Sessions löschen ────────────────────────────────────────────
log "Räume Plugin-Merge-Sessions aus ${PROJECTS_DIR}…"
if [ ! -d "$PROJECTS_DIR" ]; then
  warn "Keine Projects-Verzeichnis gefunden — überspringe."
else
  # Aktuelle Session NICHT löschen — finde sie via CLAUDE_SESSION_ID falls gesetzt,
  # sonst lass den Filter (erste User-Nachricht beginnt mit Merge-Prompt) alle
  # echten Konversationen automatisch ausnehmen.
  current_session="${CLAUDE_SESSION_ID:-}.jsonl"
  deleted=0
  while IFS= read -r f; do
    base=$(basename "$f")
    [ "$base" = "$current_session" ] && continue
    first_user_raw=$(jq -r 'select(.message.role=="user") | .message.content | if type=="string" then . else (.[0].text // "") end' "$f" 2>/dev/null | head -5)
    if echo "$first_user_raw" | grep -q "You are merging knowledge bases from the same person across multiple machines"; then
      rm -f "$f" && deleted=$((deleted+1))
    fi
  done < <(find "$PROJECTS_DIR" -type f -name "*.jsonl" -exec grep -l "merging knowledge bases from the same person" {} + 2>/dev/null)
  ok "  Gelöscht: $deleted Plugin-Merge-Session(s)"
fi

# ── 6. Zusammenfassung ────────────────────────────────────────────────────────
echo
ok "Fertig."
echo
echo "Marketplace : $mp_head"
echo "Cache       : $(for d in "${cache_dirs[@]}"; do echo -n "$d "; done)"
echo
echo "Nächster Schritt:"
echo "  1. VSCode auf dieser Maschine neu starten."
echo "  2. Beobachten: Activity Monitor / Task Manager sollte KEINE neuen"
echo "     'claude -p' Prozesse im Sekundentakt mehr zeigen."
echo "  3. Session-Liste sollte sauber bleiben (keine neuen"
echo "     'You are merging knowledge bases…' Einträge)."
echo "  4. Falls ein Merge lief: ls ~/.claude/brain-runs/ zeigt die Detail-Logs;"
echo "     /brain-log verbose zeigt sie an."
