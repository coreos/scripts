#!/usr/bin/python
'''Scan an existing directory tree and record installed directories.

During build a number of directories under /var are created in the stateful
partition. We want to make sure that those are always there so create a record
of them using systemd's tempfiles config format so they are recreated during
boot if they go missing for any reason.
'''

import optparse
import os
import stat
import sys
import pwd
import grp

def main():
    keep = set()
    parser = optparse.OptionParser(description=__doc__)
    parser.add_option('--root', help='Remove root prefix from output')
    parser.add_option('--output', help='Write output to the given file')
    opts, args = parser.parse_args()

    if opts.root:
        opts.root = os.path.abspath(opts.root)

    for path in args:
        path = os.path.abspath(path)
        if opts.root:
            assert path.startswith(opts.root)

        for dirpath, dirnames, filenames in os.walk(path):
            if any(f.startswith('.keep') for f in filenames):
                keep.add(dirpath)

    # Add all parent directories too
    for path in frozenset(keep):
        split = []
        for pathbit in path.split('/'):
            split.append(pathbit)
            joined = '/'.join(split)
            if not joined:
                continue
            if opts.root and not joined.startswith(opts.root):
                continue
            if opts.root == joined:
                continue
            keep.add(joined)

    config = []
    for path in sorted(keep):
        if opts.root:
            assert path.startswith(opts.root)
            stripped = path[len(opts.root):]
            assert len(stripped) > 1
        else:
            stripped = path

        info = os.stat(path)
        assert stat.S_ISDIR(info.st_mode)
        mode = stat.S_IMODE(info.st_mode)

        try:
            owner = pwd.getpwuid(info.st_uid).pw_name
        except KeyError:
            owner = str(info.st_uid)
        try:
            group = grp.getgrgid(info.st_gid).gr_name
        except KeyError:
            group = str(info.st_gid)

        config.append('d %-22s %04o %-10s %-10s - -'
                % (stripped, mode, owner, group))

    if opts.output:
        fd = open(opts.output, 'w')
        fd.write('\n'.join(config))
        fd.close()
    else:
        print '\n'.join(config)

if __name__ == '__main__':
    main()
