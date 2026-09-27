$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$evidence = Join-Path $env:RUNNER_TEMP "evidence"
$download = Join-Path $env:RUNNER_TEMP "dia-open-beta-uia"
New-Item -ItemType Directory -Force -Path $evidence, $download | Out-Null

$msixUrl = "https://releases.diabrowser.com/windows/release-candidate/8EE7CF18-AF4C-48AF-94B0-4B9300876DA5/0.28.0.380/Dia.x64.msix"
$dependencyUrl = "https://releases.diabrowser.com/windows/dependencies/x64/Microsoft.VCLibs.x64.14.00.Desktop.14.0.33728.0.appx"
$expectedMsix = "fd92a6dd178222bc687683a2353b540bd13d0ed42ff87b61124a09bd8be09407"
$expectedDependency = "077a3d1a5d0622bd3004dca85f5e192d6e98ec79b83d4aa06766759ea6c09c3d"
$msixPath = Join-Path $download "Dia.x64.msix"
$dependencyPath = Join-Path $download "Microsoft.VCLibs.x64.appx"
$resultPath = Join-Path $evidence "uia-result.json"

$result = [ordered]@{
  schema = "bcny-r13-dia-windows-open-beta-uia-v1"
  target = "TheBrowserCompany.Dia"
  requested_version = "0.28.0.380"
  baseline = $null
  package = $null
  process_count = 0
  target_processes = @()
  uia = $null
  cleanup = $null
  failure = $null
}
$failed = $false
$diaPackage = $null
$diaInstallLocation = $null
$installedDependencyByRun = $false
$dependencyInstalledFullName = $null
$baselineProfile = @{}

function Download-Exact([string]$Url, [string]$Path, [string]$Expected) {
  & curl.exe --fail --location --silent --show-error --retry 3 --max-time 900 --user-agent "authorized-security-research/1.0" --output $Path $Url
  if ($LASTEXITCODE -ne 0) { throw "curl failed with exit $LASTEXITCODE" }
  $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
  if ($actual -ne $Expected) { throw "download hash mismatch" }
}

try {
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
  $result.baseline = [ordered]@{
    dia_package_count = $baselineDia.Count
    dependency_package_count = $baselineDependency.Count
  }
  if ($baselineDia.Count -ne 0) { throw "Dia unexpectedly installed at baseline" }

  Download-Exact $msixUrl $msixPath $expectedMsix
  Download-Exact $dependencyUrl $dependencyPath $expectedDependency
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

  $diaExe = Join-Path $diaInstallLocation "Dia.exe"
  Start-Process -FilePath $diaExe | Out-Null
  Start-Sleep -Seconds 25
  $processes = @(Get-CimInstance Win32_Process | Where-Object {
    $_.ExecutablePath -and $_.ExecutablePath.StartsWith($diaInstallLocation, [StringComparison]::OrdinalIgnoreCase)
  })
  $pids = @($processes | ForEach-Object { [int]$_.ProcessId })
  $result.process_count = $processes.Count
  $result.target_processes = @($processes | ForEach-Object {
    [ordered]@{
      name = $_.Name
      pid = [int]$_.ProcessId
      parent_pid = [int]$_.ParentProcessId
      executable_relative = $_.ExecutablePath.Substring($diaInstallLocation.Length).TrimStart('\')
    }
  })
  if ($pids.Count -eq 0) { throw "no target package process after launch" }

  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  $nodes = New-Object System.Collections.Generic.List[object]
  $all = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition
  )
  for ($i = 0; $i -lt $all.Count; $i++) {
    if ($nodes.Count -ge 2000) { break }
    try {
      $element = $all.Item($i)
      $pid = [int]$element.Current.ProcessId
      if ($pids -notcontains $pid) { continue }
      $invoke = $false
      $selectionItem = $false
      $valuePattern = $false
      $patternObject = $null
      try { $invoke = $element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$patternObject) } catch {}
      $patternObject = $null
      try { $selectionItem = $element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$patternObject) } catch {}
      $patternObject = $null
      try { $valuePattern = $element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$patternObject) } catch {}
      $nodes.Add([ordered]@{
        pid = $pid
        control_type = $element.Current.ControlType.ProgrammaticName
        name = [string]$element.Current.Name
        automation_id = [string]$element.Current.AutomationId
        class_name = [string]$element.Current.ClassName
        framework_id = [string]$element.Current.FrameworkId
        is_enabled = [bool]$element.Current.IsEnabled
        is_offscreen = [bool]$element.Current.IsOffscreen
        has_invoke_pattern = [bool]$invoke
        has_selection_item_pattern = [bool]$selectionItem
        has_value_pattern = [bool]$valuePattern
      })
    } catch {}
  }
  $named = @($nodes | Where-Object { $_.name -or $_.automation_id })
  $result.uia = [ordered]@{
    scope = "exact installed-package process IDs; names and structural metadata only; no value reads or actions"
    node_count = $nodes.Count
    named_or_identified_count = $named.Count
    truncated = ($nodes.Count -ge 2000)
    process_ids = @($pids | Sort-Object -Unique)
    nodes = @($nodes)
  }
} catch {
  $failed = $true
  $result.failure = [ordered]@{ type=$_.Exception.GetType().FullName; message=$_.Exception.Message }
} finally {
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
  $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultPath -Encoding utf8
}

if ($failed -or -not $result.cleanup.cleanup_gate_passed) { exit 1 }
