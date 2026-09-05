#Requires -Version 7.4
#Requires -PSEdition Core
BeforeAll {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $RepoRoot 'scripts' 'herdr-skill-sync.ps1')
    $script:ValidSkill = "---`nname: herdr`ndescription: test`n---`n`n# Herdr`n"

    function New-TestDirectory {
        [CmdletBinding(SupportsShouldProcess)]
        param()

        $path = Join-Path ([IO.Path]::GetTempPath()) ('herdr-skill-' + [guid]::NewGuid().ToString('N'))
        if ($PSCmdlet.ShouldProcess($path, 'Create test directory')) {
            New-Item -ItemType Directory -Force -Path $path | Out-Null
        }
        return $path
    }
}

Describe 'Herdr binary-matched agent skill' {
    It 'writes identical real copies for universal and Claude discovery' {
        $root = New-TestDirectory
        try {
            $destinations = @(
                (Join-Path $root '.agents\skills\herdr\SKILL.md'),
                (Join-Path $root '.claude\skills\herdr\SKILL.md')
            )
            Write-HerdrSkillContent -Content $script:ValidSkill -Destinations $destinations | Should -BeTrue
            foreach ($destination in $destinations) {
                [IO.File]::ReadAllText($destination) | Should -BeExactly $script:ValidSkill
                (Get-Item -LiteralPath $destination).LinkType | Should -BeNullOrEmpty
            }
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not rewrite an already aligned skill' {
        $root = New-TestDirectory
        try {
            $destination = Join-Path $root '.agents\skills\herdr\SKILL.md'
            Write-HerdrSkillContent -Content $script:ValidSkill -Destinations @($destination) | Should -BeTrue
            $oldTime = [DateTimeOffset]::Parse('2020-01-02T03:04:05Z').UtcDateTime
            [IO.File]::SetLastWriteTimeUtc($destination, $oldTime)

            Write-HerdrSkillContent -Content $script:ValidSkill -Destinations @($destination) | Should -BeTrue
            [IO.File]::GetLastWriteTimeUtc($destination) | Should -Be $oldTime
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps the previous copy when output is invalid' {
        $root = New-TestDirectory
        try {
            $destination = Join-Path $root '.agents\skills\herdr\SKILL.md'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            [IO.File]::WriteAllText($destination, 'previous-good-copy')

            Write-HerdrSkillContent -Content 'not a skill' -Destinations @($destination) | Should -BeFalse
            [IO.File]::ReadAllText($destination) | Should -BeExactly 'previous-good-copy'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'gates apply-time synchronization on installHerdr without a removal path' {
        $template = Get-Content -Raw (Join-Path $RepoRoot '.chezmoiscripts' 'run_after_15_sync_herdr_skill.ps1.tmpl')
        $template | Should -Match '\{\{ if \.installHerdr'
        $template | Should -Not -Match 'Remove-Item.+\.agents.+herdr'
        $template | Should -Not -Match 'Remove-Item.+\.claude.+herdr'
    }

    It 'renders synchronization only when installHerdr is enabled' {
        if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'chezmoi is not installed'
            return
        }
        $templatePath = Join-Path $RepoRoot '.chezmoiscripts' 'run_after_15_sync_herdr_skill.ps1.tmpl'
        $enabled = & chezmoi execute-template --source $RepoRoot --override-data '{"installHerdr":true}' --file $templatePath | Out-String
        $disabled = & chezmoi execute-template --source $RepoRoot --override-data '{"installHerdr":false}' --file $templatePath | Out-String

        $enabled | Should -Match 'function Sync-HerdrSkill'
        $enabled | Should -Match '\.agents\\skills\\herdr'
        $disabled | Should -Not -Match 'function Sync-HerdrSkill'
        $disabled | Should -Not -Match '\.agents\\skills\\herdr'
    }
}
