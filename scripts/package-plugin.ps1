$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repo 'plugins/script-manager'
$output = Join-Path $repo 'build'
$marketplace = Join-Path $output 'codex-marketplace-windows'
$staging = Join-Path $output ('.codex-marketplace-windows.' + [Guid]::NewGuid().ToString('N'))
$stagedMarketplace = Join-Path $staging 'marketplace'
$stagedPlugin = Join-Path $stagedMarketplace 'plugins/script-manager'
$previous = Join-Path $staging 'previous'
$manifestPath = '.agents/plugins/marketplace.json'

try {
    [IO.Directory]::CreateDirectory($stagedPlugin) | Out-Null
    Copy-Item -LiteralPath (Join-Path $source 'plugin.json') -Destination $stagedPlugin
    foreach ($module in Get-ChildItem -LiteralPath $source -File -Filter '*.py') {
        Copy-Item -LiteralPath $module.FullName -Destination $stagedPlugin
    }
    foreach ($name in 'app', 'assets', 'skills') {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination $stagedPlugin -Recurse
    }

    $mcp = Get-Content -LiteralPath (Join-Path $source 'mcp.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $mcp.mcpServers.'script-manager'.command = 'python'
    $mcpJson = ($mcp | ConvertTo-Json -Depth 10) + "`n"
    [IO.File]::WriteAllText((Join-Path $stagedPlugin 'mcp.json'), $mcpJson, [Text.UTF8Encoding]::new($false))

    $stagedManifest = Join-Path $stagedMarketplace $manifestPath
    [IO.Directory]::CreateDirectory((Split-Path -Parent $stagedManifest)) | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'plugins/marketplace.json') -Destination $stagedManifest

    $existing = Get-Item -LiteralPath $marketplace -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        if (!$existing.PSIsContainer -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            !(Test-Path -LiteralPath (Join-Path $marketplace $manifestPath) -PathType Leaf)) {
            throw "The marketplace path is already in use: $marketplace"
        }
        [IO.Directory]::Move($marketplace, $previous)
    }

    try {
        [IO.Directory]::Move($stagedMarketplace, $marketplace)
    } catch {
        if ([IO.Directory]::Exists($previous)) {
            try {
                [IO.Directory]::Move($previous, $marketplace)
            } catch {
                throw "Could not restore the previous marketplace. It is saved at $previous"
            }
        }
        throw
    }
    if ([IO.Directory]::Exists($previous)) {
        Remove-Item -LiteralPath $previous -Recurse -Force
    }
} finally {
    if ([IO.Directory]::Exists($staging) -and ![IO.Directory]::Exists($previous)) {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
}

Write-Output "Packaged local plugin marketplace at $marketplace"
