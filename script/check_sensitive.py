#!/usr/bin/env python3
"""Fails when a private term or a credential-shaped string reaches something git would publish.

Run it through script/check_sensitive.sh, which documents the modes. Exit 0 means clean, 1 means
something was found, and 2 means the check could not run. A scan that failed never reads as clean.
"""
import json
import re
import subprocess
import sys
import tempfile

TERMS_FILE = "Local/sensitive-terms.txt"
NAMES_FILE = "Local/private-names.json"
ALLOW_FILE = "Local/sensitive-allow.txt"
EXCLUDED = ("script/check_sensitive.sh", "script/check_sensitive.py")
PUBLIC_REF = "origin/main"

# Chosen, not measured. A term this long is matched anywhere, because `quokkaFoo`, `quokka_x` and
# `myquokka` are all the same leak. Shorter terms need a token boundary, or `age` fires on `courage`
# and `lean` on `cleanObj`.
SUBSTRING_FROM = 6
# Chosen, not measured. Names shorter than this in the private file are ordinary words rather than
# identifiers (`USB`, `REA`). To scan one anyway, put it in the terms file.
DERIVED_MINIMUM = 4

# Credential shapes, deliberately specific. A broad pattern that fires on every test fixture gets
# ignored, and an ignored check is worse than none.
SECRET_REGEX = (
    r"gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}|sk-ant-[A-Za-z0-9_-]{20,}"
    r"|sk-(proj-)?[A-Za-z0-9]{32,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}"
    r"|xox[abprs]-[A-Za-z0-9-]{10,}|ya29\.[A-Za-z0-9_-]{20,}"
    r"|-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----"
)
# An account's real home path says who the account belongs to. `example`, `test`, `user` and
# `Shared` are what documentation and fixtures use.
HOME_REGEX = r"/Users/[A-Za-z0-9._-]+/"
HOME_ALLOWED = re.compile(r"/Users/(example|test|tester|dev|user|you|name|me|Shared|runner|\.\.\.)/")


class ScanFailed(Exception):
    pass


def git(*args, ok=(0,)):
    """Runs git and returns stdout. Any exit code outside `ok` stops the scan."""
    result = subprocess.run(["git", *args], capture_output=True, text=True, errors="replace")
    if result.returncode not in ok:
        raise ScanFailed(f"git {args[0]} failed ({result.returncode}): {result.stderr.strip()[:200]}")
    return result.stdout


def explicit_terms():
    try:
        with open(TERMS_FILE, encoding="utf-8") as handle:
            lines = [line.strip() for line in handle]
    except FileNotFoundError:
        return set()
    return {line.lower() for line in lines if line and not line.startswith("#")}


def derived_terms():
    """Every name in the private file. The terms file drifting behind it is how leaks passed."""
    try:
        with open(NAMES_FILE, encoding="utf-8") as handle:
            names = json.load(handle)
    except FileNotFoundError:
        return set()
    except (OSError, ValueError) as error:
        raise ScanFailed(f"{NAMES_FILE} could not be read: {error}")

    found = set()
    def add(value):
        if isinstance(value, str):
            found.add(value.rstrip("/").rsplit("/", 1)[-1].lower())

    if not isinstance(names, dict):
        raise ScanFailed(f"{NAMES_FILE} is not a JSON object")
    for group in (names.get("repositories") or {}).values():
        for name in group or []:
            add(name)
    for entry in (names.get("operatorRepositories") or []) + (names.get("nestedRepositories") or []):
        add(entry.get("name"))
        add(entry.get("relativePath"))
    for repository, keywords in (names.get("rolloutKeywords") or {}).items():
        add(repository)
        for keyword in keywords or []:
            add(keyword)
    for peer in names.get("peers") or []:
        add(peer.get("alias"))
    for value in (names.get("localAutomation") or {}).values():
        add(value)
    return {term for term in found if len(term) >= DERIVED_MINIMUM}


def is_token_start(text, index):
    if index == 0:
        return True
    before, first = text[index - 1], text[index]
    return not before.isalnum() or not first.isalnum() or before.isdigit() or (before.islower() and first.isupper())


def is_token_end(text, index):
    if index == len(text):
        return True
    last, after = text[index - 1], text[index]
    if not after.isalnum() or not last.isalnum() or after.isdigit():
        return True
    if last.islower() and after.isupper():
        return True
    # An acronym running into the next word, as in `ABCProfile`.
    return last.isupper() and after.isupper() and index + 1 < len(text) and text[index + 1].islower()


def term_in(text, term):
    lowered = text.lower()
    # `lower()` can change a string's length, and then indices stop lining up with `text`.
    if len(lowered) != len(text):
        return term in lowered
    start = lowered.find(term)
    while start != -1:
        end = start + len(term)
        if len(term) >= SUBSTRING_FROM or (is_token_start(text, start) and is_token_end(text, end)):
            return True
        start = lowered.find(term, start + 1)
    return False


def matching_terms(text, terms):
    return [term for term in terms if term in text.lower() and term_in(text, term)]


def load_allow():
    """`path:text` entries: a hit in that file whose line contains that text is not reported."""
    try:
        with open(ALLOW_FILE, encoding="utf-8") as handle:
            lines = [line.rstrip("\n") for line in handle]
    except FileNotFoundError:
        return []
    allow = []
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        path, separator, text = line.partition(":")
        if not separator or not text:
            print(f"note: {ALLOW_FILE} line ignored, it needs path:text: {line[:80]}")
            continue
        allow.append((path, text))
    return allow


def allowed(path, text, allow):
    return any(path == entry_path and entry_text in text for entry_path, entry_text in allow)


