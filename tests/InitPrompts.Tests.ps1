#Requires -Version 7
# Guards hard invariant #1 (AGENTS.md): every init prompt in .chezmoi.toml.tmpl
# must have a matching non-interactive flag in .github/workflows/windows.yml.
#
# Why this exists: adding a prompt without the flag does not fail loudly at
# authoring time — it fails much later, on the Windows runner, as an opaque
#   error calling promptChoiceOnce: EOF
# because `chezmoi init --no-tty` has no answer for the new question and hits
# end-of-input. That broke CI for three consecutive pushes when `agentSounds`
# was added. This test turns that into a local `Invoke-Pester` failure with the
# exact missing flag line to paste in.
#
# Matching is on the prompt's TEXT (3rd arg to promptXOnce), because that is
# what chezmoi's `--promptBool 'text=value'` parser keys on — not the variable
# name.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    $tomlTmpl = Join-Path $repo '.chezmoi.toml.tmpl'
    $workflow = Join-Path $repo '.github/workflows/windows.yml'

    # promptBoolOnce . "varName" "Prompt text" <default>
    $script:Prompts = [regex]::Matches(
        (Get-Content -Raw $tomlTmpl),
        'prompt(?<kind>Bool|String|Choice)Once\s+\.\s+"(?<var>[^"]+)"\s+"(?<text>[^"]+)"'
    ) | ForEach-Object {
        [pscustomobject]@{
            Kind = $_.Groups['kind'].Value
            Var  = $_.Groups['var'].Value
            Text = $_.Groups['text'].Value
        }
    }

    # '--promptBool','Prompt text=value'
    $script:Flags = [regex]::Matches(
        (Get-Content -Raw $workflow),
        "'--prompt(?<kind>Bool|String|Choice)'\s*,\s*'(?<text>[^=']+)="
    ) | ForEach-Object {
        [pscustomobject]@{
            Kind = $_.Groups['kind'].Value
            Text = $_.Groups['text'].Value
        }
    }
}

# NB: no angle brackets in Describe/It names — Pester expands `<...>` in test
# names as a data placeholder, so a name like "prompts <-> flags" is rewritten
# to `$-` and the whole file dies with a bogus CommandNotFoundException.
Describe 'init prompts vs CI flags (invariant #1)' {
    It 'finds prompts in .chezmoi.toml.tmpl' {
        $script:Prompts.Count | Should -BeGreaterThan 10
    }

    It 'finds prompt flags in windows.yml' {
        $script:Flags.Count | Should -BeGreaterThan 10
    }

    It 'has a CI flag for every init prompt' {
        $flagText = @($script:Flags.Text)
        $missing = @($script:Prompts | Where-Object { $flagText -notcontains $_.Text })
        $hint = ($missing | ForEach-Object {
            "            '--prompt$($_.Kind)','$($_.Text)=<value>',   # $($_.Var)"
        }) -join "`n"
        $missing.Count | Should -Be 0 -Because "windows.yml is missing these flags; add to the `$flags array:`n$hint"
    }

    It 'has no stale CI flag without a matching prompt' {
        # Catches the other half of a rename: the prompt text changed but the
        # flag did not. chezmoi silently ignores an unmatched flag and then
        # blocks on the real prompt, so this would otherwise be invisible.
        $promptText = @($script:Prompts.Text)
        $stale = @($script:Flags | Where-Object { $promptText -notcontains $_.Text })
        $stale.Count | Should -Be 0 -Because "these windows.yml flags match no prompt: $($stale.Text -join '; ')"
    }

    It 'uses the right flag kind for each prompt' {
        $byText = @{}
        foreach ($f in $script:Flags) { $byText[$f.Text] = $f.Kind }
        $wrong = @($script:Prompts | Where-Object {
            $byText.ContainsKey($_.Text) -and $byText[$_.Text] -ne $_.Kind
        })
        $wrong.Count | Should -Be 0 -Because "flag kind mismatch for: $($wrong.Var -join '; ')"
    }

    It 'has no "=" in any prompt text' {
        # Invariant #1 corollary: chezmoi's `name=value` parser splits on the
        # FIRST "=", so a prompt whose text contains one can never be answered
        # non-interactively. This already broke the `role` prompt once.
        $bad = @($script:Prompts | Where-Object { $_.Text -match '=' })
        $bad.Count | Should -Be 0 -Because "prompt text may not contain '=': $($bad.Var -join '; ')"
    }

    It 'keeps public package fallback explicit and default-off' {
        $template = Get-Content -Raw $tomlTmpl
        $template | Should -Match 'allowPublicPackageFallback"\s+"Allow one public PyPI/npm retry after eligible corporate feed failures"\s+false'
        @($script:Prompts | Where-Object Var -eq 'allowPublicPackageFallback').Count | Should -Be 1
    }

    It 'describes only package ecosystems with configured China mirrors' {
        $prompt = $script:Prompts | Where-Object Var -eq 'useChineseMirror'
        $prompt.Text | Should -Match 'pip/uv, npm, RubyGems, Go, and rustup'
        $prompt.Text | Should -Not -Match 'Cargo|Node'
    }
}
