---
name: project-run-and-preview
description: 사용자가 project를 실행해 달라거나 결과를 어디서 보는지, local 화면·미리보기를 열어 달라고 명시적으로 요청할 때 사용. project가 소유한 실행 방법을 찾아 local에서 시작하고 실제 접근 여부와 종료 방법을 안내한다. 새 project 생성, production deploy, 원격 server fallback에는 사용하지 않는다.
---

# Project를 실행하고 결과 보여주기

사용자가 command와 port를 추측하지 않아도 현재 project의 결과를 직접 볼 수 있게 한다. 실행 중이라는 log만 보여주지 말고 실제로 어디에서 무엇을 확인할 수 있는지까지 연결한다.

## Project가 소유한 실행 방법을 찾는다

- 가장 가까운 project instruction과 README, package script, build config에서 entry point와 권장 start command를 확인한다.
- repository command와 package script도 실행되는 code다. 시작 전에 직접 command뿐 아니라 이어서 호출되는 `pre*`·`post*` lifecycle script와 chained command까지 확인한다.
- 여러 application이 있으면 현재 요청과 명확히 일치하는 대상을 고른다. 판단 근거가 없을 때만 권장안과 함께 어느 것을 열지 묻는다.
- source 변경 전에 dependency 설치 상태, local package build, 필요한 환경 설정과 이미 사용 중인 port를 확인한다.
- build가 빠져 생긴 localhost 오류라면 먼저 기존 build 방법을 안내하거나 실행한다. 새 dependency 설치가 필요하면 이유와 영향을 설명하고 승인을 받는다.

## Local에서 안전하게 실행한다

- repository가 제공하는 command를 사용하고 임의의 framework나 start 설정을 추가하지 않는다.
- 기본값은 local이다. local 실행이 실패해도 원격 server, production data, 다른 계정으로 조용히 바꾸지 않는다.
- 출처가 낯선 repository이거나 command가 package install, network, 계정·실제 데이터 접근, 외부 전송·변경을 일으킬 수 있으면 안전한 격리 방법을 사용하거나 영향과 이유를 설명해 승인을 받는다. "실행해줘"라는 요청은 local 미리보기에 필요한 process 실행만 허용하며 이런 외부 효과까지 포괄하지 않는다.
- secret을 source, chat, 지식 vault에 붙여 넣게 하지 않는다. 계정 접근이나 외부 연결이 필요하면 먼저 이유와 범위를 설명한다.
- 오래 실행되는 process는 다시 확인하거나 종료할 수 있는 방식으로 시작한다.

## 실제 미리보기를 확인한다

- process가 떠 있다는 사실과 사용자가 결과에 접근할 수 있다는 사실을 구분한다.
- 가능한 도구가 있으면 안내할 URL이나 화면을 직접 열어 loading 실패, 명백한 runtime error, 잘못된 entry page가 없는지 확인한다.
- 화면을 임의로 고치거나 redesign하지 않는다. 발견한 문제는 실행 결과와 분리해 알리고, 수정은 사용자가 요청한 뒤 진행한다.

완료할 때는 다음만 알려준다.

- 무엇을 실행했는지
- 사용자가 열 주소나 확인할 화면
- 정상이라면 처음 보여야 할 결과
- process를 멈추고 다시 시작하는 가장 짧은 방법
- 아직 필요한 설정이나 확인하지 못한 항목

local 미리보기 성공을 deploy·publish 완료로 표현하지 않는다.
