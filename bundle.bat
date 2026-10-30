@echo off
rem ==============================================================================
rem Codebase Bundler for AI Analysis (Windows CMD / Batch Wrapper)
rem Splits codebase into atomic volumes <= limit (default 500 KB) without splitting files
rem
rem Usage:
rem   bundle.bat                           (Current directory, 500 KB per volume)
rem   bundle.bat [target_folder]           (Specified directory, 500 KB per volume)
rem   bundle.bat [target_folder] [max_kb]  (Specified directory and custom KB limit)
rem ==============================================================================
setlocal
chcp 65001 >nul
set "SCRIPT_DIR=%~dp0"
set "USER_ARG=%~1"
set "USER_MAX_KB=%~2"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$f=[System.IO.File]::ReadAllText('%~f0',[System.Text.Encoding]::UTF8); $c=$f.Substring($f.LastIndexOf(':::PS_START:::')+15).Trim(); Invoke-Expression $c"
exit /b %ERRORLEVEL%

:::PS_START:::
# ==============================================================================
# PowerShell Engine
# ==============================================================================
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 1. Target Directory and Volume Size Configuration
$target = if ($env:USER_ARG) { $env:USER_ARG } else { $env:SCRIPT_DIR }
if (-not (Test-Path -LiteralPath $target)) {
    Write-Host "[ERROR] Target directory does not exist: $target" -ForegroundColor Red
    exit 1
}
$targetDir = (Resolve-Path -LiteralPath $target).Path.TrimEnd('\')
$projectName = Split-Path -Leaf $targetDir

# Volume size limit (default: 500 KB)
$maxKb = 500
if ($env:USER_MAX_KB) {
    $parsedKb = 0
    if ([int]::TryParse($env:USER_MAX_KB, [ref]$parsedKb) -and $parsedKb -gt 0) {
        $maxKb = $parsedKb
    } else {
        Write-Host "[WARN] Invalid max size '$($env:USER_MAX_KB)'. Defaulting to 500 KB." -ForegroundColor Yellow
    }
}
$maxPartBytes = $maxKb * 1024

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Codebase Bundler for AI Analysis (ProjectGlue)" -ForegroundColor Cyan
Write-Host " Project:   $projectName" -ForegroundColor White
Write-Host " Directory: $targetDir" -ForegroundColor White
Write-Host " Part Max:  $maxKb KB (Atomic file mode: never splits files)" -ForegroundColor White
Write-Host "==========================================================" -ForegroundColor Cyan

# 2. Define Ignore Rules
$ignoredDirNames = @(
    ".git", ".svn", ".hg", ".idea", ".vscode", ".eclipse", ".settings",
    "node_modules", ".next", ".nuxt", ".turbo", "dist", "build", "out", "coverage",
    "target", ".gradle", ".m2", "bin", "obj", "Debug", "Release",
    "venv", ".venv", "env", ".env", "__pycache__", ".pytest_cache", ".mypy_cache", ".tox"
)

$ignoredExtensions = @(
    # Executables & Binaries
    ".exe", ".dll", ".so", ".dylib", ".bin", ".obj", ".o", ".a", ".lib",
    ".class", ".jar", ".war", ".ear",
    ".pyc", ".pyo", ".pyd",
    # Archives
    ".zip", ".tar", ".gz", ".tgz", ".7z", ".rar", ".bz2", ".xz",
    # Media & Images
    ".png", ".jpg", ".jpeg", ".gif", ".ico", ".webp", ".bmp", ".tiff", ".psd", ".ai",
    ".mp3", ".mp4", ".wav", ".ogg", ".flac", ".avi", ".mov", ".wmv", ".mkv", ".webm",
    # Documents & Fonts
    ".pdf", ".docx", ".xlsx", ".pptx", ".doc", ".xls", ".ppt",
    ".woff", ".woff2", ".ttf", ".eot", ".otf",
    # Databases & Heavy Logs
    ".db", ".sqlite", ".sqlite3", ".log",
    ".lock", ".lockb"
)

$ignoredFileNames = @(
    ".env", ".env.local", ".env.development", ".env.production",
    "package-lock.json", "yarn.lock", "poetry.lock", "Cargo.lock", "composer.lock", "pnpm-lock.yaml",
    ".DS_Store", "Thumbs.db", "bundle.bat", "bundle.sh"
)

# Custom .bundleignore
$customIgnore = @()
$bundleIgnorePath = Join-Path $targetDir ".bundleignore"
if (Test-Path -LiteralPath $bundleIgnorePath) {
    Write-Host "[INFO] Loading custom rules from .bundleignore" -ForegroundColor Yellow
    $lines = Get-Content -LiteralPath $bundleIgnorePath -Encoding UTF8
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -and -not $trimmed.StartsWith("#")) {
            $customIgnore += $trimmed
        }
    }
}

