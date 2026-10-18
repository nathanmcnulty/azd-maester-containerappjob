#Requires -Version 7.6

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../scripts/Maester.DriftRun.psm1') -Force
    $script:suite = Join-Path $TestDrive 'MT1060Drift.tests.ps1'
    'synthetic suite path' | Set-Content -LiteralPath $script:suite

    function New-SyntheticResult {
        param([string]$Result3 = 'Passed', [string]$Result4 = 'Failed', [string]$File = $script:suite)
        [pscustomobject]@{
            Tests = @(
                [pscustomobject]@{ Id='MT1060.case-1.1'; ScriptBlockFile=$File; Result='Passed' }
                [pscustomobject]@{ Id='MT1060.case-1.2'; ScriptBlockFile=$File; Result='Passed' }
                [pscustomobject]@{ Id='MT1060.case-1.3'; ScriptBlockFile=$File; Result=$Result3 }
                [pscustomobject]@{ Id='MT1060.case-1.4'; ScriptBlockFile=$File; Result=$Result4 }
                [pscustomobject]@{ Id='ORDINARY.1'; ScriptBlockFile='ordinary.Tests.ps1'; Result='Failed' }
            )
        }
    }

    function New-JunitFile {
        param([string]$Path, [int]$Errors = 0)
        [IO.File]::WriteAllText($Path, ('<testsuites name="MaesterApprovedDrift" errors="{0}" />' -f $Errors))
    }

    $runnerPath = Join-Path $PSScriptRoot '../scripts/Invoke-MaesterContainerJob.ps1'
    $source = [IO.File]::ReadAllText($runnerPath)
    $start = $source.IndexOf('Write-Output "Running Invoke-Maester')
    $end = $source.IndexOf("Write-Output 'Invoke-Maester execution completed.'", $start)
    $script:invokeBlock = [scriptblock]::Create($source.Substring($start, $end-$start))
    $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$null, [ref]$null)
    $options = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-ApprovedDriftCliOptions'}, $true)
    . ([scriptblock]::Create($options.Extent.Text))
    $cleanup = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Remove-ApprovedDriftRunRoot'}, $true)
    . ([scriptblock]::Create($cleanup.Extent.Text))
    $outer = $ast.Find({param($node) $node -is [Management.Automation.Language.TryStatementAst] -and $null -ne $node.Finally -and $node.Finally.Extent.Text.Contains('Remove-ApprovedDriftRunRoot')}, $true)
    if ($null -eq $outer) { throw 'Runner outer lifecycle finally missing.' }
    $script:cleanupBlock = [scriptblock]::Create('$approvedDriftPrimaryFailure=$null; try { & $operation } ' + ($outer.CatchClauses.Extent.Text -join "`n") + ' finally ' + $outer.Finally.Extent.Text)
}

