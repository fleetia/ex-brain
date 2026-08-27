---
name: change-verification
description: 제품 동작에 영향을 주는 code·config 변경이 끝났거나 사용자가 제대로 됐는지, 다 끝났는지, 보내도 되는지 확인해 달라고 할 때 사용. 변경 위험에 맞는 최소 충분 evidence를 모아 확인된 것과 미확인 상태를 구분한다. 설명·조사만 한 작업이나 문서만 바꾼 작업에는 자동 적용하지 않는다.
---

# 변경이 실제로 됐는지 확인하기

test 개수를 늘리는 것이 아니라 사용자가 요청한 결과가 어느 범위까지 확인됐는지 증명한다. 확인만 요청받았다면 source·config·snapshot·fixture·persistent local data를 의도적으로 바꾸지 않고 진행하며, 문제를 발견해도 별도 수정 요청 없이 파일을 고치지 않는다.

## 확인할 결과를 다시 세운다

- 최초 요청과 현재 diff에서 사용자가 직접 보거나 수행할 동작을 확인 기준으로 정리한다.
- 변경하지 않기로 한 범위와 별도 승인이 필요한 외부 상태를 구분한다.
- 가장 가까운 project instruction, 기존 test pattern, package script에서 이 변경을 확인하는 표준 방법을 찾는다.

## 위험에 맞는 evidence를 선택한다

모든 변경에 같은 check를 기계적으로 실행하지 않는다. 아래에서 실제 책임을 소유한 가장 가까운 evidence부터 선택한다.

1. diff와 호출 경로를 확인해 요청 밖 변경이나 빠진 경로가 없는지 본다.
2. 변경된 logic·state·interaction을 소유한 기존 test를 실행한다. 이미 승인된 구현 작업 안에서 필요한 대표 regression path가 없을 때만 최소 test를 추가하고, 확인만 요청받았다면 coverage gap만 보고한다.
3. typecheck, lint, build가 이번 변경에서 잡을 수 있는 실패가 있을 때 실행한다.
4. 가능하면 실제 UI, API, CLI 등 사용자가 겪는 흐름을 확인한다.
5. push, deploy, publish 같은 외부 상태는 명시적 승인과 실제 결과 확인이 있을 때만 검증했다고 말한다.

project가 소유한 command도 code를 실행할 수 있으므로 직접 script와 이어지는 `pre*`·`post*` lifecycle script, chained command의 영향을 확인한다. snapshot update option은 verify-only에서 사용하지 않는다. build output·fixture·cache처럼 생성물이 생길 수 있으면 disposable·temp 환경을 우선하고, tracked·unrelated file이나 persistent local data가 바뀔 가능성이 있으면 영향과 복구 방법을 먼저 설명해 승인받는다. 출처가 낯선 repository이거나 package install, network 전송, 실제 계정·데이터 변경 가능성이 있어도 같은 경계를 적용한다. 확인 요청을 이런 외부 효과의 포괄 승인으로 해석하지 않으며, test infrastructure가 없는 project에 이번 확인만을 위해 새 framework를 넣지 않는다.

실행 전후 `git status` 또는 동등한 변경 상태를 대조한다. 예상하지 못한 file·data 변경이 생기면 더 진행하지 않고 그대로 보존해 알리며, 별도 승인 없이 삭제·revert·snapshot 갱신으로 숨기지 않는다.

## 마지막 변경 뒤 다시 실행한다

검증 도중 code나 config가 바뀌었다면 관련 check를 clean 상태에서 다시 실행한다. 수정 전이나 중간 단계의 통과 결과, 관련 없는 build, mock 호출 횟수만으로 최종 동작을 증명하지 않는다.

## 상태를 섞지 않고 보고한다

- **확인됨**: 어떤 command나 실제 흐름에서 무엇을 확인했는지
- **확인하지 못함**: 환경·권한·외부 상태 등 이유와 가장 짧은 다음 확인 방법
- **남은 위험**: 공개나 실제 데이터 사용 전에 판단해야 할 항목
- **전달 상태**: local에만 있는지, commit·push·deploy까지 실제로 확인했는지

결론을 먼저 말하고 사용자가 직접 확인할 가장 짧은 방법을 함께 제공한다. test나 build가 통과해도 실제 화면과 배포를 확인했다고 확대해서 말하지 않는다.
