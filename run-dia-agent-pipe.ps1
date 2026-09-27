$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$evidence = Join-Path $env:RUNNER_TEMP "evidence"
$scratch = Join-Path $env:RUNNER_TEMP "dia-agent-pipe"
$lowDir = Join-Path $env:RUNNER_TEMP "dia-agent-low"
New-Item -ItemType Directory -Force -Path $evidence, $scratch, $lowDir | Out-Null

$msixUrl = "https://releases.diabrowser.com/windows/release-candidate/8EE7CF18-AF4C-48AF-94B0-4B9300876DA5/0.28.0.380/Dia.x64.msix"
$dependencyUrl = "https://releases.diabrowser.com/windows/dependencies/x64/Microsoft.VCLibs.x64.14.00.Desktop.14.0.33728.0.appx"
$psToolsUrl = "https://download.sysinternals.com/files/PSTools.zip"
$expectedMsix = "fd92a6dd178222bc687683a2353b540bd13d0ed42ff87b61124a09bd8be09407"
$expectedDependency = "077a3d1a5d0622bd3004dca85f5e192d6e98ec79b83d4aa06766759ea6c09c3d"
$msixPath = Join-Path $scratch "Dia.x64.msix"
$dependencyPath = Join-Path $scratch "Microsoft.VCLibs.x64.appx"
$psToolsZip = Join-Path $scratch "PSTools.zip"
$resultPath = Join-Path $evidence "agent-pipe-result.json"

$result = [ordered]@{
  schema = "bcny-r13-dia-windows-agent-pipe-v1"
  target = "TheBrowserCompany.Dia"
  requested_version = "0.28.0.380"
  scope = "packaged AgentServer component harness; not a supported signed-in product-flow claim"
  stage = "initialize"
  baseline = $null
  package = $null
  agent_server = $null
  default_browser_processes = $null
  medium_integrity = $null
  low_integrity = $null
  cleanup = $null
  failure = $null
}
$failed = $false
$diaPackage = $null
$diaInstallLocation = $null
$installedDependencyByRun = $false
$dependencyInstalledFullName = $null
$serverProcesses = New-Object System.Collections.Generic.List[System.Diagnostics.Process]
$serverJobs = New-Object System.Collections.Generic.List[object]
$baselineProfile = @{}

function Download-Exact([string]$Url, [string]$Path, [string]$Expected) {
  & curl.exe --fail --location --silent --show-error --retry 3 --max-time 900 --user-agent "authorized-security-research/1.0" --output $Path $Url
  if ($LASTEXITCODE -ne 0) { throw "curl failed with exit $LASTEXITCODE" }
  $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
  if ($actual -ne $Expected) { throw "download hash mismatch" }
}

