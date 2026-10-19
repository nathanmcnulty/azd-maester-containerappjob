Describe 'Canonical target guard provenance' {
  BeforeAll { $root = Split-Path $PSScriptRoot -Parent }
  It 'pins the reviewed consent migration revision and exact vendored bytes' {
    $lock = Get-Content (Join-Path $root 'azd-components.lock.json') -Raw | ConvertFrom-Json
    $component = $lock.components | Where-Object id -eq 'maester-azd-hooks'
    $component.version | Should -BeExactly '3.0.0'
    $component.sourceRevision | Should -BeExactly '65f6577ce805f2886b1d90198c140fd180e27e4a'
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
