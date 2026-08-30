#Requires -Version 7

$scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $HOME 'scoop' }
$node = Join-Path $scoopRoot 'apps\nodejs-lts\current\node.exe'
$packageRoot = Join-Path $scoopRoot 'persist\nodejs-lts\bin\node_modules\@earendil-works\pi-coding-agent'
$manifest = Join-Path $packageRoot 'package.json'

if ($args.Count -gt 0 -and $args[0] -ceq 'update') {
    $includesSelf = $false
    $hasNonSelfTarget = $false
    if ($args.Count -eq 1) { $includesSelf = $true }
    for ($index = 1; $index -lt $args.Count; $index++) {
        $token = $args[$index]
        if ($token -ceq '--extension') {
            $hasNonSelfTarget = $true
            $index++
        } elseif ($token -ceq '--models' -or $token -ceq '--extensions') {
            $hasNonSelfTarget = $true
        } elseif ($token -ceq '--self' -or $token -ceq '--all') {
            $includesSelf = $true
        } elseif ($token.Length -gt 0 -and -not $token.StartsWith('-')) {
            if ($token -ceq 'self' -or $token -ceq 'pi') { $includesSelf = $true }
            else { $hasNonSelfTarget = $true }
        }
    }
    if (-not $includesSelf -and -not $hasNonSelfTarget) { $includesSelf = $true }
    if ($includesSelf) {
        [Console]::Error.WriteLine(
            'Pi self-update is disabled for this managed install; run: just upgrade-npm-agents'
        )
        exit 2
    }
}

if (-not (Test-Path -LiteralPath $node -PathType Leaf)) {
    [Console]::Error.WriteLine("managed Scoop Node is missing: $node")
    exit 127
}
if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
    [Console]::Error.WriteLine("managed Pi package is missing: $manifest")
    exit 127
}

try {
    $metadata = Get-Content -Raw -LiteralPath $manifest -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $binTarget = if ($metadata.bin -is [string]) { [string] $metadata.bin } else { [string] $metadata.bin.pi }
    if (-not $binTarget) { throw 'package.json has no bin.pi entry' }
    $root = [IO.Path]::GetFullPath($packageRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    $entrypoint = [IO.Path]::GetFullPath((Join-Path $packageRoot $binTarget))
    if (-not $entrypoint.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "bin.pi escapes the managed package directory: $binTarget"
    }
    if (-not (Test-Path -LiteralPath $entrypoint -PathType Leaf)) {
        throw "bin.pi target is missing: $entrypoint"
    }
} catch {
    [Console]::Error.WriteLine("managed Pi package is invalid: $_")
    exit 126
}

& $node $entrypoint @args
exit $LASTEXITCODE
