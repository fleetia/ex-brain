# AI 세션 지식 킷

Claude Code나 Codex로 일한 내용이 세션이 끝나도 사라지지 않게 만드는 킷입니다. 세션을 마칠 때 한 마디로 기록을 남기고, 다음 세션이 그 기록을 자동으로 이어받습니다.

## 왜 필요한가

AI와 일하다 보면 이런 패턴이 반복됩니다.

- 3일 전에 뭘 했는지, 왜 그렇게 결정했는지 기억나지 않는다
- 같은 리서치를 다시 한다
- "나중에 정리해야지" → 영원히 안 한다

대화창이 닫히는 순간 그 안의 맥락은 사라집니다. 이 킷은 **세션 단위로 기록하고, 다음 세션이 그 기록에서 시작하는 구조**를 만듭니다. 기록 습관 하나만 자리 잡아도 "3일 전에 뭘 했더라?"가 해결됩니다.

## 어떻게 동작하나

```
세션에서 작업 ──▶ "세션 종료해줘" ──▶ vault에 기록
                                      (완료·미완료·과정 노트)

새 세션 시작 ──▶ 훅이 진행 중 작업·최근 문서 목록을 자동 주입
                  │
                  ├─ "이어서 하자" ──▶ 기록을 읽고 컨텍스트 복원
                  └─ 새 작업 착수 전 ──▶ 과거 기록을 먼저 검색해서 반영
```

기록은 `~/KnowledgeBase`(이하 vault)라는 폴더에 평범한 markdown 파일로 쌓입니다. Obsidian 같은 노트 앱으로 열어봐도 되고, 그냥 폴더로 둬도 됩니다.

## 구성물

**워크플로우 (기록·복원·조회)**

| 종류 | 이름 | 역할 |
|---|---|---|
| 스킬 | `session-end` | 세션 종료 시 완료·미완료·과정 노트를 기록하고 lint까지 실행 |
| 스킬 | `session-start` | 이전 기록을 읽고 컨텍스트 복원 |
| 스킬 | `kb-lookup` | 새 작업 착수 전에 과거 기록을 먼저 검색 |
| 스킬 | `kb-routing` | 문서를 어느 폴더에 둘지, 인덱스를 어떻게 관리할지 규칙 |
| 스킬 | `weekly-summary` / `monthly-summary` | 주간·월간 요약 생성 — **자동으로 돌지 않고, 요청할 때만** |
| 훅 | `session-context.sh` | 세션이 열릴 때마다 진행 중 작업·최근 문서·vault 상태를 자동 주입 |
| 훅 | `check-pii.sh` | 지원되는 쓰기 tool input에서 이메일·전화번호·토큰 등 민감정보를 저장 전에 검사 |
| 스크립트 | `kb_lint.py` | vault 위생 검사 — 깨진 링크, 인덱스 누락, 폴더-상태 불일치 |
| 템플릿 | `vault-template/` | 지식 폴더 초기 구조 (기록 예시 1개 포함) |

**글쓰기 스킬** — 기록과 별개로, 글을 쓰는 모든 작업에서 Claude가 알아서 참고합니다.

| 이름 | 역할 |
|---|---|
| `humanize-ko` | 한국어 글의 번역투·상투 표현·균일한 리듬을 자연스럽게 다듬기 (진단 스크립트 포함) |
| `cognitive-rhythm-writing` | 처음부터 끝까지 읽는 해설·블로그형 글에 강약과 호흡 만들기 |
| `task-doc-writing` | 회사 전체가 읽는 작업 문서를 체크리스트 뭉치 대신 이해하기 쉬운 서술형으로 |

스킬은 agent가 상황에 맞게 참고하는 지침서이고, 훅은 세션 시작이나 파일 쓰기 직전에 실행되는 스크립트입니다. 설치 사본은 동기화되는 vault가 아니라 `~/.ai-session-kit/runtime/`에 둡니다. vault의 markdown이 local executable로 바로 이어지지 않게 나눈 경계입니다.

vault 위생은 자동으로 관리됩니다. 세션을 종료할 때마다 lint가 돌아서 깨진 링크나 인덱스 누락을 그 자리에서 고치고, 결과 요약 한 줄이 다음 세션 시작 시 함께 주입됩니다.

