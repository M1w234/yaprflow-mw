param([Parameter(Mandatory=$true)][string]$BundleDir,[Parameter(Mandatory=$true)][string]$OutputDir,[Parameter(Mandatory=$true)][string]$ArtifactSigningMetadata,[Parameter(Mandatory=$true)][string]$ArtifactSigningDlib,[Parameter(Mandatory=$true)][string]$SignToolPath,[string]$Recipe=(Join-Path $PSScriptRoot '..\installer\deskling.iss'),[string]$SignHelper=(Join-Path $PSScriptRoot 'sign-artifact.ps1'))
$ErrorActionPreference='Stop'
$BundleDir=(Resolve-Path $BundleDir).Path
$SignHelper=(Resolve-Path $SignHelper).Path
$ArtifactSigningMetadata=(Resolve-Path $ArtifactSigningMetadata).Path
$ArtifactSigningDlib=(Resolve-Path $ArtifactSigningDlib).Path
$SignToolPath=(Resolve-Path $SignToolPath).Path
if(!(Test-Path (Join-Path $BundleDir 'tools\gift_setup\installer_hooks.py'))){throw 'Shared source installer hooks missing'}
$installer=Join-Path $BundleDir 'tools\gift_setup\optional\yaprflow-setup.exe'
$s=Get-AuthenticodeSignature $installer
if($s.Status -ne 'Valid' -or !$s.TimeStamperCertificate -or $s.SignerCertificate.GetNameInfo('SimpleName',$false) -ne 'Michael Wong'){throw 'Bundled yaprflow publisher verification failed'}
$expected=(Get-Content (Join-Path $BundleDir 'tools\gift_setup\optional\installer-sha256.txt')).Trim()
if((Get-FileHash $installer -Algorithm SHA256).Hash.ToLower() -ne $expected){throw 'Bundled yaprflow checksum mismatch'}
$compiler=Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
if(!(Test-Path $compiler)){$compiler=Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'}
function Quote-Inno([string]$Value){if($Value.Contains('"')){throw 'Invalid quote in path'};return '$q'+$Value.Replace('$','$$')+'$q'}
$command='powershell.exe -NoProfile -ExecutionPolicy Bypass -File '+(Quote-Inno $SignHelper)+' -Path $f -SignToolPath '+(Quote-Inno $SignToolPath)+' -ArtifactSigningMetadata '+(Quote-Inno $ArtifactSigningMetadata)+' -ArtifactSigningDlib '+(Quote-Inno $ArtifactSigningDlib)
& $compiler ('/DBundleDir='+$BundleDir) ('/DOutputDir='+$OutputDir) ('/Sdeskling='+$command) $Recipe
if($LASTEXITCODE -ne 0){throw 'Deskling installer build failed'}
$file=Join-Path $OutputDir 'Deskling-0.2.2-windows-x64-setup.exe'
& $SignHelper -Path $file -VerifyOnly -SignToolPath $SignToolPath
if($LASTEXITCODE -ne 0){throw 'Deskling signature verification failed'}
(Get-FileHash $file -Algorithm SHA256).Hash.ToLower()+'  '+(Split-Path $file -Leaf) | Set-Content (Join-Path $OutputDir 'SHA256SUMS.txt')
