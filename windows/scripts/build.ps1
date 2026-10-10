param(
    [switch]$Installer,
    [string]$CertificateThumbprint = "",
    [switch]$RequireSigning,
    [string]$ArtifactSigningMetadata = "",
    [string]$ArtifactSigningDlib = "",
    [string]$SignToolPath = "signtool.exe"
)
$ErrorActionPreference = 'Stop'
# Fail before touching existing artifacts when release signing is incomplete.
$cloudSigning = $ArtifactSigningMetadata -ne "" -or $ArtifactSigningDlib -ne ""
$signing = $CertificateThumbprint -ne "" -or $cloudSigning
if ($RequireSigning -and -not $signing) { throw 'Release signing is required. Supply a certificate thumbprint or an Artifact Signing metadata/Dlib pair.' }
if ($CertificateThumbprint -and $cloudSigning) { throw 'Choose one signing provider, not both.' }
if ($cloudSigning -and (-not $ArtifactSigningMetadata -or -not $ArtifactSigningDlib)) { throw 'Artifact Signing requires both metadata and the x64 Dlib path.' }
if ($signing) {
    $SignToolPath = (Get-Command $SignToolPath -ErrorAction Stop).Source
    if ($cloudSigning) {
        $ArtifactSigningMetadata = (Resolve-Path $ArtifactSigningMetadata -ErrorAction Stop).Path
        $ArtifactSigningDlib = (Resolve-Path $ArtifactSigningDlib -ErrorAction Stop).Path
        $metadata = Get-Content $ArtifactSigningMetadata -Raw | ConvertFrom-Json
        if (-not $metadata.Endpoint -or -not $metadata.CodeSigningAccountName -or -not $metadata.CertificateProfileName) {
            throw 'Artifact Signing metadata must name the endpoint, signing account and certificate profile.'
        }
    }
}
$signHelper = Join-Path $PSScriptRoot 'sign-artifact.ps1'
$signArguments = @{ SignToolPath = $SignToolPath }
if ($cloudSigning) {
    $signArguments.ArtifactSigningMetadata = $ArtifactSigningMetadata
    $signArguments.ArtifactSigningDlib = $ArtifactSigningDlib
} elseif ($CertificateThumbprint) {
    $signArguments.CertificateThumbprint = $CertificateThumbprint
}
function Protect-Artifact([string]$Path) {
    & $signHelper -Path $Path @signArguments
}
# Inno expands $q as a quote and $f as its quoted target filename.
function ConvertTo-InnoQuoted([string]$Value) {
    if ($Value.Contains('"')) { throw 'Signing paths must not contain quotes.' }
    return '$q' + $Value.Replace('$', '$$') + '$q'
}
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    dotnet test tests/YaprFlow.Tests/YaprFlow.Tests.csproj -c Release --logger "trx;LogFileName=tests.trx"
    if ($LASTEXITCODE -ne 0) { throw 'Behavior tests failed.' }
    $publish = Join-Path $root 'artifacts/publish'
    if (Test-Path $publish) { Remove-Item -Recurse -Force $publish }
    dotnet publish src/YaprFlow.Windows/YaprFlow.Windows.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false -o $publish
    if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed.' }
    # Keep the native inference DLLs adjacent to the executable. No Python,
    # CUDA, developer SDK, or separate .NET install is needed by the user.
    foreach ($required in @('yaprflow.exe', 'sherpa-onnx-c-api.dll', 'onnxruntime.dll')) {
        if (-not (Test-Path (Join-Path $publish $required))) { throw "Publish is missing $required" }
    }
    if ($signing) {
        # Sign our managed assemblies as well as the executable before packaging.
        foreach ($file in (Get-ChildItem $publish -File | Where-Object { $_.Name -eq 'yaprflow.exe' -or $_.Name -eq 'yaprflow.dll' -or $_.Name -like 'YaprFlow.*.dll' })) {
            Protect-Artifact $file.FullName
        }
    }
    $zip = Join-Path $root 'artifacts/yaprflow-0.2.2-windows-x64-preview.zip'
    Compress-Archive -Path "$publish/*" -DestinationPath $zip -Force
    if ($Installer) {
        $compiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
        if (-not (Test-Path $compiler)) { $compiler = Join-Path $env:LOCALAPPDATA 'Programs/Inno Setup 6/ISCC.exe' }
        if (-not (Test-Path $compiler)) { throw 'Install Inno Setup 6 to build the setup executable.' }
        $compilerArguments = @()
        if ($signing) {
            $command = 'powershell.exe -NoProfile -File ' + (ConvertTo-InnoQuoted $signHelper) + ' -Path $f'
            foreach ($key in $signArguments.Keys) {
                $command += ' -' + $key + ' ' + (ConvertTo-InnoQuoted $signArguments[$key])
            }
            $compilerArguments += '/DSigningEnabled=1'
            $compilerArguments += '/Syaprflow=' + $command
        }
        & $compiler @compilerArguments (Join-Path $root 'installer/yaprflow.iss')
        if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
        if ($signing) {
            & $signHelper -Path (Join-Path $root 'artifacts/yaprflow-0.2.2-windows-x64-preview-setup.exe') -VerifyOnly @signArguments
        }
    }
    Get-ChildItem (Join-Path $root 'artifacts') -File | Where-Object { $_.Extension -in '.exe', '.zip' } |
        ForEach-Object { $h = Get-FileHash $_.FullName -Algorithm SHA256; "$($h.Hash.ToLower())  $($_.Name)" } |
        Set-Content (Join-Path $root 'artifacts/SHA256SUMS.txt')
} finally { Pop-Location }
