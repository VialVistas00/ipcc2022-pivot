#!/usr/bin/env python3
"""Compare two result files after normalizing CRLF to LF."""
import hashlib
import sys


def norm_hash(path):
    data = open(path, "rb").read().replace(b"\r\n", b"\n")
    return hashlib.sha256(data).hexdigest(), data.count(b"\n")


def main():
    if len(sys.argv) != 3:
        print("usage: verify_result.py <result.txt> <refer.txt>")
        return 2

    got_hash, got_lines = norm_hash(sys.argv[1])
    ref_hash, ref_lines = norm_hash(sys.argv[2])
    same = got_hash == ref_hash

    print("result %s lines=%d" % (got_hash, got_lines))
    print("refer  %s lines=%d" % (ref_hash, ref_lines))
    print("SAME" if same else "DIFF")
    return 0 if same else 1


if __name__ == "__main__":
    sys.exit(main())