function Start-AgentServer([string]$Executable, [string]$WorkingDirectory, [string]$PipeLeaf, [string]$Label) {
  $stdout = Join-Path $scratch "$Label.stdout.txt"
  $stderr = Join-Path $scratch "$Label.stderr.txt"
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $Executable
  $psi.WorkingDirectory = $WorkingDirectory
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.Environment["AGENT_SERVER_SOCKET_PATH"] = "\\.\pipe\$PipeLeaf"
  $psi.Environment["AGENT_SERVER_PERSISTENT"] = "1"
  $psi.Environment["TOOL_SCHEMAS_DIR"] = Join-Path $WorkingDirectory "resources\tool-schemas"
  $psi.Environment["SENTRY_DSN"] = ""
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $psi
  $launchMode = "direct"
  $directLaunchError = $null
  try {
    if (-not $process.Start()) { throw "failed to start AgentServer" }
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()
  } catch {
    $directLaunchError = $_.Exception.Message
    $launchMode = "Invoke-CommandInDesktopPackage-PreventBreakaway"
    $job = Start-Job -ScriptBlock {
      param($PackageFamilyName,$ApplicationId,$Command,$PipePath,$ToolSchemas)
      $env:AGENT_SERVER_SOCKET_PATH = $PipePath
      $env:AGENT_SERVER_PERSISTENT = "1"
      $env:TOOL_SCHEMAS_DIR = $ToolSchemas
      $env:SENTRY_DSN = ""
      Import-Module Appx -ErrorAction Stop
      Invoke-CommandInDesktopPackage -PackageFamilyName $PackageFamilyName -AppId $ApplicationId -Command $Command -Args "" -PreventBreakaway
    } -ArgumentList $diaPackage.PackageFamilyName,"Dia",$Executable,"\\.\pipe\$PipeLeaf",(Join-Path $WorkingDirectory "resources\tool-schemas")
    $serverJobs.Add($job)
    $process = $null
    for ($attempt = 0; $attempt -lt 20 -and -not $process; $attempt++) {
      Start-Sleep -Milliseconds 500
      $candidate = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        ($_.ExecutablePath -and $_.ExecutablePath.Equals($Executable, [StringComparison]::OrdinalIgnoreCase)) -or
        $_.Name -ieq "agent-server.exe"
      } | Select-Object -First 1
      if ($candidate) { $process = [System.Diagnostics.Process]::GetProcessById([int]$candidate.ProcessId) }
      if ($job.State -eq "Failed") { break }
    }
    if (-not $process) {
      $jobErrors = @($job.ChildJobs | ForEach-Object { $_.Error | ForEach-Object { if ($null -ne $_) { $_.ToString() } } }) -join " | "
      $jobReason = @($job.ChildJobs | ForEach-Object { if ($null -ne $_.JobStateInfo.Reason) { $_.JobStateInfo.Reason.ToString() } }) -join " | "
      throw "packaged AgentServer launch failed; job_state=$($job.State); errors=$jobErrors; reason=$jobReason"
    }
  }
  $serverProcesses.Add($process)
  Start-Sleep -Seconds 2
  if ($process.HasExited) { throw "AgentServer exited early with code $($process.ExitCode)" }
  return [ordered]@{
    process = $process
    stdout = $stdout
    stderr = $stderr
    launch_mode = $launchMode
    direct_launch_error = $directLaunchError
  }
}

function Read-Line-With-Timeout([System.IO.StreamReader]$Reader, [int]$Milliseconds) {
  $task = $Reader.ReadLineAsync()
  if (-not $task.Wait($Milliseconds)) { return $null }
  return $task.Result
}

function Response-Summary([string]$Line) {
  if ($null -eq $Line) { return [ordered]@{ received=$false } }
  $bytes = [Text.Encoding]::UTF8.GetBytes($Line)
  $summary = [ordered]@{
    received = $true
    bytes = $bytes.Length
    sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    json_valid = $false
    type = $null
    msg = $null
    success = $null
    error = $null
    agent_count = $null
    feature_count = $null
  }
  try {
    $parsed = $Line | ConvertFrom-Json -Depth 20
    $summary.json_valid = $true
    $summary.type = $parsed.type
    $summary.msg = $parsed.msg
    if ($null -ne $parsed.success) { $summary.success = [bool]$parsed.success }
    if ($parsed.error) { $summary.error = [string]$parsed.error }
    if ($parsed.payload.error) { $summary.error = [string]$parsed.payload.error }
    if ($parsed.payload.agents) { $summary.agent_count = @($parsed.payload.agents).Count }
    if ($parsed.payload.features) { $summary.feature_count = @($parsed.payload.features).Count }
    if ($parsed.agents) { $summary.agent_count = @($parsed.agents).Count }
    if ($parsed.features) { $summary.feature_count = @($parsed.features).Count }
  } catch {}
  return $summary
}

