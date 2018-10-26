#!/usr/bin/python2
# needs to be python2 for portage

# Prints out a list of all packages in portage-stable and how they stand relative to gentoo upstream

import argparse
import json
import os
import subprocess
import sys

import portage.versions


def split_package(p):
    # split into cat/package,ver-rev
    split = portage.versions.catpkgsplit(p.strip())
    return (split[0] + "/" + split[1], split[2] + "-" + split[3])


def build_pkg_map(pkgs):
    pkgs = map(split_package, pkgs)
    package_map = dict()
    for pkg, ver in pkgs:
        if pkg not in package_map:
            package_map[pkg] = [ver]
        else:
            package_map[pkg].append(ver)
    return package_map


def exec_command_strict(cmd):
    """ Wraps check_output splitting the input and string'ing the output"""
    return bytes.decode(subprocess.check_output(cmd.split()))


def exec_command(cmd):
    """ Like exec_command_strict but returns the output even if the command exited unsuccessfully"""
    try:
        return exec_command_strict(cmd)
    except subprocess.CalledProcessError as e:
        return bytes.decode(e.output)


def get_portage_tree_packages(tree_path):
    """ returns a list of all packages in a portage tree/overlay in the form of cat/pkg-ver"""
    pkgs = exec_command_strict("find -L {} -maxdepth 3 -type f -name *.ebuild -not -name skel.ebuild -printf %P\\n".format(tree_path))

    def process_line(line):
        # cat/pkg/pkg-ver.ebuild -> cat/pkg-ver
        chunks = line.split("/")
        end = chunks[2].replace(".ebuild", "")
        return chunks[0] + "/" + end
    return build_pkg_map(map(process_line, pkgs.splitlines()))


def process_emerge_output(eout):
    """ transform from emerge --unordered-dispaly to cat/pkg-ver"""
    def process_line(line):
        return line.strip().split("] ")[1].split(":")[0]

    def is_package(line):
        # none of the header line have a /
        return "/" in line

    return map(process_line, filter(is_package, eout.splitlines()))


def get_board_packages(board):
    """ gets a list of packages used by a board. valid boards are amd64-usr, sdk, and bootstrap"""
    emerge_args = "--emptytree --pretend --verbose --unordered-display"
    if board == "sdk":
        cmd = "emerge {} @system sdk-depends sdk-extras".format(emerge_args)
    elif board == "amd64-usr":
        cmd = "emerge-{} {} @system board-packages".format(board, emerge_args)
    elif board == "bootstrap":
        pkgs = exec_command_strict("/usr/lib64/catalyst/targets/stage1/build.py")
        cmd = "emerge {} {}".format(emerge_args, pkgs)
    elif board == "image":
        cmd = "emerge-amd64-usr {} --usepkgonly board-packages".format(emerge_args)
    else:
        raise "invalid board"
    return build_pkg_map(process_emerge_output(exec_command(cmd)))


def print_table(report, head, line_head, line_tail, tail, joiner, pkg_joiner):
    print(head)
    # metapackage that acts as the header
    report.insert(0, {"name": "Package",
                      "common": ["Common"],
                      "ours": ["Ours"],
                      "upstream": ["Upstream"],
                      "tag": "Tag",
                      "sdk": ["sdk"],
                      "amd64-usr": ["amd64-usr"],
                      "bootstrap": ["bootstrap"],
                      "modified": "Modified"})
    for entry in report:
        print(line_head + joiner.join([entry.get("name",""),
              pkg_joiner.join(entry.get("common",[])),
              pkg_joiner.join(entry.get("ours",[])),
              pkg_joiner.join(entry.get("upstream",[])),
              entry.get("tag",""),
              pkg_joiner.join(entry.get("sdk", [])),
              pkg_joiner.join(entry.get("amd64-usr", [])),
              pkg_joiner.join(entry.get("bootstrap", [])),
              entry.get("modified","")]) + line_tail)
    print(tail)


def print_table_human(report):
    print_table(report, "", "", "", "", "\t", " ")


def print_html_table(report):
    print_table(report, "<html><body><table border=1>", "<tr><td>", "</td></tr>", "</table></body></html>", "</td><td>", "<br>")


def get_date(pkg, repo_root, fmt):
    return exec_command_strict("git -C {} --no-pager log -1 --pretty=%ad --date={} {}".format(repo_root, fmt, pkg)).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--update-upstream", help="run git-pull in the gentoo mirror repo first", action="store_true")
    parser.add_argument("--upstream-git", help="git uri to clone for upstream", default="https://github.com/gentoo/gentoo.git")
    parser.add_argument("--upstream-path", help="path to gentoo tree", default="/mnt/host/source/src/gentoo-portage")
    parser.add_argument("--portage-stable-path", help="path to portage-stable", default="/mnt/host/source/src/third_party/portage-stable")
    parser.add_argument("--date-fmt", help="format for git-date to use", default="relative")
    parser.add_argument("--output", help="output format, json, table, and html are accepted", default="json")
    args = parser.parse_args()

    if not os.path.exists(args.upstream_path):
        os.makedirs(args.upstream_path)
        subprocess.check_call(["git", "clone", args.upstream_git, args.upstream_path])
    elif args.update_upstream:
        # elif to not pull if we just cloned
        subprocess.check_call(["git", "-C", args.upstream_path, "pull"])

    pkg_lists = {}
    sources = ["sdk", "bootstrap", "amd64-usr", "image"]
    for i in sources:
        pkg_lists[i] = get_board_packages(i)

    gentoo_packages = get_portage_tree_packages(args.upstream_path)
    packages = get_portage_tree_packages(args.portage_stable_path)

    # time to make the report
    report = []
    for pkg, vers in packages.iteritems():
        upstream = gentoo_packages.get(pkg, [])

        entry = {
            "name": pkg,
            "common": list(set(vers).intersection(upstream)),
            "ours": list(set(vers).difference(upstream)),
            "upstream": list(set(upstream).difference(vers)),
            "modified": get_date(pkg, args.portage_stable_path, args.date_fmt)
        }
        if not entry["upstream"]:
            entry["tag"] = "updated"
        elif entry["common"]:
            entry["tag"] = "has_update"
        elif pkg in gentoo_packages:
            entry["tag"] = "no_ebuild_upstream"
        else:
            entry["tag"] = "deleted_upstream"

        for src in sources:
            if pkg in pkg_lists[src]:
                entry[src] = pkg_lists[src][pkg]
        report.append(entry)

    if args.output == "json":
        print(json.dumps(report))
    elif args.output == "table":
        print_table_human(report)
    elif args.output == "html":
        print_html_table(report)
    else:
        print("Unknown output type. Dying.")
        sys.exit(2)


if __name__ == "__main__":
    main()
