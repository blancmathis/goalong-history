#!/usr/bin/env python3
"""Run the real privacy audit against negative fixtures in an isolated copy."""
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = "Features/Ambiance/Sources/AmbianceAudioOutput.swift"


def main():
    logs = ROOT / ".ambiance-work/privacy-fixtures"
    logs.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=logs) as scratch:
        root = Path(scratch)
        for name in ("Sources", "Features", "scripts", "docs", "Distribution"):
            shutil.copytree(ROOT / name, root / name, ignore=shutil.ignore_patterns("__pycache__"))
        for name in ("Package.swift", "Package.resolved"):
            if (ROOT / name).exists():
                shutil.copy2(ROOT / name, root / name)

        def audit(label):
            result = subprocess.run(["bash", str(root / "scripts/audit_privacy_boundaries.sh")], cwd=root,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            (logs / (label + ".log")).write_text(result.stdout)
            return result.returncode

        assert audit("positive") == 0, "Baseline audit failed; see privacy-fixtures/positive.log"
        fixtures = [(OUTPUT, token) for token in (
            "inputNode", "AVAudioInputNode", "installTap", "AVAudioRecorder", "AVCaptureDevice",
            "AudioQueueNewInput", "kAudioOutputUnitProperty_EnableIO", "requestRecordPermission", "recordPermission",
            "AudioUnitRender", "AudioDeviceStart", "AudioDeviceCreateIOProcID", "AudioHardwareCreateProcessTap",
            "MediaPlayer", "MusicKit", "NSAppleMusicUsageDescription",
        )]
        fixtures += [(builder, token) for builder in ("scripts/build_app_core.sh", "scripts/update_policy.py")
                     for token in ("NSMicrophoneUsageDescription", "NSAppleMusicUsageDescription")]
        fixtures += [("Distribution/GoalongHistory.entitlements", token) for token in
                     ("com.apple.security.device.audio-input", "com.apple.security.device.microphone")]
        fixtures += [("Features/Ambiance/Sources/ForbiddenAudioFixture.swift", "AVAudioEngine")]
        fixtures += [("Features/Ambiance/Sources/ForbiddenAudioFixture.swift", token)
                     for token in ("AVAudioFile", "AVAudioPCMBuffer")]
        for index, (relative, token) in enumerate(fixtures):
            path = root / relative
            original = path.read_text() if path.exists() else None
            path.write_text((original or "") + "\n// Negative fixture: " + token + "\n")
            try:
                assert audit(f"{index:02d}-{token}") != 0, f"Audit accepted forbidden fixture: {token}"
            finally:
                if original is None:
                    path.unlink()
                else:
                    path.write_text(original)
        print(f"Ambiance privacy fixtures passed: baseline accepted, {len(fixtures)} forbidden fixtures rejected")


if __name__ == "__main__":
    main()
