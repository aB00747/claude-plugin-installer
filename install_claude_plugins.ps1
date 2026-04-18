# ================================================================
#  Claude Plugin & MCP Installer v2.0 (Windows PowerShell)
#  - Installs GitHub plugins + registers MCP servers
#  - Scopes superpowers to a target project
#  - Generates CLAUDE.md per plugin (token-efficient context)
#  - Idempotent: safe to re-run anytime
#
#  Usage:
#    .\install_claude_plugins.ps1                          # install only
#    .\install_claude_plugins.ps1 C:\projects\myapp        # + scope superpowers
# ================================================================

param(
    [string]$TargetProject = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Config ───────────────────────────────────────────────────────
$InstallDir  = if ($env:CLAUDE_PLUGIN_DIR) { $env:CLAUDE_PLUGIN_DIR } else { "$HOME\.claude-plugins" }
$SkillsDir   = "$HOME\.claude\skills"
$LogFile     = "$env:TEMP\claude-plugin-$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$ConfigFile  = "$env:APPDATA\Claude\claude_desktop_config.json"

# ── Colours ──────────────────────────────────────────────────────
function Write-Ok($msg)      { Write-Host "  [+] $msg" -ForegroundColor Green;  Add-Content $LogFile "OK:   $msg" }
function Write-Info($msg)    { Write-Host "  --> $msg" -ForegroundColor Cyan;   Add-Content $LogFile "INFO: $msg" }
function Write-Warn($msg)    { Write-Host "  [!] $msg" -ForegroundColor Yellow; Add-Content $LogFile "WARN: $msg" }
function Write-Err($msg)     { Write-Host "  [x] $msg" -ForegroundColor Red;    Add-Content $LogFile "ERR:  $msg" }
function Write-Section($msg) { Write-Host "`n  == $msg ==" -ForegroundColor Cyan; Add-Content $LogFile "=== $msg ===" }

function Has-Command($cmd) {
    return $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue)
}

# ── Plugin registry ───────────────────────────────────────────────
# @{ name; repo; type(auto/node/python); scope(global/project) }
$Plugins = @(
    @{ name="gstack";      repo="https://github.com/garrytan/gstack";        type="auto";   scope="global"  },
    @{ name="superpowers"; repo="https://github.com/obra/superpowers";        type="node";   scope="project" },
    @{ name="graphify";    repo="https://github.com/safishamsi/graphify";     type="python"; scope="global"  }
)

# ── Dependency checks ────────────────────────────────────────────
Write-Section "Checking Dependencies"

if (-not (Has-Command "git")) {
    Write-Err "git is required but not found."
    Write-Host "  Install from: https://git-scm.com/download/win" -ForegroundColor Yellow
    exit 1
}
Write-Ok "git found"

$HasNode = Has-Command "node"
$HasNpm  = Has-Command "npm"
$HasPy   = Has-Command "python"

if ($HasNode) {
    $nodeVer = (node -e "process.stdout.write(process.versions.node)" 2>$null)
    Write-Ok "node $nodeVer"
    $nodeMajor = [int]($nodeVer.Split('.')[0])
    if ($nodeMajor -lt 18) {
        Write-Warn "Node $nodeVer < 18 — some features may not work. Upgrade: winget install OpenJS.NodeJS.LTS"
    } else {
        Write-Ok "Node >= 18 [OK]"
    }
} else {
    Write-Warn "node not found — Node plugins will be skipped"
    Write-Warn "Install: winget install OpenJS.NodeJS.LTS"
}

if ($HasNpm)  { Write-Ok  "npm $(npm -v 2>$null)" } else { Write-Warn "npm not found" }
if ($HasPy)   { Write-Ok  "python $(python --version 2>&1)" } else { Write-Warn "python not found — Python plugins will be skipped" }

# ── Helpers ───────────────────────────────────────────────────────

function Detect-Type($dir) {
    if (Test-Path "$dir\package.json")                                               { return "node" }
    if ((Test-Path "$dir\pyproject.toml") -or (Test-Path "$dir\setup.py") -or (Test-Path "$dir\requirements.txt")) { return "python" }
    return "unknown"
}

function Detect-Entrypoint($dir, $type) {
    if ($type -eq "node") {
        # Read bin/main from package.json
        $ep = ""
        if ($HasNode -and (Test-Path "$dir\package.json")) {
            $ep = node -e "
                try {
                    const p = require('$($dir.Replace('\','/'))/package.json');
                    const b = p.bin; const e = b ? Object.values(b)[0] : (p.main||'');
                    process.stdout.write(e);
                } catch(e){}
            " 2>$null
        }
        if ($ep -and -not [System.IO.Path]::IsPathRooted($ep)) { $ep = Join-Path $dir $ep }
        if (-not $ep -or -not (Test-Path $ep)) {
            foreach ($f in @("index.js","server.js","src\index.js","dist\index.js","cli.js")) {
                if (Test-Path "$dir\$f") { $ep = "$dir\$f"; break }
            }
        }
        return $ep
    }
    if ($type -eq "python") {
        foreach ($f in @("server.py","main.py","src\server.py","__main__.py","app.py")) {
            if (Test-Path "$dir\$f") { return "$dir\$f" }
        }
    }
    return ""
}