try {
  $result.stage = "baseline"
  $baselineDia = @(Get-AppxPackage -Name "TheBrowserCompany.Dia" -ErrorAction SilentlyContinue)
  $baselineDependency = @(Get-AppxPackage -Name "Microsoft.VCLibs.140.00.UWPDesktop" -ErrorAction SilentlyContinue)
  $profileCandidates = @(
    (Join-Path $env:LOCALAPPDATA "The Browser Company\Dia"),
    (Join-Path $env:LOCALAPPDATA "TheBrowserCompany\Dia"),
    (Join-Path $env:LOCALAPPDATA "Dia"),
    (Join-Path $env:APPDATA "The Browser Company\Dia"),
    (Join-Path $env:APPDATA "Dia")
  )
  foreach ($candidate in $profileCandidates) { $baselineProfile[$candidate] = Test-Path -LiteralPath $candidate }
  $result.baseline = [ordered]@{ dia_package_count=$baselineDia.Count; dependency_package_count=$baselineDependency.Count }
  if ($baselineDia.Count -ne 0) { throw "Dia unexpectedly installed at baseline" }

  Download-Exact $msixUrl $msixPath $expectedMsix
  Download-Exact $dependencyUrl $dependencyPath $expectedDependency
  $result.stage = "install"
  if ($baselineDependency.Count -eq 0) {
    Add-AppxPackage -Path $dependencyPath -ForceApplicationShutdown
    $installedDependencyByRun = $true
    $dependencyInstalledFullName = (Get-AppxPackage -Name "Microsoft.VCLibs.140.00.UWPDesktop" | Select-Object -First 1).PackageFullName
  }
  Add-AppxPackage -Path $msixPath -DependencyPath $dependencyPath -ForceApplicationShutdown
  $diaPackage = Get-AppxPackage -Name "TheBrowserCompany.Dia" | Sort-Object Version -Descending | Select-Object -First 1
  if (-not $diaPackage) { throw "Dia missing after installation" }
  $diaInstallLocation = [string]$diaPackage.InstallLocation
  $result.package = [ordered]@{
    full_name = $diaPackage.PackageFullName
    family_name = $diaPackage.PackageFamilyName
    version = [string]$diaPackage.Version
    install_location_leaf = Split-Path $diaInstallLocation -Leaf
  }
  $agentDir = Join-Path $diaInstallLocation "agent-server-resources\dist"
  $agentExe = Join-Path $agentDir "agent-server.exe"
  if (-not (Test-Path -LiteralPath $agentExe)) { throw "packaged AgentServer missing" }
  $agentSignature = Get-AuthenticodeSignature -LiteralPath $agentExe
  $result.agent_server = [ordered]@{
    relative_path = "agent-server-resources/dist/agent-server.exe"
    bytes = (Get-Item -LiteralPath $agentExe).Length
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $agentExe).Hash.ToLowerInvariant()
    signature_status = [string]$agentSignature.Status
    signer_thumbprint = if ($agentSignature.SignerCertificate) { $agentSignature.SignerCertificate.Thumbprint } else { $null }
  }
  if ($agentSignature.Status -ne "Valid") { throw "AgentServer signature invalid" }

  $result.stage = "default-browser-control"
  $diaExe = Join-Path $diaInstallLocation "Dia.exe"
  Start-Process -FilePath $diaExe | Out-Null
  Start-Sleep -Seconds 12
  $defaultProcesses = @(Get-CimInstance Win32_Process | Where-Object {
    $_.ExecutablePath -and $_.ExecutablePath.StartsWith($diaInstallLocation, [StringComparison]::OrdinalIgnoreCase)
  })
  $result.default_browser_processes = [ordered]@{
    count = $defaultProcesses.Count
    agent_server_count = @($defaultProcesses | Where-Object { $_.Name -eq "agent-server.exe" }).Count
    handler_count = @($defaultProcesses | Where-Object { $_.Name -eq "handler.exe" }).Count
    names = @($defaultProcesses.Name | Sort-Object -Unique)
  }
  $defaultProcesses | ForEach-Object { Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 2

  $result.stage = "medium-integrity-component-harness"
  $mediumLeaf = "dia-agent.server.r13-medium-$([Guid]::NewGuid().ToString('N'))"
  $mediumServer = Start-AgentServer $agentExe $agentDir $mediumLeaf "medium"
  $mediumClient = [System.IO.Pipes.NamedPipeClientStream]::new(".", $mediumLeaf, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
  $mediumClient.Connect(10000)
  $aclSddl = $null
  $aclError = $null
  try {
    Add-Type -AssemblyName System.IO.Pipes.AccessControl
    $pipeSecurity = [System.IO.Pipes.PipeStreamAclExtensions]::GetAccessControl($mediumClient)
    $aclSddl = $pipeSecurity.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
  } catch { $aclError = $_.Exception.Message }
  $writer = [System.IO.StreamWriter]::new($mediumClient, [Text.UTF8Encoding]::new($false), 4096, $true)
  $writer.NewLine = "`n"
  $writer.AutoFlush = $true
  $reader = [System.IO.StreamReader]::new($mediumClient, [Text.UTF8Encoding]::new($false), $false, 4096, $true)
  $hello = '{"type":"HELLO","msg":"h1","client_id":"r13-medium-probe","protocol_version":"1.0"}'
  $writer.WriteLine($hello)
  $helloLine = Read-Line-With-Timeout $reader 10000
  if ($helloLine) { Set-Content -LiteralPath (Join-Path $evidence "medium-hello-response.txt") -Value $helloLine -Encoding utf8NoBOM }
  $invalidRun = '{"type":"RUN","msg":"r1","payload":{"agent":"__r13_impossible_agent__","prompt":"return the literal R13_PIPE_CONTROL and use no tools"}}'
  $writer.WriteLine($invalidRun)
  $runLine = Read-Line-With-Timeout $reader 10000
  if ($runLine) { Set-Content -LiteralPath (Join-Path $evidence "medium-invalid-run-response.txt") -Value $runLine -Encoding utf8NoBOM }
  $result.medium_integrity = [ordered]@{
    server_launch_mode = $mediumServer.launch_mode
    direct_server_launch_error = $mediumServer.direct_launch_error
    connected = $mediumClient.IsConnected
    pipe_leaf_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($mediumLeaf))).ToLowerInvariant()
    security_descriptor_sddl = $aclSddl
    security_descriptor_error = $aclError
    hello = Response-Summary $helloLine
    invalid_agent_run = Response-Summary $runLine
  }
  $mediumClient.Dispose()
  if (-not $mediumServer.process.HasExited) { $mediumServer.process.Kill($true); $mediumServer.process.WaitForExit(5000) | Out-Null }

  $result.stage = "low-integrity-component-harness"
  & curl.exe --fail --location --silent --show-error --retry 3 --max-time 180 --user-agent "authorized-security-research/1.0" --output $psToolsZip $psToolsUrl
  if ($LASTEXITCODE -ne 0) { throw "PSTools download failed" }
  Expand-Archive -LiteralPath $psToolsZip -DestinationPath (Join-Path $scratch "pstools") -Force
  $psExec = Join-Path $scratch "pstools\PsExec64.exe"
  $psExecSignature = Get-AuthenticodeSignature -LiteralPath $psExec
  if ($psExecSignature.Status -ne "Valid" -or $psExecSignature.SignerCertificate.Subject -notmatch "Microsoft") { throw "PsExec signature validation failed" }
  & icacls.exe $lowDir /grant '*S-1-1-0:(OI)(CI)M' /setintegritylevel '(OI)(CI)L' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "failed to prepare low-integrity output directory" }
  $lowClientScript = Join-Path $lowDir "pipe-client.ps1"
  $lowOutput = Join-Path $lowDir "low-result.json"
  @'
