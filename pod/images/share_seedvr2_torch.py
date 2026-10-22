"""Run with the trainer's Python to share only its GPU packages with the SeedVR2 venv."""

import importlib.metadata
import sys
import sysconfig
from pathlib import Path

source = Path(sysconfig.get_path("purelib"))
target = Path(sys.argv[1]) / source.relative_to(sys.prefix)
assert target.is_dir(), f"SeedVR2 site-packages is missing: {target}"

names = set()
roots = set()
for distribution in importlib.metadata.distributions(path=[str(source)]):
    name = distribution.metadata["Name"].lower().replace("_", "-")
    if name in {"torch", "torchvision", "triton"} or name.startswith(("nvidia-", "cuda-")):
        names.add(name)
        # Wheel records include modules, native-library directories and version metadata.
        # Console scripts outside site-packages are not needed by SeedVR2.
        roots.update(path.parts[0] for path in distribution.files or () if path.parts[0] != "..")

assert {"torch", "torchvision", "triton"} <= names, f"Trainer GPU packages are missing: {names}"
for name in sorted(roots):
    (target / name).symlink_to(source / name, target_is_directory=(source / name).is_dir())

print("SeedVR2 shares trainer GPU packages:", ", ".join(sorted(names)))
