"""Real installed-program predicates over synthetic image trees, without model imports or GPUs."""

from __future__ import annotations

import shutil
import sys
from dataclasses import replace
from pathlib import Path

import pytest

from podagent.catalog import CATALOG
from podagent.errors import AgentError
from podagent.gpus import FakeBackend
from podagent.settings import Paths, Settings
from podagent.supervisor import Supervisor

ROOT = Path(__file__).resolve().parents[3]
BASE = {"tensorboard", "cleanup-datasets", "pull-dataset", "push-lora"}
FAMILIES = {
    "aitoolkit": {
        "trainer-aitoolkit",
        "generate-aitoolkit",
        "draw-regularization",
        "upscale-media",
    },
    "ltx": {"trainer-ltx", "generate-ltx", "upscale-media"},
    "musubi": {"trainer-musubi", "generate-musubi", "upscale-media"},
}
AI_MODULES = (
    "toolkit/config_modules.py",
    "toolkit/stable_diffusion_model.py",
    "toolkit/sampler.py",
    "toolkit/util/get_model.py",
)
LTX_GENERATOR = "ltx-2/packages/ltx-pipelines/src/ltx_pipelines/ti2vid_one_stage.py"
MUSUBI_TASKS = ("cache_latents", "cache_text_encoder_outputs", "train_network", "generate_image")


def put(path: Path, *, executable: bool = False) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("# synthetic installed file\n")
    if executable:
        path.chmod(0o755)
    return path


@pytest.fixture
def image(settings: Settings, monkeypatch: pytest.MonkeyPatch) -> Paths:
    paths = settings.paths
    paths.scripts.mkdir(parents=True)
    for source in (ROOT / "pod/scripts").glob("*.py"):
        shutil.copy2(source, paths.scripts / source.name)
    shutil.copy2(
        ROOT / "app/Sources/ConceptStudio/Resources/Training/model-table.json",
        paths.scripts / "model-table.json",
    )
    for name in ("ltx_rules.py", "musubi_rules.py"):
        target = paths.prefix / "pod/agent/src/podagent" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / "pod/agent/src/podagent" / name, target)
    monkeypatch.setenv("AI_TOOLKIT_DIR", str(paths.prefix / "ai-toolkit"))
    monkeypatch.setenv("LTX_TRAINER_DIR", str(paths.prefix / "ltx-2/packages/ltx-trainer"))
    monkeypatch.setenv("MUSUBI_TUNER_DIR", str(paths.prefix / "musubi-tuner"))
    monkeypatch.delenv("LTX_PREPROCESS_SCRIPT", raising=False)
    monkeypatch.delenv("LTX_TRAIN_SCRIPT", raising=False)
    return paths


def base(paths: Paths) -> None:
    for binary in ("python", "tensorboard"):
        put(Path(paths.venv_bin("agent", binary)), executable=True)
    # The base ships the thin SeedVR2 environment and checkout, but not Torch.
    put(Path(paths.venv_bin("seedvr2", "python")), executable=True)
    put(paths.prefix / "seedvr2/inference_cli.py")


def install(paths: Paths, trainer: str) -> None:
    put(Path(paths.venv_bin(trainer, "python")), executable=True)
    if trainer == "aitoolkit":
        for path in ("run.py", *AI_MODULES):
            put(paths.prefix / "ai-toolkit" / path)
    elif trainer == "ltx":
        for script in ("process_dataset.py", "train.py"):
            put(paths.prefix / "ltx-2/packages/ltx-trainer/scripts" / script)
        put(paths.prefix / LTX_GENERATOR)
    else:
        for task in MUSUBI_TASKS:
            put(paths.prefix / "musubi-tuner/src/musubi_tuner" / f"krea2_{task}.py")
    torch = put(
        paths.prefix / "venvs" / trainer / "lib/python3.12/site-packages/torch/__init__.py"
    ).parent
    shared = paths.prefix / "venvs/seedvr2/lib/python3.12/site-packages/torch"
    shared.parent.mkdir(parents=True, exist_ok=True)
    shared.symlink_to(torch, target_is_directory=True)


@pytest.mark.parametrize(
    "variant", ["base", *FAMILIES, *(name + "-captioning" for name in FAMILIES)]
)
def test_each_image_advertises_exactly_its_installed_services(
    image: Paths, settings: Settings, variant: str
) -> None:
    base(image)
    expected = BASE.copy()
    family = variant.removesuffix("-captioning")
    if family != "base":
        install(image, family)
        expected |= FAMILIES[family]
    if variant.endswith("-captioning"):
        for name in ("python", "vllm"):
            put(Path(image.venv_bin("vllm", name)), executable=True)
        expected.add("vllm")
    before = set(sys.modules)
    sup = Supervisor(replace(settings, fake_gpus=None), FakeBackend(2))
    try:
        assert {state.name for state in sup.states() if state.available} == expected
        assert {name for name in CATALOG if sup.state(name).available} == expected
        assert not any(
            name.split(".")[0] in {"torch", "transformers", "diffusers", "vllm"}
            for name in set(sys.modules) - before
        )
        assert not list(image.models.rglob("*.safetensors"))  # Weights download on first use.
    finally:
        sup.shutdown()


