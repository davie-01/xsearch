#!/bin/bash
# Run from Terminal/Finder, outside an automation runner's restricted sandbox.
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
sample="${1:?用法：bash scripts/run-permission-probe.command 授权样本文件}"
probe="$PWD/work/m0/PermissionProbe.app/Contents/MacOS/PermissionProbe"
if [[ ! -x "$probe" ]]; then
  echo '请先按 README 构建原生权限探针。'
  exit 1
fi
set +e
"$probe" "$sample" > work/m0/permission-user-session.json 2>work/m0/permission-user-session.stderr
status=$?
set -e
cat work/m0/permission-user-session.json
if [[ "$status" -eq 0 ]]; then
  echo '主应用、XPC 服务、子进程均成功只读访问样本。结果已保存。'
else
  echo '权限链路尚未通过。诊断结果已保存，不会修改样本或系统权限。'
fi
read -r -p '按回车关闭窗口。' answer
exit "$status"