## 설치

지원 환경은 macOS와 Linux입니다. Windows에서는 WSL 안에 설치할 수 있지만, 그 설정은 WSL에서 실행한 agent에만 적용됩니다. native Windows 앱 설치는 아직 지원하지 않습니다. 기존 JSON 설정에 훅을 합치고 민감정보 검사를 사용하려면 `jq`가 필요하며, 없으면 설치 활성화를 멈춘 뒤 재실행 방법을 안내합니다.

1. 이 폴더를 받아서 아무 곳에나 둡니다
2. 터미널에서 실행합니다:

   ```bash
   bash setup.sh
   ```

   vault를 다른 위치에 만들고 싶으면 경로를 붙입니다. 공백이 있는 경로는 quote로 감쌉니다: `bash setup.sh "$HOME/Library/Mobile Documents/my-vault"`

3. 새 세션을 엽니다. Claude Code는 바로 동작합니다. Codex는 `/hooks`에서 새 command hook을 검토하고 신뢰합니다

여러 번 실행해도 안전합니다. 기존 vault에는 빠진 template 파일만 채우고 기존 문서는 보존합니다. 수정하지 않은 구버전 기본 CLAUDE.md만 새 privacy 규칙으로 migration하고 backup을 남깁니다. 다른 도구가 만든 skill symlink나 폴더와 충돌하면 그대로 보존하고 설치를 멈춥니다. 올바른 JSON에 등록된 다른 hook은 지우지 않고 함께 유지합니다.

스킬은 Claude Code의 `~/.claude/skills/`와 Codex의 `~/.agents/skills/`에 연결됩니다. 훅은 Claude Code의 `~/.claude/settings.json`과 Codex의 `~/.codex/hooks.json`에 각각 등록됩니다. Codex는 새 hook이나 변경된 hook의 hash를 처음 한 번 `/hooks`에서 신뢰해야 실행합니다.

## 일상 사용법

외울 것은 하나뿐입니다. **세션을 마칠 때 "세션 종료해줘"라고 말하기.**

- **세션 종료**: "세션 종료해줘" → 오늘 한 일, 남은 일, 시도했다가 접은 것까지 vault에 기록됩니다
- **세션 시작**: 자동입니다. 진행 중 작업 목록이 알아서 로드되고, "이어서 하자"라고 하면 지난 기록을 읽고 이어갑니다
- **새 작업**: 역시 자동입니다. Claude가 착수 전에 과거 기록을 먼저 검색해서, 예전에 내린 결정이나 했던 리서치를 반영합니다
- **주간·월간 요약**: 필요할 때 "주간 요약 만들어줘" / "월간 요약 만들어줘"라고 요청하면 태스크 기록을 모아 `00.memory/weekly/`, `00.memory/monthly/`에 만들어줍니다. 자동으로 돌지 않으니, 주간 회고나 월간 공유 전에 습관적으로 요청하면 좋습니다

## vault 구조

```
KnowledgeBase/
├── CLAUDE.md          # Claude가 이 폴더를 읽는 법
├── AGENTS.md          # Codex가 이 폴더를 읽는 법
├── 00.memory/tasks/   # 세션 기록 — todo / in-progress / done / cancelled
├── 10.notes/          # 개인 배움·리서치 (INDEX.md로 관리)
├── 20.work/           # 회사·프로젝트 지식 (INDEX.md로 관리)
└── 90.private/        # 개인 기록 — AI가 요청 없이 읽지 않음
```

구버전의 `vault/_kit/`은 자동 삭제하지 않지만 새 hook과 skill symlink는 `~/.ai-session-kit/runtime/`만 사용합니다.

`00.memory`는 일지라서 쌓이기만 하면 되고, `10.notes`와 `20.work`는 위키라서 문서가 추가될 때 INDEX가 함께 갱신됩니다 — 이 관리도 Claude가 `kb-routing` 규칙에 따라 알아서 합니다.

## FAQ

