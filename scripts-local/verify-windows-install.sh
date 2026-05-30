#!/usr/bin/env bash
# verify-windows-install.sh
#
# Prüft nach einer frischen Installation von claude-brain-sync auf einer
# Windows-10-VM, ob die Patches (--bare + --no-session-persistence) sowohl
# im Marketplace als auch im aktiven Plugin-Cache vorliegen.
#
# Falls der Cache nicht gepatcht ist (kann passieren, wenn Claude Code
# intern eine ältere Version cacht), wird er aus dem Marketplace
# nachgezogen.
#
# Läuft unter Git Bash auf Windows, sowie macOS/Linux.
#
# Ausführung:
#   bash verify-windows-install.sh

set -euo pipefail

FORK_OWNER="omonien"
FORK_REPO_PLUGIN="claude-brain"
FORK_REPO_DATA="my-claude-brain"

CLAUDE_DIR="${HOME}/.claude"
MARKETPLACE="${CLAUDE_DIR}/plugins/marketplaces/claude-brain-sync"
CACHE_BASE="${CLAUDE_DIR}/plugins/cache/claude-brain-sync/claude-brain-sync"
DATA_BASE="${CLAUDE_DIR}/plugins/data/claude-brain-sync-claude-brain-sync"
BRAIN_CONFIG="${CLAUDE_DIR}/brain-config.json"
BRAIN_REPO="${CLAUDE_DIR}/brain-repo"

log()  { printf "\033[1;34m[*]\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m[ok]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n"  "$*"; }
err()  { printf "\033[1;31m[x]\033[0m %s\n"  "$*" >&2; }

fail=0

# ── 1. Marketplace existiert und ist auf dem Fork ──────────────────────────────
if [ ! -d "$MARKETPLACE/.git" ]; then
  err "Marketplace nicht gefunden: $MARKETPLACE"
  err "Hast du '/plugin marketplace add github:${FORK_OWNER}/${FORK_REPO_PLUGIN}' ausgeführt?"
  exit 1
fi

cd "$MARKETPLACE"
current_url=$(git remote get-url origin 2>/dev/null || echo "")
expected_url="https://github.com/${FORK_OWNER}/${FORK_REPO_PLUGIN}.git"
if [ "$current_url" != "$expected_url" ]; then
  err "Marketplace remote ist '$current_url', erwartet '$expected_url'"
  fail=1
else
  ok "Marketplace Remote zeigt auf Fork"
fi

mp_head=$(git log --oneline -1)
ok "Marketplace HEAD: $mp_head"

# ── 2. Patches im Marketplace vorhanden ────────────────────────────────────────
mp_files_ok=true
for f in scripts/merge-semantic.sh scripts/evolve.sh; do
  if grep -q -- "--bare" "$f" && grep -q -- "--no-session-persistence" "$f"; then
    :
  else
    err "$f im Marketplace enthält die Patches NICHT (--bare/--no-session-persistence fehlt)"
    mp_files_ok=false
    fail=1
  fi
done
if $mp_files_ok; then
  ok "--bare + --no-session-persistence im Marketplace verifiziert"
fi

# ── 3. Cache existiert? Falls ja: Patches vorhanden? ──────────────────────────
cache_dirs=()
if [ -d "$CACHE_BASE" ]; then
  while IFS= read -r d; do cache_dirs+=("$d"); done \
    < <(find "$CACHE_BASE" -maxdepth 2 -type d -name "scripts" -exec dirname {} \;)
fi
if [ -d "$DATA_BASE/scripts" ]; then
  cache_dirs+=("$DATA_BASE")
fi

if [ "${#cache_dirs[@]}" -eq 0 ]; then
  warn "Kein Cache-/Data-Verzeichnis gefunden."
  warn "Das kann passieren, wenn das Plugin gerade frisch via /plugin install"
  warn "geladen wurde aber noch nie ausgeführt wurde. Beim ersten Hook-Lauf"
  warn "legt Claude Code den Cache an. Verify danach erneut ausführen."
