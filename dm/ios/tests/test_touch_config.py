"""Compile the real touch configuration on macOS with in-memory preferences."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[3]
SOURCES = REPO / 'dm/ios/Sources'


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'needs the macOS Clang toolchain')
class TouchConfigTests(unittest.TestCase):
    def test_profiles_validation_response_curves_and_layout_styles(self):
        with tempfile.TemporaryDirectory(prefix='nxnative-touch-config-') as tmp:
            tmp = Path(tmp)
            exe = tmp / 'touch_config_check'
            compile_result = subprocess.run([
                'xcrun', '--sdk', 'macosx', 'clang',
                '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                '-I', str(SOURCES), str(SOURCES / 'DmTouchConfig.m'),
                str(Path(__file__).with_name('touch_config_check.m')),
                '-framework', 'Foundation', '-framework', 'CoreGraphics',
                '-o', str(exe),
            ], cwd=tmp, capture_output=True, text=True, timeout=120)
            self.assertEqual(compile_result.returncode, 0, compile_result.stdout + compile_result.stderr)
            result = subprocess.run([str(exe)], cwd=tmp, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertRegex(result.stdout, r'^touch_config: [1-9]\d* checks passed; preferences remained in memory only\n$')


if __name__ == '__main__':
    unittest.main()
