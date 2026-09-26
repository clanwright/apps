#!/usr/bin/env python3
"""Compare a fresh consumer's direct Apps pins with the published Apps lock."""

import json
import pathlib
import sys


NETWORK_REV = "7cbc2a01e9e18299b2ac606714081cc57470778d"
PRIMITIVES_REV = "6979fee86075ae62492e1572be434caf84c8337b"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def direct_node(lock, parent, name):
    parent_node = lock["nodes"][parent]
    node_id = parent_node["inputs"][name]
    require(isinstance(node_id, str), f"{parent}.{name} is not a direct input")
    return lock["nodes"][node_id]


def resolved_input_id(lock, parent, name, resolving=None):
    if resolving is None:
        resolving = set()
    marker = (parent, name)
    require(marker not in resolving, f"cyclic follows at {parent}.{name}")
    link = lock["nodes"][parent]["inputs"][name]
    if isinstance(link, str):
        return link
    require(isinstance(link, list), f"invalid input link at {parent}.{name}")
    return resolve_path(lock, link, resolving | {marker})


def resolve_path(lock, path, resolving=None):
    require(isinstance(path, list), "invalid input path")
    node_id = lock["root"]
    for component in path:
        require(isinstance(component, str), "invalid input path component")
        node_id = resolved_input_id(lock, node_id, component, resolving)
    return node_id


def compare_graph(published, consumer, apps_id):
    # The published root becomes the Apps node in a fresh consumer. Compare
    # logical edges, not generated lock node labels, which Nix may rename.
    pending = [(published["root"], apps_id)]
    seen = set()
    published_to_consumer = {}
    consumer_to_published = {}
    while pending:
        published_id, consumer_id = pending.pop()
        require(
            published_to_consumer.get(published_id, consumer_id) == consumer_id
            and consumer_to_published.get(consumer_id, published_id) == published_id,
            "dependency graph references a different corresponding source",
        )
        published_to_consumer[published_id] = consumer_id
        consumer_to_published[consumer_id] = published_id
        if (published_id, consumer_id) in seen:
            continue
        seen.add((published_id, consumer_id))
        left = published["nodes"][published_id]
        right = consumer["nodes"][consumer_id]
        if published_id != published["root"]:
            require(
                left["locked"] == right["locked"]
                and left["original"] == right["original"],
                "corresponding dependency source identity differs from published Apps lock",
            )
        require(
            left.get("flake", True) == right.get("flake", True),
            "corresponding dependency flake property differs",
        )
        require(
            ("parent" in left) == ("parent" in right),
            "corresponding relative dependency parent differs",
        )
        if "parent" in left:
            pending.append((
                resolve_path(published, left["parent"]),
                resolve_path(consumer, right["parent"]),
            ))
        left_inputs = left.get("inputs", {})
        right_inputs = right.get("inputs", {})
        require(
            left_inputs.keys() == right_inputs.keys(),
            "corresponding dependency input names differ",
        )
        for name in left_inputs:
            pending.append((
                resolved_input_id(published, published_id, name),
                resolved_input_id(consumer, consumer_id, name),
            ))
    return len(seen) - 1


def main():
    consumer = json.loads(pathlib.Path(sys.argv[1]).read_text())
    metadata = json.loads(pathlib.Path(sys.argv[2]).read_text())
    published_path = pathlib.Path(metadata["path"])
    published = json.loads((published_path / "flake.lock").read_text())
    apps = direct_node(consumer, consumer["root"], "apps")
    require(apps["locked"] == metadata["locked"], "consumer Apps source differs from published metadata")
    require(
        all(apps["locked"].get(key) == value for key, value in {
            "type": "github", "owner": "clanwright", "repo": "apps"
        }.items()),
        "consumer Apps source is not the published GitHub repository",
    )
    apps_id = consumer["nodes"][consumer["root"]]["inputs"]["apps"]
    for name, revision in (("network", NETWORK_REV), ("primitives", PRIMITIVES_REV)):
        consumer_node = direct_node(consumer, apps_id, name)
        published_node = direct_node(published, published["root"], name)
        require(
            consumer_node["locked"] == published_node["locked"]
            and consumer_node["original"] == published_node["original"],
            f"{name} source identity differs from the published Apps lock",
        )
        require(
            all(consumer_node["locked"].get(key) == value for key, value in {
                "type": "github", "owner": "clanwright", "repo": name, "rev": revision
            }.items()),
            f"{name} is not pinned to the accepted GitHub revision",
        )
        print(f"{name}: clanwright/{name}@{revision} matches published Apps lock")
    source_count = compare_graph(published, consumer, apps_id)
    print(f"dependency graph: {source_count} corresponding source identities match")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, ValueError, IndexError, TypeError) as error:
        print(f"source identity check failed: {error}", file=sys.stderr)
        sys.exit(1)
