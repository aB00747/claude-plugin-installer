#!/usr/bin/env bash
# ================================================================
#  Claude Plugin & MCP Installer v2.0
#  - Installs GitHub plugins + registers MCP servers
#  - Scopes superpowers to a target project
#  - Generates CLAUDE.md per plugin (token-efficient context)
#  - Idempotent: safe to re-run anytime
#
#  Usage:
#    ./install_claude_plugins.sh                        # install only
#    ./install_claude_plugins.sh /srv/http/ctms/abhishek  # + scope superpowers
# ================================================================
set -euo pipefail
IFS=$'\n\t'

# ── Config ───────────────────────────────────────────────────────
INSTALL_DIR="${CLAUDE_PLUGIN_DIR:-$HOME/.claude-plugins}"
SKILLS_DIR="$HOME/.claude/skills"
LOG_FILE="/tmp/claude-plugin-$(date +%Y%m%d_%H%M%S).log"
TARGET_PROJECT="${1:-}"   # optional: scope superpowers to this project

# ── Colors (disable when not a tty) ─────────────────────────────
if [[ -t 1 ]]; then
  R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' X='\033[0m'
else
  R='' G='' Y='' C='' B='' X=''
fi

# ── Logging ──────────────────────────────────────────────────────
log()     { echo "[$(date +%H:%M:%S)] $*" >> "$LOG_FILE"; }
ok()      { echo -e "${G}✓${X} $*";   log "OK:   $*"; }
info()    { echo -e "${C}→${X} $*";   log "INFO: $*"; }
warn()    { echo -e "${Y}⚠${X}  $*";  log "WARN: $*"; }
err()     { echo -e "${R}✗${X} $*";   log "ERR:  $*"; }
die()     { err "$*"; exit 1; }
section() { echo -e "\n${B}${C}── $* ${X}\n"; log "=== $* ==="; }

# ── OS + Claude Desktop config path ──────────────────────────────
case "$(uname -s)" in
  Darwin)              CONFIG_FILE="$HOME/Library/Application Support/Claude/claude_desktop_config.json" ;;
  MINGW*|MSYS*|CYGWIN*) CONFIG_FILE="${APPDATA:-$HOME/AppData/Roaming}/Claude/claude_desktop_config.json" ;;
  *)                   CONFIG_FILE="$HOME/.config/Claude/claude_desktop_config.json" ;;
esac

# ── Plugin registry ───────────────────────────────────────────────
# "name | repo URL | type(auto/node/python) | scope(global/project)"
declare -a PLUGINS=(
  "gstack|https://github.com/garrytan/gstack|auto|global"
  "superpowers|https://github.com/obra/superpowers|node|project"
  "graphify|https://github.com/safishamsi/graphify|python|global"
)

# ── Dependency checks ────────────────────────────────────────────
section "Checking Dependencies"

has() { command -v "$1" &>/dev/null; }
need() { has "$1" || die "$1 is required but not found. Install it first."; }

need git

has node   && ok "node  $(node -e 'process.stdout.write(process.versions.node)' 2>/dev/null)" \
           || warn "node not found — Node plugins will be skipped"

has npm    && ok "npm   $(npm -v 2>/dev/null)" \
           || warn "npm not found — Node plugins will be skipped"

has python3 && ok "python3 $(python3 -c 'import sys;print(sys.version.split()[0])' 2>/dev/null)" \
            || warn "python3 not found — Python plugins will be skipped"

# Node version check (18+ required for full feature set)
if has node; then
  NODE_MAJOR=$(node -e "process.stdout.write(process.versions.node.split('.')[0])" 2>/dev/null)
  [[ "${NODE_MAJOR:-0}" -ge 18 ]] \
    && ok "Node v${NODE_MAJOR} >= 18 ✓" \
    || warn "Node v${NODE_MAJOR} < 18 — some features (e.g. /browse) may not work. Run: nvm install 18"
fi

# ── Helpers ───────────────────────────────────────────────────────

# Auto-detect project type from files present
detect_type() {
  local d="$1"
  [[ -f "$d/package.json"   ]] && echo "node"   && return
  [[ -f "$d/pyproject.toml" || -f "$d/setup.py" || -f "$d/requirements.txt" ]] \
                                 && echo "python" && return
  echo "unknown"
}

