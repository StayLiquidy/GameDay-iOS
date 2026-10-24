#!/usr/bin/env python3
"""Package an unsigned Xcode archive and a FlareStore-compatible source."""
import argparse
import datetime
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument("archive", type=pathlib.Path)
parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("dist"))
parser.add_argument("--repository", default="StayLiquidy/GameDay-iOS")
args = parser.parse_args()
app = args.archive / "Products/Applications/GameDay.app"
with (app / "Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
version = info["CFBundleShortVersionString"]
build = info["CFBundleVersion"]
tag = f"v{version}"
args.output.mkdir(parents=True, exist_ok=True)
ipa = args.output / "GameDay.ipa"
with tempfile.TemporaryDirectory(prefix="gameday-release-") as staging:
    payload = pathlib.Path(staging) / "Payload"
    payload.mkdir()
    copy = payload / app.name
    shutil.copytree(app, copy)
    # Public downloads must not contain a developer's device registration profile.
    for profile in copy.rglob("*.mobileprovision"):
        profile.unlink()
    for signature in sorted(copy.rglob("_CodeSignature"), reverse=True):
        shutil.rmtree(signature)
    with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(payload.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(staging))

root = pathlib.Path(__file__).resolve().parents[1]
shutil.copyfile(root / "GameDay/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png", args.output / "icon.png")
release_url = f"https://github.com/{args.repository}/releases/download/{tag}"
source_url = f"https://github.com/{args.repository}/releases/latest/download/source.json"
date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
description = "iPhone sports schedules, live scores, provider channel matching, and KSPlayer/AVKit playback. Bring your own provider subscription. Sign with your own certificate in FlareStore."
entry = {"version": version, "buildVersion": build, "date": date,
         "downloadURL": f"{release_url}/GameDay.ipa", "size": ipa.stat().st_size,
         "minOSVersion": info.get("MinimumOSVersion", "17.0"),
         "localizedDescription": "See the GitHub release notes for changes."}
source = {"name": "GameDay", "identifier": "net.inspectah.gameday.source",
          "sourceURL": source_url, "subtitle": "GameDay for iPhone",
          "website": f"https://github.com/{args.repository}", "tintColor": "B99AF7",
          "iconURL": f"{release_url}/icon.png", "apps": [{
              "name": "GameDay", "bundleIdentifier": info["CFBundleIdentifier"],
              "developerName": args.repository.split("/")[0],
              "localizedDescription": description, "iconURL": f"{release_url}/icon.png",
              "versions": [entry], "version": version, "buildVersion": build, "versionDate": date,
              "downloadURL": entry["downloadURL"], "size": entry["size"]}], "news": []}
(args.output / "source.json").write_text(json.dumps(source, indent=2) + "\n")
print(f"Packaged {tag}: {ipa} ({ipa.stat().st_size} bytes)")
