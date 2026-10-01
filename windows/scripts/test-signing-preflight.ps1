$ErrorActionPreference = 'Stop'
$build = Join-Path $PSScriptRoot 'build.ps1'
$cases = @(
    @{ Arguments = @{ RequireSigning = $true }; Expected = 'Release signing is required' },
    @{ Arguments = @{ CertificateThumbprint = 'test'; ArtifactSigningMetadata = 'test' }; Expected = 'Choose one signing provider' },
    @{ Arguments = @{ ArtifactSigningMetadata = 'test' }; Expected = 'requires both metadata' },
    @{ Arguments = @{ ArtifactSigningDlib = 'test' }; Expected = 'requires both metadata' }
)
foreach ($case in $cases) {
    $message = ''
    try { $arguments = $case.Arguments; & $build @arguments } catch { $message = $_.Exception.Message }
    if ($message -notlike "*$($case.Expected)*") { throw "Wrong preflight outcome: $message" }
}
'Passed four signing preflight refusal checks. No compilation, artifact replacement or signing attempted.'
