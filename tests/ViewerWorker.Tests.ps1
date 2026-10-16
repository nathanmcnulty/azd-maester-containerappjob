#Requires -Version 7.6
BeforeAll {
    $script:workerRoot = Split-Path $PSScriptRoot -Parent
    $script:workerFixture = Join-Path $PSScriptRoot 'helpers/Invoke-MaesterViewerWorkerFixture.ps1'
    Import-Module (Join-Path $script:workerRoot 'scripts/Maester.ViewerContent.psm1') -Force
    . (Join-Path $PSScriptRoot 'helpers/MaesterViewerTemplateFixture.ps1')
    $script:workerTemplate=Get-MaesterViewerTestTemplateBytes
    $script:oldReportText=[Text.Encoding]::UTF8.GetString((New-MaesterViewerQualifiedTestReport $script:workerTemplate '{"Name":"old-snapshot","EndOfJson":"EndOfJson"}'))
    $script:newReportText=[Text.Encoding]::UTF8.GetString((New-MaesterViewerQualifiedTestReport $script:workerTemplate '{"Name":"new-snapshot","EndOfJson":"EndOfJson"}'))
    function Start-WorkerFixture([string]$Case) {
        $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $probe.Server.ExclusiveAddressUse = $true
        try { $probe.Start(); $port = $probe.LocalEndpoint.Port } finally { $probe.Stop() }
        $ready = Join-Path $TestDrive "$Case-$port.ready"
        $stop = Join-Path $TestDrive "$Case-$port.stop"
        $process = $null
        $client = $null
        $outputTask = $null
        $errorTask = $null
        $returned = $false
        try {
            $info = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $script:workerFixture, '-Case', $Case, '-Root', $script:workerRoot, '-Port', "$port", '-StopPath', $stop, '-ReadyPath', $ready)) {
                $info.ArgumentList.Add($argument)
            }
            $process = [Diagnostics.Process]::Start($info)
            $outputTask = $process.StandardOutput.ReadToEndAsync()
            $errorTask = $process.StandardError.ReadToEndAsync()
            # A cold child compiles the server and qualifies several MiB before listener readiness.
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
            while (-not (Test-Path $ready) -and [DateTimeOffset]::UtcNow -lt $deadline) {
                if ($process.HasExited) {
                    $diagnostic = ($outputTask.GetAwaiter().GetResult() + $errorTask.GetAwaiter().GetResult())
                    if ($diagnostic.Length -gt 4096) { $diagnostic = $diagnostic.Substring(0, 4096) }
                    throw "Worker exited before fixture readiness: $Case. $diagnostic"
                }
                Start-Sleep -Milliseconds 20
            }
            if (-not (Test-Path $ready)) { throw "Worker fixture did not initialize: $Case" }
            $handler = [Net.Http.HttpClientHandler]::new()
            $handler.UseProxy = $false
            $handler.AllowAutoRedirect = $false
            $client = [Net.Http.HttpClient]::new($handler, $true)
            $client.Timeout = [TimeSpan]::FromSeconds(2)
            $base = "http://127.0.0.1:$port"
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(8)
            do {
                if ($process.HasExited) {
                    $diagnostic = ($outputTask.GetAwaiter().GetResult() + $errorTask.GetAwaiter().GetResult())
                    if ($diagnostic.Length -gt 4096) { $diagnostic = $diagnostic.Substring(0, 4096) }
                    throw "Worker exited before listener readiness: $Case. $diagnostic"
                }
                try {
                    $health = $client.GetAsync("$base/healthz").GetAwaiter().GetResult()
                    try {
                        $started = [int]$health.StatusCode -eq 200 -and
                            $health.Content.ReadAsStringAsync().GetAwaiter().GetResult() -ceq 'ok'
                    }
                    finally { $health.Dispose() }
                } catch { $started = $false; Start-Sleep -Milliseconds 20 }
            } while (-not $started -and [DateTimeOffset]::UtcNow -lt $deadline)
            if (-not $started) { throw "Worker listener did not start: $Case" }
            $returned = $true
            [pscustomobject]@{Process=$process; Port=$port; Stop=$stop; Client=$client; Base=$base; Trigger="$ready.advance"; Attempt="$ready.future-read"; Ready=$ready; ReadyWriteTicks=(Get-Item $ready).LastWriteTimeUtc.Ticks; OutputTask=$outputTask; ErrorTask=$errorTask}
        } finally {
            if (-not $returned) {
                if ($client) { $client.Dispose() }
                if ($process) {
                    try {
                        if (-not $process.HasExited) {
                            try { $process.Kill($true) } catch { throw 'Worker fixture cleanup failed.' }
                            if (-not $process.WaitForExit(5000)) { throw 'Worker fixture cleanup failed.' }
                        }
                        if ($outputTask) { $null = $outputTask.GetAwaiter().GetResult() }
                        if ($errorTask) { $null = $errorTask.GetAwaiter().GetResult() }
                    } finally { $process.Dispose() }
                }
            }
        }
    }
    function Stop-WorkerFixture($worker) {
        try {
            Set-Content -LiteralPath $worker.Stop -Value stop -Encoding ascii
            if (-not $worker.Process.WaitForExit(8000)) {
                try { $worker.Process.Kill($true) } catch { throw 'Worker fixture cleanup failed.' }
                if (-not $worker.Process.WaitForExit(5000)) { throw 'Worker fixture cleanup failed.' }
                throw 'Worker did not stop within its deadline.'
            }
            $null = $worker.OutputTask.GetAwaiter().GetResult()
            $null = $worker.ErrorTask.GetAwaiter().GetResult()
            $worker.Process.ExitCode | Should -Be 0
        }
        finally { $worker.Client.Dispose(); $worker.Process.Dispose() }
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $worker.Port)
        try { $listener.Start(); $listener.LocalEndpoint.Port | Should -Be $worker.Port }finally { $listener.Stop() }
    }
    function Send-WorkerRequest($worker, [string]$Method, [string]$Path, [byte[]]$Body = $null) {
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $worker.Base + $Path)
        if ($Body) { $request.Content = [Net.Http.ByteArrayContent]::new($Body) }
        try { return $worker.Client.SendAsync($request).GetAwaiter().GetResult() }finally { $request.Dispose() }
    }
    function Assert-WorkerResponsePolicy($response) {
        $expected = @{
            'Content-Security-Policy' = "frame-ancestors 'none'; sandbox allow-scripts allow-same-origin allow-modals allow-downloads"
            'X-Frame-Options' = 'DENY'
            'Referrer-Policy' = 'no-referrer'
            'Cache-Control' = 'no-store'
            'X-Content-Type-Options' = 'nosniff'
        }
        foreach ($name in $expected.Keys) {
            $values = @($response.Headers.GetValues($name))
            $values.Count | Should -Be 1
            $values[0] | Should -BeExactly $expected[$name]
        }
    }
    function Send-RawWorkerRequest($worker, [string]$RequestTarget) {
        $tcp = [Net.Sockets.TcpClient]::new()
        try {
            $tcp.ReceiveTimeout = 2000; $tcp.SendTimeout = 2000; $tcp.Connect([Net.IPAddress]::Loopback, $worker.Port)
            $stream = $tcp.GetStream(); $bytes = [Text.Encoding]::ASCII.GetBytes("GET $RequestTarget HTTP/1.1`r`nHost: 127.0.0.1:$($worker.Port)`r`nConnection: close`r`n`r`n")
            $stream.Write($bytes); $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
            try { return $reader.ReadToEnd() }finally { $reader.Dispose() }
        }
        finally { $tcp.Dispose() }
    }
    function Read-WorkerHeaders([IO.Stream]$Stream) {
        $header = [Text.StringBuilder]::new()
        while ($header.Length -lt 8192) {
            $value = $Stream.ReadByte()
            if ($value -lt 0) { throw 'Worker closed before response headers.' }
            $null = $header.Append([char]$value)
            if ($header.ToString().EndsWith("`r`n`r`n", [StringComparison]::Ordinal)) { return $header.ToString() }
        }
        throw 'Worker response headers exceeded test limit.'
    }
    function Wait-ReportStatus($worker, [int]$Status, [AllowNull()][object]$Stale, [int]$Seconds = 5) {
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($Seconds)
        do {
            $response = Send-WorkerRequest $worker GET '/report.html'
            $staleMatches = $null -eq $Stale -or ($response.Headers.Contains('X-Maester-Report-Stale') -and $response.Headers.GetValues('X-Maester-Report-Stale') -contains $Stale)
            if ([int]$response.StatusCode -eq $Status -and $staleMatches) { return $response }
            $response.Dispose(); Start-Sleep -Milliseconds 40
        } while ([DateTimeOffset]::UtcNow -lt $deadline)
        throw "Report did not reach $Status/$Stale"
    }
}

