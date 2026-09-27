#!/usr/bin/env python3
"""Prepare ordinary consumer flakes and verify candidate source identities."""

import json
import pathlib
import re
import shutil
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def direct_id(lock, parent, name):
    node_id = lock["nodes"][parent]["inputs"][name]
    require(isinstance(node_id, str), f"{parent}.{name} is not a direct input")
    return node_id


def direct_node(lock, parent, name):
    return lock["nodes"][direct_id(lock, parent, name)]


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


def compare_graph(candidate, consumer, apps_id):
    # Candidate root becomes the Apps node. Nix may rename generated labels.
    pending = [(candidate["root"], apps_id)]
    seen = set()
    candidate_to_consumer = {}
    consumer_to_candidate = {}
    while pending:
        candidate_id, consumer_id = pending.pop()
        require(
            candidate_to_consumer.get(candidate_id, consumer_id) == consumer_id
            and consumer_to_candidate.get(consumer_id, candidate_id) == candidate_id,
            "dependency graph references a different corresponding source",
        )
        candidate_to_consumer[candidate_id] = consumer_id
        consumer_to_candidate[consumer_id] = candidate_id
        if (candidate_id, consumer_id) in seen:
            continue
        seen.add((candidate_id, consumer_id))
        left = candidate["nodes"][candidate_id]
        right = consumer["nodes"][consumer_id]
        if candidate_id != candidate["root"]:
            require(
                left["locked"] == right["locked"]
                and left["original"] == right["original"],
                "corresponding dependency source identity differs from candidate Apps lock",
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
                resolve_path(candidate, left["parent"]),
                resolve_path(consumer, right["parent"]),
            ))
        left_inputs = left.get("inputs", {})
        right_inputs = right.get("inputs", {})
        require(left_inputs.keys() == right_inputs.keys(), "corresponding dependency input names differ")
        for name in left_inputs:
            pending.append((
                resolved_input_id(candidate, candidate_id, name),
                resolved_input_id(consumer, consumer_id, name),
            ))
    return len(seen) - 1


def candidate_lock(metadata):
    return json.loads((pathlib.Path(metadata["path"]) / "flake.lock").read_text())


def compare_untouched(historical, consumer):
    before = historical["nodes"][historical["root"]]["inputs"]
    after = consumer["nodes"][consumer["root"]]["inputs"]
    require(before.keys() == after.keys(), "historical root inputs were added or removed")
    selected = {"apps", "network", "primitives"}
    selected_pairs = {
        (direct_id(historical, historical["root"], name),
         direct_id(consumer, consumer["root"], name))
        for name in selected
    }
    selected_ids = {
        direct_id(historical, historical["root"], name) for name in selected
    }
    pending = []
    for name in before.keys() - selected:
        old_link, new_link = before[name], after[name]
        require(type(old_link) is type(new_link), f"historical {name} input kind changed")
        if isinstance(old_link, list):
            require(old_link == new_link, f"historical {name} follows changed")
            pending.append((resolve_path(historical, old_link), resolve_path(consumer, new_link)))
        else:
            pending.append((old_link, new_link))
    seen = set()
    while pending:
        old_id, new_id = pending.pop()
        if (old_id, new_id) in selected_pairs:
            continue
        require(old_id not in selected_ids,
                "historical dependency was redirected to a different updated input")
        if (old_id, new_id) in seen:
            continue
        seen.add((old_id, new_id))
        old = historical["nodes"][old_id]
        new = consumer["nodes"][new_id]
        require(old["locked"] == new["locked"] and old["original"] == new["original"],
                f"historical unrelated source {old_id} changed")
        require(old.get("flake", True) == new.get("flake", True),
                f"historical unrelated source {old_id} flake property changed")
        require(old.get("parent") == new.get("parent"),
                f"historical unrelated source {old_id} parent changed")
        old_inputs, new_inputs = old.get("inputs", {}), new.get("inputs", {})
        require(old_inputs.keys() == new_inputs.keys(), f"historical unrelated source {old_id} inputs changed")
        for name in old_inputs:
            old_link, new_link = old_inputs[name], new_inputs[name]
            require(type(old_link) is type(new_link), f"historical {old_id}.{name} input kind changed")
            if isinstance(old_link, list):
                require(old_link == new_link, f"historical {old_id}.{name} follows changed")
            pending.append((resolved_input_id(historical, old_id, name),
                            resolved_input_id(consumer, new_id, name)))
    return len(seen)


def pinned_url(node, name):
    locked = node["locked"]
    require(
        locked.get("type") == "github"
        and locked.get("owner") == "clanwright"
        and locked.get("repo") == name
        and isinstance(locked.get("rev"), str),
        f"candidate {name} is not an exact clanwright GitHub revision",
    )
    return f'github:clanwright/{name}/{locked["rev"]}'


def flake_text(apps_url, network_url=None, primitives_url=None):
    if network_url is None:
        return '''{
  inputs.apps.url = %s;
  outputs = { self, apps }: {
    checks.x86_64-linux.apps-contract = apps.checks.x86_64-linux.contract;
  };
}
''' % json.dumps(apps_url)
    return '''{
  inputs.apps.url = %s;
  inputs.network.url = %s;
  inputs.primitives.url = %s;
  outputs = { self, apps, network, primitives }: {
    checks.x86_64-linux.apps-contract = apps.checks.x86_64-linux.contract;
  };
}
''' % tuple(json.dumps(url) for url in (apps_url, network_url, primitives_url))