def test_shared_wrappers_and_interpreters_are_not_installed_trainers(image: Paths) -> None:
    assert not any(spec.available(image) for spec in CATALOG.values())
    for family in FAMILIES:
        put(Path(image.venv_bin(family, "python")), executable=True)
    assert not any(spec.available(image) for spec in CATALOG.values())


@pytest.mark.parametrize(
    ("family", "missing", "unavailable"),
    [
        ("aitoolkit", "ai-toolkit/run.py", {"trainer-aitoolkit"}),
        (
            "aitoolkit",
            "ai-toolkit/toolkit/config_modules.py",
            {"generate-aitoolkit", "draw-regularization"},
        ),
        ("ltx", "ltx-2/packages/ltx-trainer/scripts/process_dataset.py", {"trainer-ltx"}),
        ("ltx", LTX_GENERATOR, {"generate-ltx"}),
        (
            "musubi",
            "musubi-tuner/src/musubi_tuner/krea2_cache_text_encoder_outputs.py",
            {"trainer-musubi"},
        ),
        ("musubi", "musubi-tuner/src/musubi_tuner/krea2_generate_image.py", {"generate-musubi"}),
    ],
)
def test_missing_native_entrypoint_disables_only_its_services(
    image: Paths, family: str, missing: str, unavailable: set[str]
) -> None:
    base(image)
    install(image, family)
    (image.prefix / missing).unlink()
    actual = {name for name, spec in CATALOG.items() if spec.available(image)}
    assert actual == (BASE | FAMILIES[family]) - unavailable


@pytest.mark.parametrize("kind", ["not-executable", "broken-symlink"])
def test_an_unusable_interpreter_does_not_expose_its_services(image: Paths, kind: str) -> None:
    base(image)
    install(image, "aitoolkit")
    python = Path(image.venv_bin("aitoolkit", "python"))
    if kind == "not-executable":
        python.chmod(0o644)
    else:
        python.unlink()
        python.symlink_to(image.prefix / "missing-python")
    for name in ("trainer-aitoolkit", "generate-aitoolkit", "draw-regularization"):
        assert not CATALOG[name].available(image)


@pytest.mark.parametrize("variable", ["LTX_PREPROCESS_SCRIPT", "LTX_TRAIN_SCRIPT"])
def test_ltx_entrypoint_overrides_are_the_paths_that_count(
    image: Paths, monkeypatch: pytest.MonkeyPatch, variable: str
) -> None:
    base(image)
    install(image, "ltx")
    override = image.prefix / "custom/entrypoint.py"
    monkeypatch.setenv(variable, str(override))
    assert not CATALOG["trainer-ltx"].available(image)
    put(override)
    assert CATALOG["trainer-ltx"].available(image)


@pytest.mark.parametrize("family", ["aitoolkit", "ltx", "musubi"])
def test_native_directory_overrides_are_respected(
    image: Paths, monkeypatch: pytest.MonkeyPatch, family: str
) -> None:
    base(image)
    install(image, family)
    directories = {
        "aitoolkit": ("AI_TOOLKIT_DIR", image.prefix / "ai-toolkit"),
        "ltx": ("LTX_TRAINER_DIR", image.prefix / "ltx-2/packages/ltx-trainer"),
        "musubi": ("MUSUBI_TUNER_DIR", image.prefix / "musubi-tuner"),
    }
    variable, original = directories[family]
    relocated = image.prefix / "relocated-native"
    monkeypatch.setenv(variable, str(relocated))
    assert not CATALOG["trainer-" + family].available(image)
    shutil.copytree(original, relocated)
    assert CATALOG["trainer-" + family].available(image)


@pytest.mark.parametrize("family", ["ltx", "musubi"])
def test_partial_launcher_dependencies_are_unavailable(image: Paths, family: str) -> None:
    base(image)
    install(image, family)
    (image.prefix / f"pod/agent/src/podagent/{family}_rules.py").unlink()
    assert not CATALOG["trainer-" + family].available(image)
    assert not CATALOG["generate-" + family].available(image)


def test_ai_generation_does_not_require_the_training_wrapper(image: Paths) -> None:
    base(image)
    install(image, "aitoolkit")
    (image.scripts / "launch_aitoolkit.py").unlink()
    assert not CATALOG["trainer-aitoolkit"].available(image)
    assert CATALOG["generate-aitoolkit"].available(image)
    assert CATALOG["draw-regularization"].available(image)


def test_unavailable_refusal_precedes_validation_preparation_and_mutation(
    image: Paths, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    prepared = []
    sup = Supervisor(replace(settings, fake_gpus=None), FakeBackend(2))
    sentinel = put(image.uploads / "fixture/input.png")
    try:
        for name, spec in CATALOG.items():
            monkeypatch.setitem(
                CATALOG, name, replace(spec, prepare=lambda *_: prepared.append(True))
            )
            with pytest.raises(AgentError) as error:
                sup.start(name, [], {})
            assert (error.value.status, error.value.code) == (409, "unavailable")
        assert not prepared
        assert sentinel.is_file()
        assert not list(image.runs.glob("*"))
    finally:
        sup.shutdown()


def test_fake_mode_still_exposes_all_simulated_services(settings: Settings) -> None:
    sup = Supervisor(settings, FakeBackend(2))
    try:
        assert all(state.available for state in sup.states())
        assert len(sup.states()) == len(CATALOG) == 13
    finally:
        sup.shutdown()
