#!/usr/bin/env python3

import sys
import json

def sizeof_fmt(num, suffix='B'):
    for unit in ['', 'Ki', 'Mi', 'Gi', 'Ti', 'Pi', 'Ei', 'Zi']:
        if abs(num) < 1024.0:
            return "%3.1f%s%s" % (num, unit, suffix)
        num /= 1024.0
    return "%.1f%s%s" % (num, 'Yi', suffix)

def get_size(item):
    return item.get("asize", item.get("dsize", 0))

def get_name(item):
    if isinstance(item, dict):
        return item.get("name", "<unknown>")
    return item[0].get("name", "<unknown>")

def get_recursive(item):
    if isinstance(item, dict):
        return get_name(item), get_size(item)

    name = get_name(item)
    size = get_size(item[0])

    for sub in item[1:]:
        size += get_recursive(sub)[1]

    return name, size

def find_path(root, path_parts):
    current = root

    for part in path_parts:
        if not isinstance(current, list):
            return None

        found = None

        for child in current[1:]:
            if get_name(child) == part:
                found = child
                break

        if found is None:
            return None

        current = found

    return current

data = json.loads(sys.stdin.read())

root = data[3]

target_path = sys.argv[1] if len(sys.argv) > 1 else ""
path_parts = [p for p in target_path.strip("/").split("/") if p]

target = find_path(root, path_parts)

if target is None:
    print(f"Path not found: {target_path}")
    sys.exit(1)

if isinstance(target, dict):
    name, size = get_recursive(target)
    print(f"{sizeof_fmt(size)} {name}")
    sys.exit(0)

items = [get_recursive(child) for child in target[1:]]

sum_sizes = sum(size for _, size in items)

if not items or sum_sizes == 0:
    print("No size data found.")
    sys.exit(0)

biggest = max(size for _, size in items)
target_name = get_name(target)

display_path = target_path if target_path else target_name

print("------ {} --- {} -------".format(display_path, sizeof_fmt(sum_sizes)))

for name, size in sorted(items, key=lambda x: x[1], reverse=True):
    hsize = sizeof_fmt(size)
    percent = size / sum_sizes * 100
    percent_str = "({:.1f}%)".format(percent)

    bar_len = round(size / biggest * 10) if biggest else 0

    print("{} {:8} [{}{}] {}".format(
        " " * max(0, 10 - len(str(hsize))) + str(hsize),
        " " * max(0, 8 - len(percent_str)) + percent_str,
        "#" * bar_len,
        "-" * (10 - bar_len),
        name
    ))
