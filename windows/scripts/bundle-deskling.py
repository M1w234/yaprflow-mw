"""Stage an additive Windows gift candidate from an existing Deskling recipient package.
Never includes user data, auth caches, or an unsigned replacement app.
Signature trust must also be verified on Windows; a hash alone is not publisher trust.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--base', required=True, type=Path)
parser.add_argument('--installer', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
if args.output.exists():
    raise SystemExit('Refusing to overwrite an existing bundle')
if not (args.base / 'runtime/python.exe').is_file():
    raise SystemExit('Expected a complete Windows recipient package')
digest = hashlib.sha256(args.installer.read_bytes()).hexdigest()
package = args.output / 'Deskling-Windows-Candidate'
shutil.copytree(args.base, package, ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '.DS_Store'))
voice = package / 'tools/gift_setup/optional'
voice.mkdir(exist_ok=True)
shutil.copy2(args.installer, voice / 'yaprflow-setup.exe')
(voice / 'installer-sha256.txt').write_text(digest + '\n')
shutil.copy2(Path(__file__).resolve().parents[2] / 'LICENSE', package / 'LICENSE-yaprflow.txt')
backend = package / 'tools/gift_setup/yaprflow.py'
if 'def install_windows(' not in backend.read_text():
    raise SystemExit('Build Deskling from the shared source with Windows voice support first')
(package / 'START-HERE.md').write_text('''# Deskling for Windows — integrated voice candidate

Windows 11 on Intel or AMD x64. Extract this entire folder; do not run from inside the ZIP.

1. Open Start Deskling.cmd and install the PC companion using your own account.
2. Pair the preloaded screen using its displayed setup Wi-Fi and password, then enter your home 2.4 GHz Wi-Fi details. Allow the companion on Private networks only if Windows asks.
3. Return the computer to home Wi-Fi and check the screen connection.
4. Open Voice dictation in Deskling setup. Quit an existing copy before opening the signed installer. Publisher: Michael Wong.
5. Open yaprflow, select the PC microphone, and download its speech model. Keep both apps running. Check yaprflow connection in Deskling setup.
6. Focus a blank editable document on the PC. Use the screen to start/stop dictation or cancel. Ctrl + Alt + Space remains available. Streaming is optional; test with it off first.

Uses your computer’s microphone. Start/Stop/Cancel and toggle recording are supported. Submit is intentionally disabled on Windows: review and send text yourself. Losing the companion connection cancels a recording started by the screen. Audio and transcripts stay on the PC; only coarse state crosses the bridge.

The initial speech download requires internet. Thereafter ordinary dictation is local. Optional AI Polish requires its own model download. Unknown/password fields and changed focus block automatic insertion; recover the text from yaprflow History.

Uninstall yaprflow through Windows Settings; history, settings and models are retained. Remove the Deskling companion separately from its setup page. To gift a previously paired screen, use its Give to someone else flow and follow the operator checklist. Do not distribute personal pairing files or credentials.

Candidate status: software tests and signature verification do not establish physical screen acceptance. Check screen start/stop/cancel, microphone reconnect, offline relaunch and fresh-recipient pairing before gifting. No firmware changes or flashing are performed by this package build. Computer Vitals, Spotify and Follow Mac still require macOS. Windows ARM is not supported.
''')
# Reject accidental recipient-private state in the package.
for p in package.rglob('*'):
    if p.name.lower() in {'.env', 'secrets.h', 'settings.json', 'history.json', 'azure-auth'}:
        raise SystemExit('Unexpected private state: ' + str(p))
files = [{'path': str(p.relative_to(package)), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
         for p in sorted(package.rglob('*')) if p.is_file()]
(args.output / 'manifest.json').write_text(json.dumps({'installerSha256': digest, 'files': files}, indent=2))
archive = args.output / 'Deskling-Windows-yaprflow-0.2.2-candidate.zip'
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
    for p in sorted(package.rglob('*')):
        if p.is_file(): z.write(p, p.relative_to(args.output))
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
(args.output / 'SHA256SUMS.txt').write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n')
print(archive)
