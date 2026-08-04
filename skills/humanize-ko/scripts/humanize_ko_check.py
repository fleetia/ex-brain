#!/usr/bin/env python3
"""Report Korean prose rhythm and boilerplate without assigning an AI score."""

from __future__ import annotations

import argparse
import re
import statistics
import sys
from pathlib import Path


CODE_FENCE_PATTERN = re.compile(r"```.*?```", re.DOTALL)
INLINE_CODE_PATTERN = re.compile(r"`[^`]*`")
MARKDOWN_LINK_PATTERN = re.compile(r"\[([^\]]+)\]\([^)]*\)")
URL_PATTERN = re.compile(r"https?://\S+")
SENTENCE_BOUNDARY_PATTERN = re.compile(r"(?<=[.!?。！？])(?:\s+|$)")

WATCH_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("글을 예고하는 도입", re.compile(r"(?:이번|이|본)\s*(?:글|포스팅|콘텐츠)에서는")),
    ("알아보겠습니다/살펴보겠습니다", re.compile(r"(?:알아|살펴|정리해|소개해)\s*보겠습니다")),
    ("도움이 될 수 있습니다", re.compile(r"도움이\s*될\s*수\s*있습니다")),
    ("활용할 수 있습니다", re.compile(r"활용할\s*수\s*있습니다")),
    ("하는 것이 중요합니다", re.compile(r"하는\s*것이\s*중요합니다")),
    ("라고 할 수 있습니다", re.compile(r"라고\s*(?:할|볼)\s*수\s*있습니다")),
    ("결론형 상투어", re.compile(r"(?:결론적으로|요약하면|정리하면|이상으로)")),
    ("막연한 평가어", re.compile(r"(?:효율적|효과적|강력한|다양한)")),
)

CONNECTOR_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = tuple(
    (connector, re.compile(rf"(?<![가-힣]){connector}(?![가-힣])"))
    for connector in ("먼저", "다음으로", "마지막으로", "또한", "한편", "따라서", "즉", "결론적으로")
)

FORMAL_ENDING_PATTERN = re.compile(
    r"(?:합니다|됩니다|입니다|있습니다|없습니다|겠습니다|싶습니다|보입니다)[.!?。！？]?$"
)
CASUAL_ENDING_PATTERN = re.compile(r"(?:해요|돼요|있어요|없어요|예요|이에요)[.!?。！？]?$")
PLAIN_ENDING_PATTERN = re.compile(r"(?:한다|된다|있다|없다|했다|였다|이다)[.!?。！？]?$")


def remove_non_prose(text: str) -> str:
    without_code = CODE_FENCE_PATTERN.sub("", text)
    without_inline_code = INLINE_CODE_PATTERN.sub("", without_code)
    with_link_labels = MARKDOWN_LINK_PATTERN.sub(r"\1", without_inline_code)
    without_urls = URL_PATTERN.sub("", with_link_labels)

    prose_lines: list[str] = []
    for line in without_urls.splitlines():
        stripped = line.strip()
        if not stripped:
            prose_lines.append("")
            continue
        if stripped.startswith((">", "|")):
            continue
        if re.match(r"^#{1,6}\s*", stripped):
            continue
        if re.match(r"^[-*+]\s+", stripped) or re.match(r"^\d+[.)]\s+", stripped):
            continue
        normalized = re.sub(r"[*_~]", "", stripped)
        prose_lines.append(normalized)

    return "\n".join(prose_lines)


def split_sentences(text: str) -> list[str]:
    prose = remove_non_prose(text)
    return split_prose_sentences(prose)


def split_prose_sentences(prose: str) -> list[str]:
    parts = SENTENCE_BOUNDARY_PATTERN.split(prose)
    return [part.strip() for part in parts if len(re.sub(r"\s", "", part)) >= 2]


def get_sentence_lengths(sentences: list[str]) -> list[int]:
    return [len(re.sub(r"\s", "", sentence)) for sentence in sentences]


def calculate_cv(lengths: list[int]) -> float:
    if not lengths:
        return 0.0
    mean_length = statistics.fmean(lengths)
    if mean_length == 0:
        return 0.0
    return statistics.pstdev(lengths) / mean_length


def count_uniform_windows(lengths: list[int], window_size: int = 4) -> int:
    if len(lengths) < window_size:
        return 0

    count = 0
    for start in range(len(lengths) - window_size + 1):
        window = lengths[start : start + window_size]
        shortest = min(window)
        if shortest == 0:
            continue
        if max(window) / shortest <= 1.35:
            count += 1
    return count


