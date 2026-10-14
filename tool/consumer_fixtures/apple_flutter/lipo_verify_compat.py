#!/usr/bin/env python3
"""Opt-in consumer-build adapter for broken multi-arch lipo verification.

Some Xcode 27 lipo versions reject multiple -verify_arch operands even though
single-architecture verification works. Verify each architecture with the real
system tool and propagate any failure. All other operations remain native.
Install a copy named `lipo` only on the owned build's PATH; never replace the
system binary. Product inspection must still require both final architectures.
"""
import subprocess
import sys


def run(args, invoke=subprocess.call):
    if len(args) > 3 and not args[0].startswith('-') and args[1] == '-verify_arch':
        for arch in args[2:]:
            result = invoke(['/usr/bin/lipo', args[0], '-verify_arch', arch])
            if result != 0:
                return result
        return 0
    return invoke(['/usr/bin/lipo', *args])


if __name__ == '__main__':
    raise SystemExit(run(sys.argv[1:]))