# 3. Detect if Binary File (contains null byte)
function Test-IsBinary([string]$path) {
    try {
        $stream = [System.IO.File]::OpenRead($path)
        $buffer = New-Object byte[] 1024
        $read = $stream.Read($buffer, 0, 1024)
        $stream.Close()
        for ($i = 0; $i -lt $read; $i++) {
            if ($buffer[$i] -eq 0) { return $true }
        }
        return $false
    } catch {
        return $true
    }
}

# 4. Check if File is Ignored
function Test-ShouldIgnore([string]$relPath, [string]$fileName, [string]$extension) {
    # Exclude past bundle outputs (e.g. ProjectGlue_part1.txt, ProjectGlue_bundle.txt)
    if ($fileName -match "^$([regex]::Escape($projectName))_(part\d+|bundle.*)\.txt$") { return $true }
    if ($fileName -like "*_part*.txt" -or $fileName -like "*_bundle*.txt" -or $fileName -like "*_part*.md" -or $fileName -like "*_bundle*.md") { return $true }

    # Exclude ignored file names
    foreach ($ignName in $ignoredFileNames) {
        if ($fileName -ieq $ignName) { return $true }
    }

    # Exclude secret keys / certificates
    if ($fileName -like "*.pem" -or $fileName -like "*.key" -or $fileName -like "id_rsa*" -or $fileName -like "*.pfx") {
        return $true
    }

    # Exclude binary extensions
    foreach ($ignExt in $ignoredExtensions) {
        if ($extension -ieq $ignExt) { return $true }
    }

    # Check directory path parts
    $normalizedRel = $relPath -replace '\\', '/'
    $parts = $normalizedRel.Split('/')
    for ($i = 0; $i -lt ($parts.Length - 1); $i++) {
        $part = $parts[$i]
        foreach ($ignDir in $ignoredDirNames) {
            if ($part -ieq $ignDir) { return $true }
        }
    }

    # Check custom ignore patterns
    foreach ($pattern in $customIgnore) {
        if ($normalizedRel -like "*$pattern*" -or $fileName -like $pattern) { return $true }
    }

    return $false
}

# 5. Collect Candidates (Git-aware or Fallback)
Write-Host "[*] Scanning project files..." -ForegroundColor Gray
$candidateRelPaths = [System.Collections.Generic.List[string]]::new()
$isGitRepo = $false

try {
    $null = git -C $targetDir rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -eq 0) { $isGitRepo = $true }
} catch {
    $isGitRepo = $false
}