param([string]$PipeLeaf,[string]$OutputPath)
$ErrorActionPreference = "Stop"
$r = [ordered]@{ connected=$false; response_received=$false; response_bytes=0; response_sha256=$null; error=$null }
try {
  $c = [System.IO.Pipes.NamedPipeClientStream]::new(".",$PipeLeaf,[System.IO.Pipes.PipeDirection]::InOut,[System.IO.Pipes.PipeOptions]::Asynchronous)
  $c.Connect(7000)
  $r.connected = $c.IsConnected
  $w = [System.IO.StreamWriter]::new($c,[Text.UTF8Encoding]::new($false),4096,$true)
  $w.NewLine = "`n"; $w.AutoFlush = $true
  $reader = [System.IO.StreamReader]::new($c,[Text.UTF8Encoding]::new($false),$false,4096,$true)
  $w.WriteLine('{"type":"HELLO","msg":"h-low","client_id":"r13-low-probe","protocol_version":"1.0"}')
  $task = $reader.ReadLineAsync()
  if ($task.Wait(7000) -and $null -ne $task.Result) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($task.Result)
    $r.response_received = $true
    $r.response_bytes = $bytes.Length
    $r.response_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
  }
  $c.Dispose()
} catch { $r.error = $_.Exception.Message }
$r | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding utf8
if (-not $r.connected) { exit 2 }
'@ | Set-Content -LiteralPath $lowClientScript -Encoding utf8
  $lowLeaf = "dia-agent.server.r13-low-$([Guid]::NewGuid().ToString('N'))"
  $lowServer = Start-AgentServer $agentExe $agentDir $lowLeaf "low"
  & $psExec -accepteula -nobanner -l -w $lowDir powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $lowClientScript $lowLeaf $lowOutput | Out-Null
  $psExecExit = $LASTEXITCODE
  $lowResult = if (Test-Path -LiteralPath $lowOutput) { Get-Content -Raw -LiteralPath $lowOutput | ConvertFrom-Json } else { $null }
  $result.low_integrity = [ordered]@{
    server_launch_mode = $lowServer.launch_mode
    direct_server_launch_error = $lowServer.direct_launch_error
    harness = "Microsoft-signed PsExec64 -l"
    psexec_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $psExec).Hash.ToLowerInvariant()
    psexec_signer_subject = $psExecSignature.SignerCertificate.Subject
    psexec_exit_code = $psExecExit
    result_file_present = [bool](Test-Path -LiteralPath $lowOutput)
    connected = if ($lowResult) { [bool]$lowResult.connected } else { $false }
    response_received = if ($lowResult) { [bool]$lowResult.response_received } else { $false }
    response_bytes = if ($lowResult) { [int]$lowResult.response_bytes } else { 0 }
    response_sha256 = if ($lowResult) { $lowResult.response_sha256 } else { $null }
    error = if ($lowResult) { $lowResult.error } else { "no low-integrity result file" }
  }
  if (-not $lowServer.process.HasExited) { $lowServer.process.Kill($true); $lowServer.process.WaitForExit(5000) | Out-Null }
  $result.stage = "complete"
} catch {
  $failed = $true
  $result.failure = [ordered]@{
    type = $_.Exception.GetType().FullName
    message = $_.Exception.Message
    position = $_.InvocationInfo.PositionMessage
    script_stack = $_.ScriptStackTrace
  }
} finally {
  foreach ($server in $serverProcesses) {
    try { if (-not $server.HasExited) { $server.Kill($true); $server.WaitForExit(5000) | Out-Null } } catch {}
  }
  foreach ($job in $serverJobs) {
    try { Stop-Job -Job $job -ErrorAction SilentlyContinue; Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
  }
  if ($diaInstallLocation) {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      $_.ExecutablePath -and $_.ExecutablePath.StartsWith($diaInstallLocation, [StringComparison]::OrdinalIgnoreCase)
    } | ForEach-Object { Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue }
  }
  Start-Sleep -Seconds 2
  if ($diaPackage) { Remove-AppxPackage -Package $diaPackage.PackageFullName -ErrorAction SilentlyContinue }
  if ($installedDependencyByRun -and $dependencyInstalledFullName) {
    Remove-AppxPackage -Package $dependencyInstalledFullName -ErrorAction SilentlyContinue
  }
  foreach ($candidate in @($baselineProfile.Keys)) {
    if (-not $baselineProfile[$candidate] -and (Test-Path -LiteralPath $candidate)) {
      Remove-Item -LiteralPath $candidate -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  $remainingDia = @(Get-AppxPackage -Name "TheBrowserCompany.Dia" -ErrorAction SilentlyContinue).Count
  $remainingDependency = @(Get-AppxPackage -Name "Microsoft.VCLibs.140.00.UWPDesktop" -ErrorAction SilentlyContinue).Count
  $remainingProcesses = 0
  if ($diaInstallLocation) {
    $remainingProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      $_.ExecutablePath -and $_.ExecutablePath.StartsWith($diaInstallLocation, [StringComparison]::OrdinalIgnoreCase)
    }).Count
  }
  $newProfiles = @($baselineProfile.Keys | Where-Object { -not $baselineProfile[$_] -and (Test-Path -LiteralPath $_) })
  $cleanupPassed = ($remainingDia -eq 0 -and $remainingDependency -eq $result.baseline.dependency_package_count -and $remainingProcesses -eq 0 -and $newProfiles.Count -eq 0)
  $result.cleanup = [ordered]@{
    dia_package_count_after = $remainingDia
    dependency_count_after = $remainingDependency
    dependency_baseline_count = $result.baseline.dependency_package_count
    package_process_count_after = $remainingProcesses
    residual_new_profile_candidate_count = $newProfiles.Count
    cleanup_gate_passed = $cleanupPassed
  }
  $result | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $resultPath -Encoding utf8
}

if ($failed -or -not $result.cleanup.cleanup_gate_passed) { exit 1 }