# Find the runnable entrypoint for a plugin
detect_entrypoint() {
  local dir="$1" type="$2" ep=""

  if [[ "$type" == "node" ]]; then
    # Read bin/main from package.json
    has node && ep=$(node -e "
      try {
        const p = require('$dir/package.json');
        const b = p.bin; const e = b ? Object.values(b)[0] : (p.main||'');
        process.stdout.write(e);
      } catch(e){}
    " 2>/dev/null) || true

    # Resolve relative path
    [[ -n "$ep" && "$ep" != /* ]] && ep="$dir/$ep"

    # Fallback scan if still empty or file missing
    if [[ -z "$ep" || ! -f "$ep" ]]; then
      for f in index.js server.js src/index.js dist/index.js cli.js; do
        [[ -f "$dir/$f" ]] && ep="$dir/$f" && break
      done
    fi

  elif [[ "$type" == "python" ]]; then
    for f in server.py main.py src/server.py __main__.py app.py; do
      [[ -f "$dir/$f" ]] && ep="$dir/$f" && break
    done
  fi

  echo "${ep:-}"
}

# Clone fresh or pull latest
clone_or_update() {
  local name="$1" url="$2" dir="$3"
  if [[ -d "$dir/.git" ]]; then
    info "Updating $name..."
    git -C "$dir" fetch --quiet origin 2>>"$LOG_FILE" \
      && git -C "$dir" reset --hard origin/HEAD --quiet 2>>"$LOG_FILE" \
      || warn "Update failed — using cached version"
  else
    info "Cloning $name..."
    git clone --depth 1 --quiet "$url" "$dir" 2>>"$LOG_FILE" \
      || { err "Clone failed: $url"; return 1; }
  fi
  ok "Cloned/updated: $name"
}

# Install Node deps with offline-first + audit skip
install_node() {
  local dir="$1"
  has npm || { warn "npm missing — skipping"; return 1; }
  info "npm install..."
  (cd "$dir" && npm install --prefer-offline --no-audit --no-fund --silent 2>>"$LOG_FILE") \
    || { err "npm install failed — check $LOG_FILE"; return 1; }
  ok "npm deps ready"
}

# Install Python deps with --no-build-isolation fallback (fixes pyproject.toml issues)
install_python() {
  local dir="$1"
  has python3 || { warn "python3 missing — skipping"; return 1; }

  if [[ -f "$dir/requirements.txt" ]]; then
    info "pip install requirements.txt..."
    python3 -m pip install -r "$dir/requirements.txt" -q 2>>"$LOG_FILE" \
      || { err "pip requirements failed"; return 1; }

  elif [[ -f "$dir/pyproject.toml" || -f "$dir/setup.py" ]]; then
    info "pip install -e (editable)..."
    python3 -m pip install -e "$dir" -q 2>>"$LOG_FILE" \
      || {
        warn "Normal install failed — retrying with --no-build-isolation..."
        python3 -m pip install -e "$dir" --no-build-isolation -q 2>>"$LOG_FILE" \
          || { err "pip editable install failed"; return 1; }
      }
  fi

  ok "Python deps ready"
}

# Link plugin dir into ~/.claude/skills for global slash-command access
link_skill() {
  local name="$1" src="$2"
  mkdir -p "$SKILLS_DIR"
  if [[ -L "$SKILLS_DIR/$name" ]]; then
    info "Skill already linked: $name"
  elif [[ -d "$SKILLS_DIR/$name" ]]; then
    warn "~/.claude/skills/$name exists as a real dir — not overwriting"
  else
    ln -sf "$src" "$SKILLS_DIR/$name" && ok "Skill linked: ~/.claude/skills/$name"
  fi
}

# Write MCP entry to Claude Desktop config (idempotent)
register_mcp() {
  local name="$1" runner="$2" entry="$3"

  # Bootstrap empty config if missing
  if [[ ! -f "$CONFIG_FILE" ]]; then
    mkdir -p "$(dirname "$CONFIG_FILE")"
    echo '{"mcpServers":{}}' > "$CONFIG_FILE"
    info "Created new config: $CONFIG_FILE"
  fi

  # Backup before modifying
  cp "$CONFIG_FILE" "${CONFIG_FILE}.bak" 2>/dev/null || true

  python3 - "$name" "$runner" "$entry" "$CONFIG_FILE" <<'PYEOF'
import json, sys

name, runner, entry, path = sys.argv[1:]
with open(path) as f:
    cfg = json.load(f)

cfg.setdefault("mcpServers", {})
new = {"command": runner, "args": [entry]}

# Skip if entry is identical (idempotent)
if cfg["mcpServers"].get(name) == new:
    print(f"  MCP already registered: {name}")
    sys.exit(0)

cfg["mcpServers"][name] = new
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print(f"  MCP registered: {name}")
PYEOF
}

# Generate a compact CLAUDE.md so Claude Code loads minimal context per plugin
generate_claude_md() {
  local dir="$1" name="$2" type="$3" entry="$4"
  local md="$dir/CLAUDE.md"

  # Don't overwrite an existing authored CLAUDE.md
  [[ -f "$md" ]] && { info "CLAUDE.md exists for $name — skipping"; return; }

  {
    echo "# $name"
    echo "type: $type | entry: ${entry##*/}"
    # List slash commands if a commands dir exists
    local cmd_dir=""
    [[ -d "$dir/commands"        ]] && cmd_dir="$dir/commands"
    [[ -d "$dir/.claude/commands" ]] && cmd_dir="$dir/.claude/commands"
    if [[ -n "$cmd_dir" ]]; then
      local cmds
      cmds=$(find "$cmd_dir" -maxdepth 1 \( -name "*.md" -o -name "*.sh" \) 2>/dev/null \
             | xargs -I{} basename {} 2>/dev/null \
             | sed 's/\.[^.]*$//' | sort | tr '\n' ' ')
      [[ -n "$cmds" ]] && echo "commands: $cmds"
    fi
  } > "$md"

  ok "CLAUDE.md generated for $name"
}

# Scope superpowers plugin to a project's .claude/settings.json
scope_to_project() {
  local project="$1"
  [[ -z "$project" ]] && return
  [[ ! -d "$project" ]] && { warn "Project dir not found: $project — skipping scope"; return; }

  local settings="$project/.claude/settings.json"
  mkdir -p "$(dirname "$settings")"

  python3 - "$settings" <<'PYEOF'
import json, sys, os
path = sys.argv[1]
cfg = json.load(open(path)) if os.path.exists(path) else {}
cfg.setdefault("plugins", [])
if "superpowers@claude-plugins-official" not in cfg["plugins"]:
    cfg["plugins"].append("superpowers@claude-plugins-official")
json.dump(cfg, open(path, "w"), indent=2)
print(f"  scoped superpowers → {path}")
PYEOF
  ok "Superpowers scoped to: $project"
}

# ── Main install loop ─────────────────────────────────────────────
section "Installing Plugins"
mkdir -p "$INSTALL_DIR"

declare -A RESULTS=()

for row in "${PLUGINS[@]}"; do
  IFS='|' read -r name repo type scope <<< "$row"
  dir="$INSTALL_DIR/$name"

  echo -e "\n${B}[$name]${X}"

  # 1. Clone or update
  clone_or_update "$name" "$repo" "$dir" || { RESULTS[$name]="❌ clone failed"; continue; }

  # 2. Auto-detect type if not explicit
  [[ "$type" == "auto" ]] && type=$(detect_type "$dir")
  info "type: $type | scope: $scope"

  # 3. Install dependencies
  case "$type" in
    node)    install_node   "$dir" || { RESULTS[$name]="❌ npm install failed";  continue; } ;;
    python)  install_python "$dir" || { RESULTS[$name]="❌ pip install failed";  continue; } ;;
    unknown) warn "Unknown type — cloned only. Inspect $dir manually." ;;
  esac

  # 4. Link as skill (global scope)
  [[ "$scope" == "global" ]] && link_skill "$name" "$dir"

  # 5. Detect entrypoint + register MCP
  ep=$(detect_entrypoint "$dir" "$type")
  if [[ -n "$ep" ]]; then
    runner="node"; [[ "$type" == "python" ]] && runner="python3"
    register_mcp "$name" "$runner" "$ep"
    ok "MCP entry ready: $name → ${ep##*/}"
    RESULTS[$name]="✅ installed"
  else
    warn "No entrypoint found — skill linked but MCP not registered. Add manually."
    RESULTS[$name]="⚠️  no entrypoint"
  fi

  # 6. Generate compact CLAUDE.md for token-efficient context
  generate_claude_md "$dir" "$name" "$type" "$ep"
