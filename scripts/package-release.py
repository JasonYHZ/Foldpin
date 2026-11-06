#!/usr/bin/env python3
"""Build an ad-hoc universal release from a frozen working-tree source snapshot."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SKIP = {'.build', '.swiftpm', 'DerivedData', 'xcuserdata', '__pycache__',
        'node_modules', '.git', 'dist'}


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def output(args, **kwargs):
    return run(args, stdout=subprocess.PIPE, **kwargs).stdout.decode().strip()


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def source_files(version):
    files = [ROOT / n for n in ('LICENSE', 'README.md', 'README.zh-CN.md', 'CONTRIBUTING.md',
                               'docs/engineering/distribution.md',
                               f'docs/engineering/release-{version}.md', f'docs/releases/{version}.md')]
    for name in ('macOS', 'scripts'):
        for directory, dirs, names in os.walk(ROOT / name, followlinks=False):
            dirs[:] = sorted(d for d in dirs if d not in SKIP and not d.startswith('.')
                             and not d.endswith(('.xcarchive', '.xcresult')))
            for d in dirs:
                if (Path(directory) / d).is_symlink():
                    raise ValueError(f'Source symlink is not supported: {d}')
            for n in sorted(names):
                if n.startswith('.') or n.endswith(('.pyc', '.xcuserstate')):
                    continue
                path = Path(directory) / n
                if path.is_symlink():
                    raise ValueError(f'Source symlink is not supported: {path.relative_to(ROOT)}')
                files.append(path)
    return sorted(files)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', default='0.1.1')
    parser.add_argument('--build', default='3')
    parser.add_argument('--label', help='Release label; defaults to --version')
    parser.add_argument('--derived-data', type=Path,
                        default=Path(tempfile.gettempdir()) / 'Foldpin-Release-DerivedData')
    args = parser.parse_args()
    args.label = args.label or args.version
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
        parser.error('--version must be three numeric components')
    if not re.fullmatch(r'[1-9]\d*', args.build):
        parser.error('--build must be a positive integer')
    if not re.fullmatch(re.escape(args.version) + r'(?:-[A-Za-z0-9.-]+)?', args.label):
        parser.error('--label must be the version, optionally with a prerelease suffix')
    destination = ROOT / 'dist' / f'Foldpin-{args.label}'
    if destination.exists():
        parser.error(f'Output already exists: {destination}')
    destination.parent.mkdir(exist_ok=True)
    env = os.environ.copy()
    if not env.get('DEVELOPER_DIR') and Path('/Applications/Xcode.app').exists():
        env['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
    try:
        commit = output(['git', '-C', ROOT, 'rev-parse', 'HEAD'], stderr=subprocess.DEVNULL)
        dirty = bool(output(['git', '-C', ROOT, 'status', '--porcelain']))
    except subprocess.CalledProcessError:
        commit, dirty = None, None  # Also buildable from the distributed source ZIP.
    xcode = output(['xcodebuild', '-version'], env=env)
    # Keep the build outside the checkout and map source paths in compiler output.
    # Swift may embed source directories even in optimized release executables.
    with tempfile.TemporaryDirectory(prefix='foldpin-release-', dir='/private/tmp') as work:
        work = Path(work)
        snapshot = work / 'source'
        result = work / 'result'
        result.mkdir()
        hashes = {}
        for path in source_files(args.version):
            relative = path.relative_to(ROOT)
            target = snapshot / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
            hashes[str(relative)] = sha(target)
        command = ['xcodebuild', '-project', 'Foldpin.xcodeproj', '-scheme', 'Foldpin',
                   '-configuration', 'Release', '-destination', 'generic/platform=macOS',
                   '-derivedDataPath', str(args.derived_data.resolve()), 'ARCHS=arm64 x86_64',
                   'ONLY_ACTIVE_ARCH=NO', 'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-',
                   'CODE_SIGN_STYLE=Manual', 'DEVELOPMENT_TEAM=',
                   'CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO',
                   f'OTHER_SWIFT_FLAGS=$(inherited) -file-prefix-map {snapshot}=/Foldpin -debug-prefix-map {snapshot}=/Foldpin',
                   f'OTHER_CFLAGS=$(inherited) -ffile-prefix-map={snapshot}=/Foldpin',
                   f'MARKETING_VERSION={args.version}', f'CURRENT_PROJECT_VERSION={args.build}', 'build']
        print('Building frozen source for arm64 + x86_64…', flush=True)
        log = result / 'build.log'
        with log.open('w') as stream:
            build = subprocess.run(command, cwd=snapshot / 'macOS', env=env,
                                   stdout=stream, stderr=subprocess.STDOUT)
        if build.returncode:
            failure = destination.parent / f'Foldpin-{args.label}-failed-build.log'
            shutil.copy2(log, failure)
            raise RuntimeError(f'Build failed; see {failure}')
        app = args.derived_data.resolve() / 'Build/Products/Release/Foldpin.app'
        architectures = output(['lipo', '-archs', app / 'Contents/MacOS/Foldpin']).split()
        if set(architectures) != {'arm64', 'x86_64'}:
            raise RuntimeError(f'Unexpected architectures: {architectures}')
        if re.search(rb'/Users/[^/\x00\s]+/', (app / 'Contents/MacOS/Foldpin').read_bytes()):
            raise RuntimeError('Release executable contains a personal home-directory path')
        run(['codesign', '--verify', '--deep', '--strict', app])
        entitlements = plistlib.loads(run(['codesign', '--display', '--entitlements', '-',
                                          '--xml', app], stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE).stdout)
        required = ('app-sandbox', 'device.audio-input', 'files.user-selected.read-write',
                    'files.bookmarks.app-scope', 'network.client', 'network.server')
        if entitlements.get('com.apple.security.get-task-allow') or not all(
                entitlements.get('com.apple.security.' + key) is True for key in required):
            raise RuntimeError(f'Unexpected entitlements: {entitlements}')
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if (info['CFBundleShortVersionString'], info['CFBundleVersion']) != (args.version, args.build):
            raise RuntimeError('Version does not match requested release')
        if (app / 'Contents/Resources/LICENSE.txt').read_bytes() != (snapshot / 'LICENSE').read_bytes():
            raise RuntimeError('Application license differs from source license')
        run([sys.executable, snapshot / 'scripts/check-localizations.py', '--app', app], cwd=snapshot)
        metadata = dict(version=args.version, build=args.build, label=args.label,
                        baseCommit=commit, workingTreeDirty=dirty, xcode=xcode,
                        architectures=architectures, minimumMacOS=info['LSMinimumSystemVersion'],
                        signing='ad-hoc; not notarized', sourceSHA256=hashes,
                        buildArguments=command[1:])
        # Absolute local cache paths are not public release metadata.
        metadata['buildArguments'][metadata['buildArguments'].index('-derivedDataPath') + 1] = '<DERIVED_DATA>'
        metadata['buildArguments'] = [arg.replace(str(snapshot), '<SOURCE>')
                                      for arg in metadata['buildArguments']]
        (result / 'build-info.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
        basename = f'Foldpin-{args.label}'
        source_name = f'{basename}-source.zip'
        with zipfile.ZipFile(result / source_name, 'w', zipfile.ZIP_DEFLATED) as archive:
            for relative in hashes:
                archive.write(snapshot / relative, f'{basename}-source/{relative}')
        stage = work / 'installer'
        stage.mkdir()
        run(['ditto', app, stage / 'Foldpin.app'])
        shutil.copy2(snapshot / 'LICENSE', stage / 'LICENSE.txt')
        shutil.copy2(snapshot / 'macOS/Foldpin/ThirdPartyNotices.txt', stage / 'ThirdPartyNotices.txt')
        (stage / 'README.txt').write_text(
            f'Foldpin {args.label} — Universal macOS release\n\n'
            f'Requires macOS {info["LSMinimumSystemVersion"]} or later; Apple Silicon and Intel.\n'
            'Copy Foldpin.app to Applications. Back up your note library before upgrading.\n'
            'Ad-hoc signed, NOT Apple notarized. macOS may block the first launch.\n'
            'After verifying the download source, check System Settings > Privacy & Security\n'
            'for Open Anyway. Do not disable system-wide security protections.\n\n'
            'GPL-3.0-only. Copyright (C) 2026 Foldpin contributors. No warranty.\n'
            f'Corresponding source: {source_name}, distributed alongside this package.\n'
            'Keep the matching source archive available whenever redistributing this binary.\n'
            'Third-party terms remain in ThirdPartyNotices.txt and application resources.\n', encoding='utf-8')
        run(['ditto', '-c', '-k', '--sequesterRsrc', stage, result / f'{basename}-universal.zip'])
        (stage / 'Applications').symlink_to('/Applications')
        run(['hdiutil', 'create', '-quiet', '-volname', 'Foldpin', '-srcfolder', stage,
             '-format', 'UDZO', result / f'{basename}-universal.dmg'])
        run(['hdiutil', 'verify', '-quiet', result / f'{basename}-universal.dmg'])
        artifacts = sorted(p for p in result.iterdir() if p.name != 'build.log')
        (result / 'SHA256SUMS').write_text(''.join(f'{sha(p)}  {p.name}\n' for p in artifacts))
        result.rename(destination)
    print(f'Created {destination}', flush=True)


if __name__ == '__main__':
    main()
