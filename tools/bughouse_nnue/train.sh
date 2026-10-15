#!/usr/bin/env bash
# Train a pocketknight NNUE from a packed dataset, on a machine with a CUDA GPU.
#
#   train.sh DATASET.bin DATASET.val.bin --config trainer-config/ [options]
#
#   --config DIR     the variant.h/variant.py `setup` wrote (required)
#   --lambda X       0.0 = game results only (default), 1.0 = search scores only
#   --epochs N       passes of 20M positions (default 20)
#   --out NAME       the net to write (default pocketknight-<lambda>-<epochs>.nnue)
#   --trainer DIR    an existing variant-nnue-pytorch checkout (default: clone the pin)
#   --resume FILE    continue from a .nnue or .pt
#   --keep-captures  do not skip positions whose move was a capture
#
# What it does, each step the trainer wiki's: clone the pinned trainer, copy
# the variant files into it, install the requirements (CUDA PyTorch, CuPy),
# build the C++ data loader, train, then serialize the last checkpoint to an
# .nnue Fairy-Stockfish loads with `EvalFile`.
#
# The result label is what `--lambda 0` learns from: `extract` wrote it from
# the side to move's point of view.  A blend (`--lambda 0.3`) needs a dataset
# built from `score`d records, or the score side of the loss is all zeros.
#
# Kaggle (free GPU, 30 h/week, 12 h sessions): upload the two .bin files and
# the trainer-config directory as a dataset, open a GPU notebook with internet
# on, and run this script from a cell:
#   !bash /kaggle/input/<dataset>/train.sh /kaggle/input/<dataset>/pocketknight.bin \
#        /kaggle/input/<dataset>/pocketknight.val.bin --config /kaggle/input/<dataset>/trainer-config \
#        --out /kaggle/working/pocketknight.nnue
# Save the .nnue from /kaggle/working before the session ends.
set -euo pipefail

TRAINER_URL=https://github.com/fairy-stockfish/variant-nnue-pytorch.git
TRAINER_SHA=b15df38a9aae8ab9b40b2378020b3099c7c5d179
FEATURES='HalfKAv2^'

TRAIN=${1:?training .bin}; VAL=${2:?validation .bin}; shift 2
CONFIG=""; LAMBDA=0.0; EPOCHS=20; OUT=""; TRAINER=""; RESUME=""; SKIP="--smart-fen-skipping"
while [[ $# -gt 0 ]]; do
  case $1 in
    --config) CONFIG=$2; shift 2 ;;
    --lambda) LAMBDA=$2; shift 2 ;;
    --epochs) EPOCHS=$2; shift 2 ;;
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
OUT=${OUT:-pocketknight-lambda${LAMBDA}-e${EPOCHS}.nnue}
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

python3 -c 'import torch, cupy' 2>/dev/null || pip install -q -r requirements.txt
python3 -c 'import torch; assert torch.cuda.is_available(), "no CUDA device"'

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

echo "training: lambda=$LAMBDA epochs=$EPOCHS features=$FEATURES $SKIP"
python3 train.py "$TRAIN" "$VAL" \
  --features="$FEATURES" --lambda "$LAMBDA" --max_epochs "$EPOCHS" \
  --gpus 1 --threads 2 --num-workers 2 $SKIP "${RESUME_ARGS[@]}"

LAST=$(ls -t logs/default/version_*/checkpoints/last.ckpt | head -1)
python3 serialize.py --features="$FEATURES" "$LAST" "$OUT" \
  --description "pocketknight NNUE, lambda=$LAMBDA, $EPOCHS epochs, FICS bughouse outcomes"
echo "wrote $OUT"
echo "gate it: python3 -m bughouse_nnue evaluate --net $OUT"
