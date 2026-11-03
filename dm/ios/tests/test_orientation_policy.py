"""Keep the production and harness phone/iPad orientation contracts aligned."""
import re
import unittest
from pathlib import Path

IOS = Path(__file__).resolve().parents[1]


class OrientationPolicyTests(unittest.TestCase):
    def test_phone_and_ipad_keep_all_orientations_for_custom_touch_profiles(self):
        landscape = {"UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"}
        all_orientations = landscape | {"UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown"}
        # This fork keeps portrait on phones for the upper-picture/lower-controls
        # layout. An omitted iPad override inherits the phone orientation array.
        for project in (IOS / "project.yml", IOS / "tests/duo/project.yml", IOS / "tests/duo_ui/project.yml"):
            source = project.read_text()
            for key, expected in (("UISupportedInterfaceOrientations", all_orientations),
                                  ("UISupportedInterfaceOrientations~ipad", all_orientations)):
                with self.subTest(project=str(project.relative_to(IOS)), key=key):
                    match = re.search(r"^        " + re.escape(key) + r":\n((?:          - .*\n)+)", source, re.MULTILINE)
                    if match is None and key.endswith("~ipad"):
                        match = re.search(r"^        UISupportedInterfaceOrientations:\n((?:          - .*\n)+)", source, re.MULTILINE)
                    assert match is not None, f"Missing orientation array: {key}"
                    self.assertEqual(set(re.findall(r"- (\w+)", match[1])), expected)
            self.assertNotIn("UIRequiresFullScreen:", source)


if __name__ == "__main__":
    unittest.main()
