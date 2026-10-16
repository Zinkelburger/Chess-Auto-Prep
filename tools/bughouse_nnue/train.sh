#!/usr/bin/env bash
# Train a pocketknight NNUE from a packed dataset, on a machine with a CUDA GPU.
#
#   train.sh DATASET.bin DATASET.val.bin --config trainer-config/ [options]
#
#   --config DIR     the variant.h/variant.py `setup` wrote (required)
#   --lambda X[,Y…]  0.0 = game results only (default), 1.0 = search scores only;
#                    a comma list trains one net per value, in turn
#   --epochs N       passes of --epoch-size positions (default 10); the epoch
#                    with the lowest validation loss is the one serialized
#   --epoch-size N   positions per epoch (default 20M; use ~1M for a smoke test)
#   --val-size N     positions per validation pass (default 1M)
#   --out NAME       the net to write (default pocketknight-lambda<L>.nnue; with
#                    several lambdas, -lambda<L> is inserted before .nnue)
#   --trainer DIR    an existing variant-nnue-pytorch checkout (default: clone the pin)
#   --resume FILE    continue from a .nnue or .pt
#   --keep-captures  do not skip positions whose move was a capture
#
# What it does, each step the trainer wiki's: clone the pinned trainer, copy
# the variant files into it, install the requirements (CUDA PyTorch, CuPy),
# build the C++ data loader, train, then serialize the checkpoint with the
# lowest validation loss (not the last: a net that has started to memorise
# its training set has a worse validation loss than an earlier epoch) to an
# .nnue Fairy-Stockfish loads with `EvalFile`.
#
# The result label is what `--lambda 0` learns from: `extract` wrote it from
# the side to move's point of view.  A blend (`--lambda 0.3`) needs a dataset
# built from `score`d records, or the score side of the loss is all zeros.
#
# Kaggle (free GPU, 30 h/week, 12 h sessions): `python3 -m bughouse_nnue
# bundle` writes a folder with the two .bin files, trainer-config, this script
# and a notebook. Upload the folder as a Kaggle dataset, open the notebook
# with a GPU and internet on, and run it; the one cell is
#   !bash /kaggle/input/<dataset>/train.sh /kaggle/input/<dataset>/pocketknight.bin \
#        /kaggle/input/<dataset>/pocketknight.val.bin --config /kaggle/input/<dataset>/trainer-config \
#        --out /kaggle/working/pocketknight.nnue
# Save the .nnue from /kaggle/working before the session ends.
set -euo pipefail

TRAINER_URL=https://github.com/fairy-stockfish/variant-nnue-pytorch.git
TRAINER_SHA=b15df38a9aae8ab9b40b2378020b3099c7c5d179
FEATURES='HalfKAv2^'

TRAIN=${1:?training .bin}; VAL=${2:?validation .bin}; shift 2
CONFIG=""; LAMBDA=0.0; EPOCHS=10; OUT=""; TRAINER=""; RESUME=""; SKIP="--smart-fen-skipping"
EPOCH_SIZE=20000000; VAL_SIZE=1000000
while [[ $# -gt 0 ]]; do
  case $1 in
    --config) CONFIG=$2; shift 2 ;;
    --lambda) LAMBDA=$2; shift 2 ;;
    --epochs) EPOCHS=$2; shift 2 ;;
    --epoch-size) EPOCH_SIZE=$2; shift 2 ;;
    --val-size) VAL_SIZE=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --trainer) TRAINER=$2; shift 2 ;;
    --resume) RESUME=$2; shift 2 ;;
    --keep-captures) SKIP="--no-smart-fen-skipping"; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[[ -n $CONFIG ]] || { echo "--config DIR is required (the trainer-config setup wrote)" >&2; exit 2; }