done

# ── Scope superpowers to target project ──────────────────────────
if [[ -n "$TARGET_PROJECT" ]]; then
  section "Scoping Superpowers"
  scope_to_project "$TARGET_PROJECT"
fi

# ── Final summary ─────────────────────────────────────────────────
section "Summary"
printf "  %-14s  %s\n" "Plugin" "Status"
printf "  %-14s  %s\n" "──────────────" "────────────────────────"
for name in "${!RESULTS[@]}"; do
  printf "  %-14s  %s\n" "$name" "${RESULTS[$name]}"
done

echo ""
echo -e "  Plugins : ${C}$INSTALL_DIR${X}"
echo -e "  Skills  : ${C}$SKILLS_DIR${X}"
echo -e "  Config  : ${C}$CONFIG_FILE${X}"
echo -e "  Log     : ${C}$LOG_FILE${X}"
echo ""
echo -e "${Y}  Restart Claude Desktop / Claude Code to activate.${X}"

if [[ -z "$TARGET_PROJECT" && -n "$(ls -A "$INSTALL_DIR/superpowers" 2>/dev/null)" ]]; then
  echo ""
  echo -e "  ${Y}Tip:${X} Scope superpowers to your project:"
  echo -e "  ${C}$0 /srv/http/ctms/abhishek${X}"
fi
