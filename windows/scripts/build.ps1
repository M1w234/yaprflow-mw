param(
    [switch]$Installer,
    [string]$CertificateThumbprint = ""
)
$ErrorActionPreference = 'Stop'
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
    if ($CertificateThumbprint) {
        & signtool sign /sha1 $CertificateThumbprint /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 (Join-Path $publish 'yaprflow.exe')
        if ($LASTEXITCODE -ne 0) { throw 'Application signing failed.' }
    }
    $zip = Join-Path $root 'artifacts/yaprflow-0.1.1-windows-x64-preview.zip'
    Compress-Archive -Path "$publish/*" -DestinationPath $zip -Force
    if ($Installer) {
        $compiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
        if (-not (Test-Path $compiler)) { throw 'Install Inno Setup 6 to build the setup executable.' }
        & $compiler (Join-Path $root 'installer/yaprflow.iss')
        if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
        if ($CertificateThumbprint) {
            & signtool sign /sha1 $CertificateThumbprint /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 (Join-Path $root 'artifacts/yaprflow-0.1.1-windows-x64-preview-setup.exe')
            if ($LASTEXITCODE -ne 0) { throw 'Installer signing failed.' }
        }
    }
    Get-ChildItem (Join-Path $root 'artifacts') -File | Where-Object { $_.Extension -in '.exe', '.zip' } |
        ForEach-Object { $h = Get-FileHash $_.FullName -Algorithm SHA256; "$($h.Hash.ToLower())  $($_.Name)" } |
        Set-Content (Join-Path $root 'artifacts/SHA256SUMS.txt')
} finally { Pop-Location }