def classify_ending(sentence: str) -> str:
    compact = sentence.strip()
    if FORMAL_ENDING_PATTERN.search(compact):
        return "-습니다"
    if CASUAL_ENDING_PATTERN.search(compact):
        return "-해요"
    if PLAIN_ENDING_PATTERN.search(compact):
        return "-다"
    return "other"


def get_longest_ending_run(sentences: list[str]) -> tuple[str, int]:
    longest_label = "other"
    longest_run = 0
    current_label = ""
    current_run = 0

    for sentence in sentences:
        label = classify_ending(sentence)
        if label == current_label:
            current_run += 1
        else:
            current_label = label
            current_run = 1
        if label != "other" and current_run > longest_run:
            longest_label = label
            longest_run = current_run

    return longest_label, longest_run


def count_pattern_hits(text: str, patterns: tuple[tuple[str, re.Pattern[str]], ...]) -> list[tuple[str, int]]:
    return [
        (label, len(pattern.findall(text)))
        for label, pattern in patterns
        if pattern.search(text)
    ]


def describe_cv(cv: float) -> str:
    if cv < 0.40:
        return "문장 길이가 꽤 고르게 이어집니다. 단조로운 구간만 다시 읽어보세요."
    if cv > 0.95:
        return "길이 차가 큽니다. 자연스러운 강조인지, 문장이 잘게 부서진 결과인지 확인하세요."
    return "길이 편차가 한쪽으로 치우치지 않았습니다. 수치보다 실제 문맥을 우선하세요."


def build_report(text: str) -> str:
    prose = remove_non_prose(text)
    sentences = split_prose_sentences(prose)
    if len(sentences) < 3:
        return "문체를 점검하려면 마침표로 끝나는 prose 문장이 3개 이상 필요합니다."

    lengths = get_sentence_lengths(sentences)
    cv = calculate_cv(lengths)
    uniform_windows = count_uniform_windows(lengths)
    comma_count = prose.count(",") + prose.count("，")
    sentences_without_comma = sum(1 for sentence in sentences if "," not in sentence and "，" not in sentence)
    comma_per_sentence = comma_count / len(sentences)
    no_comma_ratio = sentences_without_comma / len(sentences)
    ending_label, ending_run = get_longest_ending_run(sentences)
    watch_hits = count_pattern_hits(prose, WATCH_PATTERNS)
    connector_hits = count_pattern_hits(prose, CONNECTOR_PATTERNS)

    lines = [
        "=" * 58,
        "한국어 문체 점검 — AI 판별 점수가 아닌 편집용 heuristic",
        "=" * 58,
        f"문장 수: {len(sentences)}",
        f"문장 길이: 평균 {statistics.fmean(lengths):.1f}자 / 범위 {min(lengths)}–{max(lengths)}자 / CV {cv:.2f}",
        f"비슷한 길이의 4문장 연속 구간: {uniform_windows}개",
        f"문장당 쉼표: {comma_per_sentence:.2f}개 / 쉼표 없는 문장: {no_comma_ratio:.0%}",
        f"같은 높임 종결형의 최장 연속: {ending_label} {ending_run}문장",
    ]

    if len(sentences) < 10:
        lines.extend(("", "표본이 10문장 미만이라 수치 해석보다 직접 읽기를 우선하세요."))

    lines.extend(("", describe_cv(cv), "", "상투 표현:"))

    if watch_hits:
        lines.extend(f"- {label}: {count}회" for label, count in watch_hits)
    else:
        lines.append("- 두드러진 상투 표현이 없습니다.")

    lines.append("")
    lines.append("접속어:")
    if connector_hits:
        lines.extend(f"- {label}: {count}회" for label, count in connector_hits)
    else:
        lines.append("- 점검 대상 접속어가 없습니다.")

    lines.extend(
        (
            "",
            "경고가 곧 수정 명령은 아닙니다. 표시된 문단을 소리 내어 읽고 실제로 단조롭거나 모호할 때만 고치세요.",
        )
    )
    return "\n".join(lines)


def parse_args(args: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", help="Markdown/text file path, or '-' for stdin")
    return parser.parse_args(args)


def read_text(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    return Path(path).read_text(encoding="utf-8")


def main(args: list[str] | None = None) -> int:
    parsed = parse_args(sys.argv[1:] if args is None else args)
    try:
        text = read_text(parsed.path)
    except (OSError, UnicodeError) as error:
        print(f"입력 파일을 읽지 못했습니다: {error}", file=sys.stderr)
        return 1
    print(build_report(text))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
