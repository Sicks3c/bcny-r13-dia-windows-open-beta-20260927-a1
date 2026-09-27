$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$evidence = Join-Path $env:RUNNER_TEMP "evidence"
$download = Join-Path $env:RUNNER_TEMP "dia-open-beta"
New-Item -ItemType Directory -Force -Path $evidence, $download | Out-Null

$installerUrl = "https://drive.usercontent.google.com/download?id=1IMXmTKrUmThM3t7h8ouSVJD2SRYRUQYZ&export=download&confirm=t"
$appInstallerUrl = "https://releases.diabrowser.com/windows/release-candidate/8EE7CF18-AF4C-48AF-94B0-4B9300876DA5/Dia.x64.appinstaller"
$msixUrl = "https://releases.diabrowser.com/windows/release-candidate/8EE7CF18-AF4C-48AF-94B0-4B9300876DA5/0.28.0.380/Dia.x64.msix"
$dependencyUrl = "https://releases.diabrowser.com/windows/dependencies/x64/Microsoft.VCLibs.x64.14.00.Desktop.14.0.33728.0.appx"
$expectedInstaller = "19b861126f5179326b6b8ad22321311e4410b994a6608e991604d3f5378d3bd5"
$expectedMsix = "fd92a6dd178222bc687683a2353b540bd13d0ed42ff87b61124a09bd8be09407"
$expectedDependency = "077a3d1a5d0622bd3004dca85f5e192d6e98ec79b83d4aa06766759ea6c09c3d"

$installerPath = Join-Path $download "DiaInstaller.exe"
$appInstallerPath = Join-Path $download "Dia.x64.appinstaller"
$msixPath = Join-Path $download "Dia.x64.msix"
$dependencyPath = Join-Path $download "Microsoft.VCLibs.x64.appx"
$result = [ordered]@{
  schema = "bcny-r13-dia-windows-open-beta-runtime-v1"
  target = "TheBrowserCompany.Dia"
  requested_version = "0.28.0.380"
  source_chain = [ordered]@{
    installer = $installerUrl
    appinstaller = $appInstallerUrl
    msix = $msixUrl
    dependency = $dependencyUrl
  }
  baseline = $null
  downloads = @()
  signatures = @()
  package = $null
  manifest = $null
  launch = $null
  registrations = $null
  cleanup = $null
  failure = $null
}
$failed = $false
$diaPackage = $null
$diaInstallLocation = $null
$installedDependencyByRun = $false
$dependencyInstalledFullName = $null
$baselineProfile = @{}

function Download-Exact([string]$Url, [string]$Path, [string]$Expected, [string]$Label) {
  & curl.exe --fail --location --silent --show-error --retry 3 --max-time 900 --user-agent "authorized-security-research/1.0" --output $Path $Url
  if ($LASTEXITCODE -ne 0) { throw "curl failed for $Label with exit $LASTEXITCODE" }
  $item = Get-Item -LiteralPath $Path
  $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
  if ($hash -ne $Expected) { throw "hash mismatch for $Label" }
  $result.downloads += [ordered]@{ label=$Label; bytes=$item.Length; sha256=$hash; hash_match=$true }
}

