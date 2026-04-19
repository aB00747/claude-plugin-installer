# ================================================================
#  Claude Plugin Installer v3.1  (PowerShell 5.1 compatible)
#
#  Zero prereqs needed - auto installs git, node, python.
#  npm: 4-level fallback to handle ETARGET and version errors.
#  pip: 3-level fallback for pyproject.toml issues.
#  Safe to re-run anytime (idempotent).
#
#  Usage:
#    .\install_claude_plugins.ps1
#    .\install_claude_plugins.ps1 -TargetProject "C:\projects\myapp"
#    .\install_claude_plugins.ps1 -SkipAutoInstall
# ================================================================
param(
    [string]$TargetProject   = "",
    [switch]$SkipAutoInstall = $false
)

$ErrorActionPreference = "Continue"

# ── Paths ─────────────────────────────────────────────────────────
$InstallDir = "$HOME\.claude-plugins"
if ($env:CLAUDE_PLUGIN_DIR) { $InstallDir = $env:CLAUDE_PLUGIN_DIR }
$SkillsDir  = "$HOME\.claude\skills"
$LogFile    = "$env:TEMP\claude-plugin-$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$ConfigFile = "$env:APPDATA\Claude\claude_desktop_config.json"

# ── Output helpers ────────────────────────────────────────────────
function WL  { param($m) Add-Content -Path $LogFile -Value $m -ErrorAction SilentlyContinue }
function OK  { param($m) Write-Host "  [+] $m" -ForegroundColor Green;  WL "OK:   $m" }
function INF { param($m) Write-Host "  --> $m" -ForegroundColor Cyan;   WL "INFO: $m" }
function WAR { param($m) Write-Host "  [!] $m" -ForegroundColor Yellow; WL "WARN: $m" }
function ERR { param($m) Write-Host "  [x] $m" -ForegroundColor Red;    WL "ERR:  $m" }
function SEC { param($m) Write-Host "`n  ==== $m ====" -ForegroundColor Cyan; WL "=== $m ===" }

function Has {
    param($cmd)
    return ($null -ne (Get-Command $cmd -ErrorAction SilentlyContinue))
}

function RefreshPath {
    $mp = [System.Environment]::GetEnvironmentVariable("PATH","Machine")
    $up = [System.Environment]::GetEnvironmentVariable("PATH","User")
    $env:PATH = "$mp;$up"
}

function RunNpm {
    param([string[]]$Args)
    $out = & npm $Args 2>&1
    WL ($out | Out-String)
    return $out
}

function RunPip {
    param([string[]]$Args)
    $out = & $script:PythonCmd -m pip $Args 2>&1
    WL ($out | Out-String)
    return $out
}

# ── Plugin list ───────────────────────────────────────────────────
$Plugins = @(
    @{ name="gstack";      repo="https://github.com/garrytan/gstack";    ptype="auto";   scope="global"  },
    @{ name="superpowers"; repo="https://github.com/obra/superpowers";    ptype="node";   scope="project" },
    @{ name="graphify";    repo="https://github.com/safishamsi/graphify"; ptype="python"; scope="global"  }
)

# ── STEP 1: Prerequisites ─────────────────────────────────────────
SEC "Checking and Installing Prerequisites"

# -- git --
if (-not (Has "git")) {
    if ($SkipAutoInstall) {
        ERR "git is required. Install from https://git-scm.com/download/win then re-run."
        exit 1
    }
    WAR "git not found - installing via winget..."
    if (Has "winget") {
        winget install --id Git.Git --silent --accept-package-agreements --accept-source-agreements 2>&1 |
            Tee-Object -FilePath $LogFile -Append | Out-Null
        RefreshPath
    }
    if (-not (Has "git")) {
        ERR "git install failed. Install manually: https://git-scm.com/download/win"
        exit 1
    }
}
OK "git $((git --version 2>&1))"

# -- node / npm --
$script:HasNode = Has "node"
$script:HasNpm  = Has "npm"

