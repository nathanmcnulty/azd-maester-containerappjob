Describe 'Canonical target guard provenance' {
  BeforeAll { $root = Split-Path $PSScriptRoot -Parent }
  It 'pins the reviewed consent migration revision and exact vendored bytes' {
    $lock = Get-Content (Join-Path $root 'azd-components.lock.json') -Raw | ConvertFrom-Json
    $component = $lock.components | Where-Object id -eq 'maester-azd-hooks'
    $component.version | Should -BeExactly '3.0.1'
    $component.sourceRevision | Should -BeExactly 'b9019c809bcffd2747fdb2f47e455ee9edfe7564'
    $component.files.Count | Should -Be 13
    foreach ($file in $component.files) {
      (Get-FileHash -LiteralPath (Join-Path $root $file.target) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $file.sha256
    }
    $coordinator = @($lock.components | Where-Object id -eq 'graph-delegated-authentication')
    $coordinator.Count | Should -Be 1
    $coordinator[0].version | Should -BeExactly '1.1.0'
    $coordinator[0].sourceRevision | Should -BeExactly '552ade2f0267e6872bd681f9a1d8a67ac72d055b'
    $coordinator[0].files.Count | Should -Be 2
    foreach ($file in $coordinator[0].files) {
      (Get-FileHash -LiteralPath (Join-Path $root $file.target) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $file.sha256
    }
  }
  It 'keeps permission evidence hashes equal to the current source bytes without authorizing grants' {
    $manifest = Get-Content (Join-Path $root 'azd-permissions.json') -Raw | ConvertFrom-Json
    foreach ($requirement in $manifest.requirements) {
      foreach ($evidence in $requirement.evidence) {
        (Get-FileHash -LiteralPath (Join-Path $root $evidence.path) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $evidence.sha256
      }
    }
  }
}

Describe 'Owned cleanup authority stays separately declared' {
  It 'declares conditional operator scopes without changing runtime or self-consent authority' {
    $root = Split-Path $PSScriptRoot -Parent
    $manifest = Get-Content (Join-Path $root 'azd-permissions.json') -Raw | ConvertFrom-Json
    $cleanup = @($manifest.requirements | Where-Object phase -EQ 'cleanup')
    $cleanup.Count | Should -Be 6
    foreach ($entry in $cleanup) {
      $entry.kind | Should -BeExactly 'delegated'
      $entry.principal | Should -BeExactly 'cleanup-operator'
      $entry.defaultEnabled | Should -BeFalse
      $entry.evidence.path | Should -Contain 'scripts/Run-AzdPostDown.ps1'
      $entry.evidence.path | Should -Contain 'scripts/vendor/Azd.MaesterHooks/Maester-PreDownCleanup.psm1'
    }
    $cleanup.permission | Should -Not -Contain 'Directory.AccessAsUser.All'
    $manifest.coverage | Should -BeExactly 'partial'
    ($manifest.gaps -join ' ') | Should -Match 'setup client'
  }
}

Describe 'Consent documentation follows distinct component pins' {
  It 'documents the current hooks version separately from the unchanged coordinator' {
    $root = Split-Path $PSScriptRoot -Parent
    $lock = Get-Content (Join-Path $root 'azd-components.lock.json') -Raw | ConvertFrom-Json
    $hooks = $lock.components | Where-Object id -EQ 'maester-azd-hooks'
    $coordinator = $lock.components | Where-Object id -EQ 'graph-delegated-authentication'
    $documentation = Get-Content (Join-Path $root 'docs/setup-consent-migration.md') -Raw
    $documentation | Should -Match ('hooks ' + [regex]::Escape($hooks.version))
    $documentation | Should -Match ('coordinator (?:remains )?' + [regex]::Escape($coordinator.version))
    $documentation | Should -Match ([regex]::Escape($coordinator.sourceRevision))
    $documentation | Should -Match '\.\./azd-components\.lock\.json'
  }
}
