#!/usr/bin/env bash
#
# 真正的「本地多进程」场景（评分测试，需 -DUNO_GRADING_TESTS=ON）：
# 一个 host 进程 + 两个 client 进程，通过本地房间交换真实协议消息。
#
# 脚本不关心你的内部设计，只要求外部契约成立：
#   * 客户端连上后会发出 JOIN；
#   * host 认识两个玩家，并且能开局；
#   * 客户端收到 START 并切换阶段；
#   * 全流程不再出现框架的 TODO 占位提示。
set -euo pipefail

uno=${1:?usage: room_scenario.sh /path/to/uno}
score_tool=${2:-} # 可选：写评分文件的小工具（见 tests/support/score.h）
room="scenario-$$"
tmp=$(mktemp -d)

# 评分文件按「实际检查了几项、失败几项」记录：
#   * 前置条件（socket、进程、连接）失败说明这一轮根本没测成，不写评分文件；
#   * 学生实现的检查逐项计分，跑到哪一项挂掉就按已检查的项数结算。
checked=0
failed=0
write_score() {
    if [[ -n "$score_tool" ]]; then
        "$score_tool" room_scenario 1 "$checked" "$failed" >/dev/null 2>&1 || true
    fi
}

mkdir -p "${XDG_RUNTIME_DIR:-/tmp/uno-$(id -u)}/uno"
socket="${XDG_RUNTIME_DIR:-/tmp/uno-$(id -u)}/uno/$room.sock"

pids=()
cleanup() {
    exec 3>&- 4>&- 5>&- 2>/dev/null || true
    for pid in "${pids[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    rm -rf "$tmp"
}
trap cleanup EXIT

# 前置条件不满足：这一轮没测成，不写评分文件（读不到文件按 0 分处理）。
infra_fail() {
    report "$1" "无法开始测试"
    exit 1
}

# 学生实现的检查失败了：记这一项，然后收尾。
check_fail() {
    checked=$((checked + 1))
    failed=$((failed + 1))
    write_score
    report "$1" "检查失败"
    exit 1
}

report() {
    printf 'room scenario failure: %s（%s）\n' "$1" "$2" >&2
    for log in host alice bob; do
        if [[ -s "$tmp/$log.log" ]]; then
            printf '%s\n' "--- $log.log ---" >&2
            cat "$tmp/$log.log" >&2
        fi
    done
}

# 等到某个日志文件里出现指定的模式。
wait_for() {
    local file=$1 pattern=$2 attempts=${3:-200}
    for ((i = 0; i < attempts; ++i)); do
        if grep -q -- "$pattern" "$file" 2>/dev/null; then return 0; fi
        sleep 0.02
    done
    return 1
}

mkfifo "$tmp/host.in" "$tmp/alice.in" "$tmp/bob.in"

"$uno" --room="$room" --name=Host --seed=42 <"$tmp/host.in" \
    >"$tmp/host.log" 2>&1 &
host_pid=$!
pids+=("$host_pid")
exec 3>"$tmp/host.in" # 保持写端打开，否则 host 会立刻看到 EOF

for ((i = 0; i < 200; ++i)); do
    [[ -S "$socket" ]] && break
    sleep 0.02
done
[[ -S "$socket" ]] || infra_fail "the host never opened room $room"
grep -q 'Listening on room' "$tmp/host.log" ||
    infra_fail "the host did not announce its room"

"$uno" --join --room="$room" --name=Alice <"$tmp/alice.in" \
    >"$tmp/alice.log" 2>&1 &
alice_pid=$!
pids+=("$alice_pid")
exec 4>"$tmp/alice.in"

"$uno" --join --room="$room" --name=Bob <"$tmp/bob.in" \
    >"$tmp/bob.log" 2>&1 &
bob_pid=$!
pids+=("$bob_pid")
exec 5>"$tmp/bob.in"

# 从这里开始都是「学生实现应该产生的结果」，逐项计分。
wait_for "$tmp/alice.log" 'Joined room' 200 ||
    infra_fail "the client process never joined the room"

wait_for "$tmp/host.log" 'JOIN' 300 || check_fail "the host never saw a JOIN"
checked=$((checked + 1))
wait_for "$tmp/alice.log" 'WELCOME' 300 ||
    check_fail "Alice never received WELCOME"
checked=$((checked + 1))
wait_for "$tmp/bob.log" 'WELCOME' 300 || check_fail "Bob never received WELCOME"
checked=$((checked + 1))

printf 'start\n' >&3
wait_for "$tmp/alice.log" 'START' 300 || check_fail "Alice never received START"
checked=$((checked + 1))
wait_for "$tmp/bob.log" 'START' 300 || check_fail "Bob never received START"
checked=$((checked + 1))

if grep -q 'TODO' "$tmp/host.log" "$tmp/alice.log" "$tmp/bob.log"; then
    check_fail "the scenario still emits framework TODO guidance"
fi
checked=$((checked + 1))

# 让所有人干净地退出：关掉三个进程的标准输入即可。
exec 3>&- 4>&- 5>&-
for pid in "$host_pid" "$alice_pid" "$bob_pid"; do
    wait "$pid" 2>/dev/null || true
done
pids=()

printf 'room scenario tests passed\n'
write_score