def grep(args, pattern_args, tree=None, paths=None):
    """`git grep` hits as (path, line, text). Exit 1 means no match; anything above it is a failure."""
    target = [tree] if tree else []
    limit = paths if paths is not None else ["."]
    output = git("grep", "-I", "-n", "-z", *pattern_args, *args, *target, "--", *limit,
                 *[f":(exclude){path}" for path in EXCLUDED], ok=(0, 1))
    hits = []
    for record in output.split("\n"):
        fields = record.split("\0", 2)
        if len(fields) != 3:
            continue
        name, number, text = fields
        hits.append((name[len(tree) + 1:] if tree else name, number, text))
    return hits


def term_hits(args, terms, patterns, tree=None, paths=None):
    if not terms:
        return []
    return [hit for hit in grep(args, ["-i", "-F", "-f", patterns], tree, paths) if matching_terms(hit[2], terms)]


def carried_terms(derived, patterns):
    """Derived names `origin/main` already holds. They are public, so a hit teaches nothing."""
    if not derived or not git("rev-parse", "--verify", "--quiet", PUBLIC_REF, ok=(0, 1)).strip():
        return set()
    hits = grep([], ["-i", "-F", "-f", patterns], PUBLIC_REF)
    lines = [hit[2] for hit in hits]
    return {term for term in derived if any(term in line.lower() and term_in(line, term) for line in lines)}


def write_patterns(handle, terms):
    handle.seek(0)
    handle.truncate()
    handle.write("".join(term + "\n" for term in sorted(terms)))
    handle.flush()


def scan(label, args, names, terms, patterns, allow, paths=None):
    """Contents, secrets and home paths in one place, then every file name."""
    hits = term_hits(args, terms, patterns, paths=paths)
    hits += grep(args, ["-E", "-e", SECRET_REGEX], paths=paths)
    hits += [hit for hit in grep(args, ["-E", "-e", HOME_REGEX], paths=paths)
             if any(not HOME_ALLOWED.fullmatch(found) for found in re.findall(HOME_REGEX, hit[2]))]
    lines = {f"{path}:{number}:{text}"[:200] for path, number, text in hits if not allowed(path, text, allow)}
    lines |= {f"{name}: file name" for name in names
              if name not in EXCLUDED and matching_terms(name, terms) and not allowed(name, name, allow)}
    if lines:
        print(f"SENSITIVE ({label}):")
        print("\n".join(sorted(lines)))
    return bool(lines)


def scan_commit(commit, terms, patterns):
    """What a commit would publish: file contents, file names, and who and what it says."""
    findings = sorted({hit[0] for hit in term_hits([], terms, patterns, commit)})
    findings += [f"{name} (file name)" for name in git("ls-tree", "-r", "-z", "--name-only", commit).split("\0")
                 if name and name not in EXCLUDED and matching_terms(name, terms)]
    header = git("log", "-1", "--format=%an%n%ae%n%cn%n%ce%n%B", commit)
    findings += [f"commit {field}" for field, text in zip(
        ("author", "author email", "committer", "committer email", "message"),
        header.split("\n", 4)) if matching_terms(text, terms)]
    return findings


def main(argv):
    mode = argv[1] if len(argv) > 1 else "all"
    if mode not in ("all", "--staged", "--history"):
        print("usage: script/check_sensitive.sh [--staged | --history [RANGE]]")
        return 2
    history_range = argv[2] if len(argv) > 2 else f"{PUBLIC_REF}..HEAD"

    explicit, derived = explicit_terms(), derived_terms()
    with tempfile.NamedTemporaryFile("w", suffix=".terms", encoding="utf-8") as handle:
        write_patterns(handle, derived)
        carried = carried_terms(derived, handle.name) - explicit
        terms = sorted(explicit | (derived - carried))
        write_patterns(handle, terms)
        if carried:
            print(f"note: {len(carried)} name(s) in {NAMES_FILE} are already on {PUBLIC_REF}, so they were skipped: "
                  + ", ".join(sorted(carried)))

        if mode == "--history":
            if not terms:
                print(f"no private terms: {TERMS_FILE} and {NAMES_FILE} are missing or empty")
                return 2
            commits = git("rev-list", history_range).split()
            found = False
            for commit in commits:
                findings = scan_commit(commit, terms, handle.name)
                if findings:
                    found = True
                    print(git("log", "-1", "--format=%h %s", commit).strip()[:72])
                    print("\n".join("    " + finding for finding in findings))
            if not found:
                print(f"no commit in {history_range} has a private term in a file, a file name, its message or its author")
            return 1 if found else 0

        if not terms:
            print(f"note: {TERMS_FILE} and {NAMES_FILE} are missing or empty, so only the generic credential scan ran")
        allow = load_allow()
        indexed = [name for name in git("ls-files", "-z", "--cached").split("\0") if name]
        if mode == "--staged":
            # The whole index, not only what changed: it is the tree the next commit publishes.
            found = scan("staged", ["--cached"], indexed, terms, handle.name, allow)
        else:
            # Index entries still equal to HEAD are HEAD's text, and `--history` reports those.
            # A fix waiting to be staged would otherwise read as a hit.
            changed = [name for name in git("diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR").split("\0") if name]
            found = bool(changed) and scan("staged", ["--cached"], changed, terms, handle.name, allow, paths=changed)
            # --untracked honours .gitignore, so this covers tracked files plus new ones a commit would add.
            published = [name for name in git("ls-files", "-z", "--cached", "--others", "--exclude-standard").split("\0") if name]
            found |= scan("working tree", ["--untracked"], published, terms, handle.name, allow)
        if not found:
            print("sensitive check: clean")
        return 1 if found else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except ScanFailed as error:
        print(f"sensitive check could not run: {error}")
        sys.exit(2)
