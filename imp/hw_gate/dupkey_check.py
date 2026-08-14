#!/usr/bin/env python3
"""Duplicate-key-aware YAML check for docs/BUG_REGISTRY.yaml.

yaml.safe_load SILENTLY accepts duplicate mapping keys (last-key-wins). That is
exactly how a bare-indented amendment block once got absorbed into the preceding
list item and shadowed TL-041's verification/signoff. This walks the raw node
graph BEFORE construction, so repeated keys are reported with line numbers.

Usage: dupkey_check.py <file.yaml> [<file.yaml> ...]
Exit 0 = clean, 1 = duplicates / structural problem found.
"""
import sys
import yaml

problems = []
docs_out = []


class DupCheckLoader(yaml.SafeLoader):
    pass


def check_mapping(node, path):
    """Walk a raw MappingNode and report repeated keys."""
    seen = {}
    for key_node, val_node in node.value:
        if not isinstance(key_node, yaml.ScalarNode):
            continue
        k = key_node.value
        if k in seen:
            problems.append(
                "DUPLICATE KEY %r at %s\n"
                "    first  : line %d col %d\n"
                "    repeat : line %d col %d"
                % (k, path or "<root>",
                   seen[k].start_mark.line + 1, seen[k].start_mark.column + 1,
                   key_node.start_mark.line + 1, key_node.start_mark.column + 1)
            )
        else:
            seen[k] = key_node
        walk(val_node, "%s.%s" % (path, k) if path else k)


def walk(node, path=""):
    if isinstance(node, yaml.MappingNode):
        check_mapping(node, path)
    elif isinstance(node, yaml.SequenceNode):
        for i, child in enumerate(node.value):
            # label list items by their `id:` when they have one, else index
            label = "[%d]" % i
            if isinstance(child, yaml.MappingNode):
                for kn, vn in child.value:
                    if isinstance(kn, yaml.ScalarNode) and kn.value == "id" \
                            and isinstance(vn, yaml.ScalarNode):
                        label = "[%s]" % vn.value
                        break
            walk(child, path + label)


def main(paths):
    for p in paths:
        with open(p) as fh:
            text = fh.read()
        # --- raw node walk (duplicate detection) ---
        for node in yaml.compose_all(text, Loader=DupCheckLoader):
            if node is not None:
                walk(node, "")
        # --- constructed load (id inventory) ---
        for doc in yaml.safe_load_all(text):
            docs_out.append((p, doc))

    ids = []
    for p, doc in docs_out:
        if isinstance(doc, dict) and isinstance(doc.get("bugs"), list):
            for b in doc["bugs"]:
                if isinstance(b, dict) and "id" in b:
                    ids.append(b["id"])

    dupe_ids = sorted({i for i in ids if ids.count(i) > 1})
    if dupe_ids:
        problems.append("DUPLICATE BUG IDS: %s" % ", ".join(dupe_ids))

    print("entries: %d" % len(ids))
    print("ids: %s" % " ".join(ids))
    missing_fields = []
    for p, doc in docs_out:
        if not (isinstance(doc, dict) and isinstance(doc.get("bugs"), list)):
            continue
        for b in doc["bugs"]:
            if not isinstance(b, dict):
                continue
            for req in ("id", "title", "status", "signoff"):
                if req not in b:
                    missing_fields.append("%s missing %r" % (b.get("id", "?"), req))
    if missing_fields:
        problems.append("MISSING REQUIRED FIELDS:\n    " + "\n    ".join(missing_fields))

    if problems:
        print("\nPROBLEMS (%d):" % len(problems))
        for pr in problems:
            print("  - " + pr)
        return 1
    print("\nOK: no duplicate mapping keys, no duplicate bug ids, no missing core fields.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