else
  patched_count=0
  unpatched_dirs=()
  for d in "${cache_dirs[@]}"; do
    if grep -q -- "--bare" "$d/scripts/merge-semantic.sh" 2>/dev/null && \
       grep -q -- "--bare" "$d/scripts/evolve.sh" 2>/dev/null; then
      ok "Patches aktiv in: $d/scripts/"
      patched_count=$((patched_count+1))
    else
      warn "Cache NICHT gepatcht: $d/scripts/"
      unpatched_dirs+=("$d")
    fi
  done

  # ── 4. Cache automatisch nachpatchen ────────────────────────────────────────
  if [ "${#unpatched_dirs[@]}" -gt 0 ]; then
    log "Patche ${#unpatched_dirs[@]} Cache-Verzeichnis(se) aus Marketplace…"
    for d in "${unpatched_dirs[@]}"; do
      cp "$MARKETPLACE/scripts/common.sh"         "$d/scripts/common.sh"
      cp "$MARKETPLACE/scripts/merge-semantic.sh" "$d/scripts/merge-semantic.sh"
      cp "$MARKETPLACE/scripts/evolve.sh"         "$d/scripts/evolve.sh"
      cp "$MARKETPLACE/scripts/pull.sh"           "$d/scripts/pull.sh"
      if [ -f "$MARKETPLACE/skills/brain-log/SKILL.md" ] && [ -d "$d/skills/brain-log" ]; then
        cp "$MARKETPLACE/skills/brain-log/SKILL.md" "$d/skills/brain-log/SKILL.md"
      fi
      if grep -q -- "--bare" "$d/scripts/merge-semantic.sh"; then
        ok "  ✓ Nachgepatcht: $d"
      else
        err "  ✗ Nachpatch in $d fehlgeschlagen"
        fail=1
      fi
    done
  fi
fi

# ── 5. brain-config.json zeigt auf richtiges Daten-Repo ───────────────────────
if [ -f "$BRAIN_CONFIG" ]; then
  current_remote=$(jq -r '.remote // ""' "$BRAIN_CONFIG" 2>/dev/null)
  expected_data_url="https://github.com/${FORK_OWNER}/${FORK_REPO_DATA}.git"
  if [ "$current_remote" = "$expected_data_url" ]; then
    ok "Daten-Remote in brain-config.json: $current_remote"
  else
    warn "Daten-Remote in brain-config.json: '$current_remote' (erwartet $expected_data_url)"
    warn "Falls Brain noch nicht initialisiert: führe '/brain-join $expected_data_url' im Chat aus."
  fi

  if [ -d "$BRAIN_REPO/.git" ]; then
    origin=$(git -C "$BRAIN_REPO" remote get-url origin 2>/dev/null || echo "")
    if [ "$origin" = "$expected_data_url" ]; then
      ok "brain-repo origin: $origin"
    else
      warn "brain-repo origin: '$origin' (erwartet $expected_data_url)"
    fi
  else
    warn "brain-repo noch nicht initialisiert. Führe '/brain-join' im Claude-Chat aus."
  fi
else
  warn "brain-config.json nicht vorhanden. Führe '/brain-join $expected_data_url' im Claude-Chat aus."
fi

# ── 6. Sanity: laufen aktuell schon Fork-Bomben? ──────────────────────────────
running=0
if running_list=$(ps -axww -o pid,command 2>/dev/null | grep -E "plugins/(cache|marketplaces)/claude-brain-sync|claude .*-p .*--output-format json" | grep -v grep); then
  running=$(echo "$running_list" | wc -l | tr -d ' ')
fi
if [ "$running" -gt 1 ]; then
  warn "Aktuell laufen $running Plugin-Prozesse — könnte eine alte Fork-Bombe sein."
  warn "Wenn die Zahl in 5s wächst → kill via apply-patches-on-other-machine.sh"
fi

# ── 7. Resümee ────────────────────────────────────────────────────────────────
echo
if [ "$fail" -eq 0 ]; then
  ok "Alles in Ordnung. Plugin ist gepatcht und bereit."
  echo
  echo "Nächste Schritte:"
  echo "  • Falls Brain noch nicht initialisiert: in Claude Code '/brain-join https://github.com/${FORK_OWNER}/${FORK_REPO_DATA}.git'"
  echo "  • Sonst: VSCode neu starten und Task-Manager beobachten (keine claude.exe Kaskaden)"
else
  err "Verify gefunden $fail Probleme. Siehe Output oben."
  exit 1
fi
