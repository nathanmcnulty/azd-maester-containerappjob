#Requires -Version 7.6
BeforeAll {
  $root = Split-Path $PSScriptRoot -Parent
  Import-Module (Join-Path $root 'scripts/Maester.ViewerProjection.psm1') -Force
  $tenant = '11111111-1111-1111-1111-111111111111'
  $environment = 'pilot-env'
  $run1 = '22222222-2222-2222-2222-222222222222'
  $run2 = '33333333-3333-3333-3333-333333333333'
  $html1 = [Text.Encoding]::UTF8.GetBytes('<!doctype html><html><body>one</body></html>')
  $html2 = [Text.Encoding]::UTF8.GetBytes('<html><body>two</body></html>')

  function New-TestProjectionStore {
    $state = [pscustomobject]@{
      Items = @{}
      Calls = [Collections.Generic.List[object]]::new()
      Counter = 0
      Before = $null
    }
    $store = {
      param($Operation, $Key, [byte[]]$Bytes, $ContentType, $IfMatch, $IfNoneMatch, $MaximumBytes)
      $state.Calls.Add([pscustomobject]@{ Operation=$Operation; Key=$Key; IfMatch=$IfMatch; IfNoneMatch=$IfNoneMatch; MaximumBytes=$MaximumBytes })
      if ($state.Before) {
        $override = & $state.Before $state $Operation $Key $Bytes $IfMatch $IfNoneMatch
        if ($null -ne $override) { return $override }
      }
      if ($Operation -eq 'Get') {
        if (-not $state.Items.ContainsKey($Key)) { return [pscustomobject]@{ status='missing'; etag=$null; bytes=$null } }
        $item = $state.Items[$Key]
        return [pscustomobject]@{ status='found'; etag=$item.etag; bytes=[byte[]]$item.bytes.Clone() }
      }
      $existing = $state.Items[$Key]
      if (($IfNoneMatch -eq '*' -and $null -ne $existing) -or ($IfMatch -and ($null -eq $existing -or $existing.etag -cne $IfMatch))) {
        return [pscustomobject]@{ status='preconditionFailed'; etag=$null }
      }
      $state.Counter++
      $etag = '"etag-{0}"' -f $state.Counter
      $state.Items[$Key] = [pscustomobject]@{ bytes=[byte[]]$Bytes.Clone(); etag=$etag; contentType=$ContentType }
      return [pscustomobject]@{ status='created'; etag=$etag }
    }.GetNewClosure()
    [pscustomobject]@{ State=$state; Store=$store }
  }

  function Publish-TestProjection($TestStore, $RunId, $Started, $Html=$html1) {
    Publish-MaesterViewerProjection -HtmlBytes $Html -TenantId $tenant -Environment $environment -RunId $RunId `
      -RunStartedAtUtc ([DateTimeOffset]$Started) -Store $TestStore.Store
  }
}

Describe 'Maester viewer projection protocol' {
  It 'publishes and reads one exact verified snapshot through fixed keys' {
    $testStore = New-TestProjectionStore
    $receipt = Publish-TestProjection $testStore $run1 '2026-10-15T20:00:00Z'
    $receipt.published | Should -BeTrue
    $receipt.disposition | Should -BeExactly 'advanced'
    @($receipt.PSObject.Properties.Name) | Should -Be @('published','disposition','tenantId','environment','runId','generation','htmlSha256')
    ($receipt | ConvertTo-Json -Compress) | Should -Not -Match '<html|Bearer|https?://|token'
    @($testStore.State.Items.Keys | Sort-Object) | Should -Be @('latest.json',"runs/$run1/manifest.json","runs/$run1/report.html")
    $snapshot = Read-MaesterViewerProjection -TenantId $tenant -Environment $environment -Store $testStore.Store
    $snapshot.verified | Should -BeTrue
    [Text.Encoding]::UTF8.GetString($snapshot.htmlBytes) | Should -BeExactly ([Text.Encoding]::UTF8.GetString($html1))
    $snapshot.htmlSha256 | Should -BeExactly $receipt.htmlSha256
  }

  It 'orders new, old, and idempotent publications without regressing latest' {
    $testStore = New-TestProjectionStore
    (Publish-TestProjection $testStore $run1 '2026-10-15T20:00:00Z').disposition | Should -BeExactly 'advanced'
    (Publish-TestProjection $testStore $run2 '2026-10-15T20:01:00Z' $html2).disposition | Should -BeExactly 'advanced'
    (Publish-TestProjection $testStore $run1 '2026-10-15T20:00:00Z').disposition | Should -BeExactly 'older'
    (Publish-TestProjection $testStore $run2 '2026-10-15T20:01:00Z' $html2).disposition | Should -BeExactly 'idempotent'
    (Read-MaesterViewerProjection -TenantId $tenant -Environment $environment -Store $testStore.Store).runId | Should -BeExactly $run2
  }

  It 'rejects equal generations for different candidates' {
    $testStore = New-TestProjectionStore
    $null = Publish-TestProjection $testStore $run1 '2026-10-15T20:00:00Z'
    { Publish-TestProjection $testStore $run2 '2026-10-15T20:00:00Z' $html2 } | Should -Throw '*generation collision*'
  }

  It 'verifies immutable bytes after a precondition and rejects collisions' {
    $testStore = New-TestProjectionStore
    $null = Publish-TestProjection $testStore $run1 '2026-10-15T20:00:00Z'
    { Publish-TestProjection $testStore $run1 '2026-10-15T20:00:00Z' $html2 } | Should -Throw '*Immutable projection object collision*'
    (Publish-TestProjection $testStore $run1 '2026-10-15T20:00:00Z').disposition | Should -BeExactly 'idempotent'
  }

  It 'leaves the old pointer when immutable publication is interrupted' {
    $testStore = New-TestProjectionStore
    $null = Publish-TestProjection $testStore $run1 '2026-10-15T20:00:00Z'
    $oldPointer = [byte[]]$testStore.State.Items['latest.json'].bytes.Clone()
    $testStore.State.Before = {
      param($state,$operation,$key)
      if ($operation -eq 'Put' -and $key -eq "runs/$run2/manifest.json") { throw 'injected failure' }
    }
    { Publish-TestProjection $testStore $run2 '2026-10-15T20:01:00Z' $html2 } | Should -Throw '*injected failure*'
    [Convert]::ToHexString($testStore.State.Items['latest.json'].bytes) | Should -BeExactly ([Convert]::ToHexString($oldPointer))
  }

  It 'lets a concurrent newer pointer win a CAS conflict' {
    $candidate = New-TestProjectionStore
    $null = Publish-TestProjection $candidate $run2 '2026-10-15T20:02:00Z' $html2
    $testStore = New-TestProjectionStore
    $null = Publish-TestProjection $testStore $run1 '2026-10-15T20:00:00Z'
    $fired = $false
    $testStore.State.Before = {
      param($state,$operation,$key,$bytes,$ifMatch)
      if (-not $fired -and $operation -eq 'Put' -and $key -eq 'latest.json' -and $ifMatch) {
        $fired = $true
        foreach ($entry in $candidate.State.Items.GetEnumerator()) { $state.Items[$entry.Key] = $entry.Value }
        return [pscustomobject]@{ status='preconditionFailed'; etag=$null }
      }
    }.GetNewClosure()
    $otherRun = '44444444-4444-4444-4444-444444444444'
    (Publish-TestProjection $testStore $otherRun '2026-10-15T20:01:00Z' $html1).disposition | Should -BeExactly 'older'
    (Read-MaesterViewerProjection -TenantId $tenant -Environment $environment -Store $testStore.Store).runId | Should -BeExactly $run2
  }

  It 'retries a pointer change and returns only the newer complete snapshot' {
    $older = New-TestProjectionStore; $newer = New-TestProjectionStore
    $null = Publish-TestProjection $older $run1 '2026-10-15T20:00:00Z'
    $null = Publish-TestProjection $newer $run2 '2026-10-15T20:01:00Z' $html2
    $older.State | Add-Member LatestReads 0
    $older.State.Before = {
      param($state,$operation,$key)
      if ($operation -eq 'Get' -and $key -eq 'latest.json') {
        $state.LatestReads++
        if ($state.LatestReads -eq 2) { foreach ($entry in $newer.State.Items.GetEnumerator()) { $state.Items[$entry.Key] = $entry.Value } }
      }
    }
    $snapshot = Read-MaesterViewerProjection -TenantId $tenant -Environment $environment -Store $older.Store
    $snapshot.runId | Should -BeExactly $run2
    [Text.Encoding]::UTF8.GetString($snapshot.htmlBytes) | Should -BeExactly ([Text.Encoding]::UTF8.GetString($html2))
  }

  It 'bounds a continuously changing snapshot to three attempts and no result' {
    $testStore = New-TestProjectionStore
    $null = Publish-TestProjection $testStore $run1 '2026-10-15T20:00:00Z'
    $testStore.State | Add-Member LatestReads 0
    $testStore.State.Before = {
      param($state,$operation,$key)
      if ($operation -eq 'Get' -and $key -eq 'latest.json') {
        $state.LatestReads++
        if (($state.LatestReads % 2) -eq 0) { $state.Items[$key].etag = '"changed-{0}"' -f $state.LatestReads }
      }
    }
    $before = $testStore.State.Calls.Count
    { Read-MaesterViewerProjection -TenantId $tenant -Environment $environment -Store $testStore.Store } | Should -Throw '*changed during read*'
    ($testStore.State.Calls.Count - $before) | Should -Be 12
  }

  It 'bounds pointer CAS conflicts to three attempts' {
    $testStore = New-TestProjectionStore
    $testStore.State.Before = {
      param($state,$operation,$key)
      if ($operation -eq 'Put' -and $key -eq 'latest.json') { return [pscustomobject]@{ status='preconditionFailed'; etag=$null } }
    }
    { Publish-TestProjection $testStore $run1 '2026-10-15T20:00:00Z' } | Should -Throw '*did not converge*'
    @($testStore.State.Calls | Where-Object { $_.Operation -eq 'Put' -and $_.Key -eq 'latest.json' }).Count | Should -Be 3
  }

  It 'fails closed for forged pointer documents <name>' -ForEach @(
    @{ name='unknown field'; mutate={ param($p) $p | Add-Member extra 'x'; $p } },
    @{ name='foreign tenant'; mutate={ param($p) $p.tenantId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; $p } },
    @{ name='foreign environment'; mutate={ param($p) $p.environment='foreign'; $p } },
    @{ name='foreign run'; mutate={ param($p) $p.runId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; $p } },
    @{ name='path'; mutate={ param($p) $p.manifest.key='../archive/report.html'; $p } },
    @{ name='hash'; mutate={ param($p) $p.manifest.sha256='A'*64; $p } },
    @{ name='length'; mutate={ param($p) $p.manifest.length=1; $p } },
    @{ name='schema'; mutate={ param($p) $p.schemaVersion='2.0'; $p } }
  ) {
    $testStore = New-TestProjectionStore
    $null = Publish-TestProjection $testStore $run1 '2026-10-15T20:00:00Z'
    $pointer = [Text.Encoding]::UTF8.GetString($testStore.State.Items['latest.json'].bytes) | ConvertFrom-Json -DateKind String
    $pointer = & $mutate $pointer
    $testStore.State.Items['latest.json'].bytes = [Text.Encoding]::UTF8.GetBytes(($pointer | ConvertTo-Json -Depth 8 -Compress))
    { Read-MaesterViewerProjection -TenantId $tenant -Environment $environment -Store $testStore.Store } | Should -Throw '*Projection*'
  }

  It 'rejects malformed generations without freezing publication <name>' -ForEach @(
    @{ name='Unicode digits'; value=('٠' * 20) },
    @{ name='outside tick domain'; value='99999999999999999999' }
  ) {
    $testStore = New-TestProjectionStore
    $null = Publish-TestProjection $testStore $run1 '2026-10-15T20:00:00Z'
    $manifestKey = "runs/$run1/manifest.json"
    $manifest = [Text.Encoding]::UTF8.GetString($testStore.State.Items[$manifestKey].bytes) | ConvertFrom-Json -DateKind String
    $manifest.generation = $value
    $manifestBytes = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 8 -Compress))
    $testStore.State.Items[$manifestKey].bytes = $manifestBytes
    $pointer = [Text.Encoding]::UTF8.GetString($testStore.State.Items['latest.json'].bytes) | ConvertFrom-Json -DateKind String
    $pointer.generation = $value
    $pointer.manifest.length = [long]$manifestBytes.Length
    $pointer.manifest.sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($manifestBytes))
    $forgedPointer = [Text.Encoding]::UTF8.GetBytes(($pointer | ConvertTo-Json -Depth 8 -Compress))
    $testStore.State.Items['latest.json'].bytes = $forgedPointer
    { Read-MaesterViewerProjection -TenantId $tenant -Environment $environment -Store $testStore.Store } | Should -Throw '*Projection document is invalid*'
    { Publish-TestProjection $testStore $run2 '2026-10-15T20:01:00Z' $html2 } | Should -Throw '*Projection document is invalid*'
    [Convert]::ToBase64String($testStore.State.Items['latest.json'].bytes) | Should -BeExactly ([Convert]::ToBase64String($forgedPointer))
  }

  It 'rejects a malformed manifest generation after verifying its pointer hash <value>' -ForEach @(
    @{ value=('٠' * 20) },
    @{ value='03155378976000000000' }
  ) {
    $testStore = New-TestProjectionStore
    $null = Publish-TestProjection $testStore $run1 '2026-10-15T20:00:00Z'
    $manifestKey = "runs/$run1/manifest.json"
    $manifest = [Text.Encoding]::UTF8.GetString($testStore.State.Items[$manifestKey].bytes) | ConvertFrom-Json -DateKind String
    $manifest.generation = $value
    $forgedManifest = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 8 -Compress))
    $testStore.State.Items[$manifestKey].bytes = $forgedManifest
    $pointer = [Text.Encoding]::UTF8.GetString($testStore.State.Items['latest.json'].bytes) | ConvertFrom-Json -DateKind String
    $pointer.manifest.length = [long]$forgedManifest.Length
    $pointer.manifest.sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($forgedManifest))
    $testStore.State.Items['latest.json'].bytes = [Text.Encoding]::UTF8.GetBytes(($pointer | ConvertTo-Json -Depth 8 -Compress))
    { Read-MaesterViewerProjection -TenantId $tenant -Environment $environment -Store $testStore.Store } | Should -Throw '*Projection document is invalid*'
  }

  It 'rejects forged manifest identity and HTML bytes' {
    $testStore = New-TestProjectionStore
    $null = Publish-TestProjection $testStore $run1 '2026-10-15T20:00:00Z'
    $manifestKey = "runs/$run1/manifest.json"
    $manifest = [Text.Encoding]::UTF8.GetString($testStore.State.Items[$manifestKey].bytes) | ConvertFrom-Json -DateKind String
    $manifest.environment = 'foreign'
    $forged = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 8 -Compress))
    $testStore.State.Items[$manifestKey].bytes = $forged
    { Read-MaesterViewerProjection -TenantId $tenant -Environment $environment -Store $testStore.Store } | Should -Throw '*manifest*'
    $testStore = New-TestProjectionStore
    $null = Publish-TestProjection $testStore $run1 '2026-10-15T20:00:00Z'
    $testStore.State.Items["runs/$run1/report.html"].bytes = [Text.Encoding]::UTF8.GetBytes('<html>forged</html>')
    { Read-MaesterViewerProjection -TenantId $tenant -Environment $environment -Store $testStore.Store } | Should -Throw '*HTML*'
  }

  It 'rejects invalid input before storage access <name>' -ForEach @(
    @{ name='empty'; html=[byte[]]::new(0); env='pilot-env'; max=20MB },
    @{ name='non HTML'; html=[Text.Encoding]::UTF8.GetBytes('plain text'); env='pilot-env'; max=20MB },
    @{ name='oversized'; html=[Text.Encoding]::UTF8.GetBytes('<html>x</html>'); env='pilot-env'; max=5 },
    @{ name='traversal token'; html=[Text.Encoding]::UTF8.GetBytes('<html>x</html>'); env='../archive'; max=20MB }
  ) {
    $testStore = New-TestProjectionStore
    { Publish-MaesterViewerProjection -HtmlBytes $html -TenantId $tenant -Environment $env -RunId $run1 -RunStartedAtUtc ([DateTimeOffset]'2026-10-15T20:00:00Z') -Store $testStore.Store -MaximumHtmlBytes $max } | Should -Throw
    $testStore.State.Calls.Count | Should -Be 0
  }
}