[[ -f $CONFIG/variant.h && -f $CONFIG/variant.py ]] || { echo "no variant.h/variant.py in $CONFIG" >&2; exit 2; }
grep -q 'POCKETS true' "$CONFIG/variant.h" || { echo "$CONFIG/variant.h has no pockets; wrong variant" >&2; exit 2; }
IFS=, read -r -a LAMBDAS <<< "$LAMBDA"
OUT=${OUT:-pocketknight.nnue}
# Fairy-Stockfish only uses a net whose file name starts with the variant.
case $(basename "$OUT") in pocketknight*) ;; *) echo "--out must start with 'pocketknight' or the engine ignores the net" >&2; exit 2 ;; esac
TRAIN=$(realpath "$TRAIN"); VAL=$(realpath "$VAL"); CONFIG=$(realpath "$CONFIG")
[[ -n $RESUME ]] && RESUME=$(realpath "$RESUME")
case $OUT in /*) ;; *) OUT=$PWD/$OUT ;; esac

if [[ -z $TRAINER ]]; then
  TRAINER=$PWD/variant-nnue-pytorch
  if [[ ! -d $TRAINER/.git ]]; then
    git init -q "$TRAINER"
    git -C "$TRAINER" remote add origin "$TRAINER_URL"
  fi
  git -C "$TRAINER" fetch -q --depth 1 origin "$TRAINER_SHA"
  git -C "$TRAINER" checkout -q --detach "$TRAINER_SHA"
fi
cd "$TRAINER"
cp "$CONFIG/variant.h" "$CONFIG/variant.py" .

# A fresh machine gets everything from requirements-CUDA128.txt.  A Kaggle or
# Colab image already has a CUDA torch; there only the pieces it lacks are
# added, each matched to that torch: CuPy for its CUDA major, and Lightning
# 1.9 (train.py uses Trainer.from_argparse_args and --gpus, gone in 2.x).
python3 -c 'import torch; assert torch.cuda.is_available()' 2>/dev/null \
  || pip install -q -r requirements-CUDA128.txt
python3 -c 'import torch; assert torch.cuda.is_available(), "no CUDA device"'
CUDA_MAJOR=$(python3 -c 'import torch; print(torch.version.cuda.split(".")[0])')
python3 -c 'import cupy' 2>/dev/null || pip install -q "cupy-cuda${CUDA_MAJOR}x"
python3 -c 'import pytorch_lightning as pl; assert pl.__version__.startswith("1.9")' 2>/dev/null \
  || pip install -q pytorch-lightning==1.9.5
python3 -c 'import chess, tensorboard' 2>/dev/null || pip install -q chess tensorboard
# Lightning 1.9 checkpoints hold more than tensors; torch >= 2.6 refuses them
# by default when loading.
export TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD=1

# The loader is C++; train.py finds it as ./libtraining_data_loader.so.
cmake -S . -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=./ >/dev/null
cmake --build build --config RelWithDebInfo --target install >/dev/null

RESUME_ARGS=()
if [[ -n $RESUME ]]; then
  case $RESUME in
    *.nnue) python3 serialize.py --features="$FEATURES" "$RESUME" resume.pt; RESUME=$PWD/resume.pt ;;
  esac
  RESUME_ARGS=(--resume-from-model "$RESUME")
fi

# The checkpoint whose epoch had the lowest validation loss, read from the
# run's TensorBoard log (train.py saves every epoch and never says which was
# best).  Prints the per-epoch losses so the curve is in the session log.
cat > pick_best.py <<'PY'
import glob, os, re, sys
from tensorboard.backend.event_processing.event_accumulator import EventAccumulator
run = sys.argv[1]
acc = EventAccumulator(run, size_guidance={"scalars": 0}); acc.Reload()
tags = acc.Tags()["scalars"]
tag = next((t for t in ("val_loss", "val_loss_epoch") if t in tags), None)
ckpts = {}
for path in glob.glob(os.path.join(run, "checkpoints", "epoch=*.ckpt")):
    m = re.search(r"epoch=(\d+)", os.path.basename(path))
    if m: ckpts[int(m.group(1))] = path
if tag is None or not ckpts:
    print("no validation losses logged; using last.ckpt", file=sys.stderr)
    print(os.path.join(run, "checkpoints", "last.ckpt")); sys.exit(0)
losses = [e.value for e in acc.Scalars(tag)]
# One validation pass per epoch, in order; the last one may be a partial epoch.
best = min(range(min(len(losses), len(ckpts))), key=lambda i: losses[i])
for i, loss in enumerate(losses[:len(ckpts)]):
    print(f"epoch {i}: val_loss {loss:.6f}{'  <- best' if i == best else ''}", file=sys.stderr)
print(ckpts[best])
PY

for L in "${LAMBDAS[@]}"; do
  if [[ ${#LAMBDAS[@]} -gt 1 ]]; then NET=${OUT%.nnue}-lambda${L}.nnue; else NET=$OUT; fi
  echo "training: lambda=$L epochs=$EPOCHS x $EPOCH_SIZE positions, features=$FEATURES $SKIP"
  python3 train.py "$TRAIN" "$VAL" \
    --features="$FEATURES" --lambda "$L" --max_epochs "$EPOCHS" \
    --epoch-size "$EPOCH_SIZE" --validation-size "$VAL_SIZE" \
    --gpus 1 --threads 2 --num-workers 2 $SKIP "${RESUME_ARGS[@]}"
  RUN=$(ls -td logs/*/version_* | head -1)
  BEST=$(python3 pick_best.py "$RUN")
  echo "serializing $BEST"
  python3 serialize.py --features="$FEATURES" "$BEST" "$NET" \
    --description "pocketknight NNUE, lambda=$L, best of $EPOCHS epochs, FICS bughouse checkmates"
  echo "wrote $NET"
done
echo "gate it: python3 -m bughouse_nnue match --net-one <net>   (and evaluate --net <net> for the outcome fit)"