**Q. 기록을 매번 남겨야 하나요?**
아니요. 남길 게 없는 세션은 그냥 닫아도 됩니다. 다만 "이건 다음에 이어서 해야 하는데" 싶은 세션만큼은 종료를 남기는 게 이 시스템의 핵심 습관입니다.

**Q. 이미 Claude/Codex 설정에 다른 훅이 있어요.**
setup.sh는 기존 JSON을 백업한 뒤 이 킷이 소유한 handler만 추가하거나 갱신합니다. 다른 handler는 그대로 둡니다. `jq`가 없거나 JSON이 올바르지 않으면 기존 runtime·hook·skill 연결을 보존한 채 중단하고, 문제를 고친 뒤 같은 명령을 다시 실행하도록 안내합니다.

**Q. 훅이 안 도는 것 같아요.**
터미널에서 `KB_VAULT="$HOME/KnowledgeBase" AI_SESSION_KIT_STATE_DIR="$HOME/.ai-session-kit" bash "$HOME/.ai-session-kit/runtime/hooks/session-context.sh"`를 실행해보세요. 출력이 나오면 훅 자체는 정상이고, 설정 등록 문제입니다. 훅 변경은 새 세션부터 적용된다는 점도 확인하세요.

Codex에서는 `/hooks`도 확인하세요. 설치 또는 업데이트로 command hook이 바뀌면 새 hash를 다시 신뢰해야 합니다.

**Q. 백업은 어떻게 하나요?**
vault는 평범한 markdown 폴더라서 지금은 노트북이 고장 나면 같이 사라집니다. 둘 중 하나를 권합니다: ① vault에서 `git init` 후 주기적으로 커밋하고 private repo에 올리기. ② 내 계정의 비공개 Dropbox, OneDrive, iCloud Drive 폴더 안에 vault를 만들기. AGENTS.md와 CLAUDE.md는 agent 지침이므로, 모르는 사람이 쓸 수 있는 공유 폴더나 public 저장소에는 두지 않습니다. 경로에 공백이 있어도 quote로 감싸면 됩니다. 동기화 전에 여러 컴퓨터에서 같은 파일을 동시에 수정하는 것은 피하세요.

**Q. 지우고 싶어요.**
`bash uninstall.sh`를 실행하면 스킬 연결과 훅 등록이 제거됩니다. vault는 그대로 남으니, 더 이상 필요 없으면 폴더째 지우면 됩니다.

**Q. lint가 뭘 하나요? 꼭 필요한가요?**
문서가 쌓이면 링크가 깨지거나 인덱스에서 빠진 문서가 생기는데, 그걸 AI가 검색할 때 놓치지 않도록 세션 종료 시마다 자동 점검합니다. python3가 필요하지만, 없어도 기록·복원 기능은 정상 동작합니다.

**Q. 규칙을 바꾸고 싶어요.**
배포받아 푼 원본 폴더의 `skills/`를 수정한 뒤 setup.sh를 다시 실행합니다. `~/.ai-session-kit/runtime/`은 installer가 교체하는 설치 사본이므로 직접 수정하지 않습니다. Claude에게 원본 폴더를 보여주고 "session-end 스킬에 ○○ 섹션을 추가한 뒤 다시 설치해줘"라고 시켜도 됩니다.

**Q. 민감정보 차단이 뜨는데요?**
지원되는 파일 쓰기 요청에 이메일·전화번호·API 토큰 같은 패턴이 들어 있다는 뜻입니다. 고객이나 동료의 실명·연락처는 역할명("담당 디자이너", "고객 A")으로 바꿔 저장하는 습관을 권합니다. 예시값이라 괜찮다면 `example.com`, `010-0000-0000` 같은 명백한 placeholder 형태로 바꾸면 통과됩니다.

이 훅은 Claude의 Write/Edit와 Codex의 apply_patch처럼 지원되는 쓰기 tool의 파일명과 저장 결과를 검사하는 보조장치입니다. 이미 존재하는 민감 filename은 SessionStart 목록에서 원문 대신 숨김 건수만 표시합니다. shell redirect, 일부 MCP, 외부 편집기까지 모두 감시하지 않으며 secret 관리 도구를 대체하지 않습니다. 감지 결과에는 원문 secret을 다시 출력하지 않습니다.
