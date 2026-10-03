# Shared Windows orchestration. Results use a platform-neutral, versioned schema.
Set-StrictMode -Version Latest
$script:TargetRepo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:TargetCppPin = '507ed9d840c01a3c5b2a39af8bb4000bfac30bf5'

function Save-TargetJson($Value, [string]$Path) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 70), [Text.UTF8Encoding]::new($false))
}

function Invoke-TargetProcess([string]$Exe, [string[]]$Arguments, [string]$LogPrefix = '', [int]$TimeoutSeconds = 7200) {
    $si = [Diagnostics.ProcessStartInfo]::new()
    $si.FileName = $Exe; $si.WorkingDirectory = $script:TargetRepo
    $si.UseShellExecute = $false; $si.CreateNoWindow = $true
    $si.RedirectStandardOutput = $true; $si.RedirectStandardError = $true
    if ($null -eq $si.ArgumentList) { throw 'PowerShell 7 or newer is required.' }
    if ($Exe -eq $env:ComSpec) {
        # cmd's /c command is shell source, not an argv element. ArgumentList
        # adds C-runtime escapes that cmd does not understand around quoted paths.
        $si.Arguments = '/d /s /c "' + $Arguments[-1] + '"'
    } else { foreach ($a in $Arguments) { $si.ArgumentList.Add($a) } }
    $p = [Diagnostics.Process]::new(); $p.StartInfo = $si
    $memory = [Collections.Generic.List[object]]::new()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $p.Start()) { throw "Cannot start $Exe" }
        $stdout = $p.StandardOutput.ReadToEndAsync(); $stderr = $p.StandardError.ReadToEndAsync()
        while (-not $p.WaitForExit(5000)) {
            $p.Refresh()
            $memory.Add(@{ seconds = $watch.Elapsed.TotalSeconds; private_bytes = $p.PrivateMemorySize64; working_set_bytes = $p.WorkingSet64; cpu_seconds = $p.TotalProcessorTime.TotalSeconds })
            if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
                $p.Kill($true) # Only this runner's owned child; never another Godot/editor.
                throw "Owned validation process timed out after $TimeoutSeconds seconds."
            }
        }
        $out = $stdout.GetAwaiter().GetResult(); $err = $stderr.GetAwaiter().GetResult()
        if ($LogPrefix) {
            [IO.File]::WriteAllText("$LogPrefix.stdout.log", $out, [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText("$LogPrefix.stderr.log", $err, [Text.UTF8Encoding]::new($false))
            Save-TargetJson @($memory.ToArray()) "$LogPrefix.process_memory.json"
        }
        return @{ exit_code = $p.ExitCode; stdout = $out; stderr = $err; seconds = $watch.Elapsed.TotalSeconds; process_memory = @($memory.ToArray()) }
    } finally { $p.Dispose() }
}

