Describe 'Postprovision validation policy' {
  BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'scripts/Maester-PostProvisionValidation.psm1') -Force
    $hook = Get-Content (Join-Path $root 'scripts/Run-AzdPostProvision.ps1') -Raw
  }

  BeforeEach {
    $script:validationCalls = 0
    $script:lastValidationOptions = $null
    $script:validationAction = {
      param($options)
      $script:validationCalls++
      $script:lastValidationOptions = $options
      [pscustomobject]@{
        ValidationPassed = $true
        ExecutionName = 'offline-execution'
        FinalStatus = 'Succeeded'
        CompletedAt = '2026-11-23T00:00:00Z'
      }
    }
  }

  It 'keeps Manual provision from starting the job by default' {
    $result = Invoke-MaesterPostProvisionValidation -JobTriggerType 'Manual' -ValidationAction $script:validationAction

    $script:validationCalls | Should -Be 0
    $result.ValidationSkipped | Should -BeTrue
    $result.FinalStatus | Should -BeExactly 'NotStarted'
    $result.ExecutionName | Should -BeExactly 'n/a'
    $result.SkipReason | Should -Match 'MAESTER_RUN_POSTPROVISION_VALIDATION'
    $hook | Should -Match 'Invoke-MaesterPostProvisionValidation'
    $hook | Should -Match '\$env:MAESTER_REQUIRE_NO_MAIL'
    $hook | Should -Match '\$testParams\[''RequireNoMail''\]\s*=\s*\$true'
  }

  It 'runs Manual validation only with the explicit opt-in' {
    $result = Invoke-MaesterPostProvisionValidation -JobTriggerType 'Manual' -RunValidation 'true' -ValidationAction $script:validationAction

    $script:validationCalls | Should -Be 1
    $result.ValidationSkipped | Should -BeFalse
    $result.ValidationPassed | Should -BeTrue
    $result.ExecutionName | Should -BeExactly 'offline-execution'
  }

  It 'preserves Schedule postprovision validation and forwards a no-mail request' {
    $result = Invoke-MaesterPostProvisionValidation -JobTriggerType 'Schedule' -RequireNoMail 'true' -ValidationAction $script:validationAction

    $script:validationCalls | Should -Be 1
    $script:lastValidationOptions.RequireNoMail | Should -BeTrue
    $result.ValidationSkipped | Should -BeFalse
  }

  It 'preserves validation failures instead of reporting a successful or skipped run' {
    $failingAction = { param($options) throw 'synthetic-validation-failure' }

    { Invoke-MaesterPostProvisionValidation -JobTriggerType 'Manual' -RunValidation 'true' -ValidationAction $failingAction } | Should -Throw '*synthetic-validation-failure*'
  }

  It 'fails closed for invalid trigger and opt-in values before calling validation' {
    { Invoke-MaesterPostProvisionValidation -JobTriggerType 'Unknown' -RunValidation 'true' -ValidationAction $script:validationAction } | Should -Throw '*expected Manual or Schedule*'
    { Invoke-MaesterPostProvisionValidation -JobTriggerType 'Manual' -RunValidation 'yes' -ValidationAction $script:validationAction } | Should -Throw '*must be*true*false*'
    { Invoke-MaesterPostProvisionValidation -JobTriggerType 'Manual' -RunValidation 'true' -RequireNoMail 'yes' -ValidationAction $script:validationAction } | Should -Throw '*MAESTER_REQUIRE_NO_MAIL*'
    $script:validationCalls | Should -Be 0
  }

  It 'does not start Schedule validation when the no-mail precheck fails' {
    $failingNoMailAction = {
      param($options)
      $script:validationCalls++
      if ($options.RequireNoMail) { throw 'validation.mailMustBeDisabled' }
    }

    { Invoke-MaesterPostProvisionValidation -JobTriggerType 'Schedule' -RequireNoMail 'true' -ValidationAction $failingNoMailAction } | Should -Throw 'validation.mailMustBeDisabled'
    $script:validationCalls | Should -Be 1
  }
}
