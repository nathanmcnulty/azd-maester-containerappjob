Describe 'Canonical target guard provenance' {
  BeforeAll { $root = Split-Path $PSScriptRoot -Parent }
  It 'pins the reviewed pilot revision and exact vendored bytes' {
    $lock = Get-Content (Join-Path $root 'azd-components.lock.json') -Raw | ConvertFrom-Json
    $component = $lock.components | Where-Object id -eq 'maester-azd-hooks'
    $component.version | Should -BeExactly '1.0.0'
    $component.sourceRevision | Should -BeExactly 'fd26f7351f36c569067ae37edcb35d6b6cc40f29'
    $component.files.Count | Should -Be 8
    foreach ($file in $component.files) {
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