if (-not $script:HasNode) {
    if ($SkipAutoInstall) {
        WAR "node not found - Node plugins will be skipped"
    } else {
        WAR "node not found - installing Node.js LTS via winget..."
        if (Has "winget") {
            winget install --id OpenJS.NodeJS.LTS --silent --accept-package-agreements --accept-source-agreements 2>&1 |
                Tee-Object -FilePath $LogFile -Append | Out-Null
            RefreshPath
        }
        $script:HasNode = Has "node"
        $script:HasNpm  = Has "npm"
        if ($script:HasNode) {
            OK "Node.js installed"
        } else {
            WAR "Node.js install failed - Node plugins will be skipped"
            WAR "Install manually: https://nodejs.org/en/download"
        }
    }
}

if ($script:HasNode) {
    $nv = (node -e "process.stdout.write(process.versions.node)" 2>$null)
    $nm = 0
    try { $nm = [int]($nv.Split('.')[0]) } catch {}
    OK "node $nv"
    if ($nm -lt 18) {
        WAR "Node $nv is below v18 - some plugin features may not work"
        WAR "Upgrade: winget install OpenJS.NodeJS.LTS --force"
    }
    if ($script:HasNpm) { OK "npm $((npm -v 2>$null))" }
}

# -- python --
$script:PythonCmd = ""
if (Has "python") {
    $ptest = (python --version 2>&1 | Out-String)
    if ($ptest -match "Python [0-9]") { $script:PythonCmd = "python" }
}
if ((-not $script:PythonCmd) -and (Has "python3")) {
    $script:PythonCmd = "python3"
}
$script:HasPy = ($script:PythonCmd -ne "")

if (-not $script:HasPy) {
    if ($SkipAutoInstall) {
        WAR "python not found - Python plugins will be skipped"
    } else {
        WAR "python not found - installing Python 3.12 via winget..."
        if (Has "winget") {
            winget install --id Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements 2>&1 |
                Tee-Object -FilePath $LogFile -Append | Out-Null
            RefreshPath
        }
        if (Has "python") { $script:PythonCmd = "python"; $script:HasPy = $true }
        if ($script:HasPy) {
            OK "Python installed"
        } else {
            WAR "Python install failed - Python plugins will be skipped"
            WAR "Install manually: https://www.python.org/downloads"
        }
    }
}

if ($script:HasPy) {
    OK "$((& $script:PythonCmd --version 2>&1 | Out-String).Trim()) (cmd: $script:PythonCmd)"
    # Bootstrap pip if missing
    $pipCheck = (& $script:PythonCmd -m pip --version 2>&1 | Out-String)
    if ($pipCheck -notmatch "pip") {
        INF "pip not found - bootstrapping..."
        & $script:PythonCmd -m ensurepip --upgrade 2>&1 | Tee-Object -FilePath $LogFile -Append | Out-Null
        & $script:PythonCmd -m pip install --upgrade pip -q 2>&1 | Tee-Object -FilePath $LogFile -Append | Out-Null
    }
    OK "pip ready"
}

# ── STEP 2: Helper Functions ──────────────────────────────────────

function DetectType {
    param($dir)
    if (Test-Path "$dir\package.json") { return "node" }
    $isPy = ((Test-Path "$dir\pyproject.toml") -or (Test-Path "$dir\setup.py") -or (Test-Path "$dir\requirements.txt"))
    if ($isPy) { return "python" }
    return "unknown"
}