def prepare(metadata_path, run_dir, apps_ref, existing_lock_path):
    metadata = json.loads(pathlib.Path(metadata_path).read_text())
    candidate = candidate_lock(metadata)
    network_url = pinned_url(direct_node(candidate, candidate["root"], "network"), "network")
    primitives_url = pinned_url(direct_node(candidate, candidate["root"], "primitives"), "primitives")
    run_dir = pathlib.Path(run_dir)
    apps_only = run_dir / "apps-only"
    apps_only.mkdir()
    (apps_only / "flake.nix").write_text(flake_text(apps_ref))
    coordinated = run_dir / "coordinated"
    coordinated.mkdir()
    (coordinated / "flake.nix").write_text(flake_text(apps_ref, network_url, primitives_url))
    if existing_lock_path:
        historical = json.loads(pathlib.Path(existing_lock_path).read_text())
        for name in ("apps", "network", "primitives"):
            node = direct_node(historical, historical["root"], name)
            require(
                node["locked"].get("type") == "github"
                and node["locked"].get("owner") == "clanwright"
                and node["locked"].get("repo") == name,
                f"historical {name} is not a clanwright GitHub source",
            )
        existing = run_dir / "existing"
        existing.mkdir()
        source_flake = pathlib.Path(existing_lock_path).with_name("flake.nix")
        require(source_flake.is_file(), "historical lock needs its sibling flake.nix")
        source = source_flake.read_text()
        require("  inputs = {" in source and "  outputs =" in source, "unsupported historical flake input layout")
        prefix = source.split("  outputs =", 1)[0]
        for name, url in (("apps", apps_ref), ("network", network_url), ("primitives", primitives_url)):
            prefix, count = re.subn(
                rf'(?m)^(\s*{name}\.url\s*=\s*)"[^"]+";',
                lambda match: match.group(1) + json.dumps(url) + ";",
                prefix,
            )
            require(count == 1, f"historical flake needs one {name}.url declaration")
        (existing / "flake.nix").write_text(prefix + '''  outputs = { self, apps, ... }: {
    checks.x86_64-linux.apps-contract = apps.checks.x86_64-linux.contract;
  };
}
''')
        # Preserve relative consumer-owned inputs in the isolated fixture.
        relative = source_flake.parent / "stubs" / "data-mesher"
        if relative.is_dir():
            shutil.copytree(relative, existing / "stubs" / "data-mesher")
        shutil.copyfile(existing_lock_path, existing / "flake.lock")
        shutil.copyfile(existing_lock_path, run_dir / "historical-flake.lock")
        print("Historical lock copied unchanged; updating direct Apps, Network, and Primitives inputs")
    print(f"Candidate direct inputs: {network_url}, {primitives_url}")


def verify(consumer_path, metadata_path, scenario, historical_path=None):
    consumer = json.loads(pathlib.Path(consumer_path).read_text())
    metadata = json.loads(pathlib.Path(metadata_path).read_text())
    candidate = candidate_lock(metadata)
    root = consumer["root"]
    apps_id = direct_id(consumer, root, "apps")
    apps = consumer["nodes"][apps_id]
    metadata_locked = {k: v for k, v in metadata["locked"].items() if k != "__final"}
    require(apps["locked"] == metadata_locked, "consumer Apps source differs from candidate metadata")
    for name in ("network", "primitives"):
        nested_node = direct_node(consumer, apps_id, name)
        candidate_node = direct_node(candidate, candidate["root"], name)
        require(nested_node["locked"] == candidate_node["locked"], f"Apps and candidate {name} locked sources diverge")
        if scenario == "coordinated":
            root_node = direct_node(consumer, root, name)
            require(root_node["locked"] == candidate_node["locked"], f"root and Apps {name} locked sources diverge")
        require(
            nested_node["original"] == candidate_node["original"],
            f"Apps {name} original source differs from candidate",
        )
        pinned_url(candidate_node, name)
        prefix = "root and Apps" if scenario == "coordinated" else "Apps"
        print(f"{name}: {prefix} resolve to {candidate_node['locked']['rev']}")
    source_count = compare_graph(candidate, consumer, apps_id)
    print(f"dependency graph: {source_count} corresponding source identities match")
    if historical_path:
        historical = json.loads(pathlib.Path(historical_path).read_text())
        count = compare_untouched(historical, consumer)
        print(f"historical unrelated dependency graph: {count} source identities preserved")


def main():
    command = sys.argv[1]
    if command == "prepare" and len(sys.argv) == 6:
        prepare(*sys.argv[2:])
    elif command == "verify" and len(sys.argv) in (5, 6):
        verify(*sys.argv[2:])
    else:
        raise ValueError("usage: source-identity.py prepare METADATA RUN_DIR APPS_REF EXISTING_LOCK | verify CONSUMER_LOCK METADATA")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, ValueError, IndexError, TypeError) as error:
        print(f"source identity check failed: {error}", file=sys.stderr)
        sys.exit(1)
