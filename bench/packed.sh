#!/usr/bin/env bash
set -euo pipefail
mkdir -p results
image=hosted-test-os
docker build -t "$image" -f - /tmp/empty-docker-context <<'DOCKER'
FROM ubuntu:24.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ca-certificates ffmpeg sox git libgomp1 && rm -rf /var/lib/apt/lists/*
DOCKER
python_home=$(.venv/bin/python -c 'import sys;print(sys.base_prefix)')
mounts=(-v "$PWD:$PWD:ro" -v "$PWD/results:/results" -w "$PWD")
if [[ "$python_home" != "$PWD"* && "$python_home" != /usr ]]; then mounts+=(-v "$python_home:$python_home:ro"); fi
mapfile -t masks < <(python3 - <<'PY'
import os
n=sorted(os.sched_getaffinity(0))
for cpus in (n,n[:len(n)//2],n[len(n)//2:]):print(','.join(map(str,cpus)))
PY
)
files=(tests/unit_test/pipeline/test_session_observability.py tests/unit_test/pipeline/test_native_child_processes.py tests/unit_test/personaplex/test_code2wav_batch.py tests/unit_test/pipeline/test_ipc.py tests/unit_test/pipeline/test_process_failure.py tests/unit_test/personaplex/test_code2wav_stream.py tests/unit_test/pipeline/test_process_replicas_runtime.py tests/unit_test/personaplex/test_mimi_streaming.py tests/unit_test/pipeline/test_weight_share_runner_wiring.py tests/unit_test/pipeline/test_coordinator.py tests/unit_test/personaplex/test_session_hooks.py tests/unit_test/scheduling/test_threaded_simple_scheduler.py)
docker run --rm "${mounts[@]}" -e PYTHONPATH="$PWD" "$image" .venv/bin/python -c 'import torch,pytest;print(torch.__version__)'
run_part() {
    local arm=$1 part=$2 mask=$3 rc=0 tag="$1-$2"
    docker run --rm --shm-size=1g --cpuset-cpus="$mask" "${mounts[@]}" \
      -e CUDA_VISIBLE_DEVICES= -e PYTHONPATH="$PWD" "$image" \
      .venv/bin/python -m pytest "${files[@]}" -v -m 'not benchmark and not accelerator' -p no:cacheprovider \
      -p scripts.ci.utils.pytest_partition --auto-partition-id "$part" --auto-partition-size 2 \
      --partition-model-file .github/unit_test_durations.json --junitxml="/results/$tag.xml" > "results/$tag.log" 2>&1 || rc=$?
    echo "$rc" > "results/$tag.rc"
    tail -n 3 "results/$tag.log"
}
for arm in serial-1 parallel-1 parallel-2 serial-2; do
    start=$(date +%s)
    if [[ $arm == serial-* ]]; then
        run_part "$arm" 0 "${masks[0]}"
        run_part "$arm" 1 "${masks[0]}"
    else
        run_part "$arm" 0 "${masks[1]}" &
        first=$!
        run_part "$arm" 1 "${masks[2]}" &
        second=$!
        wait "$first"; wait "$second"
    fi
    echo "$arm $(( $(date +%s) - start ))" | tee -a results/times
done
! grep -Lx '0' results/*.rc | grep .
