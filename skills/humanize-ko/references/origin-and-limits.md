# 출처와 적용 한계

## 원본

- 프로젝트: [yourbright-jp/humanizer-jp](https://github.com/yourbright-jp/humanizer-jp)
- 참조 commit: `e252b87c39270a0b9359c1e1e1f8d48b710ff4de`
- 참조 파일: `.claude/skills/humanize-jp/SKILL.md`, `reference/humanize_check.py`
- License: MIT, Copyright (c) 2026 yourbright-jp

원본에서 가져온 핵심은 문장 리듬을 먼저 보고, 의미를 보존하며, 상투 표현을 맥락에 따라 줄이고, 과도한 수정은 피한다는 workflow다.

## 한국어에 그대로 옮기지 않은 것

원본의 corpus는 일본어 인간 글 1,105편과 Claude 글 1,105편이다. 다음 결과는 한국어에서 검증되지 않았으므로 이 skill의 기준으로 사용하지 않는다.

- 인간·AI 문장 길이 중앙값과 `CV >= 0.70` 목표
- AI 글의 99%가 인간 글보다 균일하다는 비율의 한국어 일반화
- 일본어의 히라가나·가타카나·한자 비율
- `整理する`, `一方`, `といえます` 등 일본어 tell 목록
- 일본어 benchmark로 만든 AI·인간 판정과 종합 점수

한국어 진단 script의 경고값은 편집할 위치를 찾기 위한 heuristic이다. 사람과 AI를 구분하거나 검색 플랫폼의 판별을 피한다는 뜻이 아니다.

## 사용하지 않는 목적

- AI detector 또는 플랫폼 검수를 우회하기
- 표절한 글의 출처를 감추기
- 쓰지 않은 제품의 사용기나 존재하지 않는 경험 만들기
- 가짜 후기, 실적, 매출, 통계 만들기
- 의도적 오탈자나 비문을 넣어 사람인 척하기

출처를 조사해 새 글을 만드는 일과 문체를 다듬는 일은 별도 단계다. 이 skill은 후자만 담당한다.