function Clone-Or-Update($name, $url, $dir) {
    if (Test-Path "$dir\.git") {
        Write-Info "Updating $name..."
        try {
            git -C $dir fetch --quiet origin 2>>$LogFile
            git -C $dir reset --hard origin/HEAD --quiet 2>>$LogFile
            Write-Ok "Updated $name"
        } catch {
            Write-Warn "Update failed — using cached version"
        }
    } else {
        Write-Info "Cloning $name..."
        git clone --depth 1 --quiet $url $dir 2>>$LogFile
        if ($LASTEXITCODE -ne 0) { Write-Err "Clone failed: $url"; return $false }
        Write-Ok "Cloned $name"
    }
    return $true
}

function Install-Node($dir) {
    if (-not $HasNpm) { Write-Warn "npm missing — skipping"; return $false }
    Write-Info "npm install..."
    Push-Location $dir
    try {
        npm install --prefer-offline --no-audit --no-fund --silent 2>>$LogFile
        if ($LASTEXITCODE -ne 0) { throw "npm install failed" }
        Write-Ok "npm deps ready"
        return $true
    } catch {
        Write-Err "npm install failed — check $LogFile"
        return $false
    } finally {
        Pop-Location
    }
}

function Install-Python($dir) {
    if (-not $HasPy) { Write-Warn "python missing — skipping"; return $false }

    try {
        if (Test-Path "$dir\requirements.txt") {
            Write-Info "pip install requirements.txt..."
            python -m pip install -r "$dir\requirements.txt" -q 2>>$LogFile
        } elseif ((Test-Path "$dir\pyproject.toml") -or (Test-Path "$dir\setup.py")) {
            Write-Info "pip install -e (editable)..."
            python -m pip install -e $dir -q 2>>$LogFile
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "Retrying with --no-build-isolation..."
                python -m pip install -e $dir --no-build-isolation -q 2>>$LogFile
                if ($LASTEXITCODE -ne 0) { throw "pip install failed" }
            }
        }
        Write-Ok "Python deps ready"
        return $true
    } catch {
        Write-Err "pip install failed — check $LogFile"
        return $false
    }
}

function Link-Skill($name, $src) {
    if (-not (Test-Path $SkillsDir)) { New-Item -ItemType Directory -Path $SkillsDir -Force | Out-Null }
    $target = "$SkillsDir\$name"
    if (Test-Path $target) {
        Write-Info "Skill already exists: $name"
    } else {
        # Junction for dirs on Windows (works without admin rights)
        cmd /c mklink /J $target $src 2>>$LogFile | Out-Null
        Write-Ok "Skill linked: $target"
    }
}

function Register-MCP($name, $runner, $entry) {
    $configDir = Split-Path $ConfigFile
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }

    if (-not (Test-Path $ConfigFile)) {
        '{"mcpServers":{}}' | Set-Content $ConfigFile -Encoding UTF8
        Write-Info "Created new config: $ConfigFile"
    }

    # Backup
    Copy-Item $ConfigFile "$ConfigFile.bak" -Force

    $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    if (-not $cfg.mcpServers) { $cfg | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([PSCustomObject]@{}) }

    $newEntry = [PSCustomObject]@{ command = $runner; args = @($entry) }
    $existing = $cfg.mcpServers.$name

    # Idempotent check
    if ($existing -and $existing.command -eq $runner -and $existing.args[0] -eq $entry) {
        Write-Info "MCP already registered: $name"
        return
    }

    $cfg.mcpServers | Add-Member -NotePropertyName $name -NotePropertyValue $newEntry -Force
    $cfg | ConvertTo-Json -Depth 10 | Set-Content $ConfigFile -Encoding UTF8
    Write-Ok "MCP registered: $name"
}

function Generate-ClaudeMd($dir, $name, $type, $entry) {
    $md = "$dir\CLAUDE.md"
    if (Test-Path $md) { Write-Info "CLAUDE.md exists for $name — skipping"; return }

    $lines = @("# $name", "type: $type | entry: $(Split-Path $entry -Leaf)")

    $cmdDir = ""
    if (Test-Path "$dir\commands")         { $cmdDir = "$dir\commands" }
    if (Test-Path "$dir\.claude\commands") { $cmdDir = "$dir\.claude\commands" }

    if ($cmdDir) {
        $cmds = Get-ChildItem $cmdDir -File -Include "*.md","*.sh" -ErrorAction SilentlyContinue |
                ForEach-Object { $_.BaseName } | Sort-Object | Join-String -Separator " "
        if ($cmds) { $lines += "commands: $cmds" }
    }

    $lines | Set-Content $md -Encoding UTF8
    Write-Ok "CLAUDE.md generated for $name"
}