if ($isGitRepo) {
    Write-Host "[+] Git repository detected: utilizing .gitignore" -ForegroundColor Green
    $gitFiles = git -C $targetDir ls-files -co --exclude-standard
    foreach ($f in $gitFiles) {
        if ($f) {
            [void]$candidateRelPaths.Add(($f -replace '/', '\'))
        }
    }
} else {
    Write-Host "[+] Standard traversal (Git not found or not a git repo)" -ForegroundColor Yellow
    $allFiles = [System.IO.Directory]::EnumerateFiles($targetDir, "*", [System.IO.SearchOption]::AllDirectories)
    foreach ($filePath in $allFiles) {
        $rel = $filePath.Substring($targetDir.Length).TrimStart('\', '/')
        [void]$candidateRelPaths.Add($rel)
    }
}

# 6. Filter Candidates
$includedFiles = [System.Collections.Generic.List[PSCustomObject]]::new()
$skippedCount = 0

foreach ($rel in $candidateRelPaths) {
    $fullPath = Join-Path $targetDir $rel
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }

    $fileName = Split-Path -Leaf $rel
    $extension = [System.IO.Path]::GetExtension($fileName)

    if (Test-ShouldIgnore -relPath $rel -fileName $fileName -extension $extension) {
        $skippedCount++
        continue
    }

    if (Test-IsBinary -path $fullPath) {
        Write-Host "    [SKIP BINARY]  $rel" -ForegroundColor DarkGray
        $skippedCount++
        continue
    }

    $fileInfo = Get-Item -LiteralPath $fullPath
    [void]$includedFiles.Add([PSCustomObject]@{
        RelativePath = ($rel -replace '\\', '/')
        FullPath = $fullPath
        Length = $fileInfo.Length
        Extension = $extension.ToLowerInvariant()
    })
}

# Sort files alphabetically
$includedFiles = [System.Collections.Generic.List[PSCustomObject]]($includedFiles | Sort-Object RelativePath)

Write-Host "[+] Found $($includedFiles.Count) source files (Skipped: $skippedCount non-project/binary/ignored files)" -ForegroundColor Green

if ($includedFiles.Count -eq 0) {
    Write-Host "[WARN] No files matched for bundling. Exiting." -ForegroundColor Yellow
    exit 0
}

# 7. Generate Full ASCII Directory Tree
class TreeNode {
    [string]$Name
    [bool]$IsFile
    [System.Collections.Generic.Dictionary[string, TreeNode]]$Children
    TreeNode([string]$name, [bool]$isFile) {
        $this.Name = $name
        $this.IsFile = $isFile
        $this.Children = [System.Collections.Generic.Dictionary[string, TreeNode]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
}

$treeRoot = [TreeNode]::new($projectName, $false)
foreach ($file in $includedFiles) {
    $parts = $file.RelativePath.Split('/')
    $curr = $treeRoot
    for ($i = 0; $i -lt $parts.Length; $i++) {
        $part = $parts[$i]
        $isFile = ($i -eq ($parts.Length - 1))
        if (-not $curr.Children.ContainsKey($part)) {
            $curr.Children[$part] = [TreeNode]::new($part, $isFile)
        }
        $curr = $curr.Children[$part]
    }
}

function Build-TreeString([TreeNode]$node, [string]$prefix, [bool]$isLast, [System.Text.StringBuilder]$sb) {
    if ($node -ne $treeRoot) {
        $marker = if ($isLast) { "+-- " } else { "|-- " }
        $suffix = if ($node.IsFile) { "" } else { "/" }
        [void]$sb.AppendLine($prefix + $marker + $node.Name + $suffix)
        $prefix += if ($isLast) { "    " } else { "|   " }
    } else {
        [void]$sb.AppendLine($node.Name + "/")
    }
    $childList = @($node.Children.Values)
    for ($i = 0; $i -lt $childList.Count; $i++) {
        Build-TreeString $childList[$i] $prefix ($i -eq ($childList.Count - 1)) $sb
    }
}

$treeSb = [System.Text.StringBuilder]::new()
Build-TreeString $treeRoot "" $true $treeSb
$treeOutput = $treeSb.ToString()

# 8. Syntax Language Resolver
function Get-SyntaxLanguage([string]$ext) {
    switch ($ext) {
        ".java" { return "java" }
        ".py"   { return "python" }
        ".js"   { return "javascript" }
        ".jsx"  { return "javascript" }
        ".ts"   { return "typescript" }
        ".tsx"  { return "typescript" }
        ".html" { return "html" }
        ".htm"  { return "html" }
        ".css"  { return "css" }
        ".scss" { return "scss" }
        ".sass" { return "sass" }
        ".json" { return "json" }
        ".xml"  { return "xml" }
        ".yml"  { return "yaml" }
        ".yaml" { return "yaml" }
        ".sql"  { return "sql" }
        ".sh"   { return "bash" }
        ".bash" { return "bash" }
        ".bat"  { return "batch" }
        ".cmd"  { return "batch" }
        ".ps1"  { return "powershell" }
        ".c"    { return "c" }
        ".h"    { return "c" }
        ".cpp"  { return "cpp" }
        ".hpp"  { return "cpp" }
        ".cs"   { return "csharp" }
        ".go"   { return "go" }
        ".rs"   { return "rust" }
        ".php"  { return "php" }
        ".rb"   { return "ruby" }
        ".kt"   { return "kotlin" }
        ".kts"  { return "kotlin" }
        ".swift"{ return "swift" }
        ".md"   { return "markdown" }
        default { return "text" }
    }
}

# 9. Pre-calculate Part Allocations (Chunk Planning without splitting files)
Write-Host "[*] Planning bundle volumes (Limit: $maxKb KB, Atomic file mode)..." -ForegroundColor Gray

# Estimated base header size (metadata + tree structure + buffer)
$baseHeaderBytes = [System.Text.Encoding]::UTF8.GetByteCount($treeOutput) + 1200

$parts = [System.Collections.Generic.List[System.Collections.Generic.List[PSCustomObject]]]::new()
$currentPart = [System.Collections.Generic.List[PSCustomObject]]::new()
$currentPartBytes = $baseHeaderBytes

foreach ($item in $includedFiles) {
    # Estimated file block size in bundle: content length + tags/header (~350 bytes) + TOC line (~100 bytes)
    $blockBytes = $item.Length + 450

    # If adding this file exceeds limit AND current volume already has files, start a new volume
    if (($currentPartBytes + $blockBytes -gt $maxPartBytes) -and ($currentPart.Count -gt 0)) {
        [void]$parts.Add($currentPart)
        $currentPart = [System.Collections.Generic.List[PSCustomObject]]::new()
        $currentPartBytes = $baseHeaderBytes
    }

    [void]$currentPart.Add($item)
    $currentPartBytes += $blockBytes

    # If this single file was larger than maxPartBytes, isolate it in this volume
    if ($item.Length -gt $maxPartBytes) {
        $fileSizeKb = [math]::Round($item.Length / 1024, 2)
        Write-Host "    [NOTICE] Large file '$($item.RelativePath)' ($fileSizeKb KB > $maxKb KB) allocated to standalone volume." -ForegroundColor Yellow
        [void]$parts.Add($currentPart)
        $currentPart = [System.Collections.Generic.List[PSCustomObject]]::new()
        $currentPartBytes = $baseHeaderBytes
    }
}

if ($currentPart.Count -gt 0) {
    [void]$parts.Add($currentPart)
}

$totalParts = $parts.Count
Write-Host "[+] Codebase grouped into $totalParts volume(s)." -ForegroundColor Green

# 10. Clean up any previous bundle files for this project safely
$oldBundles = Get-ChildItem -LiteralPath $targetDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match "^$([regex]::Escape($projectName))_(part\d+|bundle.*)\.txt$" }

foreach ($oldFile in $oldBundles) {
    Remove-Item -LiteralPath $oldFile.FullName -Force -ErrorAction SilentlyContinue
}

# 11. Write Bundle Volumes
Write-Host "[*] Writing bundle files..." -ForegroundColor Gray

$globalFileIndex = 0
$now = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$createdFiles = [System.Collections.Generic.List[string]]::new()

for ($p = 0; $p -lt $totalParts; $p++) {
    $partNumber = $p + 1
    $partFiles = $parts[$p]
    $partFileName = "$($projectName)_part$($partNumber).txt"
    $partFilePath = Join-Path $targetDir $partFileName

    $writer = [System.IO.StreamWriter]::new($partFilePath, $false, [System.Text.Encoding]::UTF8)
    try {
        # Volume Header
        $writer.WriteLine("================================================================================")
        $writer.WriteLine("CODEBASE BUNDLE FOR AI ANALYSIS")
        $writer.WriteLine("Project:     $projectName")
        $writer.WriteLine("Volume:      Part $partNumber of $totalParts")
        $writer.WriteLine("Date:        $now")
        $writer.WriteLine("Files Here:  $($partFiles.Count) in this volume (Total project files: $($includedFiles.Count))")
        $writer.WriteLine("Max Limit:   $maxKb KB per volume (Atomic file mode: files are never split)")
        $writer.WriteLine("================================================================================")
        $writer.WriteLine()

        # 1. Full Directory Structure
        $writer.WriteLine("================================================================================")
        $writer.WriteLine("1. FULL PROJECT DIRECTORY STRUCTURE")
        $writer.WriteLine("================================================================================")
        $writer.WriteLine($treeOutput.TrimEnd())
        $writer.WriteLine()

        # 2. Table of Contents for this Volume
        $writer.WriteLine("================================================================================")
        $writer.WriteLine("2. FILES IN THIS VOLUME (Part $partNumber of $totalParts)")
        $writer.WriteLine("================================================================================")
        for ($i = 0; $i -lt $partFiles.Count; $i++) {
            $f = $partFiles[$i]
            $sizeKb = [math]::Round($f.Length / 1024, 2)
            $writer.WriteLine(("{0,3}. {1} ({2} KB)" -f ($i + 1), $f.RelativePath, $sizeKb))
        }
        $writer.WriteLine()

        # 3. Source Code Files
        $writer.WriteLine("================================================================================")
        $writer.WriteLine("3. SOURCE CODE FILES")
        $writer.WriteLine("================================================================================")
        $writer.WriteLine()

        for ($localIdx = 0; $localIdx -lt $partFiles.Count; $localIdx++) {
            $globalFileIndex++
            $item = $partFiles[$localIdx]
            $lang = Get-SyntaxLanguage $item.Extension
            $fileSizeKb = [math]::Round($item.Length / 1024, 2)

            $writer.WriteLine("================================================================================")
            $writer.WriteLine("FILE [$($localIdx + 1)/$($partFiles.Count) in Part $partNumber | Overall $globalFileIndex/$($includedFiles.Count)]: $($item.RelativePath)")
            $writer.WriteLine("LANGUAGE: $lang | SIZE: $fileSizeKb KB")
            $writer.WriteLine("================================================================================")
            $writer.WriteLine("<file path=`"$($item.RelativePath)`">")

            try {
                $content = [System.IO.File]::ReadAllText($item.FullPath, [System.Text.Encoding]::UTF8)
                $writer.WriteLine($content)
            } catch {
                Write-Host "    [WARN] Failed to read '$($item.RelativePath)': $($_.Exception.Message)" -ForegroundColor Yellow
                $writer.WriteLine("/* [ERROR: Could not read file content: $($_.Exception.Message)] */")
            }

            $writer.WriteLine("</file>")
            $writer.WriteLine()
        }
    } finally {
        $writer.Flush()
        $writer.Close()
    }

    $actualKb = [math]::Round((Get-Item -LiteralPath $partFilePath).Length / 1024, 2)
    [void]$createdFiles.Add("$partFileName ($actualKb KB)")
}

Write-Host ""
Write-Host "[SUCCESS] Bundle creation finished successfully!" -ForegroundColor Green
Write-Host "Generated $($createdFiles.Count) volume(s):" -ForegroundColor Cyan
foreach ($cf in $createdFiles) {
    Write-Host "  -> $cf" -ForegroundColor White
}
Write-Host "All files were included atomically without splitting." -ForegroundColor Gray
Write-Host "Ready to feed into LLM (Gemini, Claude, GPT, DeepSeek, etc.)" -ForegroundColor Gray
