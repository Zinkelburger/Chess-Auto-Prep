"""Everything the GPU step needs, in one folder to upload as a Kaggle dataset.

The trainer wants a CUDA GPU and this machine has none, so the data goes to
the GPU rather than the other way round: the packed dataset, the variant files
`setup` wrote for the trainer, `train.sh`, and a one-cell notebook that runs it
with the paths Kaggle gives an attached dataset.
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

from .paths import data_home, dataset_dir, trainer_config_dir

HERE = Path(__file__).resolve().parent


def _notebook(slug: str, name: str, args: str) -> dict[str, object]:
    base = f"/kaggle/input/{slug}"
    # The dataset's slug is whatever Kaggle made of its title, so find the
    # folder by its contents rather than assume the name.  Kaggle's uploader
    # also drops subfolders, so the notebook writes the two variant files
    # itself rather than expecting trainer-config/ to have survived.
    config = trainer_config_dir()
    find = (
        "import glob, os\n"
        "found = glob.glob('/kaggle/input/**/train.sh', recursive=True)\n"
        "assert found, 'dataset not attached: right panel -> Add Input -> your dataset'\n"
        "D = os.path.dirname(found[0]); print(D); print(os.listdir(D))\n"
        "os.makedirs('/kaggle/working/trainer-config', exist_ok=True)\n"
        f"open('/kaggle/working/trainer-config/variant.h', 'w').write({(config / 'variant.h').read_text()!r})\n"
        f"open('/kaggle/working/trainer-config/variant.py', 'w').write({(config / 'variant.py').read_text()!r})\n"
    )
    cmd = (
        f"!bash $D/train.sh $D/{name}.bin $D/{name}.val.bin \\\n"
        f"    --config /kaggle/working/trainer-config --out /kaggle/working/pocketknight.nnue {args}"
    )
    cells = [
        {
            "cell_type": "markdown",
            "metadata": {},
            "source": [
                "# pocketknight NNUE\n",
                "\n",
                f"Settings: **GPU** accelerator on, **Internet** on, the dataset (`{slug}` or whatever Kaggle named it) attached under Input.\n",
                "The script clones the pinned trainer, installs what the image lacks, builds the data loader,\n",
                "trains one net per `--lambda` value (best validation epoch of each), and writes them to `/kaggle/working/`.\n",
                "Download the .nnue files from Output before the session ends.\n",
            ],
        },
        {
            "cell_type": "code",
            "execution_count": None,
            "metadata": {},
            "outputs": [],
            "source": ["!nvidia-smi -L\n", find],
        },
        {"cell_type": "code", "execution_count": None, "metadata": {}, "outputs": [], "source": [cmd]},
        {
            "cell_type": "code",
            "execution_count": None,
            "metadata": {},
            "outputs": [],
            "source": ["!ls -la /kaggle/working/*.nnue\n", "# then: Output -> download, and locally\n",
                       "#   python3 -m bughouse_nnue match --net-one pocketknight-lambda0.0.nnue --games 400\n",
                       "#   python3 -m bughouse_nnue evaluate --net pocketknight-lambda0.0.nnue"],
        },
    ]
    return {
        "cells": cells,
        "metadata": {
            "kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
            "language_info": {"name": "python"},
        },
        "nbformat": 4,
        "nbformat_minor": 5,
    }


def bundle(name: str, slug: str | None, args: str) -> int:
    """Copy dataset `name` and the trainer bits into data_home()/kaggle/<slug>/."""
    src = dataset_dir()
    train, val = src / f"{name}.bin", src / f"{name}.val.bin"
    if not (train.exists() and val.exists()):
        print(f"no {name}.bin / {name}.val.bin in {src}; run convert first")
        return 1
    config = trainer_config_dir()
    if not (config / "variant.h").exists():
        print(f"no trainer-config in {config}; run setup first")
        return 1
    slug = slug or f"bughouse-nnue-{name}"
    out = data_home() / "kaggle" / slug
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    for f in (train, val, src / f"{name}.json"):
        if f.exists():
            shutil.copy2(f, out / f.name)
    shutil.copytree(config, out / "trainer-config")
    shutil.copy2(HERE / "train.sh", out / "train.sh")
    (out / "train-pocketknight.ipynb").write_text(json.dumps(_notebook(slug, name, args), indent=1))
    size = sum(p.stat().st_size for p in out.rglob("*") if p.is_file())
    print(f"bundle: {out} ({size / 1e6:.1f} MB)")
    print(f"  1. kaggle.com -> Datasets -> New Dataset -> upload this folder (title: {slug})")
    print("  2. Code -> New Notebook -> File -> Import Notebook -> train-pocketknight.ipynb")
    print("  3. right panel: Input -> add the dataset; Session options -> GPU, Internet on")
    print("  4. Run All; download the .nnue files from /kaggle/working (Output) when it finishes")
    print("  5. gate each: python3 -m bughouse_nnue match --net-one <net> --games 400")
    return 0
