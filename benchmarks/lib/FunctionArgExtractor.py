# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

# FunctionArgExtractor_fixed.py
# task_arg_extractor_simple.py

import re
from typing import List, Tuple, Dict, Any, Optional

# -------------------- small helpers --------------------

def _strip_comments_and_strings(s: str) -> str:
    """
    Remove //..., /*...*/, "..." and '...' contents (keeps newlines).
    This prevents false matches inside comments/strings.
    """
    i, n = 0, len(s)
    out = []
    while i < n:
        ch = s[i]
        # // line comment
        if i+1 < n and s[i:i+2] == "//":
            while i < n and s[i] != "\n":
                out.append(" "); i += 1
            continue
        # /* block comment */
        if i+1 < n and s[i:i+2] == "/*":
            out.append(" "); out.append(" "); i += 2
            while i+1 < n and s[i:i+2] != "*/":
                out.append(" "); i += 1
            if i+1 < n:
                out.append(" "); out.append(" "); i += 2
            continue
        # "string"
        if ch == '"':
            out.append(" "); i += 1
            while i < n:
                if s[i] == "\\" and i+1 < n:
                    out.append(" "); out.append(" "); i += 2
                elif s[i] == '"':
                    out.append(" "); i += 1; break
                else:
                    out.append(" "); i += 1
            continue
        # 'char'
        if ch == "'":
            out.append(" "); i += 1
            while i < n:
                if s[i] == "\\" and i+1 < n:
                    out.append(" "); out.append(" "); i += 2
                elif s[i] == "'":
                    out.append(" "); i += 1; break
                else:
                    out.append(" "); i += 1
            continue
        out.append(ch); i += 1
    return "".join(out)

def _grab_balanced_parens(s: str, start_idx: int) -> Tuple[str, int]:
    """Given s[start_idx] == '(', return (inside_text, index_after_closing_paren)."""
    assert s[start_idx] == "("
    depth = 0
    i = start_idx
    n = len(s)
    while i < n:
        ch = s[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return s[start_idx+1:i], i+1
        elif ch == '"':
            # skip strings
            j = i+1
            while j < n:
                if s[j] == "\\" and j+1 < n: j += 2
                elif s[j] == '"': j += 1; break
                else: j += 1
            i = j; continue
        elif ch == "'":
            # skip char literals
            j = i+1
            while j < n:
                if s[j] == "\\" and j+1 < n: j += 2
                elif s[j] == "'": j += 1; break
                else: j += 1
            i = j; continue
        i += 1
    raise ValueError("Unbalanced parentheses in parameter list")

def _split_commas_balanced(s: str) -> List[str]:
    """Split by commas that are not inside (), <> or []."""
    parts, buf = [], []
    dp = da = db = 0  # () <> []
    for ch in s:
        if ch == "(": dp += 1
        elif ch == ")": dp = max(0, dp-1)
        elif ch == "<": da += 1
        elif ch == ">": da = max(0, da-1)
        elif ch == "[": db += 1
        elif ch == "]": db = max(0, db-1)
        elif ch == "," and dp == da == db == 0:
            part = "".join(buf).strip()
            if part: parts.append(part)
            buf.clear(); continue
        buf.append(ch)
    tail = "".join(buf).strip()
    if tail: parts.append(tail)
    return parts

# -------------------- strict ARG parser --------------------

VALID_DIRECTIONS = {"IN", "OUT", "INOUT"}
VALID_ACCESS     = {"FULL", "PARTIAL", "PARTIAL_UNTRACKED"}

def _parse_ARG_param_text(param_text: str) -> Tuple[Optional[str], Optional[Dict[str, str]], Optional[str]]:
    """
    Expect:  ARG(DIR, ACCESS, TYPE) NAME
    Returns: (name, {"direction","access","type"}, error_or_None)
    """
    t = param_text.strip()
    if "=" in t:
        return None, None, "default argument not allowed"
    m = re.match(r"^\s*ARG\s*\(", t, re.S)
    if not m:
        return None, None, "expected ARG(DIR, ACCESS, TYPE) <name>"

    # find closing ')'
    start = m.end() - 1
    depth = 0
    i = start
    while i < len(t):
        ch = t[i]
        if ch == "(": depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0: break
        i += 1
    if i >= len(t) or depth != 0:
        return None, None, "unbalanced parentheses in ARG(...)"

    inner = t[start+1:i]
    args = _split_commas_balanced(inner)
    if len(args) != 3:
        return None, None, "ARG(...) must have exactly 3 arguments"

    direction = args[0].strip()
    access    = args[1].strip()
    ctype     = args[2].strip()

    if direction not in VALID_DIRECTIONS:
        return None, None, f"invalid direction '{direction}'"
    if access not in VALID_ACCESS:
        return None, None, f"invalid access '{access}'"

    rest = t[i+1:].strip()
    mname = re.fullmatch(r"[A-Za-z_]\w*", rest)
    if not mname:
        return None, None, "identifier must appear immediately after ARG(...)"
    name = mname.group(0)

    return name, {"direction": direction, "access": access, "type": ctype}, None

# -------------------- main API --------------------

_TASK_FUNC_RE = re.compile(r"\bTASK\b\s*([A-Za-z_]\w*)\s*\(", re.M)

def parse_task_functions(text: str) -> Dict[str, Any]:
    """
    Return: { func_name: { "args": [ {direction, access, type, name}, ... ] } }
    Scans the whole file; no Tree-sitter required.
    """
    clean = _strip_comments_and_strings(text)
    out: Dict[str, Any] = {}
    errors: List[str] = []

    for m in _TASK_FUNC_RE.finditer(clean):
        name = m.group(1)
        paren_open = clean.find("(", m.end()-1)
        if paren_open == -1:
            continue
        try:
            params_inner, _ = _grab_balanced_parens(clean, paren_open)
        except ValueError:
            # skip malformed
            continue

        args_list = []
        for seg in _split_commas_balanced(params_inner):
            if not seg.strip():
                continue
            pname, info, err = _parse_ARG_param_text(seg)
            if pname is None:
                errors.append(f"[{name}] {err}. Found: {seg}")
                args_list = None
                break
            args_list.append({**info, "name": pname})
        if args_list is not None:
            out[name] = {"args": args_list}

    # If you want to see why something was skipped:
    # if errors: print("\n".join(errors), file=sys.stderr)

    return out

# Convenience: parse from file path
def parse_functions_with_arg_macros(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return parse_task_functions(f.read())