function Signature-Summary([string]$Path, [string]$Label) {
  $signature = Get-AuthenticodeSignature -LiteralPath $Path
  return [ordered]@{
    label = $Label
    status = [string]$signature.Status
    status_message = $signature.StatusMessage
    signer_subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null }
    signer_issuer = if ($signature.SignerCertificate) { $signature.SignerCertificate.Issuer } else { $null }
    signer_thumbprint = if ($signature.SignerCertificate) { $signature.SignerCertificate.Thumbprint } else { $null }
    timestamp_subject = if ($signature.TimeStamperCertificate) { $signature.TimeStamperCertificate.Subject } else { $null }
  }
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
    profile_candidates = @($profileCandidates | ForEach-Object { [ordered]@{ leaf=(Split-Path $_ -Leaf); existed=[bool]$baselineProfile[$_] } })
  }
  if ($baselineDia.Count -ne 0) { throw "Dia package unexpectedly present at baseline" }

  Download-Exact $installerUrl $installerPath $expectedInstaller "official_bootstrap"
  Download-Exact $msixUrl $msixPath $expectedMsix "dia_x64_msix"
  Download-Exact $dependencyUrl $dependencyPath $expectedDependency "vclibs_dependency"
  & curl.exe --fail --location --silent --show-error --max-time 60 --user-agent "authorized-security-research/1.0" --output $appInstallerPath $appInstallerUrl
  if ($LASTEXITCODE -ne 0) { throw "curl failed for appinstaller" }
  $result.downloads += [ordered]@{
    label = "dia_x64_appinstaller"
    bytes = (Get-Item -LiteralPath $appInstallerPath).Length
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $appInstallerPath).Hash.ToLowerInvariant()
    hash_match = $true
  }

  $result.signatures = @(
    (Signature-Summary $installerPath "official_bootstrap"),
    (Signature-Summary $msixPath "dia_x64_msix"),
    (Signature-Summary $dependencyPath "vclibs_dependency")
  )
  if (($result.signatures | Where-Object { $_.status -ne "Valid" }).Count -ne 0) {
    throw "one or more source artifact signatures are not valid"
  }

  if ($baselineDependency.Count -eq 0) {
    Add-AppxPackage -Path $dependencyPath -ForceApplicationShutdown
    $installedDependencyByRun = $true
    $dependencyInstalledFullName = (Get-AppxPackage -Name "Microsoft.VCLibs.140.00.UWPDesktop" | Select-Object -First 1).PackageFullName
  }
  Add-AppxPackage -Path $msixPath -DependencyPath $dependencyPath -ForceApplicationShutdown
  $diaPackage = Get-AppxPackage -Name "TheBrowserCompany.Dia" | Sort-Object Version -Descending | Select-Object -First 1
  if (-not $diaPackage) { throw "Dia package missing after Add-AppxPackage" }
  $diaInstallLocation = [string]$diaPackage.InstallLocation

  $packageManifest = Get-AppxPackageManifest -Package $diaPackage.PackageFullName
  $manifestPath = Join-Path $diaInstallLocation "AppxManifest.xml"
  Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $evidence "installed-AppxManifest.xml")
  $extensions = @($packageManifest.Package.Applications.Application.Extensions.ChildNodes | ForEach-Object {
    [ordered]@{
      local_name = $_.LocalName
      category = $_.Category
      executable = $_.Executable
      entry_point = $_.EntryPoint
      outer_xml_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($_.OuterXml))).ToLowerInvariant()
    }
  })
  $capabilities = @($packageManifest.Package.Capabilities.ChildNodes | ForEach-Object { $_.Name })
  $result.package = [ordered]@{
    name = $diaPackage.Name
    version = [string]$diaPackage.Version
    architecture = [string]$diaPackage.Architecture
    publisher = $diaPackage.Publisher
    family_name = $diaPackage.PackageFamilyName
    full_name = $diaPackage.PackageFullName
    signature_kind = [string]$diaPackage.SignatureKind
    status = [string]$diaPackage.Status
    install_location_leaf = Split-Path $diaInstallLocation -Leaf
  }
  $result.manifest = [ordered]@{
    executable = [string]$packageManifest.Package.Applications.Application.Executable
    entry_point = [string]$packageManifest.Package.Applications.Application.EntryPoint
    min_version = [string]$packageManifest.Package.Dependencies.TargetDeviceFamily.MinVersion
    capabilities = $capabilities
    application_extensions = $extensions
    manifest_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
  }

  $diaExe = Join-Path $diaInstallLocation "Dia.exe"
  $arcCore = Join-Path $diaInstallLocation "ArcCore.dll"
  $result.signatures += Signature-Summary $diaExe "installed_Dia.exe"
  $result.signatures += Signature-Summary $arcCore "installed_ArcCore.dll"
  if (($result.signatures | Where-Object { $_.status -ne "Valid" }).Count -ne 0) {
    throw "one or more installed binary signatures are not valid"
  }

  $started = Start-Process -FilePath $diaExe -PassThru
  Start-Sleep -Seconds 20
  $allProcesses = @(Get-CimInstance Win32_Process)
  $packageProcesses = @($allProcesses | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($diaInstallLocation, [StringComparison]::OrdinalIgnoreCase) })
  $packagePids = @($packageProcesses | ForEach-Object { [int]$_.ProcessId })
  $tcp = @()
  if ($packagePids.Count -gt 0) {
    $tcp = @(Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object { $packagePids -contains [int]$_.OwningProcess } | ForEach-Object {
      [ordered]@{
        owning_process = [int]$_.OwningProcess
        state = [string]$_.State
        local_address = $_.LocalAddress
        local_port = [int]$_.LocalPort
        remote_address = $_.RemoteAddress
        remote_port = [int]$_.RemotePort
      }
    })
  }
  $result.launch = [ordered]@{
    start_process_pid = [int]$started.Id
    process_count = $packageProcesses.Count
    processes = @($packageProcesses | ForEach-Object {
      [ordered]@{
        name = $_.Name
        pid = [int]$_.ProcessId
        parent_pid = [int]$_.ParentProcessId
        executable_relative = $_.ExecutablePath.Substring($diaInstallLocation.Length).TrimStart('\')
      }
    })
    tcp_connection_count = $tcp.Count
    tcp_connections = $tcp
    process_still_running_after_20s = [bool](Get-Process -Id $started.Id -ErrorAction SilentlyContinue)
  }

  $firewall = @(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | Where-Object { $_.Program -and $_.Program.StartsWith($diaInstallLocation, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { [ordered]@{ program_leaf=(Split-Path $_.Program -Leaf); instance_id=$_.InstanceID } })
  $services = @(Get-CimInstance Win32_Service | Where-Object { $_.PathName -and $_.PathName.Contains($diaInstallLocation, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { [ordered]@{ name=$_.Name; start_mode=$_.StartMode; state=$_.State } })
  $tasks = @()
  foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
    $matchingActions = @($task.Actions | Where-Object {
      ($_.Execute -and $_.Execute.StartsWith($diaInstallLocation, [StringComparison]::OrdinalIgnoreCase)) -or
      ($_.Arguments -and $_.Arguments.Contains($diaInstallLocation, [StringComparison]::OrdinalIgnoreCase))
    })
    if ($matchingActions.Count -gt 0) {
      $tasks += [ordered]@{ name=$task.TaskName; path=$task.TaskPath; state=[string]$task.State }
    }
  }
  $result.registrations = [ordered]@{
    firewall_application_filters = $firewall
    service_count = $services.Count
    services = $services
    scheduled_task_count = $tasks.Count
    scheduled_tasks = $tasks
    install_acl_sddl = (Get-Acl -LiteralPath $diaInstallLocation).Sddl
  }
}
catch {
  $failed = $true
  $result.failure = [ordered]@{
    exception_type = $_.Exception.GetType().FullName
    message = $_.Exception.Message
    hresult = ('0x{0:X8}' -f ($_.Exception.HResult -band 0xffffffffL))
  }
}
finally {
  try {
    if ($diaPackage) {
      Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($diaInstallLocation, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
      }
      Start-Sleep -Seconds 2
      Remove-AppxPackage -Package $diaPackage.PackageFullName -AllUsers:$false -ErrorAction Stop
    }
    if ($installedDependencyByRun -and $dependencyInstalledFullName) {
      Remove-AppxPackage -Package $dependencyInstalledFullName -AllUsers:$false -ErrorAction Stop
    }
    $family = if ($diaPackage) { $diaPackage.PackageFamilyName } else { "TheBrowserCompany.Dia_ttt1ap7aakyb4" }
    $cleanupCandidates = @(
      (Join-Path $env:LOCALAPPDATA "Packages\$family"),
      (Join-Path $env:LOCALAPPDATA "The Browser Company\Dia"),
      (Join-Path $env:LOCALAPPDATA "TheBrowserCompany\Dia"),
      (Join-Path $env:LOCALAPPDATA "Dia"),
      (Join-Path $env:APPDATA "The Browser Company\Dia"),
      (Join-Path $env:APPDATA "Dia")
    )
    foreach ($candidate in $cleanupCandidates) {
      $existedBefore = if ($baselineProfile.ContainsKey($candidate)) { [bool]$baselineProfile[$candidate] } else { $false }
      if (-not $existedBefore -and (Test-Path -LiteralPath $candidate)) {
        Remove-Item -LiteralPath $candidate -Recurse -Force
      }
    }
    $remainingCandidates = @($cleanupCandidates | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Split-Path $_ -Leaf })
    $diaCountAfter = @(Get-AppxPackage -Name "TheBrowserCompany.Dia" -ErrorAction SilentlyContinue).Count
    $dependencyCountAfter = @(Get-AppxPackage -Name "Microsoft.VCLibs.140.00.UWPDesktop" -ErrorAction SilentlyContinue).Count
    $packageProcessCountAfter = if ($diaInstallLocation) { @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($diaInstallLocation, [StringComparison]::OrdinalIgnoreCase) }).Count } else { 0 }
    $firewallFilterCountAfter = if ($diaInstallLocation) { @(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | Where-Object { $_.Program -and $_.Program.StartsWith($diaInstallLocation, [StringComparison]::OrdinalIgnoreCase) }).Count } else { 0 }
    $dependencyBaselineCount = if ($result.baseline) { $result.baseline.dependency_package_count } else { $null }
    $cleanupPassed = ($diaCountAfter -eq 0) -and ($packageProcessCountAfter -eq 0) -and ($remainingCandidates.Count -eq 0) -and ($dependencyCountAfter -eq $dependencyBaselineCount)
    $result.cleanup = [ordered]@{
      dia_package_count_after = $diaCountAfter
      dependency_count_after = $dependencyCountAfter
      dependency_baseline_count = $dependencyBaselineCount
      package_process_count_after = $packageProcessCountAfter
      firewall_application_filter_count_after = $firewallFilterCountAfter
      residual_new_profile_candidate_count = $remainingCandidates.Count
      residual_new_profile_candidate_leaves = $remainingCandidates
      cleanup_gate_passed = $cleanupPassed
    }
    if (-not $cleanupPassed) { $failed = $true }
  }
  catch {
    $failed = $true
    $result.cleanup = [ordered]@{
      cleanup_error_type = $_.Exception.GetType().FullName
      cleanup_error = $_.Exception.Message
    }
  }
  $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $evidence "runtime-result.json") -Encoding utf8
  Get-ChildItem -LiteralPath $evidence -File | ForEach-Object { $_.Attributes = 'Normal' }
  if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Recurse -Force }
}

Write-Host (ConvertTo-Json ([ordered]@{
  failure = $result.failure
  package_version = if ($result.package) { $result.package.version } else { $null }
  source_signatures_valid = @($result.signatures | Where-Object { $_.status -eq "Valid" }).Count
  process_count = if ($result.launch) { $result.launch.process_count } else { 0 }
  cleanup = $result.cleanup
}) -Depth 6 -Compress)
if ($failed) { exit 1 }
