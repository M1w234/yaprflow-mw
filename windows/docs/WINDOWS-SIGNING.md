# Windows publisher signing

Status, September 30, 2026: the installed 0.2.1 preview is unsigned. The AMD test PC has no code-signing certificate in its user or machine certificate stores. Signing support is prepared, but no successful publisher signing has been performed. Do not publish an artifact based only on preflight tests.

## Choose an existing certificate or Microsoft Artifact Signing

An existing trusted code-signing certificate can be selected from the current-user certificate store by thumbprint. Its private key must be accessible to SignTool (including any provider/hardware authentication).

Microsoft Artifact Signing (formerly Trusted Signing) is the cloud alternative. Its Basic plan is listed at $9.99/month for 5,000 signatures, with additional signatures billed separately. Confirm current pricing before purchase. An Azure subscription, Microsoft Entra tenant, signing account, identity validation, Public Trust certificate profile and Certificate Profile Signer role are required. US individual developers are eligible; identity validation and the publisher identity must be completed by the account owner. Do not put identity documents or credentials in this repository.

- [Product and pricing FAQ](https://azure.microsoft.com/en-us/products/artifact-signing)
- [Account and identity setup](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart)
- [Supported signing integrations and prerequisites](https://learn.microsoft.com/en-us/azure/artifact-signing/how-to-signing-integrations)

Creating paid resources and selecting the public publisher identity require Michael's approval. No Azure resource has been created by this change.

## Prepare a Windows signing host

Follow the official integration requirements for SignTool, the Artifact Signing client, .NET runtime and Visual C++ runtime. Use the x64 SignTool and x64 `Azure.CodeSigning.Dlib.dll`. Authentication uses the supported Azure credential chain; credentials stay outside the source tree. Create a local metadata JSON using the actual account's regional endpoint:

```json
{
  "Endpoint": "<regional signing endpoint>",
  "CodeSigningAccountName": "<account name>",
  "CertificateProfileName": "<Public Trust profile name>"
}
```

The application build also needs the .NET 10 SDK and Inno Setup 6. These are build-host requirements, not end-user requirements.

## Build with signing required

From the repository root, use one provider:

```powershell
# Existing trusted certificate in the current-user store:
./windows/scripts/build.ps1 -Installer -RequireSigning `
  -CertificateThumbprint '<thumbprint>' `
  -SignToolPath 'C:\path\to\x64\signtool.exe'

# Microsoft Artifact Signing:
./windows/scripts/build.ps1 -Installer -RequireSigning `
  -ArtifactSigningMetadata 'C:\private-build-config\signing.json' `
  -ArtifactSigningDlib 'C:\path\to\x64\Azure.CodeSigning.Dlib.dll' `
  -SignToolPath 'C:\path\to\x64\signtool.exe'
```

The script signs yaprflow.exe, yaprflow.dll and YaprFlow assemblies before packaging, then signs the setup executable. Each signature must pass SignTool verification and Windows Authenticode validation and include a timestamp. Signing errors stop the build. A timestamp is especially important for Artifact Signing's short-lived certificates. Dependencies retain their upstream signatures or unsigned status. The generated Inno uninstaller is not separately signed by this script; verify and address that before final public packaging.

Unsigned private CI previews remain supported by omitting signing arguments. `-RequireSigning` is mandatory for a public candidate. Artifact names intentionally still say preview; adding a signature does not authorize a public release.

## Verification and remaining release work

`./windows/scripts/test-signing-preflight.ps1` verifies four invalid configurations are refused before compilation or artifact replacement. It passed on the AMD Windows PC on September 30, 2026. It does not test a real certificate, cloud authentication, timestamp service or successful signing.

For the first signed build:

1. Verify the expected publisher, trusted signature and timestamp on the app and setup executable. Retain verification output and final SHA-256 checksums.
2. Download that exact candidate through its intended delivery path on a normal Windows account. Inspect publisher prompts and install, upgrade and uninstall behavior. Signing does not guarantee immediate SmartScreen reputation.
3. Confirm preferences, history, vocabulary, custom sounds and downloaded models survive upgrade; complete the hardware acceptance checklist.
4. Review the final candidate and approve publication separately. Do not reuse hashes from the unsigned preview.
