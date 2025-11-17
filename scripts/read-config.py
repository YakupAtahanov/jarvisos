#!/usr/bin/env python3
"""
Read configs/builder.toml and emit a Makefile-friendly config at build/config.mk
Uses Python 3.11+ tomllib (stdlib) to avoid extra dependencies.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import sys

try:
    import tomllib  # Python 3.11+
except Exception as exc:  # pragma: no cover
    print("ERROR: Python 3.11+ required (tomllib missing).", file=sys.stderr)
    sys.exit(1)


def as_space_list(values: list[str]) -> str:
    return " ".join(values) if values else ""


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate build/config.mk from builder.toml")
    parser.add_argument("--toml", default="configs/builder.toml", help="Path to builder.toml")
    parser.add_argument("--profile", default=None, help="Profile name (overrides default_profile)")
    parser.add_argument("--out", default="build/config.mk", help="Output Makefile fragment")
    args = parser.parse_args()

    toml_path = pathlib.Path(args.toml)
    if not toml_path.exists():
        print(f"ERROR: config file not found: {toml_path}", file=sys.stderr)
        return 2

    data = toml_path.read_bytes()
    config = tomllib.loads(data.decode("utf-8"))

    default_profile = config.get("default_profile") or "minimal"
    profile_name = args.profile or os.getenv("PROFILE") or default_profile

    globals_cfg = config.get("globals") or {}
    profiles = (config.get("profiles") or {})
    profile_cfg = profiles.get(profile_name)
    if not profile_cfg:
        print(f"ERROR: profile not found: {profile_name}", file=sys.stderr)
        return 3

    # Resolve values
    arch = os.getenv("ARCH") or globals_cfg.get("arch", "x86_64")
    kernel_version = globals_cfg.get("kernel_version", "6.16.5")
    distro_version = globals_cfg.get("distro_version", "1.0.0")

    extra_packages = profile_cfg.get("rootfs_extra_packages") or []
    jarvis_enabled = bool(profile_cfg.get("jarvis_enabled", True))
    jarvis_mode = profile_cfg.get("jarvis_mode", "text")
    loading_strategy = profile_cfg.get("loading_strategy", "disabled")
    background_priority = int(profile_cfg.get("background_priority", 15))
    active_priority = int(profile_cfg.get("active_priority", 0))
    models_vosk = profile_cfg.get("models_vosk", "")
    models_piper = profile_cfg.get("models_piper_voice", "")
    ollama_model = profile_cfg.get("ollama_model", "")

    # Ensure output directory
    out_path = pathlib.Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    lines: list[str] = []
    lines.append(f'# Generated from {toml_path} (profile="{profile_name}")')
    # Quote string values to survive sourcing in shell (spaces, special chars)
    def q(val: str) -> str:
        return '"' + val.replace('"', '\\"') + '"'
    lines.append(f'PROFILE := {q(profile_name)}')
    lines.append(f'ARCH := {q(arch)}')
    lines.append(f'KERNEL_VERSION := {q(kernel_version)}')
    lines.append(f'DISTRO_VERSION := {q(distro_version)}')
    lines.append(f'EXTRA_PACKAGES := {q(as_space_list(extra_packages))}')
    lines.append(f'JARVIS_ENABLED := { "1" if jarvis_enabled else "0" }')
    lines.append(f'JARVIS_MODE := {q(jarvis_mode)}')
    lines.append(f'LOADING_STRATEGY := {q(loading_strategy)}')
    lines.append(f'BACKGROUND_PRIORITY := {background_priority}')
    lines.append(f'ACTIVE_PRIORITY := {active_priority}')
    lines.append(f'VOSK_MODEL := {q(models_vosk)}')
    lines.append(f'PIPER_VOICE := {q(models_piper)}')
    lines.append(f'OLLAMA_MODEL := {q(ollama_model)}')
    lines.append('')

    out_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"Wrote {out_path} (profile={profile_name})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


