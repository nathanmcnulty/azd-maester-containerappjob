# Requires a real Bicep CLI; CI installs the pinned compiler before Pester.
Describe 'Compiled job trigger contract' {
  BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $bicep = $env:BICEP_CLI_PATH
    if (-not $bicep) { $bicep = (Get-Command bicep -ErrorAction SilentlyContinue).Source }
    if (-not $bicep -or -not (Test-Path -LiteralPath $bicep -PathType Leaf)) { throw 'Set BICEP_CLI_PATH to the Bicep CLI executable.' }
    $compiledPath = Join-Path $TestDrive 'main.json'
    & $bicep build (Join-Path $root 'infra/main.bicep') --outfile $compiledPath
    if ($LASTEXITCODE -ne 0) { throw 'Production Bicep compilation failed.' }
    $compiled = Get-Content $compiledPath -Raw | ConvertFrom-Json -AsHashtable
    $job = @($compiled.resources | Where-Object type -eq 'Microsoft.App/jobs')
    if ($job.Count -ne 1) { throw 'Expected one production job resource.' }
    $job = $job[0]
    $parameters = Get-Content (Join-Path $root 'infra/main.parameters.json') -Raw | ConvertFrom-Json -AsHashtable
  }
  It 'keeps Schedule as the explicit Bicep and azd default and only allows Manual or Schedule' {
    $compiled.parameters.jobTriggerType.defaultValue | Should -BeExactly 'Schedule'
    $compiled.parameters.jobTriggerType.metadata.azd.default | Should -BeExactly 'Schedule'
    ($compiled.parameters.jobTriggerType.allowedValues | Sort-Object) -join ',' | Should -BeExactly 'Manual,Schedule'
    $parameters.parameters.jobTriggerType.value | Should -BeExactly '${JOB_TRIGGER_TYPE=Schedule}'
    Get-Content (Join-Path $root 'azure.yaml') -Raw | Should -Match 'provider: bicep\s+path: infra'
  }
  It 'selects the correct compiled trigger branch from the actual input parameter' {
    # Bind the parameter to both compiled objects, not a source-only text fixture.
    $job.properties.configuration | Should -BeExactly "[union(if(equals(parameters('jobTriggerType'), 'Manual'), variables('manualJobTriggerConfiguration'), variables('scheduledJobTriggerConfiguration')), createObject('replicaRetryLimit', 1, 'replicaTimeout', 3600, 'registries', createArray()))]"
  }
  It 'emits Manual config without any schedule, cron or event keys' {
    $manual = $compiled.variables.manualJobTriggerConfiguration
    ($manual.Keys | Sort-Object) -join ',' | Should -BeExactly 'manualTriggerConfig,triggerType'
    $manual.triggerType | Should -BeExactly 'Manual'
    ($manual.manualTriggerConfig.Keys | Sort-Object) -join ',' | Should -BeExactly 'parallelism,replicaCompletionCount'
    $manual.manualTriggerConfig.parallelism | Should -Be 1
    $manual.manualTriggerConfig.replicaCompletionCount | Should -Be 1
  }
  It 'preserves the exact historical weekly schedule without Manual config' {
    $schedule = $compiled.variables.scheduledJobTriggerConfiguration
    ($schedule.Keys | Sort-Object) -join ',' | Should -BeExactly 'scheduleTriggerConfig,triggerType'
    $schedule.triggerType | Should -BeExactly 'Schedule'
    ($schedule.scheduleTriggerConfig.Keys | Sort-Object) -join ',' | Should -BeExactly 'cronExpression,parallelism,replicaCompletionCount'
    $schedule.scheduleTriggerConfig.cronExpression | Should -BeExactly '0 0 * * 0'
    $schedule.scheduleTriggerConfig.parallelism | Should -Be 1
    $schedule.scheduleTriggerConfig.replicaCompletionCount | Should -Be 1
  }
}