Describe 'Approved drift run boundary' {
    It 'accepts complete drift accounting while retaining ordinary findings' {
        $junit = Join-Path $TestDrive 'results.xml'
        New-JunitFile $junit
        $receipt = [pscustomobject]@{ CaseCount=1; CaseIds=@('case-1') }
        $result = Assert-MaesterDriftResults -MaesterResult (New-SyntheticResult) -Receipt $receipt -SuitePath $script:suite -JunitPath $junit
        @($result.Tests | Where-Object Id -eq 'ORDINARY.1').Count | Should -Be 1
    }

    It 'rejects JUnit container errors, extra IDs, and wrong suite files' {
        $receipt = [pscustomobject]@{ CaseCount=1; CaseIds=@('case-1') }
        $junit = Join-Path $TestDrive 'results.xml'
        New-JunitFile $junit -Errors 1
        { Assert-MaesterDriftResults -MaesterResult (New-SyntheticResult) -Receipt $receipt -SuitePath $script:suite -JunitPath $junit } | Should -Throw '*drift.junitErrors*'
        New-JunitFile $junit
        $extra = New-SyntheticResult
        $extra.Tests = @($extra.Tests | Where-Object Id -ne 'MT1060.case-1.4') + [pscustomobject]@{Id='MT1060.case-1.5';ScriptBlockFile=$script:suite;Result='Passed'}
        { Assert-MaesterDriftResults -MaesterResult $extra -Receipt $receipt -SuitePath $script:suite -JunitPath $junit } | Should -Throw '*drift.resultAccounting*'
        $wrong = New-SyntheticResult -File (Join-Path $TestDrive 'other.Tests.ps1')
        { Assert-MaesterDriftResults -MaesterResult $wrong -Receipt $receipt -SuitePath $script:suite -JunitPath $junit } | Should -Throw '*drift.resultAccounting*'
    }

    It 'rejects invalid drift accounting: <variant>' -ForEach @(
        @{variant='missing'}, @{variant='duplicate'}, @{variant='skipped'},
        @{variant='error'}, @{variant='invalid-input'}, @{variant='lookalike-result'}
    ) {
        $receipt = [pscustomobject]@{ CaseCount=1; CaseIds=@('case-1') }
        $junit = Join-Path $TestDrive 'results-structural.xml'
        New-JunitFile $junit
        $candidate = New-SyntheticResult
        switch ($variant) {
            missing { $candidate.Tests = @($candidate.Tests | Where-Object Id -ne 'MT1060.case-1.4') }
            duplicate { $candidate.Tests += $candidate.Tests[3] }
            skipped { $candidate.Tests[2].Result = 'Skipped' }
            error { $candidate.Tests[2].Result = 'Error' }
            invalid-input { $candidate.Tests[0].Result = 'Failed' }
            lookalike-result { $candidate.Tests[2].Result = "Pass$([char]0xAD)ed" }
        }
        { Assert-MaesterDriftResults -MaesterResult $candidate -Receipt $receipt -SuitePath $script:suite -JunitPath $junit } | Should -Throw '*drift.resultAccounting*'
    }

    It 'rejects missing or unsafe JUnit instead of accepting the Maester summary' {
        $receipt = [pscustomobject]@{CaseCount=1;CaseIds=@('case-1')}
        $path = Join-Path $TestDrive 'unsafe.xml'
        { Assert-MaesterDriftResults -MaesterResult (New-SyntheticResult) -Receipt $receipt -SuitePath $script:suite -JunitPath $path } | Should -Throw '*drift.junitMissing*'
        foreach ($xml in @('<testsuites />', '<testsuites errors="-1" />', '<!DOCTYPE testsuites [<!ENTITY x "0">]><testsuites errors="&x;" />')) {
            [IO.File]::WriteAllText($path,$xml)
            { Assert-MaesterDriftResults -MaesterResult (New-SyntheticResult) -Receipt $receipt -SuitePath $script:suite -JunitPath $path } | Should -Throw '*drift.junitInvalid*'
        }
    }

    It 'refuses partial opt-ins and unsupported publication before authentication' {
        { Assert-ApprovedDriftCliOptions -Enabled $false -BoundParameters @{DriftInputRoot='incoming'} } | Should -Throw '*drift.optionsRequireEnablement*'
        { Assert-ApprovedDriftCliOptions -Enabled $true -BoundParameters @{} } | Should -Throw '*drift.optionsIncomplete*'
        $optionsArgs = @{Enabled=$true;StorageAccountName='privatefixture';BoundParameters=@{};InputRoot='incoming';ExpectedBaselineManifestSha256=('a'*64);ExpectedTenantId='00000000-0000-0000-0000-000000000001';Environment='fixture';RunId='00000000-0000-0000-0000-000000000002';ProducerId='fixture';ProducerRevision=('b'*40)}
        Assert-ApprovedDriftCliOptions @optionsArgs
        $optionsArgs.StorageAccountName=''
        { Assert-ApprovedDriftCliOptions @optionsArgs } | Should -Throw '*drift.storageDestinationRequired*'
        $optionsArgs.StorageAccountName='privatefixture'
        foreach ($channel in 'MailRecipient','WebAppName') {
            $optionsArgs[$channel]='unsupported'
            { Assert-ApprovedDriftCliOptions @optionsArgs } | Should -Throw '*drift.publishingAudienceUnsupported*'
            $optionsArgs.Remove($channel)
        }
    }

    It 'restores exact ambient state <ambient> when enabled invocation throws: <fails>' -ForEach @(
        @{ambient='absent';fails=$false}, @{ambient='absent';fails=$true},
        @{ambient='empty';fails=$false}, @{ambient='empty';fails=$true},
        @{ambient='inherited';fails=$false}, @{ambient='inherited';fails=$true}
    ) {
        $old = [Environment]::GetEnvironmentVariable('MAESTER_FOLDER_DRIFT','Process')
        try {
            $value = switch ($ambient) { absent {[NullString]::Value}; empty {''}; inherited {'unapproved-root'} }
            [Environment]::SetEnvironmentVariable('MAESTER_FOLDER_DRIFT',$value,'Process')
            $expected = [Environment]::GetEnvironmentVariable('MAESTER_FOLDER_DRIFT','Process')
            $EnableApprovedDrift=$true
            $approvedDriftReceipt=[pscustomobject]@{StageRoot='approved-private-root'}
            $approvedDriftRun=[pscustomobject]@{Root='owned-run';OutputParent='owned-output'}
            $testsPath='locked-tests'; $maesterInvokeParameters=@{}
            function Invoke-MaesterApprovedDrift {
                [Environment]::GetEnvironmentVariable('MAESTER_FOLDER_DRIFT','Process') | Should -BeExactly 'approved-private-root'
                if ($fails) { throw 'synthetic invocation error' }
            }
            if ($fails) { { & $script:invokeBlock } | Should -Throw '*drift.runFailed*' }
            else { & $script:invokeBlock | Out-Null }
            $actual = [Environment]::GetEnvironmentVariable('MAESTER_FOLDER_DRIFT','Process')
            ($null -eq $actual) | Should -Be ($null -eq $expected)
            $actual | Should -BeExactly $expected
        }
        finally {
            [Environment]::SetEnvironmentVariable('MAESTER_FOLDER_DRIFT',$(if ($null -eq $old) {[NullString]::Value} else {$old}),'Process')
        }
    }

    It 'rejects a changed locked suite hash' {
        { Assert-MaesterDriftSuite -SuitePath $script:suite } | Should -Throw '*drift.suiteHashMismatch*'
    }

    It 'creates and removes only its private owned run root' {
        $rootParent = Join-Path $TestDrive 'private'
        New-Item -ItemType Directory -Path $rootParent | Out-Null
        $run = New-MaesterDriftRunRoot
        $other = New-MaesterDriftRunRoot
        $run.Root | Should -Not -BeExactly $other.Root
        'private' | Set-Content (Join-Path $run.OutputParent 'report.json')
        'unrelated' | Set-Content (Join-Path $other.OutputParent 'sentinel.json')
        Remove-DriftOwnedDirectory -Path $run.Root -Parent $run.Parent -LeafPattern ('^' + [regex]::Escape($run.Leaf) + '\z')
        Test-Path -LiteralPath $run.Root | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $other.OutputParent 'sentinel.json') | Should -BeExactly 'unrelated'
        Remove-DriftOwnedDirectory -Path $other.Root -Parent $other.Parent -LeafPattern ('^' + [regex]::Escape($other.Leaf) + '\z')
        Test-Path -LiteralPath $rootParent | Should -BeTrue
    }

    It 'cleans the complete owned run on terminal failure: <fails>' -ForEach @(@{fails=$false},@{fails=$true}) {
        $EnableApprovedDrift=$true
        $approvedDriftRun=New-MaesterDriftRunRoot
        $sentinel=Join-Path $TestDrive 'unrelated-baseline.json'
        'preserved' | Set-Content -LiteralPath $sentinel
        'private values' | Set-Content -LiteralPath (Join-Path $approvedDriftRun.OutputParent 'report.json')
        $operation={ if ($fails) { throw 'synthetic terminal failure' } }
        if ($fails) { { & $script:cleanupBlock } | Should -Throw '*synthetic terminal failure*' }
        else { & $script:cleanupBlock }
        Test-Path -LiteralPath $approvedDriftRun.Root | Should -BeFalse
        Get-Content -LiteralPath $sentinel | Should -BeExactly 'preserved'
    }

    It 'reports cleanup refusal and preserves any primary error: <primaryFailure>' -ForEach @(@{primaryFailure=$false},@{primaryFailure=$true}) {
        $EnableApprovedDrift=$true
        $approvedDriftRun=New-MaesterDriftRunRoot
        Mock -ModuleName Maester.DriftRun Remove-Item { throw 'PLANTED-PRIVATE-DETAIL' }
        $operation={ if ($primaryFailure) { throw 'synthetic publication failure' } }
        $caught=$null
        try { & $script:cleanupBlock } catch { $caught=$_.Exception }
        $caught.Message | Should -BeExactly 'drift.runCleanupFailed'
        $caught.Data['RunRoot'] | Should -BeExactly $approvedDriftRun.Root
        Test-Path -LiteralPath $approvedDriftRun.Root | Should -BeTrue
        if ($primaryFailure) { $caught.Data['PrimaryException'].Message | Should -BeExactly 'synthetic publication failure' }
        else { $caught.Data.Contains('PrimaryException') | Should -BeFalse }
        Mock -ModuleName Maester.DriftRun Remove-Item {param($LiteralPath) Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Recurse -Force -ErrorAction Stop }
        Remove-ApprovedDriftRunRoot
        Test-Path -LiteralPath $approvedDriftRun.Root | Should -BeFalse
    }

    It 'refuses deletion outside the selected run parent' {
        $unrelated=Join-Path $TestDrive 'maester-approved-drift-00000000000000000000000000000001'
        $null=New-Item -ItemType Directory -Path $unrelated
        { Remove-DriftOwnedDirectory -Path $unrelated -Parent (Join-Path $TestDrive 'other') -LeafPattern ('^' + [regex]::Escape([IO.Path]::GetFileName($unrelated)) + '\z') } | Should -Throw '*drift.unsafeCleanupPath*'
        Test-Path -LiteralPath $unrelated | Should -BeTrue
    }

    It 'cleans an exclusively allocated directory when the first normalization fails' {
        InModuleScope Maester.DriftRun { $script:normalizationCalls=0 }
        Mock -ModuleName Maester.DriftRun Get-DriftFullPath {
            param($Path)
            $script:normalizationCalls++
            if ($script:normalizationCalls -eq 1) { throw 'synthetic post-allocation failure' }
            [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Path))
        }
        $caught=$null
        try { New-MaesterDriftRunRoot } catch { $caught=$_.Exception }
        $caught.Message | Should -BeExactly 'drift.privateOutputSetupFailed'
        $caught.Data['SetupException'].Message | Should -BeExactly 'synthetic post-allocation failure'
        $caught.Data['RunRoot'] | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $caught.Data['RunRoot'] | Should -BeFalse
    }
}
