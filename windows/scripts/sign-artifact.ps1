param(
    [Parameter(Mandatory)][string]$Path,
    [string]$CertificateThumbprint = '',
    [string]$ArtifactSigningMetadata = '',
    [string]$ArtifactSigningDlib = '',
    [string]$SignToolPath = 'signtool.exe',
    [switch]$VerifyOnly
)
$ErrorActionPreference = 'Stop'
$Path = (Resolve-Path -LiteralPath $Path).Path
$SignToolPath = (Get-Command $SignToolPath -ErrorAction Stop).Source
if (-not $VerifyOnly) {
    $cloud = $ArtifactSigningMetadata -ne '' -or $ArtifactSigningDlib -ne ''
    if ($cloud -and $CertificateThumbprint) { throw 'Choose one signing provider, not both.' }
    if ($cloud) {
        if (-not $ArtifactSigningMetadata -or -not $ArtifactSigningDlib) { throw 'Both metadata and Dlib are required.' }
        & $SignToolPath sign /v /fd SHA256 /tr http://timestamp.acs.microsoft.com /td SHA256 /dlib $ArtifactSigningDlib /dmdf $ArtifactSigningMetadata $Path
    } elseif ($CertificateThumbprint) {
        & $SignToolPath sign /sha1 $CertificateThumbprint /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 $Path
    } else { throw 'A signing provider is required.' }
    if ($LASTEXITCODE -ne 0) { throw "Signing failed: $Path" }
}
& $SignToolPath verify /pa /all /v $Path
if ($LASTEXITCODE -ne 0) { throw "Signature verification failed: $Path" }
$signature = Get-AuthenticodeSignature -LiteralPath $Path
if ($signature.Status -ne 'Valid' -or -not $signature.TimeStamperCertificate) {
    throw "A trusted, timestamped signature is required: $Path"
}
