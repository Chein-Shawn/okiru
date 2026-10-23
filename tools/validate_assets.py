#!/usr/bin/env python3
"""Validate release-critical Okiru audio and icon assets."""

from argparse import ArgumentParser
from pathlib import Path
import subprocess
import wave

ROOT = Path(__file__).resolve().parents[1]
SOUND_NAMES = ("sunrise", "bells", "marimba", "pulse", "orbit", "tide")


def validate_alarm_sounds() -> None:
    problems: list[str] = []
    for name in SOUND_NAMES:
        path = ROOT / "Resources" / "Sounds" / f"{name}.wav"
        if not path.is_file():
            problems.append(f"missing {path.relative_to(ROOT)}")
            continue
        try:
            with wave.open(str(path), "rb") as audio:
                duration = audio.getnframes() / audio.getframerate()
                if duration >= 30:
                    problems.append(f"{path.name} is {duration:.3f}s; it must be shorter than 30s")
                if audio.getsampwidth() != 2:
                    problems.append(f"{path.name} is not 16-bit Linear PCM")
                if audio.getnchannels() not in (1, 2):
                    problems.append(f"{path.name} must be mono or stereo")
        except (wave.Error, EOFError) as error:
            problems.append(f"{path.name} is not a readable Linear PCM WAV: {error}")
    if problems:
        raise ValueError("Alarm sound validation failed:\n- " + "\n- ".join(problems))


def validate_app_icon() -> None:
    path = ROOT / "Resources" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon.png"
    result = subprocess.run(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", str(path)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    if "pixelWidth: 1024" not in result or "pixelHeight: 1024" not in result:
        raise ValueError("AppIcon.png must be exactly 1024x1024 pixels")
    if "hasAlpha: no" not in result:
        raise ValueError("AppIcon.png must not contain an alpha channel")


if __name__ == "__main__":
    parser = ArgumentParser()
    parser.add_argument("--audio-only", action="store_true", help="Skip AppIcon validation")
    args = parser.parse_args()
    validate_alarm_sounds()
    if not args.audio_only:
        validate_app_icon()
    print("Okiru asset validation passed.")
