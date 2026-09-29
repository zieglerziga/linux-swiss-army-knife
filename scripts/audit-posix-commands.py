#!/usr/bin/env python3
"""Fail when a POSIX collector command is outside its explicit allowlist."""

from __future__ import annotations

import re
import shlex
import sys
from pathlib import Path


ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
FUNCTION = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)", re.MULTILINE)
OUTPUT_REDIRECTION = re.compile(r"^(?:[0-9]*)(>>?)(.*)$")
ARITHMETIC = re.compile(r"\$\(\([^\n]*?\)\)")
PARAMETER = re.compile(r"\$\{[^{}\n]*\}")
BUILTINS = {
    "break",
    "continue",
    "exit",
    "false",
    "return",
    "set",
    "shift",
    "test",
    "true",
}


class AuditError(RuntimeError):
    pass


def remove_heredoc_bodies(source: str) -> str:
    output: list[str] = []
    delimiter: str | None = None
    heredoc = re.compile(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")
    for line in source.splitlines(keepends=True):
        if delimiter is not None:
            if line.rstrip("\r\n\t") == delimiter:
                delimiter = None
            continue
        output.append(line)
        match = heredoc.search(line)
        if match:
            delimiter = match.group(1)
    if delimiter is not None:
        raise AuditError(f"unterminated heredoc: {delimiter}")
    return "".join(output)


def normalize_source(source: str) -> str:
    """Turn unquoted newlines into separators without touching awk/sed programs."""
    source = remove_heredoc_bodies(source)
    output: list[str] = []
    quote: str | None = None
    escaped = False
    comment = False
    index = 0
    while index < len(source):
        character = source[index]
        if comment:
            if character == "\n":
                output.append(" ; ")
                comment = False
            index += 1
            continue
        if escaped:
            if character != "\n":
                output.extend(("\\", character))
            escaped = False
            index += 1
            continue
        if character == "\\" and quote != "'":
            escaped = True
            index += 1
            continue
        if quote is None and character == "#":
            comment = True
            index += 1
            continue
        if character in ("'", '"'):
            if quote is None:
                quote = character
            elif quote == character:
                quote = None
            output.append(character)
            index += 1
            continue
        if character == "\n" and quote is None:
            output.append(" ; ")
        else:
            output.append(character)
        index += 1
    if quote is not None:
        raise AuditError("unterminated quote")
    normalized = ARITHMETIC.sub("ARITHMETIC", "".join(output))
    return PARAMETER.sub("PARAMETER", normalized)


def tokenize(source: str) -> list[str]:
    lexer = shlex.shlex(normalize_source(source), posix=True, punctuation_chars=";&|()")
    lexer.commenters = ""
    lexer.whitespace_split = True
    try:
        return list(lexer)
    except ValueError as error:
        raise AuditError(str(error)) from error


def audit_redirections(tokens: list[str]) -> None:
    for index, token in enumerate(tokens):
        match = OUTPUT_REDIRECTION.match(token)
        if not match:
            continue
        target = match.group(2)
        if target == "/dev/null":
            continue
        if not target and index + 1 < len(tokens) and tokens[index + 1] in {"/dev/null", "&"}:
            continue
        raise AuditError(f"output redirection is not read-only: {token}")


def audit_commands(source: str, allowed: set[str]) -> set[str]:
    tokens = tokenize(source)
    audit_redirections(tokens)
    functions = set(FUNCTION.findall(source))
    permitted = allowed | BUILTINS | functions
    observed: set[str] = set()
    expect_command = True
    for_header = False
    case_header = False
    case_pattern = False

    for index, token in enumerate(tokens):
        if case_pattern:
            if token == "esac":
                case_pattern = False
                expect_command = False
            elif ")" in token:
                case_pattern = False
                expect_command = True
            continue
        if case_header:
            if token == "in":
                case_header = False
                case_pattern = True
            continue
        if for_header:
            if token == "do":
                for_header = False
                expect_command = True
            continue

        if token == ";;":
            case_pattern = True
            expect_command = False
            continue
        if token == ";":
            expect_command = True
            continue
        if token in {"|", "||", "&&", "("}:
            expect_command = True
            continue
        if token == ")":
            expect_command = False
            continue
        if token == "{":
            expect_command = True
            continue
        if token == "}":
            expect_command = False
            continue
        if token in {"<", "<<", ">", ">>"} or OUTPUT_REDIRECTION.match(token):
            continue
        if not expect_command:
            continue
        if token in {"if", "elif", "while", "until", "then", "else", "do", "!"}:
            expect_command = True
            continue
        if token == "for":
            for_header = True
            continue
        if token == "case":
            case_header = True
            continue
        if token in {"fi", "done", "esac"}:
            expect_command = False
            continue
        if ASSIGNMENT.match(token):
            continue
        if token.startswith("$") or token.startswith("`"):
            raise AuditError(f"dynamic command invocation is forbidden: {token}")

        command = token.rsplit("/", 1)[-1]
        if command not in permitted:
            raise AuditError(f"command is not allowlisted: {command}")
        observed.add(command)
        if command == "command":
            next_token = tokens[index + 1] if index + 1 < len(tokens) else ""
            if next_token != "-v":
                raise AuditError("the command builtin is allowed only for command -v lookups")
        expect_command = False

    return observed


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: audit-posix-commands.py ALLOWLIST COLLECTOR", file=sys.stderr)
        return 2
    allowlist_path = Path(sys.argv[1])
    collector_path = Path(sys.argv[2])
    allowed = {
        line.strip()
        for line in allowlist_path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }
    try:
        observed = audit_commands(collector_path.read_text(encoding="utf-8"), allowed)
    except AuditError as error:
        print(f"{collector_path}: {error}", file=sys.stderr)
        return 1
    unused = sorted(allowed - observed)
    if unused:
        print("allowlist contains commands not found by the audit: " + ", ".join(unused), file=sys.stderr)
        return 1
    print("POSIX command allowlist audit passed: " + ", ".join(sorted(observed)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
