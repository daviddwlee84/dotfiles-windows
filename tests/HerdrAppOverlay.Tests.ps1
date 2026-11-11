#Requires -Version 7.4
#Requires -PSEdition Core
BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'scripts/herdr-app-json-merge.ps1')
    $script:KeysOverlay = Get-Content -Raw (Join-Path $script:Root '.chezmoitemplates/herdr-app/keys.json')
    $script:SettingsOverlay = Get-Content -Raw (Join-Path $script:Root '.chezmoitemplates/herdr-app/settings.json')
    function Invoke-Merge([string]$Text, [string]$Overlay) {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
        [System.Text.UTF8Encoding]::new($false).GetString((Get-HerdrAppMergedJson -InputBytes $bytes -OverlayJson $Overlay))
    }
}

Describe 'Herdr App modify_ overlay merge' {
    It 'leaves an empty or whitespace-only live file empty' {
        Invoke-Merge '' $script:KeysOverlay | Should -BeExactly ''
        Invoke-Merge " `n" $script:SettingsOverlay | Should -BeExactly ''
    }

    It 'adds the tmux-prefix bindings and keeps every other key' {
        $out = Invoke-Merge '{"global":{"cmd-q":"app.quit","ctrl-b":"old"},"pane":{"x":"y"}}' $script:KeysOverlay | ConvertFrom-Json
        $out.global.'cmd-q' | Should -Be 'app.quit'
        $out.global.'ctrl-b' | Should -Be 'mod.open:tmux-prefix'
        $out.terminal.'ctrl-b' | Should -Be 'mod.open:tmux-prefix'
        $out.'mod:tmux-prefix'.'ctrl-b' | Should -Be 'tmux-prefix.send-prefix'
        $out.pane.x | Should -Be 'y'
    }

    It 'enforces managed settings and preserves app-owned ones' {
        $out = Invoke-Merge '{"zoom":1.5,"appearance":"light","sounds":{"enabled":false}}' $script:SettingsOverlay | ConvertFrom-Json
        $out.zoom | Should -Be 1.5
        $out.appearance | Should -Be 'dark'
        $out.sounds.enabled | Should -BeFalse
    }

    It 'keeps terminal control-character escapes as JSON escapes' {
        $out = Invoke-Merge '{"terminal":{"alt-left":"send:\u001bb"}}' $script:KeysOverlay
        $out | Should -Match ([regex]::Escape('"send:\u001bb"'))
    }

    It 'is idempotent' {
        $once = Invoke-Merge '{"global":{"a":"b"}}' $script:KeysOverlay
        Invoke-Merge $once $script:KeysOverlay | Should -BeExactly $once
    }

    It 'passes invalid JSON through untouched' {
        Invoke-Merge '{broken' $script:KeysOverlay 2>$null | Should -BeExactly '{broken'
    }

    It 'shares the fragment and the vendored mod byte-for-byte with the parent repo layout' {
        foreach ($p in '.chezmoitemplates/herdr-app/keys.json', '.chezmoitemplates/herdr-app/settings.json',
            'dot_config/herdr-app/mods/tmux-prefix/main.js', 'dot_config/herdr-app/mods/tmux-prefix/mod.json') {
            Test-Path -LiteralPath (Join-Path $script:Root $p) | Should -BeTrue
        }
    }
}