function DetectEntrypoint {
    param($dir, $ptype)
    $ep = ""

    if ($ptype -eq "node") {
        if ($script:HasNode -and (Test-Path "$dir\package.json")) {
            $safe = $dir.Replace("\","/")
            $ep = (node -e "try{var p=require('$safe/package.json');var b=p.bin;var e=b?Object.values(b)[0]:(p.main||'');process.stdout.write(e);}catch(e){process.stdout.write('');}" 2>$null)
        }
        if ($ep -and (-not [System.IO.Path]::IsPathRooted($ep))) {
            $ep = Join-Path $dir $ep
        }
        if ((-not $ep) -or (-not (Test-Path $ep))) {
            $ep = ""
            $candidates = "index.js","server.js","src\index.js","dist\index.js","cli.js","bin\index.js"
            foreach ($f in $candidates) {
                if (Test-Path "$dir\$f") { $ep = "$dir\$f"; break }
            }
        }
    }

    if ($ptype -eq "python") {
        $candidates = "server.py","main.py","src\server.py","__main__.py","app.py","cli.py"
        foreach ($f in $candidates) {
            if (Test-Path "$dir\$f") { $ep = "$dir\$f"; break }
        }
    }

    return $ep
}

function CloneOrUpdate {
    param($name, $url, $dir)
    if (Test-Path "$dir\.git") {
        INF "Updating $name..."
        git -C $dir fetch --quiet origin 2>&1 | Tee-Object -FilePath $LogFile -Append | Out-Null
        git -C $dir reset --hard origin/HEAD --quiet 2>&1 | Tee-Object -FilePath $LogFile -Append | Out-Null
        OK "Updated $name"
    } else {
        INF "Cloning $name..."
        $out = (git clone --depth 1 --quiet $url $dir 2>&1)
        WL ($out | Out-String)
        if ($LASTEXITCODE -ne 0) {
            ERR "Clone failed for $name"
            $out | Select-Object -Last 5 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkRed }
            return $false
        }
        OK "Cloned $name"
    }
    return $true
}

function InstallNodeDeps {
    param($dir)
    if (-not $script:HasNpm) { WAR "npm not available - skipping"; return $false }

    Push-Location $dir

    # Attempt 1: normal
    INF "npm install - attempt 1 of 4 (normal)..."
    RunNpm @("install","--no-audit","--no-fund") | Out-Null
    if ($LASTEXITCODE -eq 0) { Pop-Location; OK "npm deps ready"; return $true }

    # Attempt 2: legacy peer deps
    INF "npm install - attempt 2 of 4 (legacy-peer-deps)..."
    RunNpm @("install","--no-audit","--no-fund","--legacy-peer-deps") | Out-Null
    if ($LASTEXITCODE -eq 0) { Pop-Location; OK "npm deps ready"; return $true }

    # Attempt 3: force (fixes ETARGET / pinned version errors)
    INF "npm install - attempt 3 of 4 (force)..."
    RunNpm @("install","--no-audit","--no-fund","--force") | Out-Null
    if ($LASTEXITCODE -eq 0) { Pop-Location; OK "npm deps ready"; return $true }

    # Attempt 4: delete lock file then clean install
    INF "npm install - attempt 4 of 4 (clean slate)..."
    if (Test-Path "package-lock.json") { Remove-Item "package-lock.json" -Force }
    if (Test-Path "node_modules")      { Remove-Item "node_modules" -Recurse -Force -ErrorAction SilentlyContinue }
    $lastOut = RunNpm @("install","--no-audit","--no-fund","--legacy-peer-deps")
    if ($LASTEXITCODE -eq 0) { Pop-Location; OK "npm deps ready"; return $true }

    Pop-Location
    ERR "npm install failed after 4 attempts. Last output:"
    $lastOut | Select-Object -Last 15 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkRed }
    WAR "Full log: $LogFile"
    return $false
}

function InstallPythonDeps {
    param($dir)
    if (-not $script:HasPy) { WAR "python not available - skipping"; return $false }

    # Upgrade pip first
    & $script:PythonCmd -m pip install --upgrade pip -q 2>&1 | Tee-Object -FilePath $LogFile -Append | Out-Null

    if (Test-Path "$dir\requirements.txt") {
        INF "pip install requirements.txt - attempt 1..."
        RunPip @("install","-r","$dir\requirements.txt","-q") | Out-Null
        if ($LASTEXITCODE -eq 0) { OK "pip deps ready"; return $true }

        INF "pip install requirements.txt - attempt 2 (no-deps)..."
        RunPip @("install","-r","$dir\requirements.txt","--no-deps","-q") | Out-Null
        if ($LASTEXITCODE -eq 0) { OK "pip deps ready"; return $true }

        ERR "pip requirements install failed"
        return $false
    }

    if ((Test-Path "$dir\pyproject.toml") -or (Test-Path "$dir\setup.py")) {
        INF "pip install editable - attempt 1..."
        RunPip @("install","-e",$dir,"-q") | Out-Null
        if ($LASTEXITCODE -eq 0) { OK "pip deps ready"; return $true }

        INF "pip install editable - attempt 2 (no-build-isolation)..."
        RunPip @("install","-e",$dir,"--no-build-isolation","-q") | Out-Null
        if ($LASTEXITCODE -eq 0) { OK "pip deps ready"; return $true }

        INF "pip install editable - attempt 3 (no-build-isolation no-deps)..."
        $lastOut = RunPip @("install","-e",$dir,"--no-build-isolation","--no-deps","-q")
        if ($LASTEXITCODE -eq 0) { OK "pip deps ready"; return $true }

        ERR "pip install failed after 3 attempts"
        $lastOut | Select-Object -Last 10 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkRed }
        return $false
    }

    OK "No dependency file found - nothing to install"
    return $true
}