function Find-TargetGodot([string]$Requested) {
    if ($Requested) { return (Resolve-Path -LiteralPath $Requested).Path }
    foreach ($name in @('godot', 'godot.exe', 'Godot_v4.7.1-stable_win64_console.exe')) {
        $c = Get-Command $name -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    foreach ($dir in @($script:TargetRepo, (Split-Path $script:TargetRepo -Parent))) {
        $c = Get-ChildItem -LiteralPath $dir -Filter 'Godot_v4.7.1*win64*.exe' -File | Sort-Object Name | Select-Object -First 1
        if ($c) { return $c.FullName }
    }
    throw 'Godot 4.7.1 not found. Pass -GodotExe with its executable path.'
}

function Get-TargetEnvironment([string]$GodotExe, [string]$PythonExe, [string]$OutputDirectory) {
    $godot = Find-TargetGodot $GodotExe
    $v = Invoke-TargetProcess $godot @('--version')
    if ($v.exit_code -ne 0 -or $v.stdout.Trim() -notmatch '^4\.7\.1(\.|$)') { throw "Godot must be 4.7.1: $($v.stdout)" }
    $cpp = Join-Path $script:TargetRepo 'addons/ocean/physics/native/godot-cpp'
    if (-not (Test-Path -LiteralPath $cpp)) {
        $clone = Invoke-TargetProcess 'git' @('clone', '--branch', '10.0.0-stable', '--depth', '1', 'https://github.com/godotengine/godot-cpp.git', $cpp) (Join-Path $OutputDirectory 'dependency')
        if ($clone.exit_code) { throw 'Pinned godot-cpp clone failed; see dependency logs.' }
    }
    if (-not (Test-Path (Join-Path $cpp '.git'))) { throw 'Existing godot-cpp directory has no Git metadata; cannot verify its pin. Preserve it and bootstrap a verified checkout explicitly.' }
    $pin = Invoke-TargetProcess 'git' @('-C', $cpp, 'rev-parse', 'HEAD')
    if ($pin.exit_code -ne 0 -or $pin.stdout.Trim() -ne $script:TargetCppPin) { throw "Wrong godot-cpp checkout; expected $script:TargetCppPin. Existing checkout is never switched silently." }
    $dirty = Invoke-TargetProcess 'git' @('-C', $cpp, 'status', '--porcelain', '--untracked-files=no')
    if ($dirty.exit_code -ne 0 -or $dirty.stdout.Trim()) { throw 'Pinned godot-cpp has modified tracked source.' }
    $ignored = Invoke-TargetProcess 'git' @('check-ignore', '-v', 'addons/ocean/physics/native/godot-cpp/SConstruct')
    if ($ignored.exit_code) { throw 'godot-cpp must be ignored by Git.' }
    if (-not (Test-Path (Join-Path $cpp '.gdignore'))) { [IO.File]::WriteAllText((Join-Path $cpp '.gdignore'), 'Local third-party checkout; excluded from Godot scanning.') }
    # SConstruct also accepts this environment override. Pin it to the checkout
    # just verified, so an inherited user variable cannot redirect the build.
    [Environment]::SetEnvironmentVariable('GODOT_CPP_PATH',$cpp,'Process')
    $buildFile = Join-Path $script:TargetRepo 'addons/ocean/physics/native/ocean_query/SConstruct'
    if ((Get-Content -Raw $buildFile) -notmatch '"api_version":\s*"4\.7"') { throw 'SConstruct no longer pins API 4.7.' }
    $candidates = [Collections.Generic.List[string]]::new()
    if ($PythonExe) { $candidates.Add((Resolve-Path $PythonExe).Path) }
    else {
        foreach ($name in @('python', 'python3')) { $c = Get-Command $name -ErrorAction SilentlyContinue; if ($c -and $c.Source -notmatch 'WindowsApps') { $candidates.Add($c.Source) } }
        $launcher = Get-Command py -ErrorAction SilentlyContinue
        if ($launcher) { $p = Invoke-TargetProcess $launcher.Source @('-3', '-c', 'import sys; print(sys.executable)'); if (-not $p.exit_code) { $candidates.Add($p.stdout.Trim()) } }
        foreach ($pattern in @("$env:LOCALAPPDATA\Programs\Python\Python*\python.exe", "$env:LOCALAPPDATA\*python*\Scripts\python.exe")) {
            foreach ($p in @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue)) { $candidates.Add($p.FullName) }
        }
    }
    $python = ''; $pv = ''; $sv = ''
    foreach ($p in $candidates) {
        try { $a = Invoke-TargetProcess $p @('--version'); $b = Invoke-TargetProcess $p @('-m', 'SCons', '--version') } catch { continue }
        if (-not $a.exit_code -and -not $b.exit_code -and $a.stdout -match '^Python 3\.' -and $b.stdout -match 'SCons:\s*v4\.11\.1') { $python=$p; $pv=$a.stdout.Trim(); $sv='4.11.1'; break }
    }
    if (-not $python) { throw 'Working Python 3 with SCons 4.11.1 not found. Install SCons explicitly with python -m pip install scons==4.11.1, or pass -PythonExe. No toolchain packages are silently installed.' }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (-not (Test-Path $vswhere)) { throw 'VS Installer/vswhere is unavailable; install the C++ Build Tools explicitly.' }
    # Discover every installed VS/Build Tools generation, then select by the
    # compiler capability required by this build rather than product branding.
    $vs = Invoke-TargetProcess $vswhere @('-products','*','-requires','Microsoft.VisualStudio.Component.VC.Tools.x86.x64','-format','json')
    if ($vs.exit_code -ne 0) { throw "vswhere could not enumerate Visual Studio installations: $($vs.stderr)" }
    $install = ''; $toolset = ''; $vcvars = ''; $vsProduct = ''; $vsVersion = ''
    $instances = @($vs.stdout | ConvertFrom-Json | Sort-Object `
        @{ Expression = { try { [version]$_.installationVersion } catch { [version]'0.0' } }; Descending = $true },
        @{ Expression = { $_.installationPath }; Descending = $false })
    foreach ($i in $instances) {
        $t = Join-Path $i.installationPath 'VC/Tools/MSVC/14.44.35207'
        $vcvarsCandidate = Join-Path $i.installationPath 'VC/Auxiliary/Build/vcvars64.bat'
        if ((Test-Path -LiteralPath $t -PathType Container) -and (Test-Path -LiteralPath $vcvarsCandidate -PathType Leaf)) {
            $install=$i.installationPath; $toolset=$t; $vcvars=$vcvarsCandidate
            $vsProduct=$i.displayName; $vsVersion=$i.installationVersion
            break
        }
    }
    if (-not $install) { throw 'No installed Visual Studio/Build Tools instance contains required MSVC toolset 14.44.35207 and VC/Auxiliary/Build/vcvars64.bat.' }
    if ($vcvars -match '[&|<>^%\r\n]') { throw 'Unsupported shell metacharacter in VS installation path.' }
    $dev = Invoke-TargetProcess $env:ComSpec @('/d','/s','/c', ('call "{0}" 10.0.26100.0 -vcvars_ver=14.44 >nul && set' -f $vcvars))
    if ($dev.exit_code) { throw 'MSVC x64 developer environment failed to initialize.' }
    foreach ($line in $dev.stdout -split '\r?\n') {
        if ($line -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') }
    }
    $cl = (Get-Command cl.exe).Source
    if ($cl -ne (Join-Path $toolset 'bin/Hostx64/x64/cl.exe')) { throw "Unexpected compiler selected: $cl" }
    $compiler = Invoke-TargetProcess $cl @('/Bv')
    if (($compiler.stdout+$compiler.stderr) -notmatch '19\.44\.\d+') { throw 'Compiler version must be 19.44.' }
    $compilerVersion = $matches[0]
    if ($env:WindowsSDKVersion.TrimEnd('\') -ne '10.0.26100.0') { throw "Unexpected Windows SDK $env:WindowsSDKVersion" }
    foreach ($sdkFile in @('Include/10.0.26100.0/um/Windows.h','Lib/10.0.26100.0/um/x64/kernel32.lib')) {
        if (-not (Test-Path (Join-Path $env:WindowsSdkDir $sdkFile))) { throw "SDK component missing: $sdkFile" }
    }
    $os=$null; $cpu=@(); $gpu=@(); $ram=$null; $power=$null; $warnings=@()
    try {
        $os=Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber
        $cpu=@(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed)
        $gpu=@(Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion)
        $ram=(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    } catch { $warnings+='CIM hardware inventory unavailable: '+$_.Exception.Message }
    try { $power=@(Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus | Select-Object PowerOnline) } catch { $warnings+='AC/battery state unavailable.' }
    $scheme=Invoke-TargetProcess 'powercfg.exe' @('/getactivescheme')
    $head=Invoke-TargetProcess 'git' @('rev-parse','HEAD')
    $branch=Invoke-TargetProcess 'git' @('branch','--show-current')
    $status=Invoke-TargetProcess 'git' @('status','--porcelain')
    $contract=(Get-Content (Join-Path $PSScriptRoot 'phys_native_build_contract.gd') -Raw)
    if ($contract -notmatch 'const ID := "([^"]+)"') { throw 'Cannot read native source build ID contract.' }
    $id=$matches[1]
    $exact = (@($cpu | Where-Object Name -Match 'i7-13650HX').Count -gt 0) -and (@($gpu | Where-Object Name -Match 'RTX\s*4070.*Laptop').Count -gt 0)
    return [ordered]@{ schema_version=1; captured_utc=[DateTime]::UtcNow.ToString('o'); cpu=$cpu; gpu=$gpu; os=$os; ram_bytes=$ram; battery=$power;
        power_scheme=$scheme.stdout.Trim(); temperatures='unavailable'; asus_profile='unavailable'; hybrid_core_types='unavailable';
        is_exact_target=$exact; godot=$v.stdout.Trim(); godot_executable=$godot; python=$pv; python_executable=$python; scons=$sv;
        visual_studio_product=$vsProduct; visual_studio_version=$vsVersion; visual_studio_installation=$install; vcvars=$vcvars;
        msvc=$compilerVersion; cl=$cl; toolset='14.44.35207'; toolset_path=$toolset; windows_sdk='10.0.26100.0';
        godot_cpp_commit=$pin.stdout.Trim(); godot_cpp_tag='10.0.0-stable'; api_version='4.7'; render_backend='Forward+ / D3D12 requested; runtime checked separately';
        source_commit=$head.stdout.Trim(); branch=$branch.stdout.Trim(); working_tree=$status.stdout.Trim(); expected_native_build_id=$id; warnings=$warnings }
}

function Build-TargetNative($Environment, [string]$OutputDirectory, [switch]$SkipBuild) {
    $native=Join-Path $script:TargetRepo 'addons/ocean/physics/native/ocean_query'
    $dll=Join-Path $native 'bin/ocean_query_native.windows.template_release.x86_64.dll'
    $manifest=Join-Path $script:TargetRepo '.godot/target_validation/native_build_manifest.json'
    $sourceFiles=@(Get-ChildItem (Join-Path $native 'src') -File -Recurse | Where-Object Extension -In '.cpp','.h') + @(Get-Item (Join-Path $native 'SConstruct'),(Join-Path $native 'ocean_query_native.gdextension.template'))
    $sourceHashes=@($sourceFiles | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($native.Length)+':'+(Get-FileHash $_.FullName -Algorithm SHA256).Hash })
    $fingerprint=$sourceHashes -join "`n"
    if ($SkipBuild) {
        if (-not (Test-Path $manifest) -or -not (Test-Path $dll)) { throw 'SkipBuild requires a prior clean build manifest from this runner.' }
        $proof=Get-Content -Raw $manifest | ConvertFrom-Json -AsHashtable
        if($proof.source_fingerprint -ne $fingerprint -or $proof.dll_sha256 -ne (Get-FileHash $dll -Algorithm SHA256).Hash -or $proof.dependency -ne $script:TargetCppPin) { throw 'SkipBuild rejected: source/dependency/DLL no longer matches the verified clean build.' }
    }
    if (-not $SkipBuild) {
        if (Test-Path $dll) {
            try { $file=[IO.File]::Open($dll,'Open','ReadWrite','None'); $file.Dispose() }
            catch { throw 'Native DLL is locked. Close the Godot/editor using this checkout and retry. This runner will not kill unrelated processes.' }
        }
        $base=@('-m','SCons','-C',$native,'platform=windows','arch=x86_64','target=template_release')
        # SCons -c follows the godot-cpp dependency graph and removes bindings.
        # Clean only this extension's regenerable objects/library/descriptor.
        $cleanFiles=@()
        $objectDir=Join-Path $native 'build/obj'
        if(Test-Path $objectDir) { $cleanFiles+=@(Get-ChildItem -LiteralPath $objectDir -File | Where-Object { $_.Name -like '*template_release*x86_64*' } | ForEach-Object FullName) }
        foreach($relative in @('bin/ocean_query_native.windows.template_release.x86_64.dll','bin/ocean_query_native.windows.template_release.x86_64.lib','bin/ocean_query_native.windows.template_release.x86_64.exp','ocean_query_native.gdextension')) {
            $path=Join-Path $native $relative
            if(Test-Path $path) { $cleanFiles+=$path }
        }
        foreach($path in $cleanFiles) {
            $resolved=[IO.Path]::GetFullPath($path)
            if(-not $resolved.StartsWith($native+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Native clean escaped its directory.' }
            Remove-Item -LiteralPath $resolved -Force
        }
        Save-TargetJson @{ removed=$cleanFiles; dependency_products_preserved=$true } (Join-Path $OutputDirectory 'native_clean.json')
        $build=Invoke-TargetProcess $Environment.python_executable ($base+@('-j','6')) (Join-Path $OutputDirectory 'native_build')
        if ($build.exit_code) { throw 'Native build/link failed; inspect native_build logs.' }
    }
    if (-not (Test-Path $dll)) { throw 'Native DLL is missing.' }
    $descriptor=Join-Path $native 'ocean_query_native.gdextension'
    $text=Get-Content $descriptor -Raw
    if ($text -notmatch 'entry_symbol\s*=\s*"ocean_query_native_library_init"' -or $text -notmatch 'windows\.x86_64\s*=\s*"res://addons/ocean/physics/native/ocean_query/bin/ocean_query_native.windows.template_release.x86_64.dll"') { throw 'Generated GDExtension mapping is invalid.' }
    $hash=(Get-FileHash $dll -Algorithm SHA256).Hash
    if(-not $SkipBuild) {
        New-Item -ItemType Directory (Split-Path $manifest -Parent) -Force | Out-Null
        Save-TargetJson @{ source_fingerprint=$fingerprint; dll_sha256=$hash; dependency=$script:TargetCppPin; source_commit=$Environment.source_commit; toolset=$Environment.toolset; sdk=$Environment.windows_sdk } $manifest
    }
    return @{ clean_rebuilt=(-not $SkipBuild); skipped=[bool]$SkipBuild; source_proven=$true; dll=$dll; bytes=(Get-Item $dll).Length; sha256=$hash; descriptor=$descriptor; expected_build_id=$Environment.expected_native_build_id }
}
