Describe 'Canonical target guard provenance' {
  BeforeAll { $root = Split-Path $PSScriptRoot -Parent }
  It 'pins the reviewed consent migration revision and exact vendored bytes' {
    $lock = Get-Content (Join-Path $root 'azd-components.lock.json') -Raw | ConvertFrom-Json
    $component = $lock.components | Where-Object id -eq 'maester-azd-hooks'
    $component.version | Should -BeExactly '2.1.0'
    $component.sourceRevision | Should -BeExactly '552ade2f0267e6872bd681f9a1d8a67ac72d055b'
    $component.files.Count | Should -Be 10
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