function LinkSkill {
    param($name, $src)
    if (-not (Test-Path $SkillsDir)) { New-Item -ItemType Directory -Path $SkillsDir -Force | Out-Null }
    $target = "$SkillsDir\$name"
    if (Test-Path $target) { INF "Skill already linked: $name"; return }
    $out = (cmd /c "mklink /J `"$target`" `"$src`"" 2>&1)
    WL $out
    if (Test-Path $target) { OK "Skill linked: $name" }
    else { WAR "Could not link skill - copy manually: $src to $target" }
}

function RegisterMCP {
    param($name, $runner, $entry)
    $configDir = Split-Path $ConfigFile
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }

    if (-not (Test-Path $ConfigFile)) {
        Set-Content -Path $ConfigFile -Value '{"mcpServers":{}}' -Encoding UTF8
        INF "Created config: $ConfigFile"
    }

    Copy-Item $ConfigFile "$ConfigFile.bak" -Force -ErrorAction SilentlyContinue

    $raw = Get-Content $ConfigFile -Raw -ErrorAction SilentlyContinue
    if (-not $raw) { $raw = '{"mcpServers":{}}' }
    $cfg = $raw | ConvertFrom-Json

    if ($null -eq $cfg.mcpServers) {
        $cfg | Add-Member -NotePropertyName "mcpServers" -NotePropertyValue (New-Object PSObject) -Force
    }

    $existing = $cfg.mcpServers.PSObject.Properties.Item($name)
    if ($null -ne $existing) {
        if ($existing.Value.command -eq $runner -and $existing.Value.args[0] -eq $entry) {
            INF "MCP already registered: $name"
            return
        }
    }

    $newEntry = New-Object PSObject -Property @{ command = $runner; args = @($entry) }
    $cfg.mcpServers | Add-Member -NotePropertyName $name -NotePropertyValue $newEntry -Force
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigFile -Encoding UTF8
    OK "MCP registered: $name"
}

function GenerateClaudeMd {
    param($dir, $name, $ptype, $entry)
    $md = "$dir\CLAUDE.md"
    if (Test-Path $md) { INF "CLAUDE.md exists for $name - skipping"; return }

    $leaf = ""
    if ($entry) { $leaf = Split-Path $entry -Leaf }

    $lines = @("# $name", "type: $ptype | entry: $leaf")

    $cmdDir = ""
    if (Test-Path "$dir\commands")         { $cmdDir = "$dir\commands" }
    if (Test-Path "$dir\.claude\commands") { $cmdDir = "$dir\.claude\commands" }
    if ($cmdDir) {
        $cmds = Get-ChildItem $cmdDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq ".md" -or $_.Extension -eq ".sh" } |
                ForEach-Object { $_.BaseName } | Sort-Object
        if ($cmds) { $lines += "commands: " + ($cmds -join " ") }
    }

    $lines | Set-Content -Path $md -Encoding UTF8
    OK "CLAUDE.md generated for $name"
}

function ScopeToProject {
    param($project)
    if (-not $project) { return }
    if (-not (Test-Path $project)) { WAR "Project dir not found: $project - skipping"; return }

    $settingsFile = "$project\.claude\settings.json"
    $settingsDir  = Split-Path $settingsFile
    if (-not (Test-Path $settingsDir)) { New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null }

    $cfg = New-Object PSObject
    if (Test-Path $settingsFile) {
        $raw = Get-Content $settingsFile -Raw -ErrorAction SilentlyContinue
        if ($raw) { $cfg = $raw | ConvertFrom-Json }
    }

    $pp = $cfg.PSObject.Properties.Item("plugins")
    if ($null -eq $pp) {
        $cfg | Add-Member -NotePropertyName "plugins" -NotePropertyValue @() -Force
    }

    if ($cfg.plugins -notcontains "superpowers@claude-plugins-official") {
        $cfg.plugins = @($cfg.plugins) + @("superpowers@claude-plugins-official")
    }

    $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsFile -Encoding UTF8
    OK "Superpowers scoped to: $project"
}