Describe 'Maester read-only loopback worker' {
    It 'releases a handler after a slow-client write deadline and shuts down with an active response' {
        $worker = Start-WorkerFixture slowClient
        $slow = [Net.Sockets.TcpClient]::new()
        try {
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
            do {
                $ready = $worker.Client.GetAsync("$($worker.Base)/readyz").GetAwaiter().GetResult()
                try { $available = [int]$ready.StatusCode -eq 200 } finally { $ready.Dispose() }
                if (-not $available) { Start-Sleep -Milliseconds 20 }
            } while (-not $available -and [DateTimeOffset]::UtcNow -lt $deadline)
            $available | Should -BeTrue
            $slow.ReceiveBufferSize = 1024
            $slow.ReceiveTimeout = 3000
            $slow.Connect('127.0.0.1', $worker.Port)
            $stream = $slow.GetStream()
            $request = [Text.Encoding]::ASCII.GetBytes("GET /report.html HTTP/1.1`r`nHost: 127.0.0.1:$($worker.Port)`r`n`r`n")
            $stream.Write($request)
            $headers = Read-WorkerHeaders $stream
            $headers | Should -Match '\AHTTP/1\.1 200 '
            $length=[regex]::Match($headers,'(?im)^Content-Length: ([0-9]+)\r?$').Groups[1].Value -as [long]
            $length | Should -BeGreaterOrEqual 16MB
            $length | Should -BeLessOrEqual 20MB
            # Keep the response blocked, then require the sole handler to become available.
            Start-Sleep -Milliseconds 1500
            $health = $worker.Client.GetAsync("$($worker.Base)/healthz").GetAwaiter().GetResult()
            try { [int]$health.StatusCode | Should -Be 200 } finally { $health.Dispose() }
            $slow.Dispose()
            $slow = [Net.Sockets.TcpClient]::new()
            $slow.ReceiveBufferSize = 1024
            $slow.ReceiveTimeout = 3000
            $slow.Connect('127.0.0.1', $worker.Port)
            $stream = $slow.GetStream()
            $stream.Write($request)
            $headers = Read-WorkerHeaders $stream
            $headers | Should -Match '\AHTTP/1\.1 200 '
            $headers | Should -Match "(?im)^Content-Length: $length\r?$"
            Stop-WorkerFixture $worker
            $worker = $null
        }
        finally {
            $slow.Dispose()
            if ($worker) { Stop-WorkerFixture $worker }
        }
    }

    It 'serves exact GET and HEAD report bytes with bounded staleness headers' {
        $worker = Start-WorkerFixture valid
        try {
            $get = Wait-ReportStatus $worker 200 'false'
            try { Assert-WorkerResponsePolicy $get; [Text.Encoding]::UTF8.GetString($get.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()) | Should -BeExactly $script:oldReportText; @($get.Headers.GetValues('X-Maester-Report-Run')).Count | Should -Be 1 }finally { $get.Dispose() }
            $head = Send-WorkerRequest $worker HEAD '/report.html'
            try { Assert-WorkerResponsePolicy $head; [int]$head.StatusCode | Should -Be 200; $head.Content.Headers.ContentLength | Should -BeGreaterThan 0; $head.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult().Length | Should -Be 0 }finally { $head.Dispose() }
            Start-Sleep -Milliseconds 400
            (Get-Item $worker.Ready).LastWriteTimeUtc.Ticks | Should -Be $worker.ReadyWriteTicks
        }
        finally { Stop-WorkerFixture $worker }
    }

    It 'rejects request-derived paths, query, methods, and bodies' {
        $worker = Start-WorkerFixture valid
        try {
            foreach ($case in @(
                    @{m = 'GET'; p = '/report.html?x=1'; b = $null; s = 404 },
                    @{m = 'GET'; p = '/runs/id/report.html'; b = $null; s = 404 }, @{m = 'POST'; p = '/report.html'; b = $null; s = 405 },
                    @{m = 'GET'; p = '/report.html'; b = [byte[]](1); s = 400 })) {
                $response = Send-WorkerRequest $worker $case.m $case.p $case.b; try { Assert-WorkerResponsePolicy $response; [int]$response.StatusCode | Should -Be $case.s }finally { $response.Dispose() }
            }
            (Send-RawWorkerRequest $worker '/%72eport.html') | Should -Match '^HTTP/1\.1 404 '
        }
        finally { Stop-WorkerFixture $worker }
    }

    It 'keeps probes minimal and startup unavailable without a snapshot' {
        $worker = Start-WorkerFixture missing
        try {
            foreach ($path in '/healthz', '/readyz', '/report.html') { $response = Send-WorkerRequest $worker GET $path; try { Assert-WorkerResponsePolicy $response; if ($path -eq '/healthz') { [int]$response.StatusCode | Should -Be 200 }else { [int]$response.StatusCode | Should -Be 503 }; $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult(); $text | Should -Not -Match '11111111|worker-test|Projection|exception|snapshot'; $response.Headers.Contains('X-Maester-Report-Run') | Should -BeFalse }finally { $response.Dispose() } }
        }
        finally { Stop-WorkerFixture $worker }
    }

    It 'rejects a future generation without serving it' {
        $worker = Start-WorkerFixture future
        try {
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
            while (-not (Test-Path $worker.Attempt) -and [DateTimeOffset]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
            Test-Path $worker.Attempt | Should -BeTrue
            $response = Wait-ReportStatus $worker 503 $null
            try {
                [int]$response.StatusCode | Should -Be 503
                $response.Headers.Contains('X-Maester-Report-Run') | Should -BeFalse
            } finally { $response.Dispose() }
        } finally { Stop-WorkerFixture $worker }
    }

    It 'retains exact last-good bytes after corrupt refresh and marks them stale' {
        $worker = Start-WorkerFixture corruptRefresh
        try { $response = Wait-ReportStatus $worker 200 'true'; try { [Text.Encoding]::UTF8.GetString($response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()) | Should -BeExactly $script:oldReportText }finally { $response.Dispose() } } finally { Stop-WorkerFixture $worker }
    }

    It 'stops serving last-good bytes after maximum report age' {
        $worker = Start-WorkerFixture expire
        try {
            $old = Wait-ReportStatus $worker 200 'false'
            try { $old.Content.ReadAsStringAsync().GetAwaiter().GetResult() | Should -BeExactly $script:oldReportText } finally { $old.Dispose() }
            Set-Content -LiteralPath $worker.Trigger -Value advance
            $response = Wait-ReportStatus $worker 503 $null
            try { [int]$response.StatusCode | Should -Be 503 } finally { $response.Dispose() }
        } finally { Stop-WorkerFixture $worker }
    }

    It 'retains last-good bytes when a fully rehashed refresh fails content qualification' {
        $worker=Start-WorkerFixture qualifiedTamperRefresh
        try {
            $old=Wait-ReportStatus $worker 200 'false';try{$old.Content.ReadAsStringAsync().GetAwaiter().GetResult()|Should -BeExactly $script:oldReportText}finally{$old.Dispose()}
            Set-Content -LiteralPath $worker.Trigger -Value advance
            $retained=Wait-ReportStatus $worker 200 'true' 15
            try{$retained.Content.ReadAsStringAsync().GetAwaiter().GetResult()|Should -BeExactly $script:oldReportText}finally{$retained.Dispose()}
        } finally {Stop-WorkerFixture $worker}
    }

    It 'atomically serves only complete old or new snapshots under concurrent reads' {
        $worker = Start-WorkerFixture switchSnapshot
        try {
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $old = Wait-ReportStatus $worker 200 'false'
            try { $null = $seen.Add($old.Content.ReadAsStringAsync().GetAwaiter().GetResult()) } finally { $old.Dispose() }
            $seen.Contains($script:oldReportText) | Should -BeTrue
            Set-Content -LiteralPath $worker.Trigger -Value advance
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
            do {
                $tasks = 1..4 | ForEach-Object { $worker.Client.GetByteArrayAsync("$($worker.Base)/report.html") }
                [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks)
                foreach ($task in $tasks) { $null = $seen.Add([Text.Encoding]::UTF8.GetString($task.Result)) }
            } while (-not $seen.Contains($script:newReportText) -and [DateTimeOffset]::UtcNow -lt $deadline)
            @($seen | Where-Object { $_ -notin @($script:oldReportText, $script:newReportText) }).Count | Should -Be 0
            $seen.Contains($script:newReportText) | Should -BeTrue
        }
        finally { Stop-WorkerFixture $worker }
    }
}
