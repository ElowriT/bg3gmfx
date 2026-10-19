import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "tools/launch/steam-launch.sh"


class SteamLaunchTests(unittest.TestCase):
    """tools/launch/steam-launch.sh with a stand-in for /usr/bin/open."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        checkout = self.root / "checkout"
        (checkout / "tools/launch").mkdir(parents=True)
        shutil.copy(SCRIPT, checkout / "tools/launch/steam-launch.sh")
        self.script = checkout / "tools/launch/steam-launch.sh"
        self.runtime = checkout / "build/bin/libBG3MetalFX.dylib"
        self.runtime.parent.mkdir(parents=True)
        self.runtime.write_bytes(b"")
        self.env_file = checkout / "build/steam-launch.env"
        self.home = self.root / "home"
        self.app = self.home / "Library/Application Support/Steam/steamapps/common/Baldurs Gate 3/Baldur's Gate 3.app"
        self.app.mkdir(parents=True)
        self.log = self.root / "open-arguments"
        opener = self.root / "open"
        opener.write_text('#!/bin/sh\nfor a in "$@"; do printf "%s\\n" "$a"; done > "$LOG"\n')
        opener.chmod(0o755)
        self.base = {"PATH": "/usr/bin:/bin", "HOME": str(self.home), "BG3MFX_OPEN": str(opener), "LOG": str(self.log)}

    def launch(self, *arguments, **env):
        result = subprocess.run([str(self.script), *arguments], env={**self.base, **env}, capture_output=True, text=True)
        return result, self.log.read_text().splitlines() if self.log.exists() else []

    def test_injects_next_to_steam_libraries_and_finds_the_bundle(self):
        # Steam's quoting of the apostrophe may leave pieces of the path; they are ignored.
        self.env_file.write_text("# lab\nBG3MFX_LAB=/tmp/lab dir\n")
        result, arguments = self.launch("#'/elsewhere/Baldur", "s", "Gate", "3.app'",
                                        STEAM_DYLD_INSERT_LIBRARIES="/steam/overlay.dylib")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(arguments[:2], ["-n", "-W"])
        environment = [arguments[i + 1] for i, a in enumerate(arguments) if a == "--env"]
        self.assertIn(f"DYLD_INSERT_LIBRARIES=/steam/overlay.dylib:{self.runtime}", environment)
        for value in ("BG3MFX_ENABLE_METALFX=1", "SteamAppId=1086940", "SteamGameId=1086940",
                      "MTL_HUD_ENABLED=1", "BG3MFX_LAB=/tmp/lab dir"):
            self.assertIn(value, environment)
        self.assertEqual(arguments[-4:], [str(self.app), "--args", "-NoLauncher", "1"])

    def test_leaves_out_steam_libraries_on_request(self):
        self.env_file.write_text("BG3MFX_STEAM_OVERLAY=0\n")
        result, arguments = self.launch(STEAM_DYLD_INSERT_LIBRARIES="/steam/overlay.dylib")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"DYLD_INSERT_LIBRARIES={self.runtime}", arguments)
        self.assertNotIn("BG3MFX_STEAM_OVERLAY=0", arguments)

    def test_uses_an_intact_bundle_and_another_runtime(self):
        other = self.root / "Other Library/Baldur's Gate 3.app"
        other.mkdir(parents=True)
        self.env_file.write_text(f"BG3MFX_RUNTIME={self.runtime}\n")
        result, arguments = self.launch(str(other))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"DYLD_INSERT_LIBRARIES={self.runtime}", arguments)
        self.assertEqual(arguments[-4], str(other))

    def test_missing_runtime_does_not_start_the_game(self):
        self.runtime.unlink()
        result, arguments = self.launch()
        self.assertEqual(result.returncode, 1)
        self.assertIn("runtime", result.stderr)
        self.assertEqual(arguments, [])


if __name__ == "__main__":
    unittest.main()
