"""Portable version-query regression; no native compiler or artifact emission."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
SUPPORT = SCRIPTS / 'Support' / 'paused-async-context'
VERSION = (SUPPORT / 'expected-swift-version.txt').read_text().strip()
DRIVER = 'swift-driver version: 1.168.6'

def load(path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

class ReachedSDK(Exception):
    """Stop immediately after version validation, before emitting anything."""

class ToolchainQueryTests(unittest.TestCase):
    def validate(self, script, compiler=VERSION, driver=DRIVER, status=0):
        module = load(SUPPORT / 'emit_controls.py' if script == 'emitter'
                      else SCRIPTS / 'inspect-paused-async-contexts.py')
        def run(argv, **kwargs):
            self.assertEqual(list(argv), ['xcrun', 'swiftc', '--version'])
            result = subprocess.CompletedProcess(argv, status, compiler + '\n', driver + ' \n')
            if kwargs.get('check'):
                result.check_returncode()
            return result
        def output(argv, **kwargs):
            if list(argv) == ['xcrun', 'swiftc', '--version']:
                return compiler + '\n'
            if argv[-1] == '--show-sdk-path':
                raise ReachedSDK()
            raise AssertionError('Unsupported toolchain query: ' + str(argv))
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            manifest = directory / 'manifest.json'
            manifest.write_text(json.dumps(dict(schema=1, compiler_version=VERSION,
                driver_version=DRIVER, target='arm64-apple-tvos27.0-simulator')))
            with patch.object(module.subprocess, 'run', side_effect=run), \
                 patch.object(module.subprocess, 'check_output', side_effect=output), \
                 patch('sys.argv', ['emit_controls.py', '--configuration', 'Debug',
                                    '--output', str(directory / 'output')]):
                if script == 'emitter':
                    module.main()
                else:
                    module.artifact_mode(manifest, VERSION)

    def test_valid_separate_streams_reach_sdk(self):
        for script in ('emitter', 'reader'):
            with self.subTest(script=script), self.assertRaises(ReachedSDK):
                self.validate(script)

    def test_unknown_versions_and_diagnostics_reject(self):
        for script in ('emitter', 'reader'):
            for change in (dict(compiler='unknown compiler'), dict(driver='swift-driver version: 1.168.7'),
                           dict(driver=''), dict(driver=DRIVER + '\nerror: invalid driver name')):
                with self.subTest(script=script, change=change), self.assertRaises(RuntimeError):
                    self.validate(script, **change)

    def test_nonzero_exit_rejects_even_matching_text(self):
        for script in ('emitter', 'reader'):
            with self.subTest(script=script), self.assertRaises(subprocess.CalledProcessError):
                self.validate(script, status=1)

if __name__ == '__main__':
    unittest.main()
