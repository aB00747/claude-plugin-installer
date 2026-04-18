# claude-plugin-installer

A single Bash script that installs, configures, and manages Claude Code plugins and MCP servers from GitHub — automatically.

No manual JSON editing. No hunting for entrypoints. Just run and go.

---

## What It Does

- Clones GitHub-based Claude plugins into `~/.claude-plugins/`
- Auto-detects Node.js or Python project type and installs dependencies
- Registers each plugin as an MCP server in Claude Desktop's config
- Links global plugins into `~/.claude/skills/` for slash-command access
- Generates a compact `CLAUDE.md` per plugin to reduce token usage in Claude Code
- Scopes project-level plugins (like `superpowers`) to a specific directory
- **Idempotent** — safe to re-run; skips what's already installed

---

## Plugins Included

| Plugin | Repo | Type | Scope |
|--------|------|------|-------|
| gstack | [garrytan/gstack](https://github.com/garrytan/gstack) | auto | global |
| superpowers | [obra/superpowers](https://github.com/obra/superpowers) | node | project |
| graphify | [safishamsi/graphify](https://github.com/safishamsi/graphify) | python | global |

**Global** plugins are available in every project via `~/.claude/skills/`.  
**Project** plugins must be scoped to a directory (see usage below).

---

## Prerequisites

| Tool | Required | Notes |
|------|----------|-------|
| `git` | ✅ Yes | For cloning repos |
| `node` + `npm` | For Node plugins | v18+ recommended |
| `python3` + `pip` | For Python plugins | Any modern version |

---

## Installation

**Linux / macOS:**
```bash
git clone https://github.com/YOUR_USERNAME/claude-plugin-installer.git
cd claude-plugin-installer
chmod +x install_claude_plugins.sh
./install_claude_plugins.sh
```

**Windows (PowerShell):**
```powershell
git clone https://github.com/YOUR_USERNAME/claude-plugin-installer.git
cd claude-plugin-installer

# Allow script execution (one-time, if not already set)
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

.\install_claude_plugins.ps1
```

**Windows (Git Bash / WSL):**
```bash
./install_claude_plugins.sh   # same as Linux
```

---

## Usage

**Linux / macOS:**
```bash
# Install all plugins globally
./install_claude_plugins.sh

# Install + scope superpowers to a specific project
./install_claude_plugins.sh /path/to/your/project
```

**Windows (PowerShell):**
```powershell
# Install all plugins globally
.\install_claude_plugins.ps1

# Install + scope superpowers to a specific project
.\install_claude_plugins.ps1 C:\path\to\your\project
```

**Custom install directory (all platforms):**
```bash
# Linux/macOS
CLAUDE_PLUGIN_DIR=/custom/path ./install_claude_plugins.sh

# Windows PowerShell
$env:CLAUDE_PLUGIN_DIR = "D:\claude-plugins"
.\install_claude_plugins.ps1
```

### Example output

```
── Checking Dependencies

✓ node  20.11.0
✓ npm   10.2.4
✓ python3 3.11.6
✓ Node v20 >= 18 ✓

── Installing Plugins

[gstack]
→ Cloning gstack...
✓ Cloned/updated: gstack
→ type: node | scope: global
→ npm install...
✓ npm deps ready
✓ Skill linked: ~/.claude/skills/gstack
✓ MCP entry ready: gstack → index.js
✓ CLAUDE.md generated for gstack

── Summary

  Plugin          Status
  ──────────────  ────────────────────────
  gstack          ✅ installed
  superpowers     ✅ installed
  graphify        ✅ installed

  Plugins : /home/user/.claude-plugins
  Skills  : /home/user/.claude/skills
  Config  : /home/user/.config/Claude/claude_desktop_config.json
  Log     : /tmp/claude-plugin-20260418_143012.log

  Restart Claude Desktop / Claude Code to activate.
```

---

## Verifying Installation

After running, check what's active:

```bash
# See all installed plugins
cat ~/.claude/plugins/installed_plugins.json

# See linked skills
ls ~/.claude/skills/

# Verify MCP config
cat ~/.config/Claude/claude_desktop_config.json   # Linux
cat ~/Library/Application\ Support/Claude/claude_desktop_config.json  # macOS
```

Then open Claude Code in your project and type `/help` — all registered slash commands will be listed.

---

## Troubleshooting

**Windows: script execution blocked**
```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

**Windows: mklink requires admin (skill linking)**  
The script uses directory junctions (`mklink /J`) which don't need admin rights on most Windows setups. If it fails, run PowerShell as Administrator once.

**Windows: `python` not found but Python is installed**  
Windows sometimes installs Python as `python3`. Edit line 20 of the `.ps1` file:
```powershell
$HasPy = Has-Command "python3"
# and update the runner line further down to "python3"
```

**Node version too old**
```bash
# Install nvm then upgrade
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash
nvm install 18 && nvm use 18
```

**Python pyproject.toml install fails**  
The script automatically retries with `--no-build-isolation`. If it still fails:
```bash
cd ~/.claude-plugins/graphify
pip install . --no-build-isolation
```

**Superpowers not showing slash commands in a project**  
It needs to be scoped to that project explicitly:
```bash
./install_claude_plugins.sh /path/to/your/project
```
Or inside Claude Code chat in that project:
```
/plugin install superpowers@claude-plugins-official
```

**Check the log for any error**
```bash
cat /tmp/claude-plugin-*.log
```

---

## Configuration

### Change install directory
```bash
CLAUDE_PLUGIN_DIR=/custom/path ./install_claude_plugins.sh
```

### Add your own plugin

**Linux/macOS** — edit the `PLUGINS` array in `install_claude_plugins.sh`:
```bash
declare -a PLUGINS=(
  "gstack|https://github.com/garrytan/gstack|auto|global"
  "superpowers|https://github.com/obra/superpowers|node|project"
  "graphify|https://github.com/safishamsi/graphify|python|global"
  "myplugin|https://github.com/you/myplugin|auto|global"   # ← add here
)
```

**Windows** — edit the `$Plugins` array in `install_claude_plugins.ps1`:
```powershell
$Plugins = @(
    @{ name="gstack";      repo="https://github.com/garrytan/gstack";    type="auto";   scope="global"  },
    @{ name="myplugin";    repo="https://github.com/you/myplugin";        type="auto";   scope="global"  }  # ← add here
)
```

Format fields: `name` | `repo` (GitHub URL) | `type` (`auto`/`node`/`python`) | `scope` (`global`/`project`)

---

## What Is CLAUDE.md?

Each installed plugin gets a minimal `CLAUDE.md` file generated automatically. Claude Code reads this file to understand the plugin without loading its entire source tree — keeping context lean and token usage low.

Example generated `CLAUDE.md`:
```
# gstack
type: node | entry: index.js
commands: review plan-ceo-review qa investigate ship
```

If a plugin already has its own `CLAUDE.md`, the script skips generation and leaves it untouched.

---

## Platform Support

| Platform | Script | Status |
|----------|--------|--------|
| Linux | `install_claude_plugins.sh` | ✅ Tested |
| macOS | `install_claude_plugins.sh` | ✅ Supported |
| Windows (native) | `install_claude_plugins.ps1` | ✅ Supported |
| Windows (Git Bash / WSL) | `install_claude_plugins.sh` | ✅ Works too |

---

## How It Works

```
install_claude_plugins.sh
│
├── check deps (git, node, npm, python3)
│
├── for each plugin:
│   ├── git clone --depth 1  (or git pull if exists)
│   ├── detect type          (node / python / unknown)
│   ├── install deps         (npm install / pip install)
│   ├── detect entrypoint    (reads package.json bin/main, then scans)
│   ├── link skill           (global → ~/.claude/skills/name)
│   ├── register MCP         (writes to claude_desktop_config.json)
│   └── generate CLAUDE.md   (compact context file)
│
└── scope superpowers        (writes project/.claude/settings.json)
```

---

## Contributing

Pull requests are welcome. To add a plugin or fix a bug:

1. Fork the repo
2. Create a branch: `git checkout -b feat/my-plugin`
3. Add your plugin to the `PLUGINS` array
4. Test on a clean machine
5. Open a PR with what the plugin does and why it's useful

Please test on both Linux and macOS if possible.

---

## License

MIT — use it, fork it, share it freely.
