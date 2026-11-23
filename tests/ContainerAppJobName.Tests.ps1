# Snapshot evaluates the actual deployment template locally, including the resource name.
Describe 'Compiled Container Apps job name' {
  BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $bicep = $env:BICEP_CLI_PATH
    if (-not $bicep) { $bicep = (Get-Command bicep -ErrorAction Stop).Source }
    $subscription = '00000000-0000-0000-0000-000000000000'
    $group = 'rg-maester-name-test'
    $location = 'eastus2'
    $metadata = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"location":"eastus2","tags":{}}'))
  }

  It 'renders the expected job name for <case> through <template>' -ForEach @(
    @{ case = 'hyphen at the truncation boundary'; template = 'main'; environment = 'maester-caj-test-99'; segment = 'maester-caj' }
    @{ case = 'already valid mixed-case input'; template = 'main'; environment = 'LAB-East-012'; segment = 'lab-east-012' }
    @{ case = 'long alphanumeric prefix'; template = 'main'; environment = 'abcdefghijklmnop'; segment = 'abcdefghijkl' }
    @{ case = 'leading and consecutive hyphens'; template = 'main'; environment = '--Lab---2'; segment = 'lab-2' }
    @{ case = 'unsupported characters'; template = 'resources'; environment = 'lab_2.test'; segment = 'lab-2-test' }
    @{ case = 'no usable characters in the prefix'; template = 'main'; environment = '------------lab'; segment = 'job' }
    @{ case = 'empty input'; template = 'resources'; environment = ''; segment = 'job' }
  ) {
    $source = Join-Path $root "infra/$template.bicep"
    $relative = [IO.Path]::GetRelativePath($TestDrive, $source).Replace('\', '/')
    $parameters = Join-Path $TestDrive 'job-name.bicepparam'
    $content = @(
      "using '$relative'"
      "param location = '$location'"
      "param environmentName = '$environment'"
      "param jobTriggerType = 'Manual'"
    )
    $scope = @()
    if ($template -eq 'main') {
      $content += "param resourceGroupName = '$group'"
      $content += "param resourceGroupMetadataBase64 = '$metadata'"
    } else {
      $scope = @('--resource-group', $group)
    }
    Set-Content -LiteralPath $parameters -Value $content -Encoding utf8
    & $bicep snapshot $parameters --mode overwrite --subscription-id $subscription --location $location @scope
    if ($LASTEXITCODE -ne 0) { throw 'Bicep deployment snapshot failed.' }

    $plan = Get-Content (Join-Path $TestDrive 'job-name.snapshot.json') -Raw | ConvertFrom-Json
    $jobs = @($plan.predictedResources | Where-Object type -eq 'Microsoft.App/jobs')
    $storage = @($plan.predictedResources | Where-Object type -eq 'Microsoft.Storage/storageAccounts')
    $jobs.Count | Should -Be 1
    $storage.Count | Should -Be 1
    $suffix = $storage[0].name.Substring('stmaester'.Length, 6)
    $jobs[0].name | Should -BeExactly "caj-maester-$segment-$suffix"
    $jobs[0].name | Should -MatchExactly '^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$'
    $jobs[0].name.Length | Should -BeGreaterOrEqual 2
    $jobs[0].name.Length | Should -BeLessOrEqual 32
  }
}
