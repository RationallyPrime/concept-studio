"""Model identity, trainer pair selection, and Krea's captured inference recipe; offline."""

import ast
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

import pytest


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).parents[1] / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


table = load("model_table")
launcher = load("launch_aitoolkit")


def test_model_is_unique_and_pairing_lookups_follow_the_requested_trainer():
    document = table.load()
    models = table.models(document)
    assert len(models) == len({row["model_ref"] for row in models}) == 25
    musubi = table.exact_row("krea/Krea-2-Raw", "musubi", document)
    toolkit = table.exact_row("krea/Krea-2-Raw", "aitoolkit", document)
    assert musubi["recipe_status"] == "verified"
    assert toolkit["recipe_status"] == "unverified"
    assert table.exact_row("krea/Krea-2-Raw", table=document) == musubi
    assert table.exact_row("krea/Krea-2-Raw", "ltx", document) is None
    assert table.effective_row("aitoolkit", "krea/Krea-2-Raw", document) == toolkit
    assert table.trainer_default_row("musubi", document) == musubi
    assert not table.trainer_resumes("musubi", document)
    assert table.trainer_resumes("aitoolkit", document)
    assert table.supports_regularization(toolkit, "generate")
    assert not table.supports_regularization(musubi, "generate")


@pytest.mark.parametrize("change", ["duplicate", "default", "trainer", "shared"])
def test_rejects_invalid_pairing_contract(tmp_path, change):
    document = table.load()
    model = document["models"][0]
    if change == "duplicate":
        document["models"].append(model.copy())
    elif change == "default":
        model["default_trainer"] = "missing"
    elif change == "trainer":
        model["trainers"]["missing"] = model["trainers"]["aitoolkit"]
    else:
        model["trainers"]["aitoolkit"]["model_ref"] = "duplicate/fact"
    path = tmp_path / "table.json"
    path.write_text(json.dumps(document))
    with pytest.raises(ValueError):
        table.load(path)


def test_krea_recipe_trains_raw_without_dropout_and_samples_turbo(tmp_path, monkeypatch):
    monkeypatch.setenv("PODAGENT_WORKSPACE", str(tmp_path))
    dataset = tmp_path / "datasets/subject"
    dataset.mkdir(parents=True)
    run = tmp_path / "runs/krea"
    run.mkdir(parents=True)
    cfg = launcher.validate_run_config(
        {
            "run_id": "krea",
            "base_model": "krea/Krea-2-Raw",
            "triggers": ["NORA7"],
            "dataset": {"path": str(dataset)},
            "rank": 32,
            "alpha": 32,
            "steps": 1600,
            "resolution": [1024],
            "learning_rate": 1e-4,
            "sample_every": 100,
            "sample_prompts": ["NORA7 outdoors"],
        },
        tmp_path,
    )
    process = launcher.build_native_config(cfg, run)["config"]["process"][0]
    assert process["model"]["name_or_path"] == "krea/Krea-2-Raw"
    assert process["model"]["arch"] == "krea2"
    assert process["model"]["quantize"] is False
    assert process["train"]["optimizer"] == "adamw"
    assert process["train"]["lr_scheduler"] == "constant"
    assert process["train"]["timestep_type"] == "shift"
    assert process["datasets"][0]["caption_dropout_rate"] == 0.0
    assert process["sample"]["sample_steps"] == 8
    assert process["sample"]["guidance_scale"] == 1.0
    assert process["model"]["model_kwargs"]["sample_model"] == {
        "name_or_path": "krea/Krea-2-Turbo",
        "model_kwargs": {"schedule_mu": 1.15},
    }


@pytest.mark.parametrize("fails", [False, True])
def test_sampling_patch_restores_training_weights_and_parameter_identity(fails):
    # Execute the shipped override against a tensor boundary, without importing a GPU runtime.
    patch = (
        Path(__file__).parents[2] / "images/patches/ai-toolkit/0004-Krea-2-Turbo-samples.patch"
    ).read_text()
    added = "\n".join(
        line[1:]
        for line in patch.splitlines()
        if line.startswith("+") and not line.startswith("+++")
    )
    method = ast.parse("class Krea2Model:\n" + added).body[0].body[0]

    class Base:
        def generate_images(self, *args, **kwargs):
            assert self.transformer.state == "turbo"
            assert self.model_config.model_kwargs["schedule_mu"] == 1.15
            if fails:
                raise RuntimeError("synthetic render failure")
            return "sample"

    class Tensor:
        def detach(self):
            return self

        def to(self, *args, **kwargs):
            return "raw"

    class Transformer:
        state = "raw"

        def state_dict(self):
            return {"weight": Tensor()}

        def load_state_dict(self, state, strict):
            assert strict
            self.state = state["weight"]

    tree = ast.Module(
        body=[
            ast.ClassDef(
                name="Krea2Model",
                bases=[ast.Name(id="Base", ctx=ast.Load())],
                keywords=[],
                body=[method],
                decorator_list=[],
            )
        ],
        type_ignores=[],
    )
    namespace = {
        "Base": Base,
        "unwrap_model": lambda value: value,
        "_load_mmdit_state_dict": lambda repo, filename: {"weight": "turbo"},
        "flush": lambda: None,
    }
    exec(compile(ast.fix_missing_locations(tree), "sampling-patch", "exec"), namespace)
    model = namespace["Krea2Model"]()
    transformer = Transformer()
    original = {
        "sample_model": {"name_or_path": "krea/Krea-2-Turbo", "model_kwargs": {"schedule_mu": 1.15}}
    }
    model.transformer = transformer
    model.model_config = SimpleNamespace(quantize=False, model_kwargs=original)
    if fails:
        with pytest.raises(RuntimeError, match="synthetic render failure"):
            model.generate_images([])
    else:
        assert model.generate_images([]) == "sample"
    assert model.transformer is transformer
    assert transformer.state == "raw"
    assert model.model_config.model_kwargs is original


def test_comparisons_load_captured_turbo_weights_instead_of_training_raw(tmp_path, monkeypatch):
    import sys
    from types import ModuleType

    generation = load("generate_results")
    checkpoint = tmp_path / "selected-checkpoint.safetensors"
    native = {
        "config": {
            "process": [
                {
                    "network": {"type": "lora"},
                    "train": {"dtype": "bf16"},
                    "model": {
                        "name_or_path": "krea/Krea-2-Raw",
                        "arch": "krea2",
                        "model_kwargs": {
                            "sample_model": {
                                "name_or_path": "krea/Krea-2-Turbo",
                                "model_kwargs": {"schedule_mu": 1.15},
                            }
                        },
                    },
                }
            ]
        }
    }
    (tmp_path / "source-native-config.json").write_text(json.dumps(native))
    config = ModuleType("toolkit.config_modules")

    def inspect_model(**values):
        assert values["name_or_path"] == "krea/Krea-2-Turbo"
        assert values["arch"] == "krea2"
        assert values["model_kwargs"] == {"schedule_mu": 1.15}
        raise RuntimeError("captured inference boundary")

    config.ModelConfig = inspect_model
    config.GenerateImageConfig = object
    config.NetworkConfig = object
    model = ModuleType("toolkit.util.get_model")
    model.get_model_class = lambda _: None
    monkeypatch.setitem(sys.modules, "torch", ModuleType("torch"))
    monkeypatch.setitem(sys.modules, "toolkit.config_modules", config)
    monkeypatch.setitem(sys.modules, "toolkit.util.get_model", model)
    with pytest.raises(RuntimeError, match="captured inference boundary"):
        generation.arch_generate({}, checkpoint, {}, [], tmp_path)
