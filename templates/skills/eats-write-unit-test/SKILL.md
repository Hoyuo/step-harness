---
name: eats-write-unit-test
description: 게이트 리포트를 근거로 누락된 유닛 테스트를 작성한다.
# ↓ 핵심 한 줄. 이 스킬은 메인 컨텍스트에 "텍스트"로 들어가지 않고 fixer 서브에이전트에서 실행된다.
#   → "스킬만 부르고 지침은 안 따름"이 구조적으로 불가능해진다 (메인은 지침을 보지도 못한다).
#   플러그인에 든 프로필이면 `step-harness:fixer`, 프로젝트 .devin/agents/ 에 복사했다면 `fixer`.
agent: step-harness:fixer
triggers: [model, user]
---
<!-- 템플릿: 실제 스킬 폴더(.devin/skills/eats-write-unit-test/)로 복사해 내용을 채운다 -->

The argument is the path of a gate report file.

1. Read that report.
2. For every failing item in it, write or fix the unit test it asks for.
3. List the files you changed and stop.
