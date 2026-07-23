import importlib.util
import unittest
from pathlib import Path
from unittest import mock


SCRIPT_PATH = Path(__file__).with_name("generate_release_metadata.py")
SPEC = importlib.util.spec_from_file_location("generate_release_metadata", SCRIPT_PATH)
release_metadata = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release_metadata)


class AltStoreSourceTests(unittest.TestCase):
    def test_replaces_all_builds_for_the_same_version(self):
        source = {
            "apps": [
                {
                    "bundleIdentifier": release_metadata.BUNDLE_IDENTIFIER,
                    "versions": [
                        {
                            "version": "1.1.2",
                            "buildVersion": "7",
                            "downloadURL": "https://example.com/fork.ipa",
                        },
                        {
                            "version": "1.1.2",
                            "buildVersion": "26",
                            "downloadURL": "https://example.com/upstream.ipa",
                        },
                        {
                            "version": "1.1.1",
                            "buildVersion": "25",
                            "downloadURL": "https://example.com/previous.ipa",
                        },
                    ],
                }
            ]
        }
        ipa = {
            "name": "ivLyrics-IOS-v1.1.2-unsigned.ipa",
            "versionName": "1.1.2",
            "buildNumber": "8",
            "size": 123,
            "sha256": "abc123",
            "minimumOSVersion": "17.0",
            "privacy": {},
        }

        with mock.patch.object(release_metadata, "load_source", return_value=source), mock.patch.object(
            release_metadata, "REPOSITORY", "oneulddu/ivLyrics-IOS"
        ):
            result = release_metadata.build_altstore_source("v1.1.2", ipa, {})

        versions = result["apps"][0]["versions"]
        current_versions = [item for item in versions if item.get("version") == "1.1.2"]
        self.assertEqual(len(current_versions), 1)
        self.assertEqual(current_versions[0]["buildVersion"], "8")
        self.assertIn("oneulddu/ivLyrics-IOS", current_versions[0]["downloadURL"])
        self.assertEqual(versions[1]["version"], "1.1.1")


if __name__ == "__main__":
    unittest.main()
