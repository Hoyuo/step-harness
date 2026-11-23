#!/usr/bin/env bash
# 기존 게이트를 하네스의 판정 명령으로 쓰는 예 (flow 의 check / 라우터의 gate 인자).
# 계약은 두 가지뿐이다:
#   1) exit 0 = 통과, 그 외 = 실패
#   2) 실패 시 stdout 에 `HARNESS_ROUTE=<실패 종류>` 한 줄 → flow 의 on.fail 맵에서 다음 액션을 고른다
# 출력 전체는 .step-harness/last-report.txt 로 저장돼 수정 액션에 전달된다.
node scripts/validate-gate.mjs "$@"
code=$?
if [ "$code" -ne 0 ]; then
  # 예: 기존 .harness/validate.json 이 { "fixer": "unit-test" } 같은 값을 갖고 있다면 그대로 route 로 쓴다
  route=$(node -e 'try{const v=require("./.harness/validate.json");console.log(v.fixer||v.next||"")}catch{console.log("")}')
  [ -n "$route" ] && echo "HARNESS_ROUTE=$route"
fi
exit "$code"
