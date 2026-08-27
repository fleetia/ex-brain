# Project identity

개발 태스크와 특정 codebase에 종속된 `20.work` 문서에서 같은 `project` 값을 만들 때 사용한다. 목적은 folder명이나 worktree명이 달라져도 같은 codebase를 찾고, 다른 project의 결정을 섞지 않는 것이다. 이 값은 같은 checkout·branch·working tree를 보고 있다는 증거가 아니며, 실제 code state는 session-start에서 별도로 대조한다.

## Canonical key

다음 순서에서 처음 확정할 수 있는 값을 사용한다.

1. 현재 작업을 소유한 Git repository의 검증된 network `origin` remote가 있으면 `host/repository-path`를 사용한다. protocol, credential, port, leading slash와 `.git`은 제거하고 host는 lowercase, path의 대소문자는 보존한다. 예: `github.com/owner/repository`, `git.example.com/group/subgroup/repository`. SSH host alias는 임의로 실제 host라고 추정하지 않고 설정된 값을 provisional key로 사용한다.
2. monorepo 안의 특정 workspace에만 해당하는 작업이면 repository key 뒤에 검증된 workspace package name을 붙인다. 예: `github.com/owner/repository#@scope/package`.
3. remote가 없으면 `package.json`, `pyproject.toml` 같은 project manifest의 명시적인 package·project name을 사용한다. `app`처럼 여러 곳에 흔한 이름이라 project를 유일하게 식별하지 못하면 다음 단계로 간다.
4. 위 값이 없거나 후보가 여러 개면 folder basename을 자동으로 사용하지 않는다. 사용자에게 짧은 project key 하나를 확인한다.

local path나 `file://` remote는 machine마다 달라질 수 있고 개인 경로를 노출하므로 project key로 사용하지 않는다.

YAML에는 항상 quoted string으로 기록한다.

```yaml
project: "github.com/owner/repository"
```

absolute path, 사용자 home, branch명, 임시 worktree 이름은 `project` 값에 저장하지 않는다. 두 기록은 정규화된 key가 정확히 같을 때만 같은 project로 자동 판단한다. `project`가 없는 legacy 기록은 후보로 제시할 수 있지만 자동 선택·병합하지 않는다.

같은 repository를 기기나 도구마다 SSH alias와 HTTPS처럼 다른 remote 표기로 열면 key가 달라질 수 있다. 이때 새 key로 별도 기록을 만들거나 두 기록을 자동 병합하지 않는다. live remote와 repository evidence를 보여주고 같은 codebase인지 사용자에게 확인한 뒤, 유지할 stable key를 하나 고른다. 확인된 범위의 task·project 문서 frontmatter를 그 key로 함께 migration하고 이후에는 current alias가 달라도 확인된 stable key를 재사용한다. SSH 설정을 읽어 alias의 실제 host를 추정하거나, 사용자 확인 없이 public host로 바꾸지 않는다.