# ── STEP 3: Install Plugins ───────────────────────────────────────
SEC "Installing Plugins"

if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

$Results = [ordered]@{}

foreach ($plugin in $Plugins) {
    $name  = $plugin.name
    $repo  = $plugin.repo
    $ptype = $plugin.ptype
    $scope = $plugin.scope
    $dir   = "$InstallDir\$name"

    Write-Host "`n  [$name]" -ForegroundColor White

    # 1. Clone or update
    $ok = CloneOrUpdate $name $repo $dir
    if (-not $ok) { $Results[$name] = "FAILED - clone error"; continue }

    # 2. Detect type if auto
    if ($ptype -eq "auto") { $ptype = DetectType $dir }
    INF "type: $ptype | scope: $scope"

    # 3. Install dependencies
    $depsOk = $true
    if      ($ptype -eq "node")   { $depsOk = InstallNodeDeps   $dir }
    elseif  ($ptype -eq "python") { $depsOk = InstallPythonDeps $dir }
    else    { WAR "Unknown project type - cloned only, check $dir manually" }

    if (-not $depsOk) { $Results[$name] = "FAILED - deps error"; continue }

    # 4. Link as global skill
    if ($scope -eq "global") { LinkSkill $name $dir }

    # 5. Detect entrypoint and register MCP
    $ep = DetectEntrypoint $dir $ptype
    if ($ep) {
        $runner = "node"
        if ($ptype -eq "python") { $runner = $script:PythonCmd }
        RegisterMCP $name $runner $ep
        OK "MCP ready: $name -> $(Split-Path $ep -Leaf)"
        $Results[$name] = "INSTALLED"
    } else {
        WAR "No entrypoint found - MCP not registered (slash commands still work via skill link)"
        $Results[$name] = "PARTIAL - no entrypoint"
    }

    # 6. Generate CLAUDE.md
    $epVal = ""
    if ($ep) { $epVal = $ep }
    GenerateClaudeMd $dir $name $ptype $epVal
}

# ── STEP 4: Scope superpowers ─────────────────────────────────────
if ($TargetProject) {
    SEC "Scoping Superpowers"
    ScopeToProject $TargetProject
}

# ── STEP 5: Summary ───────────────────────────────────────────────
SEC "Summary"
Write-Host ""

$allOk = $true
foreach ($key in $Results.Keys) {
    $val  = $Results[$key]
    $icon = "[!]"
    $col  = "Yellow"
    if ($val -eq "INSTALLED")           { $icon = "[+]"; $col = "Green" }
    if ($val.StartsWith("FAILED"))      { $icon = "[x]"; $col = "Red"; $allOk = $false }
    Write-Host ("  {0}  {1,-14}  {2}" -f $icon, $key, $val) -ForegroundColor $col
}

Write-Host ""
Write-Host "  Plugins : $InstallDir"  -ForegroundColor Cyan
Write-Host "  Skills  : $SkillsDir"   -ForegroundColor Cyan
Write-Host "  Config  : $ConfigFile"  -ForegroundColor Cyan
Write-Host "  Log     : $LogFile"     -ForegroundColor Cyan
Write-Host ""

if ($allOk) {
    Write-Host "  All done! Restart Claude Desktop or Claude Code to activate." -ForegroundColor Green
} else {
    Write-Host "  Some plugins failed. Open the log for details:" -ForegroundColor Red
    Write-Host "  notepad $LogFile" -ForegroundColor Yellow
}

if (-not $TargetProject) {
    Write-Host ""
    Write-Host "  Tip: to scope superpowers to your project run:" -ForegroundColor Yellow
    Write-Host "  .\install_claude_plugins.ps1 -TargetProject `"C:\path\to\project`"" -ForegroundColor Cyan
}