function Scope-ToProject($project) {
    if (-not $project) { return }
    if (-not (Test-Path $project)) { Write-Warn "Project dir not found: $project — skipping"; return }

    $settingsDir  = "$project\.claude"
    $settingsFile = "$settingsDir\settings.json"
    if (-not (Test-Path $settingsDir)) { New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null }

    $cfg = if (Test-Path $settingsFile) { Get-Content $settingsFile -Raw | ConvertFrom-Json } else { [PSCustomObject]@{} }
    if (-not $cfg.plugins) { $cfg | Add-Member -NotePropertyName plugins -NotePropertyValue @() }

    if ($cfg.plugins -notcontains "superpowers@claude-plugins-official") {
        $cfg.plugins += "superpowers@claude-plugins-official"
    }

    $cfg | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8
    Write-Ok "Superpowers scoped to: $project"
}

# ── Main install loop ─────────────────────────────────────────────
Write-Section "Installing Plugins"
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

$Results = @{}

foreach ($plugin in $Plugins) {
    $name  = $plugin.name
    $repo  = $plugin.repo
    $type  = $plugin.type
    $scope = $plugin.scope
    $dir   = "$InstallDir\$name"

    Write-Host "`n  [$name]" -ForegroundColor White

    # 1. Clone / update
    $ok = Clone-Or-Update $name $repo $dir
    if (-not $ok) { $Results[$name] = "FAILED: clone"; continue }

    # 2. Auto-detect type
    if ($type -eq "auto") { $type = Detect-Type $dir }
    Write-Info "type: $type | scope: $scope"

    # 3. Install deps
    $depsOk = switch ($type) {
        "node"    { Install-Node   $dir }
        "python"  { Install-Python $dir }
        default   { Write-Warn "Unknown type — cloned only. Check $dir manually."; $true }
    }
    if (-not $depsOk) { $Results[$name] = "FAILED: deps"; continue }

    # 4. Link skill if global
    if ($scope -eq "global") { Link-Skill $name $dir }

    # 5. Detect entrypoint + register MCP
    $ep = Detect-Entrypoint $dir $type
    if ($ep) {
        $runner = if ($type -eq "python") { "python" } else { "node" }
        Register-MCP $name $runner $ep
        Write-Ok "MCP entry ready: $name -> $(Split-Path $ep -Leaf)"
        $Results[$name] = "INSTALLED"
    } else {
        Write-Warn "No entrypoint found — skill linked but MCP not registered"
        $Results[$name] = "WARNING: no entrypoint"
    }

    # 6. Generate CLAUDE.md
    Generate-ClaudeMd $dir $name $type ($ep ?? "")
}

# ── Scope superpowers ─────────────────────────────────────────────
if ($TargetProject) {
    Write-Section "Scoping Superpowers"
    Scope-ToProject $TargetProject
}

# ── Summary ───────────────────────────────────────────────────────
Write-Section "Summary"
Write-Host ""
foreach ($k in $Results.Keys) {
    $icon = if ($Results[$k] -eq "INSTALLED") { "[+]" } elseif ($Results[$k].StartsWith("FAILED")) { "[x]" } else { "[!]" }
    $col  = if ($Results[$k] -eq "INSTALLED") { "Green" } elseif ($Results[$k].StartsWith("FAILED")) { "Red" } else { "Yellow" }
    Write-Host ("  {0,-6}  {1,-14}  {2}" -f $icon, $k, $Results[$k]) -ForegroundColor $col
}

Write-Host ""
Write-Host "  Plugins : $InstallDir"    -ForegroundColor Cyan
Write-Host "  Skills  : $SkillsDir"     -ForegroundColor Cyan
Write-Host "  Config  : $ConfigFile"    -ForegroundColor Cyan
Write-Host "  Log     : $LogFile"       -ForegroundColor Cyan
Write-Host ""
Write-Host "  Restart Claude Desktop / Claude Code to activate." -ForegroundColor Yellow

if (-not $TargetProject -and (Test-Path "$InstallDir\superpowers")) {
    Write-Host ""
    Write-Host "  Tip: Scope superpowers to your project:" -ForegroundColor Yellow
    Write-Host "  .\install_claude_plugins.ps1 C:\path\to\your\project" -ForegroundColor Cyan
}
