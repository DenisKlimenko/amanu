import json
import os
import shutil
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "landing" / "script.js"


# The page's script runs in Node here. A machine without it cannot run the
# test, which is a skip and says so rather than a FileNotFoundError from deep
# inside subprocess. CI, which sets CI and installs Node, may not skip it: a
# check that quietly stopped running there would look exactly like one that
# passed.
NODE = shutil.which("node")


class LandingAnalyticsTests(unittest.TestCase):
    def setUp(self):
        if NODE is None:
            if os.environ.get("CI"):
                self.fail("Node.js is required on CI for the landing-page analytics test")
            self.skipTest("Node.js is not installed; the landing-page script cannot be run")

    def test_page_view_and_download_click_use_the_first_party_pixel(self):
        harness = r"""
const fs = require('fs');
const sent = [];
const links = [{ handler: null }, { handler: null }];
class Pixel {
  set src(value) { sent.push(value); }
}
global.Image = Pixel;
global.location = { origin: 'https://amanu.me', pathname: '/ru/' };
global.screen = { width: 1440, height: 900 };
global.devicePixelRatio = 2;
global.document = {
  title: 'Amanu',
  referrer: 'https://example.com/article',
  getElementById() { return null; },
  querySelectorAll(selector) {
    if (selector !== 'a[href*="/releases/download/"]') throw new Error(selector);
    return links;
  }
};
for (const link of links) {
  link.addEventListener = (name, handler) => {
    if (name !== 'click') throw new Error(name);
    link.handler = handler;
  };
}
eval(fs.readFileSync(process.argv[1], 'utf8'));
links[0].handler();
console.log(JSON.stringify(sent));
"""
        result = subprocess.run(
            [NODE, "-e", harness, str(SCRIPT)],
            check=False,
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        urls = [dict(item.split("=", 1) for item in value.split("?", 1)[1].split("&"))
                for value in json.loads(result.stdout)]

        self.assertEqual(len(urls), 2)
        self.assertEqual(urls[0]["p"], "%2Fru%2F")
        self.assertNotIn("e", urls[0])
        self.assertEqual(urls[1]["p"], "download_clicked")
        self.assertEqual(urls[1]["e"], "1")
        self.assertEqual(urls[1]["t"], "Amanu+download")


if __name__ == "__main__":
    unittest.main()
